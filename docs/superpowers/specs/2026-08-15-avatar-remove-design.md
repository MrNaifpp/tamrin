# Removing a profile photo

## Problem

The avatar in `ProfileSettingsView` can be replaced but never cleared. The whole
avatar is a `PhotosPicker` label, so every tap opens the photo library — there is
no path back to "no photo". A user who uploads the wrong picture is stuck with
it.

Underneath, `HomeStore.saveProfile(name:avatarData:playerPosition:)` reads
`avatarData: nil` as *unchanged* (`if let avatarData { … }`, and `newUrl` starts
from the existing `avatarUrl`). The store has no way to express *removed*, so the
gap is in the data model, not only the UI.

## Scope

`ProfileSettingsView` only. It is the sole live profile editor, reached from
`DesignerHomeView.swift:409` and `AppSettingsView.swift:155`. `EditProfileSheet`
is presented only by `EventPageView`, which nothing instantiates.

Out of scope: the exercise avatar in `CreateTeamFlow`, which is broken end to end
for a different reason — `draft.avatarData` is collected but never uploaded, and
`mapTeam` hardcodes `avatarData: nil`.

## Design

### 1. Menu on the avatar

Conditional on whether a photo exists
(`avatarData != nil || feed.avatarUrl != nil`):

- **Photo present** — a `Menu` with «اختر صورة» and «حذف الصورة»
  (`role: .destructive`).
- **No photo** — an ordinary button opening the picker directly. A one-item menu
  is a dropdown of one.

The picker moves from being the label to the
`.photosPicker(isPresented:selection:matching:)` modifier, which is how SwiftUI
presents it from an action other than its own label.

### 2. Expressing removal

```swift
enum AvatarEdit { case unchanged, replaced(Data), removed }
```

replaces the `avatarData: Data?` parameter. Three states in one value, so
`data != nil && remove == true` cannot be written. `saveProfile` has a single
caller, so the change is contained.

Picking a photo produces `.replaced`; «حذف الصورة» produces `.removed`; picking
after removing goes back to `.replaced`.

### 3. Save path

`.removed` performs, in order:

1. clear `avatarData` and `avatarUrl` locally
2. `updateProfile(avatarUrl: nil)` — what makes the photo gone for everyone
3. `AuthService.deleteAvatar(userId:)` → `storage.remove(paths: ["<UUID>.jpg"])`

Database before file. A failed step 3 leaves an orphan nobody can reach through
the app, and the next upload overwrites it anyway since the path is fixed per
user. The reverse order would leave every roster pointing at a 404 if the
database write failed.

Deletion commits on «حفظ», like every other field in the sheet, so dismissing
without saving backs out.

### 4. `AuthService.deleteAvatar(userId:)`

Mirrors `uploadAvatar`: same file, same bucket, returns `Bool`, logs failures
with `privacy: .public`.

The Storage API is used rather than `delete from storage.objects` because the SQL
route removes only the metadata row and orphans the blob in the storage backend.
No edge function: the user is deleting their own object while signed in, which is
what the RLS policy authorizes.

### 5. Migration

A second migration adding a DELETE policy on `storage.objects`, with the same
predicate as the others:

```sql
bucket_id = 'tamrin-stg' and lower(name) = auth.uid()::text || '.jpg'
```

`lower(name)` because Swift's `UUID.uuidString` is uppercase while
`auth.uid()::text` is lowercase. Separate file, since
`20260815100000_avatar_storage_policies.sql` is already applied to sandbox.

## Verification

Build, then on device: remove a photo, save, relaunch — the initial shows rather
than the old photo — and confirm the public URL returns 404. That last check is
what proves the blob went, not just the row.
