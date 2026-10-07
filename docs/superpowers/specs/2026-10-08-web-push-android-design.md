# Web Push for the member web app — design

**Date:** 2026-10-08
**Status:** approved in conversation, awaiting spec review

## Goal

Members who use the web app (`tamrin-landing-page/app`, mostly Android) get the
same notifications iOS members get today: reminders, payment notices,
registration pushes. Nothing about *when* a push is sent or *what it says*
changes — every notification is still one `push_outbox` row rendered by
`send-push/copy.ts`. Only the delivery gains a second channel.

## Decisions

- **Standard Web Push (VAPID)**, sent directly from `send-push`. No Firebase,
  no third-party service.
- **Permission is asked right after a successful registration**, plus an
  on/off switch in Settings.
- **Shown wherever the browser supports push**, detected by feature
  (`serviceWorker`, `PushManager`, `Notification`), not by user agent. This
  covers Android Chrome / Samsung Internet / Edge / Firefox, also lights up on
  desktop Chrome, and naturally hides itself in in-app browsers (Instagram,
  Snapchat), incognito and iPhone Safari.
- **Where the code lives:** database + `send-push` in this repo (`tamrin`,
  `staging` branch). The website change lives in `tamrin-landing-page` on its
  own branch, delivered as a PR against `main`.

## 1. Database (tamrin repo, one migration)

```
web_push_subscriptions
  endpoint      text primary key      -- unique per browser subscription
  user_id       uuid not null references auth.users(id) on delete cascade
  p256dh        text not null
  auth          text not null
  created_at    timestamptz not null default now()
  last_seen_at  timestamptz not null default now()
index on (user_id)
RLS enabled, no policies — clients reach it only through the RPCs.
```

RPCs (`security definer`, granted to `authenticated` only):

- `save_web_push_subscription(p_endpoint, p_p256dh, p_auth)` — upsert on
  `endpoint`, setting `user_id = auth.uid()` and `last_seen_at = now()`. If a
  different account signs in on the same browser the row moves to them, so a
  shared phone never notifies the previous account.
- `delete_web_push_subscription(p_endpoint)` — deletes the row only if it
  belongs to `auth.uid()`.

## 2. `send-push` (tamrin repo)

- Step 3 loads `device_tokens` **and** `web_push_subscriptions` for
  `row.user_id`. The row fails with `no device tokens` only when both are empty.
- APNs signing (JWT) happens only if there are Apple tokens.
- Web delivery: payload `{ title, body, event_id }`, TTL 24h, urgency `high`,
  signed with `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT`
  (new function secrets, set on both Supabase projects).
- Library: a Deno-native Web Push implementation built on WebCrypto
  (candidate `jsr:@negrel/webpush`); the plan pins it after a spike proving it
  runs on Supabase Edge.
- A `404` or `410` from the push service means the subscription is gone for
  good: delete that row. Other failures are recorded in `last_error` like APNs
  failures are today.
- The outbox row is `sent` if any channel delivered.
- Web-push sending lives in its own module (`send-push/webpush.ts`) beside
  `apns.ts`, with Deno tests alongside like `copy_test.ts`.

## 3. Web app (tamrin-landing-page repo)

- **`/app/sw.js`** — service worker that only handles `push` (show the
  notification, Arabic, RTL, icon `/assets/favicon.png`, status-bar badge) and
  `notificationclick` (focus an open tab or open `/event/<event_id>`). No fetch
  handler, no caching. `netlify.toml` gets `Cache-Control: no-cache` for it.
- **`src/push.js`** — one module owning the feature: `isSupported()`,
  `permission()`, `enable()` (register SW → `requestPermission` → subscribe →
  `save_web_push_subscription`), `disable()` (unsubscribe →
  `delete_web_push_subscription`), `repair()` (permission already granted but
  no subscription → resubscribe silently). The VAPID public key goes in
  `config.js`.
- **Prompt after registering:** when a registration succeeds on the event
  screen, a small card offers «تبي ننبهك بالتذكيرات والدفع؟» with
  «فعّل التنبيهات» and «لاحقاً». It appears only if push is supported,
  permission is still `default`, and «لاحقاً» was not tapped in the last 14 days
  (localStorage, wrapped in try/catch). The browser's own prompt is triggered by
  the tap on «فعّل التنبيهات».
- **Settings:** a notifications switch. If permission is `denied`, the switch is
  disabled with a line explaining how to allow notifications from the browser's
  site settings.
- **On load:** `repair()` runs once a session exists.
- **Sign out:** `disable()` runs before `supabase.auth.signOut()`.

## 4. Rollout

1. Migration and `send-push` deploy to **sandbox**; VAPID secrets set there.
2. Verify locally: serve the web app with `config.js` temporarily pointed at
   sandbox, enable notifications in desktop Chrome on `localhost`, fire a push
   through `push_outbox`, confirm it arrives and opens the event. The sandbox
   pointer is never committed.
3. Production: the migration is applied as hand-run SQL (never `db push` from
   staging), `send-push` deployed, VAPID secrets set — then the landing-page PR
   is merged, because the website must not save subscriptions before the table
   exists.
4. Naif tests on an Android phone against production.

## Asset

A monochrome (white on transparent) 96×96 PNG for Android's status-bar badge.
Until one exists Chrome shows a generic bell; this does not block shipping.

## Out of scope

- iPhone web push (needs Add to Home Screen; iPhone members use the app).
- Offline support or any caching in the service worker.
- Per-type notification preferences.
- The stale `device_tokens` accumulation (tracked separately).
