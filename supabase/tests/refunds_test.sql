-- Refunds: money only ever goes back through settle_refund, and never more than
-- came in. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql

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
  ('81000000-0000-0000-0000-000000000001', 'refund-owner@test.local'),
  ('81000000-0000-0000-0000-000000000002', 'refund-payer@test.local'),
  ('81000000-0000-0000-0000-000000000003', 'refund-stranger@test.local');

insert into public.workspaces (id, name, owner_id)
values ('81000000-0000-0000-0000-0000000000a1', 'Refund WS',
        '81000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('81000000-0000-0000-0000-0000000000a1', '81000000-0000-0000-0000-000000000001'),
  ('81000000-0000-0000-0000-0000000000a1', '81000000-0000-0000-0000-000000000002');

insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, max_participants, published_at)
values ('81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000001',
        '81000000-0000-0000-0000-0000000000a1',
        'تمرين للاسترجاع', now() + interval '2 days', 1200, 10, now());

-- A paid card payment covering two seats at 120 SAR each.
insert into public.payments
  (id, workspace_id, event_id, user_id, seat_count, amount, status,
   payment_method, provider_payment_id, paid_at)
values ('81000000-0000-0000-0000-0000000000f1',
        '81000000-0000-0000-0000-0000000000a1',
        '81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000002', 2, 24000, 'paid',
        'applepay', 'pay_moy_refund_1', now());

insert into public.event_participants (event_id, user_id, payment_status, payment_id)
values ('81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000002', 'confirmed',
        '81000000-0000-0000-0000-0000000000f1');
insert into public.event_participants (event_id, user_id, added_by, guest_name,
                                       payment_status, payment_id)
values ('81000000-0000-0000-0000-0000000000e1', null,
        '81000000-0000-0000-0000-000000000002', 'ضيف',
        'confirmed', '81000000-0000-0000-0000-0000000000f1');

do $$
declare
  v json;
  v_refund_a uuid;
  v_refund_b uuid;
  v_amount int;
  v_seats int;
  v_status text;
  v_count int;
begin
  -- 1. A refund row cannot claim more than the payment took.
  begin
    insert into public.refunds
      (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
    values ('81000000-0000-0000-0000-0000000000f1',
            '81000000-0000-0000-0000-0000000000e1',
            '81000000-0000-0000-0000-000000000002', 3, 99999, 'withdrew',
            'pay_moy_refund_1');
    -- The row itself is allowed; the ceiling is enforced when it settles.
  end;
  delete from public.refunds;

  -- 2. Half the payment goes back: one seat, 120 SAR.
  insert into public.refunds
    (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
  values ('81000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'guest_removed',
          'pay_moy_refund_1')
  returning id into v_refund_a;

  v := public.settle_refund(v_refund_a, 'refunded', null, null);
  if v ->> 'status' <> 'settled' then
    raise exception 'FAIL: expected settled, got %', v;
  end if;

  select refunded_amount, refunded_seats, status
    into v_amount, v_seats, v_status
  from public.payments where id = '81000000-0000-0000-0000-0000000000f1';
  if v_amount <> 12000 or v_seats <> 1 then
    raise exception 'FAIL: expected 12000/1 refunded, got %/%', v_amount, v_seats;
  end if;
  if v_status <> 'paid' then
    raise exception 'FAIL: a half-refunded payment is still paid, got %', v_status;
  end if;

  -- 3. Settling the same refund twice moves nothing.
  v := public.settle_refund(v_refund_a, 'refunded', null, null);
  if v ->> 'status' <> 'already_settled' then
    raise exception 'FAIL: replay should say already_settled, got %', v;
  end if;
  select refunded_amount into v_amount
  from public.payments where id = '81000000-0000-0000-0000-0000000000f1';
  if v_amount <> 12000 then
    raise exception 'FAIL: replay changed the refunded total to %', v_amount;
  end if;

  -- 4. The rest goes back: the payment is now refunded in full.
  insert into public.refunds
    (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
  values ('81000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'withdrew',
          'pay_moy_refund_1')
  returning id into v_refund_b;

  v := public.settle_refund(v_refund_b, 'refunded', null, null);
  select refunded_amount, refunded_seats, status
    into v_amount, v_seats, v_status
  from public.payments where id = '81000000-0000-0000-0000-0000000000f1';
  if v_amount <> 24000 or v_seats <> 2 or v_status <> 'refunded' then
    raise exception 'FAIL: expected 24000/2/refunded, got %/%/%',
      v_amount, v_seats, v_status;
  end if;

  -- 5. A fully refunded payment releases the seats it was holding.
  select count(*) into v_count from public.event_participants
  where payment_id = '81000000-0000-0000-0000-0000000000f1'
    and payment_status = 'confirmed';
  if v_count <> 0 then
    raise exception 'FAIL: % seats still confirmed after a full refund', v_count;
  end if;

  -- 6. The payer is told.
  if not exists (select 1 from public.push_outbox
                 where type = 'refund_issued'
                   and user_id = '81000000-0000-0000-0000-000000000002') then
    raise exception 'FAIL: the payer was not queued a refund_issued push';
  end if;

  -- 7. A failed refund records the reason and moves no money.
  insert into public.refunds
    (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
  values ('81000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'withdrew',
          'pay_moy_refund_1')
  returning id into v_refund_b;
  v := public.settle_refund(v_refund_b, 'failed', null, 'already fully refunded');
  if v ->> 'status' <> 'failed' then
    raise exception 'FAIL: expected failed, got %', v;
  end if;
  select refunded_amount into v_amount
  from public.payments where id = '81000000-0000-0000-0000-0000000000f1';
  if v_amount <> 24000 then
    raise exception 'FAIL: a failed refund changed the total to %', v_amount;
  end if;

  raise notice 'PASS: refunds ledger';
end;
$$;

-- RLS, outside the definer function.
do $$
declare
  v_count integer;
begin
  perform pg_temp.set_auth('81000000-0000-0000-0000-000000000002');
  set local role authenticated;

  -- 8. The payer sees their own refunds.
  select count(*) into v_count from public.refunds;
  if v_count < 1 then
    raise exception 'FAIL: the payer should see their refunds, saw %', v_count;
  end if;

  -- 9. Nobody may write one.
  begin
    insert into public.refunds
      (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
    values ('81000000-0000-0000-0000-0000000000f1',
            '81000000-0000-0000-0000-0000000000e1',
            '81000000-0000-0000-0000-000000000002', 1, 100, 'withdrew', 'x');
    raise exception 'FAIL: authenticated inserted a refund row';
  exception
    when insufficient_privilege then null;
  end;

  -- 10. A stranger sees none.
  reset role;
  perform pg_temp.set_auth('81000000-0000-0000-0000-000000000003');
  set local role authenticated;
  select count(*) into v_count from public.refunds;
  if v_count <> 0 then
    raise exception 'FAIL: a stranger saw % refunds', v_count;
  end if;

  reset role;
  raise notice 'PASS: refunds rls';
end;
$$;

-- ============================================================
-- Section 3: request_refund is the only door, and it will not
-- open past what the payment actually took.
-- ============================================================
insert into public.payments
  (id, workspace_id, event_id, user_id, seat_count, amount, status,
   payment_method, provider_payment_id, paid_at)
values ('81000000-0000-0000-0000-0000000000f2',
        '81000000-0000-0000-0000-0000000000a1',
        '81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000002', 2, 24000, 'paid',
        'creditcard', 'pay_moy_refund_2', now());

insert into public.payments
  (id, workspace_id, event_id, user_id, seat_count, amount, status)
values ('81000000-0000-0000-0000-0000000000f3',
        '81000000-0000-0000-0000-0000000000a1',
        '81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000002', 1, 12000, 'pending');

do $$
declare
  v_id uuid;
  v_amount int;
  v json;
begin
  -- 1. An unpaid payment has nothing to give back.
  v_id := public.request_refund('81000000-0000-0000-0000-0000000000f3',
                                1, 12000, 'withdrew');
  if v_id is not null then
    raise exception 'FAIL: a pending payment produced a refund row';
  end if;

  -- 2. A normal partial request is written as asked.
  v_id := public.request_refund('81000000-0000-0000-0000-0000000000f2',
                                1, 12000, 'guest_removed');
  if v_id is null then raise exception 'FAIL: expected a refund row'; end if;
  select amount into v_amount from public.refunds where id = v_id;
  if v_amount <> 12000 then
    raise exception 'FAIL: expected 12000, got %', v_amount;
  end if;
  v := public.settle_refund(v_id, 'refunded', null, null);

  -- 3. Asking for more than remains is clamped to what remains.
  v_id := public.request_refund('81000000-0000-0000-0000-0000000000f2',
                                2, 99999, 'withdrew');
  select amount into v_amount from public.refunds where id = v_id;
  if v_amount <> 12000 then
    raise exception 'FAIL: expected the remaining 12000, got %', v_amount;
  end if;
  v := public.settle_refund(v_id, 'refunded', null, null);

  -- 4. Nothing remains, so nothing is written.
  v_id := public.request_refund('81000000-0000-0000-0000-0000000000f2',
                                1, 12000, 'withdrew');
  if v_id is not null then
    raise exception 'FAIL: a fully refunded payment produced another row';
  end if;

  raise notice 'PASS: request_refund guards';
end;
$$;

-- ============================================================
-- Section 5: withdrawing, removing a guest, and cancelling.
-- ============================================================
insert into auth.users (id, email) values
  ('82000000-0000-0000-0000-000000000002', 'trigger-payer@test.local');
insert into public.workspace_members (workspace_id, user_id) values
  ('81000000-0000-0000-0000-0000000000a1', '82000000-0000-0000-0000-000000000002');

-- Future workout, and one that has already kicked off but not finished.
insert into public.events (id, creator_id, workspace_id, name, start_date, end_date,
                           total_price, max_participants, published_at)
values ('82000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000001',
        '81000000-0000-0000-0000-0000000000a1',
        'تمرين قادم', now() + interval '2 days', now() + interval '2 days 2 hours',
        1200, 10, now()),
       ('82000000-0000-0000-0000-0000000000e2',
        '81000000-0000-0000-0000-000000000001',
        '81000000-0000-0000-0000-0000000000a1',
        'تمرين بدأ', now() - interval '20 minutes', now() + interval '40 minutes',
        1200, 10, now());

do $$
declare
  v json;
  v_participant uuid;
  v_refunds int;
  v_amount int;
  v_payment uuid;
begin
  -- ---------- removing one guest refunds exactly that seat ----------
  insert into public.payments
    (id, workspace_id, event_id, user_id, seat_count, amount, status,
     payment_method, provider_payment_id, paid_at)
  values ('82000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000a1',
          '82000000-0000-0000-0000-0000000000e1',
          '82000000-0000-0000-0000-000000000002', 2, 24000, 'paid',
          'applepay', 'pay_moy_trigger_1', now());
  insert into public.event_participants
    (event_id, user_id, payment_status, payment_id)
  values ('82000000-0000-0000-0000-0000000000e1',
          '82000000-0000-0000-0000-000000000002', 'confirmed',
          '82000000-0000-0000-0000-0000000000f1');
  insert into public.event_participants
    (event_id, user_id, added_by, guest_name, payment_status, payment_id)
  values ('82000000-0000-0000-0000-0000000000e1', null,
          '82000000-0000-0000-0000-000000000002', 'ضيف الإزالة',
          'confirmed', '82000000-0000-0000-0000-0000000000f1')
  returning id into v_participant;

  perform pg_temp.set_auth('82000000-0000-0000-0000-000000000002');
  v := public.remove_my_guest(v_participant);
  if v ->> 'status' <> 'removed' then
    raise exception 'FAIL: expected removed, got %', v;
  end if;
  select count(*), max(amount) into v_refunds, v_amount
  from public.refunds where payment_id = '82000000-0000-0000-0000-0000000000f1';
  if v_refunds <> 1 or v_amount <> 12000 then
    raise exception 'FAIL: expected one 12000 refund, got % of %', v_refunds, v_amount;
  end if;

  -- ---------- a guest that is not mine is refused ----------
  insert into public.event_participants
    (event_id, user_id, added_by, guest_name, payment_status)
  values ('82000000-0000-0000-0000-0000000000e1', null,
          '81000000-0000-0000-0000-000000000001', 'ضيف المنظّم', 'confirmed')
  returning id into v_participant;
  begin
    v := public.remove_my_guest(v_participant);
    raise exception 'FAIL: removed a guest the caller did not add';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- ---------- withdrawing before the start refunds the remainder ----------
  perform pg_temp.set_auth('82000000-0000-0000-0000-000000000002');
  v := public.decline_event('82000000-0000-0000-0000-0000000000e1', 'busy', null);
  if v ->> 'status' <> 'declined' then
    raise exception 'FAIL: expected declined, got %', v;
  end if;
  select coalesce(sum(amount), 0) into v_amount
  from public.refunds where payment_id = '82000000-0000-0000-0000-0000000000f1';
  if v_amount <> 24000 then
    raise exception 'FAIL: expected 24000 refunded in total, got %', v_amount;
  end if;

  -- ---------- withdrawing after the start refunds nothing ----------
  insert into public.payments
    (id, workspace_id, event_id, user_id, seat_count, amount, status,
     payment_method, provider_payment_id, paid_at)
  values ('82000000-0000-0000-0000-0000000000f2',
          '81000000-0000-0000-0000-0000000000a1',
          '82000000-0000-0000-0000-0000000000e2',
          '82000000-0000-0000-0000-000000000002', 1, 12000, 'paid',
          'applepay', 'pay_moy_trigger_2', now());
  insert into public.event_participants
    (event_id, user_id, payment_status, payment_id)
  values ('82000000-0000-0000-0000-0000000000e2',
          '82000000-0000-0000-0000-000000000002', 'confirmed',
          '82000000-0000-0000-0000-0000000000f2');

  perform pg_temp.set_auth('82000000-0000-0000-0000-000000000002');
  v := public.decline_event('82000000-0000-0000-0000-0000000000e2', 'busy', null);
  select count(*) into v_refunds
  from public.refunds where payment_id = '82000000-0000-0000-0000-0000000000f2';
  if v_refunds <> 0 then
    raise exception 'FAIL: a started workout refunded % times', v_refunds;
  end if;

  -- ---------- cancelling refunds every card payer in full ----------
  insert into public.payments
    (id, workspace_id, event_id, user_id, seat_count, amount, status,
     payment_method, provider_payment_id, paid_at)
  values ('82000000-0000-0000-0000-0000000000f3',
          '81000000-0000-0000-0000-0000000000a1',
          '82000000-0000-0000-0000-0000000000e2',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'paid',
          'creditcard', 'pay_moy_trigger_3', now());

  perform pg_temp.set_auth('81000000-0000-0000-0000-000000000001');
  v := public.cancel_event_occurrence('82000000-0000-0000-0000-0000000000e2',
                                      'weather', null);
  if v ->> 'status' <> 'cancelled' then
    raise exception 'FAIL: expected cancelled, got %', v;
  end if;
  select count(*), coalesce(sum(amount), 0) into v_refunds, v_amount
  from public.refunds where event_id = '82000000-0000-0000-0000-0000000000e2';
  if v_refunds <> 2 or v_amount <> 24000 then
    raise exception 'FAIL: cancelling produced % refunds worth %', v_refunds, v_amount;
  end if;

  raise notice 'PASS: refund trigger points';
end;
$$;

-- ============================================================
-- Section 6: the row fires itself, and an unconfigured stack stays green.
-- ============================================================
do $$
declare
  v_id uuid;
  v_count int;
begin
  -- 1. The trigger exists on the table.
  select count(*) into v_count from pg_trigger
  where tgrelid = 'public.refunds'::regclass
    and tgname = 'trg_fire_refund_outbox'
    and not tgisinternal;
  if v_count <> 1 then
    raise exception 'FAIL: the refunds outbox trigger is missing';
  end if;

  -- 2. With no vault entry the insert still succeeds, exactly as push does.
  --    A local stack and CI have no secrets, and neither may fail because of it.
  insert into public.payments
    (id, workspace_id, event_id, user_id, seat_count, amount, status,
     payment_method, provider_payment_id, paid_at)
  values ('83000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000a1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'paid',
          'applepay', 'pay_moy_fire_1', now());
  v_id := public.request_refund('83000000-0000-0000-0000-0000000000f1',
                                1, 12000, 'withdrew');
  if v_id is null then raise exception 'FAIL: expected a refund row'; end if;

  -- 3. The sweep is service_role's, never a client's.
  select count(*) into v_count
  from information_schema.role_routine_grants
  where routine_name = 'retry_pending_refunds' and grantee = 'authenticated';
  if v_count <> 0 then
    raise exception 'FAIL: authenticated can run the refund sweep';
  end if;

  raise notice 'PASS: refund outbox wiring';
end;
$$;

-- ============================================================
-- Section 7: MyFatoorah refunds can wait — for the provider, or for balance.
-- ============================================================
insert into auth.users (id, email) values
  ('84000000-0000-0000-0000-0000000000c1', 'ops@test.local');

insert into public.payments
  (id, workspace_id, event_id, user_id, seat_count, amount, status,
   payment_method, provider_payment_id, paid_at)
values ('84000000-0000-0000-0000-0000000000f1',
        '81000000-0000-0000-0000-0000000000a1',
        '81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000002', 2, 12000, 'paid',
        'applepay', 'mf_pay_7', now());

do $$
declare
  v json;
  v_id uuid;
  v_id2 uuid;
  v_status text;
  v_ref text;
  v_next timestamptz;
  v_amount int;
  v_count int;
begin
  delete from public.push_outbox;
  -- 1. pending keeps processing
  v_id := public.request_refund('84000000-0000-0000-0000-0000000000f1', 1, 6000, 'withdrew');
  v := public.settle_refund(v_id, 'pending', 'R1', null);
  select status, provider_refund_id into v_status, v_ref from public.refunds where id = v_id;
  select refunded_amount into v_amount from public.payments where id = '84000000-0000-0000-0000-0000000000f1';
  if v_status <> 'processing' or v_ref <> 'R1' or v_amount <> 0 then
    raise exception 'FAIL 7.1: expected processing/R1/0, got %/%/%', v_status, v_ref, v_amount;
  end if;
  -- …and refunded later still settles it
  v := public.settle_refund(v_id, 'refunded', 'R1', null);
  select status into v_status from public.refunds where id = v_id;
  select refunded_amount into v_amount from public.payments where id = '84000000-0000-0000-0000-0000000000f1';
  if v_status <> 'done' or v_amount <> 6000 then
    raise exception 'FAIL 7.1: expected done/6000 after refunded, got %/%', v_status, v_amount;
  end if;
  raise notice 'PASS 7.1 pending keeps processing';

  -- 2. waiting_balance schedules next day
  v_id2 := public.request_refund('84000000-0000-0000-0000-0000000000f1', 1, 6000, 'guest_removed');
  v := public.settle_refund(v_id2, 'waiting_balance', null, 'Insufficient balance');
  select status, next_attempt_at into v_status, v_next from public.refunds where id = v_id2;
  if v_status <> 'waiting_balance'
     or v_next < now() + interval '23 hours' or v_next > now() + interval '25 hours' then
    raise exception 'FAIL 7.2: expected waiting_balance tomorrow, got % at %', v_status, v_next;
  end if;
  raise notice 'PASS 7.2 waiting_balance schedules next day';

  -- 3. open refunds count toward the cap: 6000 refunded + 6000 waiting = nothing left
  if public.request_refund('84000000-0000-0000-0000-0000000000f1', 1, 12000, 'withdrew') is not null then
    raise exception 'FAIL 7.3: a refund was written although the waiting one covers the rest';
  end if;
  raise notice 'PASS 7.3 open refunds count toward the cap';

  -- 4. waiting_balance after 7 days fails and pushes ops
  perform vault.create_secret('84000000-0000-0000-0000-0000000000c1', 'ops_user_id');
  update public.refunds set created_at = now() - interval '8 days' where id = v_id2;
  v := public.settle_refund(v_id2, 'waiting_balance', null, 'Insufficient balance');
  select status into v_status from public.refunds where id = v_id2;
  select count(*) into v_count from public.push_outbox
   where type = 'refund_failed' and user_id = '84000000-0000-0000-0000-0000000000c1';
  if v_status <> 'failed' or v_count <> 1 then
    raise exception 'FAIL 7.4: expected failed + 1 ops push, got % / %', v_status, v_count;
  end if;
  raise notice 'PASS 7.4 waiting_balance after 7 days fails and pushes ops';

  -- 5. sweep picks due rows only
  delete from public.refunds;
  update public.payments set refunded_amount = 0, refunded_seats = 0
   where id = '84000000-0000-0000-0000-0000000000f1';
  insert into public.refunds (payment_id, event_id, user_id, seats, amount, reason,
                              provider_payment_id, status, created_at, updated_at, next_attempt_at)
  select '84000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000e1',
         '81000000-0000-0000-0000-000000000002', 1, 100, 'withdrew', 'mf_pay_7',
         s, c, u, n
  from (values
    ('pending',         now() - interval '10 minutes', now() - interval '10 minutes', null::timestamptz), -- due
    ('processing',      now() - interval '1 hour',     now() - interval '30 minutes', null),             -- due
    ('waiting_balance', now() - interval '1 day',      now() - interval '1 day',      now() - interval '1 minute'), -- due
    ('processing',      now(),                         now(),                         null),             -- fresh
    ('waiting_balance', now(),                         now(),                         now() + interval '1 day') -- not yet
  ) as t(s, c, u, n);
  v_count := public.retry_pending_refunds();
  if v_count <> 3 then raise exception 'FAIL 7.5: sweep should pick 3 rows, picked %', v_count; end if;
  raise notice 'PASS 7.5 sweep picks due rows only';

  -- 6. refunds of Moyasar-era payments are never sent to MyFatoorah
  update public.payments set provider = 'moyasar' where id = '84000000-0000-0000-0000-0000000000f1';
  v_count := public.retry_pending_refunds();
  if v_count <> 0 then raise exception 'FAIL 7.6: Moyasar refunds must be skipped, picked %', v_count; end if;
  update public.payments set provider = 'myfatoorah' where id = '84000000-0000-0000-0000-0000000000f1';
  raise notice 'PASS 7.6 Moyasar-era refunds are skipped';
end;
$$;

-- ============================================================
-- Section 8: duplicate-charge refunds and giving up on silence.
-- ============================================================
do $$
declare
  v json;
  v_id uuid;
  v_amount int;
  v_status text;
  v_count int;
begin
  delete from public.refunds;
  delete from public.push_outbox;
  update public.payments set refunded_amount = 0, refunded_seats = 0, status = 'paid'
   where id = '84000000-0000-0000-0000-0000000000f1';

  -- 1. a duplicate-charge refund settles without touching the real payment
  insert into public.refunds (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
  values ('84000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'duplicate_charge', 'mf_dup')
  returning id into v_id;
  -- …and it does not eat into what the real payment can still refund
  if public.request_refund('84000000-0000-0000-0000-0000000000f1', 1, 6000, 'withdrew') is null then
    raise exception 'FAIL 8.1: a duplicate-charge refund must not count against the cap';
  end if;
  v := public.settle_refund(v_id, 'refunded', 'RD', null);
  select refunded_amount, status into v_amount, v_status
    from public.payments where id = '84000000-0000-0000-0000-0000000000f1';
  if v_amount <> 0 or v_status <> 'paid' then
    raise exception 'FAIL 8.1: duplicate refund touched the payment: %/%', v_amount, v_status;
  end if;
  raise notice 'PASS 8.1 duplicate-charge refund is kept apart';

  -- 2. no answer for 3 hours: stop resending, fail it, tell ops
  delete from public.refunds;
  insert into public.refunds (payment_id, event_id, user_id, seats, amount, reason,
                              provider_payment_id, status, created_at)
  values ('84000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 100, 'withdrew', 'mf_pay_7',
          'processing', now() - interval '4 hours')
  returning id into v_id;
  v_count := public.retry_pending_refunds();
  select status into v_status from public.refunds where id = v_id;
  select count(*) into v_count from public.push_outbox where type = 'refund_failed';
  if v_status <> 'failed' or v_count <> 1 then
    raise exception 'FAIL 8.2: silent refund should fail with one ops push, got % / %', v_status, v_count;
  end if;
  raise notice 'PASS 8.2 silent refund gives up after 3 hours';
end;
$$;

rollback;
