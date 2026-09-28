-- «سجّل معك أحد» on a paid workout with several payment methods. The app sends
-- no method when adding guests, so the server must not ask for one.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/guests_with_several_payment_methods_test.sql

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
  ('45000000-0000-0000-0000-000000000001', 'methods-owner@test.local'),
  ('45000000-0000-0000-0000-000000000002', 'methods-member@test.local'),
  ('45000000-0000-0000-0000-000000000003', 'methods-guest-only@test.local'),
  ('45000000-0000-0000-0000-000000000004', 'methods-confirmed@test.local');

insert into public.users (user_id, name) values
  ('45000000-0000-0000-0000-000000000001', 'منظم بثلاث وسائل'),
  ('45000000-0000-0000-0000-000000000002', 'عضو يضيف ضيفًا'),
  ('45000000-0000-0000-0000-000000000003', 'عضو يسجل ضيوفه فقط'),
  ('45000000-0000-0000-0000-000000000004', 'عضو دفعه مؤكد');

do $$
declare
  v_workspace_id uuid;
  v_method_ids uuid[];
  v_event_id uuid;
  v_result json;
  v_count int;
begin
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_workspace_id := (public.create_workspace('مجموعة الوسائل الثلاث')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '45000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '45000000-0000-0000-0000-000000000003'),
    (v_workspace_id, '45000000-0000-0000-0000-000000000004');

  v_method_ids := array[
    (public.upsert_workspace_payment_method(v_workspace_id, 'stc_bank', '0500000011')->>'id')::uuid,
    (public.upsert_workspace_payment_method(v_workspace_id, 'barq', '0500000012')->>'id')::uuid,
    (public.upsert_workspace_payment_method(v_workspace_id, 'cash')->>'id')::uuid
  ];

  v_event_id := (public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين بثلاث وسائل دفع',
    p_start_date => now() + interval '3 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => v_method_ids
  )->>'id')::uuid;

  -- The prod report: a member whose payment the organizer already confirmed.
  -- The Aug 19 body answered 'payment_method_required' here.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000004');
  v_result := public.register_event_seat(
    p_event_id => v_event_id,
    p_expected_price_per_person => 100
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: confirmed member registration returned %', v_result;
  end if;
  update public.event_participants
  set payment_status = 'confirmed'
  where event_id = v_event_id
    and user_id = '45000000-0000-0000-0000-000000000004';
  v_result := public.register_event_guests(
    p_event_id => v_event_id,
    p_guest_names => array['ضيف المؤكد'],
    p_expected_payment_method_id => null,
    p_expected_price_per_person => 100,
    p_payment_method_id => null
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: guests from a confirmed seat returned %', v_result;
  end if;

  -- The member's own seat, as «سجّل التمرين» takes it: pending, undeclared.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_event_id,
    p_expected_price_per_person => 100
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: self registration returned %', v_result;
  end if;

  -- «سجّل معك أحد», called exactly as the app calls it: no method.
  v_result := public.register_event_guests(
    p_event_id => v_event_id,
    p_guest_names => array['ضيف أول', 'ضيف ثان'],
    p_expected_payment_method_id => null,
    p_expected_price_per_person => 100,
    p_payment_method_id => null
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: guests on a 3-method workout returned %', v_result;
  end if;

  select count(*) into v_count
  from public.event_participants
  where event_id = v_event_id
    and user_id is null
    and added_by = '45000000-0000-0000-0000-000000000002'
    and payment_status = 'pending'
    and payment_declared_at is null
    and payment_method_id is null;
  if v_count <> 2 then
    raise exception 'FAIL: expected 2 undeclared guest seats, found %', v_count;
  end if;

  -- Guests without the member's own seat go through the same impl.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000003');
  v_result := public.register_event_guest_only(
    p_event_id => v_event_id,
    p_guest_names => array['ضيف بدون صاحبه'],
    p_expected_payment_method_id => null,
    p_expected_price_per_person => 100,
    p_payment_method_id => null
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: guest-only on a 3-method workout returned %', v_result;
  end if;

  raise notice 'PASS: guests_with_several_payment_methods';
end;
$$;

rollback;
