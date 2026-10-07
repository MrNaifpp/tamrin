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
