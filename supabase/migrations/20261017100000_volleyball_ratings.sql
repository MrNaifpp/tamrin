-- Volleyball positions and ratings, next to football's.
--
-- A player has one position per sport. Football keeps living in
-- users.postion, which every roster and the football ratings already read;
-- other sports live in user_sports. A row there with a null position means
-- "I play this", added from the profile before choosing where.
--
-- Volleyball ratings mirror player_ratings column for column: six attributes,
-- one row per (workspace, rater, player), RPC-only. A workspace has a single
-- sport, so player_rating_changes is shared: its key never collides.

create table public.user_sports (
  user_id uuid not null references auth.users(id) on delete cascade,
  sport public.sport not null,
  position text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, sport)
);
alter table public.user_sports enable row level security;
revoke all on public.user_sports from public, anon, authenticated;

-- The stored values are Arabic, like football's. The app shows them through
-- its own titles.
create or replace function public.sport_positions(p_sport public.sport)
returns text[]
language sql
immutable
set search_path = public
as $$
  select case p_sport
    when 'soccer' then array['حارس', 'دفاع', 'وسط', 'هجوم']
    when 'volleyball' then array['معدّ', 'مستقبل', 'ضارب يسار', 'ضارب يمين', 'صادّ', 'ليبرو']
    else array[]::text[]
  end;
$$;

-- --------------------------------------------------------------------------
-- My sports.
-- --------------------------------------------------------------------------

create or replace function public.get_my_sports()
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  return coalesce((
    select json_agg(json_build_object('sport', s.sport, 'position', s.position) order by s.created_at)
    from (
      select sport,
        case when sport = 'soccer'
          then nullif(trim((select postion from public.users where user_id = v_uid)), '')
          else position end as position,
        created_at
      from public.user_sports where user_id = v_uid
    ) s
  ), '[]'::json);
end;
$$;

-- Null position adds the sport without choosing yet. Football writes through
-- to users.postion so everything that already reads it keeps working.
create or replace function public.set_my_sport_position(p_sport public.sport, p_position text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_position text := nullif(trim(coalesce(p_position, '')), '');
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if cardinality(public.sport_positions(p_sport)) = 0 then
    raise exception 'Sport has no positions';
  end if;
  if v_position is not null and not v_position = any(public.sport_positions(p_sport)) then
    raise exception 'Unknown position for this sport';
  end if;
  insert into public.user_sports(user_id, sport, position)
  values (v_uid, p_sport, case when p_sport = 'soccer' then null else v_position end)
  on conflict (user_id, sport) do update
    set position = coalesce(excluded.position, user_sports.position), updated_at = now();
  if p_sport = 'soccer' and v_position is not null then
    update public.users set postion = v_position where user_id = v_uid;
  end if;
  return public.get_my_sports();
end;
$$;

create or replace function public.remove_my_sport(p_sport public.sport)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  delete from public.user_sports where user_id = v_uid and sport = p_sport;
  return public.get_my_sports();
end;
$$;

-- Football has kept its position on the profile all along; it is a sport the
-- player already plays.
insert into public.user_sports(user_id, sport)
select user_id, 'soccer' from public.users where trim(coalesce(postion, '')) <> ''
on conflict do nothing;

-- --------------------------------------------------------------------------
-- Volleyball ratings.
-- --------------------------------------------------------------------------

create table public.volleyball_ratings (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  rater_id uuid not null references auth.users(id) on delete cascade,
  ratee_id uuid not null references auth.users(id) on delete cascade,
  receiving smallint not null check (receiving between 0 and 100),
  setting smallint not null check (setting between 0 and 100),
  attacking smallint not null check (attacking between 0 and 100),
  blocking smallint not null check (blocking between 0 and 100),
  serving smallint not null check (serving between 0 and 100),
  awareness smallint not null check (awareness between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, rater_id, ratee_id),
  check (rater_id <> ratee_id)
);
create index volleyball_ratings_ratee on public.volleyball_ratings(workspace_id, ratee_id);
alter table public.volleyball_ratings enable row level security;
revoke all on public.volleyball_ratings from public, anon, authenticated;

-- The same shape as football: the position's own skill carries the most,
-- then awareness, then two supporting skills, then the rest. The setter is
-- weighted like the keeper, because the whole game runs through him. The
-- libero breaks the pattern on purpose: the rules forbid him to attack, block
-- or serve, so those three are token weights and reception carries 40.
-- Unknown or blank positions score on the left hitter's set for read-only
-- legacy data; new writes require a real position. The Swift side mirrors
-- this table; the two must be changed together.
create or replace function public.volleyball_rating_overall(
  p_position text,
  p_receiving numeric,
  p_setting numeric,
  p_attacking numeric,
  p_blocking numeric,
  p_serving numeric,
  p_awareness numeric
)
returns integer
language sql
immutable
set search_path = public
as $$
  select case coalesce(nullif(trim(p_position), ''), 'ضارب يسار')
    when 'معدّ' then round(
      p_setting * 0.35 + p_awareness * 0.25 + p_serving * 0.15
      + p_receiving * 0.10 + p_blocking * 0.10 + p_attacking * 0.05
    )
    when 'مستقبل' then round(
      p_receiving * 0.30 + p_awareness * 0.20 + p_attacking * 0.15
      + p_serving * 0.15 + p_blocking * 0.10 + p_setting * 0.10
    )
    when 'ضارب يمين' then round(
      p_attacking * 0.30 + p_awareness * 0.20 + p_blocking * 0.15
      + p_serving * 0.15 + p_receiving * 0.10 + p_setting * 0.10
    )
    when 'صادّ' then round(
      p_blocking * 0.30 + p_awareness * 0.20 + p_attacking * 0.15
      + p_serving * 0.15 + p_receiving * 0.10 + p_setting * 0.10
    )
    when 'ليبرو' then round(
      p_receiving * 0.40 + p_awareness * 0.25 + p_setting * 0.20
      + p_attacking * 0.05 + p_blocking * 0.05 + p_serving * 0.05
    )
    else round(
      p_attacking * 0.30 + p_awareness * 0.20 + p_receiving * 0.15
      + p_serving * 0.15 + p_blocking * 0.10 + p_setting * 0.10
    )
  end::integer;
$$;

create or replace function public.volleyball_position(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select position from public.user_sports
    where user_id = p_user_id and sport = 'volleyball'), '');
$$;

create or replace function public.get_volleyball_rating(p_workspace_id uuid, p_user_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_position text;
  v_mine public.volleyball_ratings;
  v_count integer;
  v_avg record;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if not public.is_workspace_member(p_workspace_id, p_user_id) then
    raise exception 'Player is not a workspace member';
  end if;
  v_position := public.volleyball_position(p_user_id);

  select * into v_mine from public.volleyball_ratings
  where workspace_id = p_workspace_id and rater_id = v_uid and ratee_id = p_user_id;
  select count(*) into v_count from public.volleyball_ratings
  where workspace_id = p_workspace_id and ratee_id = p_user_id;

  if v_count = 0 then
    return json_build_object('sport', 'volleyball', 'position', v_position,
      'has_rated', false, 'ratings_count', 0, 'mine', null, 'average', null);
  end if;

  select avg(receiving) as receiving, avg(setting) as setting, avg(attacking) as attacking,
    avg(blocking) as blocking, avg(serving) as serving, avg(awareness) as awareness,
    round(avg(public.volleyball_rating_overall(
      v_position, receiving, setting, attacking, blocking, serving, awareness
    )))::integer as overall
  into v_avg
  from public.volleyball_ratings
  where workspace_id = p_workspace_id and ratee_id = p_user_id;

  return json_build_object(
    'sport', 'volleyball',
    'position', v_position,
    'has_rated', v_mine.ratee_id is not null,
    'ratings_count', v_count,
    'mine', case when v_mine.ratee_id is null then null else json_build_object(
        'receiving', v_mine.receiving, 'setting', v_mine.setting,
        'attacking', v_mine.attacking, 'blocking', v_mine.blocking,
        'serving', v_mine.serving, 'awareness', v_mine.awareness,
        'overall', public.volleyball_rating_overall(v_position, v_mine.receiving,
          v_mine.setting, v_mine.attacking, v_mine.blocking, v_mine.serving, v_mine.awareness),
        'updated_at', v_mine.updated_at
      ) end,
    'trend', (
      select json_build_object(
        'previous_overall', change.previous_overall,
        'current_overall', change.current_overall,
        'delta', change.current_overall - change.previous_overall,
        'changed_at', change.changed_at)
      from public.player_rating_changes change
      where change.workspace_id = p_workspace_id and change.ratee_id = p_user_id
        and change.position = v_position and change.current_overall = v_avg.overall
    ),
    'average', json_build_object(
      'receiving', round(v_avg.receiving), 'setting', round(v_avg.setting),
      'attacking', round(v_avg.attacking), 'blocking', round(v_avg.blocking),
      'serving', round(v_avg.serving), 'awareness', round(v_avg.awareness),
      'overall', v_avg.overall
    )
  );
end;
$$;

create or replace function public.submit_volleyball_rating(
  p_workspace_id uuid,
  p_user_id uuid,
  p_receiving smallint,
  p_setting smallint,
  p_attacking smallint,
  p_blocking smallint,
  p_serving smallint,
  p_awareness smallint
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_position text;
  v_before integer;
  v_after integer;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if (select sport from public.workspaces where id = p_workspace_id) <> 'volleyball' then
    raise exception 'Not a volleyball workspace';
  end if;
  if p_user_id = v_uid then return json_build_object('status', 'is_self'); end if;
  if not public.is_workspace_member(p_workspace_id, p_user_id) then
    return json_build_object('status', 'not_a_member');
  end if;
  select position into v_position from public.user_sports
  where user_id = p_user_id and sport = 'volleyball' for share;
  if v_position is null or not v_position = any(public.sport_positions('volleyball')) then
    return json_build_object('status', 'position_required');
  end if;
  if num_nonnulls(p_receiving, p_setting, p_attacking, p_blocking, p_serving, p_awareness) <> 6
     or least(p_receiving, p_setting, p_attacking, p_blocking, p_serving, p_awareness) < 0
     or greatest(p_receiving, p_setting, p_attacking, p_blocking, p_serving, p_awareness) > 100 then
    return json_build_object('status', 'out_of_range');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || p_user_id::text, 917));
  select round(avg(public.volleyball_rating_overall(
    v_position, receiving, setting, attacking, blocking, serving, awareness)))::integer
  into v_before
  from public.volleyball_ratings where workspace_id = p_workspace_id and ratee_id = p_user_id;

  insert into public.volleyball_ratings (workspace_id, rater_id, ratee_id,
    receiving, setting, attacking, blocking, serving, awareness)
  values (p_workspace_id, v_uid, p_user_id,
    p_receiving, p_setting, p_attacking, p_blocking, p_serving, p_awareness)
  on conflict (workspace_id, rater_id, ratee_id) do update
  set receiving = excluded.receiving, setting = excluded.setting,
      attacking = excluded.attacking, blocking = excluded.blocking,
      serving = excluded.serving, awareness = excluded.awareness, updated_at = now()
  where (volleyball_ratings.receiving, volleyball_ratings.setting, volleyball_ratings.attacking,
         volleyball_ratings.blocking, volleyball_ratings.serving, volleyball_ratings.awareness)
    is distinct from
        (excluded.receiving, excluded.setting, excluded.attacking,
         excluded.blocking, excluded.serving, excluded.awareness);

  select round(avg(public.volleyball_rating_overall(
    v_position, receiving, setting, attacking, blocking, serving, awareness)))::integer
  into v_after
  from public.volleyball_ratings where workspace_id = p_workspace_id and ratee_id = p_user_id;

  if v_before is not null and v_before <> v_after then
    insert into public.player_rating_changes
      (workspace_id, ratee_id, position, previous_overall, current_overall, changed_at)
    values (p_workspace_id, p_user_id, v_position, v_before, v_after, clock_timestamp())
    on conflict (workspace_id, ratee_id) do update
    set position = excluded.position, previous_overall = excluded.previous_overall,
        current_overall = excluded.current_overall, changed_at = excluded.changed_at;
  end if;

  return json_build_object('status', 'saved',
    'rating', public.get_volleyball_rating(p_workspace_id, p_user_id));
end;
$$;

revoke execute on function public.sport_positions(public.sport),
  public.volleyball_rating_overall(text, numeric, numeric, numeric, numeric, numeric, numeric),
  public.volleyball_position(uuid),
  public.get_my_sports(), public.set_my_sport_position(public.sport, text),
  public.remove_my_sport(public.sport),
  public.get_volleyball_rating(uuid, uuid),
  public.submit_volleyball_rating(uuid, uuid, smallint, smallint, smallint, smallint, smallint, smallint)
  from public, anon;
revoke execute on function public.volleyball_position(uuid) from authenticated;
grant execute on function public.get_my_sports(), public.set_my_sport_position(public.sport, text),
  public.remove_my_sport(public.sport),
  public.get_volleyball_rating(uuid, uuid),
  public.submit_volleyball_rating(uuid, uuid, smallint, smallint, smallint, smallint, smallint, smallint)
  to authenticated;

notify pgrst, 'reload schema';
