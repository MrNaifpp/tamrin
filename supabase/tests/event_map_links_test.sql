-- The pasted map link is kept per series (or per one-off) and read by members.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/event_map_links_test.sql

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
  ('71000000-0000-0000-0000-000000000001', 'map-owner@test.local'),
  ('71000000-0000-0000-0000-000000000002', 'map-member@test.local'),
  ('71000000-0000-0000-0000-000000000003', 'map-outsider@test.local');

insert into public.workspaces (id, name, owner_id)
values ('71000000-0000-0000-0000-0000000000a1', 'Map WS',
        '71000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id)
values ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000001'),
       ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000002');

do $$
declare
  v_series uuid;
  v_oneoff uuid;
  v_template uuid;
  v_next uuid;
  v_link text := 'https://l.hudhud.sa/p/01JZXAH59TYFQDDHGBW32KNCEV';
begin
  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000001');

  v_series := (public.create_event(
    p_creator_id => '71000000-0000-0000-0000-000000000001',
    p_workspace_id => '71000000-0000-0000-0000-0000000000a1',
    p_name => 'أسبوعي',
    p_start_date => now() + interval '2 days',
    p_end_date => now() + interval '2 days 2 hours',
    p_recurrence => 'weekly'
  ) ->> 'id')::uuid;
  v_oneoff := (public.create_event(
    p_creator_id => '71000000-0000-0000-0000-000000000001',
    p_workspace_id => '71000000-0000-0000-0000-0000000000a1',
    p_name => 'مرة',
    p_start_date => now() + interval '3 days',
    p_end_date => now() + interval '3 days 2 hours'
  ) ->> 'id')::uuid;
  select template_id into v_template from public.events where id = v_series;
  if v_template is null then raise exception 'FAIL: fixture series has no template'; end if;

  perform public.set_event_map_link(v_series, v_link);
  perform public.set_event_map_link(v_oneoff, '  https://maps.app.goo.gl/abc  ');

  if not exists (select 1 from public.event_map_links where template_id = v_template and url = v_link) then
    raise exception 'FAIL: a series keeps its link on the template';
  end if;

  -- Another occurrence of the same series shares the link.
  insert into public.events (creator_id, workspace_id, name, start_date, end_date, template_id)
  values ('71000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-0000000000a1',
          'أسبوعي', now() + interval '9 days', now() + interval '9 days 2 hours', v_template)
  returning id into v_next;

  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000002');
  if public.get_event_map_link(v_next) is distinct from v_link then
    raise exception 'FAIL: every occurrence of a series reads its link';
  end if;
  if public.get_event_map_link(v_oneoff) is distinct from 'https://maps.app.goo.gl/abc' then
    raise exception 'FAIL: a one-off reads its own, trimmed link';
  end if;

  begin
    perform public.set_event_map_link(v_series, 'https://example.com');
    raise exception 'FAIL: a member must not change the link';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000003');
  begin
    perform public.get_event_map_link(v_series);
    raise exception 'FAIL: an outsider must not read the link';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  perform pg_temp.set_auth('71000000-0000-0000-0000-000000000001');
  begin
    perform public.set_event_map_link(v_series, 'javascript:alert(1)');
    raise exception 'FAIL: only https links are kept';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  perform public.set_event_map_link(v_series, '');
  if exists (select 1 from public.event_map_links where template_id = v_template) then
    raise exception 'FAIL: an empty link removes it';
  end if;

  raise notice 'PASS: event map links';
end;
$$;

rollback;
