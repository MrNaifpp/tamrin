-- What the merge of the guest sprint and the waiting list has to get right.
-- Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/merge_guests_and_waitlist_test.sql

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
  ('40000000-0000-0000-0000-000000000001', 'mg-owner@test.local'),
  ('40000000-0000-0000-0000-000000000002', 'mg-a@test.local'),
  ('40000000-0000-0000-0000-000000000003', 'mg-b@test.local'),
  ('40000000-0000-0000-0000-000000000004', 'mg-c@test.local');

insert into public.users (user_id, name) values
  ('40000000-0000-0000-0000-000000000001', 'المنظّم'),
  ('40000000-0000-0000-0000-000000000002', 'عضو أ'),
  ('40000000-0000-0000-0000-000000000003', 'عضو ب'),
  ('40000000-0000-0000-0000-000000000004', 'عضو ج');

do $$
declare
  OWNER_ID constant uuid := '40000000-0000-0000-0000-000000000001';
  A_ID     constant uuid := '40000000-0000-0000-0000-000000000002';
  B_ID     constant uuid := '40000000-0000-0000-0000-000000000003';
  C_ID     constant uuid := '40000000-0000-0000-0000-000000000004';
  v_workspace_id uuid;
  v_method_id uuid;
  v_event_id uuid;
  v_closed_id uuid;
  v_result json;
  v_text text;
  v_count int;
  v_declared timestamptz;
begin
  perform pg_temp.set_auth(OWNER_ID);
  v_workspace_id := (public.create_workspace('مجموعة الدمج')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, A_ID), (v_workspace_id, B_ID), (v_workspace_id, C_ID);

  insert into public.workspace_payment_methods (workspace_id, provider, mobile_number)
  values (v_workspace_id, 'stc_bank', '0500000000')
  returning id into v_method_id;

  -- ========================================================================
  -- A paid event with a reserve list. Three seats, one of them the organizer's.
  -- ========================================================================
  v_event_id := (public.create_event(
    p_creator_id => OWNER_ID,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مدفوع',
    p_start_date => now() + interval '2 hours',
    p_max_participants => 2,
    p_total_price => 100,
    p_price_per_person => 50,
    p_payment_method_ids => array[v_method_id]
  )->>'id')::uuid;
  perform public.publish_event(v_event_id);

  -- A seat taken before any money moves is 'pending' and undeclared.
  perform pg_temp.set_auth(A_ID);
  v_result := public.register_event_seat(p_event_id => v_event_id);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: A could not take a seat (%)', v_result->>'status';
  end if;
  select payment_status, payment_declared_at into v_text, v_declared
  from public.event_participants where event_id = v_event_id and user_id = A_ID;
  if v_text <> 'pending' or v_declared is not null then
    raise exception 'FAIL: held seat was % / declared %', v_text, v_declared;
  end if;

  -- The event is now full of held-but-unpaid seats. It must read as full.
  perform pg_temp.set_auth(B_ID);
  v_result := public.register_event_seat(p_event_id => v_event_id);
  if v_result->>'status' <> 'waitlisted' then
    raise exception 'FAIL: expected B on the reserve list, got %', v_result->>'status';
  end if;

  -- ========================================================================
  -- Promotion off the queue, into a seat that still owes money.
  -- ========================================================================
  perform pg_temp.set_auth(A_ID);
  perform public.decline_event(v_event_id, 'commitment', null);

  select count(*) into v_count from public.event_waitlist where event_id = v_event_id;
  if v_count <> 0 then raise exception 'FAIL: B was not promoted off the queue'; end if;

  select payment_status, payment_declared_at into v_text, v_declared
  from public.event_participants where event_id = v_event_id and user_id = B_ID;
  if v_text is null then raise exception 'FAIL: B holds no seat after promotion'; end if;
  if v_text <> 'pending' or v_declared is not null then
    raise exception 'FAIL: promoted seat was % / declared % -- a free ride', v_text, v_declared;
  end if;

  if not exists (
    select 1 from public.push_outbox
    where event_id = v_event_id and user_id = B_ID and type = 'waitlist_promoted'
  ) then
    raise exception 'FAIL: B was not told they were promoted';
  end if;

  -- Declaring the transfer marks the same seat, and asks the organizer.
  perform pg_temp.set_auth(B_ID);
  v_result := public.declare_event_payment(v_event_id, v_method_id);
  if v_result->>'status' <> 'declared' then
    raise exception 'FAIL: B could not declare payment (%)', v_result->>'status';
  end if;
  select payment_declared_at into v_declared
  from public.event_participants where event_id = v_event_id and user_id = B_ID;
  if v_declared is null then raise exception 'FAIL: the declaration was not recorded'; end if;

  -- ========================================================================
  -- A closed event offers no queue, and says so.
  -- ========================================================================
  perform pg_temp.set_auth(OWNER_ID);
  v_closed_id := (public.create_event(
    p_creator_id => OWNER_ID,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مقفل',
    p_start_date => now() + interval '3 hours',
    p_max_participants => 1,
    p_total_price => 100,
    p_price_per_person => 50,
    p_payment_method_ids => array[v_method_id],
    p_capacity_policy => 'closed'
  )->>'id')::uuid;
  perform public.publish_event(v_closed_id);

  perform pg_temp.set_auth(C_ID);
  v_result := public.register_event_seat(p_event_id => v_closed_id);
  if v_result->>'status' <> 'registration_closed_full' then
    raise exception 'FAIL: a closed event queued someone (%)', v_result->>'status';
  end if;
  select count(*) into v_count from public.event_waitlist where event_id = v_closed_id;
  if v_count <> 0 then raise exception 'FAIL: a closed event kept a reserve list'; end if;

  v_result := public.submit_payment_v2(p_event_id => v_closed_id);
  if v_result->>'status' <> 'registration_closed_full' then
    raise exception 'FAIL: submit_payment_v2 ignored the closed policy (%)', v_result->>'status';
  end if;

  -- ========================================================================
  -- The roster still carries both worlds: the queue, and the money columns.
  -- ========================================================================
  perform pg_temp.set_auth(OWNER_ID);
  perform public.register_event_seat(p_event_id => v_event_id);
  perform pg_temp.set_auth(C_ID);
  perform public.register_event_seat(p_event_id => v_event_id);

  select count(*) into v_count
  from json_array_elements(public.get_event_participants_lifecycle_impl(v_event_id)) e
  where (e->>'is_waitlisted')::boolean;
  if v_count < 1 then raise exception 'FAIL: the roster lost its reserve rows'; end if;

  if not exists (
    select 1
    from json_array_elements(public.get_event_participants_lifecycle_impl(v_event_id)) e
    where e::jsonb ?& array['payment_declared_at', 'guest_only', 'player_position']
  ) then
    raise exception 'FAIL: the roster lost the payment-walk columns';
  end if;
end $$;

select 'ALL MERGE TESTS PASSED' as result;
rollback;
