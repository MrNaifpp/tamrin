-- Sport-aware workspace RPC suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_rpcs_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك');

-- ============================================================
-- Section 1: the sport overload writes the sport.
-- ============================================================
do $$
declare
  result json;
  w_id uuid;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  result := public.create_workspace('نادي البادل', 'padel'::public.sport);
  w_id := (result->>'id')::uuid;

  select sport into got from public.workspaces where id = w_id;
  if got <> 'padel' then
    raise exception 'FAIL: create_workspace(sport) stored %, expected padel', got;
  end if;

  if result->>'symbol' <> 'figure.pickleball' then
    raise exception 'FAIL: returned symbol is %, expected figure.pickleball', result->>'symbol';
  end if;
end $$;

-- ============================================================
-- Section 2: the legacy symbol overload still works, and no
-- longer writes symbol directly.
-- ============================================================
do $$
declare
  result json;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  result := public.create_workspace('نادي التنس', 'figure.tennis');

  select sport into got from public.workspaces where id = (result->>'id')::uuid;
  if got <> 'tennis' then
    raise exception 'FAIL: symbol overload stored %, expected tennis', got;
  end if;
end $$;

-- ============================================================
-- Section 3: an unknown symbol falls back to soccer rather than
-- failing. Older builds send whatever they had.
-- ============================================================
do $$
declare
  result json;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  result := public.create_workspace('نادي قديم', 'figure.something.unknown');

  select sport into got from public.workspaces where id = (result->>'id')::uuid;
  if got <> 'soccer' then
    raise exception 'FAIL: unknown symbol stored %, expected soccer', got;
  end if;
end $$;

-- ============================================================
-- Section 4: update_workspace changes the sport, owner only.
-- ============================================================
do $$
declare
  w_id uuid;
  got public.sport;
  denied boolean := false;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w_id := (public.create_workspace('نادي', 'soccer'::public.sport)->>'id')::uuid;

  perform public.update_workspace(w_id, 'نادي', 'volleyball'::public.sport);
  select sport into got from public.workspaces where id = w_id;
  if got <> 'volleyball' then
    raise exception 'FAIL: update_workspace stored %, expected volleyball', got;
  end if;

  insert into auth.users (id, email)
  values ('00000000-0000-0000-0000-000000000009', 'outsider@test.local');
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000009');
  begin
    perform public.update_workspace(w_id, 'نادي', 'tennis'::public.sport);
  exception when others then
    denied := true;
  end;
  if not denied then
    raise exception 'FAIL: a non owner changed the sport';
  end if;
end $$;

-- ============================================================
-- Section 5: get_my_workspaces carries the sport.
-- ============================================================
do $$
declare
  feed json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_workspaces();

  if not (feed::text like '%"sport"%') then
    raise exception 'FAIL: get_my_workspaces does not return a sport key';
  end if;
end $$;

-- ============================================================
-- Section 6: editing an exercise still works. update_exercise_template
-- wrote `symbol` directly, which is an error now that the column is
-- generated, so this is the section that catches a half done migration.
-- ============================================================
do $$
declare
  w_id uuid;
  e_id uuid;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w_id := (public.create_workspace('نادي', 'soccer'::public.sport)->>'id')::uuid;

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_id, '00000000-0000-0000-0000-000000000001', 'تمرين', now() + interval '1 day', now())
  returning id into e_id;

  perform public.update_exercise_template(
    w_id, e_id, 'occurrence_only', 'نادي البادل', 'figure.pickleball', 'تمرين',
    -- Free, so this section is not also asserting the payment rules: a
    -- priced exercise requires a payment destination, which has nothing to
    -- do with the sport being written.
    'الملعب', now() + interval '1 day', now() + interval '1 day 2 hours',
    14, 0, null::double precision, null::double precision,
    null::jsonb, null::uuid[]
  );

  select sport into got from public.workspaces where id = w_id;
  if got <> 'padel' then
    raise exception 'FAIL: editing the exercise stored sport %, expected padel', got;
  end if;
end $$;

-- ============================================================
-- Section 7: the colour overloads, which are the pair the app
-- actually calls. The three argument symbol version was the last
-- function still inserting into the generated column.
-- ============================================================
do $$
declare
  result json;
  got public.sport;
  got_color text;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');

  result := public.create_workspace('نادي السلة', 'basketball'::public.sport, 'lime');
  select sport, color into got, got_color
  from public.workspaces where id = (result->>'id')::uuid;
  if got <> 'basketball' or got_color <> 'lime' then
    raise exception 'FAIL: create_workspace(sport, color) stored %/%', got, got_color;
  end if;

  result := public.create_workspace('نادي الطائرة', 'figure.volleyball', 'red');
  select sport, color into got, got_color
  from public.workspaces where id = (result->>'id')::uuid;
  if got <> 'volleyball' or got_color <> 'red' then
    raise exception 'FAIL: create_workspace(symbol, color) stored %/%', got, got_color;
  end if;
end $$;

-- ============================================================
-- Section 8: nothing writes the generated column any more. This
-- is the guard that catches an overload nobody remembered: the
-- write only fails when that particular function is called, which
-- a test of the other overloads will not reach.
-- ============================================================
do $$
declare
  offenders text;
begin
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
  into offenders
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and (p.prosrc ~* 'insert into public\.workspaces[^;]*symbol'
         or p.prosrc ~* 'set[^;]*symbol\s*=');

  if offenders is not null then
    raise exception 'FAIL: these functions still write workspaces.symbol: %', offenders;
  end if;
end $$;

select 'workspace_sport_rpcs: all sections passed' as result;

rollback;
