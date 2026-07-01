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

select 'ALL WORKSPACE TESTS PASSED' as result;
rollback;
