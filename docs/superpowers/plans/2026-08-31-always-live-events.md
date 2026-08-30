# Always-live events and the 24-hour payment grace — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every event live the moment it is created, and stop an unpaid seat from blocking anyone — the debt is waived 24 hours after the event starts.

**Architecture:** Four SQL migrations move the invite-and-push work out of `publish_event` and into `create_event`, delete the payment gate that withholds the next occurrence, add a waiver that rides the existing per-minute `recurring-events` cron, and teach `get_my_feed` to keep a finished-but-unpaid occurrence visible for 24 hours. Two Swift tasks then remove the publish UI and restore the poster card's action bar, which has been dead since `cf5ae1e`.

**Tech Stack:** PostgreSQL (Supabase, pg_cron), SwiftUI (iOS 26), plain `.sql` test scripts run through `psql`.

## Global Constraints

- Migrations are new timestamped files. Never edit an applied migration in place.
- **Do not run `supabase db reset`** — it is broken on this machine. Apply a migration with `psql -f`, then run the test with `psql -f`.
- Test connection string, used verbatim everywhere below:
  `postgresql://postgres:postgres@127.0.0.1:54322/postgres`
- Every test script runs with `-v ON_ERROR_STOP=1` and opens with `begin;`.
- "Has not declared payment" always means `payment_status = 'pending' AND payment_declared_at IS NULL`.
- The grace deadline is always `start_date + interval '24 hours'` — never end date.
- The `published_at` column stays and is always non-null after this work. Do not drop it.
- User-facing copy is Arabic. Digits render Western (`0123456789`) via the app's locale; do not hand-write Arabic-Indic digits.
- `git commit` at the end of every task. Never stage `Sirr.xcodeproj/project.pbxproj`.

---

## File Structure

**Created:**
- `supabase/migrations/20260831100000_waive_expired_event_debts.sql` — widens `payment_status`, adds the waiver, hangs it on the cron
- `supabase/migrations/20260831110000_invite_without_payment_gate.sql` — deletes the debt gate
- `supabase/migrations/20260831120000_create_event_goes_live.sql` — create publishes, invites, pushes; drops `publish_event`
- `supabase/migrations/20260831130000_linger_unpaid_occurrence.sql` — 24h linger in `get_my_feed`
- `supabase/tests/waive_expired_event_debts_test.sql`
- `supabase/tests/create_event_goes_live_test.sql`
- `supabase/tests/linger_unpaid_occurrence_test.sql`

**Modified:**
- `supabase/tests/recurring_payment_gate_test.sql` — currently asserts the gate this plan deletes; inverted
- `Sirr/features/home/EventPosterCard.swift` — action bar restored, publish tag removed
- `Sirr/features/home/DesignerHomeView.swift` — publish action, state and sheet removed
- `Sirr/core/supabase/EventService.swift:1186-1194` — `publishEvent` removed
- `Sirr/features/home/MockHomeFeed.swift:1895-1908` — `publish(_:)` removed
- `Sirr/core/supabase/ServerErrorMessage.swift:68,138` — two dead errors removed

---

### Task 1: Waive a debt 24 hours after the event starts

**Files:**
- Create: `supabase/migrations/20260831100000_waive_expired_event_debts.sql`
- Test: `supabase/tests/waive_expired_event_debts_test.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `public.waive_expired_event_debts() returns integer` — the number of rows waived. `payment_status` accepts the new value `'waived'`. Task 4 relies on `'waived'` existing.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/waive_expired_event_debts_test.sql`:

```sql
-- Waiver tests. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/waive_expired_event_debts_test.sql

begin;

insert into auth.users (id, email) values
  ('61000000-0000-0000-0000-000000000001', 'waive-owner@test.local'),
  ('61000000-0000-0000-0000-000000000002', 'waive-late@test.local'),
  ('61000000-0000-0000-0000-000000000003', 'waive-declared@test.local');

insert into public.workspaces (id, name, owner_id)
values ('61000000-0000-0000-0000-0000000000a1', 'Waiver WS',
        '61000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id)
values ('61000000-0000-0000-0000-0000000000a1', '61000000-0000-0000-0000-000000000002'),
       ('61000000-0000-0000-0000-0000000000a1', '61000000-0000-0000-0000-000000000003');

-- Started 25 hours ago: past the deadline.
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at)
values ('61000000-0000-0000-0000-0000000000b1',
        '61000000-0000-0000-0000-000000000001',
        '61000000-0000-0000-0000-0000000000a1',
        'Expired', now() - interval '25 hours', now() - interval '23 hours', now());

-- Started 2 hours ago: still inside the grace window.
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at)
values ('61000000-0000-0000-0000-0000000000b2',
        '61000000-0000-0000-0000-000000000001',
        '61000000-0000-0000-0000-0000000000a1',
        'Fresh', now() - interval '2 hours', now() - interval '1 hour', now());

insert into public.event_participants (event_id, user_id, payment_status, payment_declared_at)
values
  -- expired + never declared: waived
  ('61000000-0000-0000-0000-0000000000b1', '61000000-0000-0000-0000-000000000002', 'pending', null),
  -- expired but declared: untouched
  ('61000000-0000-0000-0000-0000000000b1', '61000000-0000-0000-0000-000000000003', 'pending', now()),
  -- inside the window: untouched
  ('61000000-0000-0000-0000-0000000000b2', '61000000-0000-0000-0000-000000000002', 'pending', null);

do $$
declare
  v_waived integer;
begin
  v_waived := public.waive_expired_event_debts();
  if v_waived <> 1 then
    raise exception 'expected 1 waived row, got %', v_waived;
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b1'
        and user_id = '61000000-0000-0000-0000-000000000002') <> 'waived' then
    raise exception 'an undeclared debt past the deadline must be waived';
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b1'
        and user_id = '61000000-0000-0000-0000-000000000003') <> 'pending' then
    raise exception 'a declared payment must never be waived';
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b2'
        and user_id = '61000000-0000-0000-0000-000000000002') <> 'pending' then
    raise exception 'a debt inside the 24h window must not be waived yet';
  end if;

  -- Idempotence: a second run has nothing left to move.
  v_waived := public.waive_expired_event_debts();
  if v_waived <> 0 then
    raise exception 'second run must waive nothing, waived %', v_waived;
  end if;
end;
$$;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/waive_expired_event_debts_test.sql
```

Expected: FAIL — `function public.waive_expired_event_debts() does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260831100000_waive_expired_event_debts.sql`:

```sql
-- A seat nobody paid for stops being owed a day after the exercise starts.
--
-- The deadline is measured from start_date, not from the end, so a two-hour
-- session and a four-hour one give the member the same 24 hours from a time
-- the group already knows.

alter table public.event_participants
  drop constraint if exists event_participants_payment_status_check;

alter table public.event_participants
  add constraint event_participants_payment_status_check
  check (payment_status in ('pending', 'confirmed', 'rejected', 'waived'));

comment on constraint event_participants_payment_status_check
  on public.event_participants is
  'waived is written only by waive_expired_event_debts(), 24h after start_date.';

create or replace function public.waive_expired_event_debts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  with waived as (
    update public.event_participants ep
    set payment_status = 'waived'
    from public.events e
    where e.id = ep.event_id
      and ep.payment_status = 'pending'
      and ep.payment_declared_at is null
      and e.cancelled_at is null
      and e.start_date + interval '24 hours' <= now()
    returning ep.event_id
  )
  select count(*) into v_count from waived;
  return v_count;
end;
$$;

revoke execute on function public.waive_expired_event_debts()
  from public, anon, authenticated;

-- Rides the per-minute recurring-events job rather than adding a schedule, so
-- the waiver lands within a minute of the deadline.
create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.generate_recurring_events_internal();
  perform public.waive_expired_event_debts();
end;
$$;

notify pgrst, 'reload schema';
```

**Note for the implementer:** `generate_recurring_events` already exists and holds the generation logic directly. Before writing the block above, open `supabase/migrations/20260829100000_roll_recurring_events_after_end.sql`, find the current `create or replace function public.generate_recurring_events()`, rename that body verbatim to `generate_recurring_events_internal()` in this new migration, and only then add the two-line wrapper. Do not retype the generation logic from memory.

- [ ] **Step 4: Apply and run the test**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260831100000_waive_expired_event_debts.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/waive_expired_event_debts_test.sql
```

Expected: PASS, no exception raised.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260831100000_waive_expired_event_debts.sql supabase/tests/waive_expired_event_debts_test.sql
git commit -m "feat(payments): forgive an undeclared seat a day after kickoff"
```

---

### Task 2: Invite the next occurrence to everyone, paid or not

**Files:**
- Modify: `supabase/migrations/` — new file `20260831110000_invite_without_payment_gate.sql`
- Test: `supabase/tests/recurring_payment_gate_test.sql` (inverted)

**Interfaces:**
- Consumes: nothing
- Produces: `publish_recurring_event_internal(uuid, uuid)` keeps its signature; it simply no longer excludes anyone.

- [ ] **Step 1: Invert the existing test**

Open `supabase/tests/recurring_payment_gate_test.sql`. It currently asserts that a member with an undeclared payment receives **no** `event_member_responses` row for the next occurrence. Change that assertion to its opposite, and update the file header comment.

Replace the assertion block that expects the gate with:

```sql
do $$
begin
  -- The gate is gone: an undeclared payment no longer withholds anything.
  if not exists (
    select 1 from public.event_member_responses
    where event_id = v_next_event_id
      and user_id = '52000000-0000-0000-0000-000000000003'
  ) then
    raise exception 'an owing member must still be invited to the next occurrence';
  end if;

  if not exists (
    select 1 from public.push_outbox
    where event_id = v_next_event_id
      and user_id = '52000000-0000-0000-0000-000000000003'
      and type = 'event_invited'
  ) then
    raise exception 'an owing member must still be pushed';
  end if;
end;
$$;
```

**Note:** the variable and user ids above are the ones already in that file — read it and match them rather than pasting blindly. Keep every other case in the file as it is.

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_payment_gate_test.sql
```

Expected: FAIL — `an owing member must still be invited to the next occurrence`, because the gate is still in place.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260831110000_invite_without_payment_gate.sql`. Copy `publish_recurring_event_internal` verbatim from `20260829100000_roll_recurring_events_after_end.sql` and delete only the `and not exists (...)` block that joins `debt_event`, `debt_template`, `current_template` and `debt`:

```sql
-- An undeclared payment used to withhold the next occurrence indefinitely.
-- It no longer withholds anything: the debt is waived a day after the event
-- starts instead, and the organizer takes non-payment up with the person.
--
-- series_key stays. It is what keeps an occurrence attached to its series
-- across a template edit, which the waiver and the feed both still need.

create or replace function public.publish_recurring_event_internal(
  p_event_id uuid,
  p_invited_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then return; end if;

  with inserted as (
    insert into public.event_member_responses
      (event_id, user_id, status, invited_by, invited_at, updated_at)
    select v_event.id, wm.user_id, 'invited', p_invited_by, now(), now()
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id <> v_event.creator_id
      and wm.user_id <> p_invited_by
      and not exists (
        select 1
        from public.event_participants ep
        where ep.event_id = v_event.id
          and ep.user_id = wm.user_id
      )
    on conflict (event_id, user_id) do nothing
    returning user_id
  )
  insert into public.push_outbox (user_id, type, event_id)
  select i.user_id, 'event_invited', v_event.id
  from inserted i
  where not exists (
    select 1
    from public.push_outbox po
    where po.event_id = v_event.id
      and po.user_id = i.user_id
      and po.type in ('event_opened', 'event_invited')
  );
end;
$$;

revoke execute on function public.publish_recurring_event_internal(uuid, uuid)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Apply and run the test**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260831110000_invite_without_payment_gate.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_payment_gate_test.sql
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260831110000_invite_without_payment_gate.sql supabase/tests/recurring_payment_gate_test.sql
git commit -m "feat(events): stop withholding next week over an unpaid seat"
```

---

### Task 3: Creating an event puts it in front of the group

**Files:**
- Create: `supabase/migrations/20260831120000_create_event_goes_live.sql`
- Create: `supabase/tests/create_event_goes_live_test.sql`
- Modify: `supabase/tests/event_lifecycle_test.sql`

**Interfaces:**
- Consumes: `publish_recurring_event_internal(uuid, uuid)` from Task 2 — reused as the invite path so creation and rollover invite identically.
- Produces: `create_event(...)` unchanged in signature and return shape. `publish_event(uuid)` no longer exists — nothing may call it after this task.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/create_event_goes_live_test.sql`:

```sql
-- Creation publishes. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/create_event_goes_live_test.sql

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
begin
  perform pg_temp.set_auth('62000000-0000-0000-0000-000000000001');

  v_result := public.create_event(
    p_creator_id => '62000000-0000-0000-0000-000000000001',
    p_workspace_id => '62000000-0000-0000-0000-0000000000a1',
    p_name => 'Live on create',
    p_start_date => now() + interval '2 days',
    p_end_date => now() + interval '2 days 2 hours'
  );
  v_event_id := (v_result ->> 'id')::uuid;

  if (select published_at from public.events where id = v_event_id) is null then
    raise exception 'a created event must be live immediately';
  end if;

  if not exists (
    select 1 from public.event_member_responses
    where event_id = v_event_id
      and user_id = '62000000-0000-0000-0000-000000000002'
  ) then
    raise exception 'creating an event must invite the workspace members';
  end if;

  if not exists (
    select 1 from public.push_outbox
    where event_id = v_event_id
      and user_id = '62000000-0000-0000-0000-000000000002'
      and type = 'event_invited'
  ) then
    raise exception 'creating an event must push the workspace members';
  end if;

  -- The organizer never invites or pushes themselves.
  if exists (
    select 1 from public.push_outbox
    where event_id = v_event_id
      and user_id = '62000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'the organizer must not be pushed about their own event';
  end if;

  -- publish_event is gone.
  if exists (
    select 1 from pg_proc where proname = 'publish_event'
  ) then
    raise exception 'publish_event must no longer exist';
  end if;
end;
$$;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/create_event_goes_live_test.sql
```

Expected: FAIL — `a created event must be live immediately`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260831120000_create_event_goes_live.sql`. Copy `create_event` verbatim from `20260821100000_capacity_policy_and_waitlist_promotion.sql`, then make exactly two changes to the copy:

Change the `published_at` value in the insert from `null` to `now()`:

```sql
  -- before:  v_payment_method_ids, null, p_capacity_policy)
  -- after:
     v_payment_method_ids, now(), p_capacity_policy)
```

And immediately after `returning * into v_event;`, invite the group through the same path the weekly rollover uses:

```sql
  -- The draft state is gone, so creation does what publish_event used to do.
  -- Reusing the rollover's path keeps one definition of "invite the group".
  perform public.publish_recurring_event_internal(v_event.id, v_uid);
```

Then append, at the end of the same migration file:

```sql
-- Nothing can be unpublished any more, so there is nothing left to publish.
drop function if exists public.publish_event(uuid);

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Strip publication from the lifecycle test**

Open `supabase/tests/event_lifecycle_test.sql`. Delete every case that calls `public.publish_event(...)` or asserts on a draft being invisible. Where a case only needed publication as setup, delete the `publish_event` call — the event is already live.

- [ ] **Step 5: Apply and run both tests**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260831120000_create_event_goes_live.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/create_event_goes_live_test.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_lifecycle_test.sql
```

Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260831120000_create_event_goes_live.sql supabase/tests/create_event_goes_live_test.sql supabase/tests/event_lifecycle_test.sql
git commit -m "feat(events): an exercise is live the moment it is made"
```

---

### Task 4: Keep the unpaid card for a day

**Files:**
- Create: `supabase/migrations/20260831130000_linger_unpaid_occurrence.sql`
- Create: `supabase/tests/linger_unpaid_occurrence_test.sql`

**Interfaces:**
- Consumes: `'waived'` from Task 1 — a waived row must not keep the card alive.
- Produces: `get_my_feed()` returns finished occurrences the caller still owes, alongside upcoming ones. Its column list is unchanged; Task 6 needs no new field.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/linger_unpaid_occurrence_test.sql`:

```sql
-- The finished card lingers while it is owed. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/linger_unpaid_occurrence_test.sql

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
  ('63000000-0000-0000-0000-000000000001', 'linger-owner@test.local'),
  ('63000000-0000-0000-0000-000000000002', 'linger-owes@test.local'),
  ('63000000-0000-0000-0000-000000000003', 'linger-settled@test.local');

insert into public.workspaces (id, name, owner_id)
values ('63000000-0000-0000-0000-0000000000a1', 'Linger WS',
        '63000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id)
values ('63000000-0000-0000-0000-0000000000a1', '63000000-0000-0000-0000-000000000002'),
       ('63000000-0000-0000-0000-0000000000a1', '63000000-0000-0000-0000-000000000003');

-- Finished two hours ago, still inside the 24h grace.
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at)
values ('63000000-0000-0000-0000-0000000000b1',
        '63000000-0000-0000-0000-000000000001',
        '63000000-0000-0000-0000-0000000000a1',
        'Last Sunday', now() - interval '4 hours', now() - interval '2 hours', now());

insert into public.event_participants (event_id, user_id, payment_status, payment_declared_at)
values ('63000000-0000-0000-0000-0000000000b1', '63000000-0000-0000-0000-000000000002', 'pending', null),
       ('63000000-0000-0000-0000-0000000000b1', '63000000-0000-0000-0000-000000000003', 'confirmed', now());

do $$
declare
  v_feed json;
begin
  perform pg_temp.set_auth('63000000-0000-0000-0000-000000000002');
  v_feed := public.get_my_feed();
  if v_feed::text not like '%63000000-0000-0000-0000-0000000000b1%' then
    raise exception 'an owing member must still see the finished occurrence';
  end if;

  perform pg_temp.set_auth('63000000-0000-0000-0000-000000000003');
  v_feed := public.get_my_feed();
  if v_feed::text like '%63000000-0000-0000-0000-0000000000b1%' then
    raise exception 'a settled member must not see the finished occurrence';
  end if;

  -- Waiving it removes the card even though the event is unchanged.
  update public.event_participants set payment_status = 'waived'
  where event_id = '63000000-0000-0000-0000-0000000000b1'
    and user_id = '63000000-0000-0000-0000-000000000002';

  perform pg_temp.set_auth('63000000-0000-0000-0000-000000000002');
  v_feed := public.get_my_feed();
  if v_feed::text like '%63000000-0000-0000-0000-0000000000b1%' then
    raise exception 'a waived debt must drop the finished occurrence';
  end if;
end;
$$;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/linger_unpaid_occurrence_test.sql
```

Expected: FAIL — `an owing member must still see the finished occurrence`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260831130000_linger_unpaid_occurrence.sql`. Copy `get_my_feed` verbatim from `20260830140000_get_my_feed.sql` and widen its three time filters.

Each of the three currently reads:

```sql
          and coalesce(e.end_date, e.start_date) >= now()
```

Replace each with the same clause plus the debt exception. Use the table alias that the surrounding query actually uses — `e.` in the first, bare column names in the second and third:

```sql
          and (
            coalesce(e.end_date, e.start_date) >= now()
            -- A finished exercise stays on the feed of whoever still owes for
            -- it, until the waiver clears the debt a day after it started.
            or exists (
              select 1
              from public.event_participants ep
              where ep.event_id = e.id
                and ep.payment_status = 'pending'
                and ep.payment_declared_at is null
                and (ep.user_id = v_uid or (ep.user_id is null and ep.added_by = v_uid))
            )
          )
```

Since `published_at` is now always set, the `published_at is not null or is_workspace_owner(...)` guards beside them are always true; leave them alone — Task 3 already made them inert and removing them is out of scope.

End the file with:

```sql
notify pgrst, 'reload schema';
```

- [ ] **Step 4: Apply and run the test**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260831130000_linger_unpaid_occurrence.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/linger_unpaid_occurrence_test.sql
```

Expected: PASS.

- [ ] **Step 5: Run the whole suite for regressions**

```bash
for f in supabase/tests/*_test.sql; do echo "--- $f"; psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f "$f" >/dev/null || echo "FAILED $f"; done
```

Expected: no `FAILED` line. `get_my_feed_test.sql` is the one most likely to break — if it asserts that a past event is absent, give its member a settled row.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260831130000_linger_unpaid_occurrence.sql supabase/tests/linger_unpaid_occurrence_test.sql supabase/tests/get_my_feed_test.sql
git commit -m "feat(home): let an owed exercise linger over the new one"
```

---

### Task 5: Take publishing out of the app

**Files:**
- Modify: `Sirr/core/supabase/EventService.swift:1186-1194`
- Modify: `Sirr/features/home/MockHomeFeed.swift:1895-1908`
- Modify: `Sirr/features/home/DesignerHomeView.swift:51,546-557,712-727`
- Modify: `Sirr/features/home/EventPosterCard.swift`
- Modify: `Sirr/core/supabase/ServerErrorMessage.swift:68,138`
- Delete: `AdminPublishEventSheet` — find its file with `grep -rn "struct AdminPublishEventSheet" Sirr`

**Interfaces:**
- Consumes: nothing
- Produces: `cardActions(for:)` returns owner actions without a publish entry. `EventPosterCard` no longer takes a `publishTag:` argument — Task 6 restores its action bar against this reduced surface.

- [ ] **Step 1: Delete the service call**

In `Sirr/core/supabase/EventService.swift`, delete `publishEvent(eventId:)` together with its doc comment (around lines 1186–1194).

- [ ] **Step 2: Delete the feed method**

In `Sirr/features/home/MockHomeFeed.swift`, delete `func publish(_ occurrence: FeedOccurrence) async -> RegistrationOutcome` and its doc comment (around lines 1895–1908).

- [ ] **Step 3: Delete the publish action, state and sheet**

In `Sirr/features/home/DesignerHomeView.swift`:

Delete the `@State private var publishConfirmation: FeedOccurrence?` declaration at line 51.

Delete the whole `.sheet(item: $publishConfirmation) { ... }` modifier (lines 546–557).

In `cardActions(for:)`, delete the `EventPosterCardAction(id: "send", ...)` entry and the two locals that only it used, so the owner branch begins:

```swift
        if feed.isOwner(of: occurrence) {
            let actionInFlight = eventActionsInFlight[occurrence.id]
            let actionsEnabled = actionInFlight == nil
            return [
                EventPosterCardAction(
                    id: "edit",
```

- [ ] **Step 4: Delete the publish tag from the card**

In `Sirr/features/home/EventPosterCard.swift`, delete `EventPosterPublishTagView`, the `EventPosterPublishTag` enum, the `publishTag` property and its initializer parameter, and every use of it in the layout. Fix the previews at the bottom of the file that pass `publishTag:`.

- [ ] **Step 5: Delete the two dead errors**

In `Sirr/core/supabase/ServerErrorMessage.swift`, delete the entries at lines 68 and 138:

```swift
        "Event is not published": "التمرين ما انفتح للتسجيل بعد.",
        "Template is not published": "قالب التمرين ما اننشر بعد.",
```

- [ ] **Step 6: Build**

```bash
xcodebuild build -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Any "cannot find `publishTag`" error is a preview or call site missed in Step 4.

- [ ] **Step 7: Commit**

```bash
git add Sirr/
git commit -m "refactor(events): drop publishing now that nothing is a draft"
```

---

### Task 6: Give the card its actions back

**Files:**
- Modify: `Sirr/features/home/EventPosterCard.swift:134-211`

**Interfaces:**
- Consumes: `EventPosterCardAction` (already declared at the top of the file, lines 6–39) and `cardActions(for:)` from Task 5.
- Produces: nothing later tasks depend on. This is the last task.

This restores what `cf5ae1e` deleted, adapted to the rebuilt layout. The card now has a progressive-blur artwork and an avatar cluster that the old version did not, so the bar is re-added as a sibling in the existing `ZStack(alignment: .bottom)` rather than by reverting the commit.

- [ ] **Step 1: Add the action bar and its cell**

In `Sirr/features/home/EventPosterCard.swift`, add `hasActions` next to the other computed properties:

```swift
    private var hasActions: Bool { !actions.isEmpty }
```

Add `actionBar` as a new property after `posterArtwork`:

```swift
    private var actionBar: some View {
        HStack(spacing: 0) {
            ForEach(actions) { item in
                EventPosterCardActionCell(item: item)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.black.opacity(0.28))
                }
        }
        .colorScheme(.dark)
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
```

Add the cell and its press style at file scope, after the `EventPosterCard` struct's closing brace:

```swift
private struct EventPosterCardActionCell: View {
    let item: EventPosterCardAction

    private var symbolColor: Color {
        switch item.kind {
        case .primary:
            TamrinTheme.lime
        case .secondary:
            .white.opacity(0.84)
        case .destructive:
            .white.opacity(0.72)
        case .status:
            TamrinTheme.lime
        }
    }

    private var accessibilityValue: String {
        if item.isLoading { return "جارٍ التنفيذ" }
        if item.kind == .status { return "مكتمل" }
        if !item.isEnabled { return "غير متاح حاليًا" }
        return ""
    }

    var body: some View {
        Button(action: item.action) {
            VStack(spacing: 5) {
                Group {
                    if item.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(symbolColor)
                    } else {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(symbolColor)
                    }
                }
                .frame(height: 24)
                .accessibilityHidden(true)

                Text(item.title)
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(EventActionPressStyle())
        .disabled(!item.isEnabled || item.isLoading)
        .opacity(item.isEnabled || item.kind == .status ? 1 : 0.42)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
    }
}

private struct EventActionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
```

- [ ] **Step 2: Place the bar and make room for it**

In `posterContent`, change the text `VStack`'s bottom padding so the bar does not cover the location line:

```swift
            .padding(.top, 76)
            .padding(.bottom, hasActions ? 122 : 32)
```

Then add the bar as the last child of the `ZStack(alignment: .bottom)`, immediately after that `VStack`'s `.frame(maxWidth: .infinity)`:

```swift
            if hasActions {
                actionBar
            }
```

- [ ] **Step 3: Take the actions out of the card's own button**

The whole card is wrapped in `Button(action: action)`. A button inside a button does not receive taps on iOS, so the bar has to sit outside it. In `body`, restructure so the poster is the button and the bar is layered over it:

```swift
    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: action) {
                posterContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(occurrence.title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
            .accessibilityValue("\(registeredCount) من \(occurrence.capacity) مسجلين")
            .accessibilityHint("يفتح تفاصيل الموعد")

            if hasActions {
                actionBar
            }
        }
        .clipShape(.rect(cornerRadius: 36, style: .continuous))
```

and remove the `if hasActions { actionBar }` added inside `posterContent` in Step 2 — keep only the padding change there. The rest of `body` below `.clipShape` is unchanged.

- [ ] **Step 4: Build**

```bash
xcodebuild build -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify on device**

This is the step the whole plan exists for, and it cannot be checked by building. Install on the device and confirm, as the organizer:

1. The poster card shows تعديل / تخطي / حذف. Each opens its sheet.
2. Creating an event makes it appear for a member account without any publish step, and pushes it.
3. A member who owes still sees last week's card above next week's, with دفع القطة.
4. Declaring payment removes the old card immediately.

- [ ] **Step 6: Commit**

```bash
git add Sirr/features/home/EventPosterCard.swift
git commit -m "fix(home): draw the card's actions again"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: draft removal and invite-on-create → Task 3; rollover unconditional → Task 2; the 24-hour linger → Task 4; the waiver and the `waived` state → Task 1; the action bar → Task 6; publish UI removal → Task 5. The spec's "out of scope" items (dropping `published_at`, payment enforcement, the lineup's own publish) appear in no task, correctly.

**Ordering.** Task 3 calls `publish_recurring_event_internal`, so Task 2 must land first — it does. Task 4 asserts on `'waived'`, so Task 1 must land first — it does. Task 6 restores a bar whose contents Task 5 defines, so Task 5 comes first.

**Known risk in Task 6, Step 3.** The nested-button problem is real but the exact restructuring may fight the existing `.background` and shadow chain below `.clipShape`. If the bar renders but does not receive taps, the cause is the outer `Button` still wrapping it — not the padding. Do not solve it by putting the actions back inside `posterContent`.

**Not verified.** The three time filters in `get_my_feed` (Task 4, Step 3) were located by grep at lines 61, 77 and 96; the implementer must confirm the alias in each before editing, as two of the three are inside subqueries that do not use `e.`.
