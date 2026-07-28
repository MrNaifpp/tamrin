-- Workspace-membership guards on the event RPC surface. Non-members can no
-- longer view, join, pay for, or wait on a workspace's events.

-- ----------------------------------------------------------------------------
-- create_event: gains p_workspace_id; creator must be a member.
-- Drop the previous overload to avoid PostgREST ambiguity.
-- ----------------------------------------------------------------------------
drop function if exists public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision);

create or replace function public.create_event(
  p_creator_id uuid,
  p_workspace_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null,
  p_total_price int default 0,
  p_price_per_person decimal default 0,
  p_latitude double precision default null,
  p_longitude double precision default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
begin
  if p_creator_id is distinct from auth.uid() then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(p_workspace_id, p_creator_id) then
    raise exception 'Not a workspace member';
  end if;

  insert into public.events (creator_id, workspace_id, name, location, description, start_date, end_date, image_url, max_participants, total_price, price_per_person, latitude, longitude)
  values (p_creator_id, p_workspace_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants, p_total_price, p_price_per_person, p_latitude, p_longitude)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision) to authenticated;

-- ----------------------------------------------------------------------------
-- get_event_by_id: member-gated (was: anyone with the link).
-- ----------------------------------------------------------------------------
create or replace function public.get_event_by_id(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(ev.workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;
  return row_to_json(ev);
end;
$$;

revoke execute on function public.get_event_by_id(uuid) from anon;
grant execute on function public.get_event_by_id(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- get_event_participants: member-gated (participant names are private now).
-- Body unchanged from 20260628100100 apart from the guard.
-- ----------------------------------------------------------------------------
create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_workspace uuid;
begin
  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_workspace, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;

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

revoke execute on function public.get_event_participants(uuid) from anon;
grant execute on function public.get_event_participants(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- join_event: guard added after the event lookup. Body otherwise unchanged
-- from 20260130500000.
-- ----------------------------------------------------------------------------
create or replace function public.join_event(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if p_user_id is distinct from auth.uid() then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(ev.workspace_id, p_user_id) then
    raise exception 'Not a workspace member';
  end if;
  if ev.registration_locked then
    raise exception 'Registration is closed for this event';
  end if;

  insert into public.event_participants (event_id, user_id)
  values (p_event_id, p_user_id)
  on conflict (event_id, user_id) do nothing;

  return true;
end;
$$;

revoke execute on function public.join_event(uuid, uuid) from anon;
grant execute on function public.join_event(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- submit_payment (guest-aware 3-arg version): guard added after the row lock.
-- Body otherwise identical to 20260628100100.
-- ----------------------------------------------------------------------------
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
  if p_user_id is distinct from auth.uid() then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(ev.workspace_id, p_user_id) then
    raise exception 'Not a workspace member';
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

  select coalesce(array_agg(trim(g)), '{}')
    into v_guests
    from unnest(p_guest_names) as g
    where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

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

  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

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

-- ----------------------------------------------------------------------------
-- join_waitlist: guard added (needs the event row to find the workspace).
-- ----------------------------------------------------------------------------
create or replace function public.join_waitlist(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_workspace uuid;
begin
  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then
    raise exception 'Event not found';
  end if;
  if p_user_id is distinct from auth.uid() then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(v_workspace, p_user_id) then
    raise exception 'Not a workspace member';
  end if;

  insert into public.event_waitlist (event_id, user_id)
    values (p_event_id, p_user_id)
    on conflict (event_id, user_id) do nothing;
  return json_build_object('status', 'joined');
end;
$$;

grant execute on function public.join_waitlist(uuid, uuid) to authenticated;
