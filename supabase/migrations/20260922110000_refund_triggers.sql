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
