-- Workspace test suite. Run against the LOCAL stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
-- Everything runs in one transaction and rolls back.

begin;

-- Impersonation helper: makes auth.uid() return the given uuid.
create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

-- Fixture users (local auth schema accepts direct inserts as postgres).
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local'),
  ('00000000-0000-0000-0000-000000000002', 'member@test.local'),
  ('00000000-0000-0000-0000-000000000003', 'outsider@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك'),
  ('00000000-0000-0000-0000-000000000002', 'عضو'),
  ('00000000-0000-0000-0000-000000000003', 'غريب');

-- ============================================================
-- Section 1: tables + is_workspace_member
-- ============================================================
do $$
declare
  w_id uuid;
begin
  insert into public.workspaces (name, owner_id)
  values ('شباب الحي', '00000000-0000-0000-0000-000000000001')
  returning id into w_id;

  -- invite_code default generated, 12 chars
  perform 1 from public.workspaces
    where id = w_id and length(invite_code) = 12;
  if not found then raise exception 'FAIL: invite_code not generated'; end if;

  insert into public.workspace_members (workspace_id, user_id)
  values (w_id, '00000000-0000-0000-0000-000000000001');

  if not public.is_workspace_member(w_id, '00000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: owner should be member';
  end if;
  if public.is_workspace_member(w_id, '00000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL: outsider should not be member';
  end if;
end $$;

-- ============================================================
-- Section 2: events.workspace_id + membership-based events RLS
-- ============================================================
do $$
declare
  w_id uuid;
  e_id uuid;
  visible int;
begin
  insert into public.workspaces (name, owner_id)
  values ('مساحة الأحداث', '00000000-0000-0000-0000-000000000001')
  returning id into w_id;
  insert into public.workspace_members (workspace_id, user_id) values
    (w_id, '00000000-0000-0000-0000-000000000001'),
    (w_id, '00000000-0000-0000-0000-000000000002');

  -- workspace_id is required
  begin
    insert into public.events (creator_id, name, start_date)
    values ('00000000-0000-0000-0000-000000000001', 'بدون مساحة', now() + interval '1 day');
    raise exception 'FAIL: event insert without workspace_id should be rejected';
  exception when not_null_violation then null;
  end;

  insert into public.events (creator_id, name, start_date, workspace_id)
  values ('00000000-0000-0000-0000-000000000001', 'حدث المساحة', now() + interval '1 day', w_id)
  returning id into e_id;

  -- RLS backstop: member sees the event, outsider does not.
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  set local role authenticated;
  select count(*) into visible from public.events where id = e_id;
  if visible <> 1 then raise exception 'FAIL: member cannot select workspace event'; end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000003');
  set local role authenticated;
  select count(*) into visible from public.events where id = e_id;
  if visible <> 0 then raise exception 'FAIL: outsider can select workspace event'; end if;

  reset role;
end $$;

-- ============================================================
-- Section 3: workspace RPCs (auth.uid()-based)
-- ============================================================
do $$
declare
  w json; w_id uuid; code text; new_code text; r json;
  cnt int;
begin
  -- create_workspace
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة الاختبار', 'figure.basketball');
  w_id := (w->>'id')::uuid;
  code := w->>'invite_code';
  if w->>'symbol' <> 'figure.basketball' then
    raise exception 'FAIL: create_workspace did not persist symbol';
  end if;
  if not public.is_workspace_member(w_id, '00000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: create_workspace did not add owner member row';
  end if;

  -- join_workspace via code (idempotent)
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  r := public.join_workspace(code);
  if r->>'status' <> 'joined' then raise exception 'FAIL: join_workspace'; end if;
  r := public.join_workspace(code);
  if r->>'status' <> 'joined' then raise exception 'FAIL: join_workspace not idempotent'; end if;

  -- get_workspace_by_invite preview
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000003');
  r := public.get_workspace_by_invite(code);
  if (r->>'member_count')::int <> 2 then raise exception 'FAIL: invite preview member_count'; end if;
  if (r->>'is_member')::boolean then raise exception 'FAIL: outsider flagged as member'; end if;

  -- get_workspace: members only
  begin
    r := public.get_workspace(w_id);
    raise exception 'FAIL: outsider could call get_workspace';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- get_my_workspaces
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  r := public.get_my_workspaces();
  select json_array_length(r) into cnt;
  if cnt < 1 then raise exception 'FAIL: get_my_workspaces empty for member'; end if;
  if not exists (
    select 1
    from json_array_elements(r) item
    where (item->>'id')::uuid = w_id
      and item->>'symbol' = 'figure.basketball'
  ) then
    raise exception 'FAIL: get_my_workspaces did not return symbol';
  end if;

  -- owner-only ops rejected for plain member
  begin
    r := public.update_workspace(w_id, 'اسم جديد');
    raise exception 'FAIL: member could rename workspace';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    r := public.delete_workspace(w_id);
    raise exception 'FAIL: member could delete workspace';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- owner cannot leave
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  begin
    r := public.leave_workspace(w_id);
    raise exception 'FAIL: owner could leave workspace';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- regenerate kills the old code
  r := public.regenerate_invite_code(w_id);
  new_code := r->>'invite_code';
  if new_code = code then raise exception 'FAIL: invite code unchanged'; end if;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000003');
  begin
    r := public.join_workspace(code);
    raise exception 'FAIL: old invite code still works';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- leave_workspace removes member + their upcoming participant rows
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  declare
    e_up uuid; e_past uuid;
  begin
    insert into public.events (creator_id, name, start_date, end_date, workspace_id) values
      ('00000000-0000-0000-0000-000000000001', 'قادم', now() + interval '1 day', now() + interval '1 day 2 hours', w_id)
      returning id into e_up;
    insert into public.events (creator_id, name, start_date, end_date, workspace_id) values
      ('00000000-0000-0000-0000-000000000001', 'ماضي', now() - interval '2 day', now() - interval '2 day' + interval '2 hours', w_id)
      returning id into e_past;
    insert into public.event_participants (event_id, user_id, payment_status) values
      (e_up,   '00000000-0000-0000-0000-000000000002', 'confirmed'),
      (e_past, '00000000-0000-0000-0000-000000000002', 'confirmed');

    perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
    r := public.leave_workspace(w_id);
    if r->>'status' <> 'left' then raise exception 'FAIL: leave_workspace status %', r->>'status'; end if;

    select count(*) into cnt from public.event_participants
      where event_id = e_up and user_id = '00000000-0000-0000-0000-000000000002';
    if cnt <> 0 then raise exception 'FAIL: upcoming participant row not removed on leave'; end if;
    select count(*) into cnt from public.event_participants
      where event_id = e_past and user_id = '00000000-0000-0000-0000-000000000002';
    if cnt <> 1 then raise exception 'FAIL: past participant row should be kept'; end if;

    -- get_workspace_events: member sees upcoming only; non-member rejected
    perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
    select json_array_length(public.get_workspace_events(w_id)) into cnt;
    if cnt <> 1 then raise exception 'FAIL: get_workspace_events expected 1 upcoming, got %', cnt; end if;

    perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
    begin
      r := public.get_workspace_events(w_id);
      raise exception 'FAIL: non-member could list workspace events';
    exception when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
    end;
  end;

  -- delete_workspace cascades events + members
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  r := public.delete_workspace(w_id);
  if r->>'status' <> 'deleted' then raise exception 'FAIL: delete_workspace'; end if;
  select count(*) into cnt from public.events where workspace_id = w_id;
  if cnt <> 0 then raise exception 'FAIL: events not cascaded on workspace delete'; end if;
end $$;

-- ============================================================
-- Section 4: membership guards on event RPCs
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; e_id uuid; r json; ok boolean;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة الحراسة');
  w_id := (w->>'id')::uuid;
  if w->>'symbol' <> 'figure.soccer' then
    raise exception 'FAIL: legacy create_workspace did not use default symbol';
  end if;
  update public.users set stc_pay_number = '0500000000'
    where user_id = '00000000-0000-0000-0000-000000000001';

  -- create_event now requires workspace + membership
  ev := public.create_event(
    p_creator_id => '00000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'حدث محروس',
    p_start_date => now() + interval '1 day',
    p_end_date => now() + interval '1 day 2 hours',
    p_price_per_person => 25
  );
  e_id := (ev->>'id')::uuid;
  if (ev->>'workspace_id')::uuid <> w_id then
    raise exception 'FAIL: create_event did not store workspace_id';
  end if;

  -- non-member cannot create an event in the workspace
  begin
    ev := public.create_event(
      p_creator_id => '00000000-0000-0000-0000-000000000003',
      p_workspace_id => w_id,
      p_name => 'تسلل',
      p_start_date => now() + interval '1 day'
    );
    raise exception 'FAIL: non-member created an event';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- non-member: join_event / submit_payment / join_waitlist / get_event_by_id all rejected
  begin
    ok := public.join_event(e_id, '00000000-0000-0000-0000-000000000003');
    raise exception 'FAIL: non-member joined event';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    r := public.submit_payment(e_id, '00000000-0000-0000-0000-000000000003', '{}');
    raise exception 'FAIL: non-member submitted payment';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    r := public.join_waitlist(e_id, '00000000-0000-0000-0000-000000000003');
    raise exception 'FAIL: non-member joined waitlist';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000003');
  begin
    r := public.get_event_by_id(e_id);
    raise exception 'FAIL: non-member fetched event by id';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    r := public.get_event_participants(e_id);
    raise exception 'FAIL: non-member fetched participants';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- New create_event rows are drafts. Publishing makes the event visible and
  -- invites current members before the normal registration/payment path.
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  if r->>'status' <> 'published' then raise exception 'FAIL: publish_event'; end if;

  -- member path still works end-to-end (join workspace → pay → confirm)
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  r := public.join_workspace((select invite_code from public.workspaces where id = w_id));
  r := public.submit_payment(e_id, '00000000-0000-0000-0000-000000000002', '{}');
  if r->>'status' <> 'submitted' then
    raise exception 'FAIL: member submit_payment status %', r->>'status';
  end if;
  r := public.get_event_by_id(e_id);
  if (r->>'id')::uuid <> e_id then raise exception 'FAIL: member get_event_by_id'; end if;
  r := public.confirm_payment(e_id, '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001');
  if r->>'status' <> 'confirmed' then raise exception 'FAIL: confirm_payment broken by guards'; end if;
end $$;

select 'ALL WORKSPACE TESTS PASSED' as result;
rollback;
