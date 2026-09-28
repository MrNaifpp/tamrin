# Registration Pushes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every registration pushes the organizer once per tap, naming the player, and fill milestones reach the whole group.

**Architecture:** The existing deferred trigger `announce_event_fill()` on `event_participants` is rewritten. It finds the tap's seats through a new `registration_announced` flag, marks them, and queues rows in `push_outbox`, which gains `actor_id`, `guest_count` and `fill_pct`. The `send-push` Edge Function reads those fields and builds the Arabic text in `copy.ts`.

**Tech Stack:** Postgres (Supabase) plpgsql migrations and SQL test suites, a Deno Edge Function (`supabase/functions/send-push`), and Deno tests run through Docker.

**Spec:** `docs/superpowers/specs/2026-09-28-registration-pushes-design.md`

## Global Constraints

- Work in worktree `/Users/naifalialshahrani/Documents/tamrin-registration-pushes`, branch `feat/registration-pushes`, off `origin/staging`. Never touch `feat/moyasar-payments` or `fix/registration-without-payment-method`.
- Never commit `Sirr.xcodeproj/project.pbxproj`. This plan changes no app code.
- No em dashes (—) in any push copy (rule at the top of `copy.ts`).
- Numbers in push copy use Arabic-Indic digits (٠١٢٣٤٥٦٧٨٩).
- Milestone thresholds and the "once, ever" rule are unchanged: quarters `[25,50,75,100]` for `max_participants >= 8`, `[50,100]` below that, and `fill_notified_pct` never decreases.
- Local DB: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`. `supabase db reset` is broken on this machine, so rebuild with the script in Task 1 Step 1.
- Two suites fail before this work and are not regressions: `update_exercise_template_test.sql` ("A payment method is required…") and `workspaces_test.sql` ("Event has ended").
- Deno runs only through Docker. `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"` first, or pulls fail on the credential helper.
- Deploy order on every project: **`send-push` first, then the migration.**
- Deploying to sandbox or prod is outward-facing. Stop and get Naif's explicit yes before each.

---

### Task 1: Database: flag, queue columns, rewritten trigger

**Files:**
- Create: `supabase/migrations/20260928110000_registration_pushes.sql`
- Create: `supabase/tests/registration_pushes_test.sql`
- Modify: `supabase/tests/event_fill_notifications_test.sql` (header comment, the `fill_pushes` comment, a new `owner_pushes` helper, and the owner block's two assertions)

**Interfaces:**
- Produces: `push_outbox.actor_id uuid`, `push_outbox.guest_count smallint`, and `push_outbox.fill_pct smallint`.
- Produces: push types `member_registered` (the actor took their own seat, with `guest_count` guests alongside) and `member_added_guests` (guests only, `guest_count` ≥ 1). Both go to `events.creator_id`. `fill_pct` is the milestone the tap crossed, or null.
- Produces: group milestone rows use the existing types `event_fill_25`, `event_fill_50`, `event_fill_75` and `event_full`, with the new columns null.

- [ ] **Step 1: Rebuild the local database from this branch**

Save this as a scratch script (not in the repo) and run it from the worktree root:

```bash
cat > /tmp/claude-501/rebuild_db.sh <<'EOF'
#!/bin/zsh
# usage: rebuild_db.sh <repo-root>
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -q -v ON_ERROR_STOP=1 <<SQL
drop schema public cascade; create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
truncate auth.users cascade;
delete from supabase_migrations.schema_migrations;
SQL
for f in $1/supabase/migrations/*.sql; do
  [[ $f == *avatar_storage* ]] && continue
  psql "$DB" -q -v ON_ERROR_STOP=1 -f $f >/dev/null 2>/tmp/claude-501/rebuild_err || { echo "FAILED at $f"; cat /tmp/claude-501/rebuild_err; exit 1; }
done
echo "rebuilt"
EOF
chmod +x /tmp/claude-501/rebuild_db.sh
/tmp/claude-501/rebuild_db.sh "$PWD" 2>&1 | tail -1
```

Expected: `rebuilt`

- [ ] **Step 2: Write the failing test `supabase/tests/registration_pushes_test.sql`**

```sql
-- Registration pushes to the organizer, fill milestones to the group.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/registration_pushes_test.sql

begin;

-- trg_announce_event_fill is deferred to commit and this suite never commits:
-- `set constraints all immediate` after each tap is what makes it run.

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

-- Pushes of one type for one event, to one recipient.
create or replace function pg_temp.pushes(p_event_id uuid, p_user_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id and user_id = p_user_id and type = p_type;
$$;

-- Every push this feature can produce for one event, to anyone.
create or replace function pg_temp.feature_pushes(p_event_id uuid)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id
    and (type in ('member_registered', 'member_added_guests', 'event_full')
         or type like 'event_fill_%');
$$;

insert into auth.users (id, email) values
  ('47000000-0000-0000-0000-000000000001', 'reg-owner@test.local'),
  ('47000000-0000-0000-0000-000000000002', 'reg-a@test.local'),
  ('47000000-0000-0000-0000-000000000003', 'reg-b@test.local'),
  ('47000000-0000-0000-0000-000000000004', 'reg-c@test.local');

insert into public.users (user_id, name) values
  ('47000000-0000-0000-0000-000000000001', 'منظم التسجيلات'),
  ('47000000-0000-0000-0000-000000000002', 'فهد'),
  ('47000000-0000-0000-0000-000000000003', 'سالم'),
  ('47000000-0000-0000-0000-000000000004', 'ناصر');

do $$
declare
  O constant uuid := '47000000-0000-0000-0000-000000000001';
  A constant uuid := '47000000-0000-0000-0000-000000000002';
  B constant uuid := '47000000-0000-0000-0000-000000000003';
  C constant uuid := '47000000-0000-0000-0000-000000000004';
  v_workspace_id uuid;
  v_e1 uuid;
  v_e2 uuid;
  v_e3 uuid;
  v_e4 uuid;
  v_e5 uuid;
  v_row public.push_outbox;
  v_result json;
  v_count int;
  v_before int;
begin
  perform pg_temp.set_auth(O);
  v_workspace_id := (public.create_workspace('مجموعة التسجيلات')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, A), (v_workspace_id, B), (v_workspace_id, C);

  -- -------------------------------------------------------------------
  -- E1: 16 seats. The owner's own seat from create_event is one of them.
  -- -------------------------------------------------------------------
  v_e1 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين الخميس',
    p_start_date => now() + interval '3 days',
    p_max_participants => 16
  )->>'id')::uuid;
  set constraints all immediate;

  if pg_temp.feature_pushes(v_e1) <> 0 then
    raise exception 'FAIL: the owner''s own seat was announced';
  end if;

  -- 1. A registers alone -> 2/16. One push to the owner, no milestone.
  perform pg_temp.set_auth(A);
  v_result := public.register_event_seat(p_event_id => v_e1);
  set constraints all immediate;

  select * into v_row from public.push_outbox
  where event_id = v_e1 and type = 'member_registered';
  if pg_temp.feature_pushes(v_e1) <> 1
     or v_row.user_id <> O
     or v_row.actor_id <> A
     or v_row.guest_count <> 0
     or v_row.fill_pct is not null then
    raise exception 'FAIL: lone registration pushed %', row_to_json(v_row);
  end if;

  -- 2. B registers with 2 guests -> 5/16 = 31%, crossing 25%.
  --    The owner gets ONE combined push, the group gets the milestone.
  perform pg_temp.set_auth(B);
  v_result := public.register_event_seat(
    p_event_id => v_e1,
    p_guest_names => array['ضيف سالم ١', 'ضيف سالم ٢']
  );
  set constraints all immediate;

  select count(*) into v_count from public.push_outbox
  where event_id = v_e1 and actor_id = B;
  if v_count <> 1 then
    raise exception 'FAIL: one tap with guests queued % organizer pushes', v_count;
  end if;
  select * into v_row from public.push_outbox
  where event_id = v_e1 and actor_id = B;
  if v_row.type <> 'member_registered'
     or v_row.user_id <> O
     or v_row.guest_count <> 2
     or v_row.fill_pct <> 25 then
    raise exception 'FAIL: combined push was %', row_to_json(v_row);
  end if;
  if pg_temp.pushes(v_e1, O, 'event_fill_25') <> 0 then
    raise exception 'FAIL: the owner got the milestone twice';
  end if;
  if pg_temp.pushes(v_e1, A, 'event_fill_25') <> 1
     or pg_temp.pushes(v_e1, C, 'event_fill_25') <> 1 then
    raise exception 'FAIL: the group was not told about 25%%';
  end if;
  if pg_temp.pushes(v_e1, B, 'event_fill_25') <> 0 then
    raise exception 'FAIL: the player who crossed 25%% was told about it';
  end if;

  -- 3. A, already seated, adds one guest -> 6/16. Reads as guests only.
  perform pg_temp.set_auth(A);
  v_result := public.register_event_guests(
    p_event_id => v_e1,
    p_guest_names => array['ضيف فهد']
  );
  set constraints all immediate;

  select * into v_row from public.push_outbox
  where event_id = v_e1 and type = 'member_added_guests';
  if pg_temp.pushes(v_e1, O, 'member_added_guests') <> 1
     or v_row.actor_id <> A
     or v_row.guest_count <> 1
     or v_row.fill_pct is not null then
    raise exception 'FAIL: guests-only push was %', row_to_json(v_row);
  end if;
  if pg_temp.pushes(v_e1, O, 'member_registered') <> 2 then
    raise exception 'FAIL: adding guests re-announced the member''s own seat';
  end if;

  -- -------------------------------------------------------------------
  -- 5. E2: the owner fills by hand to 4/8 = 50%. Nothing to the owner,
  --    the whole group hears it.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e2 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين المشرف',
    p_start_date => now() + interval '4 days',
    p_max_participants => 8
  )->>'id')::uuid;
  v_result := public.add_manual_participant(v_e2, 'يدوي ١');
  v_result := public.add_manual_participant(v_e2, 'يدوي ٢');
  v_result := public.add_manual_participant(v_e2, 'يدوي ٣');
  set constraints all immediate;

  if pg_temp.pushes(v_e2, O, 'event_fill_50') <> 0
     or pg_temp.pushes(v_e2, O, 'member_registered') <> 0
     or pg_temp.pushes(v_e2, O, 'member_added_guests') <> 0 then
    raise exception 'FAIL: the owner was told about their own additions';
  end if;
  if pg_temp.pushes(v_e2, A, 'event_fill_50') <> 1
     or pg_temp.pushes(v_e2, B, 'event_fill_50') <> 1
     or pg_temp.pushes(v_e2, C, 'event_fill_50') <> 1 then
    raise exception 'FAIL: the group missed a milestone the owner caused';
  end if;

  -- -------------------------------------------------------------------
  -- 6. E3: 2 seats. A fills it, then B joins the waitlist: no push.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e3 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين صغير',
    p_start_date => now() + interval '5 days',
    p_max_participants => 2
  )->>'id')::uuid;
  set constraints all immediate;

  perform pg_temp.set_auth(A);
  v_result := public.register_event_seat(p_event_id => v_e3);
  set constraints all immediate;

  select * into v_row from public.push_outbox
  where event_id = v_e3 and type = 'member_registered';
  if v_row.fill_pct is distinct from 100 then
    raise exception 'FAIL: filling the last seat pushed %', row_to_json(v_row);
  end if;

  v_before := pg_temp.feature_pushes(v_e3);
  perform pg_temp.set_auth(B);
  v_result := public.register_event_seat(p_event_id => v_e3);
  if v_result->>'status' <> 'waitlisted' then
    raise exception 'FAIL: expected B on the waitlist, got %', v_result;
  end if;
  set constraints all immediate;

  if pg_temp.feature_pushes(v_e3) <> v_before then
    raise exception 'FAIL: a waitlist join was announced';
  end if;

  -- -------------------------------------------------------------------
  -- 7. E4: no cap. Registrations push, milestones never do.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e4 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين بلا سقف',
    p_start_date => now() + interval '6 days'
  )->>'id')::uuid;

  perform pg_temp.set_auth(A);
  v_result := public.register_event_seat(
    p_event_id => v_e4,
    p_guest_names => array['ضيف ١', 'ضيف ٢', 'ضيف ٣']
  );
  set constraints all immediate;

  if pg_temp.pushes(v_e4, O, 'member_registered') <> 1 then
    raise exception 'FAIL: an uncapped workout did not announce a registration';
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_e4 and (type like 'event_fill_%' or type = 'event_full');
  if v_count <> 0 then
    raise exception 'FAIL: an uncapped workout announced a milestone';
  end if;

  -- -------------------------------------------------------------------
  -- 8. E5: seats inserted by the system (no auth.uid(), like the weekly
  --    roll-over) crossing 50%: the owner alone, as before. Those seats
  --    are marked, so C adding a guest later reads as guests only.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e5 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مُرحّل',
    p_start_date => now() + interval '7 days',
    p_max_participants => 8
  )->>'id')::uuid;
  set constraints all immediate;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  insert into public.event_participants (event_id, user_id, payment_status) values
    (v_e5, A, 'confirmed'),
    (v_e5, B, 'confirmed'),
    (v_e5, C, 'confirmed');
  set constraints all immediate;

  if pg_temp.pushes(v_e5, O, 'event_fill_50') <> 1 then
    raise exception 'FAIL: the owner lost the milestone on a system insert';
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_e5 and user_id <> O;
  if v_count <> 0 then
    raise exception 'FAIL: a system insert announced to the group';
  end if;
  if pg_temp.pushes(v_e5, O, 'member_registered') <> 0 then
    raise exception 'FAIL: a system insert was announced as a registration';
  end if;

  perform pg_temp.set_auth(C);
  v_result := public.register_event_guests(
    p_event_id => v_e5,
    p_guest_names => array['ضيف ناصر']
  );
  set constraints all immediate;

  if pg_temp.pushes(v_e5, O, 'member_added_guests') <> 1
     or pg_temp.pushes(v_e5, O, 'member_registered') <> 0 then
    raise exception 'FAIL: a carried seat was swept into a later tap';
  end if;

  raise notice 'PASS: registration_pushes';
end;
$$;

rollback;
```

- [ ] **Step 3: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/registration_pushes_test.sql 2>&1 | grep -E "ERROR|PASS"`

Expected: `ERROR:` about the missing `actor_id` column (`record "v_row" has no field "actor_id"` or similar). Anything that isn't a missing-column or `FAIL:` error is a setup problem in the test; fix it before going on.

- [ ] **Step 4: Write the migration `supabase/migrations/20260928110000_registration_pushes.sql`**

```sql
-- Every registration tells the organizer, by name, once per tap; fill
-- milestones tell the whole group, not only the organizer.
-- Spec: docs/superpowers/specs/2026-09-28-registration-pushes-design.md
--
-- Still one trigger on event_participants, for the reason
-- 20260827110000_event_fill_notifications gave: eight RPCs insert seats, and
-- a ninth added later must not be able to forget to notify.

alter table public.push_outbox
  add column if not exists actor_id uuid references auth.users(id) on delete set null,
  add column if not exists guest_count smallint,
  add column if not exists fill_pct smallint;

comment on column public.push_outbox.actor_id is
  'Who caused the push, for copy that names them (member_registered, member_added_guests).';
comment on column public.push_outbox.guest_count is
  'Guests the actor added in the tap being announced.';
comment on column public.push_outbox.fill_pct is
  'Fill milestone the tap crossed, appended to the organizer''s registration push.';

-- Seats taken before this migration start as already announced, so the first
-- tap after it does not report them. New seats default to false.
alter table public.event_participants
  add column if not exists registration_announced boolean not null default true;
alter table public.event_participants
  alter column registration_announced set default false;

comment on column public.event_participants.registration_announced is
  'Whether announce_event_fill has already looked at this seat. The first trigger run of a transaction reads the unannounced seats as "this tap" and marks them all.';

comment on column public.events.fill_notified_pct is
  'High-water mark of the fill milestone already announced (organizer and group): 0, 25, 50, 75 or 100. Never decreases, so a withdrawal cannot re-arm a milestone.';

create or replace function public.announce_event_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_self boolean := false;
  v_guests int := 0;
  v_seated int;
  v_pct int;
  v_thresholds int[];
  v_milestone int;
  v_type text;
begin
  select * into v_event
  from public.events
  where id = new.event_id
  for update;

  -- A draft or skipped session tells nobody. Its seats are still marked, so
  -- they cannot surface later inside somebody's next tap.
  if v_event.published_at is null or v_event.cancelled_at is not null then
    update public.event_participants
    set registration_announced = true
    where event_id = v_event.id and not registration_announced;
    return null;
  end if;

  -- What this tap added. The trigger is deferred to commit and the event row
  -- is locked, so the unannounced seats are exactly this transaction's. Only a
  -- member's own tap is announced: the organizer's and the system's are not.
  if v_uid is not null and v_uid is distinct from v_event.creator_id then
    select
      coalesce(bool_or(ep.user_id = v_uid), false),
      count(*) filter (where ep.user_id is null and ep.added_by = v_uid)
    into v_self, v_guests
    from public.event_participants ep
    where ep.event_id = v_event.id
      and not ep.registration_announced
      and ep.payment_status in ('pending', 'confirmed');
  end if;

  -- Every later run in this transaction finds nothing, which is what makes
  -- it one push per tap however many seats the tap inserted.
  update public.event_participants
  set registration_announced = true
  where event_id = v_event.id and not registration_announced;

  -- Milestones, unchanged from 20260827110000. Without a cap there is no
  -- percentage, but there are still registrations.
  if v_event.max_participants is not null then
    select count(*) into v_seated
    from public.event_participants ep
    where ep.event_id = v_event.id
      and ep.payment_status in ('pending', 'confirmed');

    v_pct := (v_seated * 100) / v_event.max_participants;

    v_thresholds := case
      when v_event.max_participants >= 8 then array[25, 50, 75, 100]
      else array[50, 100]
    end;

    select max(t) into v_milestone
    from unnest(v_thresholds) as t
    where t <= v_pct and t > v_event.fill_notified_pct;

    if v_milestone is not null then
      update public.events
      set fill_notified_pct = v_milestone
      where id = v_event.id;

      v_type := case v_milestone
        when 100 then 'event_full'
        else 'event_fill_' || v_milestone::text
      end;
    end if;
  end if;

  -- The organizer: one push per tap, carrying the milestone when it crossed
  -- one. Never for the organizer's own taps, which spend the milestone
  -- silently as before.
  if v_uid is distinct from v_event.creator_id then
    if v_self then
      insert into public.push_outbox
        (user_id, type, event_id, actor_id, guest_count, fill_pct)
      values
        (v_event.creator_id, 'member_registered', v_event.id,
         v_uid, v_guests, v_milestone);
    elsif v_guests > 0 then
      insert into public.push_outbox
        (user_id, type, event_id, actor_id, guest_count, fill_pct)
      values
        (v_event.creator_id, 'member_added_guests', v_event.id,
         v_uid, v_guests, v_milestone);
    elsif v_milestone is not null then
      insert into public.push_outbox (user_id, type, event_id)
      values (v_event.creator_id, v_type, v_event.id);
    end if;
  end if;

  -- The group: everyone but the person who crossed it and the organizer, who
  -- already heard above. A system insert (the weekly roll-over carrying
  -- seats) has no one who crossed it and tells only the organizer.
  if v_milestone is not null and v_uid is not null then
    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, v_type, v_event.id
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id is distinct from v_uid
      and wm.user_id is distinct from v_event.creator_id;
  end if;

  return null;
end;
$$;

revoke execute on function public.announce_event_fill()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
```

- [ ] **Step 5: Apply it and run the new test**

```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -q -v ON_ERROR_STOP=1 -f supabase/migrations/20260928110000_registration_pushes.sql && echo applied
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/registration_pushes_test.sql 2>&1 | grep -E "ERROR|PASS"
```

Expected: `applied`, then `NOTICE:  PASS: registration_pushes`

- [ ] **Step 6: Run the existing fill suite and see its owner block fail**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql 2>&1 | grep -E "ERROR|PASSED"`

Expected: `ERROR:  FAIL: the owner was told about their own additions`. The suite's `fill_pushes` counts every recipient, and the group now gets the owner-caused 50%.

- [ ] **Step 7: Update `supabase/tests/event_fill_notifications_test.sql`**

Replace the first line:

```sql
-- Fill milestone notifications to the event owner. Local stack only:
```

with:

```sql
-- Fill milestone notifications. Since 20260928110000 the group hears them
-- too, so owner-specific assertions use owner_pushes. Local stack only:
```

Replace the helper block:

```sql
-- Counts owner-bound pushes of one type for one event.
create or replace function pg_temp.fill_pushes(p_event_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id and type = p_type;
$$;
```

with:

```sql
-- Counts pushes of one type for one event, to anyone.
create or replace function pg_temp.fill_pushes(p_event_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id and type = p_type;
$$;

-- Counts pushes of one type for one event, to its owner only.
create or replace function pg_temp.owner_pushes(p_event_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int
  from public.push_outbox o
  join public.events e on e.id = o.event_id
  where o.event_id = p_event_id
    and o.type = p_type
    and o.user_id = e.creator_id;
$$;
```

In the owner block, replace:

```sql
  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_50') <> 0 then
    raise exception 'FAIL: the owner was told about their own additions';
  end if;
```

with:

```sql
  if pg_temp.owner_pushes(v_owner_event_id, 'event_fill_50') <> 0 then
    raise exception 'FAIL: the owner was told about their own additions';
  end if;
  -- The group still hears it: members B and C.
  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_50') <> 2 then
    raise exception 'FAIL: the group missed an owner-caused half';
  end if;
```

and replace:

```sql
  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_50') <> 0 then
    raise exception 'FAIL: a spent milestone fired for a later join';
  end if;
```

with:

```sql
  if pg_temp.fill_pushes(v_owner_event_id, 'event_fill_50') <> 2 then
    raise exception 'FAIL: a spent milestone fired for a later join';
  end if;
```

- [ ] **Step 8: Run the fill suite again**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql 2>&1 | grep -E "ERROR|PASSED"`

Expected: `NOTICE:  ALL FILL NOTIFICATION TESTS PASSED`

- [ ] **Step 9: Rebuild from scratch and run every suite**

```bash
/tmp/claude-501/rebuild_db.sh "$PWD" 2>&1 | tail -1
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
for t in supabase/tests/*.sql; do
  out=$(psql "$DB" -v ON_ERROR_STOP=1 -f $t 2>&1)
  if echo "$out" | grep -q "ERROR"; then echo "FAIL $(basename $t): $(echo "$out" | grep ERROR | head -1 | cut -c1-150)"; else echo "ok   $(basename $t)"; fi
done
```

Expected: `rebuilt`, then every suite `ok` except the two already-failing ones: `update_exercise_template_test.sql` (payment method required) and `workspaces_test.sql` (Event has ended).

- [ ] **Step 10: Commit**

```bash
git add supabase/migrations/20260928110000_registration_pushes.sql \
        supabase/tests/registration_pushes_test.sql \
        supabase/tests/event_fill_notifications_test.sql
git commit -m "feat(push): announce each registration to the organizer, milestones to the group"
```

---

### Task 2: Copy: `member_registered` and `member_added_guests`

**Files:**
- Modify: `supabase/functions/send-push/copy.ts`
- Test: `supabase/functions/send-push/copy_test.ts` (append)

**Interfaces:**
- Consumes: the push types and columns from Task 1.
- Produces: `export type CopyDetails = { actorName?: string | null; guestCount?: number | null; fillPct?: number | null }`, and `copyFor(type: string, eventName: string, details: CopyDetails = {}): { title: string; body: string } | null`. Existing two-argument calls are unchanged.

- [ ] **Step 1: Append the failing tests to `copy_test.ts`**

```ts
Deno.test("member_registered alone names the player", () => {
  assertEquals(
    copyFor("member_registered", "تمرين الخميس", { actorName: "فهد", guestCount: 0 }),
    { title: "تسجيل جديد ⚽", body: "فهد سجّل في تمرين الخميس" },
  );
});

Deno.test("member_registered with guests counts them in Arabic", () => {
  const body = (n: number) =>
    copyFor("member_registered", "تمرين الخميس", { actorName: "فهد", guestCount: n })!.body;
  assertEquals(body(1), "فهد سجّل ومعه ضيف في تمرين الخميس");
  assertEquals(body(2), "فهد سجّل ومعه ضيفين في تمرين الخميس");
  assertEquals(body(3), "فهد سجّل ومعه ٣ ضيوف في تمرين الخميس");
  assertEquals(body(10), "فهد سجّل ومعه ١٠ ضيوف في تمرين الخميس");
  assertEquals(body(11), "فهد سجّل ومعه ١١ ضيف في تمرين الخميس");
});

Deno.test("member_added_guests reads as guests only", () => {
  assertEquals(
    copyFor("member_added_guests", "تمرين الخميس", { actorName: "فهد", guestCount: 2 }),
    { title: "تسجيل جديد ⚽", body: "فهد سجّل ضيفين في تمرين الخميس" },
  );
});

Deno.test("a crossed milestone is appended to the registration", () => {
  const body = (pct: number) =>
    copyFor("member_registered", "تمرين الخميس", {
      actorName: "فهد",
      guestCount: 0,
      fillPct: pct,
    })!.body;
  assertEquals(body(25), "فهد سجّل في تمرين الخميس. ربع المقاعد انحجزت");
  assertEquals(body(50), "فهد سجّل في تمرين الخميس. نص المقاعد انحجزت 🔥");
  assertEquals(body(75), "فهد سجّل في تمرين الخميس. باقي ربع المقاعد ⏳");
  assertEquals(body(100), "فهد سجّل في تمرين الخميس واكتمل العدد 🎉");
});

Deno.test("a missing name falls back to لاعب", () => {
  for (const actorName of [null, undefined, "", "   "]) {
    assertEquals(
      copyFor("member_registered", "تمرين الخميس", { actorName, guestCount: 0 })!.body,
      "لاعب سجّل في تمرين الخميس",
    );
  }
});

Deno.test("existing types ignore the details argument", () => {
  assertEquals(
    copyFor("event_fill_50", "تمرين الخميس", { actorName: "فهد", fillPct: 50 }),
    copyFor("event_fill_50", "تمرين الخميس"),
  );
});

Deno.test("registration copy has no em dash", () => {
  const all = [
    copyFor("member_registered", "x", { actorName: "فهد", guestCount: 3, fillPct: 75 })!,
    copyFor("member_added_guests", "x", { actorName: "فهد", guestCount: 12, fillPct: 100 })!,
  ];
  for (const c of all) {
    assertEquals(c.title.includes("—") || c.body.includes("—"), false);
  }
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app/copy_test.ts 2>&1 | tail -15
```

Expected: the new tests FAIL. The TS type check rejects the third argument (`Expected 2 arguments, but got 3`), or `copyFor` returns `null` for the new types.

- [ ] **Step 3: Implement it in `copy.ts`**

Change the signature at the top of `copyFor`:

```ts
export function copyFor(
  type: string,
  eventName: string,
  details: CopyDetails = {},
): { title: string; body: string } | null {
```

Add these two cases directly above `default:`:

```ts
    case "member_registered": {
      const guests = details.guestCount ?? 0;
      const verb = guests > 0 ? `سجّل ومعه ${guestPhrase(guests)}` : "سجّل";
      return {
        title: "تسجيل جديد ⚽",
        body: registrationBody(details, verb, eventName),
      };
    }
    case "member_added_guests":
      return {
        title: "تسجيل جديد ⚽",
        body: registrationBody(
          details,
          `سجّل ${guestPhrase(details.guestCount ?? 1)}`,
          eventName,
        ),
      };
```

Append at the end of the file:

```ts
// What the queue row carries beyond its type, for copy that names who acted.
export type CopyDetails = {
  actorName?: string | null;
  guestCount?: number | null;
  fillPct?: number | null;
};

const ARABIC_DIGITS = "٠١٢٣٤٥٦٧٨٩";
const arabicNumber = (n: number) =>
  String(n).replace(/[0-9]/g, (d) => ARABIC_DIGITS[Number(d)]);

// Arabic counts: one and two have their own words, three to ten take the
// plural, eleven and up take the singular.
function guestPhrase(n: number): string {
  if (n === 1) return "ضيف";
  if (n === 2) return "ضيفين";
  if (n <= 10) return `${arabicNumber(n)} ضيوف`;
  return `${arabicNumber(n)} ضيف`;
}

// Appended to the organizer's registration push when the tap crossed a
// milestone, so one tap is one push.
const FILL_SUFFIX: Record<number, string> = {
  25: ". ربع المقاعد انحجزت",
  50: ". نص المقاعد انحجزت 🔥",
  75: ". باقي ربع المقاعد ⏳",
  100: " واكتمل العدد 🎉",
};

function registrationBody(
  details: CopyDetails,
  verb: string,
  eventName: string,
): string {
  const name = details.actorName?.trim() || "لاعب";
  const suffix = details.fillPct ? FILL_SUFFIX[details.fillPct] ?? "" : "";
  return `${name} ${verb} في ${eventName}${suffix}`;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app/copy_test.ts 2>&1 | tail -5
```

Expected: `ok | 26 passed | 0 failed` (19 existing + 7 new).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(push): copy for member_registered and member_added_guests"
```

---

### Task 3: `send-push` reads the new fields

**Files:**
- Modify: `supabase/functions/send-push/index.ts` (step 2's select, and new step 4b before `// 5. Copy.`)

**Interfaces:**
- Consumes: `CopyDetails` and the three-argument `copyFor` from Task 2, and the `push_outbox` columns from Task 1.
- Produces: nothing new. The function's HTTP contract (`{ outbox_id }` in, `{ ok }` out) is unchanged.

- [ ] **Step 1: Read the whole row**

Replace:

```ts
    .select("id, user_id, type, event_id")
```

with:

```ts
    // The whole row, not named columns: this runs both before and after a
    // migration adds optional fields, and must work on either side of it.
    .select("*")
```

- [ ] **Step 2: Look up the actor and pass the details**

Replace:

```ts
  // 5. Copy.
  const copy = copyFor(row.type, eventName);
```

with:

```ts
  // 4b. Who acted, for copy that names them.
  let actorName: string | null = null;
  if (row.actor_id) {
    const { data: actor } = await admin
      .from("users").select("name").eq("user_id", row.actor_id).single();
    actorName = actor?.name ?? null;
  }

  // 5. Copy.
  const copy = copyFor(row.type, eventName, {
    actorName,
    guestCount: row.guest_count ?? null,
    fillPct: row.fill_pct ?? null,
  });
```

- [ ] **Step 3: Type-check the function**

```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine check /app/index.ts 2>&1 | tail -5
```

Expected: `Check file:///app/index.ts` with no errors. Downloading the `esm.sh` import on first run is normal.

- [ ] **Step 4: Run the copy tests once more**

Same command as Task 2 Step 4. Expected: `26 passed | 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/index.ts
git commit -m "feat(push): send-push names the actor on registration pushes"
```

---

### Task 4: PR, then sandbox, then prod

**Files:** none changed. This task is about pushing, deploying and verifying.

**Interfaces:**
- Consumes: Tasks 1–3 committed on `feat/registration-pushes`.

- [ ] **Step 1: Pull, push and open the PR into `staging`**

```bash
git fetch origin && git rebase origin/staging
git push -u origin feat/registration-pushes
gh pr create --base staging --head feat/registration-pushes \
  --title "feat(push): registration pushes to the organizer, milestones to the group" \
  --body "Spec: docs/superpowers/specs/2026-09-28-registration-pushes-design.md. Plan: docs/superpowers/plans/2026-09-28-registration-pushes.md. Deploy send-push before the migration on each project."
```

Then call `mcp__ccd_pr__get_status`, and `mcp__ccd_pr__bind_pr` if the PR isn't bound.

- [ ] **Step 2: STOP and ask Naif before deploying to the sandbox**

- [ ] **Step 3: Sandbox: deploy `send-push` from a temporary merge with the payment branch**

The sandbox's `send-push` carries `payment_paid` and `refund_issued` from `feat/moyasar-payments`. Deploying this branch's copy alone would drop them.

```bash
git worktree add /tmp/claude-501/push-deploy feat/moyasar-payments --detach
cd /tmp/claude-501/push-deploy
git merge --no-commit --no-ff feat/registration-pushes 2>&1 | tail -2
git diff --cached --stat -- supabase/functions/send-push
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app/copy_test.ts 2>&1 | tail -3
supabase functions deploy send-push --project-ref kpcdinxusxycenfnitjc
cd - && git worktree remove --force /tmp/claude-501/push-deploy
```

Expected: the merge touches only `send-push` files, the copy tests pass with both branches' cases, and the deploy prints `Deployed Functions on project kpcdinxusxycenfnitjc: send-push`. If the merge conflicts in `copy.ts`, keep both sides' cases.

- [ ] **Step 4: Sandbox: apply the migration**

Paste `supabase/migrations/20260928110000_registration_pushes.sql` into the sandbox SQL editor and run it. Then record it, so the history matches what ran:

```sql
insert into supabase_migrations.schema_migrations (version, name)
values ('20260928110000', 'registration_pushes')
on conflict do nothing;
```

Verify that the body really changed. The 2026-09-28 lesson is to trust the function body, not the migration list:

```sql
select position('registration_announced' in prosrc) > 0 as new_body
from pg_proc where proname = 'announce_event_fill';
```

Expected: `new_body = true`

- [ ] **Step 5: Hand over for the device check (sandbox build)**

Naif registers from a second account on a capped sandbox workout, then adds guests. Check that:
- the organizer's phone shows «… سجّل في …», then «… سجّل ضيف في …»,
- a tap crossing a quarter shows one combined push on the organizer's phone,
- other group members get «ربع/نص مقاعد … انحجزت».

Don't boot a simulator. Naif tests on device.

- [ ] **Step 6: STOP and ask Naif before prod**

- [ ] **Step 7: Prod: deploy `send-push` from this branch, then the migration**

Prod has no payment types, so this branch's `send-push` is the right one:

```bash
supabase functions deploy send-push --project-ref hzsxwnmbdkrmipjtfzlp
```

Then paste the migration into the prod SQL editor, run the same `insert into supabase_migrations.schema_migrations …`, and the same `new_body` check. Expected: `true`.
