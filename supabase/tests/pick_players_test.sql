-- Picking players for a new event. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/pick_players_test.sql
--
-- O owns workspace A (members P1, P2) and workspace C (only O). P3 is in
-- someone else's workspace B. P4 once played in C. A guest (no account)
-- played in A.

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
  ('64000000-0000-0000-0000-000000000001', 'pick-owner@test.local'),
  ('64000000-0000-0000-0000-000000000002', 'pick-p1@test.local'),
  ('64000000-0000-0000-0000-000000000003', 'pick-p2@test.local'),
  ('64000000-0000-0000-0000-000000000004', 'pick-p3@test.local'),
  ('64000000-0000-0000-0000-000000000005', 'pick-p4@test.local'),
  ('64000000-0000-0000-0000-000000000006', 'pick-other-owner@test.local');

insert into public.users (user_id, name) values
  ('64000000-0000-0000-0000-000000000001', 'نايف'),
  ('64000000-0000-0000-0000-000000000002', 'باسل'),
  ('64000000-0000-0000-0000-000000000003', 'تركي'),
  ('64000000-0000-0000-0000-000000000004', 'ثامر'),
  ('64000000-0000-0000-0000-000000000005', 'جاسم'),
  ('64000000-0000-0000-0000-000000000006', 'حمد')
on conflict (user_id) do update set name = excluded.name;

insert into public.workspaces (id, name, owner_id) values
  ('64000000-0000-0000-0000-0000000000a1', 'شباب الخميس', '64000000-0000-0000-0000-000000000001'),
  ('64000000-0000-0000-0000-0000000000b1', 'غيرهم',       '64000000-0000-0000-0000-000000000006'),
  ('64000000-0000-0000-0000-0000000000c1', 'لحالي',       '64000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('64000000-0000-0000-0000-0000000000a1', '64000000-0000-0000-0000-000000000001'),
  ('64000000-0000-0000-0000-0000000000a1', '64000000-0000-0000-0000-000000000002'),
  ('64000000-0000-0000-0000-0000000000a1', '64000000-0000-0000-0000-000000000003'),
  ('64000000-0000-0000-0000-0000000000b1', '64000000-0000-0000-0000-000000000006'),
  ('64000000-0000-0000-0000-0000000000b1', '64000000-0000-0000-0000-000000000004'),
  ('64000000-0000-0000-0000-0000000000c1', '64000000-0000-0000-0000-000000000001')
on conflict do nothing;

insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, max_participants, published_at) values
  ('64000000-0000-0000-0000-0000000000e1', '64000000-0000-0000-0000-000000000001',
   '64000000-0000-0000-0000-0000000000a1', 'تمرين قديم', '2026-10-01 18:00+03', 0, 10, now()),
  ('64000000-0000-0000-0000-0000000000e2', '64000000-0000-0000-0000-000000000001',
   '64000000-0000-0000-0000-0000000000c1', 'تمرين أقدم', '2026-09-01 18:00+03', 0, 10, now());

-- Past events refuse new seats, so the history is written with triggers off.
set local session_replication_role = replica;
insert into public.event_participants (event_id, user_id, payment_status) values
  ('64000000-0000-0000-0000-0000000000e1', '64000000-0000-0000-0000-000000000002', 'confirmed'),
  ('64000000-0000-0000-0000-0000000000e2', '64000000-0000-0000-0000-000000000005', 'confirmed');
insert into public.event_participants (event_id, user_id, added_by, guest_name, payment_status) values
  ('64000000-0000-0000-0000-0000000000e1', null, '64000000-0000-0000-0000-000000000002', 'ضيف', 'confirmed');
set local session_replication_role = origin;

-- get_my_pick_sources: the owner sees group A only, and P1 + P4 as past players.
do $$
declare
  v json;
  v_group json;
  v_member_ids text;
  v_past_ids text;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  v := public.get_my_pick_sources();

  if json_array_length(v->'groups') <> 1 then
    raise exception 'expected 1 group, got %', v->'groups';
  end if;
  v_group := v->'groups'->0;
  if v_group->>'workspace_id' <> '64000000-0000-0000-0000-0000000000a1' then
    raise exception 'expected group A, got %', v_group;
  end if;
  select string_agg(m->>'user_id', ',' order by m->>'user_id') into v_member_ids
  from json_array_elements(v_group->'members') m;
  if v_member_ids <> '64000000-0000-0000-0000-000000000002,64000000-0000-0000-0000-000000000003' then
    raise exception 'group A members wrong: %', v_member_ids;
  end if;
  if (v_group->>'last_played_at')::timestamptz <> '2026-10-01 18:00+03'::timestamptz then
    raise exception 'last_played_at wrong: %', v_group->>'last_played_at';
  end if;
  if v_group->'members'->0->>'name' is null then
    raise exception 'member names missing: %', v_group->'members';
  end if;

  select string_agg(p->>'user_id', ',' order by p->>'user_id') into v_past_ids
  from json_array_elements(v->'past_players') p;
  if v_past_ids <> '64000000-0000-0000-0000-000000000002,64000000-0000-0000-0000-000000000005' then
    raise exception 'past players wrong: %', v_past_ids;
  end if;
end;
$$;

-- create_event_with_players --------------------------------------------------

insert into public.workspace_payment_methods (id, workspace_id, provider, mobile_number) values
  ('64000000-0000-0000-0000-0000000000f1', '64000000-0000-0000-0000-0000000000a1', 'cash', null);

create or replace function pg_temp.make_event(
  p_name text, p_players uuid[], p_price int default 100, p_max int default 10,
  p_workspace uuid default '64000000-0000-0000-0000-0000000000a1'
) returns uuid
language plpgsql as $$
declare v json;
begin
  v := public.create_event_with_players(
    p_creator_id => auth.uid(),
    p_workspace_id => p_workspace,
    p_name => p_name,
    p_start_date => now() + interval '3 days',
    p_end_date => now() + interval '3 days 2 hours',
    p_max_participants => p_max,
    p_total_price => p_price,
    p_payment_method_ids => case when p_price > 0
      then array['64000000-0000-0000-0000-0000000000f1'::uuid] else null end,
    p_player_ids => p_players
  );
  return (v->>'id')::uuid;
end;
$$;

-- seats picked players
do $$
declare v_event uuid;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  v_event := pg_temp.make_event('مقعد', array['64000000-0000-0000-0000-000000000002'::uuid]);
  if not exists (select 1 from public.event_participants
                 where event_id = v_event and user_id = '64000000-0000-0000-0000-000000000002'
                   and payment_status = 'pending') then
    raise exception 'seats picked players: P1 not seated as pending';
  end if;
  if exists (select 1 from public.event_participants
             where event_id = v_event and user_id = '64000000-0000-0000-0000-000000000003') then
    raise exception 'seats picked players: P2 was seated without being picked';
  end if;
end;
$$;

-- whole group gets one push
do $$
declare v_event uuid; v_bad int;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  v_event := pg_temp.make_event('الكل',
    array['64000000-0000-0000-0000-000000000002', '64000000-0000-0000-0000-000000000003']::uuid[]);
  select count(*) into v_bad from (
    select p.user_id
    from unnest(array['64000000-0000-0000-0000-000000000002',
                      '64000000-0000-0000-0000-000000000003']::uuid[]) as p(user_id)
    where (select count(*) from public.push_outbox po
           where po.event_id = v_event and po.user_id = p.user_id) <> 1
       or not exists (select 1 from public.push_outbox po
                      where po.event_id = v_event and po.user_id = p.user_id
                        and po.type = 'added_to_event'
                        and po.actor_id = '64000000-0000-0000-0000-000000000001')
  ) x;
  if v_bad <> 0 then
    raise exception 'whole group gets one push: %', (
      select json_agg(json_build_object('user', user_id, 'type', type))
      from public.push_outbox where event_id = v_event);
  end if;
end;
$$;

-- new member joins workspace
do $$
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  perform pg_temp.make_event('عضو جديد', array['64000000-0000-0000-0000-000000000005'::uuid]);
  if not exists (select 1 from public.workspace_members
                 where workspace_id = '64000000-0000-0000-0000-0000000000a1'
                   and user_id = '64000000-0000-0000-0000-000000000005') then
    raise exception 'new member joins workspace: P4 not a member of A';
  end if;
end;
$$;

-- too many players
do $$
declare v_hint text;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  begin
    perform pg_temp.make_event('زحمة',
      array['64000000-0000-0000-0000-000000000002', '64000000-0000-0000-0000-000000000003']::uuid[],
      100, 1);
    raise exception 'too many players: no error raised';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint is distinct from 'too_many_players' then raise; end if;
  end;
  if exists (select 1 from public.events where name = 'زحمة') then
    raise exception 'too many players: event was created';
  end if;
end;
$$;

-- organizer seat counts toward the limit: 2 seats, organizer + 2 players
do $$
declare v_hint text;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  begin
    perform pg_temp.make_event('زحمة ٢',
      array['64000000-0000-0000-0000-000000000002', '64000000-0000-0000-0000-000000000003']::uuid[],
      100, 2);
    raise exception 'organizer seat counts: no error raised';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint is distinct from 'too_many_players' then raise; end if;
  end;
end;
$$;

-- stranger refused
do $$
declare v_hint text;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  begin
    perform pg_temp.make_event('غريب', array['64000000-0000-0000-0000-000000000004'::uuid]);
    raise exception 'stranger refused: no error raised';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint is distinct from 'player_not_pickable' then raise; end if;
  end;
  if exists (select 1 from public.events where name = 'غريب') then
    raise exception 'stranger refused: event was created';
  end if;
end;
$$;

-- organizer id ignored
do $$
declare v_event uuid;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  v_event := pg_temp.make_event('أنا',
    array['64000000-0000-0000-0000-000000000001', '64000000-0000-0000-0000-000000000002']::uuid[]);
  -- create_event already seats the organizer; picking them adds nothing.
  if (select count(*) from public.event_participants
      where event_id = v_event and user_id = '64000000-0000-0000-0000-000000000001') <> 1 then
    raise exception 'organizer id ignored: organizer seat count is not 1';
  end if;
  if exists (select 1 from public.push_outbox
             where event_id = v_event and user_id = '64000000-0000-0000-0000-000000000001'
               and type = 'added_to_event') then
    raise exception 'organizer id ignored: organizer was told they were added';
  end if;
  if not exists (select 1 from public.event_participants
                 where event_id = v_event and user_id = '64000000-0000-0000-0000-000000000002') then
    raise exception 'organizer id ignored: P1 not seated';
  end if;
end;
$$;

-- free event seats confirmed
do $$
declare v_event uuid;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  v_event := pg_temp.make_event('مجاني', array['64000000-0000-0000-0000-000000000002'::uuid], 0);
  if not exists (select 1 from public.event_participants
                 where event_id = v_event and user_id = '64000000-0000-0000-0000-000000000002'
                   and payment_status = 'confirmed') then
    raise exception 'free event seats confirmed: P1 not confirmed';
  end if;
end;
$$;

-- not owner refused
do $$
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000002');
  begin
    perform pg_temp.make_event('مو لك', array['64000000-0000-0000-0000-000000000003'::uuid]);
    raise exception 'not owner refused: no error raised';
  exception when others then
    if sqlerrm not like 'Not authorized%' then raise; end if;
  end;
end;
$$;

-- debtor refused with a message for the organizer
set local session_replication_role = replica;
insert into public.events (id, creator_id, workspace_id, name, start_date,
                           total_price, price_per_person, max_participants, published_at) values
  ('64000000-0000-0000-0000-0000000000e3', '64000000-0000-0000-0000-000000000001',
   '64000000-0000-0000-0000-0000000000a1', 'تمرين ما انسدد', '2026-10-15 18:00+03', 100, 50, 2, now());
insert into public.event_participants (event_id, user_id, payment_status) values
  ('64000000-0000-0000-0000-0000000000e3', '64000000-0000-0000-0000-000000000003', 'pending');
set local session_replication_role = origin;

do $$
declare v_hint text;
begin
  if public.unpaid_debt_event('64000000-0000-0000-0000-0000000000a1',
                              '64000000-0000-0000-0000-000000000003') is null then
    raise exception 'debtor fixture: P2 has no debt';
  end if;
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000001');
  begin
    perform pg_temp.make_event('مديون', array['64000000-0000-0000-0000-000000000003'::uuid]);
    raise exception 'debtor refused: no error raised';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint is distinct from 'player_owes' then raise; end if;
  end;
end;
$$;

-- Someone who owns nothing has nothing to pick from.
do $$
declare v json;
begin
  perform pg_temp.set_auth('64000000-0000-0000-0000-000000000002');
  v := public.get_my_pick_sources();
  if json_array_length(v->'groups') <> 0 or json_array_length(v->'past_players') <> 0 then
    raise exception 'non-owner should see nothing, got %', v;
  end if;
end;
$$;

rollback;
