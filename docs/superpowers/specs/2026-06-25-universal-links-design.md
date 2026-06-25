# Universal Links for Sirr — Design

Date: 2026-06-25

## Goal
Turn the existing custom-scheme deep link (`sirr://event/{UUID}`) into a real
Universal Link served from `https://dreams-hub.com`, so tapping an event link
opens the app directly (installed) or falls back to the App Store (not
installed). The custom `sirr://` scheme is kept as a permanent fallback.

## Identifiers
- App ID: `V2PFCP3D26.com.businessech.tmrin` (Team ID `V2PFCP3D26` + bundle id)
- Domain: `dreams-hub.com`
- Universal Link format: `https://dreams-hub.com/event/{UUID}`
- Custom scheme (fallback): `sirr://event/{UUID}`

## Part A — Website (DONE)
Hosted on Netlify (React SPA).
1. `public/.well-known/apple-app-site-association` (no extension) containing the
   AASA JSON for `/event/*`.
2. `netlify.toml` header forcing `Content-Type: application/json` for that path,
   placed before the SPA `/* -> /index.html` catch-all.
3. `/event/{id}` web route redirects non-app visitors to the App Store.

Verified live:
- `https://dreams-hub.com/.well-known/apple-app-site-association` → 200,
  `content-type: application/json`, raw JSON (no redirect).
- Apple CDN (`app-site-association.cdn-apple.com/a/v1/dreams-hub.com`) → 200,
  `Apple-Origin-Format: json` (parsed valid).

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
