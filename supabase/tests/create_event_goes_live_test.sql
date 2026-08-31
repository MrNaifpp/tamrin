-- Creating an exercise puts it in front of the group. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/create_event_goes_live_test.sql
--
-- There is no draft state left to be in, so there is nothing to publish and
-- no way for an exercise to exist that its own group cannot see.

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
  ('62000000-0000-0000-0000-000000000001', 'live-owner@test.local'),
  ('62000000-0000-0000-0000-000000000002', 'live-member@test.local');

insert into public.workspaces (id, name, owner_id)
values ('62000000-0000-0000-0000-0000000000a1', 'Live WS',
        '62000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id)
values ('62000000-0000-0000-0000-0000000000a1', '62000000-0000-0000-0000-000000000001'),
       ('62000000-0000-0000-0000-0000000000a1', '62000000-0000-0000-0000-000000000002');

do $$
declare
  v_result json;
  v_event_id uuid;
  v_template_id uuid;
  v_count integer;
  v_feed json;
begin
  perform pg_temp.set_auth('62000000-0000-0000-0000-000000000001');

  v_result := public.create_event(
    p_creator_id => '62000000-0000-0000-0000-000000000001',
    p_workspace_id => '62000000-0000-0000-0000-0000000000a1',
    p_name => 'تمرين مباشر',
    p_start_date => now() + interval '2 days',
    p_end_date => now() + interval '2 days 2 hours',
    p_max_participants => 12
  );
  v_event_id := (v_result ->> 'id')::uuid;

  if (select published_at from public.events where id = v_event_id) is null then
    raise exception 'FAIL: a created exercise must be live immediately';
  end if;

  if not exists (
    select 1 from public.event_member_responses
    where event_id = v_event_id
      and user_id = '62000000-0000-0000-0000-000000000002'
  ) then
    raise exception 'FAIL: creating an exercise must invite the group';
  end if;

  if not exists (
    select 1 from public.push_outbox
    where event_id = v_event_id
      and user_id = '62000000-0000-0000-0000-000000000002'
      and type = 'event_invited'
  ) then
    raise exception 'FAIL: creating an exercise must notify the group';
  end if;

  -- The organizer is already seated by create_event; they are not invited to
  -- their own exercise and must not be told about it.
  if exists (
    select 1 from public.push_outbox
    where event_id = v_event_id
      and user_id = '62000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'FAIL: the organizer was notified of their own exercise';
  end if;

  -- The member can see it without anyone publishing anything.
  perform pg_temp.set_auth('62000000-0000-0000-0000-000000000002');
  v_feed := public.get_workspace_events('62000000-0000-0000-0000-0000000000a1');
  select count(*) into v_count from json_array_elements(v_feed) item
  where (item->>'id')::uuid = v_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: a member cannot see the new exercise: %', v_feed;
  end if;

  -- A weekly exercise publishes its template too, or the series behind it
  -- stays invisible to everyone but its organizer.
  perform pg_temp.set_auth('62000000-0000-0000-0000-000000000001');
  v_result := public.create_event(
    p_creator_id => '62000000-0000-0000-0000-000000000001',
    p_workspace_id => '62000000-0000-0000-0000-0000000000a1',
    p_name => 'تمرين أسبوعي',
    p_start_date => now() + interval '3 days',
    p_end_date => now() + interval '3 days 2 hours',
    p_max_participants => 12,
    p_recurrence => 'weekly'
  );
  v_template_id := (v_result ->> 'template_id')::uuid;
  if v_template_id is null then
    raise exception 'FAIL: weekly fixture did not produce a template: %', v_result;
  end if;
  if (select published_at from public.event_templates where id = v_template_id) is null then
    raise exception 'FAIL: a weekly exercise left its template unpublished';
  end if;

  -- Nothing is left to publish.
  if exists (select 1 from pg_proc where proname = 'publish_event') then
    raise exception 'FAIL: publish_event still exists';
  end if;
end;
$$;

rollback;
