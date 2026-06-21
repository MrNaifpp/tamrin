# Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a server-driven APNs push to the event creator when a joiner submits a payment, proven end-to-end on a real device.

**Architecture:** RPCs insert a row into a `push_outbox` table inside the payment transaction; an `AFTER INSERT` trigger calls a `send-push` Supabase Edge Function via `pg_net`; the function looks up the recipient's APNs token, signs an APNs JWT, and POSTs to APNs, then records the result back on the outbox row. The iOS client only registers for notifications and uploads its token — it never sends pushes.

**Tech Stack:** Postgres (Supabase migrations, `pg_net`), Deno (Supabase Edge Function, Web Crypto ES256), Swift/SwiftUI (UserNotifications, `supabase-swift`).

## Global Constraints

- Supabase project id: `tamrin`. Local API: `http://127.0.0.1:54321`. Local DB port: `54322`.
- iOS bundle id / APNs topic: `com.businessech.tmrin`.
- APNs host for this work: **sandbox** — `https://api.sandbox.push.apple.com` (staging only; prod cutover handled separately).
- Supabase client is always reached via `SupabaseClientManager.shared.client`.
- Loggers use `Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: ...)`.
- Notification copy lives ONLY in the Edge Function (`type` → Arabic text). Never in the client or the outbox row.
- This pass ships exactly one push type: `payment_submitted`. Do not add the other types.
- The `device_tokens` table already exists (migration `20260617400000_create_device_tokens.sql`) with RLS allowing users to manage their own tokens.

---

### Task 1: `push_outbox` table

**Files:**
- Create: `supabase/migrations/20260622100000_create_push_outbox.sql`

**Interfaces:**
- Produces: table `public.push_outbox(id uuid, user_id uuid, type text, event_id uuid, status text, attempts int, last_error text, created_at timestamptz, sent_at timestamptz)`. RLS enabled, no policies (service-role + SECURITY DEFINER only).

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/20260622100000_create_push_outbox.sql
-- Outbox for server-driven push notifications. RPCs insert rows; a trigger
-- (next migration) fires the send-push Edge Function. The row is the durable
-- log of every push attempt + result.

create table if not exists public.push_outbox (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade, -- recipient
  type        text not null,            -- 'payment_submitted' (more types later)
  event_id    uuid,                     -- deep link + event-name lookup
  status      text not null default 'pending',  -- pending | sent | failed
  attempts    int  not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);

create index if not exists idx_push_outbox_pending
  on public.push_outbox(status) where status = 'pending';

alter table public.push_outbox enable row level security;
-- No policies on purpose: normal clients cannot see or touch this table.
-- SECURITY DEFINER RPCs insert; the Edge Function uses the service role.
```

- [ ] **Step 2: Apply and verify the table exists with RLS on**

Run:
```bash
cd /Users/naifalialshahrani/Documents/tamrin
supabase db reset   # applies all migrations to the local DB
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "select relrowsecurity from pg_class where relname = 'push_outbox';"
```
Expected: one row, `relrowsecurity = t`.

- [ ] **Step 3: Verify a normal (anon) client cannot read the table**

Run:
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "set role anon; select count(*) from public.push_outbox;"
```
Expected: `0` (RLS with no policy yields no rows; the query itself succeeds but returns nothing). Reset role with `reset role;` if continuing in the same session.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260622100000_create_push_outbox.sql
git commit -m "feat(db): push_outbox table for server-driven notifications"
```

---

### Task 2: `submit_payment` inserts the outbox row

**Files:**
- Create: `supabase/migrations/20260622110000_submit_payment_outbox.sql`

**Interfaces:**
- Consumes: `public.push_outbox` (Task 1); existing `public.submit_payment(p_event_id uuid, p_user_id uuid)`.
- Produces: `submit_payment` now inserts `(ev.creator_id, 'payment_submitted', p_event_id)` into `push_outbox` on the success path only.

- [ ] **Step 1: Write the migration (full `create or replace`, with the new insert)**

Copy the current function body verbatim from `20260617500000_stcpay_rpcs.sql` and add the outbox insert immediately before the final success `return`:

```sql
-- supabase/migrations/20260622110000_submit_payment_outbox.sql
-- Adds a push_outbox insert to submit_payment so the creator is notified.
-- Inside the same transaction: if the payment write rolls back, so does the
-- notification.

create or replace function public.submit_payment(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  creator_stc text;
  current_seats int;
  existing_status text;
begin
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;

  if ev.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into existing_status
    from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;
  if existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', existing_status);
  end if;

  if ev.max_participants is not null then
    select count(*) into current_seats
      from public.event_participants
      where event_id = p_event_id
        and payment_status in ('pending', 'confirmed');
    if current_seats >= ev.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  select stc_pay_number into creator_stc
    from public.users
    where user_id = ev.creator_id;
  if creator_stc is null or creator_stc = '' then
    return json_build_object('status', 'creator_missing_number');
  end if;

  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

  delete from public.event_waitlist
    where event_id = p_event_id and user_id = p_user_id;

  -- NEW: enqueue a push to the creator (server-driven).
  insert into public.push_outbox (user_id, type, event_id)
  values (ev.creator_id, 'payment_submitted', p_event_id);

  return json_build_object(
    'status', 'submitted',
    'creator_id', ev.creator_id,
    'paid_to_number', creator_stc
  );
end;
$$;

grant execute on function public.submit_payment(uuid, uuid) to authenticated;
```

- [ ] **Step 2: Apply migrations**

Run: `supabase db reset`
Expected: completes without error.

- [ ] **Step 3: Verify the insert fires only on success**

This requires a seeded event + creator + joiner. Using existing local seed data (or insert minimal rows), call the RPC and assert an outbox row appears. Example assuming you have an event id `:eid`, joiner id `:jid`:

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" <<'SQL'
-- Replace the UUIDs with rows that exist locally (creator has a stc_pay_number).
select public.submit_payment('<EVENT_ID>'::uuid, '<JOINER_ID>'::uuid);
select user_id, type, event_id, status from public.push_outbox order by created_at desc limit 1;
SQL
```
Expected: the RPC returns `{"status":"submitted",...}` AND one `push_outbox` row with `type = 'payment_submitted'`, `status = 'pending'`, `user_id` = the creator.

- [ ] **Step 4: Verify no row on a rejected path**

Run the RPC again for the SAME joiner (now `already_joined`):
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "select public.submit_payment('<EVENT_ID>'::uuid, '<JOINER_ID>'::uuid);
   select count(*) from public.push_outbox;"
```
Expected: RPC returns `already_joined`; outbox row count is still `1` (no new row).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260622110000_submit_payment_outbox.sql
git commit -m "feat(db): submit_payment enqueues payment_submitted push"
```

---

### Task 3: `pg_net` trigger to fire the Edge Function

**Files:**
- Create: `supabase/migrations/20260622120000_push_outbox_trigger.sql`
- Create (NOT committed; ops doc): `docs/superpowers/plans/push-db-settings.md`

**Interfaces:**
- Consumes: `public.push_outbox` (Task 1); GUCs `app.send_push_url`, `app.send_push_secret`.
- Produces: trigger `trg_fire_push_outbox` that POSTs `{ "outbox_id": <id> }` to the `send-push` function. Guards: does nothing if the GUCs are unset (so `db reset` in CI never errors).

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/20260622120000_push_outbox_trigger.sql
-- Fires the send-push Edge Function via pg_net whenever a push_outbox row is
-- inserted. Passes ONLY the row id; the function re-reads the row.

create extension if not exists pg_net with schema extensions;

create or replace function public.fire_push_outbox()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url    text := current_setting('app.send_push_url', true);
  v_secret text := current_setting('app.send_push_secret', true);
begin
  -- If env not configured (e.g. CI / fresh local reset), skip silently.
  if v_url is null or v_url = '' then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || coalesce(v_secret, '')),
    body    := jsonb_build_object('outbox_id', new.id)
  );
  return new;
end;
$$;

drop trigger if exists trg_fire_push_outbox on public.push_outbox;
create trigger trg_fire_push_outbox
  after insert on public.push_outbox
  for each row execute function public.fire_push_outbox();
```

- [ ] **Step 2: Write the ops doc for setting the GUCs (secrets — never in a migration)**

```markdown
<!-- docs/superpowers/plans/push-db-settings.md -->
# Push DB settings (run per environment — NOT committed as a migration)

These set the function URL + shared secret the trigger reads via current_setting.

## Local
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "alter database postgres set app.send_push_url = 'http://host.docker.internal:54321/functions/v1/send-push';"
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "alter database postgres set app.send_push_secret = 'local-dev-secret';"

## Staging (run against the staging DB)
alter database postgres set app.send_push_url = 'https://kpcdinxusxycenfnitjc.supabase.co/functions/v1/send-push';
alter database postgres set app.send_push_secret = '<same value as the SEND_PUSH_SECRET function secret>';

# After ALTER DATABASE, open a NEW connection for the setting to take effect.
```

- [ ] **Step 3: Apply migration and set local GUCs**

Run:
```bash
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "alter database postgres set app.send_push_url = 'http://host.docker.internal:54321/functions/v1/send-push';
   alter database postgres set app.send_push_secret = 'local-dev-secret';"
```
Expected: `ALTER DATABASE` twice, no error.

- [ ] **Step 4: Verify the trigger enqueues a net request**

In a fresh psql session (so the GUCs are loaded), insert a row directly and check `pg_net`'s queue:
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" <<'SQL'
insert into public.push_outbox (user_id, type, event_id)
values ((select id from auth.users limit 1), 'payment_submitted', null);
select count(*) from net.http_request_queue;  -- or net._http_response shortly after
SQL
```
Expected: the insert succeeds and a request is queued (count ≥ 1). The actual delivery fails until Task 4 exists — that is fine here.

- [ ] **Step 5: Commit (migration only — not the secrets)**

```bash
git add supabase/migrations/20260622120000_push_outbox_trigger.sql docs/superpowers/plans/push-db-settings.md
git commit -m "feat(db): pg_net trigger fires send-push on outbox insert"
```

---

### Task 4: `send-push` Edge Function

**Files:**
- Create: `supabase/functions/send-push/index.ts`
- Create: `supabase/functions/send-push/copy.ts`
- Create: `supabase/functions/send-push/apns.ts`
- Test: `supabase/functions/send-push/copy_test.ts`

**Interfaces:**
- Consumes: POST body `{ outbox_id: string }`, `Authorization: Bearer <SEND_PUSH_SECRET>`; tables `push_outbox`, `device_tokens`, `events`.
- Produces: sends APNs alert; updates the outbox row to `sent`/`failed`. Env: `SEND_PUSH_SECRET`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_AUTH_KEY`, `APNS_HOST`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.
- `copy.ts` exports `copyFor(type: string, eventName: string): { title: string; body: string } | null`.
- `apns.ts` exports `makeApnsJwt(opts)` and `sendApns(opts)`.

- [ ] **Step 1: Write the failing copy test**

```ts
// supabase/functions/send-push/copy_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { copyFor } from "./copy.ts";

Deno.test("payment_submitted copy interpolates the event name", () => {
  const c = copyFor("payment_submitted", "تمرين كرة قدم");
  assertEquals(c, { title: "طلب دفع جديد", body: "طلب دفع جديد لحدث تمرين كرة قدم" });
});

Deno.test("unknown type returns null", () => {
  assertEquals(copyFor("nope", "x"), null);
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `deno test supabase/functions/send-push/copy_test.ts`
Expected: FAIL — `copy.ts` does not exist / `copyFor` not found.

- [ ] **Step 3: Implement `copy.ts`**

```ts
// supabase/functions/send-push/copy.ts
// type -> Arabic notification copy. This is the ONLY place push wording lives.
export function copyFor(
  type: string,
  eventName: string,
): { title: string; body: string } | null {
  switch (type) {
    case "payment_submitted":
      return { title: "طلب دفع جديد", body: `طلب دفع جديد لحدث ${eventName}` };
    default:
      return null;
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `deno test supabase/functions/send-push/copy_test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Implement `apns.ts` (ES256 JWT + APNs POST)**

```ts
// supabase/functions/send-push/apns.ts
// Builds the APNs provider JWT (ES256) and sends an alert push over HTTP/2.

function b64url(bytes: Uint8Array): string {
  let s = btoa(String.fromCharCode(...bytes));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function makeApnsJwt(opts: {
  keyId: string;
  teamId: string;
  authKeyPem: string;
  nowSeconds: number;
}): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(opts.authKeyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64url(new TextEncoder().encode(
    JSON.stringify({ alg: "ES256", kid: opts.keyId }),
  ));
  const payload = b64url(new TextEncoder().encode(
    JSON.stringify({ iss: opts.teamId, iat: opts.nowSeconds }),
  ));
  const signingInput = `${header}.${payload}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

export async function sendApns(opts: {
  host: string;       // https://api.sandbox.push.apple.com
  deviceToken: string;
  topic: string;      // bundle id
  jwt: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
}): Promise<{ ok: boolean; status: number; text: string }> {
  const res = await fetch(`${opts.host}/3/device/${opts.deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${opts.jwt}`,
      "apns-topic": opts.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title: opts.title, body: opts.body }, sound: "default" },
      ...opts.data,
    }),
  });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text };
}
```

- [ ] **Step 6: Implement `index.ts` (the handler)**

```ts
// supabase/functions/send-push/index.ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { copyFor } from "./copy.ts";
import { makeApnsJwt, sendApns } from "./apns.ts";

const SEND_PUSH_SECRET = Deno.env.get("SEND_PUSH_SECRET")!;
const APNS_HOST = Deno.env.get("APNS_HOST") ?? "https://api.sandbox.push.apple.com";
const APNS_TOPIC = Deno.env.get("APNS_BUNDLE_ID")!;

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  // 1. Auth — server-only.
  if (req.headers.get("authorization") !== `Bearer ${SEND_PUSH_SECRET}`) {
    return new Response("unauthorized", { status: 401 });
  }

  const { outbox_id } = await req.json().catch(() => ({}));
  if (!outbox_id) return new Response("missing outbox_id", { status: 400 });

  // 2. Load the outbox row (authoritative).
  const { data: row } = await admin
    .from("push_outbox")
    .select("id, user_id, type, event_id")
    .eq("id", outbox_id)
    .single();
  if (!row) return new Response("outbox row not found", { status: 404 });

  const fail = async (msg: string) => {
    await admin.from("push_outbox").update({
      status: "failed",
      last_error: msg.slice(0, 500),
      attempts: 1,
    }).eq("id", row.id);
    return new Response(msg, { status: 200 }); // 200: we recorded the failure
  };

  // 3. Recipient tokens.
  const { data: tokens } = await admin
    .from("device_tokens")
    .select("apns_token")
    .eq("user_id", row.user_id);
  if (!tokens || tokens.length === 0) return await fail("no device tokens");

  // 4. Event name (for copy).
  let eventName = "";
  if (row.event_id) {
    const { data: ev } = await admin
      .from("events").select("name").eq("id", row.event_id).single();
    eventName = ev?.name ?? "";
  }

  // 5. Copy.
  const copy = copyFor(row.type, eventName);
  if (!copy) return await fail(`no copy for type ${row.type}`);

  // 6. Sign + send to every device.
  const jwt = await makeApnsJwt({
    keyId: Deno.env.get("APNS_KEY_ID")!,
    teamId: Deno.env.get("APNS_TEAM_ID")!,
    authKeyPem: Deno.env.get("APNS_AUTH_KEY")!,
    nowSeconds: Math.floor(Date.now() / 1000),
  });

  const results = await Promise.all(tokens.map((t) =>
    sendApns({
      host: APNS_HOST,
      deviceToken: t.apns_token,
      topic: APNS_TOPIC,
      jwt,
      title: copy.title,
      body: copy.body,
      data: { event_id: row.event_id },
    })
  ));

  const anyOk = results.some((r) => r.ok);
  await admin.from("push_outbox").update({
    status: anyOk ? "sent" : "failed",
    sent_at: anyOk ? new Date().toISOString() : null,
    last_error: anyOk ? null : results.map((r) => `${r.status}:${r.text}`).join("; ").slice(0, 500),
    attempts: 1,
  }).eq("id", row.id);

  return new Response(JSON.stringify({ ok: anyOk }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
```

- [ ] **Step 7: Set local function secrets and serve**

Run:
```bash
cd /Users/naifalialshahrani/Documents/tamrin
cat > supabase/functions/.env <<EOF
SEND_PUSH_SECRET=local-dev-secret
APNS_KEY_ID=<your key id>
APNS_TEAM_ID=<your team id>
APNS_BUNDLE_ID=com.businessech.tmrin
APNS_HOST=https://api.sandbox.push.apple.com
APNS_AUTH_KEY="$(cat AuthKey.p8)"
EOF
supabase functions serve send-push --env-file supabase/functions/.env
```
Expected: function boots and serves at `/functions/v1/send-push`. (`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are injected automatically by `functions serve`.)

- [ ] **Step 8: Verify auth rejection**

Run (new terminal):
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  http://127.0.0.1:54321/functions/v1/send-push \
  -H "Authorization: Bearer wrong" -H "Content-Type: application/json" \
  -d '{"outbox_id":"00000000-0000-0000-0000-000000000000"}'
```
Expected: `401`.

- [ ] **Step 9: Verify "no device tokens" marks the row failed (not a throw)**

With a real pending outbox row id (from Task 2/3, for a user with no token):
```bash
curl -s -X POST http://127.0.0.1:54321/functions/v1/send-push \
  -H "Authorization: Bearer local-dev-secret" -H "Content-Type: application/json" \
  -d '{"outbox_id":"<OUTBOX_ID>"}'
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "select status, last_error from public.push_outbox where id = '<OUTBOX_ID>';"
```
Expected: response `200`; row `status = 'failed'`, `last_error = 'no device tokens'`.

- [ ] **Step 10: Add `.gitignore` entry for the function env, commit**

```bash
printf "\nsupabase/functions/.env\n" >> .gitignore
git add supabase/functions/send-push/ supabase/functions/send-push/copy_test.ts .gitignore
git commit -m "feat(edge): send-push Edge Function (APNs ES256, outbox-driven)"
```

---

### Task 5: iOS — Push capability, entitlement, AppDelegate adaptor

**Files:**
- Modify: `Sirr/Sirr.entitlements`
- Create: `Sirr/core/push/PushAppDelegate.swift`
- Modify: `Sirr/App/SirrApp.swift:14-16` (add the adaptor property)

**Interfaces:**
- Produces: `PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate` wired via `@UIApplicationDelegateAdaptor`. Calls (added in Task 6/8): `PushManager.shared.upsertToken(_:)`, deep-link routing.

- [ ] **Step 1: Add the Push Notifications entitlement**

Add `aps-environment` to `Sirr/Sirr.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
</dict>
</plist>
```

> Also enable the **Push Notifications** capability on the Sirr target in Xcode (Signing & Capabilities → + Capability → Push Notifications) so the provisioning profile includes it. The entitlement edit above is what the build consumes.

- [ ] **Step 2: Create the AppDelegate shim (registration callbacks + logging only for now)**

```swift
// Sirr/core/push/PushAppDelegate.swift
import UIKit
import UserNotifications
import os

private let pushLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Push")

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pushLogger.info("APNs token registered (len: \(hex.count))")
        Task { await PushManager.shared.upsertToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushLogger.error("APNs registration failed: \(error.localizedDescription)")
    }

    // Foreground presentation.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
```

> `PushManager` is created in Task 6. This file will not compile until then — that is fine; we build at the end of Task 6.

- [ ] **Step 3: Wire the adaptor into `SirrApp`**

In `Sirr/App/SirrApp.swift`, add the property inside `struct SirrApp: App` (right after the `@main`/struct line, before `init()`):

```swift
@main
struct SirrApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    init() {
        // existing font setup unchanged
```

- [ ] **Step 4: Commit (compiles after Task 6)**

```bash
git add Sirr/Sirr.entitlements Sirr/core/push/PushAppDelegate.swift Sirr/App/SirrApp.swift
git commit -m "feat(ios): push capability + AppDelegate adaptor shim"
```

---

### Task 6: iOS — `PushManager` (permission request + token upsert)

**Files:**
- Create: `Sirr/core/push/PushManager.swift`

**Interfaces:**
- Consumes: `SupabaseClientManager.shared.client`; `device_tokens` table.
- Produces: `PushManager.shared` (`@MainActor`) with `func requestAuthorizationAndRegister() async` and `func upsertToken(_ hex: String) async`.

- [ ] **Step 1: Create `PushManager`**

```swift
// Sirr/core/push/PushManager.swift
import Foundation
import UIKit
import UserNotifications
import os

@MainActor
final class PushManager {
    static let shared = PushManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Push")
    private let client = SupabaseClientManager.shared.client
    private init() {}

    /// Ask for permission (system dialog shows once) and register for APNs if granted.
    /// Safe to call repeatedly and from any payment entry point.
    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("notification authorization granted: \(granted)")
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            logger.error("requestAuthorization failed: \(error.localizedDescription)")
        }
    }

    /// Upsert the APNs token for the signed-in user. RLS lets a user manage own tokens.
    func upsertToken(_ hex: String) async {
        struct DeviceToken: Encodable {
            let user_id: String
            let apns_token: String
            let platform: String
        }
        do {
            let session = try await client.auth.session
            let payload = DeviceToken(
                user_id: session.user.id.uuidString,
                apns_token: hex,
                platform: "ios")
            try await client.from("device_tokens")
                .upsert(payload, onConflict: "user_id,apns_token")
                .execute()
            logger.info("device token upserted")
        } catch {
            logger.error("upsertToken failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build the app (Tasks 5 + 6 now compile together)**

Run:
```bash
cd /Users/naifalialshahrani/Documents/tamrin
xcodebuild -project Sirr.xcodeproj -scheme Sirr \
  -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sirr/core/push/PushManager.swift
git commit -m "feat(ios): PushManager — permission request + device token upsert"
```

---

### Task 7: iOS — request permission at the two contextual moments

**Files:**
- Modify: `Sirr/pages/NewEventView.swift:470` (creator — after saving STC Pay number)
- Modify: `Sirr/core/payment/STCPayService.swift` (joiner — after a successful `submitPayment`)

**Interfaces:**
- Consumes: `PushManager.shared.requestAuthorizationAndRegister()`.

- [ ] **Step 1: Creator trigger — after `updateSTCPayNumber` succeeds in `NewEventView`**

At `Sirr/pages/NewEventView.swift:470`, the code currently calls:
```swift
            try await AuthService.shared.updateSTCPayNumber(canonical)
```
Add immediately after that line (same `do` block, after the await succeeds):
```swift
            try await AuthService.shared.updateSTCPayNumber(canonical)
            await PushManager.shared.requestAuthorizationAndRegister()
```

- [ ] **Step 2: Joiner trigger — after a successful submit in `STCPayService.submitPayment`**

In `Sirr/core/payment/STCPayService.swift`, in the `.submitted` success branch (around line 65, after `stcPayLogger.info("submit_payment submitted ...")` and before `return .submitted(...)`), add:
```swift
            await PushManager.shared.requestAuthorizationAndRegister()
```
> `submitPayment` is `async`; `PushManager` is `@MainActor`. If `STCPayService` is not main-actor isolated, this `await` hops to the main actor correctly. No other change needed.

- [ ] **Step 3: Build**

Run:
```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr \
  -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sirr/pages/NewEventView.swift Sirr/core/payment/STCPayService.swift
git commit -m "feat(ios): request push permission at creator save + joiner submit"
```

---

### Task 8: iOS — tap notification → deep link to event

**Files:**
- Modify: `Sirr/core/push/PushAppDelegate.swift` (add `didReceive response`)

**Interfaces:**
- Consumes: payload `data.event_id`; existing deep-link channel `Notification.Name.deepLinkReceived` (posted with a `sirr://event/<id>` URL, handled by `SirrApp.onOpenURL` → `AppState.handleDeepLink`).

- [ ] **Step 1: Add the tap handler to `PushAppDelegate`**

Add this method to `PushAppDelegate`:
```swift
    // Tap on a delivered notification -> route to the event via the existing deep-link channel.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let eventId = info["event_id"] as? String,
              let url = URL(string: "sirr://event/\(eventId)") else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .deepLinkReceived, object: url)
        }
    }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr \
  -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sirr/core/push/PushAppDelegate.swift
git commit -m "feat(ios): tap push -> deep-link to event detail"
```

---

### Task 9: Secret handling — stop tracking `AuthKey.p8`

**Files:**
- Delete (untrack): `AuthKey.p8`
- Modify: `.gitignore`

**Interfaces:** none (ops). The key's contents now live only in the Edge Function env / Supabase secret.

- [ ] **Step 1: Confirm the key is already loaded into the function env**

The `APNS_AUTH_KEY` value was set from `AuthKey.p8` in Task 4 Step 7. For staging, set it as a deployed secret (Task 10 Step 1). Verify you have a copy outside git before untracking.

- [ ] **Step 2: Untrack the file and ignore `*.p8`**

```bash
cd /Users/naifalialshahrani/Documents/tamrin
git rm --cached AuthKey.p8
printf "\n*.p8\n" >> .gitignore
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore(security): stop tracking AuthKey.p8 (lives in Supabase secrets)"
```

> Rotation of the (historically leaked) key is deferred to the production cutover per the spec — not part of this staging pass.

---

### Task 10: Deploy to staging + end-to-end device verification

**Files:** none (deploy + manual test).

- [ ] **Step 1: Deploy the function and set staging secrets**

Run:
```bash
cd /Users/naifalialshahrani/Documents/tamrin
supabase functions deploy send-push
supabase secrets set \
  SEND_PUSH_SECRET="<random staging secret>" \
  APNS_KEY_ID="<key id>" \
  APNS_TEAM_ID="<team id>" \
  APNS_BUNDLE_ID="com.businessech.tmrin" \
  APNS_HOST="https://api.sandbox.push.apple.com" \
  APNS_AUTH_KEY="$(cat /path/to/AuthKey.p8)"
```
Expected: deploy succeeds; secrets set.

- [ ] **Step 2: Push migrations + set staging DB GUCs**

Run:
```bash
supabase db push
```
Then, against the staging DB, run the two `alter database` statements from `docs/superpowers/plans/push-db-settings.md` (Staging section), using the SAME secret value as `SEND_PUSH_SECRET`. Open a new connection afterward.

- [ ] **Step 3: Install the app on a REAL device (Simulator cannot get an APNs token)**

Build/run on a physical device signed with a profile that includes the Push Notifications capability.

- [ ] **Step 4: Verify token registration (creator)**

As the creator account, save an STC Pay number / create a paid event → accept the permission prompt. Then check:
```bash
psql "<staging connection>" -c \
  "select user_id, platform, updated_at from public.device_tokens order by updated_at desc limit 3;"
```
Expected: a row for the creator's user_id, `platform = 'ios'`.

- [ ] **Step 5: Verify the end-to-end push**

As a different (joiner) account on a second device or via the app, submit a payment for that creator's event. Within a few seconds:
- The creator's device shows a banner: **"طلب دفع جديد لحدث {event name}"**.
- Check the outbox flipped to sent:
```bash
psql "<staging connection>" -c \
  "select type, status, sent_at, last_error from public.push_outbox order by created_at desc limit 3;"
```
Expected: latest row `status = 'sent'`, `sent_at` populated, `last_error` null.

- [ ] **Step 6: Verify tap → event**

Tap the banner on the creator's device.
Expected: the app opens directly to that event's detail screen (via the existing deep-link routing).

- [ ] **Step 7: Final commit / branch wrap**

No code change here; ensure all prior task commits are present. The thin slice is complete when Steps 4–6 pass.

---

## Self-Review Notes

- **Spec coverage:** server-driven model (Tasks 2–4), outbox + logging (Tasks 1, 4), thin slice = one type (Task 2), contextual permission both roles (Task 7), copy only in Edge Function (Task 4 `copy.ts`), tap→deep link (Task 8), secret handling + rotation deferred (Task 9), real-device testing (Task 10) — all mapped.
- **Deferred items** (other 5 types, retry of failed rows, prod APNs host switch) are intentionally absent, per the spec's Out-of-Scope.
- **Type consistency:** `PushManager.shared` / `requestAuthorizationAndRegister()` / `upsertToken(_:)` and `copyFor(type:eventName:)` used identically across the tasks that define and consume them.
- **iOS testing note:** the repo has no XCTest target, so iOS tasks verify via `xcodebuild` + on-device steps rather than unit tests (follows existing codebase patterns). SQL and the Edge Function get real automated checks.
