-- STC Pay: all RPCs for the manual payment + confirmation flow.
--
-- Concurrency note: paid joins serialize on `select ... for update` of the
-- target events row, so concurrent submit_payment calls for the same event
-- see consistent seat counts.
--
-- Auth model:
--   submit_payment / cancel_pending / join_waitlist / leave_waitlist —
--     joiner identifies themselves via p_user_id.
--   confirm_payment / reject_payment — creator must pass p_creator_id; RPC
--     verifies it matches events.creator_id and raises otherwise.
--
-- All push notifications are fired from the Swift client AFTER the RPC
-- returns successfully. RPCs return the relevant user ids so the client
-- knows who to notify.

-- ============================================================================
-- submit_payment: joiner submits a paid-event payment.
-- ============================================================================

create or replace function public.submit_payment(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  creator_stc text;
  current_seats int;
  existing_status text;
begin
  -- Lock the event row to serialize concurrent submits for the same event.
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;

  if ev.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  -- Already joined? (any status counts)
  select payment_status into existing_status
    from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;
  if existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', existing_status);
  end if;

  -- Seat cap (pending + confirmed both count).
  if ev.max_participants is not null then
    select count(*) into current_seats
      from public.event_participants
      where event_id = p_event_id
        and payment_status in ('pending', 'confirmed');
    if current_seats >= ev.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  -- Creator's STC Pay number (snapshot).
  select stc_pay_number into creator_stc
    from public.users
    where user_id = ev.creator_id;
  if creator_stc is null or creator_stc = '' then
    return json_build_object('status', 'creator_missing_number');
  end if;

  -- Insert pending row + capture snapshot of the creator's number.
  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

  -- If the joiner was on the waitlist, remove them.
  delete from public.event_waitlist
    where event_id = p_event_id and user_id = p_user_id;

  return json_build_object(
    'status', 'submitted',
    'creator_id', ev.creator_id,
    'paid_to_number', creator_stc
  );
end;
$$;

grant execute on function public.submit_payment(uuid, uuid) to authenticated;

-- ============================================================================
-- confirm_payment: creator confirms a pending payment.
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

  return json_build_object('status', 'confirmed', 'joiner_id', p_user_id);
end;
$$;

grant execute on function public.confirm_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- reject_payment: creator rejects a pending payment. Deletes row, frees seat,
-- returns waitlist user_ids so the client can push them "seat available".
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

  -- Collect waiter ids to notify (Swift client will fan out the pushes).
  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object('status', 'rejected', 'joiner_id', p_user_id, 'waiter_ids', waiters);
end;
$$;

grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- cancel_pending: joiner cancels their own pending payment.
-- ============================================================================

create or replace function public.cancel_pending(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_rows int;
  waiters json;
begin
  -- Lock the event row to serialize with concurrent submit_payment.
  perform 1 from public.events where id = p_event_id for update;

  delete from public.event_participants
    where event_id = p_event_id
      and user_id = p_user_id
      and payment_status = 'pending';

  get diagnostics deleted_rows = row_count;

  if deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object('status', 'cancelled', 'waiter_ids', waiters);
end;
$$;

grant execute on function public.cancel_pending(uuid, uuid) to authenticated;

-- ============================================================================
-- join_waitlist / leave_waitlist
-- ============================================================================

create or replace function public.join_waitlist(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.event_waitlist (event_id, user_id)
    values (p_event_id, p_user_id)
    on conflict (event_id, user_id) do nothing;
  return json_build_object('status', 'joined');
end;
$$;

grant execute on function public.join_waitlist(uuid, uuid) to authenticated;

create or replace function public.leave_waitlist(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.event_waitlist
    where event_id = p_event_id and user_id = p_user_id;
  return json_build_object('status', 'left');
end;
$$;

grant execute on function public.leave_waitlist(uuid, uuid) to authenticated;

-- ============================================================================
-- leave_event: modified to return waitlist user_ids alongside the existing
-- boolean semantics. The Swift client currently ignores the return value, so
-- changing the return type from `boolean` to `json` is backward compatible.
-- ============================================================================

drop function if exists public.leave_event(uuid, uuid);

create or replace function public.leave_event(
  p_event_id uuid,
  p_user_id uuid
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
  if ev.creator_id = p_user_id then
    raise exception 'Event creator cannot leave their own event';
  end if;

  delete from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;

  get diagnostics deleted_rows = row_count;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object(
    'status', case when deleted_rows > 0 then 'left' else 'not_participant' end,
    'waiter_ids', waiters
  );
end;
$$;

grant execute on function public.leave_event(uuid, uuid) to authenticated;

-- ============================================================================
-- get_event_participants: extend to return payment_status so the client can
-- show pending vs confirmed pills.
-- ============================================================================

create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  return (
    select coalesce(json_agg(row_to_json(t)), '[]'::json)
    from (
      select
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, u.email) as display_name,
        null::text as avatar_url,
        ep.payment_status,
        ep.paid_to_number
      from public.event_participants ep
      left join auth.users u on u.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id
      order by ep.created_at asc
    ) t
  );
end;
$$;

grant execute on function public.get_event_participants(uuid) to authenticated;
grant execute on function public.get_event_participants(uuid) to anon;
