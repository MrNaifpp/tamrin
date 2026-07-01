# Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every event lives inside a private workspace (group); members join via invite link; the app runs in current-workspace mode with a Slack-style switcher.

**Architecture:** Two new tables (`workspaces`, `workspace_members`) + required `events.workspace_id`. All permission checks live in SECURITY DEFINER RPCs (existing codebase pattern); new RPCs derive the caller from `auth.uid()`. RLS membership policies are a backstop. iOS adds `WorkspaceService`, a persisted `currentWorkspaceId` in `AppState`, and four UI pieces (switcher sheet, create sheet, settings sheet, join overlay).

**Tech Stack:** Supabase (Postgres migrations + RPCs, local stack via `supabase` CLI), SwiftUI iOS app (Xcode project uses file-system-synchronized groups — new `.swift` files under `Sirr/` are picked up automatically, no pbxproj edits).

**Spec:** `docs/superpowers/specs/2026-07-02-workspaces-design.md`

## Global Constraints

- All UI text is Arabic, RTL (`.environment(\.layoutDirection, .rightToLeft)` on sheet roots, like existing sheets). Fonts via `.font(.appBody)` etc. from `Sirr/Extensions/FontExtension.swift`.
- New RPCs use `auth.uid()` — never trust a client-passed caller id. Existing RPCs keep their `p_user_id` signatures.
- Payment flow, guest rows, waitlist mechanics, and `enqueue_event_reminders()` logic are UNCHANGED (only membership guards are added around them).
- Migration timestamps: `202607021000xx` (must sort after `20260628110000`).
- SQL tests: `supabase/tests/workspaces_test.sql`, run against the local stack:
  `supabase db reset && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql`
  (Requires `supabase start` once beforehand. Success = last line prints `ALL WORKSPACE TESTS PASSED`.)
- iOS verification (no XCTest target exists): `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3` must print `BUILD SUCCEEDED`.
- Commit after every task. Do not commit `.superpowers/`.

---

### Task 1: `workspaces` + `workspace_members` tables, membership helper, RLS

**Files:**
- Create: `supabase/migrations/20260702100000_create_workspaces.sql`
- Create: `supabase/tests/workspaces_test.sql`

**Interfaces:**
- Produces: tables `public.workspaces(id, name, owner_id, invite_code, image_url, created_at)`, `public.workspace_members(workspace_id, user_id, joined_at)`; function `public.is_workspace_member(p_workspace_id uuid, p_user_id uuid) returns boolean`; function `public.new_invite_code() returns text`. Later tasks call `is_workspace_member` in guards and policies.

- [ ] **Step 1: Write the failing test file**

Create `supabase/tests/workspaces_test.sql`:

```sql
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
```

- [ ] **Step 2: Run to verify it fails**

```bash
supabase db reset && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
```
Expected: FAIL with `relation "public.workspaces" does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260702100000_create_workspaces.sql`:

```sql
-- Workspaces: private groups that contain events. One owner + equal members.
-- Mutations are RPC-only (see 20260702100200); RLS gives members read access.

-- URL-safe invite token, ambiguous chars (0O1Il o) excluded. 55^12 ≈ 2^69.
create or replace function public.new_invite_code()
returns text
language sql
volatile
as $$
  select string_agg(
    substr('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789',
           (floor(random() * 55) + 1)::int, 1), '')
  from generate_series(1, 12);
$$;

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invite_code text not null unique default public.new_invite_code(),
  image_url text,
  created_at timestamptz not null default now()
);

-- The owner also gets a member row, so "members of X" is always one query.
create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create index idx_workspaces_owner_id on public.workspaces(owner_id);
create index idx_workspace_members_user_id on public.workspace_members(user_id);

-- Membership check. SECURITY DEFINER so RLS policies can call it without
-- recursing into workspace_members' own policy (same trick as
-- get_event_ids_visible_to_user).
create or replace function public.is_workspace_member(p_workspace_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.workspace_members
    where workspace_id = p_workspace_id and user_id = p_user_id
  );
$$;

grant execute on function public.is_workspace_member(uuid, uuid) to authenticated;

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;

create policy "Members can select their workspaces"
  on public.workspaces for select
  using (public.is_workspace_member(id, auth.uid()));

create policy "Members can select co-members"
  on public.workspace_members for select
  using (public.is_workspace_member(workspace_id, auth.uid()));
```

- [ ] **Step 4: Run to verify it passes**

Same command as Step 2. Expected: `ALL WORKSPACE TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260702100000_create_workspaces.sql supabase/tests/workspaces_test.sql
git commit -m "feat(db): workspaces + workspace_members tables with membership helper and RLS"
```

---

### Task 2: `events.workspace_id` + backfill + events RLS

**Files:**
- Create: `supabase/migrations/20260702100100_events_workspace_backfill.sql`
- Modify: `supabase/tests/workspaces_test.sql` (append Section 2)

**Interfaces:**
- Consumes: `public.is_workspace_member(uuid, uuid)` from Task 1.
- Produces: `events.workspace_id uuid NOT NULL` (FK → workspaces, cascade); events SELECT policy is now membership-based. Every later task can assume every event has a workspace.

- [ ] **Step 1: Append the failing test section**

In `supabase/tests/workspaces_test.sql`, insert before the final `select 'ALL WORKSPACE TESTS PASSED'` line:

```sql
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
  select count(*) into visible from public.events where id = e_id;
  if visible <> 0 then raise exception 'FAIL: outsider can select workspace event'; end if;

  reset role;
end $$;
```

- [ ] **Step 2: Run to verify it fails**

```bash
supabase db reset && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
```
Expected: FAIL with `FAIL: event insert without workspace_id should be rejected` (column doesn't exist yet → actually fails earlier with `column "workspace_id" of relation "events" does not exist` — either failure is the correct red state).

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260702100100_events_workspace_backfill.sql`:

```sql
-- Every event now belongs to a workspace. Backfills existing (test) data:
-- one personal workspace per event creator, named from users.name; all of a
-- creator's events move into it; every existing participant becomes a member.
-- One-shot backfill — assumes each creator owns no workspace yet (true on the
-- pre-workspace schema this migration upgrades).

alter table public.events
  add column workspace_id uuid references public.workspaces(id) on delete cascade;

insert into public.workspaces (name, owner_id)
select coalesce(nullif(trim(u.name), ''), 'مساحتي'), c.creator_id
from (select distinct creator_id from public.events) c
left join public.users u on u.user_id = c.creator_id;

insert into public.workspace_members (workspace_id, user_id)
select w.id, w.owner_id
from public.workspaces w
on conflict do nothing;

update public.events e
set workspace_id = w.id
from public.workspaces w
where w.owner_id = e.creator_id
  and e.workspace_id is null;

-- Existing participants keep sight of their events by becoming members.
insert into public.workspace_members (workspace_id, user_id)
select e.workspace_id, ep.user_id
from public.event_participants ep
join public.events e on e.id = ep.event_id
where ep.user_id is not null
on conflict do nothing;

alter table public.events alter column workspace_id set not null;
create index idx_events_workspace_id on public.events(workspace_id);

-- Visibility is now workspace membership, not creator-or-participant.
drop policy "Users can select events they created or participate in" on public.events;
create policy "Members can select workspace events"
  on public.events for select
  using (public.is_workspace_member(workspace_id, auth.uid()));
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: `ALL WORKSPACE TESTS PASSED`.

- [ ] **Step 5: Verify the backfill against seeded old-model data**

```bash
supabase db reset --version 20260628110000
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'creator@seed.local'),
  ('10000000-0000-0000-0000-000000000002', 'joiner@seed.local');
insert into public.users (user_id, name) values
  ('10000000-0000-0000-0000-000000000001', 'منشئ');
insert into public.events (id, creator_id, name, start_date) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'حدث قديم', now() + interval '2 day');
insert into public.event_participants (event_id, user_id) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
SQL
supabase migration up
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 <<'SQL'
do $$
declare w uuid; n text; members int;
begin
  select workspace_id into w from public.events where id = '20000000-0000-0000-0000-000000000001';
  if w is null then raise exception 'FAIL: event not backfilled'; end if;
  select name into n from public.workspaces where id = w;
  if n <> 'منشئ' then raise exception 'FAIL: workspace not named from users.name (got %)', n; end if;
  select count(*) into members from public.workspace_members where workspace_id = w;
  if members <> 2 then raise exception 'FAIL: expected 2 members, got %', members; end if;
  raise notice 'BACKFILL OK';
end $$;
SQL
```
Expected: `NOTICE: BACKFILL OK`. Then restore a clean state: `supabase db reset`.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260702100100_events_workspace_backfill.sql supabase/tests/workspaces_test.sql
git commit -m "feat(db): require events.workspace_id, backfill personal workspaces, membership RLS"
```

---

### Task 3: Workspace RPCs

**Files:**
- Create: `supabase/migrations/20260702100200_workspace_rpcs.sql`
- Modify: `supabase/tests/workspaces_test.sql` (append Section 3)

**Interfaces:**
- Consumes: tables + `is_workspace_member` from Tasks 1–2.
- Produces (all SECURITY DEFINER, caller = `auth.uid()`, grants to `authenticated` only):
  - `create_workspace(p_name text) returns json` — workspace row
  - `get_my_workspaces() returns json` — array of `{id, name, owner_id, invite_code, image_url, created_at, member_count}`
  - `get_workspace(p_workspace_id uuid) returns json` — `{workspace: {...}, members: [{user_id, display_name, avatar_url, joined_at, is_owner}]}`
  - `get_workspace_by_invite(p_code text) returns json` — `{id, name, owner_name, member_count, is_member}`
  - `join_workspace(p_code text) returns json` — `{status: 'joined', workspace_id, name}`
  - `leave_workspace(p_workspace_id uuid) returns json` — `{status: 'left'|'not_member'}`
  - `remove_member(p_workspace_id uuid, p_member_id uuid) returns json` — `{status: 'removed'|'not_member'}`
  - `update_workspace(p_workspace_id uuid, p_name text) returns json` — workspace row
  - `regenerate_invite_code(p_workspace_id uuid) returns json` — `{invite_code}`
  - `delete_workspace(p_workspace_id uuid) returns json` — `{status: 'deleted'}`
  - `get_workspace_events(p_workspace_id uuid) returns json` — array of event rows (upcoming only)

- [ ] **Step 1: Append the failing test section**

Insert before the final `select 'ALL WORKSPACE TESTS PASSED'` line:

```sql
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
  w := public.create_workspace('مساحة الاختبار');
  w_id := (w->>'id')::uuid;
  code := w->>'invite_code';
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
  select json_array_length(public.get_my_workspaces()) into cnt;
  if cnt < 1 then raise exception 'FAIL: get_my_workspaces empty for member'; end if;

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
```

- [ ] **Step 2: Run to verify it fails**

```bash
supabase db reset && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
```
Expected: FAIL with `function public.create_workspace(unknown) does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260702100200_workspace_rpcs.sql`:

```sql
-- Workspace RPCs. All SECURITY DEFINER; the caller is auth.uid() — these do
-- NOT trust a client-passed user id (unlike the older event RPCs).

-- ----------------------------------------------------------------------------
-- Internal: strip a user's participation from a workspace's UPCOMING events
-- (their own row, guest rows they added, and waitlist rows). Past events keep
-- history. Not granted to clients.
-- ----------------------------------------------------------------------------
create or replace function public.remove_workspace_participation(p_workspace_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.event_participants ep
  using public.events e
  where ep.event_id = e.id
    and e.workspace_id = p_workspace_id
    and coalesce(e.end_date, e.start_date) >= now()
    and (ep.user_id = p_user_id or ep.added_by = p_user_id);

  delete from public.event_waitlist wl
  using public.events e
  where wl.event_id = e.id
    and e.workspace_id = p_workspace_id
    and wl.user_id = p_user_id;
end;
$$;

revoke execute on function public.remove_workspace_participation(uuid, uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.create_workspace(p_name text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  insert into public.workspaces (name, owner_id)
  values (trim(p_name), v_uid)
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

grant execute on function public.create_workspace(text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_my_workspaces()
returns json
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(json_agg(row_to_json(t) order by t.created_at asc), '[]'::json)
  from (
    select w.id, w.name, w.owner_id, w.invite_code, w.image_url, w.created_at,
           (select count(*) from public.workspace_members m2
             where m2.workspace_id = w.id) as member_count
    from public.workspaces w
    join public.workspace_members m
      on m.workspace_id = w.id and m.user_id = auth.uid()
  ) t;
$$;

grant execute on function public.get_my_workspaces() to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_workspace(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select json_build_object(
      'workspace', row_to_json(w),
      'members', (
        select coalesce(json_agg(json_build_object(
          'user_id', m.user_id,
          'display_name', coalesce(usr.name, au.email),
          'avatar_url', usr.avatar_url,
          'joined_at', m.joined_at,
          'is_owner', m.user_id = w.owner_id
        ) order by (m.user_id = w.owner_id) desc, m.joined_at asc), '[]'::json)
        from public.workspace_members m
        left join public.users usr on usr.user_id = m.user_id
        left join auth.users au on au.id = m.user_id
        where m.workspace_id = w.id
      )
    )
    from public.workspaces w
    where w.id = p_workspace_id
  );
end;
$$;

grant execute on function public.get_workspace(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_workspace_by_invite(p_code text)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  w public.workspaces;
begin
  select * into w from public.workspaces where invite_code = p_code;
  if w.id is null then raise exception 'Invalid invite link'; end if;

  return json_build_object(
    'id', w.id,
    'name', w.name,
    'owner_name', coalesce((select name from public.users where user_id = w.owner_id), ''),
    'member_count', (select count(*) from public.workspace_members where workspace_id = w.id),
    'is_member', public.is_workspace_member(w.id, auth.uid())
  );
end;
$$;

grant execute on function public.get_workspace_by_invite(text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.join_workspace(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into w from public.workspaces where invite_code = p_code;
  if w.id is null then raise exception 'Invalid invite link'; end if;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid)
  on conflict (workspace_id, user_id) do nothing;

  return json_build_object('status', 'joined', 'workspace_id', w.id, 'name', w.name);
end;
$$;

grant execute on function public.join_workspace(text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.leave_workspace(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  deleted_rows int;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if exists (select 1 from public.workspaces where id = p_workspace_id and owner_id = v_uid) then
    raise exception 'Owner cannot leave the workspace; delete it instead';
  end if;

  delete from public.workspace_members
  where workspace_id = p_workspace_id and user_id = v_uid;
  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'not_member');
  end if;

  perform public.remove_workspace_participation(p_workspace_id, v_uid);
  return json_build_object('status', 'left');
end;
$$;

grant execute on function public.leave_workspace(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.remove_member(p_workspace_id uuid, p_member_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  deleted_rows int;
begin
  if not exists (select 1 from public.workspaces where id = p_workspace_id and owner_id = v_uid) then
    raise exception 'Not authorized: only the workspace owner can remove members';
  end if;
  if p_member_id = v_uid then
    raise exception 'Owner cannot remove themselves; delete the workspace instead';
  end if;

  delete from public.workspace_members
  where workspace_id = p_workspace_id and user_id = p_member_id;
  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'not_member');
  end if;

  perform public.remove_workspace_participation(p_workspace_id, p_member_id);
  return json_build_object('status', 'removed');
end;
$$;

grant execute on function public.remove_member(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.update_workspace(p_workspace_id uuid, p_name text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  update public.workspaces
  set name = trim(p_name)
  where id = p_workspace_id and owner_id = v_uid
  returning * into w;

  if w.id is null then
    raise exception 'Not authorized: only the workspace owner can rename it';
  end if;
  return row_to_json(w);
end;
$$;

grant execute on function public.update_workspace(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.regenerate_invite_code(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
begin
  update public.workspaces
  set invite_code = public.new_invite_code()
  where id = p_workspace_id and owner_id = v_uid
  returning invite_code into v_code;

  if v_code is null then
    raise exception 'Not authorized: only the workspace owner can regenerate the invite link';
  end if;
  return json_build_object('invite_code', v_code);
end;
$$;

grant execute on function public.regenerate_invite_code(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.delete_workspace(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  deleted_id uuid;
begin
  if not exists (select 1 from public.workspaces where id = p_workspace_id and owner_id = v_uid) then
    raise exception 'Not authorized: only the workspace owner can delete it';
  end if;

  -- push_outbox.event_id has no FK; clean rows for this workspace's events.
  delete from public.push_outbox
  where event_id in (select id from public.events where workspace_id = p_workspace_id);

  delete from public.workspaces
  where id = p_workspace_id
  returning id into deleted_id;

  return json_build_object('status', 'deleted');
end;
$$;

grant execute on function public.delete_workspace(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_workspace_events(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_workspace_member(p_workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(e) order by e.start_date asc), '[]'::json)
    from public.events e
    where e.workspace_id = p_workspace_id
      and coalesce(e.end_date, e.start_date) >= now()
  );
end;
$$;

grant execute on function public.get_workspace_events(uuid) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: `ALL WORKSPACE TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260702100200_workspace_rpcs.sql supabase/tests/workspaces_test.sql
git commit -m "feat(db): workspace RPCs (create/join/leave/manage/events) via auth.uid()"
```

---

### Task 4: Membership guards on event RPCs

**Files:**
- Create: `supabase/migrations/20260702100300_event_rpcs_workspace_guards.sql`
- Modify: `supabase/tests/workspaces_test.sql` (append Section 4)

**Interfaces:**
- Consumes: `is_workspace_member`, `events.workspace_id`.
- Produces: `create_event` signature changes — new 2nd param `p_workspace_id uuid` (old 12-arg overload dropped). `get_event_by_id` / `get_event_participants` become member-only (anon grants revoked). `join_event`, `submit_payment`, `join_waitlist` reject non-members. Task 5's Swift `createEvent` must pass `p_workspace_id`.

- [ ] **Step 1: Append the failing test section**

Insert before the final `select ... PASSED` line:

```sql
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
```

- [ ] **Step 2: Run to verify it fails**

Same command as before. Expected: FAIL (first at the named-arg `create_event(... p_workspace_id ...)` call — no such parameter yet).

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260702100300_event_rpcs_workspace_guards.sql`. Note: `create_event` keeps trusting `p_creator_id` (existing pattern, Swift passes the session user); the membership check binds it to the workspace. `get_event_by_id` / `get_event_participants` switch to `auth.uid()` gating and lose their `anon` grants — this is what retires the public share flow:

```sql
-- Workspace-membership guards on the event RPC surface. Non-members can no
-- longer view, join, pay for, or wait on a workspace's events.

-- ----------------------------------------------------------------------------
-- create_event: gains p_workspace_id; creator must be a member.
-- Drop the previous overload to avoid PostgREST ambiguity.
-- ----------------------------------------------------------------------------
drop function if exists public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision);

create or replace function public.create_event(
  p_creator_id uuid,
  p_workspace_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null,
  p_total_price int default 0,
  p_price_per_person decimal default 0,
  p_latitude double precision default null,
  p_longitude double precision default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
begin
  if not public.is_workspace_member(p_workspace_id, p_creator_id) then
    raise exception 'Not a workspace member';
  end if;

  insert into public.events (creator_id, workspace_id, name, location, description, start_date, end_date, image_url, max_participants, total_price, price_per_person, latitude, longitude)
  values (p_creator_id, p_workspace_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants, p_total_price, p_price_per_person, p_latitude, p_longitude)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision) to authenticated;

-- ----------------------------------------------------------------------------
-- get_event_by_id: member-gated (was: anyone with the link).
-- ----------------------------------------------------------------------------
create or replace function public.get_event_by_id(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(ev.workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;
  return row_to_json(ev);
end;
$$;

revoke execute on function public.get_event_by_id(uuid) from anon;
grant execute on function public.get_event_by_id(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- get_event_participants: member-gated (participant names are private now).
-- Body unchanged from 20260628100100 apart from the guard.
-- ----------------------------------------------------------------------------
create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_workspace uuid;
begin
  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_workspace, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(t)), '[]'::json)
    from (
      select
        ep.id as participant_id,
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, u.email, ep.guest_name) as display_name,
        null::text as avatar_url,
        ep.payment_status,
        ep.paid_to_number,
        ep.guest_name,
        ep.added_by
      from public.event_participants ep
      left join auth.users u on u.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id
      order by ep.created_at asc
    ) t
  );
end;
$$;

revoke execute on function public.get_event_participants(uuid) from anon;
grant execute on function public.get_event_participants(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- join_event: guard added after the event lookup. Body otherwise unchanged
-- from 20260130500000.
-- ----------------------------------------------------------------------------
create or replace function public.join_event(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(ev.workspace_id, p_user_id) then
    raise exception 'Not a workspace member';
  end if;
  if ev.registration_locked then
    raise exception 'Registration is closed for this event';
  end if;

  insert into public.event_participants (event_id, user_id)
  values (p_event_id, p_user_id)
  on conflict (event_id, user_id) do nothing;

  return true;
end;
$$;

revoke execute on function public.join_event(uuid, uuid) from anon;
grant execute on function public.join_event(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- submit_payment (guest-aware 3-arg version): guard added after the row lock.
-- Body otherwise identical to 20260628100100.
-- ----------------------------------------------------------------------------
create or replace function public.submit_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_guest_names text[] default '{}'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  creator_stc text;
  current_seats int;
  existing_status text;
  v_guests text[];
  v_group_size int;
begin
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(ev.workspace_id, p_user_id) then
    raise exception 'Not a workspace member';
  end if;

  if ev.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into existing_status
    from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;
  if existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', existing_status);
  end if;

  select coalesce(array_agg(trim(g)), '{}')
    into v_guests
    from unnest(p_guest_names) as g
    where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

  if ev.max_participants is not null then
    select count(*) into current_seats
      from public.event_participants
      where event_id = p_event_id
        and payment_status in ('pending', 'confirmed');
    if current_seats + v_group_size > ev.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  select stc_pay_number into creator_stc
    from public.users
    where user_id = ev.creator_id;
  if creator_stc is null or creator_stc = '' then
    return json_build_object('status', 'creator_missing_number');
  end if;

  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

  insert into public.event_participants (event_id, user_id, guest_name, added_by, payment_status, paid_to_number)
  select p_event_id, null, g, p_user_id, 'pending', creator_stc
  from unnest(v_guests) as g;

  delete from public.event_waitlist
    where event_id = p_event_id and user_id = p_user_id;

  insert into public.push_outbox (user_id, type, event_id)
  values (ev.creator_id, 'payment_submitted', p_event_id);

  return json_build_object(
    'status', 'submitted',
    'creator_id', ev.creator_id,
    'paid_to_number', creator_stc,
    'group_size', v_group_size
  );
end;
$$;

grant execute on function public.submit_payment(uuid, uuid, text[]) to authenticated;

-- ----------------------------------------------------------------------------
-- join_waitlist: guard added (needs the event row to find the workspace).
-- ----------------------------------------------------------------------------
create or replace function public.join_waitlist(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_workspace uuid;
begin
  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_workspace, p_user_id) then
    raise exception 'Not a workspace member';
  end if;

  insert into public.event_waitlist (event_id, user_id)
    values (p_event_id, p_user_id)
    on conflict (event_id, user_id) do nothing;
  return json_build_object('status', 'joined');
end;
$$;

grant execute on function public.join_waitlist(uuid, uuid) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: `ALL WORKSPACE TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260702100300_event_rpcs_workspace_guards.sql supabase/tests/workspaces_test.sql
git commit -m "feat(db): membership guards on event RPCs; create_event takes workspace_id"
```

---

### Task 5: `WorkspaceService` + models (Swift)

**Files:**
- Create: `Sirr/core/supabase/WorkspaceService.swift`
- Modify: `Sirr/core/supabase/EventService.swift` (createEvent gains `workspaceId`; new `getWorkspaceEvents`)

**Interfaces:**
- Consumes: Task 3/4 RPCs; `EventRecord` (existing).
- Produces (used by Tasks 6–9):
  - `WorkspaceRecord { id: UUID, name: String, ownerId: UUID, inviteCode: String?, imageUrl: String?, memberCount: Int? }`
  - `WorkspaceMemberRecord { userId: UUID, displayName: String?, avatarUrl: String?, isOwner: Bool }`
  - `WorkspaceDetail { workspace: WorkspaceRecord, members: [WorkspaceMemberRecord] }`
  - `WorkspaceInvitePreview { id: UUID, name: String, ownerName: String?, memberCount: Int, isMember: Bool }`
  - `WorkspaceService.shared` methods: `createWorkspace(name:) -> WorkspaceRecord`, `getMyWorkspaces() -> [WorkspaceRecord]`, `getWorkspace(id:) -> WorkspaceDetail`, `getInvitePreview(code:) -> WorkspaceInvitePreview`, `joinWorkspace(code:) -> UUID`, `leaveWorkspace(id:)`, `removeMember(workspaceId:userId:)`, `renameWorkspace(id:name:) -> WorkspaceRecord`, `regenerateInviteCode(id:) -> String`, `deleteWorkspace(id:)`
  - `EventService.getWorkspaceEvents(workspaceId:) -> [EventRecord]`; `EventService.createEvent(workspaceId:name:...)` (new required first param)
  - `WorkspaceRecord.inviteURL` → `https://guileless-squirrel-b6537a.netlify.app/join/{code}`

- [ ] **Step 1: Create `Sirr/core/supabase/WorkspaceService.swift`**

```swift
//
//  WorkspaceService.swift
//  Sirr
//
//  Workspaces: private groups that contain events. All calls go through
//  SECURITY DEFINER RPCs that identify the caller via auth.uid().
//

import Supabase
import Foundation
import os

private let wsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "WorkspaceService")

/// Row from public.workspaces (as returned by workspace RPCs).
struct WorkspaceRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let ownerId: UUID
    let inviteCode: String?
    let imageUrl: String?
    let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
        case inviteCode = "invite_code"
        case imageUrl = "image_url"
        case memberCount = "member_count"
    }

    /// Universal invite link (same domain as event links).
    var inviteURL: URL? {
        guard let inviteCode else { return nil }
        return URL(string: "https://guileless-squirrel-b6537a.netlify.app/join/\(inviteCode)")
    }
}

/// Member row from get_workspace RPC.
struct WorkspaceMemberRecord: Codable, Identifiable, Hashable {
    let userId: UUID
    let displayName: String?
    let avatarUrl: String?
    let isOwner: Bool

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case isOwner = "is_owner"
    }
}

/// Payload of get_workspace RPC.
struct WorkspaceDetail: Codable {
    let workspace: WorkspaceRecord
    let members: [WorkspaceMemberRecord]
}

/// Payload of get_workspace_by_invite RPC (join screen preview).
struct WorkspaceInvitePreview: Codable {
    let id: UUID
    let name: String
    let ownerName: String?
    let memberCount: Int
    let isMember: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerName = "owner_name"
        case memberCount = "member_count"
        case isMember = "is_member"
    }
}

final class WorkspaceService {
    static let shared = WorkspaceService()
    private let client = SupabaseClientManager.shared.client

    func createWorkspace(name: String) async throws -> WorkspaceRecord {
        let response = try await client
            .rpc("create_workspace", params: ["p_name": name])
            .execute()
        let ws = try JSONDecoder().decode(WorkspaceRecord.self, from: response.data)
        wsLogger.info("API createWorkspace succeeded (id: \(ws.id))")
        return ws
    }

    func getMyWorkspaces() async throws -> [WorkspaceRecord] {
        let response = try await client
            .rpc("get_my_workspaces")
            .execute()
        let list = try JSONDecoder().decode([WorkspaceRecord].self, from: response.data)
        wsLogger.info("API getMyWorkspaces succeeded (count: \(list.count))")
        return list
    }

    func getWorkspace(id: UUID) async throws -> WorkspaceDetail {
        let response = try await client
            .rpc("get_workspace", params: ["p_workspace_id": id.uuidString])
            .execute()
        let detail = try JSONDecoder().decode(WorkspaceDetail.self, from: response.data)
        wsLogger.info("API getWorkspace succeeded (id: \(id))")
        return detail
    }

    func getInvitePreview(code: String) async throws -> WorkspaceInvitePreview {
        let response = try await client
            .rpc("get_workspace_by_invite", params: ["p_code": code])
            .execute()
        return try JSONDecoder().decode(WorkspaceInvitePreview.self, from: response.data)
    }

    /// Joins via invite code; returns the workspace id (idempotent server-side).
    func joinWorkspace(code: String) async throws -> UUID {
        struct JoinResult: Decodable {
            let workspaceId: UUID
            enum CodingKeys: String, CodingKey { case workspaceId = "workspace_id" }
        }
        let response = try await client
            .rpc("join_workspace", params: ["p_code": code])
            .execute()
        let result = try JSONDecoder().decode(JoinResult.self, from: response.data)
        wsLogger.info("API joinWorkspace succeeded (id: \(result.workspaceId))")
        return result.workspaceId
    }

    func leaveWorkspace(id: UUID) async throws {
        try await client
            .rpc("leave_workspace", params: ["p_workspace_id": id.uuidString])
            .execute()
        wsLogger.info("API leaveWorkspace succeeded (id: \(id))")
    }

    func removeMember(workspaceId: UUID, userId: UUID) async throws {
        let params = [
            "p_workspace_id": workspaceId.uuidString,
            "p_member_id": userId.uuidString
        ]
        try await client.rpc("remove_member", params: params).execute()
        wsLogger.info("API removeMember succeeded (workspace: \(workspaceId))")
    }

    func renameWorkspace(id: UUID, name: String) async throws -> WorkspaceRecord {
        let params = ["p_workspace_id": id.uuidString, "p_name": name]
        let response = try await client.rpc("update_workspace", params: params).execute()
        return try JSONDecoder().decode(WorkspaceRecord.self, from: response.data)
    }

    func regenerateInviteCode(id: UUID) async throws -> String {
        struct CodeResult: Decodable {
            let inviteCode: String
            enum CodingKeys: String, CodingKey { case inviteCode = "invite_code" }
        }
        let response = try await client
            .rpc("regenerate_invite_code", params: ["p_workspace_id": id.uuidString])
            .execute()
        return try JSONDecoder().decode(CodeResult.self, from: response.data).inviteCode
    }

    func deleteWorkspace(id: UUID) async throws {
        try await client
            .rpc("delete_workspace", params: ["p_workspace_id": id.uuidString])
            .execute()
        wsLogger.info("API deleteWorkspace succeeded (id: \(id))")
    }
}
```

- [ ] **Step 2: Update `EventService.swift`**

(a) `createEvent` gains a required `workspaceId` as first parameter and passes it to the RPC. Change the signature (`Sirr/core/supabase/EventService.swift:151`):

```swift
    func createEvent(
        workspaceId: UUID,
        name: String,
        location: String,
        description: String,
        startDate: Date,
        endDate: Date?,
        imageUrl: String?,
        maxParticipants: Int?,
        totalPrice: Int = 0,
        pricePerPerson: Double = 0,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) async throws -> EventRecord {
```

and in the params dictionary add the workspace id:

```swift
        var params: [String: String] = [
            "p_creator_id": userId.uuidString,
            "p_workspace_id": workspaceId.uuidString,
            "p_name": name,
            "p_location": location,
            "p_description": description,
            "p_start_date": iso.string(from: startDate)
        ]
```

(b) Replace `getEventsForCurrentUser()` (lines 100–147) with a workspace-scoped fetch — the two-query merge is dead now that visibility is workspace-based:

```swift
    /// Upcoming events of one workspace (member-gated server-side).
    /// Ordered by start_date ascending.
    func getWorkspaceEvents(workspaceId: UUID) async throws -> [EventRecord] {
        let params: [String: String] = ["p_workspace_id": workspaceId.uuidString]
        let response = try await client
            .rpc("get_workspace_events", params: params)
            .execute()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = ISO8601DateFormatter().date(from: str) { return d }
            let pg = DateFormatter()
            pg.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            pg.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg.date(from: str) { return d }
            let pg2 = DateFormatter()
            pg2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            pg2.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg2.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(str)")
        }
        let events = try decoder.decode([EventRecord].self, from: response.data)
        eventLogger.info("API getWorkspaceEvents succeeded (count: \(events.count))")
        return events
    }
```

Also add `workspaceId` to `EventRecord` so decoded rows carry it (used for push-tap workspace switching in Task 7):

```swift
    let workspaceId: UUID?
```
with coding key `case workspaceId = "workspace_id"` (optional so old cached payloads don't crash decoding).

The app will not compile yet (`EventPageView` still calls `getEventsForCurrentUser`, `NewEventView` calls the old `createEvent`) — that is expected; Tasks 7 and 9 fix the call sites. To keep this task independently verifiable, keep a temporary shim at the old name:

```swift
    /// TEMPORARY shim until EventPageView switches to getWorkspaceEvents (Task 7).
    /// Returns [] — home shows the workspace empty state until then.
    func getEventsForCurrentUser() async throws -> [EventRecord] { [] }
```

and in `NewEventView.swift` (line ~436) pass a placeholder that Task 9 replaces — instead, defer: change `NewEventView` in this task by adding the property now (it is a one-line call-site fix):

In `Sirr/pages/NewEventView.swift`, add a stored property near the other properties at the top of the struct. (If the struct has an explicit `init`, add the parameter there too with default `nil`; if it relies on the memberwise init, note that Task 7 constructs it as `NewEventView(workspaceId:onCreated:)` — keep the property declared before `onCreated` so the argument order matches.)

```swift
    /// Workspace the new event is created in (current workspace on home).
    var workspaceId: UUID? = nil
```

and at the `createEvent(` call (line ~436) add the first argument:

```swift
            let event = try await EventService.shared.createEvent(
                workspaceId: workspaceId ?? UUID(),
```

(The `?? UUID()` fallback is temporary; Task 7 passes the real current workspace and Task 9's manual pass verifies creation.)

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sirr/core/supabase/WorkspaceService.swift Sirr/core/supabase/EventService.swift Sirr/pages/NewEventView.swift
git commit -m "feat(ios): WorkspaceService + workspace-scoped event fetching/creation"
```

---

### Task 6: `AppState` — current workspace + join deep link; `ContentView` routing

**Files:**
- Modify: `Sirr/AppState.swift`
- Modify: `Sirr/ContentView.swift`

**Interfaces:**
- Consumes: nothing new (UI pieces arrive in Tasks 7–9; this task only adds state + parsing, which compiles standalone).
- Produces: `AppState.currentWorkspaceId: UUID?` (persisted to UserDefaults key `"currentWorkspaceId"`), `AppState.deepLinkJoinCode: String?`, `handleDeepLink` parses `/join/{code}` (and still `/event/{id}`). `ContentView` holds `pendingJoinCode` across login like `pendingEventId`.

- [ ] **Step 1: Extend `AppState`**

Replace the body of `Sirr/AppState.swift` with:

```swift
//
//  AppState.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Combine
import Foundation

@MainActor
class AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var deepLinkEventId: UUID?
    /// Invite code from a /join/{code} link, pending until the join screen handles it.
    @Published var deepLinkJoinCode: String?
    /// False until the initial session check completes. Used to avoid flashing
    /// the logged-out deep-link sheet to a user who turns out to be signed in.
    @Published var sessionChecked = false
    /// The workspace the app is currently "inside" (Slack-style). Persisted so
    /// relaunch lands in the same workspace. nil = not yet chosen / none.
    @Published var currentWorkspaceId: UUID? {
        didSet {
            UserDefaults.standard.set(currentWorkspaceId?.uuidString, forKey: Self.currentWorkspaceKey)
        }
    }
    let authVM = AuthViewModel()
    private var cancellables = Set<AnyCancellable>()
    private static let currentWorkspaceKey = "currentWorkspaceId"

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.currentWorkspaceKey) {
            currentWorkspaceId = UUID(uuidString: stored)
        }
        authVM.$isAuthenticated
            .assign(to: \.isLoggedIn, on: self)
            .store(in: &cancellables)
        Task {
            await authVM.checkSession()
            sessionChecked = true
        }
    }

    func handleDeepLink(_ url: URL) {
        // Accept both the custom scheme (sirr://event/{id}, sirr://join/{code})
        // and the Universal Link (https://<domain>/event/{id}, /join/{code}).
        // The payload is the path segment that follows "event" / "join".
        let segments = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        if let idx = segments.firstIndex(of: "event"),
           idx + 1 < segments.count,
           let eventId = UUID(uuidString: segments[idx + 1]) {
            deepLinkEventId = eventId
            return
        }
        if let idx = segments.firstIndex(of: "join"),
           idx + 1 < segments.count {
            let code = segments[idx + 1]
            // Invite codes are 12 alphanumeric chars (new_invite_code()).
            guard code.count == 12, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
            deepLinkJoinCode = code
        }
    }
}
```

- [ ] **Step 2: Hold the join code across login in `ContentView`**

In `Sirr/ContentView.swift` add alongside `pendingEventId` (line ~20):

```swift
    /// Invite code the user was trying to use when prompted to log in.
    @State private var pendingJoinCode: String?
```

In the `.onChange(of: appState.isLoggedIn)` block, extend the signed-out cleanup and the resume logic (replace the existing closure body):

```swift
        .onChange(of: appState.isLoggedIn) { loggedIn in
            guard loggedIn else {
                // Signed out: drop any stale deep-link so overlays don't
                // reappear over the login screen and error out.
                appState.deepLinkEventId = nil
                appState.deepLinkJoinCode = nil
                pendingEventId = nil
                pendingJoinCode = nil
                return
            }
            // Resume whichever deep link was pending before login.
            if let id = pendingEventId {
                pendingEventId = nil
                appState.deepLinkEventId = id
            }
            if let code = pendingJoinCode {
                pendingJoinCode = nil
                appState.deepLinkJoinCode = code
            }
        }
```

For the logged-OUT case, mirror the `SharedEventView` pattern: when `deepLinkJoinCode` is set and the user isn't logged in, stash it and send them to login. Add inside the `ZStack`, after the `SharedEventView` block:

```swift
            if let code = appState.deepLinkJoinCode, !appState.isLoggedIn, appState.sessionChecked {
                JoinWorkspaceView(
                    code: code,
                    isLoggedIn: false,
                    onDismiss: { appState.deepLinkJoinCode = nil },
                    onRequestLogin: {
                        pendingJoinCode = code
                        appState.deepLinkJoinCode = nil
                        authPath = NavigationPath()
                    },
                    onJoined: { _ in }
                )
                .transition(.move(edge: .bottom))
            }
```

`JoinWorkspaceView` doesn't exist until Task 9 — to keep this task compiling, add a minimal placeholder file now that Task 9 replaces wholesale. Create `Sirr/pages/JoinWorkspaceView.swift`:

```swift
//
//  JoinWorkspaceView.swift
//  Sirr
//
//  Invite-link join screen. Placeholder — full UI lands with the join flow task.
//

import SwiftUI

struct JoinWorkspaceView: View {
    let code: String
    var isLoggedIn: Bool
    var onDismiss: () -> Void
    var onRequestLogin: () -> Void
    /// Called with the workspace id after a successful join.
    var onJoined: (UUID) -> Void

    var body: some View {
        Color.black.ignoresSafeArea()
            .overlay(ProgressView().tint(.white))
            .onTapGesture { onDismiss() }
    }
}
```

Also update the animation value so the overlay animates for both links (line ~65):

```swift
        .animation(.easeInOut(duration: 0.3), value: appState.deepLinkEventId != nil || appState.deepLinkJoinCode != nil)
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sirr/AppState.swift Sirr/ContentView.swift Sirr/pages/JoinWorkspaceView.swift
git commit -m "feat(ios): current-workspace state + /join deep-link parsing and login resume"
```

---

### Task 7: Home in current-workspace mode — switcher sheet + create sheet

**Files:**
- Create: `Sirr/Components/WorkspaceSwitcherSheet.swift`
- Create: `Sirr/Components/CreateWorkspaceSheet.swift`
- Modify: `Sirr/pages/EventPageView.swift`
- Modify: `Sirr/ContentView.swift` (pass `appState` into `EventPageView`)

**Interfaces:**
- Consumes: `WorkspaceService.getMyWorkspaces/createWorkspace`, `EventService.getWorkspaceEvents`, `AppState.currentWorkspaceId`, `NewEventView.workspaceId` (Task 5).
- Produces: `WorkspaceSwitcherSheet(workspaces:currentId:onSelect:onCreate:onOpenSettings:onLogout:)`, `CreateWorkspaceSheet(onCreated:)`, `WorkspaceAvatar(name:id:size:)` (deterministic color from the workspace id — reused by settings + join screens).

- [ ] **Step 1: Create `Sirr/Components/WorkspaceSwitcherSheet.swift`**

```swift
//
//  WorkspaceSwitcherSheet.swift
//  Sirr
//
//  Slack-style half-sheet listing the user's workspaces. Tapping a row makes
//  it the current workspace; the gear opens its settings; logout lives at the
//  bottom (it left the home toolbar when the workspace avatar took its place).
//

import SwiftUI

/// Colored-initial square used everywhere a workspace needs an identity.
/// The hue is derived from the workspace id so it is stable across launches.
struct WorkspaceAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 34

    private var color: Color {
        let hue = Double(abs(id.uuidString.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

struct WorkspaceSwitcherSheet: View {
    let workspaces: [WorkspaceRecord]
    let currentId: UUID?
    var onSelect: (WorkspaceRecord) -> Void
    var onCreate: () -> Void
    var onOpenSettings: (WorkspaceRecord) -> Void
    var onLogout: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("مساحاتك")
                    .font(.appSubheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(workspaces) { ws in
                            workspaceRow(ws)
                        }
                        createRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                logoutRow
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func workspaceRow(_ ws: WorkspaceRecord) -> some View {
        Button {
            onSelect(ws)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                WorkspaceAvatar(name: ws.name, id: ws.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name)
                        .font(.appBodyMedium)
                        .foregroundStyle(.white)
                    if let count = ws.memberCount {
                        Text("\(count) أعضاء")
                            .font(.appCaption)
                            .foregroundStyle(Color(white: 0.55))
                    }
                }
                Spacer()
                if ws.id == currentId {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                Button {
                    dismiss()
                    onOpenSettings(ws)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(white: 0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ws.id == currentId ? .white.opacity(0.14) : .white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var createRow: some View {
        Button {
            dismiss()
            onCreate()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "plus").foregroundStyle(.white))
                Text("مساحة جديدة")
                    .font(.appBodyMedium)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var logoutRow: some View {
        Button {
            dismiss()
            onLogout()
        } label: {
            Text("تسجيل الخروج")
                .font(.appBody)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}
```

- [ ] **Step 2: Create `Sirr/Components/CreateWorkspaceSheet.swift`**

```swift
//
//  CreateWorkspaceSheet.swift
//  Sirr
//
//  Single-field sheet: name the workspace, create it, switch into it.
//

import SwiftUI

struct CreateWorkspaceSheet: View {
    /// Called with the created workspace; caller switches into it.
    var onCreated: (WorkspaceRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("مساحة جديدة")
                    .font(.appSubheadline)
                    .foregroundStyle(.white)
                    .padding(.top, 24)

                TextField("", text: $name, prompt: Text("اسم المساحة").foregroundColor(Color(white: 0.45)))
                    .font(.appBody)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.right)
                    .focused($nameFocused)
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .padding(.horizontal, 20)

                if let errorText {
                    Text(errorText)
                        .font(.appCaption)
                        .foregroundStyle(.red)
                }

                Button {
                    handleCreate()
                } label: {
                    Group {
                        if isCreating {
                            ProgressView().tint(.black)
                        } else {
                            Text("إنشاء")
                                .font(.headline)
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(isCreating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { nameFocused = true }
    }

    private func handleCreate() {
        guard !isCreating else { return }
        isCreating = true
        errorText = nil
        Task {
            defer { isCreating = false }
            do {
                let ws = try await WorkspaceService.shared.createWorkspace(name: name)
                onCreated(ws)
                dismiss()
            } catch {
                errorText = "تعذر إنشاء المساحة. حاول مرة أخرى."
            }
        }
    }
}
```

- [ ] **Step 3: Rewire `EventPageView` to current-workspace mode**

In `Sirr/pages/EventPageView.swift`:

(a) Add state and the app-state hookup. Change the struct header/properties (lines 17–33):

```swift
struct EventPageView: View {
    var authVM: AuthViewModel? = nil
    @ObservedObject var appState: AppState
    @Binding var deepLinkEventId: UUID?
    @Namespace private var zoomNamespace
    @State private var currentPage: Int = 0
    @State private var navigationPath = NavigationPath()
    @State private var showEditProfileSheet = false
    @State private var events: [EventData] = []
    @State private var eventsLoading = false
    @State private var eventsError: String? = nil
    @State private var workspaces: [WorkspaceRecord] = []
    @State private var workspacesLoaded = false
    @State private var showSwitcher = false
    @State private var showCreateWorkspace = false
    @State private var settingsWorkspace: WorkspaceRecord?

    private var currentWorkspace: WorkspaceRecord? {
        workspaces.first { $0.id == appState.currentWorkspaceId } ?? workspaces.first
    }

    init(authVM: AuthViewModel? = nil, appState: AppState, deepLinkEventId: Binding<UUID?> = .constant(nil)) {
        self.authVM = authVM
        self.appState = appState
        self._deepLinkEventId = deepLinkEventId
    }
```

(Remove the now-unused `path: [EventData]` and `selectedTab` state while here.)

(b) Replace `loadEvents()` (lines 198–216) with workspace-aware loading:

```swift
    /// Loads the workspace list, resolves the current workspace, then its events.
    func loadEvents() async {
        eventsLoading = true
        eventsError = nil
        defer { eventsLoading = false }
        do {
            workspaces = try await WorkspaceService.shared.getMyWorkspaces()
            workspacesLoaded = true
            guard let ws = currentWorkspace else {
                appState.currentWorkspaceId = nil
                events = []
                return
            }
            if appState.currentWorkspaceId != ws.id {
                appState.currentWorkspaceId = ws.id
            }
            let records = try await EventService.shared.getWorkspaceEvents(workspaceId: ws.id)
            events = records.map { EventData.from(record: $0) }
            if currentPage >= events.count && !events.isEmpty {
                currentPage = events.count - 1
            } else if events.isEmpty {
                currentPage = 0
            }
        } catch {
            eventsError = error.localizedDescription
            events = []
        }
    }
```

(The client-side `end >= now` filter is gone — `get_workspace_events` already returns upcoming only.)

(c) Toolbar: the leading logout button ("القادمة", lines 108–113) becomes the workspace avatar button:

```swift
                ToolbarItem(placement: .navigationBarLeading) {
                    if let ws = currentWorkspace {
                        Button {
                            showSwitcher = true
                        } label: {
                            WorkspaceAvatar(name: ws.name, id: ws.id, size: 30)
                        }
                    }
                }
```

(d) The main `ZStack` gets a third branch: signed-in user with zero workspaces. Replace the `if events.isEmpty && !eventsLoading` condition (line 39) with:

```swift
                    if workspacesLoaded && workspaces.isEmpty {
                        emptyStateBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        noWorkspaceContent
                    } else if events.isEmpty && !eventsLoading {
```

and add to the "Events loading & empty state" extension:

```swift
    /// Zero-workspace onboarding: create one, or join via a friend's link.
    var noWorkspaceContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("🏟️").font(.system(size: 56))
            Text("ابدأ مساحتك الأولى")
                .font(.appTitle)
                .foregroundStyle(.white)
            Text("المساحة هي مجموعتك — أنشئ واحدة لشلّتك\nأو انضم برابط دعوة من صديق")
                .font(.appBody)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                showCreateWorkspace = true
            } label: {
                Text("إنشاء مساحة")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color.white))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 48)
            Text("عندك رابط دعوة؟ افتحه وسينقلك إلى هنا")
                .font(.appCaption)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 24)
        }
    }
```

Also update the existing no-events copy (line 233–236) to point at the current workspace:

```swift
            Text("لا توجد فعاليات في \(currentWorkspace?.name ?? "المساحة")")
```

(e) Wire the sheets. After the existing `.sheet(isPresented: $showEditProfileSheet)` block add:

```swift
            .sheet(isPresented: $showSwitcher) {
                WorkspaceSwitcherSheet(
                    workspaces: workspaces,
                    currentId: currentWorkspace?.id,
                    onSelect: { ws in
                        appState.currentWorkspaceId = ws.id
                        currentPage = 0
                        Task { await loadEvents() }
                    },
                    onCreate: { showCreateWorkspace = true },
                    onOpenSettings: { ws in settingsWorkspace = ws },
                    onLogout: {
                        Task { await authVM?.logout() }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCreateWorkspace) {
                CreateWorkspaceSheet { ws in
                    appState.currentWorkspaceId = ws.id
                    Task { await loadEvents() }
                }
                .presentationDetents([.fraction(0.45)])
                .presentationDragIndicator(.visible)
            }
```

(`settingsWorkspace` presents `WorkspaceSettingsSheet` — added in Task 8; until then also add a temporary empty sheet so this compiles:)

```swift
            .sheet(item: $settingsWorkspace) { ws in
                // Replaced by WorkspaceSettingsSheet in the next task.
                Text(ws.name)
            }
```

(f) Push taps land in the right workspace. In the `.task(id: deepLinkEventId)` block (line 146), after decoding the record and before appending to the path:

```swift
                    if let wsId = record.workspaceId, appState.currentWorkspaceId != wsId {
                        appState.currentWorkspaceId = wsId
                        await loadEvents()
                    }
```

(g) `NewEventView` gets the real workspace. In the `.navigationDestination(for: NavigationDestination.self)` block, pass it:

```swift
                case .newEvent:
                    NewEventView(workspaceId: currentWorkspace?.id, onCreated: { newEvent in
```

(h) In `Sirr/ContentView.swift` line 30, pass the app state:

```swift
                    EventPageView(authVM: appState.authVM, appState: appState, deepLinkEventId: $appState.deepLinkEventId)
```

And fix the `#Preview` at the bottom of `EventPageView.swift`:

```swift
#Preview {
    EventPageView(appState: AppState())
}
```

- [ ] **Step 4: Remove the dead shim**

Delete the temporary `getEventsForCurrentUser()` shim added in Task 5 from `EventService.swift` — nothing calls it now.

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sirr/Components/WorkspaceSwitcherSheet.swift Sirr/Components/CreateWorkspaceSheet.swift Sirr/pages/EventPageView.swift Sirr/ContentView.swift Sirr/core/supabase/EventService.swift
git commit -m "feat(ios): current-workspace home with switcher, create sheet, zero-workspace state"
```

---

### Task 8: Workspace settings sheet

**Files:**
- Create: `Sirr/Components/WorkspaceSettingsSheet.swift`
- Modify: `Sirr/pages/EventPageView.swift` (swap the placeholder sheet)

**Interfaces:**
- Consumes: `WorkspaceService.getWorkspace/renameWorkspace/regenerateInviteCode/removeMember/leaveWorkspace/deleteWorkspace`, `WorkspaceAvatar`, `WorkspaceRecord.inviteURL`.
- Produces: `WorkspaceSettingsSheet(workspace:currentUserId:onChanged:onLeftOrDeleted:)`.

- [ ] **Step 1: Create `Sirr/Components/WorkspaceSettingsSheet.swift`**

```swift
//
//  WorkspaceSettingsSheet.swift
//  Sirr
//
//  Single half-sheet (same pattern as EventSettingsSheet): identity header,
//  invite-link share, member list (owner can remove), rename/regenerate for the
//  owner, and delete (owner) / leave (member) at the bottom.
//

import SwiftUI

struct WorkspaceSettingsSheet: View {
    let workspace: WorkspaceRecord
    let currentUserId: UUID?
    /// Called after rename/regenerate/remove so home can refresh its list.
    var onChanged: () -> Void
    /// Called after leave or delete; caller clears currentWorkspaceId and reloads.
    var onLeftOrDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var detail: WorkspaceDetail?
    @State private var loadError: String?
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDestructiveConfirm = false

    private var isOwner: Bool { currentUserId == workspace.ownerId }
    private var inviteCode: String? { detail?.workspace.inviteCode ?? workspace.inviteCode }

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        identitySection
                        inviteSection
                        membersSection
                        dangerSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task { await loadDetail() }
        .alert("إعادة تسمية المساحة", isPresented: $showRename) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { handleRename() }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog(
            isOwner ? "حذف المساحة" : "مغادرة المساحة",
            isPresented: $showDestructiveConfirm,
            titleVisibility: .visible
        ) {
            Button(isOwner ? "حذف" : "مغادرة", role: .destructive) { handleLeaveOrDelete() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text(isOwner
                 ? "سيتم حذف المساحة وجميع أحداثها ومشاركيها نهائيًا. لا يمكن التراجع."
                 : "ستفقد الوصول إلى أحداث هذه المساحة وستُزال من الأحداث القادمة.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        ZStack {
            Text("إعدادات المساحة")
                .font(.appSubheadline)
                .foregroundStyle(.white)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var identitySection: some View {
        VStack(spacing: 8) {
            WorkspaceAvatar(name: workspace.name, id: workspace.id, size: 56)
            Text(detail?.workspace.name ?? workspace.name)
                .font(.appSubheadline)
                .foregroundStyle(.white)
            Text("\(detail?.members.count ?? workspace.memberCount ?? 0) أعضاء" + (isOwner ? " · أنت المالك" : ""))
                .font(.appCaption)
                .foregroundStyle(Color(white: 0.55))
            if isOwner {
                Button("إعادة تسمية") {
                    renameText = detail?.workspace.name ?? workspace.name
                    showRename = true
                }
                .font(.appCaption)
                .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let code = inviteCode,
               let url = URL(string: "https://guileless-squirrel-b6537a.netlify.app/join/\(code)") {
                ShareLink(item: url) {
                    HStack {
                        Spacer()
                        Image(systemName: "link")
                        Text("مشاركة رابط الدعوة")
                            .font(.appBody)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.blue.opacity(0.35))
                    )
                }
            }
            if isOwner {
                Button {
                    handleRegenerate()
                } label: {
                    Text("إبطال الرابط وإنشاء رابط جديد")
                        .font(.appCaption)
                        .foregroundStyle(Color(white: 0.55))
                }
                .disabled(isWorking)
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("الأعضاء")
                .font(.appBody)
                .foregroundStyle(Color(white: 0.5))
                .padding(.horizontal, 4)

            if let loadError {
                Text(loadError).font(.appCaption).foregroundStyle(.red)
            } else if let members = detail?.members {
                ForEach(members) { member in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Text(String((member.displayName ?? "؟").prefix(1)))
                                    .font(.appCaption)
                                    .foregroundStyle(.white)
                            )
                        Text(member.displayName ?? "عضو")
                            .font(.appBody)
                            .foregroundStyle(.white)
                        Spacer()
                        if member.isOwner {
                            Text("المالك")
                                .font(.appCaption)
                                .foregroundStyle(Color(white: 0.55))
                        } else if isOwner {
                            Button("إزالة") { handleRemove(member) }
                                .font(.appCaption)
                                .foregroundStyle(.red)
                                .disabled(isWorking)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity)
            }
        }
    }

    private var dangerSection: some View {
        VStack(spacing: 8) {
            Button {
                showDestructiveConfirm = true
            } label: {
                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView().tint(.red)
                    } else {
                        Text(isOwner ? "حذف المساحة" : "مغادرة المساحة")
                            .font(.appBody)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            if let actionError {
                Text(actionError).font(.appCaption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func loadDetail() async {
        do {
            detail = try await WorkspaceService.shared.getWorkspace(id: workspace.id)
        } catch {
            loadError = "تعذر تحميل الأعضاء."
        }
    }

    private func handleRename() {
        run {
            _ = try await WorkspaceService.shared.renameWorkspace(id: workspace.id, name: renameText)
            await loadDetail()
            onChanged()
        }
    }

    private func handleRegenerate() {
        run {
            _ = try await WorkspaceService.shared.regenerateInviteCode(id: workspace.id)
            await loadDetail()
            onChanged()
        }
    }

    private func handleRemove(_ member: WorkspaceMemberRecord) {
        run {
            try await WorkspaceService.shared.removeMember(workspaceId: workspace.id, userId: member.userId)
            await loadDetail()
            onChanged()
        }
    }

    private func handleLeaveOrDelete() {
        run {
            if isOwner {
                try await WorkspaceService.shared.deleteWorkspace(id: workspace.id)
            } else {
                try await WorkspaceService.shared.leaveWorkspace(id: workspace.id)
            }
            onLeftOrDeleted()
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        Task {
            defer { isWorking = false }
            do { try await work() }
            catch { actionError = "تعذر تنفيذ العملية. حاول مرة أخرى." }
        }
    }
}
```

- [ ] **Step 2: Swap the placeholder in `EventPageView`**

Replace the temporary `.sheet(item: $settingsWorkspace)` from Task 7 with:

```swift
            .sheet(item: $settingsWorkspace) { ws in
                WorkspaceSettingsSheet(
                    workspace: ws,
                    currentUserId: authVM?.currentProfile?.userId,
                    onChanged: { Task { await loadEvents() } },
                    onLeftOrDeleted: {
                        appState.currentWorkspaceId = nil
                        currentPage = 0
                        Task { await loadEvents() }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
```

If `authVM?.currentProfile` has no `userId` property, use the session instead: check `Sirr/features/auth/AuthViewModel.swift` for the current user id accessor and pass that (the value must be the auth user id, matching `workspaces.owner_id`). If nothing suitable is published, fetch it inline:

```swift
                    currentUserId: SupabaseClientManager.shared.client.auth.currentSession?.user.id,
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sirr/Components/WorkspaceSettingsSheet.swift Sirr/pages/EventPageView.swift
git commit -m "feat(ios): workspace settings sheet (invite, members, rename, leave/delete)"
```

---

### Task 9: Join flow + retired outsider share flow + AASA

**Files:**
- Modify: `Sirr/pages/JoinWorkspaceView.swift` (replace Task 6 placeholder)
- Modify: `Sirr/ContentView.swift` (logged-in join presentation)
- Modify: `Sirr/pages/SharedEventView.swift` (private-workspace error copy)
- Modify: `landing/.well-known/apple-app-site-association` (add `/join/*`)

**Interfaces:**
- Consumes: `WorkspaceService.getInvitePreview/joinWorkspace`, `AppState.deepLinkJoinCode/currentWorkspaceId`, `WorkspaceAvatar`.
- Produces: full-screen `JoinWorkspaceView` (same construction signature as the Task 6 placeholder — callers don't change).

- [ ] **Step 1: Replace `Sirr/pages/JoinWorkspaceView.swift` wholesale**

```swift
//
//  JoinWorkspaceView.swift
//  Sirr
//
//  Invite-link join screen (sirr://join/{code} or https://<domain>/join/{code}).
//  Shows a preview (name, owner, member count) and one big join button.
//  Logged-out users get a login CTA; ContentView resumes the code post-login.
//

import SwiftUI

struct JoinWorkspaceView: View {
    let code: String
    var isLoggedIn: Bool
    var onDismiss: () -> Void
    var onRequestLogin: () -> Void
    /// Called with the workspace id after a successful join.
    var onJoined: (UUID) -> Void

    @State private var preview: WorkspaceInvitePreview?
    @State private var loadError: String?
    @State private var isJoining = false

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.55, green: 0.23, blue: 0.36),
                    Color(red: 0.10, green: 0.30, blue: 0.23)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if let preview {
                VStack(spacing: 14) {
                    Spacer()
                    WorkspaceAvatar(name: preview.name, id: preview.id, size: 64)
                    Text(preview.name)
                        .font(.appTitle)
                        .foregroundStyle(.white)
                    Text(previewSubtitle(preview))
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("\(preview.memberCount) أعضاء")
                        .font(.appCaption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    joinButton(preview)
                    Button("ليس الآن") { onDismiss() }
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 32)
            } else if let loadError {
                VStack(spacing: 16) {
                    Text("🔗").font(.system(size: 48))
                    Text(loadError)
                        .font(.appBody)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("إغلاق") { onDismiss() }
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView().tint(.white)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task { await loadPreview() }
    }

    private func previewSubtitle(_ p: WorkspaceInvitePreview) -> String {
        if p.isMember { return "أنت عضو في هذه المساحة" }
        if let owner = p.ownerName, !owner.isEmpty { return "دعاك \(owner) للانضمام" }
        return "دُعيت للانضمام"
    }

    @ViewBuilder
    private func joinButton(_ p: WorkspaceInvitePreview) -> some View {
        Button {
            if isLoggedIn { handleJoin() } else { onRequestLogin() }
        } label: {
            Group {
                if isJoining {
                    ProgressView().tint(.black)
                } else {
                    Text(p.isMember ? "فتح المساحة" : (isLoggedIn ? "انضمام" : "سجّل الدخول للانضمام"))
                        .font(.headline)
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color.white))
        }
        .buttonStyle(.plain)
        .disabled(isJoining)
    }

    private func loadPreview() async {
        guard isLoggedIn else {
            // get_workspace_by_invite requires an authenticated session; show a
            // generic invite card prompting login instead of failing.
            preview = nil
            loadError = nil
            // Minimal logged-out experience: straight to the login CTA.
            preview = WorkspaceInvitePreview(id: UUID(), name: "دعوة إلى مساحة", ownerName: nil, memberCount: 0, isMember: false)
            return
        }
        do {
            preview = try await WorkspaceService.shared.getInvitePreview(code: code)
        } catch {
            loadError = "رابط الدعوة غير صالح أو تم إبطاله.\nاطلب رابطًا جديدًا من صاحب المساحة."
        }
    }

    private func handleJoin() {
        guard !isJoining else { return }
        isJoining = true
        Task {
            defer { isJoining = false }
            do {
                let wsId = try await WorkspaceService.shared.joinWorkspace(code: code)
                onJoined(wsId)
                onDismiss()
            } catch {
                loadError = "تعذر الانضمام. حاول مرة أخرى."
            }
        }
    }
}
```

Note: `WorkspaceInvitePreview` needs a memberwise init for the logged-out placeholder — it's a plain struct with `let`s, so Swift synthesizes one (the custom `CodingKeys` doesn't remove it).

- [ ] **Step 2: Present the join screen for logged-IN users**

In `Sirr/ContentView.swift`, the Task 6 block only covers logged-out. Add a logged-in overlay right above it (inside the `ZStack`):

```swift
            if let code = appState.deepLinkJoinCode, appState.isLoggedIn {
                JoinWorkspaceView(
                    code: code,
                    isLoggedIn: true,
                    onDismiss: { appState.deepLinkJoinCode = nil },
                    onRequestLogin: {},
                    onJoined: { wsId in
                        appState.currentWorkspaceId = wsId
                    }
                )
                .transition(.move(edge: .bottom))
            }
```

(`EventPageView.loadEvents()` reruns on its next appearance; switching `currentWorkspaceId` here makes the joined workspace current. `EventPageView`'s `.onAppear` already reloads when the overlay dismisses back to it — verify during the manual pass; if the feed is stale after join, change `EventPageView`'s `.onAppear` `Task` to also observe `appState.currentWorkspaceId` via `.task(id: appState.currentWorkspaceId) { await loadEvents() }`.)

- [ ] **Step 3: Private-workspace copy in `SharedEventView`**

`SharedEventView` still loads events via `getEventById` (line ~285), which now throws for non-members/anonymous users. Find the error state it renders (the `catch` around that call sets an error message) and set this copy for the failure case:

```swift
"هذا الحدث في مساحة خاصة.\nاطلب دعوة من صاحب المساحة للانضمام."
```

Keep the existing login CTA — a logged-out *member* who opens an event link should still be routed to login, after which the deep link resumes and `get_event_by_id` succeeds for them.

- [ ] **Step 4: AASA + landing**

Replace `landing/.well-known/apple-app-site-association` content with:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["V2PFCP3D26.com.businessech.tmrin"],
        "components": [
          { "/": "/event/*", "comment": "Event detail deep link" },
          { "/": "/join/*", "comment": "Workspace invite deep link" }
        ]
      }
    ]
  }
}
```

(No web landing page for `/join/{id}` — same as `/event/{id}` today, which also has no page; the link works when the app is installed. Deploying the updated AASA to Netlify is a user step — flag it in the final report.)

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sirr/pages/JoinWorkspaceView.swift Sirr/ContentView.swift Sirr/pages/SharedEventView.swift landing/.well-known/apple-app-site-association
git commit -m "feat(ios): invite join screen, private-event copy, /join universal link"
```

---

### Task 10: Full SQL suite + manual simulator pass

**Files:** none created — verification only.

- [ ] **Step 1: Full SQL suite green**

```bash
supabase db reset && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
```
Expected: `ALL WORKSPACE TESTS PASSED`.

- [ ] **Step 2: Manual simulator pass (two accounts, A = owner, B = friend)**

Run the app in the simulator against the local stack (or the project's dev Supabase if that's where the team tests — apply migrations there first with `supabase db push`).

1. Fresh account A → zero-workspace empty state → "إنشاء مساحة" → create "شباب الحي" → home shows workspace avatar, empty feed copy names the workspace.
2. A creates an event (＋) → event appears in feed; event carries the workspace.
3. A opens switcher → gear → settings sheet → "مشاركة رابط الدعوة" → copy the link.
4. Account B (second simulator/device or sign out+in): open the invite link (paste in Notes → tap, or `xcrun simctl openurl booted "sirr://join/<code>"`) → join screen shows preview → انضمام → B lands in the workspace and sees A's event.
5. B joins the event → STC Pay flow (أرسلت المبلغ) → A confirms — payment flow unchanged.
6. B opens the workspace settings → "مغادرة المساحة" → B loses the feed; B's participant row on the upcoming event is gone (check A's participants list).
7. A regenerates the invite link → old link shows "رابط الدعوة غير صالح".
8. Outsider C opens an old **event** link → sees the private-workspace message.
9. Push tap (use `scripts/push-sim.sh` if configured) opens the event with the right workspace current.
10. Kill + relaunch A's app → still inside the same workspace (UserDefaults persistence).

- [ ] **Step 3: Report results**

Record any failures as bugs; do not mark this task complete with failing steps. Flag for the user: deploy `landing/` to Netlify (AASA change) and apply migrations to the remote project (`supabase db push`).

---

## Self-Review Notes

- Spec coverage: data model (T1–2), backfill (T2 incl. seeded verification), RPCs (T3), guards + strict privacy (T4), invite links/deep links (T6, T9), switcher UI option B (T7), settings sheet option A (T8), join + empty state (T9), payment/guests untouched (T4 re-creates `submit_payment` byte-identical apart from the guard), testing (per-task + T10).
- `get_event_participants` gained the member gate (spec's "strictly private" — participant names must not leak via the old anon grant).
- Deliberate deviation from the mockup: the empty state's "عندي رابط دعوة" paste-field is replaced by a hint line ("افتح الرابط وسينقلك إلى هنا") — the OS-level link open is the actual join path; a paste-field duplicates it for marginal value. Flag to the user at review.
