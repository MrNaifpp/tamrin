# Moyasar Card + Apple Pay Payments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a member pay their seat (and their guests' seats) by card or Apple Pay through Moyasar, with the seat confirmed only after the server has verified and captured the payment.

**Architecture:** Money logic stays in Postgres RPCs (`begin_card_payment`, `settle_payment`) exactly like every other rule in this repo, so it is covered by the same `psql` test suites. Three thin Deno Edge Functions hold the Moyasar secret key and are the only writers to `payments`. The iOS app authorizes with the Moyasar SDK using `manual: true` and never decides an outcome — it asks `verify-payment` and renders what the server says.

**Tech Stack:** Supabase Postgres 17 (plpgsql, RLS), Supabase Edge Functions (Deno, `esm.sh/@supabase/supabase-js@2`), Moyasar REST API v1 (HTTP Basic, secret key as username), `moyasar/moyasar-ios-sdk` 3.2.3 via SPM, SwiftUI + PassKit, iOS 26 deployment target.

**Spec:** `docs/superpowers/specs/2026-09-06-moyasar-payments-design.md` — read it before Task 1.

## Global Constraints

- Secrets live only in Supabase secrets: `MOYASAR_SECRET_KEY`, `MOYASAR_PUBLISHABLE_KEY`, `MOYASAR_WEBHOOK_SECRET`. Never in Swift, `Config/*.xcconfig`, or git.
- Role `authenticated` gets **no** `insert`, `update` or `delete` on `public.payments`, `public.workspace_moyasar_recipients`, or `public.moyasar_webhook_events`. Writes come from `service_role` only.
- `settle_payment()` is the only code path that sets `payments.status = 'paid'` or flips an `event_participants` row to `confirmed` for a card payment.
- Amounts are integers in halalas (`amount >= 100`, Moyasar's minimum). Never computed on the device.
- Payment statuses: `pending`, `processing`, `paid`, `failed`, `cancelled`, `refunded`.
- Moyasar base URL `https://api.moyasar.com/v1`; auth header `Authorization: Basic base64(secret_key + ":")`.
- Moyasar payment statuses (from docs): `initiated`, `paid`, `authorized`, `failed`, `captured`, `refunded`, `voided`, `verified`.
- Webhook events used: `payment_paid`, `payment_captured`, `payment_faild` (Moyasar's spelling), `payment_voided`, `payment_refunded`. Never trust the body — re-fetch.
- Manual transfer flow is untouched. Card is offered only when `workspace_moyasar_recipients.status = 'verified'` for the event's workspace.
- Arabic UI copy, no em dashes in push copy (see `copy.ts` header).
- `project.pbxproj` changes (SPM dependency, Apple Pay capability) go in their **own commit**, called out in the PR. Never bundle them with source changes.
- No simulators. iOS tasks end with `xcodebuild … build` and a hand-over checklist for on-device testing.
- Local SQL tests: rebuild schema per `~/.claude/.../memory/local-supabase-db-workflow.md`, apply migrations in order skipping `*avatar_storage*`, then `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f <test>`. A pass ends with `ROLLBACK` and no `ERROR` line.
- Deno tests: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/<path>`.

---

## File map

**Create**
```
supabase/migrations/20260919100000_moyasar_payments.sql     tables, RLS, grants
supabase/migrations/20260919110000_card_payment_rpcs.sql    begin_card_payment, settle_payment
supabase/tests/moyasar_payments_schema_test.sql
supabase/tests/card_payment_rpcs_test.sql
supabase/functions/_shared/moyasar.ts                       REST client
supabase/functions/_shared/moyasar_test.ts
supabase/functions/_shared/payment_checks.ts                pure assertions
supabase/functions/_shared/payment_checks_test.ts
supabase/functions/_shared/cors.ts
supabase/functions/create-payment/index.ts
supabase/functions/create-payment/handler.ts
supabase/functions/create-payment/handler_test.ts
supabase/functions/verify-payment/index.ts
supabase/functions/verify-payment/handler.ts
supabase/functions/verify-payment/handler_test.ts
supabase/functions/moyasar-webhook/index.ts
supabase/functions/moyasar-webhook/handler.ts
supabase/functions/moyasar-webhook/handler_test.ts
supabase/functions/.env.example
Sirr/core/payment/MoyasarPaymentModels.swift
Sirr/core/payment/MoyasarPaymentService.swift
Sirr/Components/CardPaymentSheet.swift
Sirr/Components/ApplePayButton.swift
PAYMENT_SETUP.md
```

**Modify**
```
supabase/config.toml                              three [functions.*] blocks
supabase/functions/send-push/copy.ts              payment_paid copy
supabase/functions/send-push/copy_test.ts
Sirr/features/home/EventDetailView.swift          card button in the review step
Sirr/features/home/MockHomeFeed.swift             payWithCard(for:) view-model method
Sirr/Sirr.entitlements                            in-app-payments (Apple Pay) — own commit
Config/Base.xcconfig                              APPLE_PAY_MERCHANT_ID (empty)
Sirr.xcodeproj/project.pbxproj                    SPM + capability — own commit
```

---

### Task 1: Schema — tables, RLS, grants

**Files:**
- Create: `supabase/migrations/20260919100000_moyasar_payments.sql`
- Test: `supabase/tests/moyasar_payments_schema_test.sql`

**Interfaces:**
- Produces: tables `public.payments`, `public.workspace_moyasar_recipients`, `public.moyasar_webhook_events`; column `public.event_participants.payment_id uuid`.

- [ ] **Step 1: Write the failing test**

```sql
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
values ('71000000-0000-0000-0000-0000000000p1',
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
    where id = '71000000-0000-0000-0000-0000000000p1';
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/moyasar_payments_schema_test.sql`
Expected: `ERROR:  relation "public.payments" does not exist`

- [ ] **Step 3: Write the migration**

```sql
-- Moyasar card payments: the rows only the server may write.
--
-- payments is the money ledger. event_participants stays the seat. One payment
-- covers N seats (a member and their guests), so the seat points at the payment,
-- matching how payment_method_id already sits on the seat row.
--
-- authenticated gets select only. Every insert/update arrives through an Edge
-- Function holding service_role, and settle_payment() is the single place a
-- card-paid seat is confirmed. "The app cannot mark itself paid" is therefore a
-- grant, not a convention.

create table public.workspace_moyasar_recipients (
  workspace_id          uuid primary key references public.workspaces(id) on delete cascade,
  moyasar_recipient_id  text not null,
  recipient_type        text not null
                          check (recipient_type in ('Entity', 'Platform', 'Beneficiary')),
  status                text not null default 'pending'
                          check (status in ('pending', 'verified', 'disabled')),
  verified_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references public.workspaces(id) on delete cascade,
  event_id            uuid not null references public.events(id) on delete cascade,
  user_id             uuid not null references auth.users(id) on delete cascade,
  seat_count          int  not null check (seat_count > 0),
  amount              int  not null check (amount >= 100),
  currency            text not null default 'SAR',
  status              text not null default 'pending'
                        check (status in ('pending', 'processing', 'paid',
                                          'failed', 'cancelled', 'refunded')),
  payment_method      text check (payment_method in ('creditcard', 'applepay',
                                                     'stcpay', 'token')),
  moyasar_payment_id  text unique,
  given_id            uuid not null unique default gen_random_uuid(),
  split_recipient_id  text,
  platform_fee        int  not null default 0 check (platform_fee >= 0),
  failure_code        text,
  failure_message     text,
  last_moyasar_status text,
  authorized_at       timestamptz,
  paid_at             timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index idx_payments_event_user on public.payments(event_id, user_id);
create index idx_payments_pending
  on public.payments(created_at) where status = 'pending';

create table public.moyasar_webhook_events (
  id           text primary key,
  type         text not null,
  payment_id   uuid references public.payments(id) on delete set null,
  received_at  timestamptz not null default now(),
  raw          jsonb not null
);

alter table public.event_participants
  add column payment_id uuid references public.payments(id) on delete set null;

create index idx_event_participants_payment
  on public.event_participants(payment_id) where payment_id is not null;

-- updated_at upkeep
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger payments_touch before update on public.payments
  for each row execute function public.touch_updated_at();
create trigger recipients_touch before update on public.workspace_moyasar_recipients
  for each row execute function public.touch_updated_at();

-- RLS: read paths only.
alter table public.workspace_moyasar_recipients enable row level security;
alter table public.payments enable row level security;
alter table public.moyasar_webhook_events enable row level security;

create policy "Owners can see their Moyasar recipient"
  on public.workspace_moyasar_recipients for select
  using (exists (
    select 1 from public.workspaces w
    where w.id = workspace_id and w.owner_id = auth.uid()
  ));

create policy "Payers can see their payments"
  on public.payments for select
  using (user_id = auth.uid());

create policy "Owners can see their workspace's payments"
  on public.payments for select
  using (exists (
    select 1 from public.workspaces w
    where w.id = workspace_id and w.owner_id = auth.uid()
  ));

-- No policies on moyasar_webhook_events on purpose: clients never see it.

-- Grants: the default privileges in this project hand `all` to authenticated.
-- Take the write half back explicitly.
revoke insert, update, delete, truncate, references, trigger
  on public.workspace_moyasar_recipients from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.payments from anon, authenticated;
revoke all on public.moyasar_webhook_events from anon, authenticated;
grant select on public.workspace_moyasar_recipients to authenticated;
grant select on public.payments to authenticated;
```

- [ ] **Step 4: Apply and run the test**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260919100000_moyasar_payments.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/moyasar_payments_schema_test.sql`
Expected: `NOTICE:  PASS: moyasar payments schema` then `ROLLBACK`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260919100000_moyasar_payments.sql supabase/tests/moyasar_payments_schema_test.sql
git commit -m "feat(payments): ledger tables only the server may write"
```

---

### Task 2: `begin_card_payment` RPC — the server prices the seat

**Files:**
- Create: `supabase/migrations/20260919110000_card_payment_rpcs.sql` (first half)
- Test: `supabase/tests/card_payment_rpcs_test.sql`

**Interfaces:**
- Produces: `public.begin_card_payment(p_event_id uuid, p_user_id uuid) returns json` — service_role only. Returns one of:
  - `{"status":"ready","payment_id":uuid,"given_id":uuid,"amount":int,"currency":"SAR","seat_count":int,"recipient_id":text,"recipient_type":text,"platform_fee":0,"event_name":text}`
  - `{"status":"free_event"}` · `{"status":"nothing_due"}` · `{"status":"already_paid"}` · `{"status":"recipient_not_onboarded"}` · `{"status":"event_closed"}`
- Consumes: Task 1 tables.

- [ ] **Step 1: Write the failing test**

```sql
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

insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, price_per_person, published_at)
values ('72000000-0000-0000-0000-0000000000e1',
        '72000000-0000-0000-0000-000000000001',
        '72000000-0000-0000-0000-0000000000a1',
        'تمرين بالبطاقة', now() + interval '2 days', 600, 60, now()),
       ('72000000-0000-0000-0000-0000000000e2',
        '72000000-0000-0000-0000-000000000001',
        '72000000-0000-0000-0000-0000000000a1',
        'تمرين مجاني', now() + interval '2 days', 0, 0, now());

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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/card_payment_rpcs_test.sql`
Expected: `ERROR:  function public.begin_card_payment(uuid, uuid) does not exist`

- [ ] **Step 3: Write `begin_card_payment`**

```sql
-- Card payment RPCs. Both are service_role only: the Edge Functions call them
-- with the caller's identity already established from the JWT.
--
-- begin_card_payment prices the caller's owed seats from the database. The app
-- sends an event id and nothing financial. A pending row is reused so a retry
-- after a dropped connection cannot stack payments.

create or replace function public.begin_card_payment(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_recipient public.workspace_moyasar_recipients;
  v_seats int;
  v_amount int;
  v_payment public.payments;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.workspace_id is null then
    raise exception 'Event has no workspace';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, p_user_id) then
    raise exception 'Not a workspace member';
  end if;

  if v_event.cancelled_at is not null or v_event.published_at is null then
    return json_build_object('status', 'event_closed');
  end if;

  if v_event.total_price <= 0 then
    return json_build_object('status', 'free_event');
  end if;

  select * into v_recipient
  from public.workspace_moyasar_recipients
  where workspace_id = v_event.workspace_id and status = 'verified';
  if v_recipient.workspace_id is null then
    return json_build_object('status', 'recipient_not_onboarded');
  end if;

  if exists (
    select 1 from public.payments
    where event_id = p_event_id and user_id = p_user_id and status = 'paid'
  ) then
    return json_build_object('status', 'already_paid');
  end if;

  -- Seats this member still owes for: their own plus guests they added.
  select count(*),
         coalesce(round(sum(coalesce(ep.paid_price_per_person,
                                     v_event.price_per_person)) * 100), 0)::int
    into v_seats, v_amount
  from public.event_participants ep
  where ep.event_id = p_event_id
    and ep.payment_status = 'pending'
    and (ep.user_id = p_user_id
         or (ep.user_id is null and ep.added_by = p_user_id));

  if v_seats = 0 then
    return json_build_object('status', 'nothing_due');
  end if;

  -- Reuse a still-open attempt for the same seats.
  select * into v_payment
  from public.payments
  where event_id = p_event_id and user_id = p_user_id
    and status = 'pending' and seat_count = v_seats and amount = v_amount
  order by created_at desc limit 1;

  if v_payment.id is null then
    insert into public.payments
      (workspace_id, event_id, user_id, seat_count, amount,
       split_recipient_id, platform_fee)
    values
      (v_event.workspace_id, p_event_id, p_user_id, v_seats, v_amount,
       v_recipient.moyasar_recipient_id, 0)
    returning * into v_payment;
  end if;

  return json_build_object(
    'status', 'ready',
    'payment_id', v_payment.id,
    'given_id', v_payment.given_id,
    'amount', v_payment.amount,
    'currency', v_payment.currency,
    'seat_count', v_payment.seat_count,
    'recipient_id', v_recipient.moyasar_recipient_id,
    'recipient_type', v_recipient.recipient_type,
    'platform_fee', v_payment.platform_fee,
    'event_name', v_event.name
  );
end;
$$;

revoke execute on function public.begin_card_payment(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.begin_card_payment(uuid, uuid) to service_role;
```

- [ ] **Step 4: Apply and run the test — expect it to fail at `settle_payment`**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260919110000_card_payment_rpcs.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/card_payment_rpcs_test.sql`
Expected: `ERROR:  function public.settle_payment(uuid, unknown, unknown, unknown, integer, unknown) does not exist` (assertions 1–4 passed silently before it)

- [ ] **Step 5: Commit the half**

```bash
git add supabase/migrations/20260919110000_card_payment_rpcs.sql supabase/tests/card_payment_rpcs_test.sql
git commit -m "feat(payments): begin_card_payment prices the seat on the server"
```

---

### Task 3: `settle_payment` RPC — the only door to `paid`

**Files:**
- Modify: `supabase/migrations/20260919110000_card_payment_rpcs.sql` (append)
- Modify: `supabase/functions/send-push/copy.ts`, `supabase/functions/send-push/copy_test.ts`
- Test: `supabase/tests/card_payment_rpcs_test.sql` (already written)

**Interfaces:**
- Produces: `public.settle_payment(p_payment_id uuid, p_moyasar_payment_id text, p_moyasar_status text, p_payment_method text, p_amount int, p_currency text) returns json` — service_role only. Statuses: `settled`, `already_settled`, `amount_mismatch`, `failed`, `refunded`, `ignored`.
- The caller passes the status **as fetched from Moyasar with the secret key**, never from a webhook body.

- [ ] **Step 1: Append `settle_payment`**

```sql
-- settle_payment is the single place a card payment becomes paid and its seats
-- become confirmed. verify-payment and moyasar-webhook both end here, so
-- idempotency lives in one function. The Edge Function passes the status it
-- fetched from Moyasar itself; nothing here trusts a webhook body.

create or replace function public.settle_payment(
  p_payment_id uuid,
  p_moyasar_payment_id text,
  p_moyasar_status text,
  p_payment_method text,
  p_amount int,
  p_currency text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_event public.events;
  v_seats int;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if v_payment.id is null then raise exception 'Payment not found'; end if;

  -- Bind the Moyasar id on first contact; refuse a different one afterwards.
  if v_payment.moyasar_payment_id is null then
    update public.payments set moyasar_payment_id = p_moyasar_payment_id
    where id = p_payment_id;
    v_payment.moyasar_payment_id := p_moyasar_payment_id;
  elsif v_payment.moyasar_payment_id <> p_moyasar_payment_id then
    raise exception 'Moyasar payment id does not match this payment';
  end if;

  update public.payments
     set last_moyasar_status = p_moyasar_status,
         payment_method = coalesce(p_payment_method, payment_method)
   where id = p_payment_id;

  if p_moyasar_status in ('paid', 'captured') then
    if v_payment.status = 'paid' then
      return json_build_object('status', 'already_settled');
    end if;
    if p_amount <> v_payment.amount or p_currency <> v_payment.currency then
      update public.payments
         set status = 'failed',
             failure_code = 'amount_mismatch',
             failure_message = format('expected %s %s, moyasar reports %s %s',
                                      v_payment.amount, v_payment.currency,
                                      p_amount, p_currency)
       where id = p_payment_id;
      return json_build_object('status', 'amount_mismatch');
    end if;

    with mine as (
      update public.event_participants ep
         set payment_status = 'confirmed',
             payment_id = p_payment_id,
             payment_declared_at = coalesce(ep.payment_declared_at, now())
       where ep.event_id = v_payment.event_id
         and ep.payment_status = 'pending'
         and (ep.user_id = v_payment.user_id
              or (ep.user_id is null and ep.added_by = v_payment.user_id))
       returning 1
    )
    select count(*) into v_seats from mine;

    update public.payments
       set status = 'paid', paid_at = now()
     where id = p_payment_id;

    select * into v_event from public.events where id = v_payment.event_id;
    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, 'payment_paid', v_payment.event_id);

    return json_build_object('status', 'settled', 'seats', v_seats);
  end if;

  if p_moyasar_status = 'authorized' then
    update public.payments
       set status = 'processing', authorized_at = coalesce(authorized_at, now())
     where id = p_payment_id;
    return json_build_object('status', 'ignored');
  end if;

  if p_moyasar_status in ('failed', 'voided') then
    if v_payment.status = 'paid' then
      return json_build_object('status', 'already_settled');
    end if;
    update public.payments set status = 'failed' where id = p_payment_id;
    return json_build_object('status', 'failed');
  end if;

  if p_moyasar_status = 'refunded' then
    update public.payments set status = 'refunded' where id = p_payment_id;
    update public.event_participants
       set payment_status = 'pending'
     where payment_id = p_payment_id and payment_status = 'confirmed';
    return json_build_object('status', 'refunded');
  end if;

  return json_build_object('status', 'ignored');
end;
$$;

revoke execute on function public.settle_payment(uuid, text, text, text, int, text)
  from public, anon, authenticated;
grant execute on function public.settle_payment(uuid, text, text, text, int, text)
  to service_role;
```

- [ ] **Step 2: Re-apply and run the SQL test**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260919110000_card_payment_rpcs.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/card_payment_rpcs_test.sql`
Expected: `NOTICE:  PASS: card payment rpcs` then `ROLLBACK`

- [ ] **Step 3: Write the failing push-copy test**

Append to `supabase/functions/send-push/copy_test.ts`:

```ts
Deno.test("payment_paid copy interpolates the event name", () => {
  const c = copyFor("payment_paid", "تمرين كرة قدم");
  assertEquals(c, {
    title: "وصلت قطة بالبطاقة 💳",
    body: "لاعب دفع قطة تمرين كرة قدم بالبطاقة وتأكد مقعده تلقائيًا.",
  });
});
```

- [ ] **Step 4: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts`
Expected: FAIL — `payment_paid copy … Values are not equal` (copyFor returned `null`)

- [ ] **Step 5: Add the copy**

In `supabase/functions/send-push/copy.ts`, after the `payment_rejected` case:

```ts
    case "payment_paid":
      return {
        title: "وصلت قطة بالبطاقة 💳",
        body: `لاعب دفع قطة ${eventName} بالبطاقة وتأكد مقعده تلقائيًا.`,
      };
```

- [ ] **Step 6: Run to verify it passes**

Same command. Expected: all tests `ok`.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260919110000_card_payment_rpcs.sql supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(payments): settle_payment is the only door to paid"
```

---

### Task 4: Shared Moyasar client and pure payment checks

**Files:**
- Create: `supabase/functions/_shared/moyasar.ts`, `supabase/functions/_shared/moyasar_test.ts`
- Create: `supabase/functions/_shared/payment_checks.ts`, `supabase/functions/_shared/payment_checks_test.ts`
- Create: `supabase/functions/_shared/cors.ts`

**Interfaces:**
- Produces:
  ```ts
  // moyasar.ts
  export type MoyasarPayment = { id: string; status: string; amount: number; currency: string; source?: { type?: string }; metadata?: Record<string, unknown>; splits?: Array<{ recipient_id: string; amount: number }> | null };
  export function makeMoyasarClient(secretKey: string, fetchImpl?: typeof fetch, baseUrl?: string): { fetchPayment(id: string): Promise<MoyasarPayment>; capture(id: string): Promise<MoyasarPayment>; voidPayment(id: string): Promise<MoyasarPayment> };
  export function basicAuthHeader(secretKey: string): string;
  // payment_checks.ts
  export type Expected = { amount: number; currency: string; recipientId: string | null };
  export type CheckResult = { ok: true } | { ok: false; reason: "amount" | "currency" | "recipient" | "status" };
  export function checkAuthorized(p: MoyasarPayment, e: Expected): CheckResult;
  // cors.ts
  export const corsHeaders: Record<string, string>;
  export function json(body: unknown, status?: number): Response;
  ```

- [ ] **Step 1: Write the failing tests**

`supabase/functions/_shared/moyasar_test.ts`:
```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { basicAuthHeader, makeMoyasarClient } from "./moyasar.ts";

Deno.test("basic auth is the secret key as username with an empty password", () => {
  assertEquals(basicAuthHeader("sk_test_abc"), "Basic " + btoa("sk_test_abc:"));
});

Deno.test("fetchPayment hits /v1/payments/{id} with basic auth", async () => {
  let seen: { url: string; auth: string | null } | null = null;
  const fakeFetch: typeof fetch = async (input, init) => {
    seen = {
      url: String(input),
      auth: new Headers(init?.headers).get("authorization"),
    };
    return new Response(JSON.stringify({ id: "p1", status: "authorized", amount: 6000, currency: "SAR" }), { status: 200 });
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  const p = await c.fetchPayment("p1");
  assertEquals(p.status, "authorized");
  assertEquals(seen!.url, "https://api.moyasar.com/v1/payments/p1");
  assertEquals(seen!.auth, "Basic " + btoa("sk_test_abc:"));
});

Deno.test("capture posts to /capture and void posts to /void", async () => {
  const urls: string[] = [];
  const fakeFetch: typeof fetch = async (input, init) => {
    urls.push(`${init?.method} ${String(input)}`);
    return new Response(JSON.stringify({ id: "p1", status: "captured", amount: 6000, currency: "SAR" }), { status: 200 });
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  await c.capture("p1");
  await c.voidPayment("p1");
  assertEquals(urls, [
    "POST https://api.moyasar.com/v1/payments/p1/capture",
    "POST https://api.moyasar.com/v1/payments/p1/void",
  ]);
});
```

`supabase/functions/_shared/payment_checks_test.ts`:
```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { checkAuthorized } from "./payment_checks.ts";

const base = { id: "p1", status: "authorized", amount: 6000, currency: "SAR",
  splits: [{ recipient_id: "rcp_1", amount: 6000 }] };
const expected = { amount: 6000, currency: "SAR", recipientId: "rcp_1" };

Deno.test("matching authorized payment passes", () => {
  assertEquals(checkAuthorized(base, expected), { ok: true });
});
Deno.test("tampered amount is caught", () => {
  assertEquals(checkAuthorized({ ...base, amount: 100 }, expected), { ok: false, reason: "amount" });
});
Deno.test("wrong currency is caught", () => {
  assertEquals(checkAuthorized({ ...base, currency: "USD" }, expected), { ok: false, reason: "currency" });
});
Deno.test("redirected split recipient is caught", () => {
  assertEquals(
    checkAuthorized({ ...base, splits: [{ recipient_id: "rcp_evil", amount: 6000 }] }, expected),
    { ok: false, reason: "recipient" },
  );
});
Deno.test("no splits when a recipient is expected is caught", () => {
  assertEquals(checkAuthorized({ ...base, splits: null }, expected), { ok: false, reason: "recipient" });
});
Deno.test("already paid is accepted as well as authorized", () => {
  assertEquals(checkAuthorized({ ...base, status: "paid" }, expected), { ok: true });
});
Deno.test("failed status is not accepted", () => {
  assertEquals(checkAuthorized({ ...base, status: "failed" }, expected), { ok: false, reason: "status" });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/_shared/`
Expected: `error: Module not found "file:///app/supabase/functions/_shared/moyasar.ts"`

- [ ] **Step 3: Implement**

`supabase/functions/_shared/cors.ts`:
```ts
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
```

`supabase/functions/_shared/moyasar.ts`:
```ts
// Moyasar REST client. HTTP Basic: the secret key is the username, the
// password is empty (docs: `curl … -u sk_test_xxx:`). Only ever runs inside an
// Edge Function; the secret never reaches the app.
export type MoyasarPayment = {
  id: string;
  status: string;
  amount: number;
  currency: string;
  source?: { type?: string; message?: string };
  metadata?: Record<string, unknown>;
  splits?: Array<{ recipient_id: string; amount: number }> | null;
};

export function basicAuthHeader(secretKey: string): string {
  return "Basic " + btoa(`${secretKey}:`);
}

export class MoyasarError extends Error {
  constructor(public status: number, public body: string) {
    super(`Moyasar ${status}: ${body.slice(0, 300)}`);
  }
}

export function makeMoyasarClient(
  secretKey: string,
  fetchImpl: typeof fetch = fetch,
  baseUrl = "https://api.moyasar.com/v1",
) {
  const headers = { Authorization: basicAuthHeader(secretKey), "Content-Type": "application/json" };

  async function call(method: "GET" | "POST", path: string): Promise<MoyasarPayment> {
    const res = await fetchImpl(`${baseUrl}${path}`, { method, headers });
    const text = await res.text();
    if (!res.ok) throw new MoyasarError(res.status, text);
    return JSON.parse(text) as MoyasarPayment;
  }

  return {
    fetchPayment: (id: string) => call("GET", `/payments/${encodeURIComponent(id)}`),
    capture: (id: string) => call("POST", `/payments/${encodeURIComponent(id)}/capture`),
    voidPayment: (id: string) => call("POST", `/payments/${encodeURIComponent(id)}/void`),
  };
}
```

`supabase/functions/_shared/payment_checks.ts`:
```ts
// The gate between "the device says it paid" and "the seat is confirmed".
// Pure so it can be tested without a network.
import type { MoyasarPayment } from "./moyasar.ts";

export type Expected = { amount: number; currency: string; recipientId: string | null };
export type CheckResult = { ok: true } | { ok: false; reason: "amount" | "currency" | "recipient" | "status" };

const ACCEPTABLE = new Set(["authorized", "paid", "captured"]);

export function checkAuthorized(p: MoyasarPayment, e: Expected): CheckResult {
  if (!ACCEPTABLE.has(p.status)) return { ok: false, reason: "status" };
  if (p.amount !== e.amount) return { ok: false, reason: "amount" };
  if (p.currency !== e.currency) return { ok: false, reason: "currency" };
  if (e.recipientId !== null) {
    const splits = p.splits ?? [];
    const toRecipient = splits
      .filter((s) => s.recipient_id === e.recipientId)
      .reduce((sum, s) => sum + s.amount, 0);
    const toOthers = splits
      .filter((s) => s.recipient_id !== e.recipientId)
      .reduce((sum, s) => sum + s.amount, 0);
    if (toRecipient !== e.amount || toOthers !== 0) return { ok: false, reason: "recipient" };
  }
  return { ok: true };
}
```

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: 10 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/
git commit -m "feat(payments): moyasar client and the pure authorize gate"
```

---

### Task 5: `create-payment` Edge Function

**Files:**
- Create: `supabase/functions/create-payment/handler.ts`, `index.ts`, `handler_test.ts`
- Create: `supabase/functions/.env.example`
- Modify: `supabase/config.toml`

**Interfaces:**
- Consumes: `begin_card_payment` (Task 2) via service-role RPC.
- Produces: `POST /functions/v1/create-payment` body `{ "event_id": uuid }` → `200 { status:"ready", payment_id, given_id, amount, currency, seat_count, publishable_key, description, metadata:{payment_id, event_id, user_id}, splits:[{recipient_id, recipient_type, amount, fee_source:true, refundable:true}] }` or `200 { status: "<other begin status>" }`; `401` on bad JWT; `400` on missing `event_id`.
- Handler factory: `export function makeHandler(deps: CreateDeps): (req: Request) => Promise<Response>` with `type CreateDeps = { getUserId(authHeader: string | null): Promise<string | null>; rpc(name: "begin_card_payment", args: { p_event_id: string; p_user_id: string }): Promise<Record<string, unknown>>; publishableKey: string }`.

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const ready = {
  status: "ready", payment_id: "pay-uuid", given_id: "given-uuid", amount: 12000,
  currency: "SAR", seat_count: 2, recipient_id: "rcp_1", recipient_type: "Beneficiary",
  platform_fee: 0, event_name: "تمرين",
};

function deps(over: Partial<Parameters<typeof makeHandler>[0]> = {}) {
  const calls: unknown[] = [];
  return {
    calls,
    getUserId: async (auth: string | null) => (auth === "Bearer good" ? "user-1" : null),
    rpc: async (_name: string, args: unknown) => { calls.push(args); return ready; },
    publishableKey: "pk_test_x",
    ...over,
  };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/create-payment", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("rejects a missing or bad JWT", async () => {
  const res = await makeHandler(deps())(post({ event_id: "e1" }, "Bearer bad"));
  assertEquals(res.status, 401);
});

Deno.test("requires event_id", async () => {
  const res = await makeHandler(deps())(post({}));
  assertEquals(res.status, 400);
});

Deno.test("ignores any amount the client sends and uses the caller from the JWT", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ event_id: "e1", amount: 1, user_id: "someone-else" }));
  const body = await res.json();
  assertEquals(d.calls, [{ p_event_id: "e1", p_user_id: "user-1" }]);
  assertEquals(body.amount, 12000);
});

Deno.test("returns the publishable key and a server-built splits array", async () => {
  const res = await makeHandler(deps())(post({ event_id: "e1" }));
  const body = await res.json();
  assertEquals(body.publishable_key, "pk_test_x");
  assertEquals(body.splits, [{ recipient_id: "rcp_1", recipient_type: "Beneficiary", amount: 12000, fee_source: true, refundable: true }]);
  assertEquals(body.metadata, { payment_id: "pay-uuid", event_id: "e1", user_id: "user-1" });
});

Deno.test("passes a non-ready status through without a key", async () => {
  const d = deps({ rpc: async () => ({ status: "recipient_not_onboarded" }) });
  const res = await makeHandler(d)(post({ event_id: "e1" }));
  const body = await res.json();
  assertEquals(body, { status: "recipient_not_onboarded" });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/create-payment/`
Expected: `Module not found … handler.ts`

- [ ] **Step 3: Implement the handler and entrypoint**

`supabase/functions/create-payment/handler.ts`:
```ts
// Prices the caller's seats and hands the app what the Moyasar SDK needs.
// The body carries an event id and nothing else that matters: the price, the
// seat count, the recipient and the idempotency key all come from the database.
import { corsHeaders, json } from "../_shared/cors.ts";

export type CreateDeps = {
  getUserId(authHeader: string | null): Promise<string | null>;
  rpc(name: "begin_card_payment", args: { p_event_id: string; p_user_id: string }): Promise<Record<string, unknown>>;
  publishableKey: string;
};

export function makeHandler(deps: CreateDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const eventId = typeof body?.event_id === "string" ? body.event_id : null;
    if (!eventId) return json({ error: "event_id required" }, 400);

    const r = await deps.rpc("begin_card_payment", { p_event_id: eventId, p_user_id: userId });
    if (r.status !== "ready") return json({ status: r.status });

    const amount = r.amount as number;
    return json({
      status: "ready",
      payment_id: r.payment_id,
      given_id: r.given_id,
      amount,
      currency: r.currency,
      seat_count: r.seat_count,
      publishable_key: deps.publishableKey,
      description: `تمرين: ${r.event_name}`,
      metadata: { payment_id: r.payment_id, event_id: eventId, user_id: userId },
      splits: [{
        recipient_id: r.recipient_id,
        recipient_type: r.recipient_type,
        amount,
        fee_source: true,
        refundable: true,
      }],
    });
  };
}
```

`supabase/functions/create-payment/index.ts`:
```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeHandler } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  publishableKey: Deno.env.get("MOYASAR_PUBLISHABLE_KEY")!,
  async getUserId(auth) {
    if (!auth) return null;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data } = await asUser.auth.getUser();
    return data.user?.id ?? null;
  },
  async rpc(name, args) {
    const { data, error } = await admin.rpc(name, args);
    if (error) throw error;
    return data as Record<string, unknown>;
  },
}));
```

`supabase/functions/.env.example`:
```
# Moyasar — set with `supabase secrets set KEY=value`, never commit real values.
MOYASAR_SECRET_KEY=
MOYASAR_PUBLISHABLE_KEY=
MOYASAR_WEBHOOK_SECRET=
```

Append to `supabase/config.toml`:
```toml
[functions.create-payment]
verify_jwt = true

[functions.verify-payment]
verify_jwt = true

[functions.moyasar-webhook]
# Moyasar cannot present a Supabase JWT. The function checks the shared
# secret_token itself and re-fetches every payment from Moyasar before acting.
verify_jwt = false
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 5 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/create-payment supabase/functions/.env.example supabase/config.toml
git commit -m "feat(payments): create-payment prices the seat and hands the SDK its request"
```

---

### Task 6: `verify-payment` Edge Function — capture or void

**Files:**
- Create: `supabase/functions/verify-payment/handler.ts`, `index.ts`, `handler_test.ts`

**Interfaces:**
- Consumes: `makeMoyasarClient`, `checkAuthorized` (Task 4); `settle_payment` (Task 3).
- Produces: `POST /functions/v1/verify-payment` body `{ payment_id: uuid, moyasar_payment_id: string }` → `200 { status: "paid" | "failed" | "processing", reason?: string }`; `401`/`400`/`404`.
- Handler factory: `makeHandler(deps: VerifyDeps)` with `type VerifyDeps = { getUserId(auth: string | null): Promise<string | null>; loadPayment(id: string): Promise<{ id: string; user_id: string; amount: number; currency: string; split_recipient_id: string | null; status: string } | null>; moyasar: ReturnType<typeof makeMoyasarClient>; settle(args: { p_payment_id: string; p_moyasar_payment_id: string; p_moyasar_status: string; p_payment_method: string | null; p_amount: number; p_currency: string }): Promise<{ status: string }> }`.

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const row = { id: "pay-1", user_id: "user-1", amount: 6000, currency: "SAR", split_recipient_id: "rcp_1", status: "pending" };
const authorized = { id: "moy-1", status: "authorized", amount: 6000, currency: "SAR",
  source: { type: "creditcard" }, splits: [{ recipient_id: "rcp_1", amount: 6000 }] };

function deps(moyasarPayment = authorized) {
  const log: string[] = [];
  return {
    log,
    getUserId: async (a: string | null) => (a === "Bearer good" ? "user-1" : null),
    loadPayment: async (id: string) => (id === "pay-1" ? row : null),
    moyasar: {
      fetchPayment: async () => { log.push("fetch"); return moyasarPayment; },
      capture: async () => { log.push("capture"); return { ...moyasarPayment, status: "captured" }; },
      voidPayment: async () => { log.push("void"); return { ...moyasarPayment, status: "voided" }; },
    },
    settle: async (args: { p_moyasar_status: string }) => {
      log.push(`settle:${args.p_moyasar_status}`);
      return { status: args.p_moyasar_status === "captured" ? "settled" : "failed" };
    },
  };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/verify-payment", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("valid authorization is captured then settled", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals((await res.json()).status, "paid");
  assertEquals(d.log, ["fetch", "capture", "settle:captured"]);
});

Deno.test("tampered amount is voided, never captured", async () => {
  const d = deps({ ...authorized, amount: 100 });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  const body = await res.json();
  assertEquals(body, { status: "failed", reason: "amount" });
  assertEquals(d.log, ["fetch", "void", "settle:voided"]);
});

Deno.test("redirected recipient is voided", async () => {
  const d = deps({ ...authorized, splits: [{ recipient_id: "rcp_evil", amount: 6000 }] });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals((await res.json()).reason, "recipient");
  assertEquals(d.log.includes("capture"), false);
});

Deno.test("a payment that is not the caller's is 404", async () => {
  const d = deps();
  d.getUserId = async () => "someone-else";
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals(res.status, 404);
});

Deno.test("still initiated (3DS not finished) reports processing without capture", async () => {
  const d = deps({ ...authorized, status: "initiated" });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals((await res.json()).status, "processing");
  assertEquals(d.log, ["fetch"]);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/verify-payment/`
Expected: `Module not found … handler.ts`

- [ ] **Step 3: Implement**

`supabase/functions/verify-payment/handler.ts`:
```ts
// The device authorized; only this function may turn that into money moving.
// Fetch with the secret key, compare to what the database says is owed,
// capture on a match, void on anything else. A tampered amount therefore
// costs nothing to anyone: the hold is released, no refund is ever needed.
import { corsHeaders, json } from "../_shared/cors.ts";
import type { makeMoyasarClient } from "../_shared/moyasar.ts";
import { checkAuthorized } from "../_shared/payment_checks.ts";

export type PaymentRow = {
  id: string; user_id: string; amount: number; currency: string;
  split_recipient_id: string | null; status: string;
};

export type VerifyDeps = {
  getUserId(auth: string | null): Promise<string | null>;
  loadPayment(id: string): Promise<PaymentRow | null>;
  moyasar: ReturnType<typeof makeMoyasarClient>;
  settle(args: {
    p_payment_id: string; p_moyasar_payment_id: string; p_moyasar_status: string;
    p_payment_method: string | null; p_amount: number; p_currency: string;
  }): Promise<{ status: string }>;
};

export function makeHandler(deps: VerifyDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const paymentId = typeof body?.payment_id === "string" ? body.payment_id : null;
    const moyasarId = typeof body?.moyasar_payment_id === "string" ? body.moyasar_payment_id : null;
    if (!paymentId || !moyasarId) return json({ error: "payment_id and moyasar_payment_id required" }, 400);

    const row = await deps.loadPayment(paymentId);
    if (!row || row.user_id !== userId) return json({ error: "not found" }, 404);
    if (row.status === "paid") return json({ status: "paid" });

    const remote = await deps.moyasar.fetchPayment(moyasarId);
    const method = remote.source?.type ?? null;

    if (remote.status === "initiated") return json({ status: "processing" });

    const check = checkAuthorized(remote, {
      amount: row.amount, currency: row.currency, recipientId: row.split_recipient_id,
    });

    if (!check.ok) {
      if (remote.status === "authorized") {
        const voided = await deps.moyasar.voidPayment(moyasarId);
        await deps.settle({
          p_payment_id: row.id, p_moyasar_payment_id: moyasarId, p_moyasar_status: voided.status,
          p_payment_method: method, p_amount: remote.amount, p_currency: remote.currency,
        });
      } else {
        await deps.settle({
          p_payment_id: row.id, p_moyasar_payment_id: moyasarId, p_moyasar_status: remote.status,
          p_payment_method: method, p_amount: remote.amount, p_currency: remote.currency,
        });
      }
      return json({ status: "failed", reason: check.reason });
    }

    const final = remote.status === "authorized" ? await deps.moyasar.capture(moyasarId) : remote;
    const settled = await deps.settle({
      p_payment_id: row.id, p_moyasar_payment_id: moyasarId, p_moyasar_status: final.status,
      p_payment_method: method, p_amount: final.amount, p_currency: final.currency,
    });

    if (settled.status === "settled" || settled.status === "already_settled") return json({ status: "paid" });
    return json({ status: "failed", reason: settled.status });
  };
}
```

`supabase/functions/verify-payment/index.ts`:
```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler, type PaymentRow } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  moyasar: makeMoyasarClient(Deno.env.get("MOYASAR_SECRET_KEY")!),
  async getUserId(auth) {
    if (!auth) return null;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data } = await asUser.auth.getUser();
    return data.user?.id ?? null;
  },
  async loadPayment(id) {
    const { data } = await admin.from("payments")
      .select("id, user_id, amount, currency, split_recipient_id, status").eq("id", id).maybeSingle();
    return (data as PaymentRow | null) ?? null;
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 5 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/verify-payment
git commit -m "feat(payments): verify-payment captures on a match and voids on anything else"
```

---

### Task 7: `moyasar-webhook` Edge Function — idempotent, never trusting the body

**Files:**
- Create: `supabase/functions/moyasar-webhook/handler.ts`, `index.ts`, `handler_test.ts`

**Interfaces:**
- Consumes: `makeMoyasarClient`, `settle_payment`, `moyasar_webhook_events`.
- Produces: `POST /functions/v1/moyasar-webhook`; always `200` once recorded, `401` on bad secret, `400` on unparseable body.
- Handler factory: `makeHandler(deps: WebhookDeps)` with `type WebhookDeps = { webhookSecret: string; recordEvent(e: { id: string; type: string; raw: unknown }): Promise<"new" | "duplicate">; findPaymentByMetadata(paymentId: string): Promise<{ id: string; amount: number; currency: string } | null>; moyasar: ReturnType<typeof makeMoyasarClient>; settle(args: SettleArgs): Promise<{ status: string }>; linkEvent(webhookId: string, paymentId: string): Promise<void> }`.

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const remote = { id: "moy-1", status: "paid", amount: 6000, currency: "SAR",
  source: { type: "applepay" }, metadata: { payment_id: "pay-1" } };

function deps() {
  const seen = new Set<string>();
  const log: string[] = [];
  return {
    log,
    webhookSecret: "whsec",
    recordEvent: async (e: { id: string }) => { if (seen.has(e.id)) return "duplicate" as const; seen.add(e.id); return "new" as const; },
    findPaymentByMetadata: async (id: string) => (id === "pay-1" ? { id: "pay-1", amount: 6000, currency: "SAR" } : null),
    moyasar: {
      fetchPayment: async () => { log.push("fetch"); return remote; },
      capture: async () => remote, voidPayment: async () => remote,
    },
    settle: async (a: { p_moyasar_status: string }) => { log.push(`settle:${a.p_moyasar_status}`); return { status: "settled" }; },
    linkEvent: async () => { log.push("link"); },
  };
}

const post = (body: unknown) =>
  new Request("http://x/moyasar-webhook", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

const evt = (id: string, over: Record<string, unknown> = {}) => ({
  id, type: "payment_paid", secret_token: "whsec", live: false,
  data: { id: "moy-1", status: "paid", amount: 6000, metadata: { payment_id: "pay-1" } },
  ...over,
});

Deno.test("wrong secret is 401 and nothing is fetched", async () => {
  const d = deps();
  const res = await makeHandler(d)(post(evt("wh-1", { secret_token: "nope" })));
  assertEquals(res.status, 401);
  assertEquals(d.log, []);
});

Deno.test("a real event is re-fetched from Moyasar and settled", async () => {
  const d = deps();
  const res = await makeHandler(d)(post(evt("wh-1")));
  assertEquals(res.status, 200);
  assertEquals(d.log, ["fetch", "link", "settle:paid"]);
});

Deno.test("the body's status is ignored: a forged 'paid' settles whatever Moyasar really says", async () => {
  const d = deps();
  d.moyasar.fetchPayment = async () => { d.log.push("fetch"); return { ...remote, status: "failed" }; };
  await makeHandler(d)(post(evt("wh-2")));
  assertEquals(d.log, ["fetch", "link", "settle:failed"]);
});

Deno.test("a replayed delivery is acknowledged and settles nothing", async () => {
  const d = deps();
  await makeHandler(d)(post(evt("wh-3")));
  d.log.length = 0;
  const res = await makeHandler(d)(post(evt("wh-3")));
  assertEquals(res.status, 200);
  assertEquals(d.log, []);
});

Deno.test("unknown payment id is recorded and acknowledged, never creates a row", async () => {
  const d = deps();
  const res = await makeHandler(d)(post(evt("wh-4", { data: { id: "moy-9", metadata: { payment_id: "nope" } } })));
  assertEquals(res.status, 200);
  assertEquals(d.log.includes("settle:paid"), false);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/moyasar-webhook/`
Expected: `Module not found … handler.ts`

- [ ] **Step 3: Implement**

`supabase/functions/moyasar-webhook/handler.ts`:
```ts
// Moyasar tells us something changed. We do not believe what it says changed:
// the body's secret_token gets us past the door, the webhook id gets recorded
// (a replay hits the primary key), and then the payment is fetched again with
// the secret key. Whatever Moyasar answers is what settle_payment receives.
import { json } from "../_shared/cors.ts";
import type { makeMoyasarClient } from "../_shared/moyasar.ts";

export type SettleArgs = {
  p_payment_id: string; p_moyasar_payment_id: string; p_moyasar_status: string;
  p_payment_method: string | null; p_amount: number; p_currency: string;
};

export type WebhookDeps = {
  webhookSecret: string;
  recordEvent(e: { id: string; type: string; raw: unknown }): Promise<"new" | "duplicate">;
  findPaymentByMetadata(paymentId: string): Promise<{ id: string; amount: number; currency: string } | null>;
  moyasar: ReturnType<typeof makeMoyasarClient>;
  settle(args: SettleArgs): Promise<{ status: string }>;
  linkEvent(webhookId: string, paymentId: string): Promise<void>;
};

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function makeHandler(deps: WebhookDeps) {
  return async (req: Request): Promise<Response> => {
    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") return json({ error: "bad body" }, 400);

    const token = typeof body.secret_token === "string" ? body.secret_token : "";
    if (!constantTimeEqual(token, deps.webhookSecret)) return json({ error: "unauthorized" }, 401);

    const id = typeof body.id === "string" ? body.id : null;
    const type = typeof body.type === "string" ? body.type : "unknown";
    if (!id) return json({ error: "missing id" }, 400);

    if ((await deps.recordEvent({ id, type, raw: body })) === "duplicate") {
      return json({ status: "duplicate" });
    }

    const moyasarId = typeof body.data?.id === "string" ? body.data.id : null;
    if (!moyasarId) return json({ status: "ignored", reason: "no payment id" });

    // Re-fetch: this is the only status we act on.
    const remote = await deps.moyasar.fetchPayment(moyasarId);
    const paymentId = typeof remote.metadata?.payment_id === "string" ? remote.metadata.payment_id : null;
    const row = paymentId ? await deps.findPaymentByMetadata(paymentId) : null;
    if (!row) return json({ status: "ignored", reason: "unknown payment" });

    await deps.linkEvent(id, row.id);
    const result = await deps.settle({
      p_payment_id: row.id, p_moyasar_payment_id: remote.id, p_moyasar_status: remote.status,
      p_payment_method: remote.source?.type ?? null, p_amount: remote.amount, p_currency: remote.currency,
    });
    return json({ status: result.status });
  };
}
```

`supabase/functions/moyasar-webhook/index.ts`:
```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  webhookSecret: Deno.env.get("MOYASAR_WEBHOOK_SECRET")!,
  moyasar: makeMoyasarClient(Deno.env.get("MOYASAR_SECRET_KEY")!),
  async recordEvent(e) {
    const { error } = await admin.from("moyasar_webhook_events").insert({ id: e.id, type: e.type, raw: e.raw });
    if (!error) return "new";
    if (error.code === "23505") return "duplicate";
    throw error;
  },
  async findPaymentByMetadata(paymentId) {
    const { data } = await admin.from("payments").select("id, amount, currency").eq("id", paymentId).maybeSingle();
    return (data as { id: string; amount: number; currency: string } | null) ?? null;
  },
  async linkEvent(webhookId, paymentId) {
    await admin.from("moyasar_webhook_events").update({ payment_id: paymentId }).eq("id", webhookId);
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 5 tests `ok`.

- [ ] **Step 5: Deploy all three to the sandbox and set secrets (no values in the repo)**

```bash
supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_SECRET_KEY="$(read -rs 'k?sk_test: ' && echo "$k")"
supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_PUBLISHABLE_KEY="$(read -rs 'k?pk_test: ' && echo "$k")"
supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_WEBHOOK_SECRET="$(openssl rand -hex 32 | tee /dev/stderr)"
supabase functions deploy create-payment verify-payment moyasar-webhook --project-ref kpcdinxusxycenfnitjc
```
Copy the printed webhook secret into Moyasar Dashboard → Settings → Webhooks, URL `https://kpcdinxusxycenfnitjc.supabase.co/functions/v1/moyasar-webhook`.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/moyasar-webhook
git commit -m "feat(payments): webhook records, re-fetches, settles once"
```

---

### Task 8: Swift — SDK dependency, models, service

**Files:**
- Modify: `Sirr.xcodeproj/project.pbxproj` — **own commit**, via Xcode: File → Add Package Dependencies → `https://github.com/moyasar/moyasar-ios-sdk`, Exact Version `3.2.3`, product `MoyasarSdk` → target `Sirr`.
- Create: `Sirr/core/payment/MoyasarPaymentModels.swift`, `Sirr/core/payment/MoyasarPaymentService.swift`

**Interfaces:**
- Produces:
  ```swift
  struct CardPaymentQuote: Decodable { paymentId, givenId: UUID; amount: Int; currency: String; seatCount: Int; publishableKey, description: String; metadata: [String: String]; splits: [CardPaymentSplit] }
  enum CardPaymentStart { case ready(CardPaymentQuote), freeEvent, nothingDue, alreadyPaid, recipientNotOnboarded, eventClosed }
  enum CardPaymentVerification { case paid, processing, failed(reason: String?) }
  enum CardPaymentState: Equatable { case idle, processing, success, failed(String), cancelled }
  final class MoyasarPaymentService { static let shared; func startPayment(eventId: UUID) async throws -> CardPaymentStart; func verify(paymentId: UUID, moyasarPaymentId: String) async throws -> CardPaymentVerification }
  ```

- [ ] **Step 1: Add the package in Xcode and commit only the project file**

```bash
git add Sirr.xcodeproj/project.pbxproj
git commit -m "build: add MoyasarSdk 3.2.3 via SPM (project file only)"
```

- [ ] **Step 2: Write the models**

```swift
//
//  MoyasarPaymentModels.swift
//  Sirr
//
//  Wire shapes for the create-payment / verify-payment Edge Functions, and the
//  four states the card sheet can show. Nothing here decides an outcome — the
//  server does, and the sheet renders what it says.
//

import Foundation

struct CardPaymentSplit: Decodable, Equatable {
    let recipientId: String
    let recipientType: String?
    let amount: Int
    let feeSource: Bool
    let refundable: Bool

    enum CodingKeys: String, CodingKey {
        case recipientId = "recipient_id"
        case recipientType = "recipient_type"
        case amount
        case feeSource = "fee_source"
        case refundable
    }
}

struct CardPaymentQuote: Decodable, Equatable {
    let paymentId: UUID
    let givenId: UUID
    let amount: Int
    let currency: String
    let seatCount: Int
    let publishableKey: String
    let description: String
    let metadata: [String: String]
    let splits: [CardPaymentSplit]

    enum CodingKeys: String, CodingKey {
        case paymentId = "payment_id"
        case givenId = "given_id"
        case amount, currency
        case seatCount = "seat_count"
        case publishableKey = "publishable_key"
        case description, metadata, splits
    }

    /// Halalas → riyals for display only. Never sent anywhere.
    var amountInRiyals: Double { Double(amount) / 100 }
}

enum CardPaymentStart: Equatable {
    case ready(CardPaymentQuote)
    case freeEvent
    case nothingDue
    case alreadyPaid
    case recipientNotOnboarded
    case eventClosed
}

enum CardPaymentVerification: Equatable {
    case paid
    case processing
    case failed(reason: String?)
}

/// What the sheet shows. `processing` covers both "SDK is talking to Moyasar"
/// and "we are asking the server"; the person sees one spinner either way.
enum CardPaymentState: Equatable {
    case idle
    case processing
    case success
    case failed(String)
    case cancelled
}

enum MoyasarPaymentServiceError: Error, LocalizedError {
    case malformedResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse: "تعذر قراءة رد الخادم."
        case .http(401, _): "انتهت الجلسة. سجّل الدخول مرة أخرى."
        case .http: ServerErrorMessage.general
        }
    }
}
```

- [ ] **Step 3: Write the service**

```swift
//
//  MoyasarPaymentService.swift
//  Sirr
//
//  Typed client for the two card-payment Edge Functions. The app never talks
//  to Moyasar with anything but the publishable key the server hands back, and
//  never treats an SDK result as final — verify() is the word that counts.
//

import Foundation
import Supabase
import os

private let moyasarLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sirr",
    category: "MoyasarPaymentService"
)

final class MoyasarPaymentService {
    static let shared = MoyasarPaymentService()

    private let client = SupabaseClientManager.shared.client
    private let decoder = JSONDecoder()

    private init() {}

    private struct StartEnvelope: Decodable {
        let status: String
    }

    private struct VerifyEnvelope: Decodable {
        let status: String
        let reason: String?
    }

    func startPayment(eventId: UUID) async throws -> CardPaymentStart {
        let data = try await invoke(
            "create-payment",
            body: ["event_id": eventId.uuidString.lowercased()]
        )
        let envelope = try decoder.decode(StartEnvelope.self, from: data)
        moyasarLogger.info("create-payment -> \(envelope.status, privacy: .public)")
        switch envelope.status {
        case "ready": return .ready(try decoder.decode(CardPaymentQuote.self, from: data))
        case "free_event": return .freeEvent
        case "nothing_due": return .nothingDue
        case "already_paid": return .alreadyPaid
        case "recipient_not_onboarded": return .recipientNotOnboarded
        case "event_closed": return .eventClosed
        default: throw MoyasarPaymentServiceError.malformedResponse
        }
    }

    func verify(paymentId: UUID, moyasarPaymentId: String) async throws -> CardPaymentVerification {
        let data = try await invoke(
            "verify-payment",
            body: [
                "payment_id": paymentId.uuidString.lowercased(),
                "moyasar_payment_id": moyasarPaymentId
            ]
        )
        let envelope = try decoder.decode(VerifyEnvelope.self, from: data)
        moyasarLogger.info("verify-payment -> \(envelope.status, privacy: .public)")
        switch envelope.status {
        case "paid": return .paid
        case "processing": return .processing
        default: return .failed(reason: envelope.reason)
        }
    }

    private func invoke(_ name: String, body: [String: String]) async throws -> Data {
        do {
            return try await client.functions.invoke(
                name,
                options: FunctionInvokeOptions(body: body)
            ) { data, response in
                guard (200..<300).contains(response.statusCode) else {
                    throw MoyasarPaymentServiceError.http(
                        response.statusCode,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                }
                return data
            }
        } catch let error as MoyasarPaymentServiceError {
            throw error
        } catch let error as FunctionsError {
            if case let .httpError(code, data) = error {
                throw MoyasarPaymentServiceError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            throw error
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. If `functions.invoke` overload does not match supabase-swift 2.5.x, use `try await client.functions.invoke(name, options: FunctionInvokeOptions(body: body))` returning `Data` directly and check status inside `FunctionsError.httpError` only.

- [ ] **Step 5: Commit**

```bash
git add Sirr/core/payment/MoyasarPaymentModels.swift Sirr/core/payment/MoyasarPaymentService.swift
git commit -m "feat(payments): typed client for create-payment and verify-payment"
```

---

### Task 9: Swift — the card sheet and its wiring

**Files:**
- Create: `Sirr/Components/CardPaymentSheet.swift`
- Modify: `Sirr/features/home/MockHomeFeed.swift` (next to `declarePayment(for:method:)` ~line 2409)
- Modify: `Sirr/features/home/EventDetailView.swift` (review step, ~line 2585, and state)

**Interfaces:**
- Consumes: `MoyasarPaymentService`, `CardPaymentQuote`, `CardPaymentState` (Task 8); SDK `PaymentRequest`, `CreditCardView`, `PaymentSplit`, `MetadataValue`, `PaymentResult`.
- Produces: `struct CardPaymentSheet: View { init(eventId: UUID, eventName: String, onSettled: @escaping () -> Void) }`; `MockHomeFeed.markCardPaid(for occurrence: FeedOccurrence) async`.

- [ ] **Step 1: Write the sheet**

```swift
//
//  CardPaymentSheet.swift
//  Sirr
//
//  Card payment through Moyasar. Asks the server for the quote, shows the
//  SDK's Arabic card form with manual (authorize-only) mode, then asks the
//  server to verify. The SDK saying "paid" moves us to a spinner, not to a
//  tick: only verify-payment ends in success.
//

import SwiftUI
import MoyasarSdk

struct CardPaymentSheet: View {
    let eventId: UUID
    let eventName: String
    let onSettled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quote: CardPaymentQuote?
    @State private var request: PaymentRequest?
    @State private var state: CardPaymentState = .idle
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                switch state {
                case .idle:
                    if let request, let quote {
                        amountCard(quote)
                        CreditCardView(request: request) { result in
                            handle(result, quote: quote)
                        }
                        .padding(.horizontal, 16)
                    } else if let loadError {
                        statusView(icon: "exclamationmark.triangle", title: loadError, tint: .orange)
                    } else {
                        ProgressView().tint(.white).padding(.top, 60)
                    }
                case .processing:
                    statusView(icon: "hourglass", title: "نتحقق من الدفع…", tint: .white, spinning: true)
                case .success:
                    statusView(icon: "checkmark.circle.fill", title: "تم الدفع وتأكد مقعدك", tint: .green)
                case .failed(let message):
                    statusView(icon: "xmark.circle.fill", title: message, tint: .red)
                    retryButton
                case .cancelled:
                    statusView(icon: "arrow.uturn.backward.circle", title: "ألغيت عملية الدفع", tint: .white.opacity(0.7))
                    retryButton
                }
                Spacer()
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(state == .processing)
    }

    private var header: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(state == .processing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func amountCard(_ quote: CardPaymentQuote) -> some View {
        VStack(spacing: 4) {
            Text("الدفع بالبطاقة")
                .font(TamrinFont.font(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(eventName)
                .font(TamrinFont.font(size: 15))
                .foregroundStyle(Color(white: 0.7))
            Text(quote.amountInRiyals.formatted(.number.precision(.fractionLength(0...2))) + " ريال")
                .font(TamrinFont.font(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 8)
            if quote.seatCount > 1 {
                Text("لعدد \(quote.seatCount.counted(.player))")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .padding(.vertical, 20)
    }

    private func statusView(icon: String, title: String, tint: Color, spinning: Bool = false) -> some View {
        VStack(spacing: 14) {
            if spinning {
                ProgressView().tint(tint).scaleEffect(1.4)
            } else {
                Image(systemName: icon).font(.system(size: 44)).foregroundStyle(tint)
            }
            Text(title)
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    private var retryButton: some View {
        Button {
            state = .idle
            Task { await load() }
        } label: {
            Text("حاول مرة أخرى")
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.white, in: .rect(cornerRadius: 17, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func load() async {
        loadError = nil
        do {
            switch try await MoyasarPaymentService.shared.startPayment(eventId: eventId) {
            case .ready(let q):
                quote = q
                request = try PaymentRequest(
                    apiKey: q.publishableKey,
                    amount: q.amount,
                    currency: q.currency,
                    description: q.description,
                    metadata: q.metadata.mapValues { MetadataValue.stringValue($0) },
                    manual: true,
                    givenID: q.givenId.uuidString.lowercased(),
                    allowedNetworks: [.mada, .visa, .mastercard],
                    payButtonType: .pay,
                    splits: q.splits.map {
                        PaymentSplit(
                            recipientId: $0.recipientId,
                            amount: $0.amount,
                            recipientType: $0.recipientType,
                            feeSource: $0.feeSource,
                            refundable: $0.refundable
                        )
                    }
                )
            case .alreadyPaid:
                state = .success
            case .freeEvent, .nothingDue:
                loadError = "لا يوجد مبلغ مستحق على هذا الموعد."
            case .recipientNotOnboarded:
                loadError = "الدفع بالبطاقة غير متاح لهذه المجموعة بعد."
            case .eventClosed:
                loadError = "أُغلق التسجيل لهذا الموعد."
            }
        } catch {
            loadError = ServerErrorMessage.arabic(for: error)
        }
    }

    private func handle(_ result: PaymentResult, quote: CardPaymentQuote) {
        switch result {
        case .completed(let payment):
            // Authorized or paid on Moyasar's side — the server decides which
            // of those becomes a seat.
            state = .processing
            Task { await verify(moyasarPaymentId: payment.id, paymentId: quote.paymentId) }
        case .failed(let error):
            Haptics.error()
            state = .failed(error.localizedDescription.isEmpty
                            ? "لم تنجح عملية الدفع. تحقق من البطاقة وحاول مرة أخرى."
                            : error.localizedDescription)
        case .canceled:
            state = .cancelled
        }
    }

    private func verify(moyasarPaymentId: String, paymentId: UUID) async {
        do {
            for attempt in 0..<4 {
                switch try await MoyasarPaymentService.shared.verify(
                    paymentId: paymentId, moyasarPaymentId: moyasarPaymentId
                ) {
                case .paid:
                    Haptics.success()
                    state = .success
                    onSettled()
                    return
                case .processing:
                    try await Task.sleep(for: .seconds(1 + attempt))
                case .failed(let reason):
                    Haptics.error()
                    state = .failed(reason == "amount" || reason == "recipient"
                                    ? "تعذر التحقق من الدفع. لم يُخصم أي مبلغ."
                                    : "لم تنجح عملية الدفع.")
                    return
                }
            }
            state = .failed("تأخر التحقق من الدفع. سيتأكد مقعدك تلقائيًا عند وصول التأكيد.")
        } catch {
            state = .failed(ServerErrorMessage.arabic(for: error))
        }
    }
}
```

If `MetadataValue.stringValue` does not match the SDK's enum case name, open `Sdk/MoyasarSdk/Models/PaymentRequest.swift` in the checked-out package and use the actual case — do not guess a second time.

- [ ] **Step 2: Add the view-model hook in `MockHomeFeed.swift`, after `declarePayment(for:method:)`**

```swift
    /// A card payment was verified by the server. The seat is already
    /// confirmed in the database; this only brings the local roster and the
    /// shelf up to date, the same way a declared transfer does.
    func markCardPaid(for occurrence: FeedOccurrence) async {
        guard !isPreview else {
            setMyStatus(.confirmed, on: occurrence)
            resolvePaymentAction(for: occurrence.id)
            return
        }
        await reloadRoster(occurrence.id)
        resolvePaymentAction(for: occurrence.id)
        if let workspaceID = teamID(for: occurrence) {
            Task { await loadTeamData(workspaceID) }
        }
    }
```

If `setMyStatus(.confirmed, …)` is not an existing case, use whichever `MyStatus` case `reloadRoster` would produce for a confirmed seat — grep `setMyStatus(` for the name.

- [ ] **Step 3: Offer the card in `EventDetailView.swift`**

Add state near the other `@State` vars of the sheet:
```swift
    @State private var showCardPayment = false
    @State private var cardAvailable = false
```

In the `reviewOnly` branch, directly **above** the existing `primaryButton(title: "حوّلت المبلغ" …)`, add:
```swift
                    if cardAvailable, destination.status != .free {
                        Button {
                            showCardPayment = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "creditcard")
                                Text("ادفع بالبطاقة أو Apple Pay")
                                    .font(TamrinFont.font(size: 15, weight: .bold))
                                Spacer()
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.white, in: .rect(cornerRadius: 17, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    }
```

Attach to the sheet's root view (next to its existing `.sheet`/`.task` modifiers):
```swift
        .task(id: occurrence.id) {
            // Card is only offered when the server says the workspace can take
            // it. A workspace without a verified Moyasar recipient never sees
            // the button, and the manual flow is unchanged.
            if case .ready = try? await MoyasarPaymentService.shared.startPayment(eventId: occurrence.id) {
                cardAvailable = true
            }
        }
        .sheet(isPresented: $showCardPayment) {
            CardPaymentSheet(eventId: occurrence.id, eventName: occurrence.name) {
                Task {
                    await feed.markCardPaid(for: occurrence)
                    withAnimation { step = .success }
                }
            }
        }
```

`occurrence.name` — use the property the file already uses for the event title in this sheet (grep `Text(occurrence.` nearby).

- [ ] **Step 4: Build**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit and hand over for device testing**

```bash
git add Sirr/Components/CardPaymentSheet.swift Sirr/features/home/MockHomeFeed.swift Sirr/features/home/EventDetailView.swift
git commit -m "feat(payments): card sheet — authorize on device, settle on the server"
```

Hand-over checklist (sandbox, workspace with a `verified` recipient row inserted by hand):
1. `4111111111111111` → tick, seat `confirmed`, `payments.status = paid`, organizer push arrives.
2. `4123120000000000` → red state, seat stays `pending`, `payments.status = failed`.
3. Close the SDK form → cancelled state, retry works.
4. Airplane mode right after 3DS → "تأخر التحقق"; webhook settles within a minute; reopening shows confirmed.
5. Workspace with no recipient row → no card button at all.

---

### Task 10: Apple Pay — capability, merchant id plumbing, button

**Files:**
- Modify: `Sirr/Sirr.entitlements`, `Sirr.xcodeproj/project.pbxproj` — **own commit**, via Xcode Signing & Capabilities → `+ Apple Pay` → select the Merchant ID once it exists.
- Modify: `Config/Base.xcconfig`
- Create: `Sirr/Components/ApplePayButton.swift`
- Modify: `Sirr/Components/CardPaymentSheet.swift`

**Interfaces:**
- Consumes: `CardPaymentQuote`, `PaymentRequest` (Task 8/9); SDK `ApplePayService.authorizePayment(request:token:)`.
- Produces: `struct ApplePayButton: View { init(request: PaymentRequest, quote: CardPaymentQuote, eventName: String, onResult: @escaping (PaymentResult) -> Void) }`.

- [ ] **Step 1: Merchant id from a build setting, never a literal**

Append to `Config/Base.xcconfig`:
```
// Apple Pay merchant identifier. Empty until the Merchant ID exists in Apple
// Developer and its payment processing certificate is activated in the Moyasar
// dashboard (PAYMENT_SETUP.md, Apple Pay section). Empty means the Apple Pay
// button is not shown, and nothing else changes.
APPLE_PAY_MERCHANT_ID =
INFOPLIST_KEY_ApplePayMerchantID = $(APPLE_PAY_MERCHANT_ID)
```

- [ ] **Step 2: Write the button**

```swift
//
//  ApplePayButton.swift
//  Sirr
//
//  Apple Pay through Moyasar. PassKit collects the token; the SDK sends it to
//  Moyasar with the same manual (authorize-only) request the card form uses,
//  so verify-payment is the gate for both.
//

import SwiftUI
import PassKit
import MoyasarSdk

struct ApplePayButton: View {
    let request: PaymentRequest
    let quote: CardPaymentQuote
    let eventName: String
    let onResult: (PaymentResult) -> Void

    static var merchantIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "ApplePayMerchantID") as? String,
              !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }

    static var isAvailable: Bool {
        merchantIdentifier != nil
            && PKPaymentAuthorizationController.canMakePayments(usingNetworks: [.visa, .masterCard, .mada])
    }

    var body: some View {
        PayWithApplePayButton(.pay) {
            present()
        }
        .payWithApplePayButtonStyle(.white)
        .frame(height: 48)
        .clipShape(.rect(cornerRadius: 17, style: .continuous))
    }

    private func present() {
        guard let merchant = Self.merchantIdentifier else { return }
        let pk = PKPaymentRequest()
        pk.merchantIdentifier = merchant
        pk.countryCode = "SA"
        pk.currencyCode = quote.currency
        pk.supportedNetworks = [.visa, .masterCard, .mada]
        pk.merchantCapabilities = [.threeDSecure, .credit, .debit]
        pk.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: "تمرين: \(eventName)",
                amount: NSDecimalNumber(value: quote.amountInRiyals),
                type: .final
            )
        ]
        let controller = PKPaymentAuthorizationController(paymentRequest: pk)
        let delegate = Delegate(request: request, onResult: onResult)
        controller.delegate = delegate
        Delegate.retained = delegate
        controller.present()
    }

    private final class Delegate: NSObject, PKPaymentAuthorizationControllerDelegate {
        static var retained: Delegate?
        let request: PaymentRequest
        let onResult: (PaymentResult) -> Void
        private var settled: PaymentResult?

        init(request: PaymentRequest, onResult: @escaping (PaymentResult) -> Void) {
            self.request = request
            self.onResult = onResult
        }

        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            Task {
                do {
                    let service = try ApplePayService(apiKey: request.apiKey)
                    let api = try await service.authorizePayment(request: request, token: payment.token)
                    switch api.status {
                    case .paid, .authorized, .initiated:
                        settled = .completed(api)
                        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
                    default:
                        settled = .failed(MoyasarError.unexpectedError("status \(api.status.rawValue)"))
                        completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
                    }
                } catch {
                    settled = .failed(error)
                    completion(PKPaymentAuthorizationResult(status: .failure, errors: [error]))
                }
            }
        }

        func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
            controller.dismiss {
                DispatchQueue.main.async {
                    self.onResult(self.settled ?? .canceled)
                    Delegate.retained = nil
                }
            }
        }
    }
}
```

If `MoyasarError.unexpectedError` is not a real case, read `Sdk/MoyasarSdk/Errors/MoyasarError.swift` in the package checkout and use an existing case; if `PaymentResult.failed` takes a `MoyasarError` rather than `Error`, wrap accordingly.

- [ ] **Step 3: Show it above the card form in `CardPaymentSheet.swift`**

Inside `case .idle:` where `request` and `quote` are unwrapped, before `CreditCardView`:
```swift
                        if ApplePayButton.isAvailable {
                            ApplePayButton(request: request, quote: quote, eventName: eventName) { result in
                                handle(result, quote: quote)
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            Text("أو بالبطاقة")
                                .font(TamrinFont.font(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.bottom, 8)
                        }
```

- [ ] **Step 4: Build (the button compiles with an empty merchant id; it simply stays hidden)**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit source, then capability separately**

```bash
git add Config/Base.xcconfig Sirr/Components/ApplePayButton.swift Sirr/Components/CardPaymentSheet.swift
git commit -m "feat(payments): Apple Pay button behind the same server gate"
```
Only after the Merchant ID exists and is selected in Xcode:
```bash
git add Sirr/Sirr.entitlements Sirr.xcodeproj/project.pbxproj
git commit -m "build: Apple Pay capability (entitlements + project file only)"
```

Hand-over (real device, real card in Wallet, sandbox keys): set a test workout's price to **250 SAR** — sandbox Apple Pay results are chosen by amount and Tamrin's usual 30–80 SAR falls outside every documented range. Expect: tick, seat confirmed, `payments.payment_method = 'applepay'`. Check `payments.last_moyasar_status` after the first success: if it reads `paid` rather than `authorized`/`captured`, manual mode did not apply to Apple Pay and the spec's fallback (verify-then-refund) must be raised before anything goes live.

---

### Task 11: `PAYMENT_SETUP.md`

**Files:**
- Create: `PAYMENT_SETUP.md`

- [ ] **Step 1: Write it**

```markdown
# Payment setup — Moyasar

Design: docs/superpowers/specs/2026-09-06-moyasar-payments-design.md
Plan:   docs/superpowers/plans/2026-09-19-moyasar-payments.md

## Moyasar Dashboard

Take three things from Settings → API Keys:
- `sk_test_…` / `sk_live_…` — secret key. Server only. Never in Swift, xcconfig or git.
- `pk_test_…` / `pk_live_…` — publishable key. Also stored server-side; create-payment
  returns it to the app per request, so rotation needs no App Store release.
- Confirm which payment methods are enabled on the account (mada, Visa, Mastercard, Apple Pay).

Check the account before trusting it: `./scripts/moyasar-account-check.sh`, then
`./scripts/moyasar-splits-probe.sh` once you have a real recipient id.

## Supabase secrets

Two projects, two sets. Never cross them.

    # sandbox — test keys
    supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_SECRET_KEY=sk_test_…
    supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_PUBLISHABLE_KEY=pk_test_…
    supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_WEBHOOK_SECRET=$(openssl rand -hex 32)

    # production — live keys, same three names
    supabase secrets set --project-ref hzsxwnmbdkrmipjtfzlp …

Deploy: `supabase functions deploy create-payment verify-payment moyasar-webhook --project-ref <ref>`

## Webhook

Moyasar Dashboard → Settings → Webhooks → add endpoint:

    https://<project-ref>.supabase.co/functions/v1/moyasar-webhook

Secret token: the exact value set as `MOYASAR_WEBHOOK_SECRET`. Events: payment_paid,
payment_captured, payment_faild, payment_voided, payment_refunded. The function
re-fetches every payment with the secret key, so a forged body cannot settle anything.

## Onboarding a workspace for card payments

There is no API for this. Once Moyasar gives you a recipient id for an organizer:

    insert into public.workspace_moyasar_recipients
      (workspace_id, moyasar_recipient_id, recipient_type, status, verified_at)
    values ('<workspace uuid>', '<recipient uuid>', 'Beneficiary', 'verified', now());

Run it as service_role (SQL editor). The card button appears for that workspace on the
next app launch. Every other workspace keeps the manual transfer flow.

## Apple Pay — manual steps, in this order

1. Apple Developer → Identifiers → Merchant IDs → create `merchant.com.businessech.tmrin`.
2. Enable Apple Pay Payment Processing on App IDs `com.businessech.tmrin` **and**
   `com.businessech.tmrin.staging`, selecting that Merchant ID on both.
3. Moyasar Dashboard → Settings → Apple Pay - Certificate → Add Certificate → Download CSR.
4. Apple Developer → the Merchant ID → Apple Pay Payment Processing Certificate → Create
   Certificate → "China Mainland?" **No** → upload Moyasar's CSR → download `apple_pay.cer`.
5. Moyasar → Upload File → `apple_pay.cer` → shows "Activated".
6. `Config/Local.xcconfig` (gitignored): `APPLE_PAY_MERCHANT_ID = merchant.com.businessech.tmrin`.
   For a shared value, set it in `Config/Base.xcconfig` instead.
7. Xcode → Sirr target → Signing & Capabilities → + Apple Pay → tick the Merchant ID.
   Commit `Sirr.entitlements` + `project.pbxproj` on their own.

Certificates expire every **25 months**. Renew by uploading the new one to Moyasar
*before* activating it at Apple; never revoke the old one first. Set a reminder.

## Testing (Moyasar test mode)

Cards (any two-word name, any future expiry, any 3-digit CVC):
- `4111111111111111` Visa — paid
- `4201320111111010` mada — paid
- `4123120000000000` Visa — unspecified failure
- `5105105105105100` Mastercard — unspecified failure

Apple Pay: real device, real card in Wallet, result chosen by **amount**:
- 200–300 SAR → paid · 1101–1200 → insufficient funds · 1301–1400 → declined
- Use a 250 SAR workout; a 60 SAR seat falls outside every range.

Plan:
1. Successful card → seat confirmed, `payments.status = paid`, organizer push.
2. Failed card → seat stays pending, `payments.status = failed`.
3. Cancelled → `cancelled` state in the sheet, nothing changes server-side.
4. Duplicate webhook → replay Moyasar's delivery from the dashboard; `moyasar_webhook_events`
   has one row, seat confirmed once.
5. Tampered amount → run `verify-payment` against a payment authorized for a different
   amount (curl with the SDK-created id); expect `{"status":"failed","reason":"amount"}`,
   Moyasar shows `voided`.
6. Already paid → tap card again on the same seat; `create-payment` returns `already_paid`
   before contacting Moyasar.

SQL suites: `supabase/tests/moyasar_payments_schema_test.sql`, `card_payment_rpcs_test.sql`.
Deno suites: `supabase/functions/_shared/`, `create-payment/`, `verify-payment/`, `moyasar-webhook/`.
```

- [ ] **Step 2: Commit**

```bash
git add PAYMENT_SETUP.md
git commit -m "docs: payment setup — dashboard, secrets, webhook, Apple Pay, tests"
```

---

## Self-review

**Spec coverage:** tables/RLS → T1; server-side pricing, already-paid, recipient gate → T2; single settle door, idempotency, refund release, organizer push → T3; secret-key client + pure amount/recipient gate → T4; three functions, CORS, config → T5–T7; SDK, manual mode, four UI states, verify-not-trust → T8–T9; Apple Pay code + manual steps + amount-range caveat → T10; PAYMENT_SETUP.md with all five sections → T11; `.env.example` → T5; pbxproj isolation → T8/T10 own commits.

**Deliberately not in the plan:** a pending-payment sweep cron (spec says the pending row is left; Moyasar authorizations expire on their side — revisit if `payments` accumulates `pending` rows); organizer-facing payments list UI (spec has no screen for it; owners can read rows via RLS when one is designed).

**Type consistency:** `settle_payment(uuid, text, text, text, int, text)` signature identical in T3 SQL, T6/T7 `settle` args, and the T2 test calls. `CardPaymentQuote` field names match `create-payment` JSON keys. `begin_card_payment` statuses match `CardPaymentStart` cases and the T5 pass-through.
