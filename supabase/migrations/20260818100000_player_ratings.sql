-- Peer player ratings, scoped to one workspace.
--
-- Every member rates every other member on six attributes (0–100). The six are
-- collapsed into one Overall using weights that depend on the player's own
-- position, so a defender is not judged by a striker's yardstick.
--
-- Privacy is deliberately enforced here rather than in the client:
--
--   * No RPC ever returns a rater id. What a member reads back is
--     an average and a count; who contributed is never on the wire, so it
--     cannot leak through a hand-rolled request or a future screen.
--     The player can therefore see their own score without learning who
--     submitted it.
--
-- The table is RPC-only: RLS is on with no policies, and no direct grants.

create table if not exists public.player_ratings (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  rater_id uuid not null references auth.users(id) on delete cascade,
  ratee_id uuid not null references auth.users(id) on delete cascade,
  pace smallint not null check (pace between 0 and 100),
  passing smallint not null check (passing between 0 and 100),
  shooting smallint not null check (shooting between 0 and 100),
  stamina smallint not null check (stamina between 0 and 100),
  defending smallint not null check (defending between 0 and 100),
  awareness smallint not null check (awareness between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, rater_id, ratee_id),
  constraint player_ratings_no_self check (rater_id <> ratee_id)
);

create index if not exists idx_player_ratings_ratee
  on public.player_ratings(workspace_id, ratee_id);

alter table public.player_ratings enable row level security;
revoke all on table public.player_ratings from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Overall: the weighted blend, rounded to a whole number.
--
-- Weights are per position and each set sums to 1.00. Anything outside the
-- known positions — a custom position typed into the profile, or a blank one —
-- is scored on the defender's set for read-only legacy data. New writes reject
-- a missing/unknown position. The goalkeeper has his own set: he is judged on
-- stopping and reading the ball, so defending and awareness carry more than
-- they do for an outfield defender and shooting is left a token weight. The
-- Swift side mirrors this table so the flow can show a live Overall before it
-- submits; the two must be changed together.
-- --------------------------------------------------------------------------
create or replace function public.player_rating_overall(
  p_position text,
  p_pace numeric,
  p_passing numeric,
  p_shooting numeric,
  p_stamina numeric,
  p_defending numeric,
  p_awareness numeric
)
returns integer
language sql
immutable
set search_path = public
as $$
  select case coalesce(nullif(trim(p_position), ''), 'دفاع')
    when 'وسط' then round(
      p_passing * 0.30 + p_awareness * 0.20 + p_shooting * 0.15
      + p_stamina * 0.15 + p_defending * 0.10 + p_pace * 0.10
    )
    when 'هجوم' then round(
      p_shooting * 0.30 + p_awareness * 0.20 + p_passing * 0.15
      + p_stamina * 0.15 + p_defending * 0.10 + p_pace * 0.10
    )
    when 'حارس' then round(
      p_defending * 0.35 + p_awareness * 0.25 + p_stamina * 0.15
      + p_passing * 0.10 + p_pace * 0.10 + p_shooting * 0.05
    )
    else round(
      p_defending * 0.30 + p_awareness * 0.20 + p_passing * 0.15
      + p_stamina * 0.15 + p_shooting * 0.10 + p_pace * 0.10
    )
  end::integer;
$$;

revoke execute on function public.player_rating_overall(text, numeric, numeric, numeric, numeric, numeric, numeric)
  from public, anon;
grant execute on function public.player_rating_overall(text, numeric, numeric, numeric, numeric, numeric, numeric)
  to authenticated;

-- --------------------------------------------------------------------------
-- get_player_rating: what one member may know about another's rating.
--
-- The anonymous average is returned whenever at least one rating exists,
-- including when the player opens their own sheet. `mine` is still only the
-- caller's row, which allows revising a rating without exposing anybody else.
-- --------------------------------------------------------------------------
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
  where usr.user_id = p_user_id;
  if coalesce(trim(v_position), '') not in ('حارس', 'دفاع', 'وسط', 'هجوم') then
    return json_build_object('status', 'position_required');
  end if;
  if num_nonnulls(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) <> 6
     or least(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) < 0
     or greatest(p_pace, p_passing, p_shooting, p_stamina, p_defending, p_awareness) > 100 then
    return json_build_object('status', 'out_of_range');
  end if;

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
      updated_at = now();

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

-- --------------------------------------------------------------------------
-- The roster now carries each player's position: the player sheet leads with
-- it, and the rating flow needs it to weight the Overall it previews.
-- --------------------------------------------------------------------------
create or replace function public.get_event_participants_lifecycle_impl(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_event public.events;
  v_uid uuid := auth.uid();
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(x) order by x.joined_at asc), '[]'::json)
    from (
      select
        ep.id as participant_id,
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, au.email, ep.guest_name) as display_name,
        usr.avatar_url,
        usr.postion as player_position,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id
          then ep.payment_status else null end as payment_status,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id
          then ep.payment_provider else null end as payment_provider,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.payment_method_id else null end as payment_method_id,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_number else null end as paid_to_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_iban else null end as paid_to_iban,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_account_number else null end as paid_to_account_number,
        case when v_uid = v_event.creator_id
          then ep.paid_price_per_person else null end as paid_price_per_person,
        case when v_uid = v_event.creator_id
          then ep.payment_group_size else null end as payment_group_size,
        ep.guest_name,
        ep.added_by,
        ep.added_manually,
        case when v_uid = v_event.creator_id
          then ep.payment_reminder_sent_at else null end as payment_reminder_sent_at
      from public.event_participants ep
      left join auth.users au on au.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id
    ) x
  );
end;
$$;

revoke execute on function public.get_event_participants_lifecycle_impl(uuid)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
