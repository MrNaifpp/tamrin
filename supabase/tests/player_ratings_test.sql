-- Peer player rating tests. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/player_ratings_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text,
    true
  );
end;
$$;

insert into auth.users (id, email) values
  ('30000000-0000-0000-0000-000000000001', 'rating-owner@test.local'),
  ('30000000-0000-0000-0000-000000000002', 'rating-a@test.local'),
  ('30000000-0000-0000-0000-000000000003', 'rating-b@test.local'),
  ('30000000-0000-0000-0000-000000000004', 'rating-outsider@test.local'),
  ('30000000-0000-0000-0000-000000000005', 'rating-no-position@test.local');

insert into public.users (user_id, name, postion) values
  ('30000000-0000-0000-0000-000000000001', 'المنظّم', 'وسط'),
  ('30000000-0000-0000-0000-000000000002', 'عضو أ', 'هجوم'),
  ('30000000-0000-0000-0000-000000000003', 'عضو ب', 'دفاع'),
  ('30000000-0000-0000-0000-000000000004', 'غريب', 'حارس'),
  ('30000000-0000-0000-0000-000000000005', 'بلا مركز', '');

do $$
declare
  v_workspace json;
  v_workspace_id uuid;
  v_other_workspace json;
  v_other_workspace_id uuid;
  v_result json;
  v_rating json;
  v_failed boolean;
  v_count int;
begin
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000001');
  v_workspace := public.create_workspace('مجموعة التقييمات');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '30000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '30000000-0000-0000-0000-000000000003'),
    (v_workspace_id, '30000000-0000-0000-0000-000000000005');

  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000004');
  v_other_workspace := public.create_workspace('مجموعة ثانية');
  v_other_workspace_id := (v_other_workspace->>'id')::uuid;

  -- ------------------------------------------------------------------
  -- The weighting table, position by position.
  -- ------------------------------------------------------------------
  -- Midfielder: pass .30 + awareness .20 + shoot .15 + stamina .15
  --             + defend .10 + pace .10
  if public.player_rating_overall('وسط', 60, 90, 70, 80, 50, 85) <> 78 then
    raise exception 'FAIL: midfielder overall %',
      public.player_rating_overall('وسط', 60, 90, 70, 80, 50, 85);
  end if;
  -- Same six, scored as a forward: shooting carries the weight instead.
  if public.player_rating_overall('هجوم', 60, 90, 70, 80, 50, 85) <> 75 then
    raise exception 'FAIL: forward overall %',
      public.player_rating_overall('هجوم', 60, 90, 70, 80, 50, 85);
  end if;
  if public.player_rating_overall('دفاع', 60, 90, 70, 80, 50, 85) <> 71 then
    raise exception 'FAIL: defender overall %',
      public.player_rating_overall('دفاع', 60, 90, 70, 80, 50, 85);
  end if;
  -- Keeper: defend .35 + awareness .25 + stamina .15 + pass .10 + pace .10
  --         + shoot .05  →  69.25, which rounds up.
  if public.player_rating_overall('حارس', 60, 90, 70, 80, 50, 85) <> 69 then
    raise exception 'FAIL: goalkeeper overall %',
      public.player_rating_overall('حارس', 60, 90, 70, 80, 50, 85);
  end if;
  -- A custom or blank position is weighted as a defender.
  if public.player_rating_overall('جناح أيمن', 60, 90, 70, 80, 50, 85)
     <> public.player_rating_overall('دفاع', 60, 90, 70, 80, 50, 85) then
    raise exception 'FAIL: custom position did not fall back to defender';
  end if;
  if public.player_rating_overall('', 60, 90, 70, 80, 50, 85)
     <> public.player_rating_overall('دفاع', 60, 90, 70, 80, 50, 85) then
    raise exception 'FAIL: blank position did not fall back to defender';
  end if;
  if public.player_rating_overall(null, 100, 100, 100, 100, 100, 100) <> 100 then
    raise exception 'FAIL: all-100 rating is not 100';
  end if;
  -- Exact half-up boundary; this is also the Swift parity regression case.
  if public.player_rating_overall('وسط', 40, 97, 46, 50, 50, 50) <> 63 then
    raise exception 'FAIL: .5 boundary did not round up';
  end if;

  -- ------------------------------------------------------------------
  -- Empty state before anybody has rated.
  -- ------------------------------------------------------------------
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000002');
  v_rating := public.get_player_rating(v_workspace_id, '30000000-0000-0000-0000-000000000003');
  if (v_rating->>'has_rated')::boolean then
    raise exception 'FAIL: unrated caller reported as having rated';
  end if;
  -- A JSON null reads back as SQL NULL through ->>, so this is the whole check.
  if v_rating->>'average' is not null then
    raise exception 'FAIL: empty player returned an average: %', v_rating;
  end if;
  if (v_rating->>'ratings_count')::int <> 0 then
    raise exception 'FAIL: expected 0 raters, got %', v_rating->>'ratings_count';
  end if;
  if (v_rating->>'position') <> 'دفاع' then
    raise exception 'FAIL: position not reported, got %', v_rating->>'position';
  end if;

  -- ------------------------------------------------------------------
  -- Submitting, then revising.
  -- ------------------------------------------------------------------
  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000003',
    60::smallint, 90::smallint, 70::smallint,
    80::smallint, 50::smallint, 85::smallint
  );
  if v_result->>'status' <> 'saved' then
    raise exception 'FAIL: submit status %', v_result->>'status';
  end if;
  -- Rated as a defender: the same six the weighting block checked.
  if (v_result->'rating'->'average'->>'overall')::int <> 71 then
    raise exception 'FAIL: returned average overall %',
      v_result->'rating'->'average'->>'overall';
  end if;
  if (v_result->'rating'->>'ratings_count')::int <> 1 then
    raise exception 'FAIL: expected 1 rater after submit';
  end if;

  -- A second submission replaces the first rather than adding a rater.
  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000003',
    40::smallint, 40::smallint, 40::smallint,
    40::smallint, 40::smallint, 40::smallint
  );
  if (v_result->'rating'->>'ratings_count')::int <> 1 then
    raise exception 'FAIL: revision added a second rater';
  end if;
  if (v_result->'rating'->'average'->>'overall')::int <> 40 then
    raise exception 'FAIL: revision did not replace the previous rating';
  end if;

  -- A non-rater sees the anonymous average without receiving a rater id.
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000001');
  v_rating := public.get_player_rating(v_workspace_id, '30000000-0000-0000-0000-000000000003');
  if (v_rating->>'has_rated')::boolean
     or (v_rating->'average'->>'overall')::int <> 40 then
    raise exception 'FAIL: anonymous average not visible to a non-rater: %', v_rating;
  end if;

  -- The player can see their own anonymous average, but never receives a
  -- writable `mine` row because self-rating is forbidden.
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000003');
  v_rating := public.get_player_rating(v_workspace_id, '30000000-0000-0000-0000-000000000003');
  if (v_rating->'average'->>'overall')::int <> 40
     or v_rating->>'mine' is not null then
    raise exception 'FAIL: player could not read own anonymous average: %', v_rating;
  end if;

  -- ------------------------------------------------------------------
  -- Averaging across raters.
  -- ------------------------------------------------------------------
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000001');
  perform public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000003',
    80::smallint, 80::smallint, 80::smallint,
    80::smallint, 80::smallint, 80::smallint
  );
  v_rating := public.get_player_rating(v_workspace_id, '30000000-0000-0000-0000-000000000003');
  if (v_rating->>'ratings_count')::int <> 2 then
    raise exception 'FAIL: expected 2 raters, got %', v_rating->>'ratings_count';
  end if;
  -- (40 + 80) / 2 on every attribute.
  if (v_rating->'average'->>'overall')::int <> 60 then
    raise exception 'FAIL: average across raters %', v_rating->'average'->>'overall';
  end if;
  -- The caller's own rating comes back separately from the crowd's.
  if (v_rating->'mine'->>'overall')::int <> 80 then
    raise exception 'FAIL: own rating %', v_rating->'mine'->>'overall';
  end if;
  -- Anonymity: nothing in the payload names a rater.
  if v_rating::text like '%30000000-0000-0000-0000-0000000000%' then
    raise exception 'FAIL: a rater id appeared in the payload: %', v_rating;
  end if;

  -- Average the already-rounded Overall from every submitted row. These two
  -- are 63 and 62; their 62.5 mean must round to 63. Blending the raw attribute
  -- averages first would incorrectly return 62.
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000002');
  perform public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000003',
    67::smallint, 62::smallint, 62::smallint,
    62::smallint, 62::smallint, 62::smallint
  );
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000001');
  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000003',
    66::smallint, 61::smallint, 61::smallint,
    61::smallint, 61::smallint, 61::smallint
  );
  if (v_result->'rating'->'average'->>'overall')::int <> 63 then
    raise exception 'FAIL: did not average rounded individual Overalls: %',
      v_result->'rating'->'average'->>'overall';
  end if;

  -- ------------------------------------------------------------------
  -- Refusals.
  -- ------------------------------------------------------------------
  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000001',
    50::smallint, 50::smallint, 50::smallint,
    50::smallint, 50::smallint, 50::smallint
  );
  if v_result->>'status' <> 'is_self' then
    raise exception 'FAIL: self-rating was not refused, got %', v_result->>'status';
  end if;

  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000004',
    50::smallint, 50::smallint, 50::smallint,
    50::smallint, 50::smallint, 50::smallint
  );
  if v_result->>'status' <> 'not_a_member' then
    raise exception 'FAIL: rated a non-member, got %', v_result->>'status';
  end if;

  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000005',
    50::smallint, 50::smallint, 50::smallint,
    50::smallint, 50::smallint, 50::smallint
  );
  if v_result->>'status' <> 'position_required' then
    raise exception 'FAIL: player without a position was rated, got %', v_result->>'status';
  end if;

  v_result := public.submit_player_rating(
    v_workspace_id, '30000000-0000-0000-0000-000000000003',
    150::smallint, 50::smallint, 50::smallint,
    50::smallint, 50::smallint, 50::smallint
  );
  if v_result->>'status' <> 'out_of_range' then
    raise exception 'FAIL: out-of-range value accepted, got %', v_result->>'status';
  end if;

  -- An outsider cannot read a rating inside a group they are not in.
  perform pg_temp.set_auth('30000000-0000-0000-0000-000000000004');
  v_failed := false;
  begin
    perform public.get_player_rating(v_workspace_id, '30000000-0000-0000-0000-000000000003');
  exception when others then
    v_failed := sqlerrm = 'Not a workspace member';
  end;
  if not v_failed then raise exception 'FAIL: outsider read a rating'; end if;

  -- ------------------------------------------------------------------
  -- Ratings are scoped to one group.
  -- ------------------------------------------------------------------
  select count(*) into v_count
  from public.player_ratings
  where workspace_id = v_other_workspace_id;
  if v_count <> 0 then
    raise exception 'FAIL: ratings leaked into another workspace';
  end if;

  -- Hand the generated id to the role-level permission test below without a
  -- temp table whose ownership would itself affect that permission test.
  perform set_config('test.rating_workspace_id', v_workspace_id::text, true);
end $$;

-- The table itself is RPC-only. Change role outside PL/pgSQL: SET ROLE inside
-- a function-like block is restricted by PostgreSQL and would only test the
-- block, not the application's actual database role.
set local role authenticated;

do $$
declare
  v_workspace_id uuid := current_setting('test.rating_workspace_id')::uuid;
begin
  begin
    insert into public.player_ratings (
      workspace_id, rater_id, ratee_id,
      pace, passing, shooting, stamina, defending, awareness
    ) values (
      v_workspace_id, '30000000-0000-0000-0000-000000000004',
      '30000000-0000-0000-0000-000000000003', 99, 99, 99, 99, 99, 99
    );
    raise exception 'FAIL: direct insert into player_ratings';
  exception when insufficient_privilege then
    null;
  end;

  begin
    perform count(*) from public.player_ratings;
    raise exception 'FAIL: direct select from player_ratings';
  exception when insufficient_privilege then
    null;
  end;
end $$;

reset role;

rollback;
