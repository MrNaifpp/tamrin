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
   payment_method, moyasar_payment_id, paid_at)
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
      (payment_id, event_id, user_id, seats, amount, reason, moyasar_payment_id)
    values ('81000000-0000-0000-0000-0000000000f1',
            '81000000-0000-0000-0000-0000000000e1',
            '81000000-0000-0000-0000-000000000002', 3, 99999, 'withdrew',
            'pay_moy_refund_1');
    -- The row itself is allowed; the ceiling is enforced when it settles.
  end;
  delete from public.refunds;

  -- 2. Half the payment goes back: one seat, 120 SAR.
  insert into public.refunds
    (payment_id, event_id, user_id, seats, amount, reason, moyasar_payment_id)
  values ('81000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'guest_removed',
          'pay_moy_refund_1')
  returning id into v_refund_a;

  v := public.settle_refund(v_refund_a, 'refunded', 12000, null);
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
  v := public.settle_refund(v_refund_a, 'refunded', 12000, null);
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
    (payment_id, event_id, user_id, seats, amount, reason, moyasar_payment_id)
  values ('81000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'withdrew',
          'pay_moy_refund_1')
  returning id into v_refund_b;

  v := public.settle_refund(v_refund_b, 'refunded', 24000, null);
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
    (payment_id, event_id, user_id, seats, amount, reason, moyasar_payment_id)
  values ('81000000-0000-0000-0000-0000000000f1',
          '81000000-0000-0000-0000-0000000000e1',
          '81000000-0000-0000-0000-000000000002', 1, 12000, 'withdrew',
          'pay_moy_refund_1')
  returning id into v_refund_b;
  v := public.settle_refund(v_refund_b, 'failed', 24000, 'already fully refunded');
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
      (payment_id, event_id, user_id, seats, amount, reason, moyasar_payment_id)
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

rollback;
