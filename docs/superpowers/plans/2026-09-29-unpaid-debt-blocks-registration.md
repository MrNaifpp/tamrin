# Unpaid Workout Blocks Registration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member with an unpaid seat on an ended workout cannot register (self, guests, waitlist) in the same group until it is paid; debts no longer expire; the app explains the refusal and opens the unpaid workout.

**Architecture:** One SQL helper, `unpaid_debt_event(workspace, user)`, defines a debt. The registration guard trigger, the live feed and waitlist promotion all call it, in one new migration. The trigger refuses with an Arabic message and `hint = 'payment_owed:<event id>'`. The app turns that hint into a new `RegistrationOutcome.paymentOwed(eventId:)`, which `RegistrationFlowSheet` shows as a step whose «ادفع الآن» asks Home to present the unpaid workout.

**Tech Stack:** Supabase Postgres (plpgsql, triggers), Deno Edge Function (`send-push`), SwiftUI (iOS 26), supabase-swift `PostgrestError`.

**Spec:** `docs/superpowers/specs/2026-09-29-unpaid-debt-blocks-registration-design.md`

## Global Constraints

- New migration file: `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql`. Every task that changes SQL edits this one file; it is not applied anywhere but the local DB until Task 6.
- Refusal message, verbatim: `عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.`
- Refusal hint, verbatim: `payment_owed:` followed by the unpaid event's uuid. Never `detail` (supabase-swift decodes `detail`, PostgREST sends `details`, so it arrives nil).
- Paid-promotion push type: `waitlist_promoted_unpaid`. Body: `انضممت إلى القائمة الرئيسية في {eventName}. لا تنسَ تدفع القطة 💳`. Title: `لاعب اعتذر، أنت في القائمة✨`.
- Sheet copy, verbatim: title «عليك قطة سابقة»; body «ما دفعت قطتك في {اسم التمرين}. ادفعها عشان تقدر تسجّل.» (no name: «ما دفعت قطتك في تمرين سابق. ادفعها عشان تقدر تسجّل.»); note «إذا حوّلت للمنظم مباشرة، اطلب منه يأكد إنه وصلته.»; buttons «ادفع الآن» and «لاحقاً».
- No em dashes in any Arabic copy (house rule in `send-push/copy.ts`).
- Local DB: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`. Never `supabase db reset` (broken). Apply a file with `psql "$DB" -v ON_ERROR_STOP=1 -f <file>`. The new migration is idempotent (`create or replace`, guarded `update`), so re-applying it while iterating is safe. Do NOT re-run any other migration.
- A SQL test passes when it ends in `ROLLBACK` with no `ERROR`. Three suites fail on their own and are not regressions: `workspaces_test.sql`, `update_exercise_template_test.sql`, `event_lineups_test.sql`.
- Deno has no local binary: `docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts` (Docker Desktop must be running; its credential helper must be on PATH, `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"`).
- No simulators. App verification is `xcodebuild -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build`, then Naif tests on his phone.
- Never commit `Sirr.xcodeproj/project.pbxproj`, `Config/*.xcconfig`, `SupabaseEnvironment.swift` or the scheme file (sandbox pin, deliberately uncommitted). Commit only the paths a task names.
- `EventDetailView.swift` and `MockHomeFeed.swift` already carry uncommitted, device-verified work from this session (pay control, «ضيوفك», «وصلتني القطة»). Before the first commit that touches either file (Task 4), ask Naif whether to commit that earlier work first as its own commit.
- Nothing is pushed to the sandbox or production by the implementer. Naif runs `supabase db push` and function deploys.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql` (new) | Helper, guard rule, job stops waiving, one-time cleanup, feed stops hiding, promotion skips debtors |
| `supabase/tests/unpaid_debt_blocks_registration_test.sql` (new) | Every server rule in the spec |
| `supabase/tests/recurring_payment_gate_test.sql` | Hold + "no block" assertions flip |
| `supabase/tests/linger_unpaid_occurrence_test.sql` | "next week hidden" flips to shown |
| `supabase/tests/register_event_guest_only_test.sql` | Removed "Pending guest request" refusal |
| `supabase/tests/merge_guests_and_waitlist_test.sql` | Paid promotion push type |
| `supabase/functions/send-push/copy.ts`, `copy_test.ts` | New push copy |
| `Sirr/core/payment/PaymentOwed.swift` (new) | Reads the refusal out of an `Error` |
| `Sirr/core/supabase/ServerErrorMessage.swift` | Table entry so the message is never replaced by the general apology |
| `Sirr/features/home/MockHomeFeed.swift` | `RegistrationOutcome.paymentOwed`, detection in three feed functions, `requestedOccurrenceID` |
| `Sirr/features/home/EventDetailView.swift` | `RegistrationFlowSheet` step + every `switch` over the outcome |
| `Sirr/features/home/DesignerHomeView.swift` | Presents the requested workout |

---

### Task 1: The debt helper and the registration block

**Files:**
- Create: `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql`
- Create: `supabase/tests/unpaid_debt_blocks_registration_test.sql`
- Modify: `supabase/tests/register_event_guest_only_test.sql` (the two trigger-refusal blocks around lines 471–518)

**Interfaces:**
- Produces: `public.unpaid_debt_event(p_workspace_id uuid, p_user_id uuid) returns uuid` (oldest unpaid ended non-cancelled event in the workspace for that payer, or null; not executable by `anon`/`authenticated`).
- Produces: the guard raises `message` = the refusal message, `hint` = `'payment_owed:' || <event id>`.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/unpaid_debt_blocks_registration_test.sql`:

```sql
-- An unpaid ended workout blocks registering in the same workspace.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql

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

-- Owner, M (owes), S (clean; owes only on a cancelled workout), W (clean waiter),
-- X (holds the only seat of the promotion event).
insert into auth.users (id, email) values
  ('71000000-0000-0000-0000-000000000001', 'debt-owner@test.local'),
  ('71000000-0000-0000-0000-000000000002', 'debt-m@test.local'),
  ('71000000-0000-0000-0000-000000000003', 'debt-s@test.local'),
  ('71000000-0000-0000-0000-000000000004', 'debt-w@test.local'),
  ('71000000-0000-0000-0000-000000000005', 'debt-x@test.local');

insert into public.users (user_id, name) values
  ('71000000-0000-0000-0000-000000000001', 'منظم'),
  ('71000000-0000-0000-0000-000000000002', 'مدين'),
  ('71000000-0000-0000-0000-000000000003', 'سليم'),
  ('71000000-0000-0000-0000-000000000004', 'منتظر'),
  ('71000000-0000-0000-0000-000000000005', 'جالس');

insert into public.workspaces (id, name, owner_id) values
  ('71000000-0000-0000-0000-0000000000a1', 'Debt WS', '71000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-0000000000a2', 'Other WS', '71000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id) values
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000002'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000003'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000004'),
  ('71000000-0000-0000-0000-0000000000a1', '71000000-0000-0000-0000-000000000005'),
  ('71000000-0000-0000-0000-0000000000a2', '71000000-0000-0000-0000-000000000002');

-- Every event starts in the future so the guard accepts the fixture rows,
-- then the old ones are moved into the past below.
--   b1 old paid workout M owes for (self + guest)
--   b2 old cancelled workout S "owes" for
--   b3 next workout in the same workspace (open)
--   b4 workout in the other workspace
--   b5 paid workout with one seat, used for promotion
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at,
   total_price, price_per_person, max_participants)
values
  ('71000000-0000-0000-0000-0000000000b1', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'Old', now() + interval '1 day',
   now() + interval '1 day 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b2', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'Old cancelled', now() + interval '1 day',
   now() + interval '1 day 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b3', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'Next', now() + interval '3 days',
   now() + interval '3 days 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b4', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a2', 'Elsewhere', now() + interval '3 days',
   now() + interval '3 days 2 hours', now(), 100, 50, 10),
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000001',
   '71000000-0000-0000-0000-0000000000a1', 'One seat', now() + interval '3 days',
   now() + interval '3 days 2 hours', now(), 100, 50, 1);

insert into public.event_participants (event_id, user_id, payment_status) values
  ('71000000-0000-0000-0000-0000000000b1', '71000000-0000-0000-0000-000000000002', 'pending'),
  ('71000000-0000-0000-0000-0000000000b1', '71000000-0000-0000-0000-000000000001', 'pending'),
  ('71000000-0000-0000-0000-0000000000b2', '71000000-0000-0000-0000-000000000003', 'pending'),
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000005', 'confirmed');

insert into public.event_participants
  (event_id, user_id, added_by, guest_name, payment_status)
values ('71000000-0000-0000-0000-0000000000b1', null,
        '71000000-0000-0000-0000-000000000002', 'ضيف', 'pending');

-- M queued before W, both before M's debt exists.
insert into public.event_waitlist (event_id, user_id, joined_at) values
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000002', now() - interval '2 minutes'),
  ('71000000-0000-0000-0000-0000000000b5', '71000000-0000-0000-0000-000000000004', now() - interval '1 minute');

update public.events
set start_date = now() - interval '30 hours', end_date = now() - interval '28 hours'
where id = '71000000-0000-0000-0000-0000000000b1';

update public.events
set start_date = now() - interval '30 hours', end_date = now() - interval '28 hours',
    cancelled_at = now() - interval '31 hours'
where id = '71000000-0000-0000-0000-0000000000b2';

do $$
declare
  OWNER constant uuid := '71000000-0000-0000-0000-000000000001';
  M     constant uuid := '71000000-0000-0000-0000-000000000002';
  S     constant uuid := '71000000-0000-0000-0000-000000000003';
  WS    constant uuid := '71000000-0000-0000-0000-0000000000a1';
  OLD   constant uuid := '71000000-0000-0000-0000-0000000000b1';
  NEXT_ constant uuid := '71000000-0000-0000-0000-0000000000b3';
  ELSEWHERE constant uuid := '71000000-0000-0000-0000-0000000000b4';
  v_result json;
  v_hint text;
  v_message text;
  v_blocked boolean;
begin
  -- The helper.
  if public.unpaid_debt_event(WS, M) is distinct from OLD then
    raise exception 'FAIL: helper did not name M''s unpaid workout';
  end if;
  if public.unpaid_debt_event(WS, S) is not null then
    raise exception 'FAIL: a cancelled workout counted as a debt';
  end if;
  if has_function_privilege('authenticated', 'public.unpaid_debt_event(uuid, uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.unpaid_debt_event(uuid, uuid)', 'EXECUTE') then
    raise exception 'FAIL: the helper is callable from the app';
  end if;

  -- Self-registration through the RPC the app uses.
  perform pg_temp.set_auth(M);
  v_blocked := false;
  begin
    v_result := public.register_event_seat(p_event_id => NEXT_);
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_message = message_text;
    v_blocked := v_hint = 'payment_owed:' || OLD::text
      and v_message = 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.';
  end;
  if not v_blocked then
    raise exception 'FAIL: register_event_seat was not refused (hint %, message %)', v_hint, v_message;
  end if;

  -- A guest row, and a waitlist row, hit the same trigger.
  v_blocked := false;
  begin
    insert into public.event_participants (event_id, user_id, added_by, guest_name, payment_status)
    values (NEXT_, null, M, 'ضيف جديد', 'pending');
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_blocked := v_hint = 'payment_owed:' || OLD::text;
  end;
  if not v_blocked then raise exception 'FAIL: adding a guest was not refused'; end if;

  v_blocked := false;
  begin
    insert into public.event_waitlist (event_id, user_id) values (NEXT_, M);
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_blocked := v_hint = 'payment_owed:' || OLD::text;
  end;
  if not v_blocked then raise exception 'FAIL: joining the waitlist was not refused'; end if;

  -- Another workspace is not affected.
  insert into public.event_participants (event_id, user_id, payment_status)
  values (ELSEWHERE, M, 'pending');

  -- A cancelled unpaid workout does not block.
  insert into public.event_participants (event_id, user_id, payment_status)
  values (NEXT_, S, 'pending');

  -- The owner is never blocked in their own workspace, even with an unpaid row,
  -- and a player they add is confirmed.
  insert into public.event_participants (event_id, user_id, payment_status)
  values (NEXT_, OWNER, 'confirmed');
  perform pg_temp.set_auth(OWNER);
  v_result := public.add_manual_participant(NEXT_, 'لاعب المنظم');
  if not exists (
    select 1 from public.event_participants
    where event_id = NEXT_ and guest_name = 'لاعب المنظم' and payment_status = 'confirmed'
  ) then
    raise exception 'FAIL: organizer-added player was not inserted confirmed: %', v_result;
  end if;

  -- A member with an unpaid guest-only batch can still register themselves
  -- (the old "Pending guest request" refusal is gone).
  insert into public.event_participants (event_id, user_id, added_by, guest_name, payment_status, guest_only)
  values ('71000000-0000-0000-0000-0000000000b5', null, S, 'ضيف فقط', 'pending', true);
  insert into public.event_waitlist (event_id, user_id)
  values ('71000000-0000-0000-0000-0000000000b5', S);
  delete from public.event_waitlist
  where event_id = '71000000-0000-0000-0000-0000000000b5' and user_id = S;
  delete from public.event_participants
  where event_id = '71000000-0000-0000-0000-0000000000b5' and added_by = S;

  -- Paying lifts the block at once: the organizer confirms (card settlement
  -- writes the same 'confirmed').
  perform public.confirm_payment(OLD, M, OWNER);
  perform pg_temp.set_auth(M);
  v_result := public.register_event_seat(p_event_id => NEXT_);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: a member who paid could not register: %', v_result;
  end if;
end;
$$;

select 'ALL UNPAID DEBT TESTS PASSED' as result;

rollback;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql`
Expected: `ERROR:  function public.unpaid_debt_event(uuid, uuid) does not exist`

- [ ] **Step 3: Write the migration (helper + guard)**

Create `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql`:

```sql
-- An unpaid workout blocks registering until it is paid.
--
-- Spec: docs/superpowers/specs/2026-09-29-unpaid-debt-blocks-registration-design.md
--
-- 20260830200000 lifted the old registration refusal because it trapped people:
-- the error reached them in English and the unpaid workout was not on their
-- home page, so they could neither pay nor book. Both are answered now. The
-- refusal is Arabic and names the workout in its hint, and the workout stays on
-- home until it is paid, with Apple Pay on it.
--
-- One helper defines a debt, and everything that asks the question calls it,
-- so the block, the feed and the waitlist can never disagree about who owes.

-- ---------------------------------------------------------------------------
-- 1. What a debt is
-- ---------------------------------------------------------------------------
-- An unpaid seat, the member's own or a guest they added, on a workout in this
-- workspace that has ended and was not cancelled. Whether a transfer was ever
-- "declared" does not matter: that flow is retired, a seat is paid or it is not.
create or replace function public.unpaid_debt_event(p_workspace_id uuid, p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select e.id
  from public.event_participants ep
  join public.events e on e.id = ep.event_id
  where e.workspace_id = p_workspace_id
    and e.cancelled_at is null
    and coalesce(e.end_date, e.start_date) < now()
    and ep.payment_status = 'pending'
    and (ep.user_id = p_user_id
      or (ep.user_id is null and ep.added_by = p_user_id))
  order by e.start_date asc, e.id
  limit 1
$$;

revoke execute on function public.unpaid_debt_event(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The block
-- ---------------------------------------------------------------------------
-- Reissued from 20260830200000 with two changes: the debt rule is added, and
-- the "Pending guest request must be resolved before self registration"
-- refusal is removed (a declare-then-confirm leftover; paying covers the member
-- and their guests together). Everything else is verbatim.
create or replace function public.guard_event_registration_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_payer_id uuid;
  v_series_key uuid;
  v_debt_event_id uuid;
begin
  select * into v_event
  from public.events
  where id = new.event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;

  if tg_table_name = 'event_waitlist' then
    if new.user_id is null
       or not public.is_workspace_member(v_event.workspace_id, new.user_id) then
      raise exception 'Not a workspace member';
    end if;
  elsif new.user_id is not null then
    if not public.is_workspace_member(v_event.workspace_id, new.user_id) then
      raise exception 'Not a workspace member';
    end if;
  elsif new.added_by is null
        or not public.is_workspace_member(v_event.workspace_id, new.added_by) then
    raise exception 'A guest must be added by a workspace member';
  end if;

  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  if v_event.template_id is not null then
    select series_key into v_series_key
    from public.event_templates
    where id = v_event.template_id;
    if v_series_key is not null then
      perform pg_advisory_xact_lock(hashtextextended(v_series_key::text, 0));
    end if;
  end if;

  select * into v_event
  from public.events
  where id = new.event_id
  for share;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  if tg_table_name = 'event_participants'
     and new.user_id is not null
     and new.user_id = v_event.creator_id
     and v_event.cancelled_at is null
     and not v_event.registration_locked then
    return new;
  end if;

  if tg_table_name = 'event_waitlist' then
    v_payer_id := new.user_id;
  else
    v_payer_id := coalesce(new.user_id, new.added_by);
  end if;

  -- The organizer is never blocked in their own workspace. This is also what
  -- keeps add_manual_participant working: its rows are added_by the organizer.
  if v_payer_id is not null
     and v_payer_id is distinct from v_event.creator_id
     and not public.is_workspace_owner(v_event.workspace_id, v_payer_id) then
    v_debt_event_id := public.unpaid_debt_event(v_event.workspace_id, v_payer_id);
    if v_debt_event_id is not null then
      raise exception using
        message = 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.',
        hint = 'payment_owed:' || v_debt_event_id::text;
    end if;
  end if;

  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then raise exception 'Registration is closed for this event'; end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Apply it and run the new test**

Run:
```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql
```
Expected: `ALL UNPAID DEBT TESTS PASSED`, then `ROLLBACK`.

If the local DB lacks the payment functions (e.g. `register_event_seat` missing), rebuild the schema per memory `local-supabase-db-workflow` first, then apply every migration in order (skipping `*avatar_storage*`), which includes this one.

- [ ] **Step 5: Update the guest-only suite for the removed refusal**

In `supabase/tests/register_event_guest_only_test.sql`, replace the block that starts with the comment `-- Neither a self seat nor a self waitlist row may start while this payment is` through the `raise exception 'FAIL: failed waitlist insert left a row';` / `end if;` that follows it, with:

```sql
  -- A pending guest-only batch no longer stops the member queueing for
  -- themselves (20260929120000). Probed and rolled back so the fixture below
  -- still sees the member unqueued.
  begin
    v_result := public.join_waitlist(
      v_paid_event_id,
      '45000000-0000-0000-0000-000000000002'
    );
    raise exception 'PROBE_OK';
  exception when others then
    if sqlerrm <> 'PROBE_OK' then
      raise exception 'FAIL: waitlist refused during a guest-only batch: %', sqlerrm;
    end if;
  end;
```

Then replace the `join_event` block (from `v_failed := false;` just before `perform public.join_event(` through `raise exception 'FAIL: legacy join merged with standalone payment';` / `end if;`) with:

```sql
  begin
    perform public.join_event(
      v_paid_event_id,
      '45000000-0000-0000-0000-000000000002'
    );
    raise exception 'PROBE_OK';
  exception when others then
    if sqlerrm <> 'PROBE_OK' then
      raise exception 'FAIL: legacy join refused during a guest-only batch: %', sqlerrm;
    end if;
  end;
```

Leave the `submit_payment_v2` assertion between them unchanged (it returns its own status and is not part of this change).

- [ ] **Step 6: Run the guest suites**

Run:
```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/register_event_guest_only_test.sql
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/register_event_guests_test.sql
```
Expected: both end in `ROLLBACK`, no `ERROR`.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql \
  supabase/tests/unpaid_debt_blocks_registration_test.sql \
  supabase/tests/register_event_guest_only_test.sql
git commit -m "feat(payments): an unpaid ended workout blocks registering in its group"
```

Note: `register_event_guest_only_test.sql` also carries this session's earlier uncommitted edits (the 20260929110000 fix). Ask Naif before committing it, or commit those earlier edits first together with the two `20260929100000`/`20260929110000` migrations.

---

### Task 2: Debts stop expiring; every workout shows

**Files:**
- Modify: `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql` (append)
- Modify: `supabase/tests/unpaid_debt_blocks_registration_test.sql` (add assertions)
- Modify: `supabase/tests/recurring_payment_gate_test.sql:238-481`
- Modify: `supabase/tests/linger_unpaid_occurrence_test.sql:106-112`

**Interfaces:**
- Consumes: `public.unpaid_debt_event` (Task 1).
- Produces: `generate_recurring_events()` no longer waives; `get_workspace_events` never hides a workout over a debt, and its `requires_payment_action` counts any `pending` seat on an ended workout.

- [ ] **Step 1: Add the failing assertions**

In `supabase/tests/unpaid_debt_blocks_registration_test.sql`, insert these lines inside the `do $$` block immediately before the comment `-- Paying lifts the block at once`:

```sql
  -- The job no longer forgives: M's row is 30 hours past its start.
  perform public.generate_recurring_events();
  if (select payment_status from public.event_participants
      where event_id = OLD and user_id = M) <> 'pending' then
    raise exception 'FAIL: the job still waives unpaid seats';
  end if;

  -- A declared-but-unanswered seat still counts (the flow is retired).
  update public.event_participants set payment_declared_at = now()
  where event_id = OLD and user_id = M;
  if public.unpaid_debt_event(WS, M) is distinct from OLD then
    raise exception 'FAIL: a declared unpaid seat stopped counting';
  end if;

  -- The feed shows both the unpaid workout (flagged) and the next one.
  perform pg_temp.set_auth(M);
  if not exists (
    select 1 from json_array_elements(public.get_workspace_events(WS)) i
    where (i->>'id')::uuid = OLD and (i->>'requires_payment_action')::boolean
  ) then
    raise exception 'FAIL: the unpaid workout left the feed or lost its flag';
  end if;
  if not exists (
    select 1 from json_array_elements(public.get_workspace_events(WS)) i
    where (i->>'id')::uuid = NEXT_
  ) then
    raise exception 'FAIL: the next workout was hidden from a member who owes';
  end if;
  perform pg_temp.set_auth(OWNER);
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql`
Expected: `ERROR:  FAIL: the job still waives unpaid seats`

- [ ] **Step 3: Append to the migration**

Add to the end of `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql`, before its final `notify pgrst, 'reload schema';` line (move that line so it stays last):

```sql
-- ---------------------------------------------------------------------------
-- 3. Debts stop expiring
-- ---------------------------------------------------------------------------
-- The per-minute job stops calling waive_expired_event_debts(). The function
-- is left in place, unused: putting the call back is the whole undo.
create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.generate_recurring_events_internal();
end;
$$;

-- Old "I transferred" claims nobody answered were never waived (the waiver
-- skipped declared rows). Under the new rule they would suddenly block people
-- over months-old workouts, so they are forgiven once, like the other old debts.
update public.event_participants ep
set payment_status = 'waived'
from public.events e
where e.id = ep.event_id
  and ep.payment_status = 'pending'
  and ep.payment_declared_at is not null
  and e.cancelled_at is null
  and coalesce(e.end_date, e.start_date) < now();

comment on constraint event_participants_payment_status_check
  on public.event_participants is
  'waived: forgiven by the retired 24h waiver, or by the one-time cleanup in 20260929120000. Nothing writes it now.';

-- ---------------------------------------------------------------------------
-- 4. Every workout is shown
-- ---------------------------------------------------------------------------
-- Reissued from 20260831130000. The clause that hid a series' next occurrence
-- from a member who owed for an earlier one is removed: the refusal now happens
-- at registration. requires_payment_action and the clause that keeps an unpaid
-- ended workout listed drop `payment_declared_at is null`, matching
-- unpaid_debt_event, so the workout that blocks is always the one on home.
CREATE OR REPLACE FUNCTION public.get_workspace_events(p_workspace_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(x) order by x.start_date asc), '[]'::json)
    from (
      select e.*,
             e.published_at is not null as is_published,
             e.cancelled_at is not null as is_cancelled,
             r.status as my_response_status,
             r.status as current_user_response,
             r.reason_code as current_user_reason_code,
             r.reason_text as current_user_reason_text,
             exists (
               select 1
               from public.event_templates event_template
               join public.event_templates active_template
                 on active_template.series_key = event_template.series_key
                and active_template.ended_at is null
               where event_template.id = e.template_id
             ) as is_recurring,
             exists (
               select 1
               from public.event_participants mine
               where mine.event_id = e.id
                 and mine.payment_status = 'pending'
                 and (mine.user_id = v_uid
                   or (mine.user_id is null and mine.added_by = v_uid))
             ) and e.cancelled_at is null
               and coalesce(e.end_date, e.start_date) < now()
               as requires_payment_action
      from public.events e
      left join public.event_member_responses r
        on r.event_id = e.id and r.user_id = v_uid
      where e.workspace_id = p_workspace_id
        and (e.published_at is not null
          or public.is_workspace_owner(e.workspace_id, v_uid))
        and (
          coalesce(e.end_date, e.start_date) >= now()
          or (
            e.cancelled_at is null
            and exists (
              select 1
              from public.event_participants mine
              where mine.event_id = e.id
                and mine.payment_status = 'pending'
                and (mine.user_id = v_uid
                  or (mine.user_id is null and mine.added_by = v_uid))
            )
          )
        )
    ) x
  );
end;
$function$;
```

- [ ] **Step 4: Apply and run the new test**

Run:
```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql
```
Expected: `ALL UNPAID DEBT TESTS PASSED`, `ROLLBACK`.

- [ ] **Step 5: Flip the linger suite**

In `supabase/tests/linger_unpaid_occurrence_test.sql`, replace:

```sql
  if v_shows then
    raise exception 'FAIL: next week showed while the old exercise was still owed';
  end if;
```

with:

```sql
  -- Next week shows while the old one is owed; the refusal is at registration
  -- now (20260929120000), not in the feed.
  if not v_shows then
    raise exception 'FAIL: next week was hidden from a member who owes';
  end if;
```

The rest of that suite (it calls `waive_expired_event_debts()` directly and checks both release) stays valid: the function still waives when called.

- [ ] **Step 6: Rewrite the gate suite's debt section**

In `supabase/tests/recurring_payment_gate_test.sql`, add `v_hint text;` to the `declare` list (after `v_failed boolean;`). Then replace everything from the comment line `-- One card, not two. While the old exercise is still owed for it is the only` through the `end if;` that closes the `FAIL: history lacks settled old occurrence` check (the last statement before `end;` / `$$;`) with:

```sql
  -- Every workout shows. The debt no longer hides the next occurrence; it
  -- refuses the registration instead (20260929120000).
  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_next_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: the next occurrence was hidden from a member who owes: %', v_live;
  end if;

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_other_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: debt hid an unrelated recurring template: %', v_live;
  end if;

  -- Registering is refused while the old occurrence is owed, and the refusal
  -- names it so the app can open it.
  v_failed := false;
  begin
    v_result := public.register_event_seat(p_event_id => v_next_event_id);
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_failed := v_hint = 'payment_owed:' || v_old_event_id::text;
  end;
  if not v_failed then
    raise exception 'FAIL: an unpaid ended occurrence did not block registration (hint %)', v_hint;
  end if;

  -- Ending the occurrence freezes attendance responses.
  v_failed := false;
  begin
    v_result := public.decline_event(v_old_event_id, 'other', 'انتهى الموعد');
  exception when others then
    v_failed := sqlerrm = 'Event has ended';
  end;
  if not v_failed then
    raise exception 'FAIL: member declined an ended occurrence';
  end if;

  v_failed := false;
  begin
    v_result := public.leave_event(v_old_event_id, v_member);
  exception when others then
    v_failed := sqlerrm = 'Event has ended';
  end;
  if not v_failed then
    raise exception 'FAIL: member left an ended occurrence';
  end if;

  perform 1
  from public.event_participants
  where event_id = v_old_event_id
    and user_id = v_member
    and payment_status = 'pending'
    and payment_declared_at is null;
  if not found then
    raise exception 'FAIL: rejected ended action mutated the debt row';
  end if;

  -- The organizer marks it paid; the block lifts at once.
  perform pg_temp.set_auth(v_owner);
  v_result := public.confirm_payment(v_old_event_id, v_member, v_owner);
  if v_result->>'status' <> 'confirmed' then
    raise exception 'FAIL: organizer could not confirm the ended debt: %', v_result;
  end if;

  perform pg_temp.set_auth(v_member);
  v_result := public.register_event_seat(p_event_id => v_next_event_id);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: a settled member could not register: %', v_result;
  end if;

  v_live := public.get_workspace_events(v_workspace_id);
  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_old_event_id;
  if v_count <> 0 then
    raise exception 'FAIL: settled old occurrence remained in live feed: %', v_live;
  end if;

  v_past := public.get_workspace_past_events(
    v_workspace_id,
    now(),
    60,
    0
  );

  select count(*) into v_count
  from json_array_elements(v_past) item
  where (item->>'id')::uuid = v_old_event_id
    and (item->>'requires_payment_action')::boolean is false;
  if v_count <> 1 then
    raise exception 'FAIL: history lacks settled old occurrence: %', v_past;
  end if;
```

Also update the file's header comment line 1 to `-- Recurring-payment gate tests (the block at registration, 20260929120000). Local stack only:`.

- [ ] **Step 7: Run the affected suites**

Run:
```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
for f in recurring_payment_gate_test linger_unpaid_occurrence_test waive_expired_event_debts_test get_my_feed_test unpaid_debt_blocks_registration_test; do
  echo "== $f"; psql "$DB" -v ON_ERROR_STOP=1 -f "supabase/tests/$f.sql" 2>&1 | tail -3
done
```
Expected: each ends in `ROLLBACK` with no `ERROR`.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql \
  supabase/tests/unpaid_debt_blocks_registration_test.sql \
  supabase/tests/recurring_payment_gate_test.sql \
  supabase/tests/linger_unpaid_occurrence_test.sql
git commit -m "feat(payments): debts stop expiring and no workout is hidden over one"
```

---

### Task 3: Waitlist promotion skips debtors and reminds to pay

**Files:**
- Modify: `supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql` (append)
- Modify: `supabase/tests/unpaid_debt_blocks_registration_test.sql` (add assertions)
- Modify: `supabase/tests/merge_guests_and_waitlist_test.sql:105-110`
- Modify: `supabase/functions/send-push/copy.ts` (after the `waitlist_promoted` case)
- Modify: `supabase/functions/send-push/copy_test.ts` (after the `waitlist_promoted` test)

**Interfaces:**
- Consumes: `public.unpaid_debt_event` (Task 1).
- Produces: push type `waitlist_promoted_unpaid` (paid workouts); `copyFor("waitlist_promoted_unpaid", name)`.

- [ ] **Step 1: Add the failing SQL assertions**

In `supabase/tests/unpaid_debt_blocks_registration_test.sql`, add to the `declare` list: `ONE_SEAT constant uuid := '71000000-0000-0000-0000-0000000000b5';`, `X constant uuid := '71000000-0000-0000-0000-000000000005';`, `W constant uuid := '71000000-0000-0000-0000-000000000004';`. Insert immediately before the comment `-- Paying lifts the block at once`:

```sql
  -- X frees the only seat. M is first in the queue but owes, so W gets it, and
  -- X's withdrawal does not fail because of M.
  perform pg_temp.set_auth(X);
  v_result := public.decline_event(ONE_SEAT, null, null);
  if not exists (select 1 from public.event_participants where event_id = ONE_SEAT and user_id = W) then
    raise exception 'FAIL: the seat did not go to the next clean waiter';
  end if;
  if exists (select 1 from public.event_participants where event_id = ONE_SEAT and user_id = M) then
    raise exception 'FAIL: a member who owes was promoted';
  end if;
  if not exists (select 1 from public.event_waitlist where event_id = ONE_SEAT and user_id = M) then
    raise exception 'FAIL: the skipped member lost their place in the queue';
  end if;
  if not exists (
    select 1 from public.push_outbox
    where event_id = ONE_SEAT and user_id = W and type = 'waitlist_promoted_unpaid'
  ) then
    raise exception 'FAIL: a paid promotion did not remind the member to pay';
  end if;
  perform pg_temp.set_auth(OWNER);
```

- [ ] **Step 2: Add the failing copy test**

In `supabase/functions/send-push/copy_test.ts`, after the `waitlist_promoted copy does not need the event name` test, add:

```ts
Deno.test("waitlist_promoted_unpaid copy names the event and asks to pay", () => {
  const c = copyFor("waitlist_promoted_unpaid", "تمرين الخميس");
  assertEquals(c, {
    title: "لاعب اعتذر، أنت في القائمة✨",
    body: "انضممت إلى القائمة الرئيسية في تمرين الخميس. لا تنسَ تدفع القطة 💳",
  });
});
```

- [ ] **Step 3: Run both to verify they fail**

Run:
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_debt_blocks_registration_test.sql
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts
```
Expected: SQL fails inside `decline_event` with the refusal message (promotion tried to seat M, the trigger raised, and X's withdrawal failed). Deno fails `waitlist_promoted_unpaid` (copyFor returns null).

- [ ] **Step 4: Append the promotion change to the migration**

Add before the final `notify pgrst, 'reload schema';`:

```sql
-- ---------------------------------------------------------------------------
-- 5. Promotion skips a member who owes, and reminds the promoted one to pay
-- ---------------------------------------------------------------------------
-- Reissued from 20260822100000. Without the skip, the block above would raise
-- inside drain_waitlist and fail whatever freed the seat, such as another
-- member's withdrawal. A skipped member keeps their place in the queue.
create or replace function public.promote_from_waitlist(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_seats int;
  v_user_id uuid;
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then return null; end if;
  if v_event.registration_locked then return null; end if;
  if v_event.cancelled_at is not null then return null; end if;
  -- An uncapped event has no notion of a seat freeing up.
  if v_event.max_participants is null then return null; end if;

  -- Every live seat counts, paid or not.
  select count(*) into v_seats
  from public.event_participants
  where event_id = p_event_id
    and payment_status in ('pending', 'confirmed');
  if v_seats >= v_event.max_participants then return null; end if;

  select w.user_id into v_user_id
  from public.event_waitlist w
  where w.event_id = p_event_id
    and public.unpaid_debt_event(v_event.workspace_id, w.user_id) is null
  order by w.joined_at asc
  limit 1;
  if v_user_id is null then return null; end if;

  -- A paid event leaves the promoted seat owing; a free one is simply in.
  insert into public.event_participants
    (event_id, user_id, payment_status, paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_user_id,
     case when coalesce(v_event.total_price, 0) > 0 then 'pending' else 'confirmed' end,
     v_event.price_per_person, 1);

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_user_id;

  insert into public.push_outbox (user_id, type, event_id)
  values (
    v_user_id,
    case when coalesce(v_event.total_price, 0) > 0
      then 'waitlist_promoted_unpaid' else 'waitlist_promoted' end,
    p_event_id
  );

  return v_user_id;
end;
$$;
revoke execute on function public.promote_from_waitlist(uuid) from public, anon;
```

- [ ] **Step 5: Add the copy**

In `supabase/functions/send-push/copy.ts`, directly after the `case "waitlist_promoted":` block's closing `};`, add:

```ts
    case "waitlist_promoted_unpaid":
      return {
        title: "لاعب اعتذر، أنت في القائمة✨",
        body: `انضممت إلى القائمة الرئيسية في ${eventName}. لا تنسَ تدفع القطة 💳`,
      };
```

- [ ] **Step 6: Update the merge suite's push assertion**

In `supabase/tests/merge_guests_and_waitlist_test.sql`, the promoted event is paid (`p_total_price => 100`), so change `and type = 'waitlist_promoted'` (line ~107) to `and type = 'waitlist_promoted_unpaid'`.

- [ ] **Step 7: Apply and run**

Run:
```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql
for f in unpaid_debt_blocks_registration_test waitlist_promotion_test merge_guests_and_waitlist_test; do
  echo "== $f"; psql "$DB" -v ON_ERROR_STOP=1 -f "supabase/tests/$f.sql" 2>&1 | tail -3
done
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD":/app -w /app denoland/deno:alpine test --allow-net supabase/functions/send-push/copy_test.ts
```
Expected: all SQL suites end in `ROLLBACK` with no `ERROR` (`waitlist_promotion_test` uses a free event and still expects `waitlist_promoted`); Deno reports all tests `ok`.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260929120000_unpaid_workout_blocks_registration.sql \
  supabase/tests/unpaid_debt_blocks_registration_test.sql \
  supabase/tests/merge_guests_and_waitlist_test.sql \
  supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(payments): promotion skips members who owe and reminds the promoted to pay"
```

---

### Task 4: The app recognises the refusal

**Files:**
- Create: `Sirr/core/payment/PaymentOwed.swift`
- Modify: `Sirr/core/supabase/ServerErrorMessage.swift` (table, first entry)
- Modify: `Sirr/features/home/MockHomeFeed.swift` — `RegistrationOutcome` (~line 1882), `submitRegistration` catch (~line 2398), `addGuests` catch (~line 2605), `joinWaitlist` catch (~line 609)
- Modify: `Sirr/features/home/EventDetailView.swift` — every `switch` over a `RegistrationOutcome` (lines ~1982, 2111, 2130, 2914, 3125, 3159)

**Interfaces:**
- Produces: `enum PaymentOwed { static let hintPrefix: String; static func unpaidEventID(in error: Error) -> UUID? }`.
- Produces: `HomeStore.RegistrationOutcome.paymentOwed(eventId: UUID)`.

- [ ] **Step 1: Create the reader**

`Sirr/core/payment/PaymentOwed.swift`:

```swift
//
//  PaymentOwed.swift
//  Sirr
//
//  The server refuses any registration while an ended workout in the same group
//  is unpaid (guard_event_registration_insert, 20260929120000). It names that
//  workout in the error's hint, not its detail: PostgREST sends `details` and
//  PostgrestError decodes `detail`, so a detail never arrives.
//

import Foundation
import Supabase

enum PaymentOwed {
    static let hintPrefix = "payment_owed:"

    /// The unpaid workout's id when `error` is that refusal, otherwise nil.
    static func unpaidEventID(in error: Error) -> UUID? {
        guard let hint = (error as? PostgrestError)?.hint,
              hint.hasPrefix(hintPrefix) else { return nil }
        return UUID(uuidString: String(hint.dropFirst(hintPrefix.count)))
    }
}
```

The project uses synchronized folder groups (`PBXFileSystemSynchronizedRootGroup`, verified), so a new file under `Sirr/` is compiled without touching `project.pbxproj`. Confirm with `git status` after the build that `project.pbxproj` is unchanged.

- [ ] **Step 2: Keep the message from being swallowed**

In `ServerErrorMessage.swift`, add as the first entry of `table` (before `"Previous event payment is required"`):

```swift
        // Already Arabic, and already says what to do. Listed so nothing on the
        // way to the screen replaces it with the general apology.
        "عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.":
            "عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.",
```

- [ ] **Step 3: Add the outcome case**

In `MockHomeFeed.swift`, inside `enum RegistrationOutcome`, after `case closedAtCapacity`:

```swift
        /// An ended workout in this group is still unpaid, so the server
        /// refused. The sheet offers to open it.
        case paymentOwed(eventId: UUID)
```

- [ ] **Step 4: Map the refusal in the three feed functions**

In `submitRegistration`, replace its `catch` block:

```swift
        } catch {
            await reloadRoster(occurrence.id)
            if let unpaid = PaymentOwed.unpaidEventID(in: error) {
                return .paymentOwed(eventId: unpaid)
            }
            return .failure(error.localizedDescription)
        }
```

In `addGuests`, replace its `catch` block with the same body as above.

In `joinWaitlist`, replace its `catch` block:

```swift
        } catch {
            if let unpaid = PaymentOwed.unpaidEventID(in: error) {
                return .paymentOwed(eventId: unpaid)
            }
            return .failure(error.localizedDescription)
        }
```

- [ ] **Step 5: Build to list every switch that must handle the case**

Run: `xcodebuild -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build 2>&1 | grep -E "error:" | head -20`
Expected: `switch must be exhaustive` errors in `EventDetailView.swift` at the switches listed under Files.

- [ ] **Step 6: Handle the case where it cannot occur**

The organizer-side switches (remove participant ~1982, confirm ~2111, reject ~2130) and `declarePayment` (~3125) never register anyone. In each, extend the existing `case .seatsFullOfferWaitlist, .closedAtCapacity:` arm to `case .seatsFullOfferWaitlist, .closedAtCapacity, .paymentOwed:` — the arm's existing error message stays.

The two registering switches (`joinWaitlist` in `waitlistOfferStep` ~2914, and `submitRegistration()` ~3159) get the real handling in Task 5. For now, add to each:

```swift
                    case .paymentOwed(let eventId):
                        Haptics.error()
                        withAnimation(.smooth(duration: 0.3)) { step = .paymentOwed(eventId) }
```

(`step = .paymentOwed` does not compile until Task 5 Step 1 adds the step. Do Task 5 Step 1 now, then build.)

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build 2>&1 | grep -E "error:|BUILD" | head -20; echo "exit ${pipestatus[1]}"`
Expected: no `error:` lines, `exit 0`.

- [ ] **Step 8: Commit** (after asking Naif about the earlier uncommitted work in these files; see Global Constraints)

```bash
git add Sirr/core/payment/PaymentOwed.swift Sirr/core/supabase/ServerErrorMessage.swift \
  Sirr/features/home/MockHomeFeed.swift Sirr/features/home/EventDetailView.swift
git commit -m "feat(app): recognise the unpaid-workout refusal"
```

---

### Task 5: The sheet step, and opening the unpaid workout

**Files:**
- Modify: `Sirr/features/home/EventDetailView.swift` — `RegistrationFlowSheet`: `Step` (~2269), `stepTitle` (~2398), `backStep` (~2411), body `switch step` (~2432), new `paymentOwedStep` next to `closedAtCapacityStep` (~2952)
- Modify: `Sirr/features/home/MockHomeFeed.swift` — new `requestedOccurrenceID` property and `occurrence(withID:)`
- Modify: `Sirr/features/home/DesignerHomeView.swift` — observe the request (~line 468, after the existing `.onChange(of: selected?.id)`)

**Interfaces:**
- Consumes: `RegistrationOutcome.paymentOwed(eventId:)` (Task 4).
- Produces: `HomeStore.requestedOccurrenceID: UUID?` — set by the sheet, consumed and cleared by `DesignerHomeView`. `HomeStore.occurrence(withID:) -> FeedOccurrence?`.

- [ ] **Step 1: Add the step**

In `RegistrationFlowSheet.Step`, after `case closedAtCapacity`:

```swift
        /// An ended workout in this group is unpaid; registering waits on it.
        case paymentOwed(UUID)
```

In `stepTitle`, add: `case .paymentOwed: "عليك قطة سابقة"`.
In `backStep`, add `.paymentOwed` to the first arm: `case .selection, .success, .waitlistOffer, .waitlisted, .closedAtCapacity, .paymentOwed: nil`.
In the body's `switch step`, add:

```swift
                    case .paymentOwed(let eventId):
                        paymentOwedStep(eventId)
```

- [ ] **Step 2: Add the feed pieces**

In `MockHomeFeed.swift`, next to `var allOccurrences` (~line 476):

```swift
    /// A workout another screen asked Home to open, e.g. the unpaid one a
    /// refused registration points at. Home presents it and clears this.
    var requestedOccurrenceID: UUID?

    func occurrence(withID id: UUID) -> FeedOccurrence? {
        allOccurrences.first { $0.id == id }
    }
```

- [ ] **Step 3: Write the step view**

In `RegistrationFlowSheet`, directly after `closedAtCapacityStep`:

```swift
    /// The server refused because an ended workout here is unpaid. Its name
    /// comes from the loaded feed; without it the sentence still reads.
    private func paymentOwedStep(_ unpaidEventID: UUID) -> some View {
        let unpaid = feed.occurrence(withID: unpaidEventID)
        let body = unpaid.map { "ما دفعت قطتك في \($0.title). ادفعها عشان تقدر تسجّل." }
            ?? "ما دفعت قطتك في تمرين سابق. ادفعها عشان تقدر تسجّل."
        return VStack(spacing: 14) {
            Color.clear.frame(height: 26)

            ZStack {
                Circle().fill(.white.opacity(0.12))
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)

            Text("عليك قطة سابقة")
                .font(TamrinFont.font(size: 24, weight: .bold))
                .foregroundStyle(.white)

            Text(body)
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Text("إذا حوّلت للمنظم مباشرة، اطلب منه يأكد إنه وصلته.")
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            primaryButton(title: "ادفع الآن", color: TamrinTheme.lime, foregroundColor: TamrinTheme.ink) {
                // Home swaps its presented workout for the unpaid one, or, when
                // the feed does not hold it, simply closes back to Home where
                // the unpaid workout is listed.
                feed.requestedOccurrenceID = unpaidEventID
                dismiss()
            }

            Button("لاحقاً") { dismiss() }
                .font(TamrinFont.font(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(minHeight: 44)
        }
    }
```

`FeedOccurrence.title` is the workout's display name (verified).

If the spec's "reload once when not loaded" is wanted, it is already covered: Home reloads its feed on appear, and the fallback sentence covers the moment before. Do not add a separate reload.

- [ ] **Step 4: Home presents the request**

In `DesignerHomeView.swift`, directly after the existing `.onChange(of: selected?.id) { ... }` modifier:

```swift
                // A refused registration asks for the unpaid workout. Setting
                // the cover's item to a different workout replaces the one on
                // screen (SwiftUI dismisses and re-presents on an item change).
                .onChange(of: feed.requestedOccurrenceID) { _, requested in
                    guard let requested else { return }
                    feed.requestedOccurrenceID = nil
                    selected = feed.occurrence(withID: requested)
                }
```

`selected = nil` when the feed does not hold it returns the person to Home, which is the spec's fallback.

- [ ] **Step 5: Build**

Run: `xcodebuild -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' -quiet build 2>&1 | grep -E "error:|BUILD" | head -20; echo "exit ${pipestatus[1]}"`
Expected: no `error:` lines, `exit 0`. Then `git status --short Sirr.xcodeproj` shows only the pre-existing scheme change, no `project.pbxproj`.

- [ ] **Step 6: Commit**

```bash
git add Sirr/features/home/EventDetailView.swift Sirr/features/home/MockHomeFeed.swift \
  Sirr/features/home/DesignerHomeView.swift
git commit -m "feat(app): an unpaid workout explains the refusal and opens it to pay"
```

---

### Task 6: Full verification and hand-over

**Files:** none changed.

- [ ] **Step 1: Run every SQL suite**

```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
for f in supabase/tests/*.sql; do
  out=$(psql "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1)
  echo "$out" | grep -q "ERROR" && echo "FAIL $f: $(echo "$out" | grep ERROR | head -1)" || echo "ok   $f"
done
```
Expected: `ok` for every suite except the three known pre-existing failures (`workspaces_test`, `update_exercise_template_test`, `event_lineups_test`) with their known errors. Any other failure is a regression; fix it before continuing. A fixture that inserts a seat for a member who already owes in the same workspace is the likely cause: reorder the fixture (insert first, move the old event into the past after), do not weaken the rule.

- [ ] **Step 2: Seeded apply check**

An empty database hides plan-time errors inside loops (memory `local-supabase-db-workflow`). The loops touched here are the recurring job and promotion; both ran against seeded rows in the suites above (`recurring_payment_gate_test` runs the generator; the new test runs promotion). Confirm those two suites passed in Step 1.

- [ ] **Step 3: Hand over to Naif** (he runs these; the implementer does not)

Before pushing, count what the one-time cleanup will forgive on the sandbox, in the SQL editor:

```sql
select count(*) from public.event_participants ep join public.events e on e.id = ep.event_id
where ep.payment_status = 'pending' and ep.payment_declared_at is not null
  and e.cancelled_at is null and coalesce(e.end_date, e.start_date) < now();
```

Then:

```bash
supabase link --project-ref kpcdinxusxycenfnitjc
```

```bash
supabase db push
```

```bash
supabase functions deploy send-push --project-ref kpcdinxusxycenfnitjc
```

Device test on the sandbox-pinned build: owe for a workout, try to register for another in the same group, see «عليك قطة سابقة», tap «ادفع الآن», pay with Apple Pay, register again. Also: organizer taps «وصلتني القطة» on a debtor, who can then register.

Production gets none of this until the payments branch ships; the block reaches every installed build the moment it lands there.
