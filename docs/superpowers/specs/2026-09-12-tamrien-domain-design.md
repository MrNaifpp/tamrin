# Move share links to tamrien.app — design

**Date:** 2026-09-12
**Status:** approved (code phase only; hosting phase deferred)

## Problem

Every Universal Link the app produces, and every canonical/OG URL on the landing
site, hardcodes the Netlify placeholder host `guileless-squirrel-b6537a.netlify.app`.
The real domain is `https://tamrien.app`. Today that domain is served by GoDaddy
Website Builder (returns 200 at `/`, 404 at `/.well-known/apple-app-site-association`),
so it cannot yet host Universal Links.

The domain/DNS account is not currently accessible. This spec covers only the code
changes, on branches that must **not** merge until the hosting checklist below is done —
otherwise shipped share links would open GoDaddy's 404 page and never launch the app.

## Scope

### App repo (`tamrin-designer-ui`, branch `feat/tamrien-domain` off `staging`)

1. **New `Sirr/core/AppLinks.swift`** — a single source of truth for public link hosts:
   - `static let host = "https://tamrien.app"`
   - `static func eventURL(_ id: UUID) -> URL`  → `\(host)/event/\(id.uuidString)`
   - `static func joinURL(_ code: String) -> URL` → `\(host)/join/\(code)`
   - Force-unwrap is acceptable inside these helpers: the inputs are a compile-time
     constant plus a UUID string / server-issued invite code, so the URL is always valid.
2. **Replace the three hardcoded strings** with `AppLinks` calls:
   - `Sirr/core/supabase/WorkspaceService.swift:42` (`WorkspaceRecord.inviteURL`)
   - `Sirr/Components/WorkspaceSettingsSheet.swift:144`
   - `Sirr/pages/EventHeroDetailView.swift:255` (`ShareLink`)
3. **`Sirr/Sirr.entitlements`** — add `applinks:tamrien.app`, **keep**
   `applinks:guileless-squirrel-b6537a.netlify.app` so links already shared keep
   opening the app during the transition.
4. Leave `docs/` history and `landing/.well-known/apple-app-site-association` untouched
   (the AASA names the app ID only; no domain inside it).
5. `Sirr/` is a `PBXFileSystemSynchronizedRootGroup` in the Xcode project, so a new file
   under `Sirr/core/` joins the target automatically. `project.pbxproj` is not touched
   and must not be committed.

### Landing repo (`~/Documents/tamrin-landing-page`, branch `feat/tamrien-domain`)

Swap `https://guileless-squirrel-b6537a.netlify.app` → `https://tamrien.app` in:
- `index.html` — canonical, `og:url`, `og:image`, `og:image:secure_url`, `twitter:image`
- `404.html` — `og:url`, `og:image`, `og:image:secure_url`, `twitter:image`
- `privacy.html` — canonical

`netlify.toml` (AASA content-type header, `/event/*` and `/join/*` rewrites, `/admin`)
and `.well-known/apple-app-site-association` need no change.

## Out of scope for this branch — hosting checklist (do before merging)

1. Netlify → Domain management: add `tamrien.app` and `www.tamrien.app`; set `tamrien.app`
   as primary. Netlify issues the TLS certificate.
2. GoDaddy DNS: apex `A`/`ALIAS` → Netlify load balancer, `www` `CNAME` → the
   `*.netlify.app` host; disable Website Builder on the domain.
3. Verify `curl -sI https://tamrien.app/.well-known/apple-app-site-association` returns
   `200` with `Content-Type: application/json`.
4. Supabase → Authentication → URL Configuration, on **both** projects
   (prod `hzsxwnmbdkrmipjtfzlp`, sandbox `kpcdinxusxycenfnitjc`): Site URL
   `https://tamrien.app`; add it to redirect URLs alongside the existing entries.
5. Merge both `feat/tamrien-domain` branches; ship a build.
6. On device: paste `https://tamrien.app/event/<real-uuid>` and `/join/<code>` into
   Notes → long-press → confirm the app opens.
7. Follow-up commit: remove the old `applinks:guileless-squirrel…` entitlement once the
   old links have aged out.

## Verification (code phase)

- `grep -rn 'netlify.app' Sirr/` → no results.
- `grep -rn 'netlify.app' index.html 404.html privacy.html` in the landing repo → no results.
- `xcodebuild -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' build`
  succeeds. No simulator is booted (per project rule).
- Device testing happens only after the hosting checklist.
