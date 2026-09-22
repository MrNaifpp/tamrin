# Refunds and One-Tap Apple Pay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Return money automatically when a player withdraws, when they remove a guest they paid for, or when the organizer cancels — and make the pay button open Apple Pay in one tap.

**Architecture:** A refund is a row, not a call. The database computes the amount from the seats **before** deleting them and inserts a `refunds` row; an `AFTER INSERT` trigger calls an Edge Function that holds the secret key and talks to Moyasar; `settle_refund()` applies the result. This is the `push_outbox` pattern already in the repo, and it means a failed HTTP call loses nothing.

**Tech Stack:** Supabase Postgres 17 (plpgsql, RLS, pg_net, vault), Supabase Edge Functions (Deno), Moyasar REST v1, SwiftUI + PassKit, iOS 26 deployment target.

**Spec:** `docs/superpowers/specs/2026-09-22-refunds-and-direct-apple-pay-design.md` — read it before Task 1.

## Global Constraints

- Amounts are integers in halalas, computed in Postgres and read from Postgres. **No request body ever names an amount.**
- Role `authenticated` gets **no** `insert`, `update` or `delete` on `public.refunds`. Writes come from `security definer` functions and service_role only.
- `settle_refund()` is the only code path that raises `payments.refunded_amount`.
- `payments.status` gains no new value. It stays `paid` while partially refunded and becomes `refunded` only when `refunded_amount = amount`.
- Refunds apply to card payments only. A seat with no `payment_id`, or whose payment is not `paid`, is skipped silently.
- Withdrawal refunds only before `events.start_date`. Cancellation refunds have no window.
- Moyasar: `POST /v1/payments/{id}/refund`, body `{"amount": N}` in halalas, secret key as HTTP Basic username with an empty password.
- Never branch on a payment's `status` after a refund. Moyasar's cumulative `refunded` integer is the truth.
- A custom button that starts Apple Pay must not show the Apple Pay name or logo. Use the system button.
- Arabic UI copy. No em dashes in push copy (see `copy.ts` header).
- No simulators. iOS tasks end with `xcodebuild … build` and a hand-over checklist.
- Local SQL: rebuild per `~/.claude/.../memory/local-supabase-db-workflow.md`, apply migrations in order skipping `*avatar_storage*`, then `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f <test>`. A pass ends with `ROLLBACK` and no `ERROR` line.
- Deno tests: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/<path>`.

---

## File map

**Create**
```
supabase/migrations/20260922100000_refunds.sql            table, payments columns, settle_refund
supabase/migrations/20260922110000_refund_triggers.sql    request_refund, the three trigger points,
                                                          remove_my_guest, the outbox trigger,
                                                          retry_pending_refunds, settle_payment rework
supabase/tests/refunds_test.sql
supabase/functions/refund-payment/index.ts
supabase/functions/refund-payment/handler.ts
supabase/functions/refund-payment/handler_test.ts
```

**Modify**
```
supabase/functions/_shared/moyasar.ts            refund(); `refunded` on MoyasarPayment
supabase/functions/_shared/moyasar_test.ts
supabase/functions/moyasar-webhook/handler.ts    reconcile a dashboard refund
supabase/functions/moyasar-webhook/handler_test.ts
supabase/functions/send-push/copy.ts             refund_issued
supabase/functions/send-push/copy_test.ts
supabase/config.toml                             [functions.refund-payment]
Sirr/core/payment/MoyasarPaymentService.swift    refundableQuote for the detail screen
Sirr/core/payment/MoyasarPaymentModels.swift     GuestRemovalOutcome
Sirr/features/home/EventDetailView.swift         system Apple Pay button, guest removal, copy
Sirr/features/home/MockHomeFeed.swift            removeMyGuest
PAYMENT_SETUP.md                                 refund secret and its vault entries
```

---

### Task 1: Schema — the refunds ledger

**Files:**
- Create: `supabase/migrations/20260922100000_refunds.sql`
- Test: `supabase/tests/refunds_test.sql`

**Interfaces:**
- Produces: table `public.refunds`; columns `public.payments.refunded_amount`, `public.payments.refunded_seats`; function `public.settle_refund(p_refund_id uuid, p_status text, p_refunded_total int, p_failure_message text) returns json` returning `{"status":"settled"|"already_settled"|"failed"}`.
- Consumes: `public.payments`, `public.event_participants`, `public.push_outbox` from the Moyasar payments work.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/refunds_test.sql`:

```sql
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: `ERROR:  relation "public.refunds" does not exist`

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260922100000_refunds.sql`:

```sql
-- Refunds. A refund is a row before it is an API call: the amount is worked out
-- in the same transaction that frees the seat, because freeing it destroys the
-- evidence of what it cost. The row is then the instruction, the audit trail,
-- and the retry handle.
--
-- payments.refunded_amount is cumulative and guarded by a check constraint, so
-- "never give back more than came in" is a property of the schema rather than a
-- thing every caller has to remember.

create table public.refunds (
  id                  uuid primary key default gen_random_uuid(),
  payment_id          uuid not null references public.payments(id) on delete cascade,
  event_id            uuid not null references public.events(id) on delete cascade,
  user_id             uuid not null references auth.users(id) on delete cascade,
  seats               int  not null check (seats > 0),
  amount              int  not null check (amount > 0),
  reason              text not null
                        check (reason in ('withdrew', 'guest_removed', 'event_cancelled')),
  status              text not null default 'pending'
                        check (status in ('pending', 'processing', 'done', 'failed')),
  moyasar_payment_id  text not null,
  failure_code        text,
  failure_message     text,
  attempts            int  not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index idx_refunds_payment on public.refunds(payment_id);
create index idx_refunds_pending
  on public.refunds(created_at) where status in ('pending', 'processing');

alter table public.payments
  add column refunded_amount int not null default 0 check (refunded_amount >= 0),
  add column refunded_seats  int not null default 0 check (refunded_seats  >= 0);

-- The ceiling, in the schema. Nothing can refund past what was taken.
alter table public.payments
  add constraint payments_refund_within_amount check (refunded_amount <= amount),
  add constraint payments_refund_within_seats  check (refunded_seats  <= seat_count);

create trigger refunds_touch before update on public.refunds
  for each row execute function public.touch_updated_at();

alter table public.refunds enable row level security;

create policy "Payers can see their refunds"
  on public.refunds for select
  using (user_id = auth.uid());

create policy "Owners can see their workspace's refunds"
  on public.refunds for select
  using (exists (
    select 1 from public.payments p
    join public.workspaces w on w.id = p.workspace_id
    where p.id = payment_id and w.owner_id = auth.uid()
  ));

revoke insert, update, delete, truncate, references, trigger
  on public.refunds from anon, authenticated;
grant select on public.refunds to authenticated;

-- settle_refund is the only thing that raises refunded_amount. Both the Edge
-- Function and the webhook end here, so idempotency lives in one place.
--
-- p_refunded_total is Moyasar's OWN cumulative `refunded` figure for the
-- payment, not our arithmetic. Taking the greater of the two means a refund
-- issued from their dashboard is absorbed rather than lost.
create or replace function public.settle_refund(
  p_refund_id uuid,
  p_status text,
  p_refunded_total int,
  p_failure_message text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_refund public.refunds;
  v_payment public.payments;
  v_event public.events;
  v_total int;
begin
  select * into v_refund from public.refunds where id = p_refund_id for update;
  if v_refund.id is null then raise exception 'Refund not found'; end if;

  if v_refund.status in ('done', 'failed') then
    return json_build_object('status', 'already_settled');
  end if;

  if p_status <> 'refunded' then
    update public.refunds
       set status = 'failed',
           failure_code = 'refund_rejected',
           failure_message = left(coalesce(p_failure_message, p_status), 500)
     where id = p_refund_id;
    return json_build_object('status', 'failed');
  end if;

  select * into v_payment from public.payments
   where id = v_refund.payment_id for update;

  v_total := greatest(coalesce(p_refunded_total, 0),
                      v_payment.refunded_amount + v_refund.amount);
  -- The constraint is the backstop; clamp so a bad figure from Moyasar cannot
  -- abort the whole transaction and strand the row in `processing`.
  v_total := least(v_total, v_payment.amount);

  update public.payments
     set refunded_amount = v_total,
         refunded_seats  = least(refunded_seats + v_refund.seats, seat_count),
         status = case when v_total >= amount then 'refunded' else status end
   where id = v_payment.id
  returning * into v_payment;

  update public.refunds set status = 'done' where id = p_refund_id;

  -- Fully refunded: the payment is holding no seats any more. On a cancelled
  -- event the debt is forgiven outright, because leaving seats `pending` there
  -- would gate the payer out of their next workout for money nobody wants.
  if v_payment.status = 'refunded' then
    select * into v_event from public.events where id = v_refund.event_id;
    update public.event_participants
       set payment_status = case
             when v_event.cancelled_at is not null then 'waived'
             else 'pending'
           end
     where payment_id = v_payment.id and payment_status = 'confirmed';
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_refund.user_id, 'refund_issued', v_refund.event_id);

  return json_build_object('status', 'settled', 'refunded_total', v_total);
end;
$$;

revoke execute on function public.settle_refund(uuid, text, int, text)
  from public, anon, authenticated;
grant execute on function public.settle_refund(uuid, text, int, text) to service_role;
```

- [ ] **Step 4: Apply and run the test**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260922100000_refunds.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: `NOTICE:  PASS: refunds ledger`, `NOTICE:  PASS: refunds rls`, then `ROLLBACK`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260922100000_refunds.sql supabase/tests/refunds_test.sql
git commit -m "feat(payments): a refunds ledger with the ceiling in the schema"
```

---

### Task 2: `request_refund`, and teaching `settle_payment` that a refund can be partial

**Files:**
- Create: `supabase/migrations/20260922110000_refund_triggers.sql` (first half)
- Modify: `supabase/tests/refunds_test.sql` (append a section)

**Interfaces:**
- Produces: `public.request_refund(p_payment_id uuid, p_seats int, p_amount int, p_reason text) returns uuid` — internal, granted to nobody, returns the new refund id or `null` when there is nothing to refund. `public.settle_payment(uuid, text, text, text, int, text, int)` — the sixth argument list gains `p_refunded_total int default 0`.
- Consumes: `public.refunds`, `public.payments.refunded_amount` (Task 1).

- [ ] **Step 1: Write the failing test**

Append to `supabase/tests/refunds_test.sql`, immediately before the final `rollback;`:

```sql
-- ============================================================
-- Section 3: request_refund is the only door, and it will not
-- open past what the payment actually took.
-- ============================================================
insert into public.payments
  (id, workspace_id, event_id, user_id, seat_count, amount, status,
   payment_method, moyasar_payment_id, paid_at)
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
  v := public.settle_refund(v_id, 'refunded', 12000, null);

  -- 3. Asking for more than remains is clamped to what remains.
  v_id := public.request_refund('81000000-0000-0000-0000-0000000000f2',
                                2, 99999, 'withdrew');
  select amount into v_amount from public.refunds where id = v_id;
  if v_amount <> 12000 then
    raise exception 'FAIL: expected the remaining 12000, got %', v_amount;
  end if;
  v := public.settle_refund(v_id, 'refunded', 24000, null);

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
-- Section 4: a webhook saying "refunded" no longer means "all of it".
-- ============================================================
insert into public.payments
  (id, workspace_id, event_id, user_id, seat_count, amount, status,
   payment_method, moyasar_payment_id, paid_at)
values ('81000000-0000-0000-0000-0000000000f4',
        '81000000-0000-0000-0000-0000000000a1',
        '81000000-0000-0000-0000-0000000000e1',
        '81000000-0000-0000-0000-000000000002', 2, 24000, 'paid',
        'creditcard', 'pay_moy_refund_4', now());

insert into public.event_participants (event_id, user_id, added_by, guest_name,
                                       payment_status, payment_id)
values ('81000000-0000-0000-0000-0000000000e1', null,
        '81000000-0000-0000-0000-000000000002', 'ضيف رابع',
        'confirmed', '81000000-0000-0000-0000-0000000000f4');

do $$
declare
  v json;
  v_amount int;
  v_status text;
  v_count int;
begin
  -- A refund of half, issued from the Moyasar dashboard, arrives as a webhook.
  v := public.settle_payment('81000000-0000-0000-0000-0000000000f4',
                             'pay_moy_refund_4', 'refunded', 'creditcard',
                             24000, 'SAR', 12000);
  select refunded_amount, status into v_amount, v_status
  from public.payments where id = '81000000-0000-0000-0000-0000000000f4';
  if v_amount <> 12000 then
    raise exception 'FAIL: expected 12000 absorbed, got %', v_amount;
  end if;
  if v_status <> 'paid' then
    raise exception 'FAIL: half a refund must not mark it refunded, got %', v_status;
  end if;
  select count(*) into v_count from public.event_participants
  where payment_id = '81000000-0000-0000-0000-0000000000f4'
    and payment_status = 'confirmed';
  if v_count <> 1 then
    raise exception 'FAIL: half a refund released the seat, % left', v_count;
  end if;

  -- The rest follows.
  v := public.settle_payment('81000000-0000-0000-0000-0000000000f4',
                             'pay_moy_refund_4', 'refunded', 'creditcard',
                             24000, 'SAR', 24000);
  select status into v_status
  from public.payments where id = '81000000-0000-0000-0000-0000000000f4';
  if v_status <> 'refunded' then
    raise exception 'FAIL: expected refunded, got %', v_status;
  end if;

  raise notice 'PASS: partial refund reconciliation';
end;
$$;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: `ERROR:  function public.request_refund(unknown, integer, integer, unknown) does not exist`

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260922110000_refund_triggers.sql`:

```sql
-- Where refunds come from, and the one change a partial refund forces on
-- settle_payment.

-- request_refund is the single door into the refunds table. Every caller goes
-- through it so the "never more than remains" rule is written once. Returning
-- null rather than raising is deliberate: a member withdrawing from a workout
-- they paid for by bank transfer is not an error, it just has no refund.
create or replace function public.request_refund(
  p_payment_id uuid,
  p_seats int,
  p_amount int,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_amount int;
  v_seats int;
  v_id uuid;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if v_payment.id is null then return null; end if;
  if v_payment.status <> 'paid' then return null; end if;
  if v_payment.moyasar_payment_id is null then return null; end if;

  v_amount := least(coalesce(p_amount, 0), v_payment.amount - v_payment.refunded_amount);
  v_seats  := least(greatest(coalesce(p_seats, 1), 1),
                    v_payment.seat_count - v_payment.refunded_seats);
  if v_amount <= 0 or v_seats <= 0 then return null; end if;

  insert into public.refunds
    (payment_id, event_id, user_id, seats, amount, reason, moyasar_payment_id)
  values
    (v_payment.id, v_payment.event_id, v_payment.user_id, v_seats, v_amount,
     p_reason, v_payment.moyasar_payment_id)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.request_refund(uuid, int, int, text)
  from public, anon, authenticated;

-- settle_payment gains the cumulative refunded figure. A PARTIAL refund also
-- arrives from Moyasar as status "refunded", so the old branch — which marked
-- the whole payment refunded and released every seat — was wrong the moment
-- partial refunds existed. The amount decides now, never the word.
drop function if exists public.settle_payment(uuid, text, text, text, int, text);

create or replace function public.settle_payment(
  p_payment_id uuid,
  p_moyasar_payment_id text,
  p_moyasar_status text,
  p_payment_method text,
  p_amount int,
  p_currency text,
  p_refunded_total int default 0
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
  v_total int;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if v_payment.id is null then raise exception 'Payment not found'; end if;

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
    -- Absorb anything Moyasar has refunded that we did not issue ourselves,
    -- which is how a refund made from their dashboard reaches our books.
    v_total := least(greatest(coalesce(p_refunded_total, 0),
                              v_payment.refunded_amount),
                     v_payment.amount);
    if v_total > v_payment.refunded_amount then
      update public.payments
         set refunded_amount = v_total,
             refunded_seats = case when v_total >= amount
                                   then seat_count else refunded_seats end,
             status = case when v_total >= amount then 'refunded' else status end
       where id = p_payment_id
      returning * into v_payment;
    end if;

    if v_payment.status = 'refunded' then
      select * into v_event from public.events where id = v_payment.event_id;
      update public.event_participants
         set payment_status = case
               when v_event.cancelled_at is not null then 'waived'
               else 'pending'
             end
       where payment_id = p_payment_id and payment_status = 'confirmed';
    end if;

    return json_build_object('status', 'refunded',
                             'refunded_total', v_payment.refunded_amount);
  end if;

  return json_build_object('status', 'ignored');
end;
$$;

revoke execute on function public.settle_payment(uuid, text, text, text, int, text, int)
  from public, anon, authenticated;
grant execute on function public.settle_payment(uuid, text, text, text, int, text, int)
  to service_role;
```

- [ ] **Step 4: Apply and run the test**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260922110000_refund_triggers.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: four `PASS:` notices, then `ROLLBACK`

- [ ] **Step 5: Re-run the card payment suite, which shares `settle_payment`**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/card_payment_rpcs_test.sql`
Expected: `PASS: card payment rpcs` and `PASS: card payment without a recipient`. The six-argument calls in that suite still resolve, because the seventh parameter has a default.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260922110000_refund_triggers.sql supabase/tests/refunds_test.sql
git commit -m "feat(payments): request_refund, and a refund that can be partial"
```

---

### Task 3: The three places a refund starts

**Files:**
- Modify: `supabase/migrations/20260922110000_refund_triggers.sql` (append)
- Modify: `supabase/tests/refunds_test.sql` (append a section)

**Interfaces:**
- Produces: `public.remove_my_guest(p_participant_id uuid) returns json` → `{"status":"removed"|"not_found","refund_id":uuid|null}`, executable by `authenticated`. Reissued: `public.decline_event(uuid, text, text)`, `public.cancel_event_occurrence(uuid, text, text)` — same signatures and same return shapes as today.
- Consumes: `public.request_refund` (Task 2).

- [ ] **Step 1: Write the failing test**

Append to `supabase/tests/refunds_test.sql`, before the final `rollback;`:

```sql
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
     payment_method, moyasar_payment_id, paid_at)
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
     payment_method, moyasar_payment_id, paid_at)
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
     payment_method, moyasar_payment_id, paid_at)
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: `ERROR:  function public.remove_my_guest(uuid) does not exist`

- [ ] **Step 3: Append the three trigger points to the migration**

Append to `supabase/migrations/20260922110000_refund_triggers.sql`:

```sql
-- The player-facing half of remove_event_participant, which is organizer-only.
-- Whoever added a guest may take them out again, and gets that seat's money back
-- when the workout has not started.
create or replace function public.remove_my_guest(p_participant_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.event_participants;
  v_event public.events;
  v_amount int;
  v_refund uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_row from public.event_participants where id = p_participant_id;
  if v_row.id is null then
    return json_build_object('status', 'not_found', 'refund_id', null);
  end if;
  if v_row.user_id is not null then
    raise exception 'Only a guest can be removed this way';
  end if;
  if v_row.added_by is distinct from v_uid then
    raise exception 'Not authorized: this guest was added by someone else';
  end if;
  if v_row.added_manually then
    raise exception 'A player the organizer added is theirs to remove';
  end if;

  select * into v_event from public.events where id = v_row.event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  -- Worked out before the delete: afterwards nothing says what the seat cost.
  if v_row.payment_id is not null and now() < v_event.start_date then
    v_amount := round(coalesce(v_row.paid_price_per_person,
                               v_event.price_per_person) * 100)::int;
    v_refund := public.request_refund(v_row.payment_id, 1, v_amount, 'guest_removed');
  end if;

  delete from public.event_participants where id = p_participant_id;

  perform public.drain_waitlist(v_row.event_id);

  return json_build_object('status', 'removed', 'refund_id', v_refund);
end;
$$;

grant execute on function public.remove_my_guest(uuid) to authenticated;

-- decline_event, reissued with the money step. Everything else is byte for byte
-- what it was: the same guards, the same deletes, the same waitlist drain.
create or replace function public.decline_event(
  p_event_id uuid,
  p_reason_code text default null,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_reason_code text := nullif(lower(trim(p_reason_code)), '');
  v_reason_text text := nullif(trim(p_reason_text), '');
  v_removed_participants int := 0;
  v_removed_waitlist int := 0;
  v_waiters json;
  v_pay record;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if v_reason_code is not null and v_reason_code !~ '^[a-z0-9_-]{1,50}$' then
    raise exception 'Invalid reason code';
  end if;
  if v_reason_text is not null and char_length(v_reason_text) > 500 then
    raise exception 'Reason text is too long';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Workspace owner cannot decline an event they administer';
  end if;
  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  -- Money first. The delete below destroys the link between a seat and what it
  -- cost, so the refund is requested while the rows are still here. Only before
  -- the start; afterwards the seat is freed and nothing goes back.
  if now() < v_event.start_date then
    for v_pay in
      select ep.payment_id as payment_id,
             count(*)::int as seats,
             sum(round(coalesce(ep.paid_price_per_person,
                                v_event.price_per_person) * 100))::int as amount
      from public.event_participants ep
      where ep.event_id = p_event_id
        and (ep.user_id = v_uid or (ep.added_by = v_uid and not ep.guest_only))
        and ep.payment_id is not null
      group by ep.payment_id
    loop
      perform public.request_refund(v_pay.payment_id, v_pay.seats,
                                    v_pay.amount, 'withdrew');
    end loop;
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or (added_by = v_uid and not guest_only));
  get diagnostics v_removed_participants = row_count;

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_uid;
  get diagnostics v_removed_waitlist = row_count;

  insert into public.event_member_responses
    (event_id, user_id, status, reason_code, reason_text,
     responded_at, updated_at)
  values
    (p_event_id, v_uid, 'declined', v_reason_code, v_reason_text,
     now(), now())
  on conflict (event_id, user_id) do update
  set status = 'declined',
      reason_code = excluded.reason_code,
      reason_text = excluded.reason_text,
      responded_at = excluded.responded_at,
      updated_at = excluded.updated_at;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'member_declined', p_event_id);

  perform public.drain_waitlist(p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'declined',
    'event_id', p_event_id,
    'reason_code', v_reason_code,
    'reason_text', v_reason_text,
    'removed_participant_rows', v_removed_participants,
    'removed_waitlist_rows', v_removed_waitlist,
    'waiter_ids', v_waiters
  );
end;
$$;

-- cancel_event_occurrence, reissued. Cancelling does not delete seats, so the
-- sweep is simply every paid card payment on the workout. No time window: this
-- is the organizer's decision, not the player's.
create or replace function public.cancel_event_occurrence(
  p_event_id uuid,
  p_reason_code text default null,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_reason_code text := nullif(lower(trim(p_reason_code)), '');
  v_reason_text text := nullif(trim(p_reason_text), '');
  v_notifications int := 0;
  v_pay record;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if v_reason_code is not null and v_reason_code !~ '^[a-z0-9_-]{1,50}$' then
    raise exception 'Invalid reason code';
  end if;
  if v_reason_text is not null and char_length(v_reason_text) > 500 then
    raise exception 'Reason text is too long';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can cancel events';
  end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  if v_event.cancelled_at is not null then
    return json_build_object(
      'status', 'already_cancelled',
      'event_id', v_event.id,
      'cancelled_at', v_event.cancelled_at,
      'reason_code', v_event.cancellation_reason_code,
      'reason_text', v_event.cancellation_reason_text,
      'notification_count', 0
    );
  end if;

  update public.events
  set published_at = coalesce(published_at, now()),
      cancelled_at = now(),
      cancelled_by = v_uid,
      cancellation_reason_code = v_reason_code,
      cancellation_reason_text = v_reason_text,
      registration_locked = true
  where id = p_event_id
  returning * into v_event;

  if v_event.template_id is not null then
    update public.event_templates
    set published_at = coalesce(published_at, v_event.published_at)
    where id = v_event.template_id
      and ended_at is null;
  end if;

  -- Nobody is playing, so nobody is paying.
  for v_pay in
    select id, seat_count - refunded_seats as seats, amount - refunded_amount as amount
    from public.payments
    where event_id = p_event_id
      and status = 'paid'
      and amount > refunded_amount
  loop
    perform public.request_refund(v_pay.id, v_pay.seats, v_pay.amount,
                                  'event_cancelled');
  end loop;

  with notified as (
    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, 'event_cancelled', v_event.id
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id <> v_uid
    returning user_id
  )
  select count(*) into v_notifications from notified;

  return json_build_object(
    'status', 'cancelled',
    'event_id', v_event.id,
    'cancelled_at', v_event.cancelled_at,
    'reason_code', v_event.cancellation_reason_code,
    'reason_text', v_event.cancellation_reason_text,
    'notification_count', v_notifications
  );
end;
$$;
```

- [ ] **Step 4: Apply and run the test**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260922110000_refund_triggers.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: five `PASS:` notices ending with `PASS: refund trigger points`, then `ROLLBACK`

- [ ] **Step 5: Re-run the suites that touch these functions**

Run: `for t in event_lifecycle_test recurring_events_test waitlist_promotion_test merge_guests_and_waitlist_test; do echo "== $t"; psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/$t.sql 2>&1 | grep -E "ERROR|PASS|FAIL"; done`
Expected: every suite still passes. `decline_event` and `cancel_event_occurrence` were reissued, so a regression shows here first.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260922110000_refund_triggers.sql supabase/tests/refunds_test.sql
git commit -m "feat(payments): withdrawing, removing a guest and cancelling all return money"
```

---

### Task 4: The row reaches the Edge Function, and keeps trying

**Files:**
- Modify: `supabase/migrations/20260922110000_refund_triggers.sql` (append)
- Modify: `supabase/tests/refunds_test.sql` (append a section)

**Interfaces:**
- Produces: `public.post_refund(p_refund_id uuid) returns void` (internal); trigger `trg_fire_refund_outbox` on `public.refunds`; `public.retry_pending_refunds() returns int`, service_role only, returning how many it re-fired.
- Consumes: `vault.decrypted_secrets` entries `refund_payment_url` and `refund_payment_secret`, and the `net` extension — both already used by `fire_push_outbox`.

- [ ] **Step 1: Write the failing test**

Append to `supabase/tests/refunds_test.sql`, before the final `rollback;`:

```sql
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
     payment_method, moyasar_payment_id, paid_at)
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: `FAIL: the refunds outbox trigger is missing`

- [ ] **Step 3: Append the wiring to the migration**

Append to `supabase/migrations/20260922110000_refund_triggers.sql`:

```sql
-- Getting the row to the function. Identical in shape to fire_push_outbox,
-- including the silent skip when the vault has no entry, so a local stack and
-- CI stay green without secrets.
create or replace function public.post_refund(p_refund_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'refund_payment_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'refund_payment_secret';

  if v_url is null or v_url = '' then
    return;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || coalesce(v_secret, '')),
    body    := jsonb_build_object('refund_id', p_refund_id)
  );
end;
$$;

create or replace function public.fire_refund_outbox()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.post_refund(new.id);
  return new;
end;
$$;

create trigger trg_fire_refund_outbox
  after insert on public.refunds
  for each row execute function public.fire_refund_outbox();

-- A refund is money we owe. If the HTTP call never lands, nothing else would
-- ever notice, so anything still waiting after a few minutes is fired again.
-- The attempt ceiling stops a permanently rejected refund from being retried
-- forever; it sits there `pending` with its attempts spent, which is a visible
-- state rather than a silent one.
create or replace function public.retry_pending_refunds()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.refunds;
  v_count int := 0;
begin
  for v_row in
    select * from public.refunds
    where status in ('pending', 'processing')
      and attempts < 5
      and created_at < now() - interval '3 minutes'
    order by created_at asc
    limit 50
  loop
    perform public.post_refund(v_row.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.retry_pending_refunds() from public, anon, authenticated;
grant execute on function public.retry_pending_refunds() to service_role;
```

- [ ] **Step 4: Apply and run the test**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260922110000_refund_triggers.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_test.sql`
Expected: six `PASS:` notices ending with `PASS: refund outbox wiring`, then `ROLLBACK`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260922110000_refund_triggers.sql supabase/tests/refunds_test.sql
git commit -m "feat(payments): a refund row fires itself, and is retried if it does not land"
```

---

### Task 5: The shared client learns to refund

**Files:**
- Modify: `supabase/functions/_shared/moyasar.ts`
- Modify: `supabase/functions/_shared/moyasar_test.ts`

**Interfaces:**
- Produces: `MoyasarPayment` gains `refunded?: number`; the client gains `refund(id: string, amount?: number): Promise<MoyasarPayment>`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `supabase/functions/_shared/moyasar_test.ts`:

```ts
Deno.test("refund posts the amount in halalas as a JSON body", async () => {
  let seen: { url: string; method?: string; body?: string } | null = null;
  const fakeFetch: typeof fetch = async (input, init) => {
    seen = { url: String(input), method: init?.method, body: init?.body as string };
    return new Response(
      JSON.stringify({ id: "p1", status: "refunded", amount: 6000, currency: "SAR", refunded: 2000 }),
      { status: 200 },
    );
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  const p = await c.refund("p1", 2000);
  assertEquals(p.refunded, 2000);
  assertEquals(seen!.url, "https://api.moyasar.com/v1/payments/p1/refund");
  assertEquals(seen!.method, "POST");
  assertEquals(seen!.body, JSON.stringify({ amount: 2000 }));
});

Deno.test("refund with no amount sends no body, which Moyasar reads as all of it", async () => {
  let seen: { body?: string | null } | null = null;
  const fakeFetch: typeof fetch = async (_input, init) => {
    seen = { body: (init?.body ?? null) as string | null };
    return new Response(
      JSON.stringify({ id: "p1", status: "refunded", amount: 6000, currency: "SAR", refunded: 6000 }),
      { status: 200 },
    );
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  await c.refund("p1");
  assertEquals(seen!.body, null);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/_shared/`
Expected: `Property 'refund' does not exist` from the type checker

- [ ] **Step 3: Implement**

In `supabase/functions/_shared/moyasar.ts`, add `refunded` to the payment type:

```ts
export type MoyasarPayment = {
  id: string;
  status: string;
  amount: number;
  currency: string;
  /// Cumulative, in halalas. The only honest answer to "how much has gone
  /// back", because a partial refund leaves `status` saying "refunded" too.
  refunded?: number;
  source?: { type?: string; message?: string };
  metadata?: Record<string, unknown>;
  splits?: Array<{ recipient_id: string; amount: number }> | null;
};
```

Then give `call` an optional body and add `refund`:

```ts
  async function call(
    method: "GET" | "POST",
    path: string,
    body?: Record<string, unknown>,
  ): Promise<MoyasarPayment> {
    const res = await fetchImpl(`${baseUrl}${path}`, {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await res.text();
    if (!res.ok) throw new MoyasarError(res.status, text);
    return JSON.parse(text) as MoyasarPayment;
  }

  return {
    fetchPayment: (id: string) => call("GET", `/payments/${encodeURIComponent(id)}`),
    capture: (id: string) => call("POST", `/payments/${encodeURIComponent(id)}/capture`),
    voidPayment: (id: string) => call("POST", `/payments/${encodeURIComponent(id)}/void`),
    // No amount means no body, which Moyasar documents as a refund in full.
    refund: (id: string, amount?: number) =>
      call("POST", `/payments/${encodeURIComponent(id)}/refund`,
           amount === undefined ? undefined : { amount }),
  };
```

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: 12 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/moyasar.ts supabase/functions/_shared/moyasar_test.ts
git commit -m "feat(payments): the Moyasar client can refund, in full or in part"
```

---

### Task 6: `refund-payment` — the only thing that sends money back

**Files:**
- Create: `supabase/functions/refund-payment/handler.ts`, `index.ts`, `handler_test.ts`
- Modify: `supabase/config.toml`

**Interfaces:**
- Consumes: `makeMoyasarClient` (Task 5), `settle_refund` (Task 1).
- Produces: `POST /functions/v1/refund-payment` body `{ "refund_id": uuid }` → `200 { status: "settled" | "duplicate" | "failed" }`; `401` on a wrong shared secret; `400` without a refund id; `404` when the row is gone.
- Handler factory: `makeHandler(deps: RefundDeps)` with
  ```ts
  type RefundRow = { id: string; moyasar_payment_id: string; amount: number; status: string };
  type RefundDeps = {
    sharedSecret: string;
    loadRefund(id: string): Promise<RefundRow | null>;
    markProcessing(id: string): Promise<void>;
    moyasar: ReturnType<typeof makeMoyasarClient>;
    settle(args: { p_refund_id: string; p_status: string; p_refunded_total: number; p_failure_message: string | null }): Promise<{ status: string }>;
  };
  ```

- [ ] **Step 1: Write the failing test**

Create `supabase/functions/refund-payment/handler_test.ts`:

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const row = { id: "ref-1", moyasar_payment_id: "moy-1", amount: 12000, status: "pending" };
const refunded = { id: "moy-1", status: "refunded", amount: 24000, currency: "SAR", refunded: 12000 };

function deps(over: Record<string, unknown> = {}) {
  const log: string[] = [];
  const settled: Array<Record<string, unknown>> = [];
  return {
    log,
    settled,
    sharedSecret: "refsec",
    loadRefund: async (id: string) => (id === "ref-1" ? { ...row } : null),
    markProcessing: async () => { log.push("processing"); },
    moyasar: {
      fetchPayment: async () => { log.push("fetch"); return refunded; },
      capture: async () => refunded,
      voidPayment: async () => refunded,
      refund: async (_id: string, amount?: number) => {
        log.push(`refund:${amount}`);
        return refunded;
      },
    },
    settle: async (args: Record<string, unknown>) => {
      settled.push(args);
      return { status: args.p_status === "refunded" ? "settled" : "failed" };
    },
    ...over,
  };
}

const post = (body: unknown, auth = "Bearer refsec") =>
  new Request("http://x/refund-payment", {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("a wrong shared secret is refused and nothing is called", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }, "Bearer nope"));
  assertEquals(res.status, 401);
  assertEquals(d.log, []);
});

Deno.test("the amount comes from the row, never from the request", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ refund_id: "ref-1", amount: 999999 }));
  assertEquals(res.status, 200);
  assertEquals(d.log, ["processing", "refund:12000", "fetch"]);
  assertEquals(d.settled[0].p_refunded_total, 12000);
  assertEquals(d.settled[0].p_status, "refunded");
});

Deno.test("a row that is no longer pending is a duplicate delivery", async () => {
  const d = deps({ loadRefund: async () => ({ ...row, status: "done" }) });
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals((await res.json()).status, "duplicate");
  assertEquals(d.log, []);
});

Deno.test("a Moyasar refusal is recorded against the row, not thrown away", async () => {
  const d = deps();
  d.moyasar.refund = async () => { throw new Error("Moyasar 400: already refunded"); };
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(res.status, 200);
  assertEquals(d.settled[0].p_status, "failed");
  assertEquals(String(d.settled[0].p_failure_message).includes("already refunded"), true);
});

Deno.test("an unknown refund id is 404", async () => {
  const res = await makeHandler(deps())(post({ refund_id: "nope" }));
  assertEquals(res.status, 404);
});

Deno.test("a missing refund id is 400", async () => {
  const res = await makeHandler(deps())(post({}));
  assertEquals(res.status, 400);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/refund-payment/`
Expected: `Module not found … handler.ts`

- [ ] **Step 3: Implement the handler and entrypoint**

`supabase/functions/refund-payment/handler.ts`:

```ts
// Sends money back. Called server to server by the refunds trigger, so the gate
// is a shared secret rather than a user's JWT — the same arrangement send-push
// uses, for the same reason: Postgres cannot present a Supabase JWT.
//
// The amount is read from the refunds row. The request body carries an id and
// nothing else that matters, exactly as create-payment carries no price.
import { json } from "../_shared/cors.ts";
import type { makeMoyasarClient } from "../_shared/moyasar.ts";

export type RefundRow = {
  id: string;
  moyasar_payment_id: string;
  amount: number;
  status: string;
};

export type RefundDeps = {
  sharedSecret: string;
  loadRefund(id: string): Promise<RefundRow | null>;
  markProcessing(id: string): Promise<void>;
  moyasar: ReturnType<typeof makeMoyasarClient>;
  settle(args: {
    p_refund_id: string;
    p_status: string;
    p_refunded_total: number;
    p_failure_message: string | null;
  }): Promise<{ status: string }>;
};

export function makeHandler(deps: RefundDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.headers.get("authorization") !== `Bearer ${deps.sharedSecret}`) {
      return json({ error: "unauthorized" }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const refundId = typeof body?.refund_id === "string" ? body.refund_id : null;
    if (!refundId) return json({ error: "refund_id required" }, 400);

    const row = await deps.loadRefund(refundId);
    if (!row) return json({ error: "not found" }, 404);

    // The trigger and the retry sweep can both reach the same row. Whichever
    // arrives second finds it already moving and leaves it alone.
    if (row.status !== "pending") return json({ status: "duplicate" });

    await deps.markProcessing(row.id);

    try {
      await deps.moyasar.refund(row.moyasar_payment_id, row.amount);
      // Re-read so the cumulative total is Moyasar's figure, not our sum.
      const payment = await deps.moyasar.fetchPayment(row.moyasar_payment_id);
      const result = await deps.settle({
        p_refund_id: row.id,
        p_status: "refunded",
        p_refunded_total: payment.refunded ?? row.amount,
        p_failure_message: null,
      });
      return json({ status: result.status });
    } catch (error) {
      // A refusal is an outcome, not a crash. Record it and acknowledge, so the
      // retry sweep does not hammer a refund Moyasar will never accept.
      console.error("refund-payment failed:", error);
      await deps.settle({
        p_refund_id: row.id,
        p_status: "failed",
        p_refunded_total: 0,
        p_failure_message: String(error).slice(0, 500),
      });
      return json({ status: "failed" });
    }
  };
}
```

`supabase/functions/refund-payment/index.ts`:

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler, type RefundRow } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(makeHandler({
  sharedSecret: Deno.env.get("REFUND_PAYMENT_SECRET")!,
  moyasar: makeMoyasarClient(Deno.env.get("MOYASAR_SECRET_KEY")!),
  async loadRefund(id) {
    const { data } = await admin.from("refunds")
      .select("id, moyasar_payment_id, amount, status").eq("id", id).maybeSingle();
    return (data as RefundRow | null) ?? null;
  },
  async markProcessing(id) {
    await admin.from("refunds").update({ status: "processing" }).eq("id", id);
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_refund", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
```

Append to `supabase/config.toml`:

```toml
[functions.refund-payment]
# Called by the refunds trigger through pg_net, which cannot present a Supabase
# JWT. The function's own shared-secret check is the gate.
verify_jwt = false
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 6 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/refund-payment supabase/config.toml
git commit -m "feat(payments): refund-payment sends back exactly what the row says"
```

---

### Task 7: The webhook carries the refunded total

**Files:**
- Modify: `supabase/functions/moyasar-webhook/handler.ts`, `handler_test.ts`

**Interfaces:**
- Consumes: `settle_payment` with its seventh argument (Task 2), `MoyasarPayment.refunded` (Task 5).
- Produces: `SettleArgs` gains `p_refunded_total: number`.

- [ ] **Step 1: Write the failing test**

Append to `supabase/functions/moyasar-webhook/handler_test.ts`:

```ts
Deno.test("a refund webhook carries Moyasar's cumulative refunded total", async () => {
  const d = deps();
  const settled: Array<Record<string, unknown>> = [];
  d.moyasar.fetchPayment = async () => ({
    ...remote, status: "refunded", refunded: 12000,
  });
  d.settle = async (a: Record<string, unknown>) => { settled.push(a); return { status: "refunded" }; };
  await makeHandler(d)(post(evt("wh-refund-1")));
  assertEquals(settled[0].p_moyasar_status, "refunded");
  assertEquals(settled[0].p_refunded_total, 12000);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net --allow-env supabase/functions/moyasar-webhook/`
Expected: FAIL — `p_refunded_total` is `undefined`

- [ ] **Step 3: Implement**

In `supabase/functions/moyasar-webhook/handler.ts`, add the field to `SettleArgs`:

```ts
export type SettleArgs = {
  p_payment_id: string; p_moyasar_payment_id: string; p_moyasar_status: string;
  p_payment_method: string | null; p_amount: number; p_currency: string;
  /// Cumulative, from Moyasar. A partial refund reports status "refunded" too,
  /// so the figure is what tells settle_payment how much actually went back.
  p_refunded_total: number;
};
```

and pass it in the settle call:

```ts
    const result = await deps.settle({
      p_payment_id: row.id, p_moyasar_payment_id: remote.id, p_moyasar_status: remote.status,
      p_payment_method: remote.source?.type ?? null, p_amount: remote.amount,
      p_currency: remote.currency, p_refunded_total: remote.refunded ?? 0,
    });
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 6 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/moyasar-webhook
git commit -m "feat(payments): the webhook tells settle how much really went back"
```

---

### Task 8: Telling the payer

**Files:**
- Modify: `supabase/functions/send-push/copy.ts`, `copy_test.ts`

**Interfaces:**
- Produces: `copyFor("refund_issued", eventName)`.
- Consumes: the `refund_issued` row `settle_refund` enqueues (Task 1).

- [ ] **Step 1: Write the failing test**

Append to `supabase/functions/send-push/copy_test.ts`:

```ts
Deno.test("refund_issued copy interpolates the event name", () => {
  const c = copyFor("refund_issued", "تمرين كرة قدم");
  assertEquals(c, {
    title: "رجعت لك قطتك 💳",
    body: "استرجعنا قطة تمرين كرة قدم إلى بطاقتك. تصل خلال أيام قليلة حسب بنكك.",
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts`
Expected: FAIL — `copyFor` returned `null`

- [ ] **Step 3: Add the copy**

In `supabase/functions/send-push/copy.ts`, after the `payment_paid` case:

```ts
    case "refund_issued":
      return {
        title: "رجعت لك قطتك 💳",
        body: `استرجعنا قطة ${eventName} إلى بطاقتك. تصل خلال أيام قليلة حسب بنكك.`,
      };
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 21 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(payments): tell the payer their money is on its way back"
```

---

### Task 9: Swift — one tap to Apple Pay

**Files:**
- Modify: `Sirr/features/home/EventDetailView.swift`
- Modify: `Sirr/Components/ApplePayButton.swift`

**Interfaces:**
- Consumes: `MoyasarPaymentService.startPayment`, `CardPaymentQuote`, `ApplePayButton`, `CardPaymentSheet` (all existing).
- Produces: no new types. `EventDetailView` gains `@State private var payQuote: CardPaymentQuote?` and `@State private var showCardSheet = false`.

**Why this shape:** the control that starts an Apple Pay transaction has to be the system button. Apple's guidelines forbid a custom button that starts Apple Pay from showing the Apple Pay name or logo, and forbid imitating the system button. Using the real one is also what puts the Apple mark on it, which is the ask.

- [ ] **Step 1: Make the Apple Pay button usable on a dark card row**

In `Sirr/Components/ApplePayButton.swift`, the body currently hard-codes a height. Give it the same 48pt height the other primary actions use and let the caller own the padding — it already does both, so the only change is to confirm no change is needed. Verify by reading the file; if `frame(height: 48)` is present, move to Step 2.

- [ ] **Step 2: Fetch the quote where the button lives**

In `Sirr/features/home/EventDetailView.swift`, next to the other `@State` declarations of `EventDetailView` (around line 29, beside `showPaymentReview`), add:

```swift
    /// The server's quote for what this member owes on this workout. Fetched
    /// here rather than inside the payment sheet, because the pay control's
    /// identity now depends on it: with a quote and Apple Pay it becomes the
    /// system Apple Pay button, and without one it opens the manual flow.
    @State private var payQuote: CardPaymentQuote?
    @State private var showCardSheet = false
```

On the same view's root, beside its existing `.task`, add:

```swift
        .task(id: occurrence.id) {
            guard occurrence.price > 0, !occurrence.isCancelled else { return }
            if case .ready(let quote) = try? await MoyasarPaymentService.shared
                .startPayment(eventId: occurrence.id) {
                payQuote = quote
            } else {
                payQuote = nil
            }
        }
        .sheet(isPresented: $showCardSheet) {
            CardPaymentSheet(eventId: occurrence.id, eventName: occurrence.title) {
                Task { await feed.markCardPaid(for: occurrence) }
            }
        }
```

- [ ] **Step 3: Replace the pay button with the three-way control**

In the same file, the member's outstanding-payment branch currently reads (around line 916):

```swift
                    if mine.status == .awaitingPayment, occurrence.price > 0 {
                        Button {
                            Haptics.impact(.light)
                            showPaymentReview = true
                        } label: {
                            Label("دفع القطة", systemImage: "banknote.fill")
                                .font(TamrinFont.font(size: 16, weight: .bold))
```

Replace the whole `if mine.status == .awaitingPayment, occurrence.price > 0 { … }` block with:

```swift
                    if mine.status == .awaitingPayment, occurrence.price > 0 {
                        if let payQuote, ApplePayButton.isAvailable {
                            // The system button, because Apple requires the
                            // control that starts a payment to be theirs. It
                            // carries the Apple mark for us.
                            ApplePayButton(quote: payQuote, eventName: occurrence.title) { outcome in
                                handleApplePay(outcome, quote: payQuote)
                            }
                        } else if payQuote != nil {
                            Button {
                                Haptics.impact(.light)
                                showCardSheet = true
                            } label: {
                                Label("ادفع بالبطاقة", systemImage: "creditcard.fill")
                                    .font(TamrinFont.font(size: 16, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(.white, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                Haptics.impact(.light)
                                showPaymentReview = true
                            } label: {
                                Label("دفع القطة", systemImage: "banknote.fill")
                                    .font(TamrinFont.font(size: 16, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(.white, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
```

If the surrounding label styling in the file differs from the `.foregroundStyle/.frame/.background` above, copy the styling from the button being replaced rather than the styling written here — the point is the three branches, not the paint.

- [ ] **Step 4: Handle the Apple Pay answer at this level**

`handleApplePay` already exists inside `RegistrationFlowSheet`. `EventDetailView` needs its own, because this button is outside that sheet. Add it to `EventDetailView`, next to its other private helpers:

```swift
    /// Apple Pay answered. Authorized is not paid: only verify-payment on the
    /// server decides whether the money is captured and the seat confirmed.
    private func handleApplePay(_ outcome: CardPaymentOutcome, quote: CardPaymentQuote) {
        switch outcome {
        case .cancelled:
            break
        case .failed(let message):
            Haptics.error()
            actionErrorMessage = message
        case .authorized(let moyasarPaymentId):
            Task {
                do {
                    let verdict = try await MoyasarPaymentService.shared.verifyUntilSettled(
                        paymentId: quote.paymentId,
                        moyasarPaymentId: moyasarPaymentId
                    )
                    switch verdict {
                    case .paid:
                        Haptics.success()
                        await feed.markCardPaid(for: occurrence)
                        payQuote = nil
                    case .processing:
                        actionErrorMessage = "تأخر التحقق من الدفع. سيتأكد مقعدك تلقائيًا عند وصول التأكيد."
                    case .failed(let reason):
                        Haptics.error()
                        actionErrorMessage = reason == "amount" || reason == "recipient"
                            ? "تعذر التحقق من الدفع. لم يُخصم أي مبلغ."
                            : "لم تنجح عملية الدفع."
                    }
                } catch {
                    actionErrorMessage = ServerErrorMessage.arabic(for: error)
                }
            }
        }
    }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sirr/features/home/EventDetailView.swift Sirr/Components/ApplePayButton.swift
git commit -m "feat(payments): pay opens Apple Pay in one tap"
```

---

### Task 10: Swift — removing your own guest

**Files:**
- Modify: `Sirr/core/supabase/EventService.swift`
- Modify: `Sirr/features/home/MockHomeFeed.swift`
- Modify: `Sirr/features/home/EventDetailView.swift`

**Interfaces:**
- Consumes: `public.remove_my_guest(uuid)` (Task 3).
- Produces: `EventService.removeMyGuest(participantId: UUID) async throws -> RemoveParticipantResult`; `MockHomeFeed.removeMyGuest(_ member: FeedMember, from occurrence: FeedOccurrence) async -> RegistrationOutcome`.

- [ ] **Step 1: Add the service call**

In `Sirr/core/supabase/EventService.swift`, directly after `removeParticipant(participantId:)`, add:

```swift
    /// The player's own version of `removeParticipant`. The server checks that
    /// the caller is the one who added this guest, and returns their share of
    /// the payment when the workout has not started.
    func removeMyGuest(participantId: UUID) async throws -> RemoveParticipantResult {
        let params: [String: String] = ["p_participant_id": participantId.uuidString]

        let response = try await client
            .rpc("remove_my_guest", params: params)
            .execute()

        guard
            let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = payload["status"] as? String
        else {
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
            )
        }

        eventLogger.info("API removeMyGuest: \(status)")
        switch status {
        case "removed": return .removed
        case "not_found": return .notFound
        default:
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "رد غير متوقع من الخادم: \(status)"]
            )
        }
    }
```

- [ ] **Step 2: Add the view-model method**

In `Sirr/features/home/MockHomeFeed.swift`, immediately after `markCardPaid(for:)`, add:

```swift
    /// Removing a guest you added. The server frees the seat and, when the
    /// workout has not started and the seat was paid by card, returns that
    /// seat's share. The money is the server's business; this only refreshes
    /// what the roster shows.
    func removeMyGuest(
        _ member: FeedMember,
        from occurrence: FeedOccurrence
    ) async -> RegistrationOutcome {
        guard !isPreview else {
            rosterCache[occurrence.id]?.removeAll { $0.id == member.id }
            return .success
        }
        do {
            switch try await EventService.shared.removeMyGuest(participantId: member.id) {
            case .removed, .notFound:
                await reloadRoster(occurrence.id)
                if let workspaceID = teamID(for: occurrence) {
                    Task { await loadTeamData(workspaceID) }
                }
                return .success
            case .isCreator:
                return .failure("لا يمكن إزالة هذا المقعد.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
```

- [ ] **Step 3: Offer it in the roster**

In `Sirr/features/home/EventDetailView.swift`, find where a roster row's actions are built for the member's own view. Add, for any row where `member.isGuest`, `member.addedBy == feed.currentUserID` and `!member.isManual`:

```swift
                    Button(role: .destructive) {
                        Task {
                            let outcome = await feed.removeMyGuest(member, from: occurrence)
                            if case .failure(let message) = outcome {
                                actionErrorMessage = message
                            }
                        }
                    } label: {
                        Label("إزالة الضيف", systemImage: "person.badge.minus")
                    }
```

`feed.currentUserID` is the property `setMyStatus` already compares against; use the same expression the file uses nearby rather than inventing a name.

- [ ] **Step 4: Say what happens to the money before they commit**

In the withdrawal sheet (`MemberDeclineSheet`, presented from `showWithdrawConfirm`), add a line above its confirm button:

```swift
                Text(refundNoticeForWithdrawal)
                    .font(TamrinFont.font(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
```

with, on `EventDetailView`:

```swift
    /// Stated before the tap, not after. Which of these is true is decided by
    /// the server when the withdrawal actually happens; this is the honest
    /// description of the rule, not a prediction of the outcome.
    private var refundNoticeForWithdrawal: String {
        guard occurrence.price > 0 else { return "" }
        if payQuote == nil && mine?.status == .registered {
            return "إن كنت قد دفعت بالبطاقة فسيُسترجع المبلغ إلى بطاقتك. التحويل البنكي يُرتَّب مع المشرف."
        }
        if Date.now >= occurrence.startAt {
            return "بدأ التمرين، فلن يُسترجع المبلغ."
        }
        return "سيُسترجع ما دفعته بالبطاقة إلى بطاقتك."
    }
```

If `mine` is not the name this file uses for the member's own roster row, use whatever it already calls it in the surrounding branch.

- [ ] **Step 5: Build**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit and hand over for device testing**

```bash
git add Sirr/core/supabase/EventService.swift Sirr/features/home/MockHomeFeed.swift Sirr/features/home/EventDetailView.swift
git commit -m "feat(payments): remove a guest you added, and get that seat back"
```

Hand-over checklist, on a real device against the sandbox, with a workout whose
total lands between 200 and 300 SAR:

1. Pay by Apple Pay in one tap from the workout screen, with no chooser in between.
2. Withdraw before the start. `refunds` shows one `done` row, `payments.refunded_amount` equals the amount, `status` is `refunded`, and the refund push arrives.
3. Pay for yourself and one guest, remove the guest, and check that exactly half comes back and the payment stays `paid`.
4. Withdraw after the start. The seat frees, `refunds` is empty for it, and the sheet said so beforehand.
5. As the organizer, cancel a workout people paid for. Every card payer gets a `done` refund row.
6. A workspace with no Moyasar recipient still shows the old manual flow untouched.

---

### Task 11: Secrets, deployment, and the runbook

**Files:**
- Modify: `PAYMENT_SETUP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Set the shared secret and the vault entries**

The function reads `REFUND_PAYMENT_SECRET`; Postgres reads the URL and the same
secret from the vault. Both sides must hold the identical value.

```bash
SECRET=$(openssl rand -hex 32) && echo "$SECRET" && supabase secrets set --project-ref kpcdinxusxycenfnitjc REFUND_PAYMENT_SECRET="$SECRET"
```

Then, in the sandbox SQL editor as service_role, with the value that printed:

```sql
select vault.create_secret(
  'https://kpcdinxusxycenfnitjc.supabase.co/functions/v1/refund-payment',
  'refund_payment_url'
);
select vault.create_secret('PASTE_THE_SECRET_HERE', 'refund_payment_secret');
```

- [ ] **Step 2: Push the migrations and deploy**

```bash
supabase db push --linked
supabase functions deploy refund-payment moyasar-webhook send-push --project-ref kpcdinxusxycenfnitjc
```

`moyasar-webhook` is redeployed because Task 7 changed it, and `send-push`
because Task 8 changed its copy.

- [ ] **Step 3: Schedule the retry sweep**

In the sandbox SQL editor:

```sql
select cron.schedule(
  'retry-pending-refunds',
  '*/5 * * * *',
  $$ select public.retry_pending_refunds(); $$
);
```

- [ ] **Step 4: Write the runbook section**

Append to `PAYMENT_SETUP.md`:

```markdown
## Refunds

Money goes back automatically in three cases: a player withdraws before the
workout starts, a player removes a guest they paid for, or the organizer cancels.
Card payments only. A bank transfer never passed through Tamrin, so there is
nothing for the app to send back.

A refund is a row in `public.refunds` before it is an API call. The amount is
worked out in the same transaction that frees the seat, because freeing it
destroys the evidence of what it cost. An `AFTER INSERT` trigger posts the row id
to the `refund-payment` function, which holds the secret key and calls
`POST /v1/payments/{id}/refund`.

Two secrets, and they must match:

    supabase secrets set --project-ref <ref> REFUND_PAYMENT_SECRET=<value>

    select vault.create_secret('https://<ref>.supabase.co/functions/v1/refund-payment',
                               'refund_payment_url');
    select vault.create_secret('<the same value>', 'refund_payment_secret');

Without the vault entries the trigger silently does nothing, which keeps a local
stack green but means **no refund is ever sent**. If refunds sit `pending` on a
deployed project, check the vault first.

The sweep `retry_pending_refunds()` re-fires anything still waiting after three
minutes, up to five attempts. Schedule it every five minutes with pg_cron.

To see what is stuck:

    select status, count(*), sum(amount) from public.refunds group by status;
    select * from public.refunds where status = 'failed' order by created_at desc;

A `failed` row carries Moyasar's own message. The commonest causes are a payment
already refunded in full, and a split whose share has already been settled to the
organizer.
```

- [ ] **Step 5: Commit**

```bash
git add PAYMENT_SETUP.md
git commit -m "docs: how refunds are wired, and what to check when one is stuck"
```

---

## Self-review

**Spec coverage:** automatic refund with no approval → T1–T4; the before-start
window → T3; partial refunds → T1 (`refunded_amount`), T2 (`request_refund`
clamp), T3 (`remove_my_guest`); the player removing their own guest → T3, T10;
full refunds on cancellation → T3; the outbox and retry → T4; the Moyasar call →
T5, T6; reconciling a dashboard refund → T2 (`settle_payment`), T7; telling the
payer → T8; one tap to Apple Pay with the card and manual fallbacks → T9;
withdrawal copy → T10; secrets, deploy and the runbook → T11.

**Deliberately not here:** refunding a manual transfer, which the app cannot do;
an organizer-facing refunds screen, which the spec does not ask for and which RLS
already permits once someone designs it; and partial refunds initiated by the
organizer, since `remove_event_participant` keeps today's behaviour and only the
player's path refunds.

**Type consistency:** `settle_refund(uuid, text, int, text)` is identical in T1,
T6's `settle` dep and T6's tests. `settle_payment`'s seventh parameter is added
in T2 and supplied in T7, and every six-argument caller still resolves through
the default. `request_refund(uuid, int, int, text)` is defined in T2 and called
in T3 only. `CardPaymentOutcome` and `verifyUntilSettled` in T9 are the existing
Swift names. `RemoveParticipantResult` in T10 is the existing enum, and its three
cases are all handled.
