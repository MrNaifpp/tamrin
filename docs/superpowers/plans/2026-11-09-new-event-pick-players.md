# New Event: Pick Players Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a last "pick the players" step to the existing تمرين جديد flow, so an organizer can seat people from their groups or past events, with a push naming who added them.

**Architecture:** One new database function creates the event and seats the picked people in a single transaction (`create_event_with_players`, which wraps the existing `create_event`), and one returns what the organizer can pick from (`get_my_pick_sources`). A `push_outbox` trigger stops picked people from also getting the "new event" push. The app adds a `.players` step to `CreateTeamFlow`, built from native SwiftUI `List`s, and decides on the device whether the event goes into an existing workspace or a new one.

**Tech Stack:** SwiftUI (iOS 26), Supabase Postgres (plpgsql), Deno edge function `send-push`.

**Spec:** `docs/superpowers/specs/2026-11-09-new-event-pick-players-design.md`

## Global Constraints

- Work on the branch this worktree is on; `git pull` first (Faris shares the branch).
- Never commit `Sirr.xcodeproj/project.pbxproj` or `Sirr.xcodeproj/xcshareddata/xcschemes/Sirr.xcscheme`. New Swift files need no project change (the project uses synchronized folders).
- The new steps use Apple's SwiftUI components only (`NavigationStack`, `List`, `Section`, `Button`, `ContentUnavailableView`, `.searchable`, `.toolbar`, `.selectionDisabled`). No hand-drawn tick circles, step bars, or bottom floating buttons. The app font (`TamrinFont`) and accent colour stay.
- Existing `CreateTeamFlow` steps stay unchanged. An organizer with nothing to pick from never sees the new step.
- Push copy: body `<organizer name> أضافك إلى «<event name>»`.
- Database tests run on the local stack only. Never `db push` to prod; never re-run old migrations (see the local Supabase memory note: rebuild the schema instead).
- Swift is checked by building only. There is no Swift test target, and adding one would change `project.pbxproj`. Never boot a simulator; Naif tests on his device.
- Release builds point at prod, Debug at the sandbox (`kpcdinxusxycenfnitjc`).

## Review Focus

1. **Whole group picked:** members already in the workspace must get only the "added you" push, not the "new event" push as well. → Task 2 test `whole group gets one push`.
2. **More picks than seats:** the server refuses, even if the app's limit is bypassed. → Task 2 test `too many players`.
3. **A user id the organizer has no link to** (stale or forged): refused, nobody seated. → Task 2 test `stranger refused`.
4. **The organizer's own id in the list:** ignored, never seated as a player. → Task 2 test `organizer id ignored`.
5. **Free event (price 0):** picked seats are `confirmed`, not `pending`. → Task 2 test `free event seats confirmed`.

---

### Task 1: `get_my_pick_sources` (database)

**Files:**
- Create: `supabase/migrations/20261109100000_pick_players.sql` (this task writes the first half)
- Test: `supabase/tests/pick_players_test.sql`

**Interfaces:**
- Produces: `public.get_my_pick_sources() returns json`, granted to `authenticated`, `security definer`, `set search_path = public`. Shape:
  ```json
  {"groups": [{"workspace_id": "uuid", "name": "text", "last_played_at": "timestamptz|null",
               "members": [{"user_id": "uuid", "name": "text", "avatar_url": "text|null"}]}],
   "past_players": [{"user_id": "uuid", "name": "text", "avatar_url": "text|null"}]}
  ```
  - `groups`: workspaces where `owner_id = auth.uid()` that have at least one member besides the caller. `members` leaves out the caller and is ordered by name. `last_played_at` = latest `events.start_date < now()` with `cancelled_at is null` in that workspace. Groups ordered by `last_played_at desc nulls last`, then name.
  - `past_players`: distinct app users (`event_participants.user_id is not null`, not the caller) from events in workspaces the caller owns, ordered by name. Name-only rows (`user_id is null`) never appear.
  - Names and avatars come from `public.users (user_id, name, avatar_url)`.

- [ ] **Step 1: Write the failing test** in `supabase/tests/pick_players_test.sql`, in the style of `supabase/tests/create_event_goes_live_test.sql` (`begin;` … `pg_temp.set_auth` … `rollback;`, ids prefixed `63000000-…`). Fixture: owner O; workspace A (owned by O) with members O, P1, P2; workspace B owned by someone else with member P3; a past event in A with participants P1 and a manual guest row (`user_id null`, `guest_name 'ضيف'`); a past event in an O-owned workspace C whose only member is O, with participant P4. Assertions (raise exception on mismatch):
  - as O: `groups` has exactly A (C has no other members; B isn't O's), with members `[P1, P2]` and `last_played_at` = that past event's start.
  - as O: `past_players` user ids = `{P1, P4}` (no guest, no O, no P3).
  - as P1 (owns nothing): `groups = []` and `past_players = []`.

- [ ] **Step 2: Run it to make sure it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/pick_players_test.sql`
Expected: FAIL, `function public.get_my_pick_sources() does not exist`.

- [ ] **Step 3: Implement `get_my_pick_sources()`** in the new migration, then apply only that file to the local stack: `psql … -f supabase/migrations/20261109100000_pick_players.sql`.

- [ ] **Step 4: Run the test** (same command). Expected: completes with no exception.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261109100000_pick_players.sql supabase/tests/pick_players_test.sql
git commit -m "feat(db): list the groups and past players an organizer can pick from"
```

### Task 2: `create_event_with_players` and the invite skip (database)

**Files:**
- Modify: `supabase/migrations/20261109100000_pick_players.sql` (append)
- Test: `supabase/tests/pick_players_test.sql` (append)

**Interfaces:**
- Consumes: `public.create_event(...)` as defined in `supabase/migrations/20260821100000_capacity_policy_and_waitlist_promotion.sql:211` (returns `row_to_json(event)`).
- Produces: `public.create_event_with_players(<every create_event parameter, same names, types and defaults>, p_player_ids uuid[]) returns json`: the same event JSON `create_event` returns. Granted to `authenticated`, `security definer`, `set search_path = public`.
- Produces: push type `'added_to_event'` in `push_outbox`, with `actor_id` = the organizer.

Behaviour, in order, all in one transaction:
1. `auth.uid()` must equal `p_creator_id`, and the caller must own `p_workspace_id` (`is_workspace_owner`). Otherwise raise `Not authorized`.
2. Drop the caller's own id and duplicates from `p_player_ids`. If nothing is left, raise `No players to add`.
3. Every remaining id must be "pickable": a member of a workspace the caller owns, or a participant in an event in a workspace the caller owns. Otherwise raise with message `'لا يمكن إضافة هذا اللاعب'`, hint `'player_not_pickable'`.
4. If `p_max_participants` is not null and the count > `p_max_participants`, raise with message `'عدد اللاعبين أكبر من المقاعد'`, hint `'too_many_players'`.
5. `perform set_config('tamrin.picked_players', array_to_string(ids, ','), true);` then call `create_event(...)`, passing every parameter through.
6. `insert into workspace_members (workspace_id, user_id) … on conflict do nothing`.
7. Seat each player the way `seat_registration_request_internal` does (`20261002100000_registration_settings.sql:395-401`): `payment_status` `'pending'` if `total_price > 0` else `'confirmed'`, `payment_declared_at` null or `now()`, `paid_price_per_person = price_per_person`, `payment_group_size = 1`. No unpaid-debt check (spec call 11). No approval or registration window (spec call 10).
8. `insert into push_outbox (user_id, type, event_id, actor_id) values (player, 'added_to_event', event_id, caller)`.

Plus a `before insert` trigger on `public.push_outbox`, `skip_invite_for_picked_players()`: when `new.type in ('event_invited', 'event_opened')` and `new.user_id::text = any(string_to_array(current_setting('tamrin.picked_players', true), ','))`, return null. Otherwise return new.

- [ ] **Step 1: Write the failing tests** (append to `pick_players_test.sql`, same fixture). Each one calls `create_event_with_players` as O on workspace A with a paid event (`p_total_price 100`, `p_max_participants 10`, a payment method row for A) unless noted:
  - `seats picked players`: picking `[P1]` → P1 has an `event_participants` row with `payment_status 'pending'`; P2 has none.
  - `whole group gets one push`: picking `[P1, P2]` → for the new event, P1 and P2 each have exactly one `push_outbox` row, of type `added_to_event`, with `actor_id = O`; zero `event_invited` rows for them.
  - `new member joins workspace`: picking `[P4]` into A → `workspace_members` has (A, P4).
  - `too many players`: `p_max_participants 1`, picking `[P1, P2]` → raises with hint `too_many_players`, and no event row exists for that name.
  - `stranger refused`: picking `[P3]` → raises with hint `player_not_pickable`; no seat, no event.
  - `organizer id ignored`: picking `[O, P1]` → only P1 is seated.
  - `free event seats confirmed`: `p_total_price 0`, picking `[P1]` → P1's row is `confirmed`.
  - `not owner refused`: as P1 on workspace A → raises `Not authorized`.

- [ ] **Step 2: Run to make sure they fail**

Run: same `psql … -f supabase/tests/pick_players_test.sql`
Expected: FAIL, `function public.create_event_with_players(...) does not exist`.

- [ ] **Step 3: Implement** the function and trigger in the migration; re-apply only the new migration file. Use `create or replace` / `drop trigger if exists` so it can be re-applied safely.

- [ ] **Step 4: Run the tests.** Expected: no exception. Also re-run `supabase/tests/create_event_goes_live_test.sql` and `supabase/tests/event_lifecycle_test.sql`; they must still pass (the trigger is a no-op without the setting).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261109100000_pick_players.sql supabase/tests/pick_players_test.sql
git commit -m "feat(db): create an event with picked players seated in one step"
```

### Task 3: Push copy for `added_to_event`

**Files:**
- Modify: `supabase/functions/send-push/copy.ts` (add a case to `copyFor`)
- Test: `supabase/functions/send-push/copy_test.ts`

**Interfaces:**
- Consumes: `CopyDetails.actorName` (already filled from `push_outbox.actor_id` in `index.ts:80-84`).

- [ ] **Step 1: Write the failing tests**

```ts
Deno.test("added_to_event names the organizer and the event", () => {
  const c = copyFor("added_to_event", "تمرين الخميس", { actorName: "نايف" });
  assertEquals(c, { title: "صار لك مقعد ⚽", body: "نايف أضافك إلى «تمرين الخميس»" });
});

Deno.test("added_to_event falls back when the organizer has no name", () => {
  const c = copyFor("added_to_event", "تمرين الخميس", { actorName: "  " });
  assertEquals(c?.body, "المشرف أضافك إلى «تمرين الخميس»");
});
```

- [ ] **Step 2: Run to make sure they fail**

Run:
```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD/supabase/functions/send-push:/app" denoland/deno:alpine test /app/copy_test.ts
```
Expected: the two new tests FAIL (`copyFor` returns null).

- [ ] **Step 3: Add the `"added_to_event"` case** with exactly the copy above; name fallback `"المشرف"`.

- [ ] **Step 4: Run the tests.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/copy.ts supabase/functions/send-push/copy_test.ts
git commit -m "feat(push): tell a player who added them to which event"
```

### Task 4: Client data — sources, pick, and the create call

**Files:**
- Create: `Sirr/core/supabase/PickPlayersService.swift`
- Modify: `Sirr/core/supabase/EventService.swift:509` (`createEvent`)

**Interfaces:**
- Produces (in `PickPlayersService.swift`):
  ```swift
  struct PickPerson: Decodable, Identifiable, Hashable { let id: UUID; let name: String; let avatarUrl: String? }   // keys user_id, name, avatar_url
  struct PickGroup: Decodable, Identifiable, Hashable { let id: UUID; let name: String; let lastPlayedAt: Date?; let members: [PickPerson] } // keys workspace_id, name, last_played_at, members
  struct PickSources: Decodable { let groups: [PickGroup]; let pastPlayers: [PickPerson]; var isEmpty: Bool { groups.isEmpty && pastPlayers.isEmpty } }
  struct PlayerPick: Equatable { var sourceGroup: PickGroup?; var selected: Set<UUID> }
  enum PlayerPickDestination: Equatable { case existing(workspaceId: UUID); case newWorkspace }
  extension PlayerPick { func destination(ownedGroups: [PickGroup]) -> PlayerPickDestination }
  final class PickPlayersService { static let shared; func getPickSources() async throws -> PickSources }
  ```
  `destination` rules: if `sourceGroup` is set and `selected` equals all its member ids → `.existing(sourceGroup.id)`. Else if `selected` is not empty and some group's member-id set equals `selected` → `.existing(that group's id)` (spec call 12). Else `.newWorkspace`.
  Decode dates with `EventService.makePostgresDecoder()`.
- Produces: `EventService.createEvent(…existing params…, playerIds: [UUID] = [])`. When `playerIds` is empty it behaves exactly as today. Otherwise it calls RPC `"create_event_with_players"` with the same params plus `"p_player_ids": .array(playerIds.map { .string($0.uuidString) })`, and decodes the same `EventRecord`.

- [ ] **Step 1: Write the code** above.
- [ ] **Step 2: Build-check**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS Simulator' build -quiet`
Expected: `** BUILD SUCCEEDED **` (or no error lines with `-quiet`).

- [ ] **Step 3: Commit**

```bash
git add Sirr/core/supabase/PickPlayersService.swift Sirr/core/supabase/EventService.swift
git commit -m "feat: client calls for picking players"
```

### Task 5: The pick screens (native SwiftUI)

**Files:**
- Create: `Sirr/features/home/PickPlayersStep.swift`

**Interfaces:**
- Consumes: Task 4 types; `MemberAvatar(name:size:imageData:imageUrl:)` for faces.
- Produces:
  ```swift
  struct PickPlayersStep: View {
      let sources: PickSources
      let seatLimit: Int?            // the event's max participants; nil = no limit
      let isSaving: Bool
      let confirm: (PlayerPick) -> Void
  }
  ```

Layout (spec "Following Apple's guidelines"):
- A `NavigationStack` whose root is an inset-grouped `List`:
  - First section: a `NavigationLink` row `Label("مجموعة جديدة", systemImage: "plus")` in the accent colour → people list over `sources.pastPlayers`, `sourceGroup = nil`. Hidden when `pastPlayers` is empty.
  - Section "مجموعاتك": one `NavigationLink` per group. Row: name; subtitle `"\(members.count) لاعب"` plus `lastPlayedAt` as relative date (`.formatted(.relative(presentation: .named))`) when present; up to 3 overlapping `MemberAvatar`s at the trailing edge.
- People list: `List(selection: $selected)` with `.environment(\.editMode, .constant(.active))`; row = `MemberAvatar` + name; `.searchable(text:)` filtering by name; section header `"\(selected.count) من \(people.count)"`; `.selectionDisabled(!selected.contains(id) && atLimit)` per row, and when `atLimit` a section footer `"اكتمل العدد (\(seatLimit))"`.
  - `ToolbarItem(placement: .bottomBar)`: "تحديد الكل" / "إلغاء التحديد" (select all respects `seatLimit`: picks the first `seatLimit` people).
  - `ToolbarItem(placement: .confirmationAction)`: "إضافة" → `confirm(PlayerPick(sourceGroup:selected:))`. Disabled while `isSaving`, and for an existing group while `selected` is empty. Shows `ProgressView()` while saving.
  - Empty `pastPlayers` or empty search results → `ContentUnavailableView`.
- `#Preview` with two groups and four past players.

- [ ] **Step 1: Write the view.**
- [ ] **Step 2: Build-check** (Task 4 command). Expected: succeeds.
- [ ] **Step 3: Commit**

```bash
git add Sirr/features/home/PickPlayersStep.swift
git commit -m "feat: pick a group and the players, with native lists"
```

### Task 6: Wire the step into `CreateTeamFlow` and `HomeStore`

**Files:**
- Modify: `Sirr/features/home/CreateTeamFlow.swift` (`CreationStep` at :49, `body` switch, `create()`, `goBack()`)
- Modify: `Sirr/features/home/MockHomeFeed.swift` (`createTeam(from:)` at :1693, `createEvents(from:startDate:in:)` at :1934)

**Interfaces:**
- Consumes: Tasks 4 and 5.
- Produces:
  ```swift
  enum CreateTeamOutcome { case newTeam(FeedTeam); case existingTeam(UUID) }
  func createTeam(from draft: TeamDraft, pick: PlayerPick? = nil, sources: PickSources? = nil) async throws -> CreateTeamOutcome
  ```
  `createEvents(from:startDate:in:playerIds: [UUID] = [])` passes `playerIds` to every `EventService.createEvent` call it makes.

Behaviour:
- `CreationStep` becomes `sport, identity, details, players, invite`. Title for `.players`: `"مين بيلعب معك؟"`. The counter leaves `.players` out of the total when `sources` is empty.
- The flow loads `PickSources` once in `.task` via `PickPlayersService.shared.getPickSources()`. On error, it treats the sources as empty, so the flow behaves exactly as today.
- Details step: when sources are empty, or still loading, "أنشئ التمرين" calls `create(pick: nil)` as today. Otherwise the button reads "التالي" and moves to `.players`.
- `.players` shows `PickPlayersStep(sources:seatLimit:isSaving:confirm:)`, with `seatLimit` = the same max-participants value `createEvents` sends for `plan`. `confirm` calls `create(pick:)`. `goBack` from `.players` → `.details`.
- `createTeam(from:pick:sources:)`:
  - `pick == nil` → today's path → `.newTeam`.
  - `pick.destination(ownedGroups: sources.groups) == .existing(id)` → no new workspace; `createEvents(from: draft.plans, startDate: draft.startDate, in: id, playerIds: Array(pick.selected))`; select that team, reload its data → `.existingTeam(id)`.
  - `.newWorkspace` → today's path (create workspace with the flow's own name, sport and colour), passing `playerIds: Array(pick.selected)`; on failure, delete the new workspace as today → `.newTeam`.
- After create: `.newTeam` → `.invite` step as today; `.existingTeam` → `Haptics.success()` and close the flow (`isPresented = false`).
- `OnboardingViews.swift:51` also opens `CreateTeamFlow`. A new user has empty sources, so nothing changes there.

- [ ] **Step 1: Make the changes.**
- [ ] **Step 2: Build-check** (Task 4 command). Expected: succeeds.
- [ ] **Step 3: Commit**

```bash
git add Sirr/features/home/CreateTeamFlow.swift Sirr/features/home/MockHomeFeed.swift
git commit -m "feat: last step of a new event picks the players"
```

### Task 7: Sandbox rollout and hand-over (ask Naif before each outward step)

- [ ] **Step 1:** Run every DB test again on the local stack and the Deno tests; all pass.
- [ ] **Step 2:** Give Naif paste-ready SQL (the whole `20261109100000_pick_players.sql`) for the **sandbox** SQL editor. Do not run it against any remote project yourself.
- [ ] **Step 3:** With Naif's yes, deploy `send-push` to the sandbox only: `supabase functions deploy send-push --project-ref kpcdinxusxycenfnitjc`.
- [ ] **Step 4:** Hand over for device testing on a Debug build, with this checklist:
  1. New account with no groups → flow is unchanged (no pick step).
  2. Pick a whole group → event lands in that group; each member gets one push «نايف أضافك إلى "…"».
  3. Tick some of a group → a new group with just them; the others don't see the event.
  4. Tick the same people again → the event goes into that same new group, no duplicate.
  5. مجموعة جديدة with nobody → invite step, as today.
  6. Seat limit stops extra ticks.
  7. A picked player can leave the event.
- [ ] **Step 5:** Prod is out of scope until Naif approves the App Store build (hand-run SQL then, per the branching rule).
