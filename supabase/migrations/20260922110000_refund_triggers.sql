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
