-- Notify the joiner when the creator confirms or rejects their payment.
-- Each RPC enqueues a push_outbox row (to p_user_id = the joiner) on its
-- success path only, inside the same transaction as the status change.

-- ============================================================================
-- confirm_payment: + payment_confirmed push to the joiner.
-- ============================================================================
create or replace function public.confirm_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  updated_rows int;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if ev.creator_id <> p_creator_id then
    raise exception 'Not authorized: only the event creator can confirm payments';
  end if;

  update public.event_participants
    set payment_status = 'confirmed'
    where event_id = p_event_id
      and user_id = p_user_id
      and payment_status = 'pending';

  get diagnostics updated_rows = row_count;

  if updated_rows = 0 then
    return json_build_object('status', 'no_pending_row');
  end if;

  -- Notify the joiner that their payment was confirmed.
  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_confirmed', p_event_id);

  return json_build_object('status', 'confirmed', 'joiner_id', p_user_id);
end;
$$;

grant execute on function public.confirm_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- reject_payment: + payment_rejected push to the joiner.
-- ============================================================================
create or replace function public.reject_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  deleted_rows int;
  waiters json;
begin
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if ev.creator_id <> p_creator_id then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  delete from public.event_participants
    where event_id = p_event_id
      and user_id = p_user_id
      and payment_status = 'pending';

  get diagnostics deleted_rows = row_count;

  if deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  -- Notify the joiner that their payment was rejected.
  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  -- Collect waiter ids to notify (Swift client will fan out the pushes).
  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object('status', 'rejected', 'joiner_id', p_user_id, 'waiter_ids', waiters);
end;
$$;

grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;
