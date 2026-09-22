-- Card payments schema: only the server writes money rows. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/moyasar_payments_schema_test.sql

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
  ('71000000-0000-0000-0000-000000000001', 'pay-owner@test.local'),
  ('71000000-0000-0000-0000-000000000002', 'pay-member@test.local'),
  ('71000000-0000-0000-0000-000000000003', 'pay-stranger@test.local');

insert into public.workspaces (id, name, owner_id)
values ('71000000-0000-0000-0000-0000000000a1', 'Pay WS',
        '71000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000002');

insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, price_per_person, published_at)
values ('71000000-0000-0000-0000-0000000000e1',
        '71000000-0000-0000-0000-000000000001',
        '71000000-0000-0000-0000-0000000000a1',
        'تمرين مدفوع', now() + interval '2 days', 600, 60, now());

-- Service role seeds one payment row (the only legitimate writer).
insert into public.payments (id, workspace_id, event_id, user_id, seat_count, amount)
values ('71000000-0000-0000-0000-0000000000f1',
        '71000000-0000-0000-0000-0000000000a1',
        '71000000-0000-0000-0000-0000000000e1',
        '71000000-0000-0000-0000-000000000002', 1, 6000);

do $$
declare
  v_count integer;
begin
  -- 1. Payer sees own row.
  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000002');
  set local role authenticated;
  select count(*) into v_count from public.payments;
  if v_count <> 1 then
    raise exception 'FAIL: payer should see exactly their payment, saw %', v_count;
  end if;

  -- 2. Payer cannot flip status.
  begin
    update public.payments set status = 'paid'
    where id = '71000000-0000-0000-0000-0000000000f1';
    get diagnostics v_count = row_count;
    if v_count > 0 then
      raise exception 'FAIL: authenticated updated a payment row';
    end if;
  exception
    when insufficient_privilege then null;  -- also acceptable
  end;

  -- 3. Payer cannot insert.
  begin
    insert into public.payments (workspace_id, event_id, user_id, seat_count, amount)
    values ('71000000-0000-0000-0000-0000000000a1',
            '71000000-0000-0000-0000-0000000000e1',
            '71000000-0000-0000-0000-000000000002', 1, 6000);
    raise exception 'FAIL: authenticated inserted a payment row';
  exception
    when insufficient_privilege then null;
  end;

  -- 4. Stranger sees nothing.
  reset role;
  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000003');
  set local role authenticated;
  select count(*) into v_count from public.payments;
  if v_count <> 0 then
    raise exception 'FAIL: stranger saw % payments', v_count;
  end if;

  -- 5. Owner sees the workspace's rows.
  reset role;
  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000001');
  set local role authenticated;
  select count(*) into v_count from public.payments;
  if v_count <> 1 then
    raise exception 'FAIL: owner should see 1 payment, saw %', v_count;
  end if;

  -- 6. Owner cannot self-verify a recipient.
  begin
    insert into public.workspace_moyasar_recipients
      (workspace_id, moyasar_recipient_id, recipient_type, status)
    values ('71000000-0000-0000-0000-0000000000a1', 'x', 'Beneficiary', 'verified');
    raise exception 'FAIL: owner inserted a recipient row';
  exception
    when insufficient_privilege then null;
  end;

  -- 7. Webhook id is the dedupe key.
  reset role;
  insert into public.moyasar_webhook_events (id, type, raw)
  values ('wh_1', 'payment_paid', '{}'::jsonb);
  begin
    insert into public.moyasar_webhook_events (id, type, raw)
    values ('wh_1', 'payment_paid', '{}'::jsonb);
    raise exception 'FAIL: duplicate webhook id was accepted';
  exception
    when unique_violation then null;
  end;

  raise notice 'PASS: moyasar payments schema';
end;
$$;

rollback;
