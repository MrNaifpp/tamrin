-- Last meaningful movement of the anonymous workspace rating. No rater IDs
-- or per-rater scores are exposed by this table or the summary payload.
create table public.player_rating_changes (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  ratee_id uuid not null references auth.users(id) on delete cascade,
  position text not null,
  previous_overall integer not null check (previous_overall between 0 and 100),
  current_overall integer not null check (current_overall between 0 and 100),
  changed_at timestamptz not null default now(),
  primary key (workspace_id, ratee_id),
  check (previous_overall <> current_overall)
);
alter table public.player_rating_changes enable row level security;
revoke all on public.player_rating_changes from public, anon, authenticated;

create or replace function public.get_player_rating(
  p_workspace_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_position text;
  v_mine public.player_ratings;
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

  select usr.postion into v_position
  from public.users usr
  where usr.user_id = p_user_id;

  select * into v_mine
  from public.player_ratings
  where workspace_id = p_workspace_id
    and rater_id = v_uid
    and ratee_id = p_user_id;

  select count(*) into v_count
  from public.player_ratings
  where workspace_id = p_workspace_id and ratee_id = p_user_id;

  if v_count = 0 then
    return json_build_object(
      'position', coalesce(v_position, ''),
      'has_rated', false,
      'ratings_count', 0,
      'mine', null,
      'average', null
    );
  end if;

  select
    avg(pace) as pace,
    avg(passing) as passing,
    avg(shooting) as shooting,
    avg(stamina) as stamina,
    avg(defending) as defending,
    avg(awareness) as awareness,
    round(avg(public.player_rating_overall(
      v_position, pace, passing, shooting, stamina, defending, awareness
    )))::integer as overall
  into v_avg
  from public.player_ratings
  where workspace_id = p_workspace_id and ratee_id = p_user_id;

  return json_build_object(
    'position', coalesce(v_position, ''),
    'has_rated', v_mine.ratee_id is not null,
    'ratings_count', v_count,
    'mine', case when v_mine.ratee_id is null then null else json_build_object(
        'pace', v_mine.pace,
        'passing', v_mine.passing,
        'shooting', v_mine.shooting,
        'stamina', v_mine.stamina,
        'defending', v_mine.defending,
        'awareness', v_mine.awareness,
        'overall', public.player_rating_overall(
          v_position, v_mine.pace, v_mine.passing, v_mine.shooting,
          v_mine.stamina, v_mine.defending, v_mine.awareness
        ),
        'updated_at', v_mine.updated_at
      ) end,
    -- Attribute averages explain the score. The Overall itself follows the
    -- product rule literally: calculate and round each submitted Overall, then
    -- average those whole-number results and round the final mean.
    'trend', (
      select json_build_object(
        'previous_overall', change.previous_overall,
        'current_overall', change.current_overall,
        'delta', change.current_overall - change.previous_overall,
        'changed_at', change.changed_at
      )
      from public.player_rating_changes change
      where change.workspace_id = p_workspace_id and change.ratee_id = p_user_id
        and change.position = coalesce(v_position, '')
        and change.current_overall = v_avg.overall
    ),
    'average', json_build_object(
      'pace', round(v_avg.pace),
      'passing', round(v_avg.passing),
      'shooting', round(v_avg.shooting),
      'stamina', round(v_avg.stamina),
      'defending', round(v_avg.defending),
      'awareness', round(v_avg.awareness),
      'overall', v_avg.overall
    )
  );
end;
$$;

revoke execute on function public.get_player_rating(uuid, uuid) from public, anon;
grant execute on function public.get_player_rating(uuid, uuid) to authenticated;

-- --------------------------------------------------------------------------
-- submit_player_rating: one row per (workspace, rater, player), re-submittable.
--
-- Refusals come back as a status string rather than an exception so the sheet
-- can say precisely what happened, in the same shape as the other RPCs here.
-- --------------------------------------------------------------------------
create or replace function public.submit_player_rating(
  p_workspace_id uuid,
  p_user_id uuid,
  p_pace smallint,
  p_passing smallint,
  p_shooting smallint,
  p_stamina smallint,
  p_defending smallint,
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
  if p_user_id = v_uid then
    return json_build_object('status', 'is_self');
  end if;
  if not public.is_workspace_member(p_workspace_id, p_user_id) then
    return json_build_object('status', 'not_a_member');
  end if;
  select usr.postion into v_position
  from public.users usr
  where usr.user_id = p_user_id for share;
  if coalesce(trim(v_position), '') not in ('حارس', 'دفاع', 'وسط', 'هجوم') then
    return json_build_object('status', 'position_required');
  end if;
  if num_nonnulls(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) <> 6
     or least(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) < 0
     or greatest(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) > 100 then
    return json_build_object('status', 'out_of_range');
  end if;

  -- Serialize all raters of this player, not only edits by one rater.
  -- The aggregate before/after and its indicator commit together.
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || p_user_id::text, 917));
  select round(avg(public.player_rating_overall(
    v_position, pace, passing, shooting, stamina, defending, awareness
  )))::integer into v_before
  from public.player_ratings where workspace_id = p_workspace_id and ratee_id = p_user_id;

  insert into public.player_ratings (
    workspace_id, rater_id, ratee_id,
    pace, passing, shooting, stamina, defending, awareness
  )
  values (
    p_workspace_id, v_uid, p_user_id,
    p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness
  )
  on conflict (workspace_id, rater_id, ratee_id) do update
  set pace = excluded.pace,
      passing = excluded.passing,
      shooting = excluded.shooting,
      stamina = excluded.stamina,
      defending = excluded.defending,
      awareness = excluded.awareness,
      updated_at = now()
  where (player_ratings.pace, player_ratings.passing, player_ratings.shooting,
         player_ratings.stamina, player_ratings.defending, player_ratings.awareness)
    is distinct from
        (excluded.pace, excluded.passing, excluded.shooting,
         excluded.stamina, excluded.defending, excluded.awareness);

  select round(avg(public.player_rating_overall(
    v_position, pace, passing, shooting, stamina, defending, awareness
  )))::integer into v_after
  from public.player_ratings where workspace_id = p_workspace_id and ratee_id = p_user_id;

  -- First-ever rating creates a baseline, not an improvement from zero.
  -- No-ops and changes too small to move the displayed total keep the latest
  -- meaningful comparison instead of manufacturing a new trend.
  if v_before is not null and v_before <> v_after then
    insert into public.player_rating_changes
      (workspace_id, ratee_id, position, previous_overall, current_overall, changed_at)
    values (p_workspace_id, p_user_id, v_position, v_before, v_after, clock_timestamp())
    on conflict (workspace_id, ratee_id) do update
    set position = excluded.position,
        previous_overall = excluded.previous_overall,
        current_overall = excluded.current_overall,
        changed_at = excluded.changed_at;
  end if;

  -- Return the refreshed anonymous aggregate with the write, avoiding a second
  -- client round trip.
  return json_build_object(
    'status', 'saved',
    'rating', public.get_player_rating(p_workspace_id, p_user_id)
  );
end;
$$;

revoke execute on function public.submit_player_rating(
  uuid, uuid, smallint, smallint, smallint, smallint, smallint, smallint
) from public, anon;
grant execute on function public.submit_player_rating(
  uuid, uuid, smallint, smallint, smallint, smallint, smallint, smallint
) to authenticated;


notify pgrst, 'reload schema';
