# Recurring Workouts (F1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Weekly recurrence templates: a "يتكرر أسبوعيًا" toggle at event creation stores a template, and a daily pg_cron job materializes the next occurrence as a normal `events` row 3 days ahead, pushing "انفتح التسجيل" to all workspace members.

**Architecture:** New `event_templates` table + nullable `events.template_id` (on delete set null). A SECURITY DEFINER generator function runs daily via pg_cron (same pattern as `enqueue_event_reminders`), advancing `next_occurrence_at` in the same transaction as the event insert for idempotency. Pushes reuse the existing `push_outbox` → pg_net trigger → `send-push` pipeline; only `copy.ts` gains a case. Occurrences are ordinary events — join/pay/guests/waitlist/reminders untouched.

**Tech Stack:** Supabase Postgres (plpgsql, pg_cron, RLS), Deno edge function tests, SwiftUI iOS app (`Sirr.xcodeproj`).

**Spec:** `docs/superpowers/specs/2026-07-03-recurring-workouts-design.md`

## Global Constraints

- v1 recurrence is **weekly only**: DB check `recurrence in ('weekly')`, `create_event` accepts `'none' | 'weekly'`, UI is a single toggle labeled **يتكرر أسبوعيًا**.
- Lead time default is **3 days** (`lead_days int not null default 3`), no UI to change it.
- Push copy for the new type `event_opened` is exactly: title `"انفتح التسجيل ⚽"`, body `` `انفتح التسجيل لتمرين ${eventName} — احجز مكانك` ``.
- The generator auto-inserts the **creator as a participant** of each occurrence (same as `create_event`), and the creator gets **no** `event_opened` push.
- Skipping/ending a series never deletes events. Deleting a template keeps its events (`on delete set null`).
- All mutations are SECURITY DEFINER RPCs with the July-2 guard pattern (`auth.uid()` identity check + `is_workspace_member`); RLS gives members SELECT only.
- **Never boot an iOS simulator.** Verify iOS work with a device-less build only: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`. Manual testing is handed to Naif.
- SQL tests run against the LOCAL stack only (`supabase start` must be running): `supabase db reset` then `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql`.
- Work happens on branch `phase_1`. Commit after every task.
- All user-facing strings are Arabic, copied verbatim from this plan.

---

### Task 1: `event_templates` table, `events.template_id`, RLS

**Files:**
- Create: `supabase/migrations/20260704100000_event_templates.sql`
- Create: `supabase/tests/recurring_events_test.sql`

**Interfaces:**
- Consumes: `public.workspaces`, `public.workspace_members`, `public.is_workspace_member(uuid, uuid)`, `public.events` (all existing).
- Produces: table `public.event_templates` (columns exactly as in the migration below) and column `public.events.template_id uuid null references event_templates(id) on delete set null`. Later tasks insert/select these columns by name.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260704100000_event_templates.sql`:

```sql
-- Recurring workout templates (F1). A template stores the weekly series;
-- occurrences are ordinary events rows linked by template_id.
-- Spec: docs/superpowers/specs/2026-07-03-recurring-workouts-design.md

create table public.event_templates (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  creator_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  location text not null default '',
  description text not null default '',
  image_url text,
  latitude double precision,
  longitude double precision,
  total_price int not null default 0,
  price_per_person decimal(10,2) not null default 0,
  max_participants int,
  duration_minutes int,          -- end - start of the first event; null when it had no end date
  recurrence text not null check (recurrence in ('weekly')),  -- relaxes when more rules ship
  next_occurrence_at timestamptz not null,  -- single source of truth for "when is the next one"
  lead_days int not null default 3,         -- occurrence created when now() >= next_occurrence_at - lead_days
  skip_next boolean not null default false, -- one-shot flag consumed by the generator
  ended_at timestamptz,                     -- set by إنهاء التكرار; generator ignores ended templates
  created_at timestamptz not null default now()
);

create index idx_event_templates_workspace_id on public.event_templates(workspace_id);
-- Generator scan: live templates by due date.
create index idx_event_templates_due on public.event_templates(next_occurrence_at) where ended_at is null;

-- Occurrences link back to their series. Deleting a template stops future
-- generation but keeps all generated events (history preserved).
alter table public.events
  add column template_id uuid references public.event_templates(id) on delete set null;
create index idx_events_template_id on public.events(template_id);

alter table public.event_templates enable row level security;

-- Members can read their workspace's templates; all writes go through
-- SECURITY DEFINER RPCs (codebase pattern).
create policy "Members can select workspace templates"
  on public.event_templates for select
  using (public.is_workspace_member(workspace_id, auth.uid()));
```

- [ ] **Step 2: Create the test suite with fixtures + Section 1**

Create `supabase/tests/recurring_events_test.sql`:

```sql
-- Recurring workouts (F1) test suite. Run against the LOCAL stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
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
  ('10000000-0000-0000-0000-000000000001', 'creator@test.local'),
  ('10000000-0000-0000-0000-000000000002', 'member@test.local'),
  ('10000000-0000-0000-0000-000000000003', 'outsider@test.local');
insert into public.users (user_id, name) values
  ('10000000-0000-0000-0000-000000000001', 'المنظّم'),
  ('10000000-0000-0000-0000-000000000002', 'عضو'),
  ('10000000-0000-0000-0000-000000000003', 'غريب');

-- ============================================================
-- Section 1: event_templates table + RLS + template_id set-null
-- ============================================================
do $$
declare
  w_id uuid; t_id uuid; e_id uuid; visible int;
begin
  insert into public.workspaces (name, owner_id)
  values ('مساحة القوالب', '10000000-0000-0000-0000-000000000001')
  returning id into w_id;
  insert into public.workspace_members (workspace_id, user_id) values
    (w_id, '10000000-0000-0000-0000-000000000001'),
    (w_id, '10000000-0000-0000-0000-000000000002');

  insert into public.event_templates
    (workspace_id, creator_id, name, recurrence, next_occurrence_at)
  values
    (w_id, '10000000-0000-0000-0000-000000000001', 'تمرين الأربعاء', 'weekly', now() + interval '9 days')
  returning id into t_id;

  -- lead_days defaults to 3
  perform 1 from public.event_templates where id = t_id and lead_days = 3;
  if not found then raise exception 'FAIL: lead_days default is not 3'; end if;

  -- recurrence check constraint: weekly only in v1
  begin
    insert into public.event_templates (workspace_id, creator_id, name, recurrence, next_occurrence_at)
    values (w_id, '10000000-0000-0000-0000-000000000001', 'x', 'biweekly', now());
    raise exception 'FAIL: biweekly recurrence should be rejected';
  exception when check_violation then null;
  end;

  -- RLS: member sees the template, outsider does not
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  set local role authenticated;
  select count(*) into visible from public.event_templates where id = t_id;
  if visible <> 1 then raise exception 'FAIL: member cannot select template'; end if;
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000003');
  set local role authenticated;
  select count(*) into visible from public.event_templates where id = t_id;
  if visible <> 0 then raise exception 'FAIL: outsider can select template'; end if;
  reset role;

  -- deleting the template keeps events (template_id goes null)
  insert into public.events (creator_id, workspace_id, name, start_date, template_id)
  values ('10000000-0000-0000-0000-000000000001', w_id, 'من قالب', now() + interval '2 days', t_id)
  returning id into e_id;
  delete from public.event_templates where id = t_id;
  perform 1 from public.events where id = e_id and template_id is null;
  if not found then raise exception 'FAIL: deleting template should null template_id and keep the event'; end if;
end $$;

select 'ALL RECURRING EVENT TESTS PASSED' as result;
rollback;
```

(Later tasks insert their sections **before** the final `select ... rollback;` lines.)

- [ ] **Step 3: Run the suite**

```bash
cd /Users/naifalialshahrani/Documents/tamrin
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
```

Expected: migrations apply cleanly; last psql output row is `ALL RECURRING EVENT TESTS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260704100000_event_templates.sql supabase/tests/recurring_events_test.sql
git commit -m "feat(db): event_templates table + events.template_id with member-select RLS"
```

---

### Task 2: `create_event` gains `p_recurrence`

**Files:**
- Create: `supabase/migrations/20260704100100_create_event_recurrence.sql`
- Modify: `supabase/tests/recurring_events_test.sql` (add Section 2)

**Interfaces:**
- Consumes: `event_templates` from Task 1; the existing 13-param `create_event` (dropped and recreated here — its exact prior body is in `supabase/migrations/20260702100300_event_rpcs_workspace_guards.sql:10-49`).
- Produces: `public.create_event(..., p_recurrence text default 'none') returns json`. When `'weekly'`, the returned event json includes a non-null `template_id`. iOS Task 6 passes `p_recurrence` as a string param.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260704100100_create_event_recurrence.sql`:

```sql
-- create_event gains p_recurrence ('none' | 'weekly'). Weekly also inserts an
-- event_templates row and stamps the first event's template_id — one transaction.
-- Body otherwise identical to 20260702100300.
-- Drop the previous overload to avoid PostgREST ambiguity.

drop function if exists public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision);

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
  p_longitude double precision default null,
  p_recurrence text default 'none'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
  v_template_id uuid;
  v_duration_minutes int;
begin
  if p_creator_id is distinct from auth.uid() then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(p_workspace_id, p_creator_id) then
    raise exception 'Not a workspace member';
  end if;
  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Invalid recurrence: %', p_recurrence;
  end if;

  if p_recurrence = 'weekly' then
    if p_end_date is not null then
      v_duration_minutes := (extract(epoch from (p_end_date - p_start_date)) / 60)::int;
    end if;
    insert into public.event_templates
      (workspace_id, creator_id, name, location, description, image_url,
       latitude, longitude, total_price, price_per_person, max_participants,
       duration_minutes, recurrence, next_occurrence_at)
    values
      (p_workspace_id, p_creator_id, p_name, p_location, p_description, p_image_url,
       p_latitude, p_longitude, p_total_price, p_price_per_person, p_max_participants,
       v_duration_minutes, 'weekly', p_start_date + interval '7 days')
    returning id into v_template_id;
  end if;

  insert into public.events (creator_id, workspace_id, name, location, description, start_date, end_date, image_url, max_participants, total_price, price_per_person, latitude, longitude, template_id)
  values (p_creator_id, p_workspace_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants, p_total_price, p_price_per_person, p_latitude, p_longitude, v_template_id)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision, text) to authenticated;
```

- [ ] **Step 2: Add Section 2 to the test suite**

Insert into `supabase/tests/recurring_events_test.sql`, before the final `select 'ALL RECURRING EVENT TESTS PASSED' as result;`:

```sql
-- ============================================================
-- Section 2: create_event with p_recurrence
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; t_id uuid; tpl public.event_templates; cnt int;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة الإنشاء المتكرر');
  w_id := (w->>'id')::uuid;

  -- weekly: template inserted + first event stamped, atomically
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'تمرين متكرر',
    p_location => 'ملعب الحي',
    p_start_date => now() + interval '5 days',
    p_end_date => now() + interval '5 days' + interval '90 minutes',
    p_total_price => 200,
    p_price_per_person => 20,
    p_max_participants => 10,
    p_recurrence => 'weekly'
  );
  t_id := (ev->>'template_id')::uuid;
  if t_id is null then raise exception 'FAIL: weekly create_event did not stamp template_id'; end if;

  select * into tpl from public.event_templates where id = t_id;
  if tpl.id is null then raise exception 'FAIL: template row missing'; end if;
  if tpl.recurrence <> 'weekly' then raise exception 'FAIL: template recurrence %', tpl.recurrence; end if;
  if tpl.duration_minutes <> 90 then raise exception 'FAIL: duration_minutes expected 90, got %', tpl.duration_minutes; end if;
  if abs(extract(epoch from (tpl.next_occurrence_at - ((ev->>'start_date')::timestamptz + interval '7 days')))) > 1 then
    raise exception 'FAIL: next_occurrence_at is not start + 7 days';
  end if;

  -- 'none': no template
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'مرة واحدة',
    p_start_date => now() + interval '3 days',
    p_recurrence => 'none'
  );
  if (ev->>'template_id') is not null then raise exception 'FAIL: none recurrence stamped a template'; end if;
  select count(*) into cnt from public.event_templates where workspace_id = w_id;
  if cnt <> 1 then raise exception 'FAIL: expected exactly 1 template, got %', cnt; end if;

  -- invalid recurrence rejected
  begin
    ev := public.create_event(
      p_creator_id => '10000000-0000-0000-0000-000000000001',
      p_workspace_id => w_id,
      p_name => 'خطأ',
      p_start_date => now() + interval '3 days',
      p_recurrence => 'biweekly'
    );
    raise exception 'FAIL: invalid recurrence accepted';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
```

- [ ] **Step 3: Run the suite**

```bash
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
```

Expected: `ALL RECURRING EVENT TESTS PASSED`.

- [ ] **Step 4: Confirm the old workspaces suite still passes** (create_event was recreated)

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
```

Expected: `ALL WORKSPACE TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260704100100_create_event_recurrence.sql supabase/tests/recurring_events_test.sql
git commit -m "feat(db): create_event p_recurrence — weekly inserts template and stamps template_id"
```

---

### Task 3: Series RPCs — `get_event_template`, `skip_next_occurrence`, `end_recurrence`

**Files:**
- Create: `supabase/migrations/20260704100200_event_template_rpcs.sql`
- Modify: `supabase/tests/recurring_events_test.sql` (add Section 3)

**Interfaces:**
- Consumes: `event_templates` (Task 1), `create_event` with recurrence (Task 2).
- Produces:
  - `public.get_event_template(p_template_id uuid) returns json` — the template row (`row_to_json`), member-gated.
  - `public.skip_next_occurrence(p_template_id uuid, p_event_id uuid) returns json` — `{"status":"skipped","skipped_date":...}` or `{"status":"already_open","event_id":...}`. `p_event_id` is the event whose detail page hosted the button; it is excluded from the "already generated?" check (the series' first event and a generated occurrence are indistinguishable by dates alone).
  - `public.end_recurrence(p_template_id uuid) returns json` — `{"status":"ended"}`.
  - iOS Task 6 calls all three by these exact names/params.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260704100200_event_template_rpcs.sql`:

```sql
-- Series read + creator controls. All SECURITY DEFINER, guarded like the
-- July 2 RPC batch. Skipping/ending never deletes events.

create or replace function public.get_event_template(p_template_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  tpl public.event_templates;
begin
  select * into tpl from public.event_templates where id = p_template_id;
  if tpl.id is null then
    raise exception 'Template not found';
  end if;
  if not public.is_workspace_member(tpl.workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;
  return row_to_json(tpl);
end;
$$;

grant execute on function public.get_event_template(uuid) to authenticated;

-- Skip the next occurrence — only before it has been generated. p_event_id is
-- the event whose page hosted the button; any OTHER future series event means
-- the next occurrence is already open, so the creator deletes that event
-- instead (existing delete_event).
create or replace function public.skip_next_occurrence(p_template_id uuid, p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl public.event_templates;
  v_open_event uuid;
begin
  select * into tpl from public.event_templates where id = p_template_id for update;
  if tpl.id is null then
    raise exception 'Template not found';
  end if;
  if tpl.creator_id is distinct from auth.uid() then
    raise exception 'Not the series creator';
  end if;
  if tpl.ended_at is not null then
    raise exception 'Series has ended';
  end if;

  select id into v_open_event
    from public.events
    where template_id = p_template_id
      and start_date > now()
      and id <> p_event_id
    order by start_date asc
    limit 1;
  if v_open_event is not null then
    return json_build_object('status', 'already_open', 'event_id', v_open_event);
  end if;

  update public.event_templates set skip_next = true where id = p_template_id;
  return json_build_object('status', 'skipped', 'skipped_date', tpl.next_occurrence_at);
end;
$$;

grant execute on function public.skip_next_occurrence(uuid, uuid) to authenticated;

-- End the series. Existing events are untouched.
create or replace function public.end_recurrence(p_template_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl public.event_templates;
begin
  select * into tpl from public.event_templates where id = p_template_id for update;
  if tpl.id is null then
    raise exception 'Template not found';
  end if;
  if tpl.creator_id is distinct from auth.uid() then
    raise exception 'Not the series creator';
  end if;

  update public.event_templates set ended_at = now() where id = p_template_id and ended_at is null;
  return json_build_object('status', 'ended');
end;
$$;

grant execute on function public.end_recurrence(uuid) to authenticated;
```

- [ ] **Step 2: Add Section 3 to the test suite**

Insert before the final `select ... rollback;`:

```sql
-- ============================================================
-- Section 3: series RPCs (get / skip / end)
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; e_id uuid; t_id uuid; r json; g_id uuid;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التحكم بالسلسلة');
  w_id := (w->>'id')::uuid;
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'سلسلة',
    p_start_date => now() + interval '2 days',
    p_end_date => now() + interval '2 days' + interval '1 hour',
    p_recurrence => 'weekly'
  );
  e_id := (ev->>'id')::uuid;
  t_id := (ev->>'template_id')::uuid;

  -- get_event_template: creator (member) reads it
  r := public.get_event_template(t_id);
  if (r->>'id')::uuid <> t_id then raise exception 'FAIL: get_event_template'; end if;

  -- outsider rejected
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000003');
  begin
    r := public.get_event_template(t_id);
    raise exception 'FAIL: outsider read template';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- plain member (not creator) cannot skip
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  r := public.join_workspace((select invite_code from public.workspaces where id = w_id));
  begin
    r := public.skip_next_occurrence(t_id, e_id);
    raise exception 'FAIL: non-creator skipped';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- creator skips from the upcoming first event: nothing generated yet -> skipped
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  r := public.skip_next_occurrence(t_id, e_id);
  if r->>'status' <> 'skipped' then raise exception 'FAIL: skip status %', r->>'status'; end if;
  perform 1 from public.event_templates where id = t_id and skip_next;
  if not found then raise exception 'FAIL: skip_next flag not set'; end if;

  -- a generated future occurrence exists -> already_open + its id
  update public.event_templates set skip_next = false where id = t_id;
  insert into public.events (creator_id, workspace_id, name, start_date, template_id)
  values ('10000000-0000-0000-0000-000000000001', w_id, 'مولّد', now() + interval '9 days', t_id)
  returning id into g_id;
  r := public.skip_next_occurrence(t_id, e_id);
  if r->>'status' <> 'already_open' then raise exception 'FAIL: expected already_open, got %', r->>'status'; end if;
  if (r->>'event_id')::uuid <> g_id then raise exception 'FAIL: already_open returned wrong event'; end if;

  -- end_recurrence: non-creator rejected
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  begin
    r := public.end_recurrence(t_id);
    raise exception 'FAIL: non-creator ended series';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- creator ends; existing events untouched
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  r := public.end_recurrence(t_id);
  if r->>'status' <> 'ended' then raise exception 'FAIL: end_recurrence status %', r->>'status'; end if;
  perform 1 from public.event_templates where id = t_id and ended_at is not null;
  if not found then raise exception 'FAIL: ended_at not set'; end if;
  perform 1 from public.events where id = g_id;
  if not found then raise exception 'FAIL: ending series deleted an event'; end if;
end $$;
```

- [ ] **Step 3: Run the suite**

```bash
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
```

Expected: `ALL RECURRING EVENT TESTS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260704100200_event_template_rpcs.sql supabase/tests/recurring_events_test.sql
git commit -m "feat(db): series RPCs — get_event_template, skip_next_occurrence, end_recurrence"
```

---

### Task 4: Generator function + pg_cron job

**Files:**
- Create: `supabase/migrations/20260704100300_generate_recurring_events.sql`
- Modify: `supabase/tests/recurring_events_test.sql` (add Sections 4–6)

**Interfaces:**
- Consumes: `event_templates` (Task 1), `push_outbox(user_id, type, event_id)` insert → existing pg_net trigger → `send-push` (no changes needed there beyond Task 5's copy).
- Produces: `public.generate_recurring_events() returns void` + cron job named `recurring-events` at `0 5 * * *` UTC (08:00 Riyadh, same slot as `event-reminders-am`). Outbox rows use type `'event_opened'`.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260704100300_generate_recurring_events.sql`:

```sql
-- Daily generator: materialize the next occurrence of each live template as a
-- normal events row once now() enters the lead window, auto-join the creator,
-- and push "انفتح التسجيل" to every other workspace member. Advancing
-- next_occurrence_at in the same transaction as the insert is what makes a
-- double cron run idempotent. Same cron pattern as enqueue_event_reminders.

create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl record;
  new_event public.events;
begin
  for tpl in
    select * from public.event_templates t
    where t.ended_at is null
      and now() >= t.next_occurrence_at - make_interval(days => t.lead_days)
    order by t.next_occurrence_at
    for update
  loop
    -- One-shot skip: consume the flag, advance, create nothing.
    if tpl.skip_next then
      update public.event_templates
        set next_occurrence_at = tpl.next_occurrence_at + interval '7 days',
            skip_next = false
        where id = tpl.id;
      continue;
    end if;

    -- Catch-up: a stale template (e.g. cron was down) advances to the future
    -- without burst-creating past workouts — at most one event per run.
    while tpl.next_occurrence_at <= now() loop
      tpl.next_occurrence_at := tpl.next_occurrence_at + interval '7 days';
    end loop;

    if now() < tpl.next_occurrence_at - make_interval(days => tpl.lead_days) then
      -- Catch-up moved it out of the lead window: persist the new anchor only.
      update public.event_templates
        set next_occurrence_at = tpl.next_occurrence_at
        where id = tpl.id;
      continue;
    end if;

    insert into public.events
      (creator_id, workspace_id, name, location, description, start_date,
       end_date, image_url, max_participants, total_price, price_per_person,
       latitude, longitude, template_id)
    values
      (tpl.creator_id, tpl.workspace_id, tpl.name, tpl.location, tpl.description,
       tpl.next_occurrence_at,
       case when tpl.duration_minutes is not null
            then tpl.next_occurrence_at + make_interval(mins => tpl.duration_minutes) end,
       tpl.image_url, tpl.max_participants, tpl.total_price, tpl.price_per_person,
       tpl.latitude, tpl.longitude, tpl.id)
    returning * into new_event;

    -- Creator auto-joins, same as create_event.
    insert into public.event_participants (event_id, user_id)
    values (new_event.id, tpl.creator_id);

    -- One "registration open" push per workspace member except the creator.
    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, 'event_opened', new_event.id
    from public.workspace_members wm
    where wm.workspace_id = tpl.workspace_id
      and wm.user_id <> tpl.creator_id;

    update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at + interval '7 days'
      where id = tpl.id;
  end loop;
end;
$$;

-- Daily at 05:00 UTC = 08:00 Riyadh, same slot as event-reminders-am.
select cron.schedule('recurring-events', '0 5 * * *', $$select public.generate_recurring_events();$$);
```

- [ ] **Step 2: Add Sections 4–6 to the test suite**

Insert before the final `select ... rollback;`:

```sql
-- ============================================================
-- Section 4: generator — creates one event, copies fields,
-- auto-joins creator, pushes members only, idempotent
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; t_id uuid; r json;
  cnt int; g public.events; v_next timestamptz;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التوليد');
  w_id := (w->>'id')::uuid;
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  r := public.join_workspace((select invite_code from public.workspaces where id = w_id));
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');

  -- first event already played: next occurrence = start + 7d = now() + 2 days,
  -- which is inside the 3-day lead window.
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'تمرين الأربعاء',
    p_location => 'ملعب الحي',
    p_start_date => now() - interval '5 days',
    p_end_date => now() - interval '5 days' + interval '90 minutes',
    p_total_price => 200,
    p_price_per_person => 20,
    p_max_participants => 10,
    p_recurrence => 'weekly'
  );
  t_id := (ev->>'template_id')::uuid;
  select next_occurrence_at into v_next from public.event_templates where id = t_id;

  -- run 1: exactly one new event
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 1 then raise exception 'FAIL: generator run 1 created % events', cnt; end if;

  select * into g from public.events
    where template_id = t_id and id <> (ev->>'id')::uuid;

  -- fields copied
  if g.name <> 'تمرين الأربعاء' or g.location <> 'ملعب الحي' or g.total_price <> 200
     or g.max_participants <> 10 or g.workspace_id <> w_id
     or g.creator_id <> '10000000-0000-0000-0000-000000000001' then
    raise exception 'FAIL: generated event fields not copied';
  end if;
  if abs(extract(epoch from (g.start_date - v_next))) > 1 then
    raise exception 'FAIL: generated start_date != next_occurrence_at';
  end if;
  if g.end_date is null or abs(extract(epoch from (g.end_date - (g.start_date + interval '90 minutes')))) > 1 then
    raise exception 'FAIL: generated end_date != start + duration';
  end if;

  -- creator auto-joined
  select count(*) into cnt from public.event_participants
    where event_id = g.id and user_id = '10000000-0000-0000-0000-000000000001';
  if cnt <> 1 then raise exception 'FAIL: creator not auto-joined'; end if;

  -- one event_opened push, member only, never the creator
  select count(*) into cnt from public.push_outbox where event_id = g.id and type = 'event_opened';
  if cnt <> 1 then raise exception 'FAIL: expected 1 event_opened outbox row, got %', cnt; end if;
  select count(*) into cnt from public.push_outbox
    where event_id = g.id and user_id = '10000000-0000-0000-0000-000000000001';
  if cnt <> 0 then raise exception 'FAIL: creator received event_opened push'; end if;

  -- next_occurrence_at advanced exactly one interval
  perform 1 from public.event_templates where id = t_id
    and abs(extract(epoch from (next_occurrence_at - (v_next + interval '7 days')))) < 1;
  if not found then raise exception 'FAIL: next_occurrence_at not advanced by 7 days'; end if;

  -- run 2: idempotent (next occurrence now outside the lead window)
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 1 then raise exception 'FAIL: generator not idempotent — % events after run 2', cnt; end if;
end $$;

-- ============================================================
-- Section 5: skip consumption, ended templates, catch-up
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; t_id uuid; cnt int; v_next timestamptz;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التخطي والإنهاء');
  w_id := (w->>'id')::uuid;

  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'سيُتخطى',
    p_start_date => now() - interval '5 days',
    p_recurrence => 'weekly'
  );
  t_id := (ev->>'template_id')::uuid;

  -- skip consumption: flag set + inside window -> no event, flag reset, date advanced
  update public.event_templates set skip_next = true where id = t_id;
  select next_occurrence_at into v_next from public.event_templates where id = t_id;
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 0 then raise exception 'FAIL: skip still generated an event'; end if;
  perform 1 from public.event_templates where id = t_id
    and not skip_next
    and abs(extract(epoch from (next_occurrence_at - (v_next + interval '7 days')))) < 1;
  if not found then raise exception 'FAIL: skip not consumed correctly'; end if;

  -- ended template: generator ignores it even inside the window
  update public.event_templates
    set ended_at = now(), next_occurrence_at = now() + interval '1 day'
    where id = t_id;
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 0 then raise exception 'FAIL: ended template generated an event'; end if;

  -- catch-up: a far-behind template creates at most one event and lands in the future
  update public.event_templates
    set ended_at = null, skip_next = false, next_occurrence_at = now() - interval '20 days'
    where id = t_id;
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt > 1 then raise exception 'FAIL: catch-up burst-created % events', cnt; end if;
  perform 1 from public.event_templates where id = t_id and next_occurrence_at > now();
  if not found then raise exception 'FAIL: catch-up left next_occurrence_at in the past'; end if;
end $$;

-- ============================================================
-- Section 6: cron job registered
-- ============================================================
do $$
declare cnt int;
begin
  select count(*) into cnt from cron.job where jobname = 'recurring-events';
  if cnt <> 1 then raise exception 'FAIL: recurring-events cron job not scheduled'; end if;
end $$;
```

- [ ] **Step 3: Run the suite**

```bash
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
```

Expected: `ALL RECURRING EVENT TESTS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260704100300_generate_recurring_events.sql supabase/tests/recurring_events_test.sql
git commit -m "feat(db): generate_recurring_events + daily pg_cron job"
```

---

### Task 5: `event_opened` push copy (TDD)

**Files:**
- Modify: `supabase/functions/send-push/copy.ts`
- Test: `supabase/functions/send-push/copy_test.ts`

**Interfaces:**
- Consumes: `copyFor(type, eventName)` — `send-push/index.ts` already looks up the event name from `push_outbox.event_id` and calls `copyFor(row.type, eventName)`, so a new case is the entire edge-function change.
- Produces: `copyFor("event_opened", name)` returns the F1 announcement copy.

- [ ] **Step 1: Write the failing test**

Add to `supabase/functions/send-push/copy_test.ts` (before the `unknown type` test):

```ts
Deno.test("event_opened copy interpolates the event name", () => {
  const c = copyFor("event_opened", "تمرين الأربعاء");
  assertEquals(c, {
    title: "انفتح التسجيل ⚽",
    body: "انفتح التسجيل لتمرين تمرين الأربعاء — احجز مكانك",
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
deno test supabase/functions/send-push/copy_test.ts
```

Expected: FAIL — `event_opened copy ...` assertion error (`copyFor` returns `null`).

- [ ] **Step 3: Add the copy case**

In `supabase/functions/send-push/copy.ts`, add before the `default:` case:

```ts
    case "event_opened":
      return {
        title: "انفتح التسجيل ⚽",
        body: `انفتح التسجيل لتمرين ${eventName} — احجز مكانك`,
      };
```

- [ ] **Step 4: Run test to verify it passes**

```bash
deno test supabase/functions/send-push/copy_test.ts
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(push): event_opened announcement copy"
```

---

### Task 6: iOS — `templateId` on models + EventService template API

**Files:**
- Modify: `Sirr/core/supabase/EventService.swift`
- Modify: `Sirr/Models/EventData.swift`

**Interfaces:**
- Consumes: RPCs from Tasks 2–3 (`create_event` `p_recurrence`, `get_event_template`, `skip_next_occurrence`, `end_recurrence`). `get_workspace_events`/`get_event_by_id` return `row_to_json(events)`, so `template_id` flows through with no server change.
- Produces (used by Tasks 7–9):
  - `EventRecord.templateId: UUID?`, `EventData.templateId: UUID?`
  - `struct EventTemplateRecord: Codable` (`id`, `workspaceId`, `creatorId`, `recurrence`, `nextOccurrenceAt: Date`, `skipNext: Bool`, `endedAt: Date?`)
  - `enum SkipNextResult { case skipped(Date?); case alreadyOpen(UUID?) }`
  - `EventService.createEvent(..., recurrence: String = "none")`
  - `EventService.getEventTemplate(templateId: UUID) async throws -> EventTemplateRecord`
  - `EventService.skipNextOccurrence(templateId: UUID, fromEventId: UUID) async throws -> SkipNextResult`
  - `EventService.endRecurrence(templateId: UUID) async throws`

- [ ] **Step 1: Add `templateId` to `EventRecord`**

In `Sirr/core/supabase/EventService.swift`, add to `EventRecord`'s properties (after `let workspaceId: UUID?`):

```swift
    let templateId: UUID?
```

and to its `CodingKeys` (after `case workspaceId = "workspace_id"`):

```swift
        case templateId = "template_id"
```

- [ ] **Step 2: Add the template record, skip result, and shared decoder**

In the same file, below the `ParticipantRecord` struct, add:

```swift
/// Row from public.event_templates (via get_event_template RPC).
struct EventTemplateRecord: Codable {
    let id: UUID
    let workspaceId: UUID
    let creatorId: UUID
    let recurrence: String
    let nextOccurrenceAt: Date
    let skipNext: Bool
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case creatorId = "creator_id"
        case recurrence
        case nextOccurrenceAt = "next_occurrence_at"
        case skipNext = "skip_next"
        case endedAt = "ended_at"
    }
}

/// Result of skip_next_occurrence: skipped now, or the next occurrence was
/// already generated (the creator deletes that event instead).
enum SkipNextResult {
    case skipped(Date?)
    case alreadyOpen(UUID?)
}
```

Inside `final class EventService`, add (near the top, after `private let client`):

```swift
    /// Decoder handling Postgres timestamp formats (same strategy the RPC
    /// decoders in this file use inline).
    private static func makePostgresDecoder() -> JSONDecoder {
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
        return decoder
    }
```

- [ ] **Step 3: Extend `createEvent` with `recurrence`**

Add a parameter to `createEvent`'s signature (after `longitude: Double? = nil`):

```swift
        recurrence: String = "none"
```

and add to the `params` construction (after the `longitude` line):

```swift
        if recurrence != "none" { params["p_recurrence"] = recurrence }
```

- [ ] **Step 4: Add the three template methods**

Add at the end of `EventService` (before the closing brace):

```swift
    /// Recurrence template backing a series-linked event.
    func getEventTemplate(templateId: UUID) async throws -> EventTemplateRecord {
        let params: [String: String] = ["p_template_id": templateId.uuidString]
        let response = try await client
            .rpc("get_event_template", params: params)
            .execute()
        let template = try Self.makePostgresDecoder().decode(EventTemplateRecord.self, from: response.data)
        eventLogger.info("API getEventTemplate succeeded (id: \(template.id))")
        return template
    }

    /// Skip the series' next occurrence. `fromEventId` is the event whose page
    /// hosted the button (the server excludes it when checking whether the
    /// next occurrence is already open).
    func skipNextOccurrence(templateId: UUID, fromEventId: UUID) async throws -> SkipNextResult {
        struct SkipResponse: Decodable {
            let status: String
            let skippedDate: Date?
            let eventId: UUID?
            enum CodingKeys: String, CodingKey {
                case status
                case skippedDate = "skipped_date"
                case eventId = "event_id"
            }
        }
        let params: [String: String] = [
            "p_template_id": templateId.uuidString,
            "p_event_id": fromEventId.uuidString
        ]
        let response = try await client
            .rpc("skip_next_occurrence", params: params)
            .execute()
        let result = try Self.makePostgresDecoder().decode(SkipResponse.self, from: response.data)
        eventLogger.info("API skipNextOccurrence: \(result.status)")
        return result.status == "already_open"
            ? .alreadyOpen(result.eventId)
            : .skipped(result.skippedDate)
    }

    /// End the series. Existing events are untouched.
    func endRecurrence(templateId: UUID) async throws {
        let params: [String: String] = ["p_template_id": templateId.uuidString]
        try await client
            .rpc("end_recurrence", params: params)
            .execute()
        eventLogger.info("API endRecurrence succeeded (templateId: \(templateId))")
    }
```

- [ ] **Step 5: Add `templateId` to `EventData`**

In `Sirr/Models/EventData.swift`:
- Add property after `let longitude: Double?`:

```swift
    /// Non-nil when this event belongs to a recurring series.
    let templateId: UUID?
```

- Add `templateId: UUID? = nil` to the `init` parameter list (after `longitude: Double? = nil`) and `self.templateId = templateId` in the body.
- In `EventData.from(record:)`, add after `longitude: record.longitude`:

```swift
            longitude: record.longitude,
            templateId: record.templateId
```

(i.e. append the argument; keep the argument order matching the init).

- [ ] **Step 6: Build check**

```bash
cd /Users/naifalialshahrani/Documents/tamrin
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED` (do NOT boot a simulator).

- [ ] **Step 7: Commit**

```bash
git add Sirr/core/supabase/EventService.swift Sirr/Models/EventData.swift
git commit -m "feat(ios): templateId on event models + EventService series API"
```

---

### Task 7: iOS — "يتكرر أسبوعيًا" toggle in NewEventView

**Files:**
- Modify: `Sirr/pages/NewEventView.swift`

**Interfaces:**
- Consumes: `EventService.createEvent(..., recurrence:)` from Task 6.
- Produces: creating with the toggle on passes `recurrence: "weekly"`.

- [ ] **Step 1: Add state**

In `NewEventView`'s state block (after `@State private var playerApprovalEnabled: Bool = false`):

```swift
    @State private var repeatsWeekly: Bool = false
```

- [ ] **Step 2: Add the toggle row under the date pickers**

In `body`, directly after the `customDateRangePicker` block:

```swift
                customDateRangePicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                // Weekly recurrence toggle (F1)
                recurrenceToggle
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
```

Add the view next to `playerApprovalToggle` (same capsule style):

```swift
    // MARK: - Weekly Recurrence Toggle
    private var recurrenceToggle: some View {
        HStack {
            Text("يتكرر أسبوعيًا")
                .font(.appBody)
                .foregroundStyle(.white)

            Spacer()

            Toggle("", isOn: $repeatsWeekly)
                .labelsHidden()
                .tint(.blue)
        }
        .frame(height: 50)
        .padding(.horizontal, 18)
        .background(
            Capsule().fill(.white.opacity(0.1))
        )
    }
```

- [ ] **Step 3: Pass recurrence on create**

In `submitCreateEvent()`, add to the `EventService.shared.createEvent(` call (after `longitude: selectedCoordinate?.longitude`):

```swift
                longitude: selectedCoordinate?.longitude,
                recurrence: repeatsWeekly ? "weekly" : "none"
```

- [ ] **Step 4: Build check**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sirr/pages/NewEventView.swift
git commit -m "feat(ios): weekly recurrence toggle on new-event form"
```

---

### Task 8: iOS — series section on event detail + settings-sheet cleanup

**Files:**
- Modify: `Sirr/pages/EventHeroDetailView.swift`
- Modify: `Sirr/Components/EventSettingsSheet.swift`

**Interfaces:**
- Consumes: `EventData.templateId`, `EventTemplateRecord`, `SkipNextResult`, `EventService.getEventTemplate/skipNextOccurrence/endRecurrence` (Task 6). `ActionChip(icon:title:style:)` exists in `EventHeroDetailView.swift` with `.solid`/`.translucent` styles.
- Produces: creator-only "سلسلة متكررة" section with skip/end actions.

- [ ] **Step 1: Add state to `EventHeroDetailView`**

After `@State private var ownerActionError: String? = nil`:

```swift
    // Recurring series (F1): loaded when the event is template-linked.
    @State private var seriesTemplate: EventTemplateRecord?
    @State private var showSkipConfirm = false
    @State private var showEndConfirm = false
    @State private var showSkipAlreadyOpen = false
    @State private var isSeriesActionInFlight = false
    @State private var seriesActionError: String?
```

- [ ] **Step 2: Load the template**

In the `.onAppear { Task { ... } }` block (currently loads `currentUserId` + `loadParticipants()`), add after `await loadParticipants()`:

```swift
                if let templateId = event.templateId {
                    seriesTemplate = try? await EventService.shared.getEventTemplate(templateId: templateId)
                }
```

- [ ] **Step 3: Add the series section view**

Add alongside the other private views (e.g. after the `isOwner` computed property):

```swift
    /// Creator-only controls for a recurring series (سلسلة متكررة).
    @ViewBuilder
    private var seriesSection: some View {
        if isOwner, let template = seriesTemplate, template.endedAt == nil {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "repeat")
                        .font(.system(size: 14, weight: .semibold))
                    Text("سلسلة متكررة — أسبوعيًا")
                        .font(.appBodySemibold)
                    Spacer()
                    Text(EventData.formatEventDate(template.nextOccurrenceAt, endDate: nil))
                        .font(.appCaption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)

                HStack(spacing: 12) {
                    if template.skipNext {
                        Text("سيتم تخطّي الأسبوع القادم")
                            .font(.appCaption)
                            .foregroundStyle(.yellow)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Capsule().fill(Color.yellow.opacity(0.18)))
                    } else {
                        Button {
                            showSkipConfirm = true
                        } label: {
                            ActionChip(icon: "forward.end.fill", title: "تخطَّ الأسبوع القادم", style: .translucent)
                                .opacity(isSeriesActionInFlight ? 0.5 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSeriesActionInFlight)
                    }

                    Button {
                        showEndConfirm = true
                    } label: {
                        ActionChip(icon: "xmark.circle.fill", title: "إنهاء التكرار", style: .translucent)
                            .opacity(isSeriesActionInFlight ? 0.5 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSeriesActionInFlight)
                }

                if let err = seriesActionError {
                    Text(err)
                        .font(.appCaption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.12))
            )
        }
    }
```

- [ ] **Step 4: Render it and wire the dialogs**

In `body`, insert `seriesSection` right after the owner-actions `HStack` closes (the block ending with the settings `.sheet` at the `}` before `} else {` of `if isOwner`):

```swift
                        }
                        seriesSection
                    } else {
```

Add the dialogs next to the existing `.sheet` modifiers (after `.sheet(isPresented: $showWaitlistSheet) { ... }`):

```swift
        .confirmationDialog(
            "تخطَّ الأسبوع القادم",
            isPresented: $showSkipConfirm,
            titleVisibility: .visible
        ) {
            Button("تخطَّ", role: .destructive) { handleSkipNext() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("لن يُنشأ تمرين الأسبوع القادم، وتستمر السلسلة بعده كالمعتاد.")
        }
        .confirmationDialog(
            "إنهاء التكرار",
            isPresented: $showEndConfirm,
            titleVisibility: .visible
        ) {
            Button("إنهاء", role: .destructive) { handleEndRecurrence() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("لن تُنشأ تمارين جديدة من هذه السلسلة. التمارين الحالية تبقى كما هي.")
        }
        .alert("التمرين القادم منشور بالفعل", isPresented: $showSkipAlreadyOpen) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text("تمرين الأسبوع القادم منشور. إذا أردت إلغاءه، افتح صفحته واحذفه من الإعدادات.")
        }
```

- [ ] **Step 5: Add the handlers**

Next to `handleLeaveEvent()`:

```swift
    private func handleSkipNext() {
        guard let template = seriesTemplate, !isSeriesActionInFlight else { return }
        isSeriesActionInFlight = true
        seriesActionError = nil
        Task {
            defer { isSeriesActionInFlight = false }
            do {
                let result = try await EventService.shared.skipNextOccurrence(templateId: template.id, fromEventId: event.id)
                switch result {
                case .skipped:
                    seriesTemplate = try? await EventService.shared.getEventTemplate(templateId: template.id)
                case .alreadyOpen:
                    showSkipAlreadyOpen = true
                }
            } catch {
                seriesActionError = "تعذر تخطي الأسبوع القادم. حاول مرة أخرى."
            }
        }
    }

    private func handleEndRecurrence() {
        guard let template = seriesTemplate, !isSeriesActionInFlight else { return }
        isSeriesActionInFlight = true
        seriesActionError = nil
        Task {
            defer { isSeriesActionInFlight = false }
            do {
                try await EventService.shared.endRecurrence(templateId: template.id)
                seriesTemplate = nil
            } catch {
                seriesActionError = "تعذر إنهاء التكرار. حاول مرة أخرى."
            }
        }
    }
```

- [ ] **Step 6: Remove the dead UI-only recurrence menu from `EventSettingsSheet`**

The sheet's "متكرر" menu (`Recurrence` enum, `@State private var recurrence`, and the `menuRow(title: "متكرر", ...)` in `managementSection`) is unpersisted placeholder UI that now misleads (real recurrence lives on creation + the series section). In `Sirr/Components/EventSettingsSheet.swift`:
- Delete the `Recurrence` enum (lines defining `case never/weekly/monthly`).
- Delete `@State private var recurrence: Recurrence = .never`.
- In `managementSection`, delete the `menuRow(title: "متكرر", value: recurrence.rawValue) { ... }` block, leaving `deleteButton` (and the error text) as the section content.
- Update the file header comment: change `Guest-limit, guest-approval and recurrence controls are UI-only for now` to `Guest-limit and guest-approval controls are UI-only for now`.

- [ ] **Step 7: Build check**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add Sirr/pages/EventHeroDetailView.swift Sirr/Components/EventSettingsSheet.swift
git commit -m "feat(ios): recurring-series section with skip/end actions; drop dead recurrence menu"
```

---

### Task 9: iOS — recurrence badge on the feed card

**Files:**
- Modify: `Sirr/NewActivtyCardView.swift`
- Modify: `Sirr/pages/EventPageView.swift`

**Interfaces:**
- Consumes: `EventData.templateId` (Task 6).
- Produces: `NewActivtyCardView(eventName:eventDate:imageURL:imageName:isRecurring:)`.

- [ ] **Step 1: Add the badge to the card**

In `Sirr/NewActivtyCardView.swift`, add a property after `var imageName: ImageResource = .card1`:

```swift
    /// Shows the "يتكرر أسبوعيًا" badge for series-linked events.
    var isRecurring: Bool = false
```

Add an overlay on the card (between the `GeometryReader { ... }` closing brace and `.clipShape(`):

```swift
        .overlay(alignment: .topTrailing) {
            if isRecurring {
                HStack(spacing: 6) {
                    Image(systemName: "repeat")
                        .font(.system(size: 12, weight: .semibold))
                    Text("يتكرر أسبوعيًا")
                        .font(.appCaption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(16)
            }
        }
```

- [ ] **Step 2: Pass the flag from the feed**

In `Sirr/pages/EventPageView.swift`, in `workoutFeed(geometry:insets:)`, extend the card call:

```swift
                            NewActivtyCardView(
                                eventName: event.name,
                                eventDate: event.date,
                                imageURL: event.imageUrl,
                                imageName: .card1,
                                isRecurring: event.templateId != nil
                            )
```

- [ ] **Step 3: Build check**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sirr/NewActivtyCardView.swift Sirr/pages/EventPageView.swift
git commit -m "feat(ios): weekly-recurrence badge on feed cards"
```

---

### Task 10: Final verification + handoff

**Files:** none (verification only)

- [ ] **Step 1: Run both SQL suites and the deno test once more**

```bash
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspaces_test.sql
deno test supabase/functions/send-push/copy_test.ts
```

Expected: `ALL RECURRING EVENT TESTS PASSED`, `ALL WORKSPACE TESTS PASSED`, deno tests PASS.

- [ ] **Step 2: Final build check**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Hand over to Naif for device testing**

Do NOT deploy or boot simulators. Report completion and hand over this manual pass (deployment first requires `supabase db push` and `supabase functions deploy send-push` — Naif's call when to run them):

1. Create a weekly paid workout (toggle on) → confirm a template row exists and the event shows the series section + feed badge.
2. In the SQL editor, shorten the lead (`update event_templates set next_occurrence_at = now() + interval '2 days';`) and run `select generate_recurring_events();` → next occurrence appears in the feed with the badge and a fresh participant list (creator only).
3. A second member's device receives the "انفتح التسجيل ⚽" push; tapping it opens the new event.
4. تخطَّ الأسبوع القادم before generation → confirms and shows "سيتم تخطّي الأسبوع القادم"; after generation → alert points to deleting the open event.
5. إنهاء التكرار → section disappears; existing events stay; generator creates nothing new.
