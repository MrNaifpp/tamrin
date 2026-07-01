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

select 'ALL WORKSPACE TESTS PASSED' as result;
rollback;
