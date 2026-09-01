-- The split, «التشكيلة», as the group's answer rather than one phone's note.
--
-- A slot points at event_participants, not at auth.users. That is the id the
-- app already carries for a player, and it is the only id a guest or a manually
-- added player has at all. It also means a participant who leaves takes his
-- slot with him through the cascade, which is the line the roster already draws.
--
-- Names, ratings and strength are deliberately absent. They are read fresh from
-- the roster every time the pitch is drawn, so a player who changed his position
-- does not carry a stale one into the next exercise.
--
-- Both tables are RPC only: RLS on with no policies, no grants. The privacy rule
-- lives in get_event_lineup, where it cannot be sidestepped by a hand rolled
-- request.

create table if not exists public.event_lineups (
  event_id     uuid primary key references public.events(id) on delete cascade,
  status       text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  updated_at   timestamptz not null default now(),
  updated_by   uuid not null references auth.users(id)
);

create table if not exists public.event_lineup_slots (
  event_id       uuid not null references public.event_lineups(event_id) on delete cascade,
  participant_id uuid not null references public.event_participants(id) on delete cascade,
  side           smallint not null check (side in (1, 2)),
  ordinal        integer not null,
  position       text check (position in ('goalkeeper', 'defender', 'midfielder', 'forward')),
  primary key (event_id, participant_id)
);

create index if not exists idx_event_lineup_slots_event_side
  on public.event_lineup_slots(event_id, side, ordinal);

alter table public.event_lineups enable row level security;
alter table public.event_lineup_slots enable row level security;
revoke all on table public.event_lineups from public, anon, authenticated;
revoke all on table public.event_lineup_slots from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Reading. The organizer always sees his own working copy. A member holding a
-- seat sees it only once it is published, and receives null before that so the
-- app can say there is no lineup yet rather than show an error. Everyone else
-- receives null.
-- --------------------------------------------------------------------------
create or replace function public.get_event_lineup(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
  v_is_owner boolean;
  v_holds_seat boolean;
  v_lineup public.event_lineups;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then return null; end if;

  select * into v_lineup from public.event_lineups where event_id = p_event_id;
  if v_lineup.event_id is null then return null; end if;

  v_is_owner := public.is_workspace_owner(v_workspace, v_uid);
  v_holds_seat := exists (
    select 1 from public.event_participants p
    where p.event_id = p_event_id and p.user_id = v_uid
  );

  if not v_is_owner and not (v_holds_seat and v_lineup.status = 'published') then
    return null;
  end if;

  return json_build_object(
    'status', v_lineup.status,
    'published_at', v_lineup.published_at,
    'updated_at', v_lineup.updated_at,
    'first', (
      select coalesce(json_agg(s.participant_id order by s.ordinal), '[]'::json)
      from public.event_lineup_slots s
      where s.event_id = p_event_id and s.side = 1
    ),
    'second', (
      select coalesce(json_agg(s.participant_id order by s.ordinal), '[]'::json)
      from public.event_lineup_slots s
      where s.event_id = p_event_id and s.side = 2
    ),
    'positions', (
      select coalesce(json_object_agg(s.participant_id, s.position), '{}'::json)
      from public.event_lineup_slots s
      where s.event_id = p_event_id and s.position is not null
    )
  );
end;
$$;

-- --------------------------------------------------------------------------
-- Saving replaces the whole split in one statement pair. A lineup is one
-- arrangement, not a set of edits, so a partial write has no meaning.
-- --------------------------------------------------------------------------
create or replace function public.save_event_lineup(
  p_event_id uuid,
  p_first uuid[],
  p_second uuid[],
  p_positions jsonb default '{}'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
  v_all uuid[] := coalesce(p_first, '{}') || coalesce(p_second, '{}');
  v_key text;
  v_value text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then raise exception 'Exercise not found'; end if;
  if not public.is_workspace_owner(v_workspace, v_uid) then
    raise exception 'Only the organizer can save a lineup';
  end if;

  if coalesce(array_length(v_all, 1), 0) is distinct from
     (select count(distinct x)::int from unnest(v_all) as x) then
    raise exception 'A player cannot hold two places in one lineup';
  end if;

  if exists (
    select 1 from unnest(v_all) as candidate(id)
    where not exists (
      select 1 from public.event_participants p
      where p.id = candidate.id and p.event_id = p_event_id
    )
  ) then
    raise exception 'Every player in a lineup must hold a seat in this exercise';
  end if;

  for v_key, v_value in select * from jsonb_each_text(coalesce(p_positions, '{}'::jsonb))
  loop
    if v_value not in ('goalkeeper', 'defender', 'midfielder', 'forward') then
      raise exception 'Unknown position: %', v_value;
    end if;
    if not (v_key::uuid = any(v_all)) then
      raise exception 'A position was given for a player who is not in the lineup';
    end if;
  end loop;

  insert into public.event_lineups (event_id, updated_by)
  values (p_event_id, v_uid)
  on conflict (event_id) do update
    set updated_at = now(), updated_by = v_uid;

  delete from public.event_lineup_slots where event_id = p_event_id;

  insert into public.event_lineup_slots (event_id, participant_id, side, ordinal, position)
  select p_event_id, t.id, 1, t.ordinality - 1,
         nullif(p_positions->>t.id::text, '')
  from unnest(coalesce(p_first, '{}')) with ordinality as t(id, ordinality)
  union all
  select p_event_id, t.id, 2, t.ordinality - 1,
         nullif(p_positions->>t.id::text, '')
  from unnest(coalesce(p_second, '{}')) with ordinality as t(id, ordinality);

  return public.get_event_lineup(p_event_id);
end;
$$;

create or replace function public.publish_event_lineup(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then raise exception 'Exercise not found'; end if;
  if not public.is_workspace_owner(v_workspace, v_uid) then
    raise exception 'Only the organizer can publish a lineup';
  end if;

  update public.event_lineups
  set status = 'published',
      published_at = coalesce(published_at, now()),
      updated_at = now(),
      updated_by = v_uid
  where event_id = p_event_id;

  if not found then
    raise exception 'There is no lineup to publish yet';
  end if;

  return public.get_event_lineup(p_event_id);
end;
$$;

revoke execute on function public.save_event_lineup(uuid, uuid[], uuid[], jsonb) from public, anon;
grant execute on function public.save_event_lineup(uuid, uuid[], uuid[], jsonb) to authenticated;
revoke execute on function public.publish_event_lineup(uuid) from public, anon;
grant execute on function public.publish_event_lineup(uuid) to authenticated;
revoke execute on function public.get_event_lineup(uuid) from public, anon;
grant execute on function public.get_event_lineup(uuid) to authenticated;

notify pgrst, 'reload schema';
