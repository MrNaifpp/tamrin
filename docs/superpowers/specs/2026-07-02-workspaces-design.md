# Workspaces — Design

**Date:** 2026-07-02
**Status:** Approved (brainstormed with visual companion; UI mockups in `.superpowers/brainstorm/17795-1782942825/content/`)

## Summary

Workspaces become the core container of Tamrin. A workspace is a private group of people (e.g. شباب الحي); **every event belongs to exactly one workspace**, and only workspace members can see or join its events. People enter a workspace via an invite link. The app runs in "current workspace" mode (Slack-style): the home feed shows one workspace's events, with a switcher to change.

Confirmed product decisions:

| Decision | Choice |
|---|---|
| Centrality | Everything is a workspace — `events.workspace_id` is required |
| Roles | One **owner** + equal **members**; any member creates events |
| Joining | Invite link (universal link), no approval step |
| Privacy | Strictly private — non-members cannot view or join workspace events; outsider event-share links are retired |
| Navigation | Current-workspace mode with a switcher |
| Migration | Test data only — simple backfill, old share links may break |
| Architecture | RPC-centric (SECURITY DEFINER RPCs carry permission checks, matching the existing codebase pattern), RLS as backstop |

Unchanged: the payment flow (manual STC Pay, event creator confirms), guest participant rows, waitlist, twice-daily reminders.

## Data model

**New table `workspaces`:**

| column | type | notes |
|---|---|---|
| `id` | uuid PK | |
| `name` | text NOT NULL | |
| `owner_id` | uuid NOT NULL → auth.users | |
| `invite_code` | text UNIQUE NOT NULL | random URL-safe token (~12 chars), owner can regenerate |
| `image_url` | text NULL | column reserved; no v1 UI |
| `created_at` | timestamptz | |

**New table `workspace_members`:**

| column | type | notes |
|---|---|---|
| `workspace_id` | uuid → workspaces (cascade) | composite PK |
| `user_id` | uuid → auth.users (cascade) | composite PK |
| `joined_at` | timestamptz | |

The owner also has a member row, so "members of X" is always one query.

**`events`:** add `workspace_id` uuid NOT NULL → workspaces (cascade delete), indexed. `creator_id` keeps its meaning: who runs the event and confirms its payments.

**Lifecycle rules:**
- Deleting a workspace cascades to members and events (events already cascade to participants/waitlist); related `push_outbox` rows are cleaned like `delete_event` does today.
- The owner cannot leave — only delete. (Ownership transfer is a future feature.)
- A member who leaves (or is removed) also loses their participant rows on that workspace's **upcoming** events; past events keep history.

**Migration (backfill, test data only):** one migration adds the tables, then for each distinct `events.creator_id` creates a personal workspace named from `users.name` (fallback "مساحتي"), inserts owner membership, points that creator's events at it, and adds each existing event participant as a workspace member. Then `events.workspace_id` is set NOT NULL.

## Backend — RPCs and RLS

All new RPCs are SECURITY DEFINER and derive the caller from **`auth.uid()`** — they do not trust a client-passed user id. (Existing RPCs keep their `p_user_id` signatures for now; tightening them is a separate cleanup.)

**New RPCs:**

| RPC | access | behavior |
|---|---|---|
| `create_workspace(p_name)` | any user | insert workspace + invite code + owner member row |
| `get_my_workspaces()` | any user | caller's workspaces with member counts (switcher list) |
| `get_workspace(p_workspace_id)` | member | details + member list |
| `get_workspace_by_invite(p_code)` | anyone | preview: name, owner name, member count (join screen) |
| `join_workspace(p_code)` | anyone | insert membership; idempotent if already a member |
| `leave_workspace(p_workspace_id)` | member, not owner | delete membership + caller's participant rows on upcoming events |
| `remove_member(p_workspace_id, p_user_id)` | owner | same cleanup as leave |
| `update_workspace(p_workspace_id, p_name)` | owner | rename |
| `regenerate_invite_code(p_workspace_id)` | owner | new token; old link dies |
| `delete_workspace(p_workspace_id)` | owner | cascade delete + push_outbox cleanup |
| `get_workspace_events(p_workspace_id)` | member | upcoming events of the workspace (`coalesce(end_date, start_date) >= now()`); replaces `getEventsForCurrentUser()` as the feed query |

**Changed RPCs:**
- `create_event(...)` gains `p_workspace_id`; caller must be a member.
- `join_event`, `submit_payment`, `join_waitlist`: add a guard — caller must be a member of the event's workspace.
- `get_event_by_id`: member-gated. This enforces "strictly private" and retires the outsider `SharedEventView` flow.

**RLS:** new helper `is_workspace_member(p_workspace_id, p_user_id)` (SECURITY DEFINER, avoids policy recursion — same trick as `get_event_ids_visible_to_user()`). SELECT policies on `workspaces`, `workspace_members`, and `events` use it. Mutations remain RPC-only.

**Untouched:** payment RPCs' logic, guest rows (`user_id NULL`, `added_by`), waitlist mechanics, `enqueue_event_reminders()` (participant-based, workspace-agnostic).

## Invite links

- URL: `https://guileless-squirrel-b6537a.netlify.app/join/{code}`, fallback `sirr://join/{code}` — same universal-link infra as event links.
- `landing/` gets a `/join/{code}` page mirroring the event page.
- `AppState.handleDeepLink` parses the `join` segment; logged-out users get the existing store-and-resume-after-login behavior.
- Event deep links (`…/event/{id}`) remain for push-notification taps and member-to-member sharing. A **non-member** opening one sees an error: "هذا الحدث في مساحة خاصة — اطلب دعوة من صاحبها".

## iOS app

**Models/services:** `Workspace`, `WorkspaceMember` models; `WorkspaceService` in `core/supabase/` mirroring `EventService` (one method per RPC). `AppState` gains `currentWorkspaceId` (persisted in UserDefaults) and a pending-join-code deep-link slot.

**UI (mockups approved):**
- **Home** (`EventPageView`): card feed stays, fed by `get_workspace_events(currentWorkspaceId)`. A **workspace avatar button** (colored initial, deterministic color from workspace id) in the toolbar opens a **half-sheet switcher**: workspace rows with avatars, active one highlighted, plus a "مساحة جديدة" row. (Chosen: option B, Slack-style.)
- **Workspace settings sheet** (chosen: option A, single half-sheet — same pattern as `EventSettingsSheet`): workspace identity header, "🔗 مشاركة رابط الدعوة" button, member list (owner sees inline إزالة per member), rename, regenerate-link, and حذف المساحة (owner) / مغادرة المساحة (member) at the bottom.
- **Join screen** (from invite link): workspace icon, "دعاك {owner} للانضمام", stacked member avatars + count, big "انضمام" button, "ليس الآن". On join → switch `currentWorkspaceId` to it.
- **Empty state** (zero workspaces, e.g. fresh account): "ابدأ مساحتك الأولى" with two actions — "إنشاء مساحة" (single name field) and "عندي رابط دعوة" (paste-a-link field). No auto-created personal workspace on signup.
- **`NewEventView`**: creates into the current workspace (no picker).
- **Push taps**: set `currentWorkspaceId` to the event's workspace before opening the event detail.
- **`SharedEventView`**: outsider flow removed; non-member event links show the private-workspace error.

## Testing

- **Migration test** on the local Supabase stack: seed old-model data, apply, assert every event has a workspace and every former participant is a member.
- **RPC guard tests** (SQL): non-member `join_event` / `get_event_by_id` / `get_workspace_events` fail; member-only and owner-only ops reject the wrong callers; `leave_workspace` clears upcoming participant rows but not past ones; `join_workspace` idempotent; regenerated code kills the old link.
- **Manual simulator pass** (two accounts): create workspace → share invite → join → see feed → create event → join event → STC Pay flow unchanged → leave/remove flows.

## Rollout

Nothing is live: ship as one batch of migrations plus the app changes on `phase_1`. No compatibility window; old outsider event links are allowed to break.

## Out of scope (future)

- Admin roles / promoting members; ownership transfer
- Join-approval mode; user search
- Workspace images, chat, media, stats ("later we can do more")
- Payment gateway integration (separately planned)
- Tightening legacy `p_user_id` RPC signatures to `auth.uid()`
