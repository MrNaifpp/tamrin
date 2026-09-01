-- Capacity policy + automatic waitlist promotion. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/waitlist_promotion_test.sql

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
  ('30000000-0000-0000-0000-000000000001', 'wl-owner@test.local'),
  ('30000000-0000-0000-0000-000000000002', 'wl-a@test.local'),
  ('30000000-0000-0000-0000-000000000003', 'wl-b@test.local'),
  ('30000000-0000-0000-0000-000000000004', 'wl-c@test.local'),
  ('30000000-0000-0000-0000-000000000005', 'wl-d@test.local');

insert into public.users (user_id, name) values
  ('30000000-0000-0000-0000-000000000001', 'المنظّم'),
  ('30000000-0000-0000-0000-000000000002', 'عضو أ'),
  ('30000000-0000-0000-0000-000000000003', 'عضو ب'),
  ('30000000-0000-0000-0000-000000000004', 'عضو ج'),
  ('30000000-0000-0000-0000-000000000005', 'عضو د');

do $$
declare
  OWNER_ID constant uuid := '30000000-0000-0000-0000-000000000001';
  A_ID     constant uuid := '30000000-0000-0000-0000-000000000002';
  B_ID     constant uuid := '30000000-0000-0000-0000-000000000003';
  C_ID     constant uuid := '30000000-0000-0000-0000-000000000004';
  D_ID     constant uuid := '30000000-0000-0000-0000-000000000005';
  v_workspace_id uuid;
  v_event json;
  v_event_id uuid;
  v_closed_id uuid;
  v_uncapped_id uuid;
  v_series_id uuid;
  v_template_id uuid;
  v_result json;
  v_roster json;
  v_count int;
  v_text text;
  v_uuid uuid;
  v_failed boolean;
begin
  perform pg_temp.set_auth(OWNER_ID);
  v_workspace_id := (public.create_workspace('مجموعة قائمة الانتظار')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, A_ID), (v_workspace_id, B_ID),
    (v_workspace_id, C_ID), (v_workspace_id, D_ID);

  -- ========================================================================
  -- Default policy
  -- ========================================================================
  v_event := public.create_event(
    p_creator_id => OWNER_ID,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين قائمة الانتظار',
    p_start_date => now() + interval '2 hours',
    p_max_participants => 3
  );
  v_event_id := (v_event->>'id')::uuid;

  select capacity_policy into v_text from public.events where id = v_event_id;
  if v_text is distinct from 'waitlist' then
    raise exception 'FAIL: default capacity_policy was %, expected waitlist', v_text;
  end if;

  -- An unknown policy is refused rather than silently stored.
  v_failed := false;
  begin
    perform public.create_event(
      p_creator_id => OWNER_ID,
      p_workspace_id => v_workspace_id,
      p_name => 'سياسة غير معروفة',
      p_start_date => now() + interval '2 hours',
      p_capacity_policy => 'whatever'
    );
  exception when others then
    v_failed := sqlerrm like 'Invalid capacity policy%';
  end;
  if not v_failed then raise exception 'FAIL: an invalid capacity policy was accepted'; end if;


  -- ========================================================================
  -- Fill the event. The creator already holds one of the three seats.
  -- ========================================================================
  perform pg_temp.set_auth(A_ID);
  v_result := public.submit_payment_v2(p_event_id => v_event_id);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: member A could not register (%)', v_result->>'status';
  end if;

  perform pg_temp.set_auth(B_ID);
  perform public.submit_payment_v2(p_event_id => v_event_id);

  select count(*) into v_count from public.event_participants
  where event_id = v_event_id and payment_status = 'confirmed';
  if v_count <> 3 then raise exception 'FAIL: expected 3 confirmed seats, got %', v_count; end if;

  -- A full 'waitlist' event offers the queue.
  perform pg_temp.set_auth(C_ID);
  v_result := public.submit_payment_v2(p_event_id => v_event_id);
  if v_result->>'status' <> 'seats_full' then
    raise exception 'FAIL: expected seats_full, got %', v_result->>'status';
  end if;

  perform public.join_waitlist(v_event_id, C_ID);
  perform pg_temp.set_auth(D_ID);
  perform public.join_waitlist(v_event_id, D_ID);

  -- ========================================================================
  -- The roster carries the queue, seated players first
  -- ========================================================================
  perform pg_temp.set_auth(OWNER_ID);
  v_roster := public.get_event_participants(v_event_id);

  select count(*) into v_count
  from json_array_elements(v_roster) e where (e->>'is_waitlisted')::boolean;
  if v_count <> 2 then raise exception 'FAIL: roster showed % waiters, expected 2', v_count; end if;

  select count(*) into v_count
  from json_array_elements(v_roster) e where not (e->>'is_waitlisted')::boolean;
  if v_count <> 3 then raise exception 'FAIL: roster showed % seated, expected 3', v_count; end if;

  -- Waiters sort after every seated player, and oldest-first among themselves:
  -- that is the order they will be promoted in.
  select (json_array_elements(v_roster)->>'is_waitlisted')::boolean into v_failed limit 1;
  if v_failed then raise exception 'FAIL: a waiter sorted ahead of the seated players'; end if;

  select e->>'user_id' into v_text
  from json_array_elements(v_roster) e
  where (e->>'is_waitlisted')::boolean limit 1;
  if v_text::uuid <> C_ID then
    raise exception 'FAIL: queue head was %, expected the earliest waiter', v_text;
  end if;

  -- A waiter carries no payment snapshot.
  select count(*) into v_count
  from json_array_elements(v_roster) e
  where (e->>'is_waitlisted')::boolean and e->>'payment_status' is not null;
  if v_count <> 0 then raise exception 'FAIL: a waiter carried a payment status'; end if;

  -- ========================================================================
  -- Declining frees a seat, promotes the longest waiter, and tells both sides
  -- ========================================================================
  perform pg_temp.set_auth(A_ID);
  perform public.decline_event(v_event_id, 'busy', null);

  select payment_status into v_text from public.event_participants
  where event_id = v_event_id and user_id = C_ID;
  if v_text is distinct from 'confirmed' then
    raise exception 'FAIL: promoted waiter had status %, expected confirmed', v_text;
  end if;

  select count(*) into v_count from public.event_waitlist
  where event_id = v_event_id and user_id = C_ID;
  if v_count <> 0 then raise exception 'FAIL: promoted waiter kept their queue row'; end if;

  -- D waited longer than nobody: one seat freed, so exactly one promotion.
  select count(*) into v_count from public.event_waitlist where event_id = v_event_id;
  if v_count <> 1 then raise exception 'FAIL: % waiters left, expected 1', v_count; end if;

  select count(*) into v_count from public.event_participants
  where event_id = v_event_id and payment_status = 'confirmed';
  if v_count <> 3 then
    raise exception 'FAIL: promotion pushed the count to %, over the cap of 3', v_count;
  end if;

  -- The organizer is told a member pulled out. This is the bug that made the
  -- withdrawal invisible: decline_event used to enqueue nothing at all.
  select count(*) into v_count from public.push_outbox
  where event_id = v_event_id and user_id = OWNER_ID and type = 'member_declined';
  if v_count <> 1 then
    raise exception 'FAIL: organizer got % member_declined pushes, expected 1', v_count;
  end if;

  select count(*) into v_count from public.push_outbox
  where event_id = v_event_id and user_id = C_ID and type = 'waitlist_promoted';
  if v_count <> 1 then
    raise exception 'FAIL: promoted waiter got % pushes, expected 1', v_count;
  end if;

  -- No further seat is free, so the last waiter stays put.
  perform pg_temp.set_auth(OWNER_ID);
  if public.promote_from_waitlist(v_event_id) is not null then
    raise exception 'FAIL: promoted into a full event';
  end if;

  -- ========================================================================
  -- Several seats freeing promote several waiters
  -- ========================================================================
  perform pg_temp.set_auth(B_ID);
  perform public.decline_event(v_event_id, null, null);
  select count(*) into v_count from public.event_waitlist where event_id = v_event_id;
  if v_count <> 0 then raise exception 'FAIL: queue not drained, % left', v_count; end if;

  -- ========================================================================
  -- 'closed': no queue, and a distinct full state for the UI
  -- ========================================================================
  perform pg_temp.set_auth(OWNER_ID);
  v_closed_id := (public.create_event(
    p_creator_id => OWNER_ID,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين يقفل عند الاكتمال',
    p_start_date => now() + interval '2 hours',
    p_max_participants => 1,
    p_capacity_policy => 'closed'
  )->>'id')::uuid;

  perform pg_temp.set_auth(A_ID);
  v_result := public.submit_payment_v2(p_event_id => v_closed_id);
  if v_result->>'status' <> 'registration_closed_full' then
    raise exception 'FAIL: closed+full returned %, expected registration_closed_full',
      v_result->>'status';
  end if;

  v_failed := false;
  begin
    perform public.join_waitlist(v_closed_id, A_ID);
  exception when others then
    v_failed := sqlerrm like '%no waiting list%';
  end;
  if not v_failed then raise exception 'FAIL: joined the queue of a closed event'; end if;

  -- Switching to 'waitlist' does not retroactively seat anyone, but it does
  -- reopen the queue.
  perform pg_temp.set_auth(OWNER_ID);
  perform public.set_event_capacity_policy(v_closed_id, 'waitlist');
  perform pg_temp.set_auth(A_ID);
  perform public.join_waitlist(v_closed_id, A_ID);
  select count(*) into v_count from public.event_waitlist where event_id = v_closed_id;
  if v_count <> 1 then raise exception 'FAIL: queue did not reopen'; end if;

  -- ...and switching back to 'closed' keeps the people already queued, who are
  -- still promoted when a seat frees. Closing stops new waiters, it does not
  -- strand the ones already there.
  perform pg_temp.set_auth(OWNER_ID);
  perform public.set_event_capacity_policy(v_closed_id, 'closed');
  select count(*) into v_count from public.event_waitlist where event_id = v_closed_id;
  if v_count <> 1 then raise exception 'FAIL: closing the policy dropped an existing waiter'; end if;

  update public.events set max_participants = 5 where id = v_closed_id;
  if public.promote_from_waitlist(v_closed_id) is distinct from A_ID then
    raise exception 'FAIL: a closed event stranded a waiter who was already queued';
  end if;

  -- ========================================================================
  -- An uncapped event has no seat to free
  -- ========================================================================
  v_uncapped_id := (public.create_event(
    p_creator_id => OWNER_ID,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين بلا حد',
    p_start_date => now() + interval '2 hours'
  )->>'id')::uuid;
  perform pg_temp.set_auth(B_ID);
  perform public.join_waitlist(v_uncapped_id, B_ID);
  perform pg_temp.set_auth(OWNER_ID);
  if public.promote_from_waitlist(v_uncapped_id) is not null then
    raise exception 'FAIL: promoted into an uncapped event';
  end if;

  -- A locked registration freezes the queue: the organizer's manual lock stays
  -- authoritative, and capacity_policy never touches it.
  update public.events
  set max_participants = 5, registration_locked = true
  where id = v_uncapped_id;
  if public.promote_from_waitlist(v_uncapped_id) is not null then
    raise exception 'FAIL: promoted while registration was locked';
  end if;

  update public.events set registration_locked = false where id = v_uncapped_id;
  if public.promote_from_waitlist(v_uncapped_id) is distinct from B_ID then
    raise exception 'FAIL: unlocking registration did not release the queue';
  end if;

  -- ========================================================================
  -- A weekly series carries the policy to every occurrence
  -- ========================================================================
  v_series_id := (public.create_event(
    p_creator_id => OWNER_ID,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين أسبوعي مقفل',
    p_start_date => now() + interval '2 hours',
    p_max_participants => 4,
    p_recurrence => 'weekly',
    p_capacity_policy => 'closed'
  )->>'id')::uuid;

  select template_id into v_template_id from public.events where id = v_series_id;
  select capacity_policy into v_text from public.event_templates where id = v_template_id;
  if v_text is distinct from 'closed' then
    raise exception 'FAIL: template policy was %, expected closed', v_text;
  end if;

  -- Editing the live session keeps the series in step, so next week's
  -- occurrence does not quietly revert.
  perform public.set_event_capacity_policy(v_series_id, 'waitlist');
  select capacity_policy into v_text from public.event_templates where id = v_template_id;
  if v_text is distinct from 'waitlist' then
    raise exception 'FAIL: template did not follow the event, still %', v_text;
  end if;

  raise notice 'ALL WAITLIST PROMOTION TESTS PASSED';
end;
$$;

rollback;
