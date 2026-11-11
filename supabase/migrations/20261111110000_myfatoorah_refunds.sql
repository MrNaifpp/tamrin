-- MyFatoorah refunds can take a while, and can be refused for a while.
--
-- A MyFatoorah refund is a request: it may answer "Pending" and finish hours or
-- days later (by hand at their finance team unless Auto Refund is on). And the
-- refundable balance excludes money received today, so a member who withdraws
-- on the day they paid can be refused for "insufficient balance". That is a
-- "not yet", so it gets its own state and a daily retry for a week. After that,
-- or on any other refusal, the refund fails and the ops user is pushed, because
-- money we owe someone must never fail silently.

alter table public.refunds drop constraint refunds_status_check;
alter table public.refunds add constraint refunds_status_check
  check (status in ('pending', 'processing', 'waiting_balance', 'done', 'failed'));

-- 1. settle_refund -----------------------------------------------------------

drop function if exists public.settle_refund(uuid, text, int, text);

create function public.settle_refund(
  p_refund_id uuid,
  p_status text,
  p_provider_refund_id text default null,
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
  if p_status not in ('refunded', 'pending', 'waiting_balance', 'failed') then
    raise exception 'Unknown refund status %', p_status;
  end if;

  select * into v_refund from public.refunds where id = p_refund_id for update;
  if v_refund.id is null then raise exception 'Refund not found'; end if;

  if v_refund.status in ('done', 'failed') then
    return json_build_object('status', 'already_settled');
  end if;

  if p_provider_refund_id is not null then
    update public.refunds set provider_refund_id = p_provider_refund_id
     where id = p_refund_id;
  end if;

  if p_status = 'pending' then
    update public.refunds set status = 'processing' where id = p_refund_id;
    return json_build_object('status', 'processing');
  end if;

  if p_status = 'waiting_balance' and v_refund.created_at >= now() - interval '7 days' then
    update public.refunds
       set status = 'waiting_balance',
           attempts = attempts + 1,
           next_attempt_at = now() + interval '1 day',
           failure_message = left(p_failure_message, 500)
     where id = p_refund_id;
    return json_build_object('status', 'waiting_balance');
  end if;

  if p_status in ('failed', 'waiting_balance') then
    update public.refunds
       set status = 'failed',
           failure_code = case when p_status = 'waiting_balance'
                               then 'balance_timeout' else 'refund_rejected' end,
           failure_message = left(coalesce(p_failure_message, p_status), 500)
     where id = p_refund_id;

    perform public.notify_ops('refund_failed', v_refund.event_id);
    return json_build_object('status', 'failed');
  end if;

  -- refunded. A second charge's refund is its own money: it never touches the
  -- payment's refund totals or its seats.
  if v_refund.reason = 'duplicate_charge' then
    update public.refunds set status = 'done' where id = p_refund_id;
    insert into public.push_outbox (user_id, type, event_id)
    values (v_refund.user_id, 'refund_issued', v_refund.event_id);
    return json_build_object('status', 'settled');
  end if;

  select * into v_payment from public.payments
   where id = v_refund.payment_id for update;

  -- Clamped: the check constraint is the backstop, and a bad figure must not
  -- abort the transaction and strand the row.
  v_total := least(v_payment.refunded_amount + v_refund.amount, v_payment.amount);

  update public.payments
     set refunded_amount = v_total,
         refunded_seats  = least(refunded_seats + v_refund.seats, seat_count),
         status = case when v_total >= amount then 'refunded' else status end
   where id = v_payment.id
  returning * into v_payment;

  update public.refunds set status = 'done' where id = p_refund_id;

  -- Fully refunded: the payment holds no seats any more. On a cancelled event
  -- the debt is forgiven, so the payer is not gated out of their next workout.
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

revoke execute on function public.settle_refund(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.settle_refund(uuid, text, text, text) to service_role;

-- 2. request_refund: refunds still on their way count against what remains ---

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
  v_open_amount int;
  v_open_seats int;
  v_amount int;
  v_seats int;
  v_id uuid;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if v_payment.id is null then return null; end if;
  if v_payment.status <> 'paid' then return null; end if;
  if v_payment.provider_payment_id is null then return null; end if;

  select coalesce(sum(amount), 0), coalesce(sum(seats), 0)
    into v_open_amount, v_open_seats
  from public.refunds
  where payment_id = p_payment_id
    and reason <> 'duplicate_charge'
    and status in ('pending', 'processing', 'waiting_balance');

  v_amount := least(coalesce(p_amount, 0),
                    v_payment.amount - v_payment.refunded_amount - v_open_amount);
  v_seats  := least(greatest(coalesce(p_seats, 1), 1),
                    v_payment.seat_count - v_payment.refunded_seats - v_open_seats);
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

-- 3. The sweep ---------------------------------------------------------------

-- Re-posts what needs another look. refund-payment decides what that means for
-- each row: send a new request, or ask MyFatoorah how an earlier one is going.
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
  -- Sent, and no answer for three hours. MyFatoorah keeps an idempotency key for
  -- 250 minutes, so resending past that could refund twice: stop, fail it, and
  -- let ops check the portal.
  for v_row in
    select * from public.refunds
    where status = 'processing' and provider_refund_id is null
      and created_at < now() - interval '3 hours'
  loop
    perform public.settle_refund(v_row.id, 'failed', null,
                                 'No answer from MyFatoorah for 3 hours; check the portal before retrying');
  end loop;

  for v_row in
    select * from public.refunds
    where (status = 'pending' and attempts < 5
           and created_at < now() - interval '3 minutes')
       or (status = 'processing' and updated_at < now() - interval '10 minutes')
       or (status = 'waiting_balance' and next_attempt_at <= now())
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
