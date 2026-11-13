-- MyFatoorah replaces Moyasar.
--
-- The ledger stays: payments, refunds, and the triggers that create refunds are
-- provider-neutral in everything but their column names, so the names change
-- and the Moyasar-only parts go (split recipients, the recipient gate, the SDK's
-- given_id). Production has these tables from the 2026-10-16 bundle but no card
-- payment was ever taken there, so renaming loses nothing.
--
-- New: payment_seats. A payment now records exactly which seats it was priced
-- for, and settle_payment confirms those and only those. Before, it confirmed
-- "every seat this member owes right now", so a guest added between the quote
-- and the money arriving was confirmed without being paid for.

-- 1. Names -------------------------------------------------------------------

alter table public.payments rename column moyasar_payment_id to provider_payment_id;
alter table public.payments rename column last_moyasar_status to last_provider_status;
alter table public.payments drop column if exists split_recipient_id;
alter table public.payments drop column if exists given_id;
-- Rows from before the switch are Moyasar's (the sandbox has test payments),
-- so the MyFatoorah sweep and refunds leave them alone; new rows are MyFatoorah's.
alter table public.payments add column provider text not null default 'moyasar';
alter table public.payments alter column provider set default 'myfatoorah';
-- The Apple Pay attempt in flight, as sent to MyFatoorah's ExternalIdentifier.
-- A late answer about an earlier attempt is recognised by not matching it.
alter table public.payments add column current_attempt text;

alter table public.refunds rename column moyasar_payment_id to provider_payment_id;
alter table public.refunds add column provider_refund_id text unique;
alter table public.refunds add column next_attempt_at timestamptz;

alter table public.moyasar_webhook_events rename to payment_webhook_events;

-- A second charge for an already-paid payment is refunded in full, apart from
-- the payment's own refund accounting.
alter table public.refunds drop constraint refunds_reason_check;
alter table public.refunds add constraint refunds_reason_check
  check (reason in ('withdrew', 'guest_removed', 'event_cancelled', 'duplicate_charge'));

drop table if exists public.workspace_moyasar_recipients;

-- 2. Covered seats -----------------------------------------------------------

-- participant_id has no foreign key on purpose: the seat row can be deleted
-- (withdrawal, guest removed) before the money lands, and its price is what
-- the refund for it must be.
create table public.payment_seats (
  payment_id      uuid not null references public.payments(id) on delete cascade,
  participant_id  uuid not null,
  price           int  not null check (price > 0),
  primary key (payment_id, participant_id)
);

create index idx_payment_seats_participant on public.payment_seats(participant_id);

alter table public.payment_seats enable row level security;
revoke all on public.payment_seats from anon, authenticated;

-- 3. Quote -------------------------------------------------------------------

drop function if exists public.begin_card_payment(uuid, uuid, boolean);
drop function if exists public.begin_card_payment(uuid, uuid);

create function public.begin_card_payment(
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
  v_owed uuid[];
  v_seats int;
  v_amount int;
  v_payment public.payments;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.workspace_id is null then raise exception 'Event has no workspace'; end if;
  if not public.is_workspace_member(v_event.workspace_id, p_user_id) then
    raise exception 'Not a workspace member';
  end if;

  if v_event.cancelled_at is not null or v_event.published_at is null then
    return json_build_object('status', 'event_closed');
  end if;
  if v_event.total_price <= 0 then
    return json_build_object('status', 'free_event');
  end if;

  -- Money already on its way: never open a second charge for the same seats.
  if exists (
    select 1 from public.payments
    where event_id = p_event_id and user_id = p_user_id and status = 'processing'
  ) then
    return json_build_object('status', 'processing');
  end if;

  -- Seats this member owes for: their own plus guests they added. Each keeps
  -- the price it was registered at; a later price edit changes nothing here.
  select coalesce(array_agg(ep.id order by ep.id), '{}'),
         count(*),
         coalesce(sum(round(coalesce(ep.paid_price_per_person,
                                     v_event.price_per_person) * 100)), 0)::int
    into v_owed, v_seats, v_amount
  from public.event_participants ep
  where ep.event_id = p_event_id
    and ep.payment_status = 'pending'
    and (ep.user_id = p_user_id
         or (ep.user_id is null and ep.added_by = p_user_id));

  if v_seats = 0 then
    if exists (
      select 1 from public.payments
      where event_id = p_event_id and user_id = p_user_id and status = 'paid'
    ) then
      return json_build_object('status', 'already_paid');
    end if;
    return json_build_object('status', 'nothing_due');
  end if;

  -- Reuse an open attempt only if it covers exactly these seats. A declined
  -- attempt is still open: Apple Pay can be tried again on it.
  select p.* into v_payment
  from public.payments p
  where p.event_id = p_event_id and p.user_id = p_user_id
    and p.status in ('pending', 'failed')
    and p.amount = v_amount
    and (select array_agg(s.participant_id order by s.participant_id)
           from public.payment_seats s where s.payment_id = p.id) = v_owed
  order by p.created_at desc
  limit 1;

  if v_payment.id is null then
    update public.payments
       set status = 'cancelled'
     where event_id = p_event_id and user_id = p_user_id
       and status in ('pending', 'failed');

    insert into public.payments
      (workspace_id, event_id, user_id, seat_count, amount, platform_fee)
    values
      (v_event.workspace_id, p_event_id, p_user_id, v_seats, v_amount, 0)
    returning * into v_payment;

    insert into public.payment_seats (payment_id, participant_id, price)
    select v_payment.id, ep.id,
           round(coalesce(ep.paid_price_per_person, v_event.price_per_person) * 100)::int
    from public.event_participants ep
    where ep.id = any (v_owed);
  end if;

  return json_build_object(
    'status', 'ready',
    'payment_id', v_payment.id,
    'amount', v_payment.amount,
    'currency', v_payment.currency,
    'seat_count', v_payment.seat_count,
    'event_name', v_event.name
  );
end;
$$;

revoke execute on function public.begin_card_payment(uuid, uuid) from public, anon, authenticated;
grant execute on function public.begin_card_payment(uuid, uuid) to service_role;

-- 4. request_refund: same rule, renamed column --------------------------------

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
  if v_payment.provider_payment_id is null then return null; end if;

  v_amount := least(coalesce(p_amount, 0), v_payment.amount - v_payment.refunded_amount);
  v_seats  := least(greatest(coalesce(p_seats, 1), 1),
                    v_payment.seat_count - v_payment.refunded_seats);
  if v_amount <= 0 or v_seats <= 0 then return null; end if;

  insert into public.refunds
    (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
  values
    (v_payment.id, v_payment.event_id, v_payment.user_id, v_seats, v_amount,
     p_reason, v_payment.provider_payment_id)
  returning id into v_id;

  return v_id;
end;
$$;

-- 5. Ops alerts -------------------------------------------------------------

-- Pushes the ops user (vault `ops_user_id`) when money needs a person to look at
-- it. Unset vault entry: nothing, as with the other vault-held settings.
create or replace function public.notify_ops(p_type text, p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ops uuid;
begin
  select nullif(decrypted_secret, '')::uuid into v_ops
    from vault.decrypted_secrets where name = 'ops_user_id';
  if v_ops is not null then
    insert into public.push_outbox (user_id, type, event_id) values (v_ops, p_type, p_event_id);
  end if;
end;
$$;

revoke execute on function public.notify_ops(text, uuid) from public, anon, authenticated;
grant execute on function public.notify_ops(text, uuid) to service_role;

-- 6. Claim -------------------------------------------------------------------

-- The one door into charging a payment. Locks the row, and only a pending or
-- declined payment on an open event moves to `processing`, with this attempt
-- as the current one and the previous attempt's provider id cleared. Two
-- requests racing for the same row: one claims, the other is told it is moving.
create or replace function public.claim_payment_attempt(
  p_payment_id uuid,
  p_user_id uuid,
  p_attempt text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_event public.events;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if v_payment.id is null or v_payment.user_id <> p_user_id then
    return json_build_object('status', 'not_found');
  end if;
  if v_payment.status = 'paid' then return json_build_object('status', 'paid'); end if;
  if v_payment.status = 'processing' then return json_build_object('status', 'processing'); end if;
  if v_payment.status not in ('pending', 'failed') then
    return json_build_object('status', 'not_payable');
  end if;

  select * into v_event from public.events where id = v_payment.event_id;
  if v_event.cancelled_at is not null or v_event.published_at is null then
    update public.payments set status = 'cancelled' where id = p_payment_id;
    return json_build_object('status', 'event_closed');
  end if;

  update public.payments
     set status = 'processing',
         provider_payment_id = null,
         current_attempt = p_attempt
   where id = p_payment_id;

  return json_build_object('status', 'claimed',
                           'amount', v_payment.amount,
                           'currency', v_payment.currency);
end;
$$;

revoke execute on function public.claim_payment_attempt(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.claim_payment_attempt(uuid, uuid, text) to service_role;

-- 7. Settle ------------------------------------------------------------------

drop function if exists public.settle_payment(uuid, text, text, text, int, text, int);
drop function if exists public.settle_payment(uuid, text, text, text, int, text);
drop function if exists public.settle_payment(uuid, text, text, text, int, text, text);

-- p_outcome is already ours ('paid' | 'failed' | 'processing'): the Edge
-- Functions translate MyFatoorah's statuses, so this never learns them.
-- p_attempt names the Apple Pay attempt the answer is about (null when the
-- caller cannot tell). Rules, in order:
--   * already paid, and a DIFFERENT charge reports paid → refund that charge in
--     full and alert ops; the seats stay with the first charge
--   * an answer about an earlier attempt: a success still counts (the money
--     moved), anything else is ignored so it cannot fail the attempt in flight
--   * the event was cancelled by the time the money arrived → confirm nothing,
--     refund everything
create function public.settle_payment(
  p_payment_id uuid,
  p_provider_payment_id text,
  p_outcome text,
  p_payment_method text,
  p_amount int,
  p_currency text,
  p_attempt text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_event public.events;
  v_seats int := 0;
  v_missing_seats int;
  v_missing_amount int;
  v_refund uuid;
  v_stale boolean;
begin
  if p_outcome not in ('paid', 'failed', 'processing') then
    raise exception 'Unknown outcome %', p_outcome;
  end if;

  select * into v_payment from public.payments where id = p_payment_id for update;
  if v_payment.id is null then raise exception 'Payment not found'; end if;
  select * into v_event from public.events where id = v_payment.event_id;

  if v_payment.status in ('paid', 'refunded') then
    if p_outcome = 'paid' and p_provider_payment_id is not null
       and p_provider_payment_id is distinct from v_payment.provider_payment_id then
      select id into v_refund from public.refunds
       where payment_id = p_payment_id and reason = 'duplicate_charge'
         and provider_payment_id = p_provider_payment_id;
      if v_refund is null then
        insert into public.refunds
          (payment_id, event_id, user_id, seats, amount, reason, provider_payment_id)
        values
          (p_payment_id, v_payment.event_id, v_payment.user_id, 1, p_amount,
           'duplicate_charge', p_provider_payment_id)
        returning id into v_refund;
        perform public.notify_ops('payment_problem', v_payment.event_id);
      end if;
      return json_build_object('status', 'duplicate_refunded', 'refund_id', v_refund);
    end if;
    return json_build_object('status', 'already_settled');
  end if;

  v_stale := p_attempt is not null and p_attempt is distinct from v_payment.current_attempt;
  if v_stale and p_outcome <> 'paid' then
    return json_build_object('status', 'stale');
  end if;

  update public.payments
     set provider_payment_id = coalesce(p_provider_payment_id, provider_payment_id),
         last_provider_status = p_outcome,
         payment_method = coalesce(p_payment_method, payment_method)
   where id = p_payment_id
  returning * into v_payment;

  if p_outcome = 'processing' then
    update public.payments set status = 'processing' where id = p_payment_id;
    return json_build_object('status', 'processing');
  end if;

  if p_outcome = 'failed' then
    update public.payments set status = 'failed' where id = p_payment_id;
    return json_build_object('status', 'failed');
  end if;

  -- paid
  if p_amount <> v_payment.amount or p_currency <> v_payment.currency then
    update public.payments
       set status = 'failed',
           failure_code = 'amount_mismatch',
           failure_message = format('expected %s %s, provider reports %s %s',
                                    v_payment.amount, v_payment.currency,
                                    p_amount, p_currency)
     where id = p_payment_id;
    perform public.notify_ops('payment_problem', v_payment.event_id);
    return json_build_object('status', 'amount_mismatch');
  end if;

  if v_event.cancelled_at is null then
    with mine as (
      update public.event_participants ep
         set payment_status = 'confirmed',
             payment_id = p_payment_id,
             payment_declared_at = coalesce(ep.payment_declared_at, now())
        from public.payment_seats s
       where s.payment_id = p_payment_id
         and ep.id = s.participant_id
         and ep.payment_status = 'pending'
      returning 1
    )
    select count(*) into v_seats from mine;
  end if;

  update public.payments
     set status = 'paid', paid_at = now(), failure_code = null, failure_message = null
   where id = p_payment_id;

  if v_seats > 0 then
    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, 'payment_paid', v_payment.event_id);
  end if;

  -- Covered seats this payment did not confirm (gone, settled some other way
  -- while the money was moving, or the event was cancelled) were paid for and
  -- are not held: give that money back.
  select count(*), coalesce(sum(s.price), 0)
    into v_missing_seats, v_missing_amount
  from public.payment_seats s
  where s.payment_id = p_payment_id
    and not exists (
      select 1 from public.event_participants ep
      where ep.id = s.participant_id and ep.payment_id = p_payment_id
        and ep.payment_status = 'confirmed'
    );

  if v_missing_seats > 0 then
    v_refund := public.request_refund(
      p_payment_id, v_missing_seats, v_missing_amount,
      case when v_event.cancelled_at is not null then 'event_cancelled' else 'withdrew' end
    );
  end if;

  return json_build_object('status', 'settled', 'seats', v_seats, 'refund_id', v_refund);
end;
$$;

revoke execute on function public.settle_payment(uuid, text, text, text, int, text, text) from public, anon, authenticated;
grant execute on function public.settle_payment(uuid, text, text, text, int, text, text) to service_role;
