# New event: pick the players from your groups

Date: 2026-11-09
Status: approved by Naif 2026-11-09 ("start implement")

## Why

An organizer who wants to play again with people from an earlier event has
no quick way to bring them in. Today you open a team first, and every event
in it goes to every member. There is no way to say "this event is for these
8 people" and no way to start from home and choose the group last.

Success: from home, an organizer can make an event and have the right
people in it, each told by push, in one flow.

## The flow (Naif's design)

1. **Start.** Home → the existing **+** in the top bar → the existing
   **تمرين جديد** card in the add sheet. No new button and no new card.
   The flow does not start inside a team.
2. **Details: the existing steps, unchanged.** The card keeps opening
   `CreateTeamFlow` with its current steps (sport, name, schedule, place,
   seats, price). Nothing is removed. **The new pick step is added at the
   end, before the invite step.**
   - **A new organizer** (no groups of their own and nobody from past
     events) never sees the new step. For them nothing changes.
3. **Pick a group (new step).** The organizer sees their groups: each with a few
   member faces, the member count, and when they last played. Below them
   is **+ مجموعة جديدة**.
4. **Pick the people.**
   - **From an existing group:** the group's members, each with a tick,
     plus "select all", and a button "أضف N لاعبين".
     - **Everyone ticked** → the event goes into that same workspace.
     - **Only some ticked** → a **new workspace** is made with just those
       people, and the event goes there. The others don't see it.
   - **From + مجموعة جديدة:** the list is everyone who has been in any
     event this organizer ran. The organizer ticks anyone, or nobody. A new
     workspace is made with the picked people, and the event goes there.
5. **They're in.** Each picked person gets a seat in the event at once,
   and a push: **«<organizer name> أضافك إلى "<event name>"»**.
6. **They can leave later**, the same way any player leaves an event.

The visual mockups are in `.superpowers/brainstorm/` (not committed):
`pick-group.html` (steps 3 and 4) and `flow-v3.html` (the whole flow).

## Terms

- **Group = workspace.** No separate "saved group" object. A group in this
  flow is a workspace the organizer **owns** (only owners can create events
  today: `create_event` checks `is_workspace_owner`).

## Goals

- Start a new event from home without choosing a team first.
- Bring back people from earlier events in a few taps.
- Picked people are seated and told who added them, to which event.
- An event made for some people stays hidden from the rest.

## Non-goals

- No invite-and-accept step. Picked people are added straight in.
- No new home button or new card in the add sheet.
- No change to how payment works (manual STC Pay; cards stay off in prod).
- No "saved groups" separate from workspaces.

## Anti-goals (would count as failure even if it works)

- Members who were not ticked see the event or get a push for it.
- Name-only people (manual participants, guests) show up as if they could
  be added to a workspace. They have no account.
- A push that doesn't name the organizer and the event.

## How things work today (for the builder)

- Events always live in a workspace (`events.workspace_id`). Workspaces
  have one owner plus equal members (`workspace_members`).
- People join a workspace only by invite code (`join_workspace`). There is
  no server function for an owner to add a user to a workspace directly.
- An organizer can add only **name-only** people to an event
  (`add_manual_participant`, seat confirmed straight away, money handled
  outside the app). There is no function to add a real app user to an
  event.
- Pushes go through `push_outbox` → `send-push`. The copy lives in
  `supabase/functions/send-push/copy.ts`; it already supports an
  `actorName` for copy that names who acted.
- "تمرين جديد" currently opens `CreateTeamFlow`
  (`Sirr/features/home/CreateTeamFlow.swift`), which makes a workspace
  with a sport, weekly schedule template, and invite link. The add sheet is
  `HomeQuickAddSheet` in `Sirr/features/home/DesignerHomeView.swift`.
  The older event form is `Sirr/pages/NewEventView.swift`.

## Calls I made (Naif to check)

These were not decided in the conversation; they are my defaults.

1. **Added people owe the price** like any player who registers: their
   seat is held with payment pending, and the usual payment reminders and
   rules apply.
2. **Seat limit.** The organizer cannot tick more people than the event
   has seats.
3. **New workspace name** = the event name. The owner can rename it later
   in the existing workspace settings.
4. **Picking nobody** makes a workspace with just the organizer, then shows
   the invite link to share (as `CreateTeamFlow` does today).
5. **The organizer is the owner** of any new workspace made by this flow.
6. **Only app users** appear in the "+ مجموعة جديدة" list. Name-only
   people are left out.
7. **Picked people become members** of the new workspace, so they see its
   future events too, and can leave it with the existing leave option.

8. **Payment methods** come from the flow's own details step, saved into
   whichever workspace the event lands in (as `persistPaymentMethods`
   does today).
9. **Sport, colour and name** of a new workspace come from the flow's own
   first steps, as today. Registration settings use the defaults.
10. **Publish at once.** The event is published as soon as the flow ends.
    Picked people get only the "added you" push, not the usual
    `event_invited` push, because they're already in. Picked people skip
    the group's manual approval and registration window, because the
    organizer chose them.
11. **Unpaid debt.** The organizer may add anyone, including someone who
    owes elsewhere. An added seat that is never paid counts as debt, like
    any other unpaid seat. The person can leave before the event to avoid
    that.

12. **No duplicate groups.** If the organizer ticks exactly the same people
    as a group they already own, the event goes into that group instead
    of making another one.

## Following Apple's guidelines (HIG)

The build follows the standard iOS patterns below. Where these differ from
the mockups, these win.

- **Apple's own components only (Naif's rule).** Every screen in this flow
  is built from Apple's SwiftUI components: `NavigationStack`, `List`,
  `Form`, `Section`, `TextField`, `DatePicker`, `Stepper`, `Toggle`,
  `LabeledContent`, `Button`, `ContentUnavailableView`, `.searchable`,
  `.toolbar`. No hand-drawn copies of them (no custom tick circles, step
  bars, fake text fields or custom sheets). Styling goes through standard
  modifiers only; the app's font and accent colour stay.
- **Scope of this rule:** the new steps (3 and 4). The existing
  `CreateTeamFlow` steps stay as they are.

- **One sheet, standard navigation.** The flow is a sheet with a
  `NavigationStack`. Each step is a pushed screen with the system back
  button and a navigation title. "إلغاء" sits top-leading and the confirm
  action top-trailing (`.cancellationAction` / `.confirmationAction`).
  There's no custom header or progress bar.
- **Group list (step 3).** An inset grouped `List`. Each group is a row
  with a disclosure chevron that pushes the people screen. "مجموعة جديدة"
  is the first row, with a `plus` symbol in the accent colour, like
  "New Group" lists in Apple's own apps.
- **People list (step 4).** A `List` with multiple selection
  (`List(selection:)` in edit mode), so selection circles sit at the
  **leading** edge (the right in Arabic) and VoiceOver reads "selected"
  for free. "تحديد الكل" / "إلغاء التحديد" goes in the toolbar.
  `.searchable` finds a name in long lists. A section header shows
  "٨ من ١٤".
- **Confirm.** The top-trailing button reads "إضافة" and is disabled
  until the step is valid. No floating bottom button.
- **Seat limit.** When the seats are full, the unticked rows dim and turn
  off, and a footer line says why. No alert.
- **Empty states.** `ContentUnavailableView` when the organizer has no
  groups, or no past players.
- **Finish.** The sheet closes and opens the new event (the existing
  `onCreated` path), with a success haptic.
- **The push.** It names who acted and the event, with no app name in the
  text. Tapping it opens the event.
- **Accessibility and RTL.** Dynamic Type, VoiceOver labels on every row,
  and the layout mirrors through the app's `layoutDirection`.

## Left to the builder

- Server shape: whether creating the workspace, the event, the members,
  the seats and the pushes is one database function or several. It must
  not leave half-made state (a workspace with no event, seats with no push).
- The new push type name and its exact title line.
- How "when they last played" is worked out for each group.

## Constraints

- Work on `staging`; `main` only gets App Store-approved code.
- Debug builds use the sandbox Supabase project. Never `db push` prod;
  prod SQL is hand-run after the build is approved.
- Never commit `project.pbxproj`.
- Arabic first, right-to-left; follow Apple's HIG patterns.
- Naif tests on his device; build-check only, no simulators.
