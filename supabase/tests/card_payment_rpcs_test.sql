-- Card payment RPCs: the server prices the seat and confirms it only after
-- Moyasar agrees. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/card_payment_rpcs_test.sql

begin;

insert into auth.users (id, email) values
  ('72000000-0000-0000-0000-000000000001', 'rpc-owner@test.local'),
  ('72000000-0000-0000-0000-000000000002', 'rpc-member@test.local');

insert into public.workspaces (id, name, owner_id)
values ('72000000-0000-0000-0000-0000000000a1', 'RPC WS',
        '72000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('72000000-0000-0000-0000-0000000000a1', '72000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-0000000000a1', '72000000-0000-0000-0000-000000000002');

-- max_participants matters: trg_calculate_event_price_per_person derives
-- price_per_person from total_price / max_participants and zeroes it otherwise.
insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, max_participants, published_at)
values ('72000000-0000-0000-0000-0000000000e1',
        '72000000-0000-0000-0000-000000000001',
        '72000000-0000-0000-0000-0000000000a1',
        'تمرين بالبطاقة', now() + interval '2 days', 600, 10, now()),
       ('72000000-0000-0000-0000-0000000000e2',
        '72000000-0000-0000-0000-000000000001',
        '72000000-0000-0000-0000-0000000000a1',
        'تمرين مجاني', now() + interval '2 days', 0, 10, now());

-- Member owns one pending seat + one pending guest seat on e1.
insert into public.event_participants (event_id, user_id, payment_status)
values ('72000000-0000-0000-0000-0000000000e1',
        '72000000-0000-0000-0000-000000000002', 'pending');
insert into public.event_participants (event_id, user_id, added_by, guest_name, payment_status)
values ('72000000-0000-0000-0000-0000000000e1', null,
        '72000000-0000-0000-0000-000000000002', 'ضيف', 'pending');

do $$
declare
  v json;
  v_payment uuid;
  v_confirmed integer;
begin
  -- 1. No verified recipient yet -> the manual flow stays the only path.
  v := public.begin_card_payment('72000000-0000-0000-0000-0000000000e1',
                                 '72000000-0000-0000-0000-000000000002');
  if v ->> 'status' <> 'recipient_not_onboarded' then
    raise exception 'FAIL: expected recipient_not_onboarded, got %', v;
  end if;

  insert into public.workspace_moyasar_recipients
    (workspace_id, moyasar_recipient_id, recipient_type, status, verified_at)
  values ('72000000-0000-0000-0000-0000000000a1', 'rcp_test', 'Beneficiary',
          'verified', now());

  -- 2. Free event never reaches Moyasar.
  v := public.begin_card_payment('72000000-0000-0000-0000-0000000000e2',
                                 '72000000-0000-0000-0000-000000000002');
  if v ->> 'status' <> 'free_event' then
    raise exception 'FAIL: expected free_event, got %', v;
  end if;

  -- 3. Priced from the database: 2 seats x 60 SAR = 12000 halalas.
  v := public.begin_card_payment('72000000-0000-0000-0000-0000000000e1',
                                 '72000000-0000-0000-0000-000000000002');
  if v ->> 'status' <> 'ready' then
    raise exception 'FAIL: expected ready, got %', v;
  end if;
  if (v ->> 'amount')::int <> 12000 or (v ->> 'seat_count')::int <> 2 then
    raise exception 'FAIL: expected 12000 for 2 seats, got %', v;
  end if;
  if v ->> 'recipient_id' <> 'rcp_test' then
    raise exception 'FAIL: split recipient not carried, got %', v;
  end if;
  v_payment := (v ->> 'payment_id')::uuid;

  -- 4. Calling again reuses the pending row (no stacking).
  v := public.begin_card_payment('72000000-0000-0000-0000-0000000000e1',
                                 '72000000-0000-0000-0000-000000000002');
  if (v ->> 'payment_id')::uuid <> v_payment then
    raise exception 'FAIL: a second call created a second pending payment';
  end if;

  -- 5. settle_payment confirms both seats, once.
  v := public.settle_payment(v_payment, 'pay_moy_1', 'paid', 'creditcard', 12000, 'SAR');
  if v ->> 'status' <> 'settled' then
    raise exception 'FAIL: expected settled, got %', v;
  end if;
  select count(*) into v_confirmed from public.event_participants
  where event_id = '72000000-0000-0000-0000-0000000000e1'
    and payment_status = 'confirmed' and payment_id = v_payment;
  if v_confirmed <> 2 then
    raise exception 'FAIL: expected 2 confirmed seats, got %', v_confirmed;
  end if;
  if not exists (select 1 from public.push_outbox
                 where type = 'payment_paid'
                   and user_id = '72000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: organizer was not queued a payment_paid push';
  end if;

  -- 6. Idempotent: replay settles nothing new, reports already_settled.
  v := public.settle_payment(v_payment, 'pay_moy_1', 'paid', 'creditcard', 12000, 'SAR');
  if v ->> 'status' <> 'already_settled' then
    raise exception 'FAIL: replay should say already_settled, got %', v;
  end if;

  -- 7. Paying again is refused before Moyasar is ever contacted.
  v := public.begin_card_payment('72000000-0000-0000-0000-0000000000e1',
                                 '72000000-0000-0000-0000-000000000002');
  if v ->> 'status' <> 'already_paid' then
    raise exception 'FAIL: expected already_paid, got %', v;
  end if;

  -- 8. Refund releases the seats back to pending.
  v := public.settle_payment(v_payment, 'pay_moy_1', 'refunded', 'creditcard', 12000, 'SAR');
  select count(*) into v_confirmed from public.event_participants
  where payment_id = v_payment and payment_status = 'pending';
  if v_confirmed <> 2 then
    raise exception 'FAIL: refund should return 2 seats to pending, got %', v_confirmed;
  end if;

  -- 9. Amount mismatch is refused: nothing is confirmed.
  v := public.begin_card_payment('72000000-0000-0000-0000-0000000000e1',
                                 '72000000-0000-0000-0000-000000000002');
  v_payment := (v ->> 'payment_id')::uuid;
  v := public.settle_payment(v_payment, 'pay_moy_2', 'paid', 'creditcard', 100, 'SAR');
  if v ->> 'status' <> 'amount_mismatch' then
    raise exception 'FAIL: expected amount_mismatch, got %', v;
  end if;
  if exists (select 1 from public.event_participants
             where payment_id = v_payment and payment_status = 'confirmed') then
    raise exception 'FAIL: mismatched amount confirmed a seat';
  end if;

  raise notice 'PASS: card payment rpcs';
end;
$$;

rollback;
