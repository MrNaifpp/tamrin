-- An unpaid ended workout blocks registering in the same workspace.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql

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

-- Owner, M (owes), S (clean; owes only on a cancelled workout), W (clean waiter),
-- X (holds the only seat of the promotion event).
insert into auth.users (id, email) values
  ('71000000-0000-0000-0000-000000000001', 'debt-owner@test.local'),
  ('71000000-0000-0000-0000-000000000002', 'debt-m@test.local'),
  ('71000000-0000-0000-0000-000000000003', 'debt-s@test.local'),
  ('71000000-0000-0000-0000-000000000004', 'debt-w@test.local'),
  ('71000000-0000-0000-0000-000000000005', 'debt-x@test.local');

insert into public.users (user_id, name) values
  ('71000000-0000-0000-0000-000000000001', 'منظم'),
  ('71000000-0000-0000-0000-000000000002', 'مدين'),
  ('71000000-0000-0000-0000-000000000003', 'سليم'),
  ('71000000-0000-0000-0000-000000000004', 'منتظر'),
  ('71000000-0000-0000-0000-000000000005', 'جالس');

insert into public.workspaces (id, name, owner_id) values
  ('71000000-0000-0000-0000-0000000000a1', 'Debt WS', '71000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-0000000000a2', 'Other WS', '71000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-0000000000a2', '71000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000002'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000003'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000004'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000005'),
  ('71000000-0000-0000-0000-0000000000a2', '71000000-0000-0000-0000-000000000002');

-- Every event starts in the future so the guard accepts the fixture rows,
-- then the old ones are moved into the past below.
--   b1 old paid workout M owes for (self + guest)
--   b2 old cancelled workout S "owes" for
--   b3 next workout in the same workspace (open)
--   b4 workout in the other workspace
--   b5 paid workout with one seat, used for promotion
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at,
   total_price, price_per_person, max_participants)
values
  ('71000000-0000-0000-0000-0000000000b1', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'Old', now() + interval '1 day',
   now() + interval '1 day 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b2', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'Old cancelled', now() + interval '1 day',
   now() + interval '1 day 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b3', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'Next', now() + interval '3 days',
   now() + interval '3 days 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b4', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a2', 'Elsewhere', now() + interval '3 days',
   now() + interval '3 days 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'One seat', now() + interval '3 days',
   now() + interval '3 days 2 hours', now(), 100, 50, 1);

insert into public.event_participants (event_id, user_id, payment_status) values
  ('71000000-0000-0000-0000-0000000000b1', '71000000-0000-0000-0000-000000000002', 'pending'),
  ('71000000-0000-0000-0000-0000000000b1', '71000000-0000-0000-0000-000000000001', 'pending'),
  ('71000000-0000-0000-0000-0000000000b2', '71000000-0000-0000-0000-000000000003', 'pending'),
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000005', 'confirmed');

insert into public.event_participants
  (event_id, user_id, added_by, guest_name, payment_status)
values ('71000000-0000-0000-0000-0000000000b1', null,
        '71000000-0000-0000-0000-000000000002', 'ضيف', 'pending');

-- M queued before W, both before M's debt exists.
insert into public.event_waitlist (event_id, user_id, joined_at) values
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000002', now() - interval '2 minutes'),
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000004', now() - interval '1 minute');

update public.events
set start_date = now() - interval '30 hours', end_date = now() - interval '28 hours'
where id = '71000000-0000-0000-0000-0000000000b1';

update public.events
set start_date = now() - interval '30 hours', end_date = now() - interval '28 hours',
    cancelled_at = now() - interval '31 hours'
where id = '71000000-0000-0000-0000-0000000000b2';

do $$
declare
  OWNER constant uuid := '71000000-0000-0000-0000-000000000001';
  M     constant uuid := '71000000-0000-0000-0000-000000000002';
  S     constant uuid := '71000000-0000-0000-0000-000000000003';
  WS    constant uuid := '71000000-0000-0000-0000-0000000000a1';
  OLD   constant uuid := '71000000-0000-0000-0000-0000000000b1';
  NEXT_ constant uuid := '71000000-0000-0000-0000-0000000000b3';
  ONE_SEAT constant uuid := '71000000-0000-0000-0000-0000000000b5';
  X     constant uuid := '71000000-0000-0000-0000-000000000005';
  W     constant uuid := '71000000-0000-0000-0000-000000000004';
  ELSEWHERE constant uuid := '71000000-0000-0000-0000-0000000000b4';
  v_result json;
  v_hint text;
  v_message text;
  v_blocked boolean;
begin
  -- The helper.
  if public.unpaid_debt_event(WS, M) is distinct from OLD then
    raise exception 'FAIL: helper did not name M''s unpaid workout';
  end if;
  if public.unpaid_debt_event(WS, S) is not null then
    raise exception 'FAIL: a cancelled workout counted as a debt';
  end if;
  if has_function_privilege('authenticated', 'public.unpaid_debt_event(uuid, uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.unpaid_debt_event(uuid, uuid)', 'EXECUTE') then
    raise exception 'FAIL: the helper is callable from the app';
  end if;

  -- Self-registration through the RPC the app uses.
  perform pg_temp.set_auth(M);
  v_blocked := false;
  begin
    v_result := public.register_event_seat(p_event_id => NEXT_);
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_message = message_text;
    v_blocked := v_hint = 'payment_owed:' || OLD::text
      and v_message = 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.';
  end;
  if not v_blocked then
    raise exception 'FAIL: register_event_seat was not refused (hint %, message %)', v_hint, v_message;
  end if;

  -- A guest row, and a waitlist row, hit the same trigger.
  v_blocked := false;
  begin
    insert into public.event_participants (event_id, user_id, added_by, guest_name, payment_status)
    values (NEXT_, null, M, 'ضيف جديد', 'pending');
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_blocked := v_hint = 'payment_owed:' || OLD::text;
  end;
  if not v_blocked then raise exception 'FAIL: adding a guest was not refused'; end if;

  v_blocked := false;
  begin
    insert into public.event_waitlist (event_id, user_id) values (NEXT_, M);
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_blocked := v_hint = 'payment_owed:' || OLD::text;
  end;
  if not v_blocked then raise exception 'FAIL: joining the waitlist was not refused'; end if;

  -- Another workspace is not affected.
  insert into public.event_participants (event_id, user_id, payment_status)
  values (ELSEWHERE, M, 'pending');

  -- A cancelled unpaid workout does not block.
  insert into public.event_participants (event_id, user_id, payment_status)
  values (NEXT_, S, 'pending');

  -- The owner is never blocked in their own workspace, even with an unpaid row,
  -- and a player they add is confirmed.
  insert into public.event_participants (event_id, user_id, payment_status)
  values (NEXT_, OWNER, 'confirmed');
  perform pg_temp.set_auth(OWNER);
  v_result := public.add_manual_participant(NEXT_, 'لاعب المنظم');
  if not exists (
    select 1 from public.event_participants
    where event_id = NEXT_ and guest_name = 'لاعب المنظم' and payment_status = 'confirmed'
  ) then
    raise exception 'FAIL: organizer-added player was not inserted confirmed: %', v_result;
  end if;

  -- A member with an unpaid guest-only batch can still register themselves
  -- (the old "Pending guest request" refusal is gone).
  insert into public.event_participants (event_id, user_id, added_by, guest_name, payment_status, guest_only)
  values ('71000000-0000-0000-0000-0000000000b5', null, S, 'ضيف فقط', 'pending', true);
  insert into public.event_waitlist (event_id, user_id)
  values ('71000000-0000-0000-0000-0000000000b5', S);
  delete from public.event_waitlist
  where event_id = '71000000-0000-0000-0000-0000000000b5' and user_id = S;
  delete from public.event_participants
  where event_id = '71000000-0000-0000-0000-0000000000b5' and added_by = S;

  -- The job no longer forgives: M's row is 30 hours past its start.
  perform public.generate_recurring_events();
  if (select payment_status from public.event_participants
      where event_id = OLD and user_id = M) <> 'pending' then
    raise exception 'FAIL: the job still waives unpaid seats';
  end if;

  -- A declared-but-unanswered seat still counts (the flow is retired).
  update public.event_participants set payment_declared_at = now()
  where event_id = OLD and user_id = M;
  if public.unpaid_debt_event(WS, M) is distinct from OLD then
    raise exception 'FAIL: a declared unpaid seat stopped counting';
  end if;

  -- The feed shows both the unpaid workout (flagged) and the next one.
  perform pg_temp.set_auth(M);
  if not exists (
    select 1 from json_array_elements(public.get_workspace_events(WS)) i
    where (i->>'id')::uuid = OLD and (i->>'requires_payment_action')::boolean
  ) then
    raise exception 'FAIL: the unpaid workout left the feed or lost its flag';
  end if;
  if not exists (
    select 1 from json_array_elements(public.get_workspace_events(WS)) i
    where (i->>'id')::uuid = NEXT_
  ) then
    raise exception 'FAIL: the next workout was hidden from a member who owes';
  end if;
  perform pg_temp.set_auth(OWNER);

  -- X frees the only seat. M is first in the queue but owes, so W gets it, and
  -- X's withdrawal does not fail because of M.
  perform pg_temp.set_auth(X);
  v_result := public.decline_event(ONE_SEAT, null, null);
  if not exists (select 1 from public.event_participants where event_id = ONE_SEAT and user_id = W) then
    raise exception 'FAIL: the seat did not go to the next clean waiter';
  end if;
  if exists (select 1 from public.event_participants where event_id = ONE_SEAT and user_id = M) then
    raise exception 'FAIL: a member who owes was promoted';
  end if;
  if not exists (select 1 from public.event_waitlist where event_id = ONE_SEAT and user_id = M) then
    raise exception 'FAIL: the skipped member lost their place in the queue';
  end if;
  if not exists (
    select 1 from public.push_outbox
    where event_id = ONE_SEAT and user_id = W and type = 'waitlist_promoted_unpaid'
  ) then
    raise exception 'FAIL: a paid promotion did not remind the member to pay';
  end if;
  perform pg_temp.set_auth(OWNER);

  -- Paying lifts the block at once: the organizer confirms (card settlement
  -- writes the same 'confirmed').
  perform public.confirm_payment(OLD, M, OWNER);
  perform pg_temp.set_auth(M);
  v_result := public.register_event_seat(p_event_id => NEXT_);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: a member who paid could not register: %', v_result;
  end if;
end;
$$;

select 'ALL UNPAID DEBT TESTS PASSED' as result;

rollback;
