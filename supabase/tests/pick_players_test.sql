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
