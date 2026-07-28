# Universal Links for Sirr — Design

Date: 2026-06-25

## Goal
Turn the existing custom-scheme deep link (`sirr://event/{UUID}`) into a real
Universal Link served from `https://guileless-squirrel-b6537a.netlify.app`, so
tapping an event link opens the app directly (installed) or falls back to the
App Store (not installed). The custom `sirr://` scheme is kept as a permanent
fallback.

> Migration note: the original target domain was `dreams-hub.com`. It was
> retired; the site now lives on Netlify at
> `https://guileless-squirrel-b6537a.netlify.app` (served from the repo root, so
> the AASA sits at the host root where Apple reads it). If a custom domain is
> later attached, update the entitlement + share URL to match.

## Identifiers
- App ID: `V2PFCP3D26.com.businessech.tmrin` (Team ID `V2PFCP3D26` + bundle id)
- Domain: `guileless-squirrel-b6537a.netlify.app`
- Universal Link format: `https://guileless-squirrel-b6537a.netlify.app/event/{UUID}`
- Custom scheme (fallback): `sirr://event/{UUID}`

## Part A — Website (Netlify)
Hosted on Netlify at the site root (source kept in this repo under `landing/`).

1. `.well-known/apple-app-site-association` (no extension) containing the AASA
   JSON for `/event/*`, served from the **host root**.
2. `404.html` should handle `/event/{id}` for non-app visitors — shows an
   open-in-app + App Store fallback card. (Currently `/event/{id}` returns 404
   on the web; the deep link still works when the app is installed.)

Verified live:
- `https://guileless-squirrel-b6537a.netlify.app/.well-known/apple-app-site-association`
  → 200, raw JSON (content-type `text/plain`, which modern iOS accepts).
- Apple CDN
  (`app-site-association.cdn-apple.com/a/v1/guileless-squirrel-b6537a.netlify.app`)
  → 200, valid parsed JSON.

## Part B — iOS app
1. **Entitlements** (`Sirr/Sirr.entitlements`): add
   `com.apple.developer.associated-domains` = `["applinks:dreams-hub.com"]`.
2. **`Sirr/App/SirrApp.swift`**: add
   `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` that submits
   `activity.webpageURL` to the existing `DeepLinkRouter.shared`. Reuses the
   cold-launch buffer already in place.
3. **`Sirr/AppState.swift`**: generalize `handleDeepLink` to accept both the
   custom scheme and the Universal Link by locating the `event` path component
   and parsing the following UUID.
4. **`Sirr/pages/EventHeroDetailView.swift`**: `ShareLink` now shares
   `https://dreams-hub.com/event/{id}` instead of `sirr://event/{id}`.
5. **Push**: unchanged — it builds `sirr://` internally, which still routes.

## Unchanged
`DeepLinkRouter`, cold-launch buffer, login-resume flow, `EventPageView`
navigation. Only a second input source (web activity) and a second URL format
are added.

## Testing
- `curl` AASA + Apple CDN (done).
- Device: paste `https://dreams-hub.com/event/<real-uuid>` into Notes/Messages,
  tap → app opens directly to the event.
- Regression: existing `sirr://` links and push taps still open the event.
