# Push Notifications — Design

**Date:** 2026-06-22
**Status:** Approved (brainstorm), pending implementation plan
**Related:** `docs/superpowers/specs/2026-06-16-stcpay-manual-confirm-design.md` (this supersedes that doc's "Push Notifications" section, which assumed a client-driven model).

## Goal

Deliver APNs push notifications for the STC Pay payment flows. This pass builds a **thin end-to-end slice** that proves the full pipeline on one notification type, then later passes add the remaining types.

## Key Decisions

1. **Server-driven, not client-driven.** The database owns push sending. The iOS client never calls the push function. This prevents a signed-in user from forging or spoofing notifications, and means a push still fires even if the app backgrounds immediately after the action.
2. **Outbox pattern.** RPCs insert a row into a `push_outbox` table; a trigger fires the send. The row is the durable, observable log of every push attempt + result (satisfies the STC Pay spec's logging requirement) and decouples APNs failures from the payment transaction.
3. **Thin slice first.** Build and prove the whole pipe for exactly one type (`payment_submitted`: joiner submits → creator gets a push), on a real device, before fanning out to the other types.
4. **Contextual permission.** Ask for notification permission at the first payment-related action, per role (not at launch).
5. **Copy lives in one place.** The outbox stores only a `type`; the Edge Function maps `type` → Arabic copy and looks up the event name fresh. No notification wording in the client or the outbox row.

## Architecture & Data Flow

Thin slice = "joiner submits payment → creator gets a push":

```
Joiner taps "I've paid"
   │
   ▼
submit_payment RPC  ──(after payment row is written)──►  INSERT into push_outbox
   │                                                        (user_id = creator,
   │                                                         type = 'payment_submitted',
   ▼                                                         event_id, status = 'pending')
RPC returns to app                                                │
                                                                  ▼
                                              AFTER INSERT trigger on push_outbox
                                                  fires pg_net.http_post → send-push
                                                                  │
                                                                  ▼
                                          send-push Edge Function (service-only):
                                            1. verify caller secret
                                            2. load outbox row + event name
                                            3. look up creator's apns_token(s)
                                            4. build APNs JWT, POST to APNs
                                            5. update row → 'sent' / 'failed' (+ error)
                                                                  │
                                                                  ▼
                                          Creator's device: "طلب دفع جديد لحدث {event}"
                                            tap → deep-link sirr://event/<id> → event detail
```

**Properties:**
- The push request is born inside the payment transaction — it only exists if the real payment was written. The client can't forge it.
- The outbox row is the durable log of every push attempt + result.
- A flaky APNs call never touches the payment transaction — the RPC already returned.

## Thin-Slice Cut Line

**In scope now:**
- `push_outbox` table + trigger + secret plumbing.
- `send-push` Edge Function handling exactly one type (`payment_submitted`).
- `submit_payment` RPC inserts the outbox row.
- iOS: Push capability, `AppDelegate` shim, contextual permission, token upsert, **tap → deep-link to event**.
- Secret handling for `AuthKey.p8`.

**Deferred to next pass:**
- The other five push types (`confirm` / `reject` / `cancel` / `leave` / `waitlist`) — each becomes "insert an outbox row with a new `type`" + its copy mapping in the Edge Function.
- Retry of `failed` outbox rows.
- Production-vs-sandbox APNs environment switch (slice uses sandbox).

## Backend

### 1. `push_outbox` table (new migration)

```sql
create table public.push_outbox (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade, -- recipient
  type        text not null,            -- 'payment_submitted' (more types added later)
  event_id    uuid,                     -- for the deep link + event-name lookup
  status      text not null default 'pending',  -- pending | sent | failed
  attempts    int  not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index idx_push_outbox_status on public.push_outbox(status) where status = 'pending';
alter table public.push_outbox enable row level security;
-- No policies on purpose: normal clients can't see/touch it.
-- SECURITY DEFINER RPCs insert; the Edge Function uses the service role (bypasses RLS).
```

Wording is **not** stored here — only a `type`. The Edge Function maps `type` → Arabic text and looks up the event name fresh from `events` by `event_id`.

### 2. `submit_payment` change

Add one insert before the existing `return` (the RPC already has the events row `ev` with `creator_id`):

```sql
  insert into public.push_outbox (user_id, type, event_id)
  values (ev.creator_id, 'payment_submitted', p_event_id);
```

The RPC is `SECURITY DEFINER`, so the insert bypasses RLS. It is inside the same transaction — if the payment write rolls back, so does the notification.

### 3. Trigger → `pg_net` (new migration)

```sql
-- enable once: create extension if not exists pg_net;
create or replace function public.fire_push_outbox()
returns trigger language plpgsql security definer as $$
begin
  perform net.http_post(
    url     := current_setting('app.send_push_url'),
    headers := jsonb_build_object(
                 'Content-Type','application/json',
                 'Authorization','Bearer '||current_setting('app.send_push_secret')),
    body    := jsonb_build_object('outbox_id', NEW.id)
  );
  return NEW;
end $$;

create trigger trg_fire_push_outbox
  after insert on public.push_outbox
  for each row execute function public.fire_push_outbox();
```

The function URL and shared secret are read via `current_setting(...)`, stored as Postgres custom settings (or Supabase Vault) — never hardcoded in a migration. The trigger passes **only the row id**; the Edge Function re-reads the row authoritatively.

### 4. `send-push` Edge Function (new — `supabase/functions/send-push/`, Deno)

Receives `{ outbox_id }`. Steps:
1. **Auth:** reject unless the `Authorization` bearer matches `SEND_PUSH_SECRET`. This is what makes it server-only — no signed-in user can call it.
2. Load the outbox row (service-role client). Bail to `failed` if missing.
3. Look up recipient's `apns_token`(s) from `device_tokens` (a user may have several devices → send to all).
4. Look up the event name from `events` by `event_id`.
5. Map `type` → Arabic copy. `payment_submitted` → body `"طلب دفع جديد لحدث {event_name}"`. Attach `data: { event_id }` for the deep link.
6. Build the **APNs JWT** (ES256, signed with the `.p8`), POST to APNs HTTP/2. `apns-topic` = bundle id.
7. Update the row: `status = 'sent'`, `sent_at = now()`, or `failed` + `last_error`; `attempts = attempts + 1`.

**Edge Function secrets** (Supabase secrets, never in git): `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_AUTH_KEY` (the `.p8` contents), `APNS_HOST` (sandbox for the slice), `SEND_PUSH_SECRET`, plus auto-provided `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`.

### 5. Secret handling — `AuthKey.p8`

`AuthKey.p8` is currently committed at the repo root — a live APNs signing key in git history. Plan:
- Move its contents into the `APNS_AUTH_KEY` Supabase secret.
- `git rm` the file; add `*.p8` to `.gitignore`.
- **Rotate the key** in the Apple Developer portal, since it has already been in history.

The app never needs the file; only the Edge Function does.

## iOS Client

The app is pure SwiftUI with no `AppDelegate`; APNs callbacks only arrive through `UIApplicationDelegate`, so we add a minimal shim. Supabase is reached via `SupabaseClientManager.shared.client`.

### 1. Capability + entitlement
Add the **Push Notifications** capability to the Sirr target → adds `aps-environment` (`development` for debug) to `Sirr/Sirr.entitlements`. No `Info.plist` background-mode change (no silent pushes in the slice).

### 2. `AppDelegate` shim + adaptor

```swift
@main
struct SirrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() { /* existing font setup unchanged */ }
    // body unchanged
}
```

`AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate` handles:
- `didRegisterForRemoteNotificationsWithDeviceToken` → hex-encode token → `PushManager.upsertToken`.
- `didFailToRegisterForRemoteNotificationsWithError` → log (`Logger` category `"Push"`).
- `willPresent` → show banner in foreground (`[.banner, .sound]`).
- `didReceive response` → read `data.event_id` → route to event (see step 5).

### 3. `PushManager` (new — `Sirr/core/push/PushManager.swift`, `@MainActor`)
- `requestAuthorizationAndRegister()` — `UNUserNotificationCenter.requestAuthorization([.alert, .sound, .badge])`; on `granted`, `UIApplication.shared.registerForRemoteNotifications()`. Idempotent; no-ops if denied.
- `upsertToken(_ hex:)` — upsert into `device_tokens` for the current `auth.uid()`:
  ```swift
  try await client.from("device_tokens")
      .upsert(["user_id": uid, "apns_token": hex, "platform": "ios"],
              onConflict: "user_id,apns_token")
      .execute()
  ```
  RLS already permits a user to manage their own tokens; the table's PK + `updated_at` trigger handle re-registration.

### 4. Contextual permission — two trigger points
`requestAuthorizationAndRegister()` is called at:
- **Creator:** after successfully saving their STC Pay number / publishing a paid event. *The thin slice depends on this* — the creator must be registered to receive the `payment_submitted` push.
- **Joiner:** after a successful `submitPayment(...)` in `STCPayService`.

iOS shows the system dialog once; whichever payment action the user hits first triggers the prompt.

### 5. Tap → deep link
The push payload carries `data: { event_id }`. On tap, the delegate reuses the existing deep-link channel: build `sirr://event/<event_id>` and post `.deepLinkReceived` (or set `AppState.deepLinkEventId`), which `AppState`/`RootView` already handle. No new routing logic.

## Testing

- **Real device required** — the Simulator cannot obtain a real APNs token.
- **Token:** on device, grant permission → confirm a row lands in `device_tokens`.
- **End-to-end:** joiner submits payment → assert an outbox row appears, flips `pending → sent`, the creator's device shows *"طلب دفع جديد لحدث {event}"*, tapping opens the event.
- **Edge Function:** `supabase functions serve` locally; unit-test the `type → Arabic copy` mapping and JWT construction; assert a missing/garbage token marks the row `failed` with `last_error` rather than throwing.
- **Regression:** the payment RPCs' behavior is unchanged (the outbox insert is additive and inside the existing transaction), so existing STC Pay flows keep working even with push denied.

## Out of Scope (YAGNI)

- The other five push types (next pass).
- Retry/backoff of failed rows.
- Production APNs environment + per-build host switching.
- Silent/background (content-available) pushes.
- Rich notifications, notification grouping, badge counts.
