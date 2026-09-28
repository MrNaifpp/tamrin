-- A paid event whose organizer has no payment method still takes registrations.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/registration_without_payment_method_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text,
    true
  );
end;
$$;

insert into auth.users (id, email) values
  ('45000000-0000-0000-0000-000000000001', 'nomethod-owner@test.local'),
  ('45000000-0000-0000-0000-000000000002', 'nomethod-member@test.local'),
  ('45000000-0000-0000-0000-000000000003', 'nomethod-guest-only@test.local');

insert into public.users (user_id, name) values
  ('45000000-0000-0000-0000-000000000001', 'منظم بلا وسيلة'),
  ('45000000-0000-0000-0000-000000000002', 'عضو يسجل'),
  ('45000000-0000-0000-0000-000000000003', 'عضو يسجل ضيوفه فقط');

do $$
declare
  v_workspace_id uuid;
  v_method_id uuid;
  v_event_id uuid;
  v_with_method_event_id uuid;
  v_destination json;
  v_result json;
begin
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_workspace_id := (public.create_workspace('مجموعة بلا وسيلة دفع')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '45000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '45000000-0000-0000-0000-000000000003');

  v_method_id := (public.upsert_workspace_payment_method(
    v_workspace_id, 'stc_bank', '0500000009'
  )->>'id')::uuid;

  v_event_id := (public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مدفوع بلا وسيلة',
    p_start_date => now() + interval '3 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => array[v_method_id]
  )->>'id')::uuid;
  v_with_method_event_id := (public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مدفوع بوسيلة',
    p_start_date => now() + interval '3 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => array[v_method_id]
  )->>'id')::uuid;

  -- The state prod events are in: paid, with no method on the event.
  update public.events
  set payment_method_ids = '{}', payment_method_id = null
  where id = v_event_id;

  -- Registering: no seat yet, so both destinations answer 'available'.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_destination := public.get_event_payment_destination(v_event_id);
  if v_destination->>'status' <> 'available'
     or jsonb_array_length((v_destination->'payment_methods')::jsonb) <> 0
     or (v_destination->>'event_id')::uuid <> v_event_id
     or (v_destination->>'price_per_person')::numeric <> 100 then
    raise exception 'FAIL: self destination before registering %', v_destination;
  end if;

  v_destination := public.get_event_guest_payment_destination(v_event_id);
  if v_destination->>'status' <> 'available'
     or jsonb_array_length((v_destination->'payment_methods')::jsonb) <> 0
     or (v_destination->>'event_id')::uuid <> v_event_id then
    raise exception 'FAIL: guest destination without a method %', v_destination;
  end if;

  v_result := public.register_event_seat(
    p_event_id => v_event_id,
    p_expected_price_per_person => 100
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: self registration without a method returned %', v_result;
  end if;

  -- «سجّل معك أحد» from a held seat.
  v_result := public.register_event_guests(
    p_event_id => v_event_id,
    p_guest_names => array['ضيف بلا وسيلة'],
    p_expected_price_per_person => 100
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: guest registration without a method returned %', v_result;
  end if;

  -- Paying: the seat is held, so the pay sheet still hears there is no method.
  v_destination := public.get_event_payment_destination(v_event_id);
  if v_destination->>'status' <> 'payment_method_required' then
    raise exception 'FAIL: pay destination for a seat holder %', v_destination;
  end if;

  -- Guests without self: the payer holds no row of their own, only guest rows.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000003');
  v_result := public.register_event_guest_only(
    p_event_id => v_event_id,
    p_guest_names => array['ضيف بدون صاحبه'],
    p_expected_price_per_person => 100
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: guest-only registration without a method returned %', v_result;
  end if;
  v_destination := public.get_event_payment_destination(v_event_id);
  if v_destination->>'status' <> 'payment_method_required' then
    raise exception 'FAIL: pay destination for a guest-only payer %', v_destination;
  end if;

  -- An event that has a method is unchanged.
  v_destination := public.get_event_payment_destination(v_with_method_event_id);
  if v_destination->>'status' <> 'available'
     or jsonb_array_length((v_destination->'payment_methods')::jsonb) <> 1 then
    raise exception 'FAIL: destination with a method %', v_destination;
  end if;
  v_destination := public.get_event_guest_payment_destination(v_with_method_event_id);
  if v_destination->>'status' <> 'available'
     or jsonb_array_length((v_destination->'payment_methods')::jsonb) <> 1 then
    raise exception 'FAIL: guest destination with a method %', v_destination;
  end if;

  raise notice 'PASS: registration_without_payment_method';
end;
$$;

rollback;
