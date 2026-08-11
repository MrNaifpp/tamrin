# Production Supabase Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give production its own Supabase project (`hzsxwnmbdkrmipjtfzlp`), demote the existing project (`kpcdinxusxycenfnitjc`) to a development sandbox, and select between them by build configuration so a Release build cannot reach the sandbox.

**Architecture:** xcconfig files set `SUPABASE_HOST` and `SUPABASE_ANON_KEY` per configuration. Those flow into the committed `Sirr/Info.plist` via `$(VAR)` substitution, and a new `SupabaseEnvironment` enum reads them at runtime. Per-developer signing moves into a gitignored `Config/Local.xcconfig`, which finally makes `project.pbxproj` free of personal values and therefore committable.

**Tech Stack:** Swift 5 / SwiftUI, supabase-swift 2.41.0, Xcode project `objectVersion = 77`, Supabase CLI, Postgres migrations, Deno Edge Functions.

## Global Constraints

- Branch: all work lands on `staging`. Never merge to `main` — that is Naif's call after App Store acceptance.
- **Never boot a simulator.** Build checks only; Naif tests on device.
- Build check command: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration <Debug|Release> -destination 'generic/platform=iOS Simulator' build`
- The project has **no test target**. Every task's gate is a build check plus a named observable check, not a unit test. Do not invent a test target.
- Naif alone runs anything needing the database password. Never ask for it, never handle it.
- Sandbox ref: `kpcdinxusxycenfnitjc`. Production ref: `hzsxwnmbdkrmipjtfzlp`.
- Both projects use the **legacy `anon` JWT** key. Never `sb_publishable_` — it makes `auth.uid()` return NULL in RLS.
- In xcconfig, `//` begins a comment. Never put a full `https://` URL in an xcconfig value.
- **Do not touch `AuthService.uploadAvatar` or any storage bucket.** Decided out of scope on 2 August 2026; see the spec's "Storage: deliberately unchanged".
- SourceKit "Cannot find type" diagnostics are indexer noise. `xcodebuild` exit code is authoritative.

---

### Task 1: xcconfig files, inert

Creates the configuration files without wiring them to anything. The build must be unaffected, which is what makes this task independently reviewable: if the build changes, something is wrong before any risk has been taken.

**Files:**
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`
- Create: `Config/Local.xcconfig.example`
- Create: `Config/Local.xcconfig` (gitignored, Naif's machine)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: build settings `SUPABASE_HOST`, `SUPABASE_ANON_KEY`, `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` — consumed by Task 2 (wiring) and Task 3 (Info.plist).

- [ ] **Step 1: Create `Config/Base.xcconfig`**

```
// Settings shared by every configuration.
//
// Per-developer signing lives in Local.xcconfig, which is gitignored because
// Naif and Faris sign with different teams and bundle ids. The `?` makes the
// include non-fatal, so a fresh clone still builds — it just will not sign
// until the developer creates their own copy from Local.xcconfig.example.
#include? "Local.xcconfig"

// Version lives here, not in the target, so a bump is tracked in git. It used
// to sit only in Naif's working copy of project.pbxproj, which meant an
// archive from Faris's machine would have silently shipped 1.0 (1).
MARKETING_VERSION = 1.1
CURRENT_PROJECT_VERSION = 2
```

- [ ] **Step 2: Create `Config/Debug.xcconfig`**

```
#include "Base.xcconfig"

// Development sandbox. Debug is what Xcode's Run action uses; Archive uses
// Release, so nothing built for TestFlight or the App Store can land here.
SUPABASE_HOST = kpcdinxusxycenfnitjc.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwY2Rpbnh1c3h5Y2VuZm5pdGpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk3ODc0MTUsImV4cCI6MjA4NTM2MzQxNX0.yKbHhYVZbvgU8QdCyYNrvG8rC7KtX5cqXPGpedHMJ_g
```

- [ ] **Step 3: Create `Config/Release.xcconfig`**

```
#include "Base.xcconfig"

// Production. Reached by Archive, TestFlight and the App Store.
SUPABASE_HOST = hzsxwnmbdkrmipjtfzlp.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6c3h3bm1iZGtybWlwanRmemxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU2NTcwOTksImV4cCI6MjEwMTIzMzA5OX0.Opjcn6HMOWdw07RPDEXGaytKziAsnvvJSzpzuw8NiPY
```

Anon keys are public by design — they ship inside the app binary and RLS is what protects the data. Committing them is correct.

- [ ] **Step 4: Create `Config/Local.xcconfig.example`**

```
// Copy this file to Config/Local.xcconfig and fill in your own values.
// Config/Local.xcconfig is gitignored — it is the reason project.pbxproj no
// longer carries anyone's personal signing settings.
//
// Find your team id at developer.apple.com ▸ Membership.
DEVELOPMENT_TEAM =
PRODUCT_BUNDLE_IDENTIFIER =
```

- [ ] **Step 5: Create `Config/Local.xcconfig` with Naif's values**

```
DEVELOPMENT_TEAM = V2PFCP3D26
PRODUCT_BUNDLE_IDENTIFIER = com.businessech.tmrin
```

- [ ] **Step 6: Add the gitignore entry**

Append to `.gitignore` under the existing `## Secrets — never commit` block:

```
## Per-developer signing (see Config/Local.xcconfig.example)
Config/Local.xcconfig
```

- [ ] **Step 7: Verify git ignores the local file and tracks the rest**

Run: `git status --short Config/`

Expected: `?? Config/Base.xcconfig`, `?? Config/Debug.xcconfig`, `?? Config/Release.xcconfig`, `?? Config/Local.xcconfig.example`. **`Config/Local.xcconfig` must NOT appear.** If it does, the gitignore entry is wrong — fix it before continuing.

- [ ] **Step 8: Verify the build is unaffected**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Expected: `** BUILD SUCCEEDED **`. Nothing is wired yet, so this proves only that adding the files broke nothing.

- [ ] **Step 9: Commit**

```bash
git add Config/Base.xcconfig Config/Debug.xcconfig Config/Release.xcconfig Config/Local.xcconfig.example .gitignore
git commit -m "build: add xcconfig files for sandbox and production Supabase

Not wired to any configuration yet — that is the next commit, and it is the
one that touches project.pbxproj. Splitting them keeps the risky change to a
diff a reviewer can read on its own."
```

---

### Task 2: Wire the xcconfigs and strip personal values from `project.pbxproj`

The one risky task. It edits `project.pbxproj` and then commits it — something this repo has never done, because the file has always held whichever developer's signing values were last written into it.

**Files:**
- Modify: `Sirr.xcodeproj/project.pbxproj`
- Create: `Sirr.xcodeproj/xcshareddata/xcschemes/Sirr.xcscheme` (via Xcode, Step 6)

**Interfaces:**
- Consumes: the four xcconfig files from Task 1.
- Produces: a `project.pbxproj` free of `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, with `baseConfigurationReference` set on both project-level configurations, plus a shared scheme fixing Run→Debug and Archive→Release. Task 3 depends on the settings resolving.

**Object ids in play** (read from the current file, do not guess):
- Project-level configs: `5A8B1AB92E8AE2EB00BA3398` (Debug), `5A8B1ABA2E8AE2EB00BA3398` (Release)
- Target-level configs: `5A8B1ABC2E8AE2EB00BA3398` (Debug), `5A8B1ABD2E8AE2EB00BA3398` (Release)
- Main group: `5A8B1AA72E8AE2E900BA3398`

The xcconfigs attach at **project** level; the personal settings are deleted at **target** level. That direction matters — a setting present on the target overrides the project's xcconfig, so leaving them in place would make the whole change a no-op that still appears to work.

- [ ] **Step 1: Back up the file**

```bash
cp Sirr.xcodeproj/project.pbxproj /tmp/project.pbxproj.backup
```

If any later step produces a project Xcode cannot open, restore with
`cp /tmp/project.pbxproj.backup Sirr.xcodeproj/project.pbxproj`.

- [ ] **Step 2: Apply the edits**

Write this to `/tmp/wire_xcconfig.py` and run it with `python3 /tmp/wire_xcconfig.py`:

```python
import sys

PATH = "Sirr.xcodeproj/project.pbxproj"
src = open(PATH).read()

CFG_GROUP   = "DCA0C0F12F8B000100000001"
DEBUG_REF   = "DCA0C0F22F8B000100000002"
RELEASE_REF = "DCA0C0F32F8B000100000003"

PROJ_DEBUG   = "5A8B1AB92E8AE2EB00BA3398"
PROJ_RELEASE = "5A8B1ABA2E8AE2EB00BA3398"
TGT_DEBUG    = "5A8B1ABC2E8AE2EB00BA3398"
TGT_RELEASE  = "5A8B1ABD2E8AE2EB00BA3398"
MAIN_GROUP   = "5A8B1AA72E8AE2E900BA3398"

# 1. File references for the two xcconfigs Xcode needs to see.
src = src.replace(
    "/* End PBXFileReference section */",
    f"\t\t{DEBUG_REF} /* Debug.xcconfig */ = {{isa = PBXFileReference; "
    f"lastKnownFileType = text.xcconfig; name = Debug.xcconfig; "
    f"path = Config/Debug.xcconfig; sourceTree = \"<group>\"; }};\n"
    f"\t\t{RELEASE_REF} /* Release.xcconfig */ = {{isa = PBXFileReference; "
    f"lastKnownFileType = text.xcconfig; name = Release.xcconfig; "
    f"path = Config/Release.xcconfig; sourceTree = \"<group>\"; }};\n"
    "/* End PBXFileReference section */", 1)

# 2. A Config group holding them, and a reference to it from the main group.
src = src.replace(
    "/* End PBXGroup section */",
    f"\t\t{CFG_GROUP} /* Config */ = {{\n"
    f"\t\t\tisa = PBXGroup;\n"
    f"\t\t\tchildren = (\n"
    f"\t\t\t\t{DEBUG_REF} /* Debug.xcconfig */,\n"
    f"\t\t\t\t{RELEASE_REF} /* Release.xcconfig */,\n"
    f"\t\t\t);\n"
    f"\t\t\tname = Config;\n"
    f"\t\t\tsourceTree = \"<group>\";\n"
    f"\t\t}};\n"
    "/* End PBXGroup section */", 1)

src = src.replace(
    f"\t\t{MAIN_GROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n",
    f"\t\t{MAIN_GROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
    f"\t\t\t\t{CFG_GROUP} /* Config */,\n", 1)

# 3. baseConfigurationReference on the two PROJECT-level configurations.
for obj_id, ref, name in ((PROJ_DEBUG, DEBUG_REF, "Debug"),
                          (PROJ_RELEASE, RELEASE_REF, "Release")):
    needle = f"\t\t{obj_id} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n"
    if needle not in src:
        sys.exit(f"could not find project-level {name} block {obj_id}")
    src = src.replace(
        needle,
        needle + f"\t\t\tbaseConfigurationReference = {ref} /* {name}.xcconfig */;\n", 1)

# 4. Delete the settings that now come from xcconfig, TARGET level only.
#    Left in place they would override the xcconfig and silently win.
DROP = ("DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER",
        "MARKETING_VERSION", "CURRENT_PROJECT_VERSION")

def strip(block: str) -> str:
    return "\n".join(l for l in block.split("\n")
                     if not any(l.strip().startswith(k + " =") for k in DROP))

for obj_id, name in ((TGT_DEBUG, "Debug"), (TGT_RELEASE, "Release")):
    start = src.index(f"\t\t{obj_id} /* {name} */ = {{")
    end = src.index(f"\t\t\tname = {name};", start)
    src = src[:start] + strip(src[start:end]) + src[end:]

open(PATH, "w").write(src)
print("ok")
```

Expected output: `ok`. Any `could not find` message means the file has moved on from what this plan read — stop and re-derive the object ids rather than forcing it.

- [ ] **Step 3: Prove no personal values remain**

Run: `grep -nE 'DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|CURRENT_PROJECT_VERSION' Sirr.xcodeproj/project.pbxproj`

Expected: **no output at all**, exit code 1. Any hit means the file still carries a value that will override the xcconfig and break the other developer.

- [ ] **Step 4: Prove the settings now resolve from the xcconfigs**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -showBuildSettings 2>/dev/null | grep -E 'SUPABASE_HOST|PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|DEVELOPMENT_TEAM'
```

Expected: `SUPABASE_HOST = kpcdinxusxycenfnitjc.supabase.co`, `PRODUCT_BUNDLE_IDENTIFIER = com.businessech.tmrin`, `MARKETING_VERSION = 1.1`, `DEVELOPMENT_TEAM = V2PFCP3D26`.

Then the same for Release:

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Release -showBuildSettings 2>/dev/null | grep -E 'SUPABASE_HOST'
```

Expected: `SUPABASE_HOST = hzsxwnmbdkrmipjtfzlp.supabase.co`. **If Debug and Release show the same host, the wiring failed** — that is the single most important assertion in this plan.

- [ ] **Step 5: Build both configurations**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Release -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 6: Share the scheme so the guarantee lives in git**

The whole design rests on Run using Debug and Archive using Release. That mapping currently lives in `Sirr.xcodeproj/xcuserdata/`, which is gitignored — so it is per-machine, and nothing stops Faris's scheme from differing.

In Xcode: Product ▸ Scheme ▸ Manage Schemes, tick **Shared** for the `Sirr` scheme, then close. Confirm the mapping in Product ▸ Scheme ▸ Edit Scheme: **Run → Debug**, **Archive → Release**.

Verify the file now exists and holds the right mapping:

```bash
ls Sirr.xcodeproj/xcshareddata/xcschemes/Sirr.xcscheme
grep -E 'buildConfiguration = "(Debug|Release)"' Sirr.xcodeproj/xcshareddata/xcschemes/Sirr.xcscheme
```

Expected: the file exists, the Launch action shows `buildConfiguration = "Debug"` and the Archive action `buildConfiguration = "Release"`.

- [ ] **Step 7: STOP — tell Faris before committing**

This commit changes `project.pbxproj` for the first time. When Faris pulls it he will not be able to sign until he creates `Config/Local.xcconfig` from the example with `27WKP3HRAX` and `com.farisabumalih.tmrin`. Tell him first, then commit. Do not push this task's commit without confirming Naif has told him.

- [ ] **Step 8: Commit**

```bash
git add Sirr.xcodeproj/project.pbxproj Sirr.xcodeproj/xcshareddata/xcschemes/Sirr.xcscheme
git commit -m "build: drive signing and Supabase env from xcconfig

project.pbxproj no longer holds anyone's DEVELOPMENT_TEAM or bundle id, so it
stops being a file that cannot be committed. Each developer keeps their own
gitignored Config/Local.xcconfig instead.

MARKETING_VERSION and CURRENT_PROJECT_VERSION move to Base.xcconfig for the
same reason — until now the 1.1 (2) bump existed only in Naif's working tree,
so an archive from any other machine would have shipped 1.0 (1).

The scheme is now shared, so Run→Debug and Archive→Release is recorded in git
rather than living in each developer's gitignored xcuserdata.

Faris must copy Config/Local.xcconfig.example to Config/Local.xcconfig and
fill in his team and bundle id before his next build."
```

---

### Task 3: Read the environment at runtime

**Files:**
- Create: `Sirr/core/supabase/SupabaseEnvironment.swift`
- Modify: `Sirr/Info.plist`
- Modify: `Sirr/core/supabase/SupabaseClientManager.swift` (whole file)

`AuthService.swift` is **not** touched — the avatar bucket stays hardcoded and out of scope.

**Interfaces:**
- Consumes: build settings `SUPABASE_HOST` and `SUPABASE_ANON_KEY` from Task 2.
- Produces: `SupabaseEnvironment.host: String`, `.anonKey: String`, `.url: URL`.

- [ ] **Step 1: Add the two keys to `Sirr/Info.plist`**

Insert inside the top-level `<dict>`, before the existing `<key>CFBundleURLTypes</key>`:

```xml
	<key>SUPABASE_HOST</key>
	<string>$(SUPABASE_HOST)</string>
	<key>SUPABASE_ANON_KEY</key>
	<string>$(SUPABASE_ANON_KEY)</string>
```

- [ ] **Step 2: Create `Sirr/core/supabase/SupabaseEnvironment.swift`**

```swift
import Foundation

/// Which Supabase project this build talks to, resolved from Info.plist and
/// ultimately from Config/Debug.xcconfig or Config/Release.xcconfig.
///
/// Debug builds get the development sandbox, Release builds get production.
/// Xcode's Run action uses Debug and Archive uses Release, so a build on its
/// way to TestFlight or the App Store cannot reach the sandbox.
enum SupabaseEnvironment {
    static let host = value("SUPABASE_HOST")
    static let anonKey = value("SUPABASE_ANON_KEY")

    /// Built here rather than stored whole: `//` starts a comment in xcconfig,
    /// so a literal `https://…` value would silently truncate to `https:`.
    static var url: URL { URL(string: "https://\(host)")! }

    /// Traps instead of falling back. A build whose xcconfig is not wired to
    /// its configuration must fail loudly at launch — the alternative is an
    /// app that quietly talks to the wrong project, or to nothing.
    private static func value(_ key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(")  // unsubstituted — the xcconfig is not attached
        else {
            fatalError("Info.plist is missing a usable \(key). Is Config/<configuration>.xcconfig wired to this build configuration?")
        }
        return raw
    }
}
```

- [ ] **Step 3: Rewrite `Sirr/core/supabase/SupabaseClientManager.swift`**

Replace the whole file with:

```swift
//
//  SupabaseClientManager.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Supabase
import Foundation
import os

final class SupabaseClientManager {
    static let shared = SupabaseClientManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseEnvironment.url,
            supabaseKey: SupabaseEnvironment.anonKey
        )
        #if DEBUG
        // Which project this build is pointed at is the first thing worth
        // knowing when something behaves unexpectedly on device.
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Supabase")
            .info("Supabase host: \(SupabaseEnvironment.host, privacy: .public)")
        #endif
    }
}
```

The note about legacy JWT keys that used to live in this file now sits in the xcconfigs and the design doc, next to the key values themselves.

- [ ] **Step 4: Confirm no hardcoded project values survive**

Run: `grep -rnE 'supabase\.co|eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9' --include='*.swift' Sirr/`

Expected: **no output**. Both the host and the key should now come only from `SupabaseEnvironment`.

Note this grep deliberately does *not* look for `tamrin-stg`. That string stays in `AuthService.swift` on purpose.

- [ ] **Step 5: Build both configurations**

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Release -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 6: Prove the substitution actually happened in the built app**

```bash
APP=$(xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Release -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')
/usr/libexec/PlistBuddy -c "Print :SUPABASE_HOST" "$APP/Info.plist"
```

Expected: `hzsxwnmbdkrmipjtfzlp.supabase.co`. If it prints `$(SUPABASE_HOST)` the plist substitution did not run; if it prints the sandbox host, the wrong xcconfig is attached to Release.

- [ ] **Step 7: Commit**

```bash
git add Sirr/core/supabase/SupabaseEnvironment.swift Sirr/Info.plist Sirr/core/supabase/SupabaseClientManager.swift
git commit -m "feat: resolve the Supabase project from the build configuration

Debug talks to the sandbox, Release talks to production. A missing or
unsubstituted value traps at launch rather than letting the app quietly point
somewhere unintended."
```

- [ ] **Step 8: STOP — hand to Naif for a device check**

Tasks 1-3 change how every build on both machines resolves its backend. Before touching any database, Naif installs a Debug build on device and confirms the console logs `Supabase host: kpcdinxusxycenfnitjc.supabase.co` and the app behaves exactly as before. Do not start Task 4 until he confirms.

---

### Task 4: Prove the migrations replay from an empty database

Runs before anything is provisioned. Several migrations are `fix_*` files authored against a live database; whether the set rebuilds from zero has never been tested. Finding a break here costs nothing, finding it midway through provisioning production costs a lot.

Requires Docker Desktop running.

**Files:**
- Modify: any migration under `supabase/migrations/` found to be unreplayable.

**Interfaces:**
- Consumes: nothing.
- Produces: a migration set proven to apply from empty — the production push in Task 5 relies on it.

- [ ] **Step 1: Reset the local database**

Run: `supabase db reset`

Expected: every migration listed as applied, ending without error. Capture the full output.

- [ ] **Step 2: If it failed, repair the offending migration**

Read the error, identify the migration, and make it apply from empty — usually a missing `if not exists`, or a reference to an object an earlier migration never created. Do not reorder or rename existing migration files; other machines and the sandbox have already applied them under their current names. Re-run `supabase db reset` until clean.

- [ ] **Step 3: Confirm the cron jobs exist locally**

```bash
psql "$(supabase status -o env | grep DB_URL | cut -d= -f2- | tr -d '"')" -c "select jobname, schedule from cron.job order by jobname;"
```

Expected three rows: `event-reminders-am` at `0 5 * * *`, `event-reminders-pm` at `0 17 * * *`, `recurring-events` at `0 5 * * *`.

- [ ] **Step 4: Commit if anything changed**

```bash
git add supabase/migrations/
git commit -m "fix(db): make the migration set replay from an empty database

Needed before standing up a second project: a set that only applies to the
one database it grew up against cannot provision a new one."
```

If nothing changed, skip the commit and record in the task notes that the set replayed clean on the first attempt.

---

### Task 5: Provision the production project

Naif drives every step; the database password never leaves his password manager. An agent executing this plan should present the commands and wait, not attempt them.

The project itself already exists — created 2 August 2026, ref `hzsxwnmbdkrmipjtfzlp`, legacy anon JWT confirmed present.

**Files:** none — this is dashboard and CLI work.

**Interfaces:**
- Consumes: the migration set proven in Task 4.
- Produces: a production project matching the sandbox's shape. Task 6's device verification depends on it.

- [ ] **Step 1: Push the schema**

```bash
supabase link --project-ref hzsxwnmbdkrmipjtfzlp
supabase db push
```

Expected: every migration applied. `link` rewrites `supabase/.temp/project-ref`, which is gitignored.

- [ ] **Step 2: Re-link to the sandbox immediately**

```bash
supabase link --project-ref kpcdinxusxycenfnitjc
```

Do this now, not later. A `db push` that lands on production by accident is the most likely way this setup goes wrong.

- [ ] **Step 3: Verify cron on production**

In the production SQL editor: `select jobname, schedule from cron.job order by jobname;`

Expected the same three jobs as Task 4 Step 3. Schedules are UTC — `0 5` and `0 17` are 8am and 8pm Riyadh.

- [ ] **Step 4: Deploy the Edge Function**

```bash
supabase functions deploy send-push --project-ref hzsxwnmbdkrmipjtfzlp
```

- [ ] **Step 5: Set the six function secrets**

In the production dashboard, Edge Functions ▸ Secrets:

| Secret | Value |
|---|---|
| `APNS_AUTH_KEY` | the same `.p8` contents as the sandbox |
| `APNS_KEY_ID` | same as sandbox |
| `APNS_TEAM_ID` | same as sandbox |
| `APNS_BUNDLE_ID` | `com.businessech.tmrin` |
| `APNS_HOST` | `https://api.push.apple.com` |
| `SEND_PUSH_SECRET` | **newly generated**, not the sandbox value |

Generate the new secret with `openssl rand -hex 32`. Reusing the sandbox's would mean a leak from the development project could drive production pushes.

- [ ] **Step 6: Store the two Vault secrets**

In the production SQL editor, using the value from Step 5:

```sql
select vault.create_secret(
  'https://hzsxwnmbdkrmipjtfzlp.supabase.co/functions/v1/send-push',
  'send_push_url'
);
select vault.create_secret('<the SEND_PUSH_SECRET from Step 5>', 'send_push_secret');
```

`send_push_secret` must match Step 5 byte-for-byte, or the trigger gets a 401 and pushes stop with no visible error. See [push-db-settings.md](push-db-settings.md).

- [ ] **Step 7: Configure auth**

In the production dashboard:

- Authentication ▸ URL Configuration — Site URL `https://guileless-squirrel-b6537a.netlify.app`; add the same URL and `sirr://` to redirect URLs.
- Authentication ▸ Providers ▸ Apple — enable, Client IDs `com.businessech.tmrin`.
- Authentication ▸ Providers ▸ Email — confirmations **off**, matching current sandbox behaviour.
- Authentication ▸ Emails ▸ SMTP — copy the Resend settings from the sandbox project.
- Authentication ▸ Rate Limits — **raise the emails-per-hour limit.** It defaults to 2 and that cap still applies after custom SMTP is attached. Left alone, real signups start failing silently once a few people register in the same hour.

- [ ] **Step 8: Upgrade the project to Pro**

Free projects pause after roughly a week of inactivity. For production that means the app dies during any quiet stretch. The sandbox stays free.

- [ ] **Step 9: Confirm the anon key still matches the plan**

In Project Settings ▸ API Keys, confirm the legacy `anon` JWT is still the one in `Config/Release.xcconfig`. If it was rotated, update the xcconfig and re-run Task 3 Step 6.

---

### Task 6: End-to-end verification on device

Naif runs this on device. Do not boot a simulator.

**Files:** none.

**Interfaces:**
- Consumes: everything above.
- Produces: the evidence that the split actually works.

- [ ] **Step 1: Confirm the Debug build reports the sandbox**

Run from Xcode, watch the console for `Supabase host: kpcdinxusxycenfnitjc.supabase.co`.

- [ ] **Step 2: Sign up a brand new account on a Release build**

Archive, install through TestFlight, and register with an email not used before.

- [ ] **Step 3: Confirm the row landed in production and not the sandbox**

`select id, email, created_at from auth.users order by created_at desc limit 3;` in **both** dashboards.

Expected: the new account in production, absent from the sandbox. This is the assertion the whole project exists for.

- [ ] **Step 4: Confirm email delivery**

The OTP email arrives within a few seconds via Resend. If it does not, check Authentication ▸ Rate Limits from Task 5 Step 7 before anything else.

- [ ] **Step 5: Confirm Apple sign-in**

Sign in with Apple on the TestFlight build. It must complete and land on the home screen rather than erroring — that verifies the client id set in Task 5 Step 7.

- [ ] **Step 6: Confirm push**

Create an event in the TestFlight build, then check `select id, status, created_at from push_outbox order by created_at desc limit 5;` on production. The row must not be stuck pending, and the notification must arrive on device.

- [ ] **Step 7: Confirm invite links**

Create a workspace, copy its invite link, open it on a second device signed into a different account, and join.

Avatar upload is deliberately not verified — no bucket exists on production, by decision.

- [ ] **Step 8: Record the result**

If every step passes, note it and tell Naif production is ready for the 1.1 submission. If any step fails, stop and report which — do not proceed to submission with a partial pass.

---

## Follow-up outside this repo

**The landing page.** `~/Documents/tamrin-landing-page` is a separate repository deployed to Netlify. Nothing about it lands on this repo's `staging` branch, and it is not a task in this plan — it is recorded here so it is not forgotten.

After Task 5, check whether the page talks to Supabase at all:

```bash
grep -rniE 'supabase|kpcdinxusxycenfnitjc' ~/Documents/tamrin-landing-page --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' --include='*.html' --include='*.toml' 2>/dev/null | grep -v node_modules
```

No hits means the page is static and there is nothing to do. If there are hits, point them at `hzsxwnmbdkrmipjtfzlp.supabase.co` with the production anon key from `Config/Release.xcconfig` — or change the values in the Netlify dashboard if they come from environment variables. The page can only serve one project; production is the right choice, and sandbox invite links then render no preview, which is fine for development.

## Notes for whoever executes this

**Task order matters.** Tasks 1-3 are the app change and must go in sequence. Task 3 ends with a device check that gates everything after it. Task 4 gates Task 5, and Task 6 is last.

**Task 2 Step 7 is a hard stop.** Do not push that commit until Naif confirms he has told Faris.

**Task 2 Step 6 needs Xcode's GUI.** Sharing a scheme cannot be done reliably from the command line; hand that step to Naif and wait for the file to appear.

**Tasks 5 and 6 are Naif's.** An agent should present the commands and wait for results, not run them. Task 5 needs the database password and dashboard access; Task 6 needs a physical device.

**Do not touch storage.** `AuthService.uploadAvatar` and its `tamrin-stg` bucket stay exactly as they are. If a build check or grep tempts you to "tidy" it, don't.
