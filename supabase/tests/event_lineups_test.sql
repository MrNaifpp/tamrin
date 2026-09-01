-- Lineup suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_lineups_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local'),
  ('00000000-0000-0000-0000-000000000002', 'player@test.local'),
  ('00000000-0000-0000-0000-000000000003', 'outsider@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك'),
  ('00000000-0000-0000-0000-000000000002', 'لاعب'),
  ('00000000-0000-0000-0000-000000000003', 'غريب');

-- Fixture: one workspace, one published exercise, two seats.
create or replace function pg_temp.fixture(
  out w_id uuid, out e_id uuid, out p_owner uuid, out p_player uuid
) language plpgsql as $$
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي', '00000000-0000-0000-0000-000000000001')
  returning id into w_id;

  insert into public.workspace_members (workspace_id, user_id) values
    (w_id, '00000000-0000-0000-0000-000000000001'),
    (w_id, '00000000-0000-0000-0000-000000000002');

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_id, '00000000-0000-0000-0000-000000000001', 'تمرين', now() + interval '1 day', now())
  returning id into e_id;

  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-000000000001') returning id into p_owner;
  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-000000000002') returning id into p_player;
end;
$$;

-- ============================================================
-- Section 1: the owner saves a split, and reads it back in order.
-- ============================================================
do $$
declare
  f record;
  lineup json;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');

  perform public.save_event_lineup(
    f.e_id,
    array[f.p_owner],
    array[f.p_player],
    json_build_object(f.p_player::text, 'midfielder')::jsonb
  );

  lineup := public.get_event_lineup(f.e_id);
  if lineup is null then
    raise exception 'FAIL: the owner cannot read the lineup he just saved';
  end if;
  if lineup->>'status' <> 'draft' then
    raise exception 'FAIL: a fresh lineup is %, expected draft', lineup->>'status';
  end if;
  if (lineup->'first'->>0)::uuid <> f.p_owner then
    raise exception 'FAIL: side one holds the wrong participant';
  end if;
  if lineup->'positions'->>(f.p_player::text) <> 'midfielder' then
    raise exception 'FAIL: the position override did not survive the save';
  end if;
end $$;

-- ============================================================
-- Section 2: a draft is invisible to a player; publishing shows it.
-- ============================================================
do $$
declare
  f record;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  if public.get_event_lineup(f.e_id) is not null then
    raise exception 'FAIL: a player can see a draft lineup';
  end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  if public.get_event_lineup(f.e_id) is null then
    raise exception 'FAIL: a player cannot see a published lineup';
  end if;
end $$;

-- ============================================================
-- Section 3: everyone else is refused.
-- ============================================================
do $$
declare
  f record;
  denied boolean := false;
begin
  select * from pg_temp.fixture() into f;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  begin
    perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);
  exception when others then
    denied := true;
  end;
  if not denied then
    raise exception 'FAIL: a player saved a lineup';
  end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000003');
  if public.get_event_lineup(f.e_id) is not null then
    raise exception 'FAIL: an outsider read a published lineup';
  end if;
end $$;

-- ============================================================
-- Section 4: the split has to be real. A stranger to this
-- exercise, a duplicate, and an invented position are refused.
-- ============================================================
do $$
declare
  f record;
  other record;
  denied boolean;
begin
  select * from pg_temp.fixture() into f;
  select * from pg_temp.fixture() into other;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');

  denied := false;
  begin
    perform public.save_event_lineup(f.e_id, array[other.p_owner], array[f.p_player], '{}'::jsonb);
  exception when others then denied := true; end;
  if not denied then
    raise exception 'FAIL: a participant of another exercise was placed';
  end if;

  denied := false;
  begin
    perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_owner], '{}'::jsonb);
  exception when others then denied := true; end;
  if not denied then
    raise exception 'FAIL: one participant was placed on both sides';
  end if;

  denied := false;
  begin
    perform public.save_event_lineup(
      f.e_id, array[f.p_owner], array[f.p_player],
      json_build_object(f.p_player::text, 'striker')::jsonb
    );
  exception when others then denied := true; end;
  if not denied then
    raise exception 'FAIL: an unknown position was accepted';
  end if;
end $$;

-- ============================================================
-- Section 5: a correction after publishing stays published, and a
-- player who leaves takes his slot with him.
-- ============================================================
do $$
declare
  f record;
  lineup json;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);
  perform public.publish_event_lineup(f.e_id);
  perform public.save_event_lineup(f.e_id, array[f.p_player], array[f.p_owner], '{}'::jsonb);

  lineup := public.get_event_lineup(f.e_id);
  if lineup->>'status' <> 'published' then
    raise exception 'FAIL: correcting a published lineup returned it to %', lineup->>'status';
  end if;

  delete from public.event_participants where id = f.p_player;
  lineup := public.get_event_lineup(f.e_id);
  if json_array_length(lineup->'first') <> 0 then
    raise exception 'FAIL: a departed player kept his slot';
  end if;
end $$;

-- ============================================================
-- Section 6: publishing tells the players, once.
-- ============================================================
do $$
declare
  f record;
  v_pushes integer;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);

  select count(*) into v_pushes from public.push_outbox
  where event_id = f.e_id and type = 'lineup_published';
  if v_pushes <> 0 then
    raise exception 'FAIL: saving a draft already announced the lineup';
  end if;

  perform public.publish_event_lineup(f.e_id);

  select count(*) into v_pushes from public.push_outbox
  where event_id = f.e_id and type = 'lineup_published';
  if v_pushes <> 1 then
    raise exception 'FAIL: publishing queued % notifications, expected one per seated player except the organizer', v_pushes;
  end if;

  -- The organizer does not hear about his own publish.
  if exists (
    select 1 from public.push_outbox
    where event_id = f.e_id and type = 'lineup_published'
      and user_id = '00000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'FAIL: the organizer was notified of his own lineup';
  end if;

  -- A correction runs through publish again and must stay quiet.
  perform public.save_event_lineup(f.e_id, array[f.p_player], array[f.p_owner], '{}'::jsonb);
  perform public.publish_event_lineup(f.e_id);

  select count(*) into v_pushes from public.push_outbox
  where event_id = f.e_id and type = 'lineup_published';
  if v_pushes <> 1 then
    raise exception 'FAIL: correcting a published lineup announced it again (% total)', v_pushes;
  end if;
end $$;

select 'event_lineups: all sections passed' as result;

rollback;
