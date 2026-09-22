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
