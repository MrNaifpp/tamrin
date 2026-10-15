-- Production go-live bundle, staging without card payments.
--
-- Run ONCE in production's SQL editor. Everything between begin and commit
-- lands together or not at all: if any statement fails, nothing is applied.
--
-- What it applies (production lacked all of these on 2026-10-14):
--   the twelve migrations below, verbatim from supabase/migrations/;
--   a stand-in for 20260929120000's unpaid_debt_event (the debt rule is held
--   back; 20261002100000 calls the helper, so it has to exist);
--   rows in schema_migrations, so the record matches what actually ran.
--
-- The payment tables arrive empty and stay empty: no Moyasar functions are
-- deployed to production and the app does not offer cards there. The refund
-- trigger reads vault entries production does not have, so it does nothing.
--
-- NOT included, on purpose: 20260929120000_unpaid_workout_blocks_registration.

begin;

-- ===== 20260919100000_moyasar_payments =====
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

-- ===== 20260919110000_card_payment_rpcs =====
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

-- ===== 20260921100000_card_payment_without_recipient =====
-- Let a card payment proceed with no verified Moyasar recipient — but only
-- when the caller explicitly asks for it.
--
-- Why this exists: splits need a recipient id, and Moyasar has not issued one
-- yet (docs/moyasar-support-questions.md). Until they do, no card or Apple Pay
-- payment can be exercised at all, which leaves the whole flow untestable on a
-- real device.
--
-- What it costs: a payment with no split settles into Tamrin's own Moyasar
-- account rather than the organizer's. That is a different commercial
-- arrangement, and whether Tamrin may hold the money at all is still an open
-- question with Moyasar. So the parameter defaults to FALSE and the only
-- caller that passes TRUE is the create-payment Edge Function on the sandbox,
-- where ALLOW_PAYMENTS_WITHOUT_RECIPIENT is set. Production never sets it, so
-- production behaviour is byte-for-byte what it was.
--
-- A verified recipient still wins whenever one exists.

drop function if exists public.begin_card_payment(uuid, uuid);

create or replace function public.begin_card_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_allow_without_recipient boolean default false
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

  -- The gate. Closed unless the caller opened it.
  if v_recipient.workspace_id is null and not p_allow_without_recipient then
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

  -- recipient_id is null when there is none, and verify-payment reads the
  -- stored split_recipient_id, so a payment authorized without a split is
  -- checked without one too. Amount and currency are still enforced.
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

revoke execute on function public.begin_card_payment(uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.begin_card_payment(uuid, uuid, boolean) to service_role;

-- ===== 20260922100000_refunds =====
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

-- ===== 20260922110000_refund_triggers =====
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
    -- A partial refund also arrives as "refunded", so the figure decides rather
    -- than the word. A caller that gives no figure is saying "I was not told",
    -- and the only safe reading of an untotalled refund is that all of it went
    -- back: leaving the seats confirmed would let someone keep a seat they have
    -- already been repaid for. Anything Moyasar refunded that we did not issue
    -- ourselves is absorbed here too, which is how a dashboard refund lands.
    v_total := case
                 when coalesce(p_refunded_total, 0) > 0
                   then least(p_refunded_total, v_payment.amount)
                 else v_payment.amount
               end;
    v_total := greatest(v_total, v_payment.refunded_amount);
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

-- Dropped first so the whole file stays re-appliable: everything else in it is
-- `create or replace`, and a bare create trigger would abort a second run and
-- take the cron schedule below down with it.
drop trigger if exists trg_fire_refund_outbox on public.refunds;
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

-- ===== 20260922120000_schedule_refund_sweep =====
-- The refund sweep's schedule, in a migration of its own.
--
-- It started life inside 20260922110000, which had already been applied to the
-- sandbox by the time the schedule was added. Supabase records a migration by
-- its version and never re-runs it, so editing that file could not deliver
-- this. A new version can, on every environment, with no hand-run SQL.
--
-- Unschedule by name first: this file is re-applied on every local rebuild, and
-- cron.schedule refuses a duplicate job name. Same shape as recurring-events.
do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'retry-pending-refunds'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;

  perform cron.schedule(
    'retry-pending-refunds',
    '*/5 * * * *',
    $cron$select public.retry_pending_refunds();$cron$
  );
end;
$$;

-- ===== 20260929100000_pay_for_guests_added_after_paying =====
-- A guest added after paying could never be paid for.
--
-- begin_card_payment returned "already_paid" whenever the caller had ANY paid
-- payment on the workout, and it did so before counting what was still owed.
-- A member who paid for themselves and then brought a guest was stuck: the
-- guest's seat stayed pending, a past workout lingered on Home with a pay
-- button, and every tap came back "already paid" and quietly did nothing.
--
-- That early return never prevented a double charge. The seat count only ever
-- includes seats still `pending`, and a paid seat is `confirmed`, so a seat a
-- payment already covers cannot be priced twice. The check moves to where it
-- belongs: "already paid" now means nothing is left owing, and a paid payment
-- is why. Anything still owed gets a payment of its own.

create or replace function public.begin_card_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_allow_without_recipient boolean default false
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

  -- The gate. Closed unless the caller opened it.
  if v_recipient.workspace_id is null and not p_allow_without_recipient then
    return json_build_object('status', 'recipient_not_onboarded');
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
    -- Nothing left owing. Say "already paid" when a paid payment is the
    -- reason, so the app can show the paid state instead of a bare no-op.
    if exists (
      select 1 from public.payments
      where event_id = p_event_id and user_id = p_user_id and status = 'paid'
    ) then
      return json_build_object('status', 'already_paid');
    end if;
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

  -- recipient_id is null when there is none, and verify-payment reads the
  -- stored split_recipient_id, so a payment authorized without a split is
  -- checked without one too. Amount and currency are still enforced.
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

revoke execute on function public.begin_card_payment(uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.begin_card_payment(uuid, uuid, boolean) to service_role;

-- ===== 20260929110000_add_guests_while_one_is_unpaid =====
-- Adding a second guest was refused while the first was still unpaid.
--
-- register_event_guest_batch_impl answered 'pending_guest_request' whenever the
-- member had any pending guest on a paid workout. That rule dates from manual
-- transfers, where "pending" meant a transfer waiting on the organizer and
-- confirm_payment settles every pending row of a payer at once. Card payment
-- changed what pending means: a guest is pending simply because nobody has paid
-- for them yet, and there is no organizer involved. So a member bringing a
-- second guest was told to wait for an organizer who had nothing to confirm.
--
-- The block now applies only while a declared transfer is actually waiting
-- (payment_declared_at set). Everything else about the function is unchanged.

CREATE OR REPLACE FUNCTION public.register_event_guest_batch_impl(p_event_id uuid, p_guest_names text[], p_expected_payment_method_id uuid, p_expected_price_per_person numeric, p_payment_method_id uuid, p_guest_only boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_current_seats int;
  v_guests text[];
  v_group_size int;
  v_duplicate_name text;
  v_self_status text;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if p_guest_only is null then
    raise exception 'Guest registration mode is required';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;

  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select ep.payment_status
  into v_self_status
  from public.event_participants ep
  where ep.event_id = p_event_id
    and ep.user_id = v_uid
    and ep.payment_status in ('pending', 'confirmed')
  limit 1;

  if p_guest_only then
    if v_self_status = 'confirmed' then
      return json_build_object(
        'status', 'self_already_registered',
        'payment_status', v_self_status
      );
    elsif v_self_status = 'pending' then
      return json_build_object(
        'status', 'self_registration_pending',
        'payment_status', v_self_status
      );
    elsif exists (
      select 1
      from public.event_waitlist wl
      where wl.event_id = p_event_id
        and wl.user_id = v_uid
    ) then
      return json_build_object(
        'status', 'self_registration_pending',
        'payment_status', 'waitlisted'
      );
    end if;
  elsif v_self_status is null then
    -- A seat is enough. v_self_status is selected only from
    -- ('pending', 'confirmed'), so null is the one case with no seat at all.
    return json_build_object('status', 'not_registered');
  end if;

  with normalized as (
    select
      input.ordinality,
      left(
        btrim(regexp_replace(coalesce(input.name, ''), '\s+', ' ', 'g')),
        60
      ) as name
    from unnest(coalesce(p_guest_names, '{}'::text[]))
      with ordinality as input(name, ordinality)
  )
  select coalesce(array_agg(name order by ordinality), '{}'::text[])
  into v_guests
  from normalized
  where name <> '';

  v_group_size := coalesce(cardinality(v_guests), 0);
  if v_group_size = 0 then
    return json_build_object('status', 'empty_guests');
  end if;

  -- confirm_payment/reject_payment address pending rows by added_by, so a batch
  -- added while a DECLARED transfer waits on the organizer would be confirmed
  -- under a transfer that never covered it. That, and only that, must wait.
  -- An unpaid batch nobody has declared anything for is just money owed: a
  -- second batch joins it, and one payment (card or transfer) covers both.
  if v_event.total_price > 0 and exists (
    select 1
    from public.event_participants ep
    where ep.event_id = p_event_id
      and ep.user_id is null
      and ep.added_by = v_uid
      and not ep.added_manually
      and ep.payment_status = 'pending'
      and ep.payment_declared_at is not null
  ) then
    return json_build_object('status', 'pending_guest_request');
  end if;

  select min(requested.name)
  into v_duplicate_name
  from unnest(v_guests) as requested(name)
  group by lower(requested.name)
  having count(*) > 1
  limit 1;

  if v_duplicate_name is not null then
    return json_build_object(
      'status', 'duplicate_name',
      'name', v_duplicate_name
    );
  end if;

  select existing.guest_name
  into v_duplicate_name
  from public.event_participants existing
  join unnest(v_guests) as requested(name)
    on lower(existing.guest_name) = lower(requested.name)
  where existing.event_id = p_event_id
    and existing.user_id is null
    and existing.added_by = v_uid
    and not existing.added_manually
    and existing.payment_status in ('pending', 'confirmed')
  limit 1;

  if v_duplicate_name is not null then
    return json_build_object(
      'status', 'duplicate_name',
      'name', v_duplicate_name
    );
  end if;

  -- p_payment_method_id and p_expected_payment_method_id are still accepted so
  -- the wire contract does not change, but a method is no longer part of
  -- registering. Only the price is still worth guarding: the organizer may
  -- have changed it while the sheet was open.
  if p_expected_price_per_person is not null
    and abs(
      p_expected_price_per_person - coalesce(v_event.price_per_person, 0)
    ) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  if v_event.max_participants is not null then
    select count(*) into v_current_seats
    from public.event_participants
    where event_id = p_event_id
      and payment_status in ('pending', 'confirmed');

    if v_current_seats + v_group_size > v_event.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  if v_event.total_price <= 0 then
    insert into public.event_participants (
      event_id,
      user_id,
      guest_name,
      added_by,
      added_manually,
      guest_only,
      payment_status,
      paid_price_per_person
    )
    select
      p_event_id,
      null,
      guest.name,
      v_uid,
      false,
      p_guest_only,
      'confirmed',
      v_event.price_per_person
    from unnest(v_guests) as guest(name);

    return json_build_object(
      'status', 'submitted',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', v_group_size,
      'guest_only', p_guest_only
    );
  end if;

  -- The seat first, exactly as register_event_seat does for the member's own.
  -- No method is chosen or snapshotted here: declare_event_payment stamps
  -- these rows together with the member's seat when «دفع القطة» is pressed,
  -- and it already matches guests through (user_id is null and added_by = uid).
  --
  -- Nothing is owed to a destination yet, so a paid event whose organizer has
  -- not added a method no longer blocks the seat — same as self registration.
  insert into public.event_participants (
    event_id,
    user_id,
    guest_name,
    added_by,
    added_manually,
    guest_only,
    payment_status,
    payment_declared_at,
    paid_price_per_person
  )
  select
    p_event_id,
    null,
    guest.name,
    v_uid,
    false,
    p_guest_only,
    'pending',
    null,
    v_event.price_per_person
  from unnest(v_guests) as guest(name);

  -- Deliberately no push. 'payment_submitted' reads "وصلك طلب دفع جديد… راجعه
  -- وأكّده", which would ask the organizer to confirm a transfer nobody has
  -- declared. declare_event_payment sends 'payment_declared' when one is.
  return json_build_object(
    'status', 'submitted',
    'creator_id', v_event.creator_id,
    'event_id', v_event.id,
    'payment_method_id', null,
    'provider', null,
    'mobile_number', null,
    'iban', null,
    'account_number', null,
    'payment_methods', '[]'::jsonb,
    'total_price', v_event.total_price,
    'price_per_person', v_event.price_per_person,
    'group_size', v_group_size,
    'guest_only', p_guest_only
  );
end;
$function$;

-- ===== 20261001100000_preserve_seats_on_payment_reset =====
-- Reset only a reported transfer, before or after an exercise ends.
-- Existing confirm_payment already supports ended exercises.

CREATE OR REPLACE FUNCTION public.reject_payment(p_event_id uuid, p_user_id uuid, p_creator_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_changed_rows integer := 0;
  v_revoked_future_seats integer := 0;
  v_series_key uuid;
  v_waiters json := '[]'::json;
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  if v_event.template_id is not null then
    select series_key into v_series_key
    from public.event_templates
    where id = v_event.template_id;
    if v_series_key is not null then
      perform pg_advisory_xact_lock(hashtextextended(v_series_key::text, 0));
    end if;
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  -- A payment decision never changes attendance, including guests and history.
  update public.event_participants
  set payment_declared_at = null
  where event_id = p_event_id
    and (user_id = p_user_id or (user_id is null and added_by = p_user_id))
    and payment_status = 'pending'
    and payment_declared_at is not null;
  get diagnostics v_changed_rows = row_count;

  if v_changed_rows = 0 then
    return json_build_object(
      'status', 'no_pending_row',
      'waiter_ids', '[]'::json
    );
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  return json_build_object(
    'status', 'rejected',
    'joiner_id', p_user_id,
    'revoked_future_seats', v_revoked_future_seats,
    'waiter_ids', v_waiters
  );
end;
$function$;

revoke execute on function public.reject_payment(uuid, uuid, uuid) from public, anon;
grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

-- New clients must not fall back to a pre-migration RPC that deletes seats.
create or replace function public.reset_payment_declaration(
  p_event_id uuid, p_user_id uuid, p_creator_id uuid
) returns json
language sql security invoker set search_path = public
as $$ select public.reject_payment(p_event_id, p_user_id, p_creator_id); $$;
revoke execute on function public.reset_payment_declaration(uuid, uuid, uuid) from public, anon;
grant execute on function public.reset_payment_declaration(uuid, uuid, uuid) to authenticated;

notify pgrst, 'reload schema';

-- ===== stand-in for 20260929120000 (held back) =====
create or replace function public.unpaid_debt_event(p_workspace_id uuid, p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select null::uuid
$$;

revoke execute on function public.unpaid_debt_event(uuid, uuid)
  from public, anon, authenticated;

-- ===== 20261001110000_player_rating_changes =====
-- Last meaningful movement of the anonymous workspace rating. No rater IDs
-- or per-rater scores are exposed by this table or the summary payload.
create table public.player_rating_changes (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  ratee_id uuid not null references auth.users(id) on delete cascade,
  position text not null,
  previous_overall integer not null check (previous_overall between 0 and 100),
  current_overall integer not null check (current_overall between 0 and 100),
  changed_at timestamptz not null default now(),
  primary key (workspace_id, ratee_id),
  check (previous_overall <> current_overall)
);
alter table public.player_rating_changes enable row level security;
revoke all on public.player_rating_changes from public, anon, authenticated;

create or replace function public.get_player_rating(
  p_workspace_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_position text;
  v_mine public.player_ratings;
  v_count integer;
  v_avg record;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if not public.is_workspace_member(p_workspace_id, p_user_id) then
    raise exception 'Player is not a workspace member';
  end if;

  select usr.postion into v_position
  from public.users usr
  where usr.user_id = p_user_id;

  select * into v_mine
  from public.player_ratings
  where workspace_id = p_workspace_id
    and rater_id = v_uid
    and ratee_id = p_user_id;

  select count(*) into v_count
  from public.player_ratings
  where workspace_id = p_workspace_id and ratee_id = p_user_id;

  if v_count = 0 then
    return json_build_object(
      'position', coalesce(v_position, ''),
      'has_rated', false,
      'ratings_count', 0,
      'mine', null,
      'average', null
    );
  end if;

  select
    avg(pace) as pace,
    avg(passing) as passing,
    avg(shooting) as shooting,
    avg(stamina) as stamina,
    avg(defending) as defending,
    avg(awareness) as awareness,
    round(avg(public.player_rating_overall(
      v_position, pace, passing, shooting, stamina, defending, awareness
    )))::integer as overall
  into v_avg
  from public.player_ratings
  where workspace_id = p_workspace_id and ratee_id = p_user_id;

  return json_build_object(
    'position', coalesce(v_position, ''),
    'has_rated', v_mine.ratee_id is not null,
    'ratings_count', v_count,
    'mine', case when v_mine.ratee_id is null then null else json_build_object(
        'pace', v_mine.pace,
        'passing', v_mine.passing,
        'shooting', v_mine.shooting,
        'stamina', v_mine.stamina,
        'defending', v_mine.defending,
        'awareness', v_mine.awareness,
        'overall', public.player_rating_overall(
          v_position, v_mine.pace, v_mine.passing, v_mine.shooting,
          v_mine.stamina, v_mine.defending, v_mine.awareness
        ),
        'updated_at', v_mine.updated_at
      ) end,
    -- Attribute averages explain the score. The Overall itself follows the
    -- product rule literally: calculate and round each submitted Overall, then
    -- average those whole-number results and round the final mean.
    'trend', (
      select json_build_object(
        'previous_overall', change.previous_overall,
        'current_overall', change.current_overall,
        'delta', change.current_overall - change.previous_overall,
        'changed_at', change.changed_at
      )
      from public.player_rating_changes change
      where change.workspace_id = p_workspace_id and change.ratee_id = p_user_id
        and change.position = coalesce(v_position, '')
        and change.current_overall = v_avg.overall
    ),
    'average', json_build_object(
      'pace', round(v_avg.pace),
      'passing', round(v_avg.passing),
      'shooting', round(v_avg.shooting),
      'stamina', round(v_avg.stamina),
      'defending', round(v_avg.defending),
      'awareness', round(v_avg.awareness),
      'overall', v_avg.overall
    )
  );
end;
$$;

revoke execute on function public.get_player_rating(uuid, uuid) from public, anon;
grant execute on function public.get_player_rating(uuid, uuid) to authenticated;

-- --------------------------------------------------------------------------
-- submit_player_rating: one row per (workspace, rater, player), re-submittable.
--
-- Refusals come back as a status string rather than an exception so the sheet
-- can say precisely what happened, in the same shape as the other RPCs here.
-- --------------------------------------------------------------------------
create or replace function public.submit_player_rating(
  p_workspace_id uuid,
  p_user_id uuid,
  p_pace smallint,
  p_passing smallint,
  p_shooting smallint,
  p_stamina smallint,
  p_defending smallint,
  p_awareness smallint
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_position text;
  v_before integer;
  v_after integer;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if p_user_id = v_uid then
    return json_build_object('status', 'is_self');
  end if;
  if not public.is_workspace_member(p_workspace_id, p_user_id) then
    return json_build_object('status', 'not_a_member');
  end if;
  select usr.postion into v_position
  from public.users usr
  where usr.user_id = p_user_id for share;
  if coalesce(trim(v_position), '') not in ('حارس', 'دفاع', 'وسط', 'هجوم') then
    return json_build_object('status', 'position_required');
  end if;
  if num_nonnulls(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) <> 6
     or least(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) < 0
     or greatest(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) > 100 then
    return json_build_object('status', 'out_of_range');
  end if;

  -- Serialize all raters of this player, not only edits by one rater.
  -- The aggregate before/after and its indicator commit together.
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || p_user_id::text, 917));
  select round(avg(public.player_rating_overall(
    v_position, pace, passing, shooting, stamina, defending, awareness
  )))::integer into v_before
  from public.player_ratings where workspace_id = p_workspace_id and ratee_id = p_user_id;

  insert into public.player_ratings (
    workspace_id, rater_id, ratee_id,
    pace, passing, shooting, stamina, defending, awareness
  )
  values (
    p_workspace_id, v_uid, p_user_id,
    p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness
  )
  on conflict (workspace_id, rater_id, ratee_id) do update
  set pace = excluded.pace,
      passing = excluded.passing,
      shooting = excluded.shooting,
      stamina = excluded.stamina,
      defending = excluded.defending,
      awareness = excluded.awareness,
      updated_at = now()
  where (player_ratings.pace, player_ratings.passing, player_ratings.shooting,
         player_ratings.stamina, player_ratings.defending, player_ratings.awareness)
    is distinct from
        (excluded.pace, excluded.passing, excluded.shooting,
         excluded.stamina, excluded.defending, excluded.awareness);

  select round(avg(public.player_rating_overall(
    v_position, pace, passing, shooting, stamina, defending, awareness
  )))::integer into v_after
  from public.player_ratings where workspace_id = p_workspace_id and ratee_id = p_user_id;

  -- First-ever rating creates a baseline, not an improvement from zero.
  -- No-ops and changes too small to move the displayed total keep the latest
  -- meaningful comparison instead of manufacturing a new trend.
  if v_before is not null and v_before <> v_after then
    insert into public.player_rating_changes
      (workspace_id, ratee_id, position, previous_overall, current_overall, changed_at)
    values (p_workspace_id, p_user_id, v_position, v_before, v_after, clock_timestamp())
    on conflict (workspace_id, ratee_id) do update
    set position = excluded.position,
        previous_overall = excluded.previous_overall,
        current_overall = excluded.current_overall,
        changed_at = excluded.changed_at;
  end if;

  -- Return the refreshed anonymous aggregate with the write, avoiding a second
  -- client round trip.
  return json_build_object(
    'status', 'saved',
    'rating', public.get_player_rating(p_workspace_id, p_user_id)
  );
end;
$$;

revoke execute on function public.submit_player_rating(
  uuid, uuid, smallint, smallint, smallint, smallint, smallint, smallint
) from public, anon;
grant execute on function public.submit_player_rating(
  uuid, uuid, smallint, smallint, smallint, smallint, smallint, smallint
) to authenticated;


notify pgrst, 'reload schema';

-- ===== 20261002100000_registration_settings =====
-- Exercise registration settings: when registration opens, whether a seat is
-- granted on sight or by the organizer, and whether members may bring guests.
--
-- The organizer edits these from «الإعدادات» on an exercise. What he picks is
-- stored twice: on the exercise itself, and on the workspace as the default
-- every later exercise starts from. A trigger copies the workspace default
-- onto each new events row, so create_event, the recurring roll and any
-- future insert path inherit it without being rewritten here.
--
-- Manual approval turns a registration into requests: one for the member and
-- one for each guest they ask to bring, each decided on its own. The request
-- table is deliberately private: no RLS policy, no timestamp in any payload,
-- and the organizer's list is ordered by name. Nobody can tell who asked
-- first, which is the point of the feature.

-- ===========================================================================
-- 1. Columns
-- ===========================================================================

alter table public.events
  add column if not exists registration_opens_at timestamptz,
  add column if not exists registration_open_days_before int
    check (registration_open_days_before between 0 and 13),
  add column if not exists registration_open_minute int
    check (registration_open_minute between 0 and 1439),
  add column if not exists registration_opened_notified_at timestamptz,
  add column if not exists approval_mode text not null default 'auto'
    check (approval_mode in ('auto', 'manual')),
  add column if not exists guests_allowed boolean not null default true;

alter table public.workspaces
  add column if not exists registration_open_days_before int
    check (registration_open_days_before between 0 and 13),
  add column if not exists registration_open_minute int
    check (registration_open_minute between 0 and 1439),
  add column if not exists approval_mode text not null default 'auto'
    check (approval_mode in ('auto', 'manual')),
  add column if not exists guests_allowed boolean not null default true;

create table if not exists public.event_registration_requests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  -- The member who asked. For their own row user_id is the same person; for
  -- a guest they want to bring user_id is null and guest_name says who.
  requested_by uuid not null references auth.users(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  guest_name text,
  status text not null default 'pending' check (status in ('pending', 'declined')),
  created_at timestamptz not null default now(),
  check ((user_id is null) <> (guest_name is null)),
  check (user_id is null or user_id = requested_by)
);

create unique index if not exists event_registration_requests_member_once
  on public.event_registration_requests (event_id, user_id)
  where user_id is not null;
create index if not exists event_registration_requests_by_requester
  on public.event_registration_requests (event_id, requested_by);

-- Read and written only through the security-definer RPCs below.
alter table public.event_registration_requests enable row level security;

-- ===========================================================================
-- 2. The opening rule
-- ===========================================================================

-- "Two days before, at 12:00" is a wall-clock rule in the group's own time,
-- not an interval: a session at 19:00 Tuesday opens at 12:00 Sunday.
create or replace function public.registration_opens_at_for(
  p_start timestamptz,
  p_days_before int,
  p_minute int
)
returns timestamptz
language sql
immutable
as $$
  select case
    when p_days_before is null or p_minute is null then null
    else (
      (((p_start at time zone 'Asia/Riyadh')::date - p_days_before)::timestamp
        + make_interval(mins => p_minute))
      at time zone 'Asia/Riyadh'
    )
  end;
$$;

create or replace function public.apply_workspace_registration_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ws public.workspaces;
begin
  if tg_op = 'INSERT' then
    select * into v_ws from public.workspaces where id = new.workspace_id;
    if v_ws.id is not null then
      new.approval_mode := coalesce(v_ws.approval_mode, 'auto');
      new.guests_allowed := coalesce(v_ws.guests_allowed, true);
      new.registration_open_days_before := v_ws.registration_open_days_before;
      new.registration_open_minute := v_ws.registration_open_minute;
    end if;
    new.registration_opens_at := public.registration_opens_at_for(
      new.start_date, new.registration_open_days_before, new.registration_open_minute);
    -- Already open on arrival: the publish push already says so.
    if new.registration_opens_at is null or new.registration_opens_at <= now() then
      new.registration_opened_notified_at := now();
    end if;
  elsif new.start_date is distinct from old.start_date
        and new.registration_open_days_before is not null
        and (old.registration_opens_at is null or old.registration_opens_at > now()) then
    -- Moving a session that has not opened yet moves its opening with it.
    new.registration_opens_at := public.registration_opens_at_for(
      new.start_date, new.registration_open_days_before, new.registration_open_minute);
    if new.registration_opens_at > now() then
      new.registration_opened_notified_at := null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_apply_workspace_registration_defaults on public.events;
create trigger trg_apply_workspace_registration_defaults
  before insert or update of start_date on public.events
  for each row
  execute function public.apply_workspace_registration_defaults();

-- An invitation to a session nobody can register for yet would send people to
-- a locked button. The opening push below replaces it at the right moment.
create or replace function public.hold_invites_until_registration_opens()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type in ('event_invited', 'event_opened') and exists (
    select 1 from public.events e
    where e.id = new.event_id
      and e.registration_opens_at is not null
      and e.registration_opens_at > now()
  ) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_hold_invites_until_registration_opens on public.push_outbox;
create trigger trg_hold_invites_until_registration_opens
  before insert on public.push_outbox
  for each row
  execute function public.hold_invites_until_registration_opens();

-- ===========================================================================
-- 3. Guards on every way into a seat
-- ===========================================================================

-- Only a member acting for themselves is held back. The organizer seating
-- someone, an accepted request, and a waitlist promotion triggered by someone
-- else leaving all insert rows that are not the caller's own.
create or replace function public.guard_registration_settings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_is_guest boolean;
begin
  if v_uid is null then return new; end if;

  if tg_table_name = 'event_waitlist' then
    if new.user_id is distinct from v_uid then return new; end if;
    v_is_guest := false;
  else
    if new.user_id is not null and new.user_id is distinct from v_uid then return new; end if;
    if new.user_id is null and new.added_by is distinct from v_uid then return new; end if;
    if coalesce(new.added_manually, false) then return new; end if;
    v_is_guest := new.user_id is null;
  end if;

  select * into v_event from public.events where id = new.event_id;
  if v_event.id is null then return new; end if;
  if v_event.creator_id = v_uid
     or public.is_workspace_owner(v_event.workspace_id, v_uid) then
    return new;
  end if;

  if v_event.registration_opens_at is not null and v_event.registration_opens_at > now() then
    raise exception 'registration_not_open';
  end if;
  if v_is_guest and not v_event.guests_allowed then
    raise exception 'guests_not_allowed';
  end if;
  if v_event.approval_mode = 'manual' then
    raise exception 'approval_required';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_registration_settings on public.event_participants;
create trigger trg_guard_registration_settings
  before insert on public.event_participants
  for each row
  execute function public.guard_registration_settings();

drop trigger if exists trg_guard_registration_settings on public.event_waitlist;
create trigger trg_guard_registration_settings
  before insert on public.event_waitlist
  for each row
  execute function public.guard_registration_settings();

-- ===========================================================================
-- 4. register_event_seat answers the new states instead of raising
-- ===========================================================================

-- The seat logic itself is untouched and lives on as the _direct function.
-- A later migration that rewrites register_event_seat must keep this wrapper's
-- checks, or the closed/manual states fall back to the raw trigger errors.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_event_seat_direct'
  ) then
    alter function public.register_event_seat(uuid, text[], decimal)
      rename to register_event_seat_direct;
  end if;
end;
$$;

revoke execute on function public.register_event_seat_direct(uuid, text[], decimal)
  from public, anon, authenticated;

create or replace function public.register_event_seat(
  p_event_id uuid,
  p_guest_names text[] default '{}',
  p_expected_price_per_person decimal default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_guests text[];
  v_existing public.event_registration_requests;
  v_debt_event_id uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  if public.is_workspace_owner(v_event.workspace_id, v_uid) or v_event.creator_id = v_uid then
    return public.register_event_seat_direct(p_event_id, p_guest_names, p_expected_price_per_person);
  end if;

  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_opens_at is not null and v_event.registration_opens_at > now() then
    return json_build_object('status', 'registration_not_open',
                             'registration_opens_at', v_event.registration_opens_at);
  end if;

  select coalesce(array_agg(trim(g)), '{}')
  into v_guests
  from unnest(coalesce(p_guest_names, '{}'::text[])) as g
  where g is not null and length(trim(g)) > 0;

  if cardinality(v_guests) > 0 and not v_event.guests_allowed then
    return json_build_object('status', 'guests_not_allowed');
  end if;

  if v_event.approval_mode <> 'manual' then
    return public.register_event_seat_direct(p_event_id, v_guests, p_expected_price_per_person);
  end if;

  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;
  if exists (
    select 1 from public.event_participants
    where event_id = p_event_id and user_id = v_uid
  ) then
    return json_build_object('status', 'already_joined');
  end if;
  if p_expected_price_per_person is not null
    and abs(p_expected_price_per_person - coalesce(v_event.price_per_person, 0)) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  select * into v_existing
  from public.event_registration_requests
  where event_id = p_event_id and user_id = v_uid;
  if v_existing.status = 'declined' then
    return json_build_object('status', 'request_declined');
  end if;

  -- The same refusal a direct registration meets (20260929120000): an unpaid
  -- earlier workout blocks a request too, or the organizer would accept one
  -- the seat guard then refuses.
  v_debt_event_id := public.unpaid_debt_event(v_event.workspace_id, v_uid);
  if v_debt_event_id is not null then
    raise exception using
      message = 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.',
      hint = 'payment_owed:' || v_debt_event_id::text;
  end if;

  insert into public.event_registration_requests (event_id, requested_by, user_id)
  values (p_event_id, v_uid, v_uid)
  on conflict (event_id, user_id) where user_id is not null do nothing;

  -- Asking again replaces the guests still waiting, not the ones already
  -- decided.
  delete from public.event_registration_requests
  where event_id = p_event_id and requested_by = v_uid
    and user_id is null and status = 'pending';
  insert into public.event_registration_requests (event_id, requested_by, guest_name)
  select p_event_id, v_uid, g from unnest(v_guests) as g;

  delete from public.event_member_responses
  where event_id = p_event_id and user_id = v_uid and status = 'declined';

  if v_existing.event_id is null then
    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, 'registration_requested', p_event_id);
  end if;

  return json_build_object('status', 'requested', 'event_id', p_event_id);
end;
$$;

revoke execute on function public.register_event_seat(uuid, text[], decimal) from public, anon;
grant execute on function public.register_event_seat(uuid, text[], decimal) to authenticated;

-- ===========================================================================
-- 5. Requests
-- ===========================================================================

-- Seats one request: a member, or one guest a member asked to bring. The
-- caller holds the event lock and has checked that the caller may act.
-- Returns 'accepted', 'seats_full' or 'not_found'.
create or replace function public.seat_registration_request_internal(
  p_event public.events,
  p_request_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.event_registration_requests;
  v_seats int;
  v_paid boolean := coalesce(p_event.total_price, 0) > 0;
begin
  select * into v_req
  from public.event_registration_requests
  where id = p_request_id and event_id = p_event.id and status = 'pending';
  if v_req.id is null then return 'not_found'; end if;

  if v_req.user_id is not null and exists (
    select 1 from public.event_participants
    where event_id = p_event.id and user_id = v_req.user_id
  ) then
    delete from public.event_registration_requests where id = v_req.id;
    return 'accepted';
  end if;

  if p_event.max_participants is not null then
    select count(*) into v_seats
    from public.event_participants
    where event_id = p_event.id and payment_status in ('pending', 'confirmed');
    if v_seats + 1 > p_event.max_participants then
      return 'seats_full';
    end if;
  end if;

  if v_req.user_id is not null then
    insert into public.event_participants
      (event_id, user_id, payment_status, payment_declared_at,
       paid_price_per_person, payment_group_size)
    values
      (p_event.id, v_req.user_id,
       case when v_paid then 'pending' else 'confirmed' end,
       case when v_paid then null else now() end,
       p_event.price_per_person, 1);

    delete from public.event_waitlist
    where event_id = p_event.id and user_id = v_req.user_id;

    insert into public.push_outbox (user_id, type, event_id)
    values (v_req.user_id, 'registration_accepted', p_event.id);
  else
    -- A guest can be accepted without the member who asked for them, in
    -- which case the seat is the member's guest-only booking.
    insert into public.event_participants
      (event_id, user_id, guest_name, added_by, payment_status,
       payment_declared_at, paid_price_per_person, guest_only)
    values
      (p_event.id, null, v_req.guest_name, v_req.requested_by,
       case when v_paid then 'pending' else 'confirmed' end,
       case when v_paid then null else now() end,
       p_event.price_per_person,
       not exists (
         select 1 from public.event_participants
         where event_id = p_event.id and user_id = v_req.requested_by
       ));
  end if;

  delete from public.event_registration_requests where id = v_req.id;
  return 'accepted';
end;
$$;

revoke execute on function public.seat_registration_request_internal(public.events, uuid)
  from public, anon, authenticated;

create or replace function public.respond_registration_request(
  p_request_id uuid,
  p_accept boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event_id uuid;
  v_event public.events;
  v_result text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select event_id into v_event_id
  from public.event_registration_requests where id = p_request_id;
  if v_event_id is null then
    return json_build_object('status', 'not_found');
  end if;

  select * into v_event from public.events where id = v_event_id for update;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized: only the organizer can respond to requests';
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;

  if p_accept then
    v_result := public.seat_registration_request_internal(v_event, p_request_id);
  else
    update public.event_registration_requests
    set status = 'declined'
    where id = p_request_id and status = 'pending';
    v_result := case when found then 'declined' else 'not_found' end;
  end if;

  return json_build_object('status', v_result);
end;
$$;

revoke execute on function public.respond_registration_request(uuid, boolean) from public, anon;
grant execute on function public.respond_registration_request(uuid, boolean) to authenticated;

-- Organizer only. Grouped by the member who asked, in name order, with the
-- member before their guests. No timestamp leaves the table.
create or replace function public.get_event_registration_requests(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  return (
    select coalesce(
      json_agg(row_to_json(x) order by x.requester_name, x.user_id is null, x.display_name),
      '[]'::json)
    from (
      select r.id,
             r.user_id,
             r.requested_by,
             r.guest_name,
             coalesce(r.guest_name, usr.name, au.email) as display_name,
             coalesce(usr.name, au.email) as requester_name,
             case when r.user_id is not null then usr.avatar_url end as avatar_url,
             case when r.user_id is not null then usr.postion end as player_position
      from public.event_registration_requests r
      left join public.users usr on usr.user_id = r.requested_by
      left join auth.users au on au.id = r.requested_by
      where r.event_id = p_event_id and r.status = 'pending'
    ) x
  );
end;
$$;

revoke execute on function public.get_event_registration_requests(uuid) from public, anon;
grant execute on function public.get_event_registration_requests(uuid) to authenticated;

create or replace function public.get_my_registration_request(p_event_id uuid)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('status', r.status)
  from public.event_registration_requests r
  where r.event_id = p_event_id and r.user_id = auth.uid();
$$;

revoke execute on function public.get_my_registration_request(uuid) from public, anon;
grant execute on function public.get_my_registration_request(uuid) to authenticated;

-- Takes back the member's own request and the guests still waiting with it.
create or replace function public.withdraw_registration_request(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  delete from public.event_registration_requests
  where event_id = p_event_id and requested_by = auth.uid() and status = 'pending';
  return json_build_object('status', case when found then 'withdrawn' else 'not_found' end);
end;
$$;

revoke execute on function public.withdraw_registration_request(uuid) from public, anon;
grant execute on function public.withdraw_registration_request(uuid) to authenticated;

-- ===========================================================================
-- 6. Opening announcements
-- ===========================================================================

-- Tells the invited members that registration is open, once per exercise.
-- Reads the invitation rows publish wrote, so a member held back by an unpaid
-- earlier session stays held back here too.
create or replace function public.announce_registration_opening_internal(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null
     or v_event.registration_opened_notified_at is not null
     or v_event.published_at is null
     or v_event.cancelled_at is not null
     or (v_event.registration_opens_at is not null and v_event.registration_opens_at > now()) then
    return;
  end if;

  update public.events
  set registration_opened_notified_at = now()
  where id = p_event_id;

  insert into public.push_outbox (user_id, type, event_id)
  select r.user_id, 'event_opened', p_event_id
  from public.event_member_responses r
  where r.event_id = p_event_id
    and r.status = 'invited'
    and r.user_id <> v_event.creator_id
    and not exists (
      select 1 from public.event_participants ep
      where ep.event_id = p_event_id and ep.user_id = r.user_id
    )
    and not exists (
      select 1 from public.push_outbox po
      where po.event_id = p_event_id and po.user_id = r.user_id
        and po.type = 'event_opened'
    );
end;
$$;

revoke execute on function public.announce_registration_opening_internal(uuid)
  from public, anon, authenticated;

create or replace function public.announce_registration_openings()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  for v_id in
    select id from public.events
    where registration_opened_notified_at is null
      and registration_opens_at <= now()
      and published_at is not null
      and cancelled_at is null
      and coalesce(end_date, start_date) > now()
  loop
    perform public.announce_registration_opening_internal(v_id);
  end loop;
end;
$$;

revoke execute on function public.announce_registration_openings() from public, anon, authenticated;

do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'registration-openings'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
  perform cron.schedule(
    'registration-openings',
    '* * * * *',
    $cron$select public.announce_registration_openings();$cron$
  );
end;
$$;

-- ===========================================================================
-- 7. Organizer controls
-- ===========================================================================

create or replace function public.open_event_registration_now(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  update public.events
  set registration_opens_at = date_trunc('second', now())
  where id = p_event_id
    and registration_opens_at is not null
    and registration_opens_at > now();

  perform public.announce_registration_opening_internal(p_event_id);

  select * into v_event from public.events where id = p_event_id;
  return to_jsonb(v_event);
end;
$$;

revoke execute on function public.open_event_registration_now(uuid) from public, anon;
grant execute on function public.open_event_registration_now(uuid) to authenticated;

-- Saves the organizer's settings on this exercise, on every exercise of the
-- group that has not finished yet, and on the group as the default for the
-- ones still to come. A null rule means registration is open from publish.
create or replace function public.update_event_registration_settings(
  p_event_id uuid,
  p_open_days_before int,
  p_open_minute int,
  p_approval_mode text,
  p_guests_allowed boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_target public.events;
  v_req record;
  v_result text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_approval_mode not in ('auto', 'manual') then
    raise exception 'Invalid approval mode: %', p_approval_mode;
  end if;
  if (p_open_days_before is null) <> (p_open_minute is null) then
    raise exception 'Opening rule needs both a day and a time';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  update public.workspaces
  set registration_open_days_before = p_open_days_before,
      registration_open_minute = p_open_minute,
      approval_mode = p_approval_mode,
      guests_allowed = coalesce(p_guests_allowed, true)
  where id = v_event.workspace_id;

  for v_target in
    select * from public.events
    where workspace_id = v_event.workspace_id
      and coalesce(end_date, start_date) > now()
    order by start_date
    for update
  loop
    update public.events
    set registration_open_days_before = p_open_days_before,
        registration_open_minute = p_open_minute,
        registration_opens_at = public.registration_opens_at_for(
          start_date, p_open_days_before, p_open_minute),
        registration_opened_notified_at = case
          when public.registration_opens_at_for(start_date, p_open_days_before, p_open_minute) > now()
            then null
          else coalesce(registration_opened_notified_at, now())
        end,
        approval_mode = p_approval_mode,
        guests_allowed = coalesce(p_guests_allowed, true)
    where id = v_target.id
    returning * into v_target;

    -- Back to automatic: whoever was waiting on the organizer is seated now,
    -- member by member in no particular order, each before their guests. A
    -- member who no longer fits queues like any late registration.
    if p_approval_mode = 'auto' then
      for v_req in
        with requesters as (
          select requested_by, random() as k
          from public.event_registration_requests
          where event_id = v_target.id and status = 'pending'
          group by requested_by
        )
        select q.id, q.user_id
        from public.event_registration_requests q
        join requesters using (requested_by)
        where q.event_id = v_target.id and q.status = 'pending'
        order by requesters.k, q.user_id is null
      loop
        v_result := public.seat_registration_request_internal(v_target, v_req.id);
        if v_result = 'seats_full' then
          if v_req.user_id is not null and v_target.capacity_policy = 'waitlist' then
            insert into public.event_waitlist (event_id, user_id)
            values (v_target.id, v_req.user_id)
            on conflict (event_id, user_id) do nothing;
          end if;
          delete from public.event_registration_requests where id = v_req.id;
        end if;
      end loop;
      delete from public.event_registration_requests
      where event_id = v_target.id and status = 'declined';
    end if;
  end loop;

  select * into v_event from public.events where id = p_event_id;
  return to_jsonb(v_event);
end;
$$;

revoke execute on function public.update_event_registration_settings(uuid, int, int, text, boolean)
  from public, anon;
grant execute on function public.update_event_registration_settings(uuid, int, int, text, boolean)
  to authenticated;

notify pgrst, 'reload schema';

-- ===== 20261014100000_event_map_links =====
-- The map link an organizer pastes for a custom venue.
--
-- The Hudhud app opens only its own place links (l.hudhud.sa/p/<id>); a pin
-- sent as coordinates lands on its "update the app" screen. A venue pasted
-- from Hudhud is the only way to hand it a place it understands, so the link
-- the create flow already asks for is now kept instead of thrown away.
--
-- Its own table rather than another column on events and event_templates:
-- those columns are copied by every create, edit and recurrence function, and
-- the link is only ever read when someone taps directions. A series keeps one
-- link on its template, so every occurrence it rolls out shares it; a one-off
-- workout keeps it on the event.

create table if not exists public.event_map_links (
  id uuid primary key default gen_random_uuid(),
  template_id uuid unique references public.event_templates(id) on delete cascade,
  event_id uuid unique references public.events(id) on delete cascade,
  url text not null,
  updated_at timestamptz not null default now(),
  constraint event_map_links_one_owner check ((template_id is null) <> (event_id is null)),
  constraint event_map_links_url check (url ~ '^https://\S+$' and length(url) <= 500)
);

-- No policies: the two functions below are the only way in.
alter table public.event_map_links enable row level security;

-- Saves, replaces or (with an empty url) removes the link. Workspace owner only.
create or replace function public.set_event_map_link(p_event_id uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_url text := nullif(trim(p_url), '');
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can change the map link';
  end if;
  if v_url is not null and (v_url !~ '^https://\S+$' or length(v_url) > 500) then
    raise exception 'رابط الخريطة غير صحيح';
  end if;

  if v_event.template_id is not null then
    delete from public.event_map_links where template_id = v_event.template_id;
    if v_url is not null then
      insert into public.event_map_links (template_id, url) values (v_event.template_id, v_url);
    end if;
  else
    delete from public.event_map_links where event_id = v_event.id;
    if v_url is not null then
      insert into public.event_map_links (event_id, url) values (v_event.id, v_url);
    end if;
  end if;
end;
$$;

-- The link for a workout, its own or its series'. Members only; null when none.
create or replace function public.get_event_map_link(p_event_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then return null; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a member of this workspace';
  end if;

  return (
    select l.url
    from public.event_map_links l
    where l.event_id = v_event.id
       or (v_event.template_id is not null and l.template_id = v_event.template_id)
    order by (l.event_id is not null) desc
    limit 1
  );
end;
$$;

revoke execute on function public.set_event_map_link(uuid, text) from public, anon;
revoke execute on function public.get_event_map_link(uuid) from public, anon;
grant execute on function public.set_event_map_link(uuid, text) to authenticated;
grant execute on function public.get_event_map_link(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ===== record what ran =====
insert into supabase_migrations.schema_migrations (version, name) values
  ('20260919100000', 'moyasar_payments'),
  ('20260919110000', 'card_payment_rpcs'),
  ('20260921100000', 'card_payment_without_recipient'),
  ('20260922100000', 'refunds'),
  ('20260922110000', 'refund_triggers'),
  ('20260922120000', 'schedule_refund_sweep'),
  ('20260929100000', 'pay_for_guests_added_after_paying'),
  ('20260929110000', 'add_guests_while_one_is_unpaid'),
  ('20261001100000', 'preserve_seats_on_payment_reset'),
  ('20261001110000', 'player_rating_changes'),
  ('20261002100000', 'registration_settings'),
  ('20261014100000', 'event_map_links')
on conflict (version) do nothing;

commit;
