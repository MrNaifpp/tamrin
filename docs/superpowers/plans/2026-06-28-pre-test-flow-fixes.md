# Pre-Test Flow Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Tamrin app ready for real testers by hiding ended events, requiring an end time, shipping Apple-only sign-in, letting joiners register friends as guest participants, and sending a twice-daily upcoming-event reminder.

**Architecture:** iOS SwiftUI client + Supabase (Postgres RPCs, RLS, Edge Functions, APNs push via an outbox table). Changes span Swift views/services, SQL migrations, and one Deno Edge Function copy file. The manual STC Pay confirm flow stays; the real payment gateway is out of scope.

**Tech Stack:** Swift 5 / SwiftUI, supabase-swift 2.41, Postgres (plpgsql, pg_cron, pg_net), Deno (Edge Functions), APNs.

## Global Constraints

- **No iOS test target exists.** Do NOT scaffold XCTest. iOS tasks are verified by a clean build (`xcodebuild ... build`) plus the manual checks listed in each task. Edge Function logic IS tested via Deno (`deno test`), following the existing `copy_test.ts` pattern. SQL is verified with the explicit `psql`/SQL snippets given.
- **All events are paid.** There is no free-event product path; do not add one.
- **Payment gateway / payment matching is deferred.** Keep the manual submit → confirm/reject flow.
- **Arabic UI, RTL.** All user-facing copy is Arabic, matching existing strings.
- **Timezone:** event reminder cron times are **Asia/Riyadh (UTC+3, no DST)**. Cron entries are written in **UTC**.
- **iOS build command (verification):**
  `xcodebuild -project Sirr.xcodeproj -scheme Sirr -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  Expected tail: `** BUILD SUCCEEDED **`
- **Migration filenames** use the existing `YYYYMMDDHHMMSS_name.sql` convention under `supabase/migrations/`, with a timestamp later than `20260622140000`.

---

## Task 1: Apple-only sign-in (remove Google button)

**Files:**
- Modify: `Sirr/features/auth/LoginOnbord.swift:120-171`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (pure UI).

- [ ] **Step 1: Remove the Google button and make Apple full-width**

In `LoginOnbord.swift`, replace the entire `HStack(spacing: 16) { ... }` block (the row containing the disabled `g.circle.fill` "قريباً" button and the Apple button, currently lines ~120-171) with a single full-width Apple button:

```swift
                        Button {
                            Task { await vm.signInWithApple() }
                        } label: {
                            Group {
                                if vm.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                } else {
                                    HStack(spacing: 8) {
                                        Image(systemName: "apple.logo")
                                            .font(.system(size: 22, weight: .medium))
                                        Text("المتابعة عبر Apple")
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 27, style: .continuous)
                                    .fill(Color(white: 0.95))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isLoading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
```

- [ ] **Step 2: Build**

Run the iOS build command from Global Constraints.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual check**

Run the app, reach the onboarding screen. Verify: no Google button / "قريباً" badge; a single full-width Apple button; tapping it starts Apple sign-in.

- [ ] **Step 4: Commit**

```bash
git add Sirr/features/auth/LoginOnbord.swift
git commit -m "feat(ios): Apple-only sign-in (remove disabled Google button)"
```

---

## Task 2: Carry real dates into EventData + hide ended events

**Files:**
- Modify: `Sirr/Models/EventData.swift:3-26` (struct + init), `:31-43` (from(record:))
- Modify: `Sirr/pages/EventPageView.swift` (the `loadEvents()` function in the `private extension EventPageView`)

**Interfaces:**
- Consumes: `EventRecord.startDate: Date`, `EventRecord.endDate: Date?` (already exist, `EventService.swift:21-22`).
- Produces: `EventData.startDate: Date`, `EventData.endDate: Date?`.

- [ ] **Step 1: Add stored date fields to EventData**

In `EventData.swift`, add two stored properties and init params. Replace the property list + init:

```swift
struct EventData: Identifiable, Hashable {
    let id: UUID
    let creatorId: UUID
    let name: String
    let date: String
    /// Real start/end timestamps (the `date` string above is for display only).
    let startDate: Date
    let endDate: Date?
    /// When nil, UI uses a default placeholder image (e.g. card1).
    let imageUrl: String?
    let registrationLocked: Bool
    let totalPrice: Int
    let pricePerPerson: Double
    let maxParticipants: Int?

    init(id: UUID, creatorId: UUID = UUID(), name: String, date: String, startDate: Date = Date(), endDate: Date? = nil, imageUrl: String? = nil, registrationLocked: Bool = false, totalPrice: Int = 0, pricePerPerson: Double = 0, maxParticipants: Int? = nil) {
        self.id = id
        self.creatorId = creatorId
        self.name = name
        self.date = date
        self.startDate = startDate
        self.endDate = endDate
        self.imageUrl = imageUrl
        self.registrationLocked = registrationLocked
        self.totalPrice = totalPrice
        self.pricePerPerson = pricePerPerson
        self.maxParticipants = maxParticipants
    }
}
```

- [ ] **Step 2: Populate the dates in from(record:)**

In `EventData.swift`, in `static func from(record:)`, add `startDate`/`endDate` to the returned `EventData`:

```swift
        EventData(
            id: record.id,
            creatorId: record.creatorId,
            name: record.name,
            date: EventData.formatEventDate(record.startDate, endDate: record.endDate),
            startDate: record.startDate,
            endDate: record.endDate,
            imageUrl: record.imageUrl,
            registrationLocked: record.registrationLocked ?? false,
            totalPrice: record.totalPrice ?? 0,
            pricePerPerson: record.pricePerPerson ?? 0,
            maxParticipants: record.maxParticipants
        )
```

- [ ] **Step 3: Filter ended events in loadEvents**

In `EventPageView.swift`, find `loadEvents()` (in the `private extension EventPageView`). It maps `EventRecord`s into `EventData` and assigns them to the view's events array. Add a filter that drops events whose effective end has passed. Locate the line that builds the array from records (a `.map { EventData.from(record: $0) }`) and chain a filter immediately after it:

```swift
            .map { EventData.from(record: $0) }
            .filter { (($0.endDate ?? $0.startDate)) >= Date() }
```

If `loadEvents` assigns through an intermediate variable, apply the same `.filter { (($0.endDate ?? $0.startDate)) >= Date() }` to that array before assignment. The `endDate ?? startDate` fallback covers any legacy row with a null end.

- [ ] **Step 4: Build**

Run the iOS build command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual check**

In Supabase, set one of your events' `end_date` to a past timestamp (`update public.events set end_date = now() - interval '1 day' where id = '<event-id>';`). Launch the app → that event no longer appears in the list. An event with a future end (or started-but-not-ended) still appears.

- [ ] **Step 6: Commit**

```bash
git add Sirr/Models/EventData.swift Sirr/pages/EventPageView.swift
git commit -m "feat(ios): hide ended events; carry real start/end dates into EventData"
```

---

## Task 3: Require end time at event creation

**Files:**
- Modify: `Sirr/pages/NewEventView.swift:63-70` (`isFormValid`)

**Interfaces:**
- Consumes: existing `@State startDate: Date?`, `@State endDate: Date?` (`NewEventView.swift:25-26`).
- Produces: nothing.

- [ ] **Step 1: Add date validation to isFormValid**

In `NewEventView.swift`, replace `isFormValid`:

```swift
    var isFormValid: Bool {
        guard let start = startDate, let end = endDate else { return false }
        return !exerciseName.isEmpty &&
        !exerciseLocation.isEmpty &&
        selectedCoordinate != nil &&
        !description.isEmpty &&
        fieldValue > 0 &&
        numberOfPeople > 0 &&
        end > start
    }
```

- [ ] **Step 2: Build**

Run the iOS build command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual check**

Open the create-event form. With all other fields filled but **no end time**, the create button stays disabled. Set an end time **before** the start → still disabled. Set end **after** start → enabled, and creating succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sirr/pages/NewEventView.swift
git commit -m "feat(ios): require a valid end time when creating an event"
```

---

## Task 4: Guest columns migration on event_participants

**Files:**
- Create: `supabase/migrations/20260628100000_event_participants_guests.sql`

**Interfaces:**
- Consumes: existing `public.event_participants` (`20260130100000_create_events.sql`), `payment_status`/`paid_to_number` (`20260617200000`).
- Produces: columns `guest_name text`, `added_by uuid`; nullable `user_id`; partial unique index `event_participants_event_user_uniq`.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260628100000_event_participants_guests.sql`:

```sql
-- Guests: a joiner can register friends. Each friend is its own row with a
-- null user_id (no account), a guest_name, and added_by = the paying joiner.

-- Allow guest rows (no account).
alter table public.event_participants
  alter column user_id drop not null,
  add column if not exists guest_name text,
  add column if not exists added_by uuid references auth.users(id) on delete cascade;

-- Replace the (event_id, user_id) unique constraint with a partial unique index
-- so multiple guest rows (null user_id) can coexist, while a real user still
-- can't join the same event twice.
alter table public.event_participants
  drop constraint if exists event_participants_event_id_user_id_key;

create unique index if not exists event_participants_event_user_uniq
  on public.event_participants (event_id, user_id)
  where user_id is not null;

create index if not exists idx_event_participants_added_by
  on public.event_participants(added_by);
```

- [ ] **Step 2: Apply and verify schema**

Apply via `supabase db push` (or paste into the SQL editor). Verify:

```sql
select column_name, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'event_participants'
  and column_name in ('user_id','guest_name','added_by');
```
Expected: `user_id | YES`, `guest_name | YES`, `added_by | YES`.

```sql
select indexname from pg_indexes
where tablename = 'event_participants' and indexname = 'event_participants_event_user_uniq';
```
Expected: one row.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260628100000_event_participants_guests.sql
git commit -m "feat(db): guest columns + partial unique index on event_participants"
```

---

## Task 5: Group-aware payment RPCs

**Files:**
- Create: `supabase/migrations/20260628100100_stcpay_rpcs_guests.sql`

**Interfaces:**
- Consumes: Task 4 columns; existing `push_outbox` (`20260622100000`).
- Produces (RPC contracts the Swift layer relies on):
  - `submit_payment(p_event_id uuid, p_user_id uuid, p_guest_names text[] default '{}')` → json with `status`, and on `submitted`: `creator_id`, `paid_to_number`, `group_size` (int).
  - `confirm_payment(p_event_id, p_user_id, p_creator_id)` → confirms the joiner's whole group.
  - `reject_payment` / `cancel_pending` → delete the joiner's whole group, return `waiter_ids`.
  - `get_event_participants(p_event_id)` → adds `participant_id`, `guest_name`, `added_by`; `user_id` may be null.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260628100100_stcpay_rpcs_guests.sql`:

```sql
-- Group-aware STC Pay RPCs: a joiner pays for themselves + N guests in one go.

-- ============================================================================
-- submit_payment: insert the joiner's row + one row per guest (null user_id).
-- ============================================================================
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

  if ev.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into existing_status
    from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;
  if existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', existing_status);
  end if;

  -- Clean guest names (drop nulls/blanks); group = self + valid guests.
  select coalesce(array_agg(trim(g)), '{}')
    into v_guests
    from unnest(p_guest_names) as g
    where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

  -- Seat cap (pending + confirmed both count); whole group must fit.
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

  -- Joiner's own row.
  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

  -- One row per guest.
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

-- ============================================================================
-- confirm_payment: confirm the joiner + all rows they added.
-- ============================================================================
create or replace function public.confirm_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  updated_rows int;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if ev.creator_id <> p_creator_id then
    raise exception 'Not authorized: only the event creator can confirm payments';
  end if;

  update public.event_participants
    set payment_status = 'confirmed'
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';

  get diagnostics updated_rows = row_count;
  if updated_rows = 0 then
    return json_build_object('status', 'no_pending_row');
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_confirmed', p_event_id);

  return json_build_object('status', 'confirmed', 'joiner_id', p_user_id);
end;
$$;

grant execute on function public.confirm_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- reject_payment: delete the joiner + their guests, free seats, notify waiters.
-- ============================================================================
create or replace function public.reject_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  deleted_rows int;
  waiters json;
begin
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if ev.creator_id <> p_creator_id then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  delete from public.event_participants
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';

  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object('status', 'rejected', 'joiner_id', p_user_id, 'waiter_ids', waiters);
end;
$$;

grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

-- ============================================================================
-- cancel_pending: joiner cancels their own group.
-- ============================================================================
create or replace function public.cancel_pending(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_rows int;
  waiters json;
begin
  perform 1 from public.events where id = p_event_id for update;

  delete from public.event_participants
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';

  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into waiters
    from public.event_waitlist
    where event_id = p_event_id;

  return json_build_object('status', 'cancelled', 'waiter_ids', waiters);
end;
$$;

grant execute on function public.cancel_pending(uuid, uuid) to authenticated;

-- ============================================================================
-- get_event_participants: expose participant_id (stable), guest_name, added_by.
-- user_id may be null for guests; display_name falls back to guest_name.
-- ============================================================================
create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
begin
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

grant execute on function public.get_event_participants(uuid) to authenticated;
grant execute on function public.get_event_participants(uuid) to anon;
```

- [ ] **Step 2: Apply the migration**

Apply via `supabase db push` (or SQL editor). No errors expected.

- [ ] **Step 3: Verify with a manual group submit**

Use a real event id you created (with `max_participants` ≥ 3 and a creator that has an `stc_pay_number`) and a joiner user id:

```sql
select public.submit_payment('<event-id>'::uuid, '<joiner-id>'::uuid, array['صديق أول','صديق ثاني']);
```
Expected JSON: `status = submitted`, `group_size = 3`. Then:

```sql
select user_id, guest_name, added_by, payment_status
from public.event_participants where event_id = '<event-id>'::uuid order by created_at;
```
Expected: the joiner row (user_id set, guest_name null) + 2 guest rows (user_id null, guest_name set, added_by = joiner), all `pending`.

Confirm the group:
```sql
select public.confirm_payment('<event-id>'::uuid, '<joiner-id>'::uuid, '<creator-id>'::uuid);
```
Expected: `status = confirmed`; re-running the participants select shows all 3 rows `confirmed`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260628100100_stcpay_rpcs_guests.sql
git commit -m "feat(db): group-aware STC Pay RPCs (joiner + guests)"
```

---

## Task 6: STCPayService — pass guest names, return group size

**Files:**
- Modify: `Sirr/core/payment/STCPayService.swift:18-32` (enum), `:43-85` (submitPayment)

**Interfaces:**
- Consumes: `submit_payment(..., p_guest_names text[])` returning `group_size` (Task 5).
- Produces: `SubmitPaymentResult.submitted(creatorId: UUID, paidToNumber: String, groupSize: Int)`; `submitPayment(eventId:userId:guestNames:)`.

- [ ] **Step 1: Add groupSize to the submitted case**

In `STCPayService.swift`, change the `.submitted` case:

```swift
    /// Payment was submitted; pending rows exist (joiner + guests). `groupSize`
    /// is the number of seats paid for (1 + guests).
    case submitted(creatorId: UUID, paidToNumber: String, groupSize: Int)
```

- [ ] **Step 2: Add guestNames param and parse group_size**

Replace the `submitPayment` signature and its params + `.submitted` parsing:

```swift
    /// Submit a paid-event payment for the joiner plus optional named guests.
    func submitPayment(eventId: UUID, userId: UUID, guestNames: [String] = []) async throws -> SubmitPaymentResult {
        struct Params: Encodable {
            let p_event_id: String
            let p_user_id: String
            let p_guest_names: [String]
        }
        let params = Params(
            p_event_id: eventId.uuidString,
            p_user_id: userId.uuidString,
            p_guest_names: guestNames
        )
        let response = try await client.rpc("submit_payment", params: params).execute()
        let payload = try Self.decodeJSON(response.data)

        guard let status = payload["status"] as? String else {
            throw NSError(domain: "STCPayService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed submit_payment response"])
        }

        switch status {
        case "submitted":
            guard
                let creatorIdString = payload["creator_id"] as? String,
                let creatorId = UUID(uuidString: creatorIdString),
                let number = payload["paid_to_number"] as? String
            else {
                throw NSError(domain: "STCPayService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed submitted payload"])
            }
            let groupSize = (payload["group_size"] as? Int) ?? 1
            stcPayLogger.info("submit_payment submitted (eventId: \(eventId), group: \(groupSize))")
            await PushManager.shared.requestAuthorizationAndRegister()
            return .submitted(creatorId: creatorId, paidToNumber: number, groupSize: groupSize)
```

Leave the remaining `case`s (`seats_full`, `already_joined`, `creator_missing_number`, `registration_closed`, `default`) unchanged.

- [ ] **Step 3: Build**

The build will FAIL until Task 8 updates the two call sites pattern-matching `.submitted`. That is expected — proceed; the deliverable for this task is the service change. (Do not commit a broken build alone; this task commits together with Task 8. Skip to Task 7/8, then build + commit.)

> NOTE: Tasks 6, 7, and 8 form one compile unit (the `.submitted` signature change ripples into the views). Implement 6 → 7 → 8, then build and commit once at the end of Task 8.

---

## Task 7: ParticipantRecord — guest fields + stable id

**Files:**
- Modify: `Sirr/core/supabase/EventService.swift:61-85` (`ParticipantRecord`)

**Interfaces:**
- Consumes: `get_event_participants` returning `participant_id`, `guest_name`, `added_by`, nullable `user_id` (Task 5).
- Produces: `ParticipantRecord` with `participantId: UUID` (id), `userId: UUID?`, `guestName: String?`, `addedBy: UUID?`, `isGuest: Bool`.

- [ ] **Step 1: Rewrite ParticipantRecord**

Replace the `ParticipantRecord` struct:

```swift
/// Row from get_event_participants RPC.
struct ParticipantRecord: Codable, Identifiable {
    let participantId: UUID
    let userId: UUID?
    let joinedAt: String?
    let displayName: String?
    let avatarUrl: String?
    let paymentStatus: PaymentStatus?
    let paidToNumber: String?
    let guestName: String?
    let addedBy: UUID?

    var id: UUID { participantId }

    /// True if this row is a guest (no account) added by a paying joiner.
    var isGuest: Bool { userId == nil }

    /// True if the row represents a confirmed seat.
    var isConfirmed: Bool { (paymentStatus ?? .confirmed) == .confirmed }

    /// True if the row is awaiting creator confirmation.
    var isPending: Bool { paymentStatus == .pending }

    enum CodingKeys: String, CodingKey {
        case participantId = "participant_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case paymentStatus = "payment_status"
        case paidToNumber = "paid_to_number"
        case guestName = "guest_name"
        case addedBy = "added_by"
    }
}
```

(Build verification happens at the end of Task 8.)

---

## Task 8: Wire guests through the enrollment UI

**Files:**
- Modify: `Sirr/Components/STCPaySheet.swift:13-23` (add groupSize), `:62` (amount)
- Modify: `Sirr/pages/EventHeroDetailView.swift` — `EnrollmentSheetView` (`onSubmittedPayment` signature ~`:218-223` and `:590`, `handleEnroll` `:891-929`), the STC Pay sheet presentation (`:25` state, `:404-411`), and the participant rows / owner confirm guards (`:282-365`, `:470-508`)
- Modify: `Sirr/pages/SharedEventView.swift:322` (`.submitted` pattern)

**Interfaces:**
- Consumes: `STCPayService.submitPayment(eventId:userId:guestNames:)`, `.submitted(creatorId:paidToNumber:groupSize:)` (Task 6); `ParticipantRecord.isGuest`, `.userId: UUID?`, `.guestName` (Task 7).
- Produces: nothing downstream.

- [ ] **Step 1: STCPaySheet shows the group total**

In `STCPaySheet.swift`, add a `groupSize` property and use it for the amount. Change the property block (top of the struct):

```swift
struct STCPaySheet: View {
    let eventName: String
    let amount: Double
    let stcPayNumber: String
    var groupSize: Int = 1
```

And change the amount text (currently `Text(String(format: "%.0f ر.س", amount))`, ~line 62) to:

```swift
                    Text(String(format: "%.0f ر.س", amount * Double(groupSize)))
```

- [ ] **Step 2: EnrollmentSheetView passes guest names + group size up**

In `EventHeroDetailView.swift`, change the `onSubmittedPayment` closure type on `EnrollmentSheetView` (declaration near line 590):

```swift
    var onSubmittedPayment: ((String, Int) -> Void)? = nil
```

In `handleEnroll()` (the paid branch), pass the collected guest names and propagate group size. Replace the paid-branch body's submit call and `.submitted` case:

```swift
                    let result = try await STCPayService.shared.submitPayment(
                        eventId: event.id,
                        userId: session.user.id,
                        guestNames: participants.filter { $0 != userName }
                    )
                    switch result {
                    case .submitted(_, let number, let groupSize):
                        onSubmittedPayment?(number, groupSize)
                        dismiss()
```

(The `participants` array here is the local `[String]` guest list at `EventHeroDetailView.swift:598`; excluding `userName` leaves just the friends. Leave the other `switch` cases unchanged.)

- [ ] **Step 3: Parent stores group size and feeds the sheet**

In `EventHeroDetailView` (the outer view), add state next to `stcPaySheetNumber` (line ~25):

```swift
    @State private var stcPaySheetGroupSize: Int = 1
```

Update the `onSubmittedPayment` handler passed into `EnrollmentSheetView` (line ~218):

```swift
                                    onSubmittedPayment: { number, groupSize in
                                        showEnrollmentSheet = false
                                        hasPendingPayment = true
                                        stcPaySheetNumber = number
                                        stcPaySheetGroupSize = groupSize
                                        Task { await loadParticipants() }
                                    },
```

Update the STC Pay sheet presentation (line ~408) to pass `groupSize`:

```swift
            if let number = stcPaySheetNumber {
                STCPaySheet(eventName: event.name, amount: event.pricePerPerson, stcPayNumber: number, groupSize: stcPaySheetGroupSize)
            }
```

- [ ] **Step 4: Guard owner actions to real users; show a guest tag**

In `EventHeroDetailView.swift`, in the participants `ForEach`, the owner confirm/reject buttons must only show for a real pending user (not a guest). Change the condition `if isOwner && participant.isPending {` (line ~327) to:

```swift
                                    if isOwner && participant.isPending && participant.userId != nil {
```

In the same row, add a guest label. In the trailing-status area (the `if participant.userId == event.creatorId { ... } else if participant.isPending { ... }` block near line 312), add a leading branch for guests:

```swift
                                        if participant.isGuest {
                                            Text("ضيف")
                                                .font(.appCaption)
                                                .foregroundStyle(.white.opacity(0.6))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.white.opacity(0.12))
                                                .clipShape(Capsule())
                                        } else if participant.userId == event.creatorId {
```

(i.e. prepend the `if participant.isGuest {` branch and turn the existing `if participant.userId == event.creatorId` into `else if`.)

- [ ] **Step 5: Unwrap optional userId in owner confirm/reject**

In `handleOwnerConfirm(participant:)` and `handleOwnerReject(participant:)` (lines ~470, ~490), `participant.userId` is now optional. Add an unwrap at the top of each, replacing the `actionInFlight = participant.userId` usage. For `handleOwnerConfirm`:

```swift
    private func handleOwnerConfirm(participant: ParticipantRecord) {
        guard let creatorId = currentUserId, let joinerId = participant.userId else { return }
        actionInFlight = joinerId
        ownerActionError = nil
        Task {
            defer { actionInFlight = nil }
            do {
                try await STCPayService.shared.confirmPayment(
                    eventId: event.id,
                    joinerId: joinerId,
                    creatorId: creatorId
                )
                await loadParticipants()
            } catch {
                ownerActionError = "تعذر تأكيد الدفعة"
                print("[ConfirmPayment] Error — \(error.localizedDescription)")
            }
        }
    }
```

Apply the same `guard let ... joinerId = participant.userId` + `joinerId` substitution to `handleOwnerReject`.

- [ ] **Step 6: Fix the SharedEventView pattern match**

In `SharedEventView.swift` (line ~322), the deep-link join has no guest UI (group is always 1). Update the pattern to ignore the new associated value:

```swift
            case .submitted(_, let number, _):
                hasPendingPayment = true
                stcPaySheetNumber = number
```

- [ ] **Step 7: Build (covers Tasks 6, 7, 8)**

Run the iOS build command. Expected: `** BUILD SUCCEEDED **`. Fix any remaining `.submitted` arity mismatches the compiler flags.

- [ ] **Step 8: Manual check**

As a joiner on a paid event, tap "سجل في التمرين", add one friend via "بسجل معي أحد", submit. The STC Pay sheet shows `price × 2`. As the creator, open the event: you see the joiner (with تأكيد/رفض) plus a row tagged "ضيف" (no buttons). Tap تأكيد → both flip to confirmed. Repeat and tap رفض → both rows disappear and the seat count drops by 2.

- [ ] **Step 9: Commit**

```bash
git add Sirr/core/payment/STCPayService.swift Sirr/core/supabase/EventService.swift Sirr/Components/STCPaySheet.swift Sirr/pages/EventHeroDetailView.swift Sirr/pages/SharedEventView.swift
git commit -m "feat(ios): register friends as guest participants (group pay/confirm)"
```

---

## Task 9: Edge Function copy for event reminder

**Files:**
- Modify: `supabase/functions/send-push/copy.ts:7-22` (add a case)
- Modify: `supabase/functions/send-push/copy_test.ts` (add a test)

**Interfaces:**
- Consumes: `copyFor(type, eventName)` returning `{title, body} | null`.
- Produces: copy for `type === "event_reminder"`.

- [ ] **Step 1: Write the failing test**

In `supabase/functions/send-push/copy_test.ts`, add:

```ts
Deno.test("event_reminder copy interpolates the event name", () => {
  const c = copyFor("event_reminder", "تمرين كرة قدم");
  assertEquals(c, {
    title: "تذكير بتمرينك ⏰",
    body: "لا تنسَ تمرين كرة قدم القادم. نراك هناك! 🙌",
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `deno test supabase/functions/send-push/copy_test.ts`
Expected: FAIL on the new case (`copyFor("event_reminder", ...)` returns `null`).

- [ ] **Step 3: Add the copy case**

In `supabase/functions/send-push/copy.ts`, add a case before `default`:

```ts
    case "event_reminder":
      return {
        title: "تذكير بتمرينك ⏰",
        body: `لا تنسَ ${eventName} القادم. نراك هناك! 🙌`,
      };
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `deno test supabase/functions/send-push/copy_test.ts`
Expected: PASS (all tests, including the existing three).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(push): event_reminder notification copy"
```

---

## Task 10: Twice-daily reminder scheduler

**Files:**
- Create: `supabase/migrations/20260628100200_event_reminders.sql`

**Interfaces:**
- Consumes: `public.events` (adds `reminder_sent_at`), `public.event_participants`, `public.push_outbox`, the `trg_fire_push_outbox` trigger (`20260622120000`), the `event_reminder` copy (Task 9).
- Produces: `reminder_sent_at` column; `enqueue_event_reminders()`; two pg_cron jobs.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260628100200_event_reminders.sql`:

```sql
-- Twice-daily "upcoming events" reminder. A cron job (08:00 and 20:00
-- Asia/Riyadh = 05:00 and 17:00 UTC) enqueues a push for every confirmed
-- participant of any event starting within the next 12h that hasn't been
-- reminded yet. push_outbox's insert trigger fans out to send-push.

create extension if not exists pg_cron with schema extensions;

alter table public.events
  add column if not exists reminder_sent_at timestamptz;

-- Enqueue reminders for events starting in the next 12h, once each.
create or replace function public.enqueue_event_reminders()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  with due as (
    select e.id
    from public.events e
    where e.reminder_sent_at is null
      and e.start_date > now()
      and e.start_date <= now() + interval '12 hours'
      and exists (
        select 1 from public.event_participants ep
        where ep.event_id = e.id
          and ep.user_id is not null
          and ep.payment_status = 'confirmed'
      )
  ),
  enqueued as (
    insert into public.push_outbox (user_id, type, event_id)
    select ep.user_id, 'event_reminder', ep.event_id
    from public.event_participants ep
    join due on due.id = ep.event_id
    where ep.user_id is not null
      and ep.payment_status = 'confirmed'
    returning event_id
  )
  update public.events e
    set reminder_sent_at = now()
    where e.id in (select id from due);
end;
$$;

-- Schedule two daily runs, 12h apart (UTC).
select cron.schedule('event-reminders-am', '0 5 * * *', $$select public.enqueue_event_reminders();$$);
select cron.schedule('event-reminders-pm', '0 17 * * *', $$select public.enqueue_event_reminders();$$);
```

- [ ] **Step 2: Apply the migration**

Apply via `supabase db push` (or SQL editor). If `pg_cron` is not yet enabled on the project, enable it in Dashboard → Database → Extensions first, then re-run.

- [ ] **Step 3: Verify the cron jobs registered**

```sql
select jobname, schedule from cron.job where jobname like 'event-reminders-%';
```
Expected: two rows — `event-reminders-am | 0 5 * * *` and `event-reminders-pm | 0 17 * * *`.

- [ ] **Step 4: Verify enqueue logic manually**

Set one event to start within the window and have a confirmed participant:

```sql
update public.events set start_date = now() + interval '3 hours', reminder_sent_at = null
  where id = '<event-id>'::uuid;
select public.enqueue_event_reminders();
select user_id, type, event_id from public.push_outbox
  where event_id = '<event-id>'::uuid and type = 'event_reminder';
```
Expected: one `event_reminder` row per confirmed participant. Then verify dedup:

```sql
select public.enqueue_event_reminders();   -- second run
select count(*) from public.push_outbox
  where event_id = '<event-id>'::uuid and type = 'event_reminder';
```
Expected: count unchanged (reminder_sent_at now set → no new rows).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260628100200_event_reminders.sql
git commit -m "feat(db): twice-daily upcoming-event reminder via pg_cron + outbox"
```

---

## Self-Review

**Spec coverage:**
- Hide ended events → Task 2. ✓
- Require end time → Task 3. ✓
- Apple-only sign-in → Task 1. ✓
- Add friends as participant list (nullable user_id, guest_name, added_by, partial unique index; group submit/confirm/reject; amount × group) → Tasks 4–8. ✓
- Twice-daily reminder (reminder_sent_at, 12h window, 08:00/20:00 Riyadh, push_outbox reuse, confirmed real users only) → Tasks 9–10. ✓
- Deferred items (gateway, Settings gear, realtime) → not implemented, by design. ✓

**Type consistency:**
- `submit_payment` returns `group_size` (Task 5) → parsed in `STCPayService` (Task 6) → consumed by `EnrollmentSheetView`/`STCPaySheet` (Task 8). ✓
- `.submitted(creatorId:paidToNumber:groupSize:)` updated at all three pattern sites: `STCPayService` (def), `EnrollmentSheetView` and `SharedEventView` (Task 8 steps 2 & 6). ✓
- `ParticipantRecord.userId` now `UUID?`; call sites guarded in Task 8 step 5; `id` switched to `participantId` (RPC `participant_id`, Task 5). ✓
- `get_event_participants` selects `participant_id`, `guest_name`, `added_by` (Task 5) matching `ParticipantRecord` CodingKeys (Task 7). ✓
- `confirm_payment`/`reject_payment`/`cancel_pending` keep their existing Swift signatures; group logic is server-side only. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/vague steps; every code step shows concrete code. ✓

**Note on build sequencing:** Tasks 6–8 are one compile unit and build/commit together at Task 8 (called out in Task 6 Step 3). This is intentional, not a gap.
