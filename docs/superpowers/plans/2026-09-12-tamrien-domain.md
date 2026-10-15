# Move Share Links to tamrien.app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Universal Link the app generates, plus the landing site's canonical/OG URLs, use `https://tamrien.app` instead of the Netlify placeholder host — on branches that do not merge until hosting is live.

**Architecture:** One new `AppLinks` enum in the app owns the public host and builds `/event/{uuid}` and `/join/{code}` URLs; the three call sites stop building URL strings themselves. The entitlements file gains the new `applinks:` domain alongside the old one. The landing repo is a plain host swap in three HTML files on its own branch.

**Tech Stack:** Swift / SwiftUI (iOS app, Xcode file-system-synchronized group), static HTML on Netlify.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-12-tamrien-domain-design.md`.
- New host is exactly `https://tamrien.app` (bare apex, no `www`, no trailing slash in the constant).
- Keep `applinks:guileless-squirrel-b6537a.netlify.app` in the entitlements — do **not** remove it (transition period).
- Never stage or commit `Sirr.xcodeproj/project.pbxproj`. `Sirr/` is a `PBXFileSystemSynchronizedRootGroup`, so new files under it join the target automatically.
- Do not boot a simulator. Verification is `xcodebuild` + `grep` only; device testing is Naif's, after hosting.
- App work happens in this worktree on branch `feat/tamrien-domain` (already created, spec committed). Landing work happens in `~/Documents/tamrin-landing-page` on a new branch of the same name.
- Do not push either branch without explaining first (project rule).
- Leave `docs/` history and `landing/.well-known/apple-app-site-association` untouched.
- Pre-existing uncommitted changes in the worktree (`Config/*.xcconfig`, `supabase/tests/event_lineups_test.sql`, `docs/held-migrations/`, an untracked migration) are **not ours** — never stage them.

---

### Task 1: `AppLinks` enum and the three call sites

**Files:**
- Create: `Sirr/core/AppLinks.swift`
- Modify: `Sirr/core/supabase/WorkspaceService.swift:40-43`
- Modify: `Sirr/Components/WorkspaceSettingsSheet.swift:143-144`
- Modify: `Sirr/pages/EventHeroDetailView.swift:255`

**Interfaces:**
- Produces: `enum AppLinks { static let host: String; static func eventURL(_ id: UUID) -> URL; static func joinURL(_ code: String) -> URL }`
- Consumed by: the three call sites in this task only. No later task depends on it.

- [ ] **Step 1: Confirm the scheme name and that the project builds before touching anything**

Run:
```bash
xcodebuild -list -project Sirr.xcodeproj 2>/dev/null | sed -n '/Schemes:/,$p'
```
Expected: a scheme named `Sirr` is listed. If the name differs, use that name in every `xcodebuild` command below.

Run:
```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
Expected: last line `** BUILD SUCCEEDED **`. If it already fails, stop and report — do not proceed on a broken baseline.

- [ ] **Step 2: Create `Sirr/core/AppLinks.swift`**

```swift
import Foundation

/// Public web host for Universal Links. The same host must serve
/// `/.well-known/apple-app-site-association` and be listed as an
/// `applinks:` associated domain in `Sirr.entitlements`.
enum AppLinks {
    static let host = "https://tamrien.app"

    /// `https://tamrien.app/event/{uuid}` — opens the event in the app.
    static func eventURL(_ id: UUID) -> URL {
        URL(string: "\(host)/event/\(id.uuidString)")!
    }

    /// `https://tamrien.app/join/{code}` — workspace invite.
    static func joinURL(_ code: String) -> URL {
        URL(string: "\(host)/join/\(code)")!
    }
}
```

The force-unwraps are deliberate: `host` is a compile-time constant, `uuidString` is always URL-safe, and invite codes are server-issued alphanumerics. A `nil` here is a programmer error, not a runtime condition.

- [ ] **Step 3: Replace the invite URL in `WorkspaceService.swift`**

Current (lines 40–43):
```swift
    /// Universal invite link (same domain as event links).
    var inviteURL: URL? {
        guard let inviteCode else { return nil }
        return URL(string: "https://guileless-squirrel-b6537a.netlify.app/join/\(inviteCode)")
    }
```
Replace with:
```swift
    /// Universal invite link (same domain as event links).
    var inviteURL: URL? {
        guard let inviteCode else { return nil }
        return AppLinks.joinURL(inviteCode)
    }
```

- [ ] **Step 4: Replace the invite URL in `WorkspaceSettingsSheet.swift`**

Current (lines 143–144):
```swift
            if let code = inviteCode,
               let url = URL(string: "https://guileless-squirrel-b6537a.netlify.app/join/\(code)") {
```
Replace with:
```swift
            if let code = inviteCode {
                let url = AppLinks.joinURL(code)
```
The closing `}` of the original `if let` block already exists and is unchanged — only the condition line changes, and `url` moves from an optional-binding to a `let` on the next line. Indentation of the following `ShareLink(item: url) {` line is unchanged.

- [ ] **Step 5: Replace the event ShareLink in `EventHeroDetailView.swift`**

Current (line 255):
```swift
                            ShareLink(item: "https://guileless-squirrel-b6537a.netlify.app/event/\(event.id.uuidString)") {
```
Replace with:
```swift
                            ShareLink(item: AppLinks.eventURL(event.id)) {
```
`ShareLink` accepts a `URL` item directly; sharing a `URL` instead of a `String` also lets the share sheet render it as a link rather than plain text.

- [ ] **Step 6: Verify no placeholder host remains in app code**

Run:
```bash
grep -rn 'netlify.app' Sirr/ --include='*.swift'
```
Expected: no output.

- [ ] **Step 7: Build**

Run:
```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
```
Expected: exactly one line, `** BUILD SUCCEEDED **`, and no `error:` lines. If `AppLinks` is reported as undefined, the synchronized-group assumption was wrong — stop and report rather than editing `project.pbxproj`.

- [ ] **Step 8: Commit (only our four files)**

```bash
git add Sirr/core/AppLinks.swift Sirr/core/supabase/WorkspaceService.swift Sirr/Components/WorkspaceSettingsSheet.swift Sirr/pages/EventHeroDetailView.swift
git status --short   # confirm nothing else is staged (xcconfig / sql / pbxproj must stay unstaged)
git commit -m "feat(links): build Universal Links from AppLinks on tamrien.app"
```

---

### Task 2: Associated domain in entitlements

**Files:**
- Modify: `Sirr/Sirr.entitlements:7-10`

**Interfaces:** none (plist only).

- [ ] **Step 1: Add the new applink, keep the old one**

Current (lines 7–10):
```xml
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>applinks:guileless-squirrel-b6537a.netlify.app</string>
	</array>
```
Replace with:
```xml
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>applinks:tamrien.app</string>
		<string>applinks:guileless-squirrel-b6537a.netlify.app</string>
	</array>
```
Tabs, not spaces — match the file's existing indentation.

- [ ] **Step 2: Validate the plist and confirm both domains**

Run:
```bash
plutil -lint Sirr/Sirr.entitlements && grep -c 'applinks:' Sirr/Sirr.entitlements
```
Expected: `Sirr/Sirr.entitlements: OK` then `2`.

- [ ] **Step 3: Build (entitlements are processed at build time)**

Run:
```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
```
Expected: `** BUILD SUCCEEDED **` only.

- [ ] **Step 4: Commit**

```bash
git add Sirr/Sirr.entitlements
git status --short   # only the entitlements file staged
git commit -m "feat(links): associate tamrien.app for Universal Links (keep old host during transition)"
```

---

### Task 3: Landing site canonical / OG hosts

**Files (in `~/Documents/tamrin-landing-page`, a separate git repo):**
- Modify: `index.html:10,19,20,21,31`
- Modify: `404.html:16,17,18,28`
- Modify: `privacy.html:11`

**Interfaces:** none. `netlify.toml` and `.well-known/apple-app-site-association` are **not** modified.

- [ ] **Step 1: Branch off the landing repo's default branch**

Run:
```bash
cd ~/Documents/tamrin-landing-page && git status --short && git branch --show-current
```
Expected: clean working tree (no output from `status`) and the current branch name printed. If the tree is dirty, stop and report — do not mix unrelated changes.

```bash
cd ~/Documents/tamrin-landing-page && git checkout -b feat/tamrien-domain
```

- [ ] **Step 2: Count occurrences before the swap**

Run:
```bash
cd ~/Documents/tamrin-landing-page && grep -c 'guileless-squirrel-b6537a.netlify.app' index.html 404.html privacy.html
```
Expected:
```
index.html:5
404.html:4
privacy.html:1
```

- [ ] **Step 3: Swap the host in exactly those three files**

Run:
```bash
cd ~/Documents/tamrin-landing-page && sed -i '' 's#https://guileless-squirrel-b6537a\.netlify\.app#https://tamrien.app#g' index.html 404.html privacy.html
```

- [ ] **Step 4: Verify the swap and that nothing else changed**

Run:
```bash
cd ~/Documents/tamrin-landing-page && grep -rn 'netlify.app' index.html 404.html privacy.html; echo "--- new host lines ---"; grep -c 'https://tamrien.app' index.html 404.html privacy.html; echo "--- files changed ---"; git status --short
```
Expected: first grep prints nothing; counts are `index.html:5`, `404.html:4`, `privacy.html:1`; `git status` shows exactly ` M 404.html`, ` M index.html`, ` M privacy.html`.

Run:
```bash
cd ~/Documents/tamrin-landing-page && git diff --stat
```
Expected: 3 files changed, 10 insertions(+), 10 deletions(-).

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/tamrin-landing-page && git add index.html 404.html privacy.html && git commit -m "feat: point canonical and OG URLs at tamrien.app"
```

---

## Done criteria for the code phase

- App branch `feat/tamrien-domain` has 2 feature commits on top of the spec commits; `grep -rn 'netlify.app' Sirr/ --include='*.swift'` is empty; Debug build succeeds; `Sirr.entitlements` lists both applinks.
- Landing branch `feat/tamrien-domain` has 1 commit; the three HTML files carry no `netlify.app` host.
- Nothing pushed, nothing merged. The hosting checklist in the spec (Netlify domain, GoDaddy DNS, AASA `curl` check, Supabase Auth URLs on both projects, device test, later removal of the old applink) gates the merge.
