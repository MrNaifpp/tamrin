-- Volleyball positions and ratings. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/volleyball_ratings_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;
create or replace function pg_temp.check(ok boolean, message text) returns void
language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %', message; end if; end;
$$;

insert into auth.users (id, email) values
  ('31000000-0000-0000-0000-000000000001', 'volley-owner@test.local'),
  ('31000000-0000-0000-0000-000000000002', 'volley-a@test.local'),
  ('31000000-0000-0000-0000-000000000003', 'volley-b@test.local');
insert into public.users (user_id, name, postion) values
  ('31000000-0000-0000-0000-000000000001', 'المنظّم', 'وسط'),
  ('31000000-0000-0000-0000-000000000002', 'عضو أ', 'هجوم'),
  ('31000000-0000-0000-0000-000000000003', 'عضو ب', '');

do $$
declare
  owner uuid := '31000000-0000-0000-0000-000000000001';
  a uuid := '31000000-0000-0000-0000-000000000002';
  b uuid := '31000000-0000-0000-0000-000000000003';
  ws uuid;
  football_ws uuid;
  r json;
  failed boolean;
begin
  -- The weights, position by position: one dominant attribute at 100, the rest 0.
  perform pg_temp.check(public.volleyball_rating_overall('معدّ', 0, 100, 0, 0, 0, 0) = 35, 'setter: setting .35');
  perform pg_temp.check(public.volleyball_rating_overall('معدّ', 0, 0, 0, 0, 0, 100) = 25, 'setter: awareness .25');
  perform pg_temp.check(public.volleyball_rating_overall('مستقبل', 100, 0, 0, 0, 0, 0) = 30, 'receiver: receiving .30');
  perform pg_temp.check(public.volleyball_rating_overall('ضارب يسار', 0, 0, 100, 0, 0, 0) = 30, 'left hitter: attacking .30');
  perform pg_temp.check(public.volleyball_rating_overall('ضارب يسار', 100, 0, 0, 0, 0, 0) = 15, 'left hitter: receiving .15');
  perform pg_temp.check(public.volleyball_rating_overall('ضارب يمين', 0, 0, 0, 100, 0, 0) = 15, 'right hitter: blocking .15');
  perform pg_temp.check(public.volleyball_rating_overall('صادّ', 0, 0, 0, 100, 0, 0) = 30, 'middle blocker: blocking .30');
  perform pg_temp.check(public.volleyball_rating_overall('ليبرو', 100, 0, 0, 0, 0, 0) = 40, 'libero: receiving .40');
  perform pg_temp.check(public.volleyball_rating_overall('ليبرو', 0, 0, 100, 100, 100, 0) = 15, 'libero: attack, block, serve .05 each');
  perform pg_temp.check(public.volleyball_rating_overall('', 0, 0, 100, 0, 0, 0) = 30, 'blank scores as a left hitter');
  -- Every set sums to 1.00.
  perform pg_temp.check((select bool_and(public.volleyball_rating_overall(p, 100, 100, 100, 100, 100, 100) = 100)
    from unnest(public.sport_positions('volleyball')) p), 'every position sums to 100');

  perform pg_temp.set_auth(owner);
  ws := (public.create_workspace('طائرة الخميس', 'volleyball'::public.sport)->>'id')::uuid;
  football_ws := (public.create_workspace('كورة الأحد', 'soccer'::public.sport)->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values (ws, a), (ws, b), (football_ws, a);

  -- My sports: football's position writes through to the profile column.
  perform pg_temp.set_auth(a);
  r := public.set_my_sport_position('soccer', 'دفاع');
  perform pg_temp.check((select postion from public.users where user_id = a) = 'دفاع', 'football writes users.postion');
  r := public.set_my_sport_position('volleyball', null);
  perform pg_temp.check(json_array_length(r) = 2, 'a sport can be added before choosing a position');
  r := public.set_my_sport_position('volleyball', 'ليبرو');
  perform pg_temp.check((select position from public.user_sports where user_id = a and sport = 'volleyball') = 'ليبرو', 'volleyball position stored');
  perform pg_temp.check((select postion from public.users where user_id = a) = 'دفاع', 'volleyball leaves football alone');
  r := public.set_my_sport_position('volleyball', null);
  perform pg_temp.check((select position from public.user_sports where user_id = a and sport = 'volleyball') = 'ليبرو', 'adding again keeps the position');
  begin
    perform public.set_my_sport_position('volleyball', 'حارس');
    failed := false;
  exception when others then failed := true;
  end;
  perform pg_temp.check(failed, 'a football position is refused for volleyball');

  -- Ratings: position required, self refused, then a weighted average.
  perform pg_temp.set_auth(owner);
  r := public.submit_volleyball_rating(ws, b, 50::smallint, 50::smallint, 50::smallint, 50::smallint, 50::smallint, 50::smallint);
  perform pg_temp.check(r->>'status' = 'position_required', 'no volleyball position, no rating');
  r := public.submit_volleyball_rating(ws, owner, 50::smallint, 50::smallint, 50::smallint, 50::smallint, 50::smallint, 50::smallint);
  perform pg_temp.check(r->>'status' = 'is_self', 'no self rating');
  r := public.submit_volleyball_rating(ws, a, 100::smallint, 60::smallint, 0::smallint, 0::smallint, 0::smallint, 80::smallint);
  perform pg_temp.check(r->>'status' = 'saved', 'saved');
  -- Libero: 100*.40 + 60*.20 + 80*.25 = 72.
  perform pg_temp.check((r->'rating'->'average'->>'overall')::int = 72, 'libero overall uses libero weights');
  perform pg_temp.check(r->'rating'->>'position' = 'ليبرو' and r->'rating'->>'sport' = 'volleyball', 'summary names sport and position');
  begin
    perform public.submit_volleyball_rating(football_ws, a, 50::smallint, 50::smallint, 50::smallint, 50::smallint, 50::smallint, 50::smallint);
    failed := false;
  exception when others then failed := true;
  end;
  perform pg_temp.check(failed, 'volleyball ratings only in a volleyball group');

  -- A second rating moves the average and records the change.
  perform pg_temp.set_auth(b);
  r := public.submit_volleyball_rating(ws, a, 0::smallint, 0::smallint, 0::smallint, 0::smallint, 0::smallint, 0::smallint);
  perform pg_temp.check((r->'rating'->'average'->>'overall')::int = 36, 'average of rounded overalls');
  perform pg_temp.check((r->'rating'->'trend'->>'previous_overall')::int = 72, 'change recorded');

  -- The football rating of the same player is untouched.
  perform pg_temp.check(not exists(select 1 from public.player_ratings where ratee_id = a), 'football ratings separate');

  -- Removing a sport.
  perform pg_temp.set_auth(a);
  r := public.remove_my_sport('volleyball');
  perform pg_temp.check(json_array_length(r) = 1, 'sport removed');
end $$;

-- RPC-only tables.
set local role authenticated;
do $$
declare failed boolean;
begin
  begin perform * from public.volleyball_ratings; failed := false; exception when others then failed := true; end;
  if not failed then raise exception 'FAIL: volleyball_ratings readable'; end if;
  begin perform * from public.user_sports; failed := false; exception when others then failed := true; end;
  if not failed then raise exception 'FAIL: user_sports readable'; end if;
end $$;
reset role;

rollback;
