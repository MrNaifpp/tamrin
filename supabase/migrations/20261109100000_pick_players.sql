-- Picking players for a new event.
--
-- The last step of "تمرين جديد" lets an organizer seat people from their own
-- groups, or anyone who played in an event they ran. Spec:
-- docs/superpowers/specs/2026-11-09-new-event-pick-players-design.md

-- What the organizer can pick from: their own groups (with the members other
-- than themselves) and every app user who has played in one of their events.
-- Name-only guests have no account and never appear.
create or replace function public.get_my_pick_sources()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authorized';
  end if;

  return json_build_object(
    'groups', coalesce((
      select json_agg(g order by g.last_played_at desc nulls last, g.name)
      from (
        select
          w.id as workspace_id,
          w.name,
          (select max(e.start_date)
             from events e
            where e.workspace_id = w.id
              and e.start_date < now()
              and e.cancelled_at is null) as last_played_at,
          (select json_agg(json_build_object(
                    'user_id', u.user_id, 'name', u.name, 'avatar_url', u.avatar_url)
                  order by u.name)
             from workspace_members wm
             join users u on u.user_id = wm.user_id
            where wm.workspace_id = w.id
              and wm.user_id <> v_uid) as members
        from workspaces w
        where w.owner_id = v_uid
      ) g
      where g.members is not null
    ), '[]'::json),
    'past_players', coalesce((
      select json_agg(json_build_object(
               'user_id', u.user_id, 'name', u.name, 'avatar_url', u.avatar_url)
             order by u.name)
      from users u
      where u.user_id <> v_uid
        and exists (
          select 1
          from event_participants ep
          join events e on e.id = ep.event_id
          join workspaces w on w.id = e.workspace_id
          where ep.user_id = u.user_id
            and w.owner_id = v_uid
        )
    ), '[]'::json)
  );
end;
$$;

revoke execute on function public.get_my_pick_sources() from public, anon;
grant execute on function public.get_my_pick_sources() to authenticated;

-- Creates the event exactly as create_event does, then seats the picked
-- players, makes them members of the workspace, and tells each one who added
-- them. One transaction: either all of it happens or none of it does.
create or replace function public.create_event_with_players(
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
  p_longitude double precision default null,
  p_recurrence text default 'none',
  p_payment_method_id uuid default null,
  p_payment_method_ids uuid[] default null,
  p_capacity_policy text default 'waitlist',
  p_player_ids uuid[] default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ids uuid[];
  v_stranger uuid;
  v_player uuid;
  v_result json;
  v_event public.events;
begin
  if v_uid is null
     or p_creator_id is distinct from v_uid
     or not public.is_workspace_owner(p_workspace_id, v_uid) then
    raise exception 'Not authorized';
  end if;

  -- The organizer is never one of their own picked players.
  v_ids := array(
    select distinct x from unnest(coalesce(p_player_ids, '{}'::uuid[])) as x
    where x is not null and x <> v_uid
  );
  if cardinality(v_ids) = 0 then
    raise exception 'No players to add';
  end if;

  -- Only people the organizer already plays with: members of one of their
  -- groups, or players from one of their events.
  select x into v_stranger
  from unnest(v_ids) as x
  where not exists (
          select 1 from workspace_members wm
          join workspaces w on w.id = wm.workspace_id
          where wm.user_id = x and w.owner_id = v_uid)
    and not exists (
          select 1 from event_participants ep
          join events e on e.id = ep.event_id
          join workspaces w on w.id = e.workspace_id
          where ep.user_id = x and w.owner_id = v_uid)
  limit 1;
  if v_stranger is not null then
    raise exception using
      message = 'لا يمكن إضافة هذا اللاعب',
      hint = 'player_not_pickable';
  end if;

  -- create_event seats the organizer too, so they take one of the seats.
  if p_max_participants is not null and cardinality(v_ids) + 1 > p_max_participants then
    raise exception using
      message = 'عدد اللاعبين أكبر من المقاعد',
      hint = 'too_many_players';
  end if;

  -- The seat guard refuses anyone who still owes for an earlier event in this
  -- group. Say so in words meant for the organizer, not the player.
  foreach v_player in array v_ids loop
    if public.unpaid_debt_event(p_workspace_id, v_player) is not null then
      raise exception using
        message = format('%s عليه قطة لم تُدفع من تمرين سابق',
                         coalesce((select name from users where user_id = v_player), 'لاعب')),
        hint = 'player_owes';
    end if;
  end loop;

  -- Picked players get "added you", not also the usual "new event" push.
  perform set_config('tamrin.picked_players', array_to_string(v_ids, ','), true);

  v_result := public.create_event(
    p_creator_id => p_creator_id,
    p_workspace_id => p_workspace_id,
    p_name => p_name,
    p_location => p_location,
    p_description => p_description,
    p_start_date => p_start_date,
    p_end_date => p_end_date,
    p_image_url => p_image_url,
    p_max_participants => p_max_participants,
    p_total_price => p_total_price,
    p_price_per_person => p_price_per_person,
    p_latitude => p_latitude,
    p_longitude => p_longitude,
    p_recurrence => p_recurrence,
    p_payment_method_id => p_payment_method_id,
    p_payment_method_ids => p_payment_method_ids,
    p_capacity_policy => p_capacity_policy
  );
  select * into v_event from events where id = (v_result->>'id')::uuid;

  insert into workspace_members (workspace_id, user_id)
  select p_workspace_id, x from unnest(v_ids) as x
  on conflict do nothing;

  -- Seated the way an approved registration request is.
  insert into event_participants
    (event_id, user_id, payment_status, payment_declared_at,
     paid_price_per_person, payment_group_size)
  select v_event.id, x,
         case when coalesce(v_event.total_price, 0) > 0 then 'pending' else 'confirmed' end,
         case when coalesce(v_event.total_price, 0) > 0 then null else now() end,
         v_event.price_per_person, 1
  from unnest(v_ids) as x;

  insert into push_outbox (user_id, type, event_id, actor_id)
  select x, 'added_to_event', v_event.id, v_uid
  from unnest(v_ids) as x;

  perform set_config('tamrin.picked_players', '', true);

  return v_result;
end;
$$;

revoke execute on function public.create_event_with_players(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[], text, uuid[]
) from public, anon;
grant execute on function public.create_event_with_players(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[], text, uuid[]
) to authenticated;

-- Drops the "new event" push for players being added in the same
-- transaction; they get "added_to_event" instead.
create or replace function public.skip_invite_for_picked_players()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.type in ('event_invited', 'event_opened')
     and new.user_id::text = any(
       string_to_array(nullif(current_setting('tamrin.picked_players', true), ''), ',')) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_skip_invite_for_picked_players on public.push_outbox;
create trigger trg_skip_invite_for_picked_players
  before insert on public.push_outbox
  for each row
  execute function public.skip_invite_for_picked_players();
