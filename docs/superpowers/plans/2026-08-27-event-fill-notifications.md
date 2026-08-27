# Fill Milestone Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify an event's owner by push each time their session crosses a quarter of its capacity, and when it fills.

**Architecture:** A statement-level `AFTER INSERT` trigger on `event_participants` calls `announce_event_fill()`, which compares the seated count against a high-water mark stored on `events.fill_notified_pct` and enqueues one `push_outbox` row for `creator_id`. A trigger rather than eight RPC call sites, because eight functions can seat someone and the ninth added later would silently not notify.

**Tech Stack:** PostgreSQL 15 / plpgsql (Supabase), Deno (edge function copy), no iOS changes.

**Spec:** `docs/superpowers/specs/2026-08-27-event-fill-notifications-design.md`

## Global Constraints

- **Migration file:** `supabase/migrations/20260827110000_event_fill_notifications.sql`. Tasks 1–3 all edit this same file — that is safe **only** because it is not pushed to any remote until Task 5. Once a migration has been pushed, never edit it; add a new one.
- **Local `supabase db reset` is broken** on this machine — it dies on the avatar-storage migrations because the local stack has no `storage.buckets`. Apply migrations directly instead:
  `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f <file>`
- **SQL tests** run with: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f <file>`. A pass ends in `ROLLBACK` with no `ERROR` line. Failures are `raise exception`.
- **There is no local `deno` binary.** Edge-function tests run through Docker:
  `docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts`
- **`workspaces_test.sql` already fails** (`FAIL: member submit_payment status free_event`) for reasons unrelated to this work. Do not fix it here; do not treat it as a regression.
- **Never commit `Sirr.xcodeproj/project.pbxproj` or `.DS_Store`.**
- **Push copy is Arabic** and lives only in `supabase/functions/send-push/copy.ts`. Exact strings are given in Task 4 — copy them character for character, including emoji.
- **Seated** means `payment_status in ('pending', 'confirmed')` everywhere. Waitlist rows live in `event_waitlist` and never count.

## File Structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20260827110000_event_fill_notifications.sql` | Create: the `fill_notified_pct` column, `announce_event_fill()`, and its trigger |
| `supabase/tests/event_fill_notifications_test.sql` | Create: the whole behaviour suite for the above |
| `supabase/functions/send-push/copy.ts` | Modify: four new `case` labels |
| `supabase/functions/send-push/copy_test.ts` | Modify: four new `Deno.test` blocks |

## Background the implementer needs

`create_event` seats its creator immediately (`insert into event_participants (event_id, user_id) values (...)`), and `payment_status` defaults to `'confirmed'`. **So a freshly created 16-seat event already holds 1 seat.** Every seat count below accounts for this.

`add_manual_participant(p_event_id, p_name)` is called by the owner, so it is the tool for testing owner-caused crossings. `register_event_seat(p_event_id, p_guest_names, p_expected_price_per_person)` seats the caller plus their named guests in one statement — the tool for testing non-owner crossings and batches. All four of these RPCs return `json`.

`guard_event_registration_insert` — the other trigger already on `event_participants` — rejects inserts into unpublished sessions (`Event is not published`) and cancelled ones (`Event is cancelled`) before the fill trigger runs. Two consequences:

- The **unpublished** case can only be tested through the creator's own seat, which `create_event` inserts before publication. The test below uses a one-seat session so that seat is 100% of capacity.
- The **cancelled** case is unreachable through any public path. The `cancelled_at` check in `announce_event_fill()` is defence in depth and is deliberately not tested; do not contort a test to reach it, and do not delete the check.

---

### Task 1: Column, function, trigger, and the core milestone behaviour

Fixed quarters only — the capacity-dependent threshold set arrives in Task 2, and the owner-silence rule in Task 3.

**Files:**
- Create: `supabase/migrations/20260827110000_event_fill_notifications.sql`
- Create: `supabase/tests/event_fill_notifications_test.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `public.announce_event_fill() returns trigger`; `public.events.fill_notified_pct smallint not null default 0`; trigger `trg_announce_event_fill on public.event_participants`; push types `event_fill_25`, `event_fill_50`, `event_fill_75`, `event_full` enqueued into `push_outbox`.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/event_fill_notifications_test.sql`:

```sql
-- Fill milestone notifications to the event owner. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql

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

-- Counts owner-bound pushes of one type for one event.
create or replace function pg_temp.fill_pushes(p_event_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id and type = p_type;
$$;

insert into auth.users (id, email) values
  ('46000000-0000-0000-0000-000000000001', 'fill-owner@test.local'),
  ('46000000-0000-0000-0000-000000000002', 'fill-member-b@test.local'),
  ('46000000-0000-0000-0000-000000000003', 'fill-member-c@test.local');

insert into public.users (user_id, name) values
  ('46000000-0000-0000-0000-000000000001', 'مشرف الامتلاء'),
  ('46000000-0000-0000-0000-000000000002', 'عضو ب'),
  ('46000000-0000-0000-0000-000000000003', 'عضو ج');

do $$
declare
  v_workspace json;
  v_workspace_id uuid;
  v_event json;
  v_big_event_id uuid;
  v_batch_event_id uuid;
  v_uncapped_event_id uuid;
  v_draft_event_id uuid;
  v_result json;
  v_mark int;
begin
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_workspace := public.create_workspace('مجموعة الامتلاء');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '46000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '46000000-0000-0000-0000-000000000003');

  -- ---------------------------------------------------------------------
  -- A 16 seat session announces each quarter exactly once. The owner's own
  -- seat from create_event is already one of the sixteen.
  -- ---------------------------------------------------------------------
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين كبير',
    p_start_date => now() + interval '3 days',
    p_max_participants => 16
  );
  v_big_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_big_event_id);

  -- 1/16 = 6%: nothing yet.
  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_25') <> 0 then
    raise exception 'FAIL: announced a quarter at one seat';
  end if;

  -- Member B takes 3 seats -> 4/16 = 25%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ب1', 'ضيف ب2']
  );
  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_25') <> 1 then
    raise exception 'FAIL: quarter not announced at 4/16';
  end if;

  -- Member C takes 4 seats -> 8/16 = 50%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ج1', 'ضيف ج2', 'ضيف ج3']
  );
  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: half not announced at 8/16';
  end if;

  -- Four more of member C's guests -> 12/16 = 75%.
  v_result := public.register_event_guests(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ج4', 'ضيف ج5', 'ضيف ج6', 'ضيف ج7']
  );
  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_75') <> 1 then
    raise exception 'FAIL: three quarters not announced at 12/16';
  end if;

  -- Four more -> 16/16 = 100%.
  v_result := public.register_event_guests(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ج8', 'ضيف ج9', 'ضيف ج10', 'ضيف ج11']
  );
  if pg_temp.fill_pushes(v_big_event_id, 'event_full') <> 1 then
    raise exception 'FAIL: full not announced at 16/16';
  end if;

  -- Each quarter announced once, not repeatedly on the way past.
  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_25') <> 1
     or pg_temp.fill_pushes(v_big_event_id, 'event_fill_50') <> 1
     or pg_temp.fill_pushes(v_big_event_id, 'event_fill_75') <> 1 then
    raise exception 'FAIL: a quarter announced more than once';
  end if;

  -- ---------------------------------------------------------------------
  -- A batch that vaults a milestone announces only the one it landed on.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين الدفعة',
    p_start_date => now() + interval '4 days',
    p_max_participants => 16
  );
  v_batch_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_batch_event_id);

  -- Owner holds 1. Member B takes 7 in one statement -> 8/16 = 50%,
  -- straight past 25%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_batch_event_id,
    p_guest_names => array['د1', 'د2', 'د3', 'د4', 'د5', 'د6']
  );
  if pg_temp.fill_pushes(v_batch_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: the landed milestone was not announced';
  end if;
  if pg_temp.fill_pushes(v_batch_event_id, 'event_fill_25') <> 0 then
    raise exception 'FAIL: a vaulted milestone was announced too';
  end if;

  -- ---------------------------------------------------------------------
  -- Falling back under a milestone does not re-arm it.
  -- ---------------------------------------------------------------------
  v_result := public.leave_event(
    v_batch_event_id,
    '46000000-0000-0000-0000-000000000002'
  );
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(
    p_event_id => v_batch_event_id,
    p_guest_names => array['ه1', 'ه2', 'ه3', 'ه4', 'ه5', 'ه6']
  );
  if pg_temp.fill_pushes(v_batch_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: half announced a second time after a withdrawal';
  end if;

  -- ---------------------------------------------------------------------
  -- No capacity means no percentage.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين بلا سقف',
    p_start_date => now() + interval '5 days'
  );
  v_uncapped_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_uncapped_event_id);

  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_uncapped_event_id,
    p_guest_names => array['و1', 'و2', 'و3']
  );
  select count(*) into v_mark from public.push_outbox
  where event_id = v_uncapped_event_id and type like 'event_fill%';
  if v_mark <> 0 then
    raise exception 'FAIL: an uncapped session announced a milestone';
  end if;

  -- ---------------------------------------------------------------------
  -- An unpublished session announces nothing, however full it is. A single
  -- seat is the whole capacity here, so create_event's own insert of the
  -- creator would be 100% if publication were not required.
  --
  -- It has to be tested this way round: guard_event_registration_insert
  -- rejects every other insert into a draft session with "Event is not
  -- published", so the creator's seat is the only one that can reach the
  -- fill trigger at all.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مسودة',
    p_start_date => now() + interval '6 days',
    p_max_participants => 1
  );
  v_draft_event_id := (v_event->>'id')::uuid;

  select count(*) into v_mark from public.push_outbox
  where event_id = v_draft_event_id;
  if v_mark <> 0 then
    raise exception 'FAIL: a draft session announced a milestone';
  end if;

  select fill_notified_pct into v_mark from public.events
  where id = v_draft_event_id;
  if v_mark <> 0 then
    raise exception 'FAIL: a draft session advanced its mark';
  end if;

  raise notice 'ALL FILL NOTIFICATION TESTS PASSED';
end;
$$;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql
```

Expected: `ERROR: FAIL: quarter not announced at 4/16`. (The earlier assertion — that nothing is announced at one seat — passes trivially because nothing announces anything yet.)

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260827110000_event_fill_notifications.sql`:

```sql
-- Tell an organizer, unprompted, each time their session crosses a quarter of
-- its capacity — and when it fills.
--
-- Eight functions insert into event_participants (add_manual_participant,
-- create_event, generate_recurring_events, join_event, promote_from_waitlist,
-- register_event_guest_batch_impl, register_event_seat, and
-- submit_payment_v2_before_guest_only). This is a trigger rather than eight
-- call sites because the ninth path added later would silently not notify —
-- exactly how 20260820100000_pay_after_registering left the guest path behind.

alter table public.events
  add column if not exists fill_notified_pct smallint not null default 0;

comment on column public.events.fill_notified_pct is
  'High-water mark of the fill milestone already announced to the owner: 0, 25, 50, 75 or 100. Never decreases, so a withdrawal cannot re-arm a milestone.';

create or replace function public.announce_event_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_seated int;
  v_pct int;
  v_thresholds int[];
  v_milestone int;
  v_type text;
begin
  -- Ordered so two concurrent registrations on different events cannot take
  -- these row locks in opposite orders.
  for v_event in
    select e.*
    from public.events e
    where e.id in (select distinct n.event_id from new_rows n)
    order by e.id
    for update
  loop
    -- Nobody can act on a session they cannot see, a skipped one has no
    -- roster worth reporting, and without a cap there is no percentage.
    if v_event.published_at is null
       or v_event.cancelled_at is not null
       or v_event.max_participants is null then
      continue;
    end if;

    select count(*) into v_seated
    from public.event_participants ep
    where ep.event_id = v_event.id
      and ep.payment_status in ('pending', 'confirmed');

    v_pct := (v_seated * 100) / v_event.max_participants;

    v_thresholds := array[25, 50, 75, 100];

    -- The highest milestone now passed that has not been announced. Taking
    -- the highest is what makes a batch vaulting 40% to 80% announce 75%
    -- alone rather than 50% and 75% together.
    select max(t) into v_milestone
    from unnest(v_thresholds) as t
    where t <= v_pct and t > v_event.fill_notified_pct;

    if v_milestone is null then
      continue;
    end if;

    update public.events
    set fill_notified_pct = v_milestone
    where id = v_event.id;

    v_type := case v_milestone
      when 100 then 'event_full'
      else 'event_fill_' || v_milestone::text
    end;

    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, v_type, v_event.id);
  end loop;

  return null;
end;
$$;

revoke execute on function public.announce_event_fill()
  from public, anon, authenticated;

-- Statement-level with a transition table, because guests are inserted as a
-- batch: a row-level trigger would re-count the roster once per guest and
-- could announce two milestones for a single request.
drop trigger if exists trg_announce_event_fill on public.event_participants;
create trigger trg_announce_event_fill
  after insert on public.event_participants
  referencing new table as new_rows
  for each statement
  execute function public.announce_event_fill();

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Apply the migration and run the test**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260827110000_event_fill_notifications.sql
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql
```

Expected: `NOTICE: ALL FILL NOTIFICATION TESTS PASSED`, then `ROLLBACK`, with no `ERROR` line.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260827110000_event_fill_notifications.sql supabase/tests/event_fill_notifications_test.sql
git commit -m "feat(events): announce fill milestones to the owner"
```

---

### Task 2: Halves instead of quarters below eight seats

On a 4-seat session a quarter is one player, so quarters would mean a notification per join.

**Files:**
- Modify: `supabase/migrations/20260827110000_event_fill_notifications.sql` (the `v_thresholds` assignment)
- Modify: `supabase/tests/event_fill_notifications_test.sql` (append a case before `raise notice`)

**Interfaces:**
- Consumes: `announce_event_fill()` and `fill_notified_pct` from Task 1.
- Produces: no new names. Sessions with `max_participants < 8` announce only `event_fill_50` and `event_full`.

- [ ] **Step 1: Write the failing test**

In `supabase/tests/event_fill_notifications_test.sql`, add `v_small_event_id uuid;` to the `declare` block, and insert this immediately **before** the `raise notice 'ALL FILL NOTIFICATION TESTS PASSED';` line:

```sql
  -- ---------------------------------------------------------------------
  -- Under eight seats a quarter is one player, so only halves announce.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين صغير',
    p_start_date => now() + interval '7 days',
    p_max_participants => 4
  );
  v_small_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_small_event_id);

  -- Owner holds 1 of 4 = 25%: a quarter, but not a milestone here.
  if pg_temp.fill_pushes(v_small_event_id, 'event_fill_25') <> 0 then
    raise exception 'FAIL: a small session announced a quarter';
  end if;

  -- Member B takes 1 -> 2/4 = 50%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(p_event_id => v_small_event_id);
  if pg_temp.fill_pushes(v_small_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: a small session did not announce its half';
  end if;

  -- Member C takes 2 -> 4/4 = 100%, passing 75% without announcing it.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(
    p_event_id => v_small_event_id,
    p_guest_names => array['ص1']
  );
  if pg_temp.fill_pushes(v_small_event_id, 'event_full') <> 1 then
    raise exception 'FAIL: a small session did not announce being full';
  end if;
  if pg_temp.fill_pushes(v_small_event_id, 'event_fill_75') <> 0 then
    raise exception 'FAIL: a small session announced three quarters';
  end if;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql
```

Expected: `ERROR: FAIL: a small session announced a quarter` — the owner's single seat is 25% of four.

- [ ] **Step 3: Make the threshold set depend on capacity**

In the migration, replace this line:

```sql
    v_thresholds := array[25, 50, 75, 100];
```

with:

```sql
    -- Quarters only where a quarter means something. On a four-a-side game
    -- that would be a notification per player, so small sessions get halves.
    v_thresholds := case
      when v_event.max_participants >= 8 then array[25, 50, 75, 100]
      else array[50, 100]
    end;
```

- [ ] **Step 4: Re-apply and run the test**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260827110000_event_fill_notifications.sql
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql
```

Expected: `NOTICE: ALL FILL NOTIFICATION TESTS PASSED`, then `ROLLBACK`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260827110000_event_fill_notifications.sql supabase/tests/event_fill_notifications_test.sql
git commit -m "feat(events): halve the milestones on sessions under eight seats"
```

---

### Task 3: Stay silent when the owner filled the seats themselves

**Files:**
- Modify: `supabase/migrations/20260827110000_event_fill_notifications.sql` (guard the `push_outbox` insert)
- Modify: `supabase/tests/event_fill_notifications_test.sql` (append a case before `raise notice`)

**Interfaces:**
- Consumes: `announce_event_fill()` from Tasks 1–2.
- Produces: no new names. `fill_notified_pct` still advances on an owner-caused crossing; only the push is skipped.

- [ ] **Step 1: Write the failing test**

Add `v_owner_event_id uuid;` to the `declare` block, and insert this immediately **before** the `raise notice` line:

```sql
  -- ---------------------------------------------------------------------
  -- An organizer adding players by hand does not need their own taps
  -- announced back to them. The milestone is spent all the same, so it
  -- cannot fire later for someone else's join.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين المشرف',
    p_start_date => now() + interval '8 days',
    p_max_participants => 8
  );
  v_owner_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_owner_event_id);

  -- Owner holds 1 and adds 3 by hand -> 4/8 = 50%.
  v_result := public.add_manual_participant(v_owner_event_id, 'يدوي 1');
  v_result := public.add_manual_participant(v_owner_event_id, 'يدوي 2');
  v_result := public.add_manual_participant(v_owner_event_id, 'يدوي 3');

  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_50') <> 0 then
    raise exception 'FAIL: the owner was told about their own additions';
  end if;

  select fill_notified_pct into v_mark from public.events
  where id = v_owner_event_id;
  if v_mark <> 50 then
    raise exception 'FAIL: an owner-caused crossing left the mark at %', v_mark;
  end if;

  -- Member B takes 1 -> 5/8 = 62%: still inside the spent half, silent.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(p_event_id => v_owner_event_id);
  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_50') <> 0 then
    raise exception 'FAIL: a spent milestone fired for a later join';
  end if;

  -- Member C takes 1 -> 6/8 = 75%: a fresh milestone, and not owner-caused.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(p_event_id => v_owner_event_id);
  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_75') <> 1 then
    raise exception 'FAIL: three quarters not announced after an owner fill';
  end if;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql
```

Expected: `ERROR: FAIL: the owner was told about their own additions`.

- [ ] **Step 3: Guard the insert**

In the migration, replace these four lines:

```sql
    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, v_type, v_event.id);
```

with:

```sql
    -- The update above runs unconditionally: an organizer who fills their own
    -- session spends the milestone, so it cannot arrive later attached to
    -- somebody else's join, reporting news they already acted on.
    if v_uid is distinct from v_event.creator_id then
      insert into public.push_outbox (user_id, type, event_id)
      values (v_event.creator_id, v_type, v_event.id);
    end if;
```

- [ ] **Step 4: Re-apply and run the test**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260827110000_event_fill_notifications.sql
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql
```

Expected: `NOTICE: ALL FILL NOTIFICATION TESTS PASSED`, then `ROLLBACK`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260827110000_event_fill_notifications.sql supabase/tests/event_fill_notifications_test.sql
git commit -m "feat(events): keep fill milestones silent when the owner caused them"
```

---

### Task 4: The Arabic wording

The database enqueues four type names; nothing renders them yet, so `send-push` currently fails these rows with `no copy for type ...`.

**Files:**
- Modify: `supabase/functions/send-push/copy.ts`
- Modify: `supabase/functions/send-push/copy_test.ts`

**Interfaces:**
- Consumes: the four type strings enqueued in Tasks 1–3: `event_fill_25`, `event_fill_50`, `event_fill_75`, `event_full`.
- Produces: `copyFor()` returns `{title, body}` for each of those four instead of `null`.

- [ ] **Step 1: Write the failing test**

Append to `supabase/functions/send-push/copy_test.ts`, **above** the existing `"unknown type returns null"` test:

```typescript
Deno.test("event_fill_25 copy interpolates the event name", () => {
  const c = copyFor("event_fill_25", "تمرين الخميس");
  assertEquals(c, {
    title: "التمرين بدأ يمتلئ ⚽",
    body: "ربع مقاعد تمرين الخميس انحجزت",
  });
});

Deno.test("event_fill_50 copy interpolates the event name", () => {
  const c = copyFor("event_fill_50", "تمرين الخميس");
  assertEquals(c, {
    title: "نص العدد اكتمل 🔥",
    body: "نص مقاعد تمرين الخميس انحجزت",
  });
});

Deno.test("event_fill_75 copy interpolates the event name", () => {
  const c = copyFor("event_fill_75", "تمرين الخميس");
  assertEquals(c, {
    title: "٣ أرباع المقاعد راحت ⏳",
    body: "تمرين الخميس قارب يكتمل — باقي ربع المقاعد",
  });
});

Deno.test("event_full copy interpolates the event name", () => {
  const c = copyFor("event_full", "تمرين الخميس");
  assertEquals(c, {
    title: "اكتمل العدد 🎉",
    body: "امتلأت مقاعد تمرين الخميس",
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts
```

Expected: 4 failed, 13 passed — each new test reporting `Values are not equal` with `actual: null`.

- [ ] **Step 3: Add the four cases**

In `supabase/functions/send-push/copy.ts`, add these immediately **after** the `case "event_invited":` block and **before** the first `case "waitlist_promoted":`:

```typescript
    case "event_fill_25":
      return {
        title: "التمرين بدأ يمتلئ ⚽",
        body: `ربع مقاعد ${eventName} انحجزت`,
      };
    case "event_fill_50":
      return {
        title: "نص العدد اكتمل 🔥",
        body: `نص مقاعد ${eventName} انحجزت`,
      };
    case "event_fill_75":
      return {
        title: "٣ أرباع المقاعد راحت ⏳",
        body: `${eventName} قارب يكتمل — باقي ربع المقاعد`,
      };
    case "event_full":
      return {
        title: "اكتمل العدد 🎉",
        body: `امتلأت مقاعد ${eventName}`,
      };
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts
```

Expected: `ok | 17 passed | 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "copy(push): word the fill milestone notifications"
```

---

### Task 5: Whole-suite verification and deployment notes

**Files:**
- Modify: none. This task only runs things and reports.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing.

- [ ] **Step 1: Run every SQL suite**

```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
for t in supabase/tests/*.sql; do
  out=$(psql "$DB" -v ON_ERROR_STOP=1 -f "$t" 2>&1)
  if echo "$out" | grep -q "ERROR"; then echo "FAIL  $(basename $t)"; echo "$out" | grep "ERROR" | head -1
  else echo "pass  $(basename $t)"; fi
done
```

Expected: every suite passes **except** `workspaces_test.sql`, which fails with `FAIL: member submit_payment status free_event`. That failure predates this work — confirm the message matches exactly, and do not fix it here.

- [ ] **Step 2: Run the edge-function tests**

```bash
docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts
```

Expected: `ok | 17 passed | 0 failed`.

- [ ] **Step 3: Confirm the trigger is actually attached**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -tAc "select tgname from pg_trigger where not tgisinternal and tgrelid = 'public.event_participants'::regclass order by tgname;"
```

Expected three rows, including `trg_announce_event_fill`.

- [ ] **Step 4: Report deployment requirements to the user**

State plainly, and do not perform any of it:

- The migration must reach sandbox before the feature does anything. `send-push` **does** need redeploying this time, because `copy.ts` changed — unlike the guest fix, where it did not.
- There are **no iOS changes**, so no new build is needed for this feature.
- Production is still on the `20260807110000`-era schema; this migration belongs in the same release batch as the rest of the guest sprint, not on its own.

- [ ] **Step 5: Push the branch and open a PR against `staging`**

```bash
git push -u origin feat/event-fill-notifications
gh pr create --base staging --head feat/event-fill-notifications --title "feat(events): tell the owner as their session fills" --body "See docs/superpowers/specs/2026-08-27-event-fill-notifications-design.md"
```

Do not merge. Wait for review.
