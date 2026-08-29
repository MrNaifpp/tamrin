-- Sport enum test suite. Run against the LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_enum_test.sql
-- Everything runs in one transaction and rolls back.

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
-- Section 1: the type exists, with exactly the eight sports the
-- picker offers, in the picker's order.
-- ============================================================
do $$
declare
  labels text[];
begin
  select array_agg(e.enumlabel::text order by e.enumsortorder)
  into labels
  from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  where t.typname = 'sport';

  if labels is null then
    raise exception 'FAIL: type public.sport does not exist';
  end if;

  if labels <> array['soccer','basketball','volleyball','padel',
                     'tennis','cricket','running','cycling'] then
    raise exception 'FAIL: sport labels are %, expected the eight picker sports in order', labels;
  end if;
end $$;

-- ============================================================
-- Section 2: every sport renders the symbol the app expects.
-- ============================================================
do $$
declare
  pair record;
  got text;
begin
  for pair in
    select * from (values
      ('soccer',     'figure.soccer'),
      ('basketball', 'figure.basketball'),
      ('volleyball', 'figure.volleyball'),
      ('padel',      'figure.pickleball'),
      ('tennis',     'figure.tennis'),
      ('cricket',    'figure.cricket'),
      ('running',    'figure.run'),
      ('cycling',    'figure.outdoor.cycle')
    ) as t(sport, symbol)
  loop
    insert into public.workspaces (name, owner_id, sport)
    values ('نادي', '00000000-0000-0000-0000-000000000001', pair.sport::public.sport)
    returning symbol into got;

    if got is distinct from pair.symbol then
      raise exception 'FAIL: sport % rendered symbol %, expected %',
        pair.sport, got, pair.symbol;
    end if;
  end loop;
end $$;

-- ============================================================
-- Section 3: symbol is computed, not writable.
-- ============================================================
do $$
declare
  ok boolean := false;
begin
  begin
    insert into public.workspaces (name, owner_id, sport, symbol)
    values ('نادي', '00000000-0000-0000-0000-000000000001', 'padel', 'figure.soccer');
  exception when others then
    ok := true;
  end;

  if not ok then
    raise exception 'FAIL: symbol accepted a direct write; it must be generated';
  end if;
end $$;

-- ============================================================
-- Section 4: a workspace created without a sport is soccer, and
-- reads back the soccer symbol. This is the shape every row had
-- before the enum existed.
-- ============================================================
do $$
declare
  w public.workspaces;
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي', '00000000-0000-0000-0000-000000000001')
  returning * into w;

  if w.sport <> 'soccer' then
    raise exception 'FAIL: default sport is %, expected soccer', w.sport;
  end if;
  if w.symbol <> 'figure.soccer' then
    raise exception 'FAIL: default symbol is %, expected figure.soccer', w.symbol;
  end if;
end $$;

select 'workspace_sport_enum: all sections passed' as result;

rollback;
