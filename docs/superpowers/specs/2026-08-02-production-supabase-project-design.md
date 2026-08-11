# Production Supabase project

## Context

The app has always talked to a single Supabase project, `kpcdinxusxycenfnitjc`, hardcoded
in [`SupabaseClientManager.swift`](../../../Sirr/core/supabase/SupabaseClientManager.swift).
That project holds a mix of throwaway data and a few real testers, and it is also what the
approved 1.0 App Store build points at. Every experiment Naif or Faris runs on device writes
into it.

Version 1.1 is about to ship. Before it does, production gets its own project and the old one
becomes the development sandbox.

Intended outcome: a Release build — the configuration Archive, TestFlight and the App Store all
use — physically cannot reach the sandbox, and the production project is provisioned to the same
shape as the sandbox with nothing left as undocumented dashboard state.

## Decisions taken

| Question | Answer |
|---|---|
| Existing data | A mix; a few real testers. Production starts empty. Naif hand-copies any rows he wants. |
| Old project's fate | Stays alive as the development sandbox. |
| Environment selection | xcconfig files (chosen over compile-time `#if DEBUG`). |
| Email delivery | Resend SMTP, already working on the sandbox; copied to production. |

### The two projects

| | Sandbox (existing) | Production (new) |
|---|---|---|
| Ref | `kpcdinxusxycenfnitjc` | `hzsxwnmbdkrmipjtfzlp` |
| Used by | Debug builds | Release builds — Archive, TestFlight, App Store |
| APNs host | sandbox (default) | `https://api.push.apple.com` |
| Plan | Free | Free — Pro declined 2 August 2026 (see below) |

Both projects issue **legacy JWT `anon` keys**, confirmed on the new one (decodes to
`role: anon`, `ref: hzsxwnmbdkrmipjtfzlp`, expiry 2036). This matters: the newer
`sb_publishable_` format is recorded in
[`SupabaseClientManager.swift:16-18`](../../../Sirr/core/supabase/SupabaseClientManager.swift#L16)
as breaking `auth.uid()` inside RLS ([supabase#42235](https://github.com/supabase/supabase/issues/42235)),
and every policy across the 40 migrations depends on `auth.uid()`. Using the same key format in
both projects also means a bug found in the sandbox reproduces in production.

## Architecture: how the app picks a project

### Files

```
Config/Base.xcconfig             committed — shared settings, optional include of Local
Config/Debug.xcconfig            committed — sandbox values
Config/Release.xcconfig          committed — production values
Config/Local.xcconfig            GITIGNORED — per-developer signing
Config/Local.xcconfig.example    committed — template
```

`Base.xcconfig`:

```
// Per-developer signing lives in Local.xcconfig, which is gitignored. The `?`
// makes the include non-fatal, so a fresh clone builds before that file exists.
#include? "Local.xcconfig"

// Version lives here, not in the target, so a bump is tracked in git. Until now
// the 1.1 (2) bump existed only in Naif's working copy of project.pbxproj, so an
// archive from any other machine would have silently shipped 1.0 (1).
MARKETING_VERSION = 1.1
CURRENT_PROJECT_VERSION = 2
```

`Debug.xcconfig`:

```
#include "Base.xcconfig"

SUPABASE_HOST = kpcdinxusxycenfnitjc.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwY2Rpbnh1c3h5Y2VuZm5pdGpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk3ODc0MTUsImV4cCI6MjA4NTM2MzQxNX0.yKbHhYVZbvgU8QdCyYNrvG8rC7KtX5cqXPGpedHMJ_g
```

`Release.xcconfig`:

```
#include "Base.xcconfig"

SUPABASE_HOST = hzsxwnmbdkrmipjtfzlp.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6c3h3bm1iZGtybWlwanRmemxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU2NTcwOTksImV4cCI6MjEwMTIzMzA5OX0.Opjcn6HMOWdw07RPDEXGaytKziAsnvvJSzpzuw8NiPY
```

Anon keys are public by design — they ship inside the app binary, and RLS is what protects the
data. Committing them is correct, not a leak.

`Local.xcconfig.example` carries empty `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` for
each developer to fill in with their own team and bundle id.

### Value flow

xcconfig → build setting → `Sirr/Info.plist` → Swift. Two keys are added to the existing
committed `Sirr/Info.plist`:

```xml
<key>SUPABASE_HOST</key>
<string>$(SUPABASE_HOST)</string>
<key>SUPABASE_ANON_KEY</key>
<string>$(SUPABASE_ANON_KEY)</string>
```

A new `Sirr/core/supabase/SupabaseEnvironment.swift` reads them:

```swift
enum SupabaseEnvironment {
    static let host = value("SUPABASE_HOST")
    static let anonKey = value("SUPABASE_ANON_KEY")

    static var url: URL { URL(string: "https://\(host)")! }

    /// Traps rather than falling back. A build whose xcconfig is not wired to
    /// its configuration must fail at launch, not quietly point somewhere else.
    private static func value(_ key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty, !raw.hasPrefix("$(")
        else { fatalError("Info.plist is missing \(key) — is the xcconfig wired to this configuration?") }
        return raw
    }
}
```

`SupabaseClientManager` then constructs its client from `SupabaseEnvironment`. Nothing else in
the app changes.

### Two gotchas this design works around

**`//` starts a comment in xcconfig.** Writing `SUPABASE_URL = https://x.supabase.co` silently
truncates the value to `https:`. That is why the config stores a bare host and Swift prepends
the scheme. Anon keys are base64url (`-` and `_`, never `/`), so they pass through untouched.

**An unwired configuration produces the literal string `$(SUPABASE_HOST)`.** The `hasPrefix("$(")`
check turns that into an immediate, legible crash instead of a confusing network failure.

## Unlocking `project.pbxproj`

`project.pbxproj` has never been committable because it holds each developer's
`DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` (Naif: `V2PFCP3D26` /
`com.businessech.tmrin`; Faris: `27WKP3HRAX` / `com.farisabumalih.tmrin`). Committing it breaks
the other developer's code signing.

Moving those two settings into the gitignored `Local.xcconfig` removes everything personal from
the file, so it becomes committable — permanently. That is a real side benefit of choosing
xcconfig over `#if DEBUG`.

Reaching it needs **one coordinated `project.pbxproj` commit**:

1. Wire the xcconfigs in Xcode: Project ▸ Info ▸ Configurations, set Debug and Release to their
   files. This writes `baseConfigurationReference` entries. Only `Debug.xcconfig` and
   `Release.xcconfig` need to be added to the project navigator — `Base.xcconfig` and
   `Local.xcconfig` are pulled in by `#include` and must **not** be added, which is what lets
   the gitignored one stay invisible to the project file.
2. **Delete** `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`, `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` from the target's Debug *and* Release build settings. A setting
   present in the pbxproj overrides the xcconfig, so leaving them there makes the whole exercise
   a no-op.
3. `grep` the file to prove none of those names survive anywhere.
4. **Share the scheme.** Run→Debug and Archive→Release currently lives in gitignored
   `xcuserdata`, so the guarantee this whole design rests on is per-machine and absent from git.
   Ticking "Shared" in Manage Schemes writes
   `Sirr.xcodeproj/xcshareddata/xcschemes/Sirr.xcscheme`, which is committed.
5. Tell Faris before pushing. He pulls, copies the example to `Local.xcconfig`, fills in his
   team and bundle id, and builds.

Blast radius if it goes wrong: Faris cannot sign until he creates that one file. Recoverable in
a minute, and it is the last time this file causes trouble.

Also add to `.gitignore`:

```
Config/Local.xcconfig
```

## Provisioning the production project

Naif drives this; the database password never leaves his password manager.

**Step 0 — rehearse the replay locally.** `supabase db reset` against local Docker replays all
40 migrations from an empty database. Several are `fix_*` migrations authored against a live
state, so a clean-slate replay is exactly the thing that might fail. Discovering that locally is
free; discovering it midway through provisioning production is not.

Then, in order:

1. **Create the project** in the region closest to Saudi users. Save the database password.
2. **Push the schema** — `supabase link --project-ref hzsxwnmbdkrmipjtfzlp`, then
   `supabase db push`. Link rewrites `supabase/.temp/project-ref`, which is gitignored, so the
   repo is unaffected. **Re-link back to the sandbox afterwards**, or the next casual `db push`
   lands on production.
3. **Verify cron** — `select jobname, schedule from cron.job;` must show `event-reminders-am`,
   `event-reminders-pm` and `recurring-events`. Schedules are UTC; `0 5` and `0 17` are 8am and
   8pm Riyadh, unchanged from the sandbox.
4. **Deploy the function** — `supabase functions deploy send-push --project-ref hzsxwnmbdkrmipjtfzlp`.
5. **Six Edge Function secrets.** `APNS_AUTH_KEY`, `APNS_KEY_ID` and `APNS_TEAM_ID` are the same
   Apple key as the sandbox. `APNS_BUNDLE_ID` is `com.businessech.tmrin`. `APNS_HOST` is
   `https://api.push.apple.com` — the sandbox keeps the default. `SEND_PUSH_SECRET` is
   **freshly generated**; reusing the sandbox value would let a leak from the dev project drive
   production pushes.
6. **Two Vault secrets** per [push-db-settings.md](../plans/push-db-settings.md), using the new
   function URL `https://hzsxwnmbdkrmipjtfzlp.supabase.co/functions/v1/send-push`.
   `send_push_secret` must match step 5 byte-for-byte or the trigger gets a 401 and pushes stop
   silently.
7. **Auth configuration.** Site URL and redirect URLs point at
   `https://guileless-squirrel-b6537a.netlify.app` plus the `sirr://` scheme. Enable Sign in with
   Apple with client id `com.businessech.tmrin`. Email confirmations **off**, matching current
   behaviour. Copy the Resend SMTP settings across. **Raise the email rate limit** — Supabase
   defaults to 2 emails per hour and that cap still applies after custom SMTP is attached, which
   would throttle real signups on launch day.
8. **Upgrade to Pro.** Free projects pause after roughly a week of inactivity, which for
   production means the app dies during any quiet stretch.

## Storage: deliberately unchanged

The avatar bucket is **not** part of this work, by decision on 2 August 2026.

The upload path is fully wired — `PhotosPicker` in
[`SignupView`](../../../Sirr/features/auth/SignupView.swift#L214),
[`EditProfileSheet`](../../../Sirr/features/profile/EditProfileSheet.swift#L170) and
[`ProfileSettingsView`](../../../Sirr/features/home/ProfileSettingsView.swift#L100), all reaching
`AuthService.uploadAvatar` and its hardcoded `tamrin-stg` bucket. But
[`uploadAvatar`](../../../Sirr/core/supabase/AuthService.swift#L239) catches every error and
returns nil, and each caller silently falls back to the previous URL, so a missing bucket and a
working upload look identical from the app.

Naif's call is to carry that behaviour forward untouched rather than fix it as part of standing
up production. `AuthService.swift` is therefore left alone, and no `SUPABASE_AVATAR_BUCKET` key
goes into the xcconfigs — adding per-environment plumbing for a code path that does not work
would be machinery with nothing behind it.

**Known consequence:** the production project comes up with no storage bucket, so choosing a
profile photo there does nothing, exactly as today. Whenever avatars are picked up properly, the
work is a bucket plus its RLS policies in a migration, applied to both projects, and making the
failure visible instead of swallowed.

## Landing page

`~/Documents/tamrin-landing-page` is a **separate repository**, deployed to Netlify, and nothing
in it lands on this repo's `staging` branch. It is tracked here only so it is not forgotten.

If its `/join/<code>` page queries Supabase to render an invite preview, it needs the production
host and anon key; if the page is static, there is nothing to do. It can only serve one project,
and production is the right choice — invite links generated by sandbox builds then render no
preview, which is fine for development.

## Verification

1. Local `supabase db reset` replays all migrations from empty with no errors.
2. `xcodebuild` succeeds for **both** Debug and Release. Build check only — Naif tests on device,
   no simulator boots.
3. A Debug launch logs the resolved host, so which project is in use is visible at a glance.
4. A fresh signup from a **Release** build creates its row in production and **not** in the
   sandbox — checked by querying both.
5. Creating an event writes a `push_outbox` row and the notification arrives on device.
6. An invite link joins a workspace.
7. `select jobname from cron.job` on production returns the three jobs.

Avatar upload is deliberately absent from this list — see "Storage: deliberately unchanged".

## Out of scope

- Hand-copying tester data from the sandbox — Naif does this manually, no tooling.
- The avatar storage bucket, and therefore avatar upload on production. Decided 2 August 2026;
  reasoning and consequences in "Storage: deliberately unchanged" above.
- The landing page repo. Separate repository, separate deploy, tracked here only as a reminder.
- Upgrading production to Pro. Declined 2 August 2026. Free projects pause after about a week
  with no API requests, which a live app makes unlikely — but the window between provisioning
  and App Store approval is exactly such a gap. If production pauses, un-pausing is a dashboard
  button, and the reminder cron does not run while it is down.
- Driving `aps-environment` from xcconfig. It is hardcoded to `development` in
  [`Sirr.entitlements`](../../../Sirr/Sirr.entitlements), but `send-push` already falls back to
  the sibling APNs host on `BadDeviceToken`, so tokens from either environment still deliver.
- Retiring or deleting the old project. It becomes the sandbox and stays.
- Fixing `uploadAvatar`'s missing `upsert`. Uploading to an existing `<uid>.jpg` fails, so
  changing an avatar a second time silently keeps the old picture. Real bug, unrelated to this
  work, deserves its own fix.

## Risks

**Every future migration must be applied twice.** This is the standing cost of two environments.
`supabase db push` against the wrong ref is the likely failure, which is why step 2 ends by
re-linking to the sandbox.

**The one pbxproj commit.** Covered above; mitigated by grepping before pushing and telling
Faris first.

**Migrations that cannot replay from zero.** Unknown until step 0 runs. If one fails, it is
repaired as part of this work — a migration set that cannot rebuild the database from scratch is
a latent problem regardless of this project.
