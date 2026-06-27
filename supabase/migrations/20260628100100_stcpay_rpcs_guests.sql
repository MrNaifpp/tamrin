-- Group-aware STC Pay RPCs: a joiner pays for themselves + N guests in one go.

-- ============================================================================
-- submit_payment: insert the joiner's row + one row per guest (null user_id).
-- ============================================================================
create or replace function public.submit_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_guest_names text[] default '{}'
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
  v_guests text[];
  v_group_size int;
begin
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;

  if ev.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into existing_status
    from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;
  if existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', existing_status);
  end if;

  -- Clean guest names (drop nulls/blanks); group = self + valid guests.
  select coalesce(array_agg(trim(g)), '{}')
    into v_guests
    from unnest(p_guest_names) as g
    where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

  -- Seat cap (pending + confirmed both count); whole group must fit.
  if ev.max_participants is not null then
    select count(*) into current_seats
      from public.event_participants
      where event_id = p_event_id
        and payment_status in ('pending', 'confirmed');
    if current_seats + v_group_size > ev.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  select stc_pay_number into creator_stc
    from public.users
    where user_id = ev.creator_id;
  if creator_stc is null or creator_stc = '' then
    return json_build_object('status', 'creator_missing_number');
  end if;

  -- Joiner's own row.
  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

  -- One row per guest.
  insert into public.event_participants (event_id, user_id, guest_name, added_by, payment_status, paid_to_number)
  select p_event_id, null, g, p_user_id, 'pending', creator_stc
  from unnest(v_guests) as g;

  delete from public.event_waitlist
    where event_id = p_event_id and user_id = p_user_id;

  insert into public.push_outbox (user_id, type, event_id)
  values (ev.creator_id, 'payment_submitted', p_event_id);

  return json_build_object(
    'status', 'submitted',
    'creator_id', ev.creator_id,
    'paid_to_number', creator_stc,
    'group_size', v_group_size
  );
end;
$$;

grant execute on function public.submit_payment(uuid, uuid, text[]) to authenticated;

-- ============================================================================
-- confirm_payment: confirm the joiner + all rows they added.
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
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';

  get diagnostics updated_rows = row_count;
  if updated_rows = 0 then
    return json_build_object('status', 'no_pending_row');
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_confirmed', p_event_id);

  return json_build_object('status', 'confirmed', 'joiner_id', p_user_id);
end;
$$;

grant execute on function public.confirm_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- reject_payment: delete the joiner + their guests, free seats, notify waiters.
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
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';

  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object('status', 'rejected', 'joiner_id', p_user_id, 'waiter_ids', waiters);
end;
$$;

grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- cancel_pending: joiner cancels their own group.
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
  perform 1 from public.events where id = p_event_id for update;

  delete from public.event_participants
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
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
-- get_event_participants: expose participant_id (stable), guest_name, added_by.
-- user_id may be null for guests; display_name falls back to guest_name.
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
        ep.id as participant_id,
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, u.email, ep.guest_name) as display_name,
        null::text as avatar_url,
        ep.payment_status,
        ep.paid_to_number,
        ep.guest_name,
        ep.added_by
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
