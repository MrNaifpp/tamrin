-- MyFatoorah payments: a payment confirms exactly the seats it was priced for,
-- and nothing the app says can confirm a seat. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/myfatoorah_payments_test.sql

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
  ('82000000-0000-0000-0000-000000000001', 'mf-owner@test.local'),
  ('82000000-0000-0000-0000-000000000002', 'mf-payer@test.local');

insert into public.workspaces (id, name, owner_id)
values ('82000000-0000-0000-0000-0000000000a1', 'MF WS',
        '82000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('82000000-0000-0000-0000-0000000000a1', '82000000-0000-0000-0000-000000000001'),
  ('82000000-0000-0000-0000-0000000000a1', '82000000-0000-0000-0000-000000000002');

-- 600 SAR over 10 seats: 60 SAR (6000 halalas) a seat.
insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, max_participants, published_at)
values ('82000000-0000-0000-0000-0000000000e1',
        '82000000-0000-0000-0000-000000000001',
        '82000000-0000-0000-0000-0000000000a1',
        'تمرين ماي فاتورة', now() + interval '2 days', 600, 10, now());

create or replace function pg_temp.seed_owed() returns void
language plpgsql as $$
begin
  delete from public.refunds;
  delete from public.payments;
  delete from public.event_participants
   where event_id = '82000000-0000-0000-0000-0000000000e1';
  delete from public.push_outbox;
  insert into public.event_participants (id, event_id, user_id, payment_status)
  values ('82000000-0000-0000-0000-0000000000c1',
          '82000000-0000-0000-0000-0000000000e1',
          '82000000-0000-0000-0000-000000000002', 'pending');
  insert into public.event_participants (id, event_id, user_id, added_by, guest_name, payment_status)
  values ('82000000-0000-0000-0000-0000000000c2',
          '82000000-0000-0000-0000-0000000000e1', null,
          '82000000-0000-0000-0000-000000000002', 'ضيف', 'pending');
end;
$$;

create or replace function pg_temp.quote() returns json
language sql as $$
  select public.begin_card_payment('82000000-0000-0000-0000-0000000000e1',
                                   '82000000-0000-0000-0000-000000000002');
$$;

do $$
declare
  v json;
  v_pay uuid;
  v_pay2 uuid;
  v_n int;
  v_amount int;
  v_status text;
begin
  -- 1. quote records covered seats
  perform pg_temp.seed_owed();
  v := pg_temp.quote();
  if v ->> 'status' <> 'ready' or (v ->> 'amount')::int <> 12000
     or (v ->> 'seat_count')::int <> 2 then
    raise exception 'FAIL 1: expected ready 12000/2, got %', v;
  end if;
  if v::jsonb ? 'recipient_id' or v::jsonb ? 'given_id' then
    raise exception 'FAIL 1: quote still carries Moyasar fields: %', v;
  end if;
  v_pay := (v ->> 'payment_id')::uuid;
  select count(*) into v_n from public.payment_seats
   where payment_id = v_pay and price = 6000;
  if v_n <> 2 then raise exception 'FAIL 1: expected 2 payment_seats at 6000, got %', v_n; end if;
  raise notice 'PASS 1 quote records covered seats';

  -- 2. settle paid confirms only covered seats
  insert into public.event_participants (id, event_id, user_id, added_by, guest_name, payment_status)
  values ('82000000-0000-0000-0000-0000000000c3',
          '82000000-0000-0000-0000-0000000000e1', null,
          '82000000-0000-0000-0000-000000000002', 'ضيف متأخر', 'pending');
  v := public.settle_payment(v_pay, 'mf-1', 'paid', 'applepay', 12000, 'SAR');
  if v ->> 'status' <> 'settled' or (v ->> 'seats')::int <> 2 then
    raise exception 'FAIL 2: expected settled/2, got %', v;
  end if;
  select count(*) into v_n from public.event_participants
   where event_id = '82000000-0000-0000-0000-0000000000e1' and payment_status = 'confirmed';
  if v_n <> 2 then raise exception 'FAIL 2: expected 2 confirmed, got %', v_n; end if;
  select payment_status into v_status from public.event_participants
   where id = '82000000-0000-0000-0000-0000000000c3';
  if v_status <> 'pending' then raise exception 'FAIL 2: late guest should stay pending, got %', v_status; end if;
  select status into v_status from public.payments where id = v_pay;
  if v_status <> 'paid' then raise exception 'FAIL 2: payment should be paid, got %', v_status; end if;
  select count(*) into v_n from public.push_outbox
   where type = 'payment_paid' and user_id = '82000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'FAIL 2: expected one payment_paid push, got %', v_n; end if;
  raise notice 'PASS 2 settle confirms only covered seats';

  -- 2b. the late guest owes a payment of their own
  v := pg_temp.quote();
  if v ->> 'status' <> 'ready' or (v ->> 'amount')::int <> 6000 then
    raise exception 'FAIL 2b: late guest should owe 6000, got %', v;
  end if;
  raise notice 'PASS 2b late guest owes their own payment';

  -- 3. missing covered seat queues refund
  perform pg_temp.seed_owed();
  v_pay := (pg_temp.quote() ->> 'payment_id')::uuid;
  delete from public.event_participants where id = '82000000-0000-0000-0000-0000000000c2';
  v := public.settle_payment(v_pay, 'mf-3', 'paid', 'applepay', 12000, 'SAR');
  if v ->> 'status' <> 'settled' or v ->> 'refund_id' is null then
    raise exception 'FAIL 3: expected settled with refund_id, got %', v;
  end if;
  select count(*) into v_n from public.refunds
   where payment_id = v_pay and amount = 6000 and seats = 1 and reason = 'withdrew'
     and provider_payment_id = 'mf-3';
  if v_n <> 1 then raise exception 'FAIL 3: expected one 6000/1 withdrew refund, got %', v_n; end if;
  select payment_status into v_status from public.event_participants
   where id = '82000000-0000-0000-0000-0000000000c1';
  if v_status <> 'confirmed' then raise exception 'FAIL 3: member seat should be confirmed, got %', v_status; end if;
  raise notice 'PASS 3 missing covered seat queues refund';

  -- 4. amount mismatch fails
  perform pg_temp.seed_owed();
  v_pay := (pg_temp.quote() ->> 'payment_id')::uuid;
  v := public.settle_payment(v_pay, 'mf-4', 'paid', 'applepay', 11000, 'SAR');
  if v ->> 'status' <> 'amount_mismatch' then
    raise exception 'FAIL 4: expected amount_mismatch, got %', v;
  end if;
  select count(*) into v_n from public.event_participants
   where event_id = '82000000-0000-0000-0000-0000000000e1' and payment_status = 'confirmed';
  if v_n <> 0 then raise exception 'FAIL 4: nothing should be confirmed, got %', v_n; end if;
  raise notice 'PASS 4 amount mismatch fails';

  -- 5. processing then failed; failed after paid is already_settled
  perform pg_temp.seed_owed();
  v_pay := (pg_temp.quote() ->> 'payment_id')::uuid;
  v := public.settle_payment(v_pay, 'mf-5', 'processing', 'applepay', 12000, 'SAR');
  select status into v_status from public.payments where id = v_pay;
  if v ->> 'status' <> 'processing' or v_status <> 'processing' then
    raise exception 'FAIL 5: expected processing, got % / %', v, v_status;
  end if;
  v := public.settle_payment(v_pay, 'mf-5', 'failed', 'applepay', 12000, 'SAR');
  select status into v_status from public.payments where id = v_pay;
  if v_status <> 'failed' then raise exception 'FAIL 5: expected failed, got %', v_status; end if;
  -- a declined attempt can be paid again with a new Apple Pay token
  v := public.settle_payment(v_pay, 'mf-5b', 'paid', 'applepay', 12000, 'SAR');
  if v ->> 'status' <> 'settled' then raise exception 'FAIL 5: retry after decline should settle, got %', v; end if;
  v := public.settle_payment(v_pay, 'mf-5b', 'failed', 'applepay', 12000, 'SAR');
  if v ->> 'status' <> 'already_settled' then
    raise exception 'FAIL 5: failed after paid should be already_settled, got %', v;
  end if;
  raise notice 'PASS 5 processing, failed, retry, already_settled';

  -- 6. provider id cannot change once paid
  begin
    perform public.settle_payment(v_pay, 'mf-other', 'paid', 'applepay', 12000, 'SAR');
    raise exception 'FAIL 6: changing the provider id of a paid payment should raise';
  exception when others then
    if sqlerrm like 'FAIL 6%' then raise; end if;
  end;
  raise notice 'PASS 6 provider id cannot change';

  -- 7. stale quote is replaced
  perform pg_temp.seed_owed();
  v_pay := (pg_temp.quote() ->> 'payment_id')::uuid;
  v_pay2 := (pg_temp.quote() ->> 'payment_id')::uuid;
  if v_pay2 <> v_pay then raise exception 'FAIL 7: same owed seats should reuse the quote'; end if;
  delete from public.event_participants where id = '82000000-0000-0000-0000-0000000000c2';
  insert into public.event_participants (id, event_id, user_id, added_by, guest_name, payment_status)
  values ('82000000-0000-0000-0000-0000000000c4',
          '82000000-0000-0000-0000-0000000000e1', null,
          '82000000-0000-0000-0000-000000000002', 'ضيف آخر', 'pending');
  v := pg_temp.quote();
  v_pay2 := (v ->> 'payment_id')::uuid;
  if v_pay2 = v_pay then raise exception 'FAIL 7: a different seat set needs a new payment'; end if;
  select status into v_status from public.payments where id = v_pay;
  if v_status <> 'cancelled' then raise exception 'FAIL 7: old quote should be cancelled, got %', v_status; end if;
  select count(*) into v_n from public.payment_seats
   where payment_id = v_pay2 and participant_id = '82000000-0000-0000-0000-0000000000c4';
  if v_n <> 1 then raise exception 'FAIL 7: new quote should cover the new guest'; end if;
  raise notice 'PASS 7 stale quote is replaced';

  -- 8. Moyasar leftovers are gone
  if to_regclass('public.workspace_moyasar_recipients') is not null then
    raise exception 'FAIL 8: workspace_moyasar_recipients should be dropped';
  end if;
  if to_regclass('public.payment_webhook_events') is null then
    raise exception 'FAIL 8: payment_webhook_events missing';
  end if;
  raise notice 'PASS 8 schema renamed';
end;
$$;

-- 9. authenticated cannot write
set local role authenticated;
select pg_temp.set_auth('82000000-0000-0000-0000-000000000002');
do $$
begin
  begin
    insert into public.payments (workspace_id, event_id, user_id, seat_count, amount)
    values ('82000000-0000-0000-0000-0000000000a1', '82000000-0000-0000-0000-0000000000e1',
            '82000000-0000-0000-0000-000000000002', 1, 6000);
    raise exception 'FAIL 9: authenticated inserted a payment';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.payment_seats (payment_id, participant_id, price)
    values (gen_random_uuid(), gen_random_uuid(), 100);
    raise exception 'FAIL 9: authenticated inserted a payment seat';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.settle_payment(gen_random_uuid(), 'x', 'paid', 'applepay', 1, 'SAR');
    raise exception 'FAIL 9: authenticated called settle_payment';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 9 authenticated cannot write';
end;
$$;
reset role;

rollback;
