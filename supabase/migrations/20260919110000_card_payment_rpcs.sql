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
