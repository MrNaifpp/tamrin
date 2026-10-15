# Web Push for the Member Web App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members on the web app (mostly Android) receive the same push notifications iOS members get, delivered by standard Web Push from the existing `send-push` function.

**Architecture:** Browsers save a Web Push subscription through a SECURITY DEFINER RPC into a new `web_push_subscriptions` table. `send-push` keeps reading one `push_outbox` row per notification and now delivers it to the recipient's Apple tokens **and** their browser subscriptions. The web app gets a notification-only service worker, a `push.js` module, a prompt after registering, a Settings switch, and cleanup on sign-out.

**Tech Stack:** Postgres/Supabase (plpgsql), Deno edge function with `jsr:@negrel/webpush@0.5.0`, Preact + htm web app (no build step), Netlify.

**Spec:** `docs/superpowers/specs/2026-10-08-web-push-android-design.md`

## Global Constraints

- Two repos. Database + `send-push`: **this repo** (`tamrin-designer-ui`, branch `staging`). Website: `~/Documents/tamrin-landing-page`, new branch `feat/web-push` from `origin/main`, delivered as a PR against `main`.
- Never commit `Config/Base.xcconfig`, `Sirr/Localizable.xcstrings`, `Sirr/core/supabase/SupabaseEnvironment.swift`, `docs/held-migrations/` or `project.pbxproj` in this repo — they carry uncommitted local edits that are not part of this work. Always `git add` exact paths.
- Never `supabase db push` to production. Production SQL is hand-run in the SQL editor, by Naif, after sandbox is verified.
- Sandbox project ref: `kpcdinxusxycenfnitjc`. Production project ref: `hzsxwnmbdkrmipjtfzlp`. The web app's committed `config.js` always points at production.
- Deno is not installed locally. Run Deno through Docker with Docker Desktop's credential helper on PATH: `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"`.
- Local DB: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`. `supabase db reset` is broken; rebuild with the script in Task 1 Step 1. Never re-run an already-applied migration to compare behaviour.
- Arabic UI copy is exactly as written in this plan.
- Push service hosts allowed for endpoints: `fcm.googleapis.com`, `updates.push.services.mozilla.com`, `*.notify.windows.com`, `web.push.apple.com`.
- Secrets: `VAPID_KEYS` (JWK JSON of the key pair), `VAPID_SUBJECT` = `https://guileless-squirrel-b6537a.netlify.app`. The same pair on both projects. The private key is never committed.

---

## File Structure

**This repo**

| File | Responsibility |
|---|---|
| `supabase/migrations/20261008100000_web_push_subscriptions.sql` (create) | Table, RLS, `save_web_push_subscription`, `delete_web_push_subscription` |
| `supabase/tests/web_push_subscriptions_test.sql` (create) | SQL suite for the table and RPCs |
| `supabase/functions/send-push/webpush.ts` (create) | Build the Web Push server from secrets, build the payload, send one message, classify gone subscriptions |
| `supabase/functions/send-push/webpush_test.ts` (create) | Deno tests for `webpush.ts` with a stubbed `fetch` |
| `supabase/functions/send-push/index.ts` (modify) | Load both recipient kinds, deliver to both, delete gone subscriptions |

**tamrin-landing-page**

| File | Responsibility |
|---|---|
| `app/src/push-offer.js` (create) | Pure decisions: should the prompt show, what state the Settings switch is in, base64url decoding |
| `tests/push-offer.test.html` (create) | Browser test page for `push-offer.js` |
| `app/sw.js` (create) | Service worker: show notification, open the event on tap |
| `app/src/push.js` (create) | Everything that touches the browser push APIs and the two RPCs |
| `app/src/config.js` (modify) | `VAPID_PUBLIC_KEY` |
| `netlify.toml` (modify) | No-cache header for `/app/sw.js` |
| `app/src/screens/notify.js` (create) | The «تبي ننبهك؟» sheet |
| `app/src/screens/event.js` (modify) | Show the sheet after a successful registration |
| `app/src/screens/settings.js` (modify) | Notifications switch |
| `app/src/api.js` (modify) | Remove this browser's subscription on sign-out |
| `app/src/app.js` (modify) | Quiet repair once signed in |

---

## Part A — this repo (`tamrin-designer-ui`, branch `staging`)

### Task 1: Subscriptions table and RPCs

**Files:**
- Create: `supabase/migrations/20261008100000_web_push_subscriptions.sql`
- Test: `supabase/tests/web_push_subscriptions_test.sql`

**Interfaces:**
- Produces: table `public.web_push_subscriptions(endpoint text pk, user_id uuid, p256dh text, auth text, created_at, last_seen_at)`; RPC `public.save_web_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void`; RPC `public.delete_web_push_subscription(p_endpoint text) returns void`. Both granted to `authenticated` only.

- [ ] **Step 1: Start the local stack and rebuild the local database**

```bash
supabase status >/dev/null 2>&1 || supabase start
mkdir -p /tmp/claude-501
cat > /tmp/claude-501/rebuild_db.sh <<'EOF'
#!/bin/zsh
# usage: rebuild_db.sh <repo-root>
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -q -v ON_ERROR_STOP=1 <<SQL
drop schema public cascade; create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
truncate auth.users cascade;
delete from supabase_migrations.schema_migrations;
SQL
for f in $1/supabase/migrations/*.sql; do
  [[ $f == *avatar_storage* ]] && continue
  psql "$DB" -q -v ON_ERROR_STOP=1 -f $f >/dev/null 2>/tmp/claude-501/rebuild_err || { echo "FAILED at $f"; cat /tmp/claude-501/rebuild_err; exit 1; }
done
echo "rebuilt"
EOF
chmod +x /tmp/claude-501/rebuild_db.sh
/tmp/claude-501/rebuild_db.sh "$PWD" 2>&1 | tail -1
```

Expected: `rebuilt`

- [ ] **Step 2: Write the failing test**

Create `supabase/tests/web_push_subscriptions_test.sql`:

```sql
-- Web Push subscriptions: saving, moving between accounts, deleting, and the
-- endpoint allow-list.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/web_push_subscriptions_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    case when uid is null then '{}'
         else json_build_object('sub', uid, 'role', 'authenticated')::text end,
    true
  );
end;
$$;

insert into auth.users (id, email) values
  ('48000000-0000-0000-0000-000000000001', 'push-a@test.local'),
  ('48000000-0000-0000-0000-000000000002', 'push-b@test.local');

do $$
declare
  A constant uuid := '48000000-0000-0000-0000-000000000001';
  B constant uuid := '48000000-0000-0000-0000-000000000002';
  E constant text := 'https://fcm.googleapis.com/fcm/send/test-endpoint-1';
  v_owner uuid;
  v_count int;
  v_raised boolean;
begin
  -- 1. Saving stores the subscription for the caller.
  perform pg_temp.set_auth(A);
  perform public.save_web_push_subscription(E, 'p256dh-a', 'auth-a');
  select user_id into v_owner from public.web_push_subscriptions where endpoint = E;
  assert v_owner = A, 'save should store the caller as owner';

  -- 2. The same browser signed in as someone else moves the row to them.
  perform pg_temp.set_auth(B);
  perform public.save_web_push_subscription(E, 'p256dh-b', 'auth-b');
  select count(*) into v_count from public.web_push_subscriptions where endpoint = E;
  assert v_count = 1, 'one browser is one row';
  select user_id into v_owner from public.web_push_subscriptions where endpoint = E;
  assert v_owner = B, 'the row should move to the account now signed in';
  assert (select p256dh from public.web_push_subscriptions where endpoint = E) = 'p256dh-b',
    'keys should be replaced';

  -- 3. Someone else cannot delete it.
  perform pg_temp.set_auth(A);
  perform public.delete_web_push_subscription(E);
  select count(*) into v_count from public.web_push_subscriptions where endpoint = E;
  assert v_count = 1, 'another account must not delete the row';

  -- 4. The owner can.
  perform pg_temp.set_auth(B);
  perform public.delete_web_push_subscription(E);
  select count(*) into v_count from public.web_push_subscriptions where endpoint = E;
  assert v_count = 0, 'the owner deletes the row';

  -- 5. Every allowed push service is accepted.
  perform public.save_web_push_subscription('https://updates.push.services.mozilla.com/wpush/v2/x', 'k', 'a');
  perform public.save_web_push_subscription('https://wns2-db5p.notify.windows.com/w/?token=x', 'k', 'a');
  perform public.save_web_push_subscription('https://web.push.apple.com/x', 'k', 'a');
  select count(*) into v_count from public.web_push_subscriptions where user_id = B;
  assert v_count = 3, 'mozilla, windows and apple endpoints are accepted';

  -- 6. An endpoint off the allow-list is refused.
  v_raised := false;
  begin
    perform public.save_web_push_subscription('https://evil.example.com/fcm.googleapis.com/x', 'k', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'an unknown host must be refused';

  v_raised := false;
  begin
    perform public.save_web_push_subscription('http://fcm.googleapis.com/fcm/send/x', 'k', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'plain http must be refused';

  -- 7. Missing keys are refused.
  v_raised := false;
  begin
    perform public.save_web_push_subscription(E, '', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'an empty p256dh must be refused';

  -- 8. Signed out is refused.
  perform pg_temp.set_auth(null);
  v_raised := false;
  begin
    perform public.save_web_push_subscription(E, 'k', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'saving without a session must be refused';

  -- 9. Clients cannot read the table directly.
  v_raised := false;
  begin
    execute 'set local role authenticated';
    perform 1 from public.web_push_subscriptions limit 1;
  exception when insufficient_privilege then v_raised := true;
  end;
  execute 'reset role';
  assert v_raised, 'authenticated must not select from the table';

  raise notice 'web_push_subscriptions: PASSED';
end;
$$;

rollback;
```

- [ ] **Step 3: Run it to verify it fails**

Run: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/web_push_subscriptions_test.sql 2>&1 | grep -E "ERROR|PASSED"`
Expected: `ERROR:  function public.save_web_push_subscription(text, unknown, unknown) does not exist`

- [ ] **Step 4: Write the migration**

Create `supabase/migrations/20261008100000_web_push_subscriptions.sql`:

```sql
-- Web Push for the member web app.
--
-- A browser that allows notifications hands the site a subscription: an
-- endpoint on its push service and two keys to encrypt for. send-push reads
-- these rows beside device_tokens and delivers each push_outbox row to both.
--
-- The endpoint is the key: one browser profile is one subscription. When a
-- different account signs in on the same browser, saving again moves the row
-- to them, so a shared phone never notifies the account that signed out.

create table if not exists public.web_push_subscriptions (
  endpoint      text primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  p256dh        text not null,
  auth          text not null,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

create index if not exists idx_web_push_subscriptions_user_id
  on public.web_push_subscriptions(user_id);

-- Clients reach the table only through the two RPCs below.
alter table public.web_push_subscriptions enable row level security;
revoke all on public.web_push_subscriptions from anon, authenticated;

-- send-push POSTs to whatever endpoint is stored, so only real push services
-- are accepted: FCM (Chrome, Samsung Internet, Opera, Edge on Android),
-- Mozilla (Firefox), WNS (Edge on Windows) and Apple (Safari).
create or replace function public.save_web_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if coalesce(p_endpoint, '') !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com|web\.push\.apple\.com)/' then
    raise exception 'Invalid push subscription';
  end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Invalid push subscription';
  end if;

  insert into public.web_push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, v_uid, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        last_seen_at = now();
end;
$$;

create or replace function public.delete_web_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  delete from public.web_push_subscriptions
  where endpoint = p_endpoint
    and user_id = auth.uid();
end;
$$;

revoke execute on function public.save_web_push_subscription(text, text, text) from public, anon;
grant execute on function public.save_web_push_subscription(text, text, text) to authenticated;
revoke execute on function public.delete_web_push_subscription(text) from public, anon;
grant execute on function public.delete_web_push_subscription(text) to authenticated;

notify pgrst, 'reload schema';
```

- [ ] **Step 5: Apply it and run the test**

```bash
DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB" -q -v ON_ERROR_STOP=1 -f supabase/migrations/20261008100000_web_push_subscriptions.sql && echo applied
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/web_push_subscriptions_test.sql 2>&1 | grep -E "ERROR|PASSED"
```

Expected: `applied`, then `NOTICE:  web_push_subscriptions: PASSED` and no `ERROR`.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20261008100000_web_push_subscriptions.sql supabase/tests/web_push_subscriptions_test.sql
git commit -m "feat(push): web push subscriptions table and RPCs"
```

---

### Task 2: `webpush.ts` — send one Web Push message

**Files:**
- Create: `supabase/functions/send-push/webpush.ts`
- Test: `supabase/functions/send-push/webpush_test.ts`

**Interfaces:**
- Produces:
  - `type WebSubscription = { endpoint: string; p256dh: string; auth: string }`
  - `type WebResult = { ok: boolean; status: number; text: string; gone: boolean }`
  - `webPushPayload(copy: { title: string; body: string }, eventId: string | null): string`
  - `isGone(status: number): boolean` — true for 404 and 410
  - `makeWebPushServer(opts: { vapidKeysJson: string; subject: string }): Promise<webpush.ApplicationServer>`
  - `sendWebPush(server: webpush.ApplicationServer, sub: WebSubscription, payload: string): Promise<WebResult>` — never throws

- [ ] **Step 1: Write the failing test**

Create `supabase/functions/send-push/webpush_test.ts`:

```ts
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import * as lib from "jsr:@negrel/webpush@0.5.0";
import {
  isGone,
  makeWebPushServer,
  sendWebPush,
  webPushPayload,
} from "./webpush.ts";

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// A real key pair for the server and a real browser key, so the library does
// its actual encryption; only the network is replaced.
async function fixture() {
  const vapid = await lib.generateVapidKeys({ extractable: true });
  const server = await makeWebPushServer({
    vapidKeysJson: JSON.stringify(await lib.exportVapidKeys(vapid)),
    subject: "https://guileless-squirrel-b6537a.netlify.app",
  });
  const browser = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );
  const sub = {
    endpoint: "https://fcm.googleapis.com/fcm/send/abc",
    p256dh: b64url(new Uint8Array(await crypto.subtle.exportKey("raw", browser.publicKey))),
    auth: b64url(crypto.getRandomValues(new Uint8Array(16))),
  };
  return { server, sub };
}

async function withFetch<T>(
  status: number,
  body: string,
  run: (calls: { url: string; init: RequestInit }[]) => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  const calls: { url: string; init: RequestInit }[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return Promise.resolve(new Response(body || null, { status }));
  }) as typeof fetch;
  try {
    return await run(calls);
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test("webPushPayload carries title, body and the event to open", () => {
  assertEquals(
    JSON.parse(webPushPayload({ title: "تذكير", body: "لا تنسى" }, "e-1")),
    { title: "تذكير", body: "لا تنسى", event_id: "e-1" },
  );
  assertEquals(
    JSON.parse(webPushPayload({ title: "t", body: "b" }, null)).event_id,
    null,
  );
});

Deno.test("isGone is true only for 404 and 410", () => {
  assertEquals([404, 410].map(isGone), [true, true]);
  assertEquals([400, 401, 413, 429, 500].map(isGone), [false, false, false, false, false]);
});

Deno.test("sendWebPush posts an encrypted, signed, urgent message", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(201, "", async (calls) => {
    const r = await sendWebPush(server, sub, webPushPayload({ title: "t", body: "b" }, "e-1"));
    assertEquals(calls.length, 1);
    assertEquals(calls[0].url, sub.endpoint);
    const headers = new Headers(calls[0].init.headers);
    assertEquals(headers.get("content-encoding"), "aes128gcm");
    assertEquals(headers.get("ttl"), "86400");
    assertEquals(headers.get("urgency"), "high");
    assert(headers.get("authorization")?.startsWith("vapid t="));
    return r;
  });
  assertEquals(result, { ok: true, status: 201, text: "", gone: false });
});

Deno.test("sendWebPush reports a 410 as gone", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(410, "expired", () => sendWebPush(server, sub, "{}"));
  assertEquals(result, { ok: false, status: 410, text: "expired", gone: true });
});

Deno.test("sendWebPush reports a 500 as a failure that is not gone", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(500, "busy", () => sendWebPush(server, sub, "{}"));
  assertEquals(result, { ok: false, status: 500, text: "busy", gone: false });
});

Deno.test("sendWebPush turns a broken subscription into a failure, not a throw", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(201, "", () =>
    sendWebPush(server, { ...sub, p256dh: "not-a-key" }, "{}"));
  assertEquals(result.ok, false);
  assertEquals(result.gone, false);
  assertEquals(result.status, 0);
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app/webpush_test.ts 2>&1 | tail -5
```

Expected: FAIL — `Module not found "file:///app/webpush.ts"`.

- [ ] **Step 3: Write `webpush.ts`**

Create `supabase/functions/send-push/webpush.ts`:

```ts
// Web Push (RFC 8291 encryption, RFC 8292 VAPID) for the member web app.
// The library does the cryptography with WebCrypto; this module only adapts
// it to send-push: one payload shape, results shaped like sendApns's, and no
// throws, so one bad subscription cannot fail the others.

import * as webpush from "jsr:@negrel/webpush@0.5.0";

export type WebSubscription = { endpoint: string; p256dh: string; auth: string };
export type WebResult = { ok: boolean; status: number; text: string; gone: boolean };

// What sw.js reads: the notification text and the event to open on tap.
export function webPushPayload(
  copy: { title: string; body: string },
  eventId: string | null,
): string {
  return JSON.stringify({ title: copy.title, body: copy.body, event_id: eventId });
}

// 404 and 410 mean the browser dropped the subscription (site data cleared,
// permission revoked, app uninstalled). Unlike an APNs BadDeviceToken, this is
// final: the row can be deleted.
export function isGone(status: number): boolean {
  return status === 404 || status === 410;
}

// vapidKeysJson is the VAPID_KEYS secret: the output of exportVapidKeys().
export async function makeWebPushServer(opts: {
  vapidKeysJson: string;
  subject: string;
}): Promise<webpush.ApplicationServer> {
  const vapidKeys = await webpush.importVapidKeys(JSON.parse(opts.vapidKeysJson), {
    extractable: false,
  });
  return await webpush.ApplicationServer.new({
    contactInformation: opts.subject,
    vapidKeys,
  });
}

export async function sendWebPush(
  server: webpush.ApplicationServer,
  sub: WebSubscription,
  payload: string,
): Promise<WebResult> {
  try {
    await server
      .subscribe({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } })
      // A day is long enough to reach a phone that was off overnight, and short
      // enough that a reminder never arrives after the workout.
      .pushTextMessage(payload, { ttl: 86400, urgency: webpush.Urgency.High });
    return { ok: true, status: 201, text: "", gone: false };
  } catch (error) {
    if (error instanceof webpush.PushMessageError) {
      const status = error.response.status;
      const text = await error.response.text().catch(() => "");
      return { ok: false, status, text, gone: isGone(status) };
    }
    return { ok: false, status: 0, text: String(error), gone: false };
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app/webpush_test.ts 2>&1 | tail -5
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app/copy_test.ts 2>&1 | tail -2
```

Expected: `ok | 6 passed | 0 failed` for `webpush_test.ts`, and `copy_test.ts` still all passing.

If `webpush.Urgency.High` or `ApplicationServer.subscribe` does not exist in 0.5.0, the type check fails here. Read `https://jsr.io/@negrel/webpush/0.5.0/subscriber.ts` and `application_server.ts`, adjust only the call site in `webpush.ts`, and keep the exported signatures above unchanged.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/webpush.ts supabase/functions/send-push/webpush_test.ts
git commit -m "feat(push): web push sender for send-push"
```

---

### Task 3: `send-push` delivers to browsers too, deployed to sandbox

**Files:**
- Modify: `supabase/functions/send-push/index.ts` (steps 3 and 6, and imports)

**Interfaces:**
- Consumes: `makeWebPushServer`, `sendWebPush`, `webPushPayload`, `WebResult` from Task 2; table `web_push_subscriptions` from Task 1.
- Produces: the deployed sandbox function; the VAPID **application server key** (base64url public key) that Task 5 puts in `config.js`.

- [ ] **Step 1: Update the imports**

In `supabase/functions/send-push/index.ts`, replace:

```ts
import { makeApnsJwt, sendApns } from "./apns.ts";
```

with:

```ts
import { makeApnsJwt, sendApns } from "./apns.ts";
import { makeWebPushServer, sendWebPush, type WebResult, webPushPayload } from "./webpush.ts";
```

- [ ] **Step 2: Load both kinds of recipient**

Replace step 3:

```ts
  // 3. Recipient tokens.
  const { data: tokens } = await admin
    .from("device_tokens")
    .select("apns_token")
    .eq("user_id", row.user_id);
  if (!tokens || tokens.length === 0) return await fail("no device tokens");
```

with:

```ts
  // 3. Recipients: the iPhones the person signed in on, and the browsers that
  // allowed notifications (the web app, mostly Android).
  const { data: tokens } = await admin
    .from("device_tokens")
    .select("apns_token")
    .eq("user_id", row.user_id);
  const { data: webSubs } = await admin
    .from("web_push_subscriptions")
    .select("endpoint, p256dh, auth")
    .eq("user_id", row.user_id);
  const apple = tokens ?? [];
  const web = webSubs ?? [];
  if (apple.length === 0 && web.length === 0) return await fail("no device tokens");
```

- [ ] **Step 3: Deliver to both**

Replace everything from the line `  // 6. Sign + send to every device.` down to and including `  const results = await Promise.all(tokens.map((t) => deliver(t.apns_token)));` with:

```ts
  // 6a. Apple: sign once, send to every device.
  // 400 BadDeviceToken means the token belongs to the other environment, not
  // that it is dead — the same token still delivers on the sibling host.
  const isWrongEnvironment = (r: { status: number; text: string }) =>
    r.status === 400 && r.text.includes("BadDeviceToken");

  const deliverApple = async (jwt: string, deviceToken: string) => {
    const payload = {
      deviceToken,
      topic: APNS_TOPIC,
      jwt,
      title: copy.title,
      body: copy.body,
      data: { event_id: row.event_id },
    };
    const first = await sendApns({ host: APNS_HOST, ...payload });
    if (first.ok || !isWrongEnvironment(first)) return first;

    const second = await sendApns({ host: APNS_FALLBACK_HOST, ...payload });
    if (second.ok) return second;
    // Both environments rejected it. Keep each answer so the outbox says why.
    return {
      ...second,
      text: `${APNS_HOST} -> ${first.text}; ${APNS_FALLBACK_HOST} -> ${second.text}`,
    };
  };

  const appleResults = apple.length === 0 ? [] : await (async () => {
    const jwt = await makeApnsJwt({
      keyId: Deno.env.get("APNS_KEY_ID")!,
      teamId: Deno.env.get("APNS_TEAM_ID")!,
      authKeyPem: Deno.env.get("APNS_AUTH_KEY")!,
      nowSeconds: Math.floor(Date.now() / 1000),
    });
    return await Promise.all(apple.map((t) => deliverApple(jwt, t.apns_token)));
  })();

  // 6b. Browsers. A subscription the push service calls gone is deleted, so
  // dead browsers do not pile up the way old device tokens have.
  const webResults: WebResult[] = web.length === 0 ? [] : await (async () => {
    let server;
    try {
      server = await makeWebPushServer({
        vapidKeysJson: Deno.env.get("VAPID_KEYS") ?? "",
        subject: Deno.env.get("VAPID_SUBJECT") ?? "",
      });
    } catch (error) {
      // Missing or malformed secrets: record it rather than crash, so Apple
      // deliveries in the same row still count.
      return web.map(() => ({ ok: false, status: 0, text: `web push setup: ${error}`, gone: false }));
    }
    const payload = webPushPayload(copy, row.event_id ?? null);
    return await Promise.all(web.map(async (s) => {
      const result = await sendWebPush(server, s, payload);
      if (result.gone) {
        await admin.from("web_push_subscriptions").delete().eq("endpoint", s.endpoint);
      }
      return result;
    }));
  })();

  const results = [...appleResults, ...webResults];
```

The block that follows (`const anyOk = results.some((r) => r.ok);` and the outbox update) stays as it is.

- [ ] **Step 4: Type-check the function**

```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine check /app/index.ts 2>&1 | tail -5
docker run --rm -v "$PWD/supabase/functions/send-push":/app denoland/deno:alpine test /app 2>&1 | tail -3
```

Expected: `check` prints nothing after the download lines (no `error:`); the test run ends with `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/send-push/index.ts
git commit -m "feat(push): send-push delivers to web push subscriptions"
```

- [ ] **Step 6: Generate the VAPID key pair (once, outside the repo)**

`--quiet` keeps Deno's download lines out of the output, so stdout is only the JSON.

```bash
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
SCRATCH=/private/tmp/claude-501/-Users-naifalialshahrani-Documents-tamrin-designer-ui/716ea60c-5172-4fba-8aa2-405c213e4a28/scratchpad
docker run --rm denoland/deno:alpine eval --quiet '
  import * as w from "jsr:@negrel/webpush@0.5.0";
  const keys = await w.generateVapidKeys({ extractable: true });
  console.log(JSON.stringify({ pair: await w.exportVapidKeys(keys), publicKey: await w.exportApplicationServerKey(keys) }));
' > "$SCRATCH/vapid-all.json"
python3 - "$SCRATCH" <<'PY'
import json, sys
d = json.load(open(f"{sys.argv[1]}/vapid-all.json"))
json.dump(d["pair"], open(f"{sys.argv[1]}/vapid.json", "w"))
print(sorted(d["pair"]), d["publicKey"], len(d["publicKey"]))
PY
```

Expected: `['privateKey', 'publicKey'] B... 87` — the second value is the **application server key** for Task 5. Tell Naif to save `vapid.json` in his password manager: it is the private key, and losing it means every browser has to subscribe again.

- [ ] **Step 7: Ask Naif before touching sandbox, then set secrets and deploy**

This writes to the sandbox project. Get a yes in chat first, then:

```bash
supabase secrets set --project-ref kpcdinxusxycenfnitjc \
  VAPID_KEYS="$(cat "$SCRATCH/vapid.json")" \
  VAPID_SUBJECT="https://guileless-squirrel-b6537a.netlify.app"
supabase db push --project-ref kpcdinxusxycenfnitjc --dry-run
```

`db push` on sandbox requires the CLI to be linked to sandbox (`supabase/.temp/project-ref` reads `kpcdinxusxycenfnitjc`). If the dry run lists anything other than `20261008100000_web_push_subscriptions.sql`, or errors about migration history, do not push: Naif pastes the migration file into the sandbox SQL editor instead. Otherwise:

```bash
supabase db push
supabase functions deploy send-push --project-ref kpcdinxusxycenfnitjc
```

Expected: the migration applies; the deploy ends with `Deployed Functions on project kpcdinxusxycenfnitjc: send-push`.

- [ ] **Step 8: Prove iOS pushes still work on sandbox**

Naif triggers any push he normally receives on the sandbox TestFlight build (for example, registering for a sandbox workout he organizes from a second account). Expected: the iPhone notification arrives as before. In the sandbox SQL editor:

```sql
select type, status, last_error, sent_at from public.push_outbox order by created_at desc limit 5;
```

Expected: the newest row is `sent` with `last_error` null.

- [ ] **Step 9: Push the branch**

Per the team rule, pull first (Faris shares `staging`), then push:

```bash
git pull --rebase origin staging && git push origin staging
```

---

## Part B — `tamrin-landing-page` (branch `feat/web-push`)

All paths below are relative to `~/Documents/tamrin-landing-page`.

### Task 4: Pure push decisions with browser tests

**Files:**
- Create: `app/src/push-offer.js`
- Test: `tests/push-offer.test.html`

**Interfaces:**
- Produces (ES module, no imports):
  - `LATER_DAYS = 14`
  - `shouldOffer({ supported: boolean, permission: 'default'|'granted'|'denied', laterAt: number|null, now: number }): boolean`
  - `switchState({ supported: boolean, permission: string, subscribed: boolean }): 'unsupported'|'blocked'|'on'|'off'`
  - `base64UrlToBytes(value: string): Uint8Array`

- [ ] **Step 1: Create the branch**

```bash
cd ~/Documents/tamrin-landing-page
git fetch origin && git switch -c feat/web-push origin/main
```

- [ ] **Step 2: Write the failing test page**

Create `tests/push-offer.test.html`:

```html
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8" />
  <title>اختبارات التنبيهات</title>
  <style>
    body { font: 15px/1.6 system-ui, sans-serif; padding: 24px; background: #f3f3f3; }
    h1 { font-size: 19px; margin-block-end: 16px; }
    .pass { color: #2f7a48; }
    .fail { color: #b3261e; font-weight: 700; }
    ol { padding-inline-start: 22px; }
    #summary { margin-block-end: 14px; font-weight: 700; }
  </style>
</head>
<body>
  <h1>اختبارات التنبيهات — push-offer.js</h1>
  <div id="summary">جارٍ التنفيذ…</div>
  <ol id="out"></ol>

  <script type="module">
    const results = { passed: 0, failed: 0, failures: [] };
    const out = document.getElementById('out');
    const summary = document.getElementById('summary');

    function test(name, fn) {
      let error = null;
      try { fn(); } catch (e) { error = e && e.message ? e.message : String(e); }
      const li = document.createElement('li');
      if (error) {
        results.failed++;
        results.failures.push(name + ': ' + error);
        li.className = 'fail';
        li.textContent = 'FAIL — ' + name + ' — ' + error;
      } else {
        results.passed++;
        li.className = 'pass';
        li.textContent = 'PASS — ' + name;
      }
      out.appendChild(li);
    }

    function eq(actual, expected, what) {
      const a = JSON.stringify(actual), b = JSON.stringify(expected);
      if (a !== b) throw new Error((what || 'value') + ' expected ' + b + ' got ' + a);
    }

    let P;
    try {
      P = await import('../app/src/push-offer.js');
    } catch (e) {
      summary.textContent = 'FAIL — could not load push-offer.js: ' + e.message;
      summary.className = 'fail';
      window.__results = { passed: 0, failed: 1, failures: ['load: ' + e.message] };
      throw e;
    }

    const DAY = 86400000;
    const NOW = 1_800_000_000_000;

    test('offers when supported, undecided, and never postponed', () => {
      eq(P.shouldOffer({ supported: true, permission: 'default', laterAt: null, now: NOW }), true);
    });

    test('never offers where push is unsupported', () => {
      eq(P.shouldOffer({ supported: false, permission: 'default', laterAt: null, now: NOW }), false);
    });

    test('never offers once allowed or blocked', () => {
      eq(P.shouldOffer({ supported: true, permission: 'granted', laterAt: null, now: NOW }), false, 'granted');
      eq(P.shouldOffer({ supported: true, permission: 'denied', laterAt: null, now: NOW }), false, 'denied');
    });

    test('«لاحقاً» holds the offer back for 14 days', () => {
      eq(P.LATER_DAYS, 14, 'LATER_DAYS');
      eq(P.shouldOffer({ supported: true, permission: 'default', laterAt: NOW - 13 * DAY, now: NOW }), false, '13 days');
      eq(P.shouldOffer({ supported: true, permission: 'default', laterAt: NOW - 14 * DAY, now: NOW }), true, '14 days');
    });

    test('switchState covers every case', () => {
      eq(P.switchState({ supported: false, permission: 'default', subscribed: false }), 'unsupported');
      eq(P.switchState({ supported: true, permission: 'denied', subscribed: false }), 'blocked');
      eq(P.switchState({ supported: true, permission: 'granted', subscribed: true }), 'on');
      eq(P.switchState({ supported: true, permission: 'granted', subscribed: false }), 'off');
      eq(P.switchState({ supported: true, permission: 'default', subscribed: false }), 'off');
    });

    test('base64UrlToBytes decodes unpadded base64url', () => {
      eq(Array.from(P.base64UrlToBytes('AQID')), [1, 2, 3], 'no padding needed');
      eq(Array.from(P.base64UrlToBytes('-_8')), [251, 255], 'url alphabet, padding restored');
    });

    summary.textContent = results.failed
      ? `FAIL — ${results.failed} failed, ${results.passed} passed`
      : `PASS — ${results.passed} passed`;
    summary.className = results.failed ? 'fail' : 'pass';
    window.__results = results;
  </script>
</body>
</html>
```

- [ ] **Step 3: Run it to verify it fails**

```bash
python3 tools/serve.py 8765 >/dev/null 2>&1 &
```

Open `http://127.0.0.1:8765/tests/push-offer.test.html` in the built-in browser and read `window.__results`.
Expected: summary shows `FAIL — could not load push-offer.js`.

- [ ] **Step 4: Write `push-offer.js`**

Create `app/src/push-offer.js`:

```js
/// The decisions behind notifications, kept free of browser APIs so
/// tests/push-offer.test.html can check them directly.

/// «لاحقاً» on the prompt holds it back this long.
export const LATER_DAYS = 14

/// Whether to show «تبي ننبهك؟» after a registration. Only an undecided
/// browser is asked: once someone allows or blocks, Chrome will not show its
/// prompt again, so asking would only frustrate them.
export function shouldOffer({ supported, permission, laterAt, now }) {
  if (!supported || permission !== 'default') return false
  if (!laterAt) return true
  return now - laterAt >= LATER_DAYS * 86400000
}

/// What the Settings switch shows.
export function switchState({ supported, permission, subscribed }) {
  if (!supported) return 'unsupported'
  if (permission === 'denied') return 'blocked'
  return permission === 'granted' && subscribed ? 'on' : 'off'
}

/// The VAPID public key travels as unpadded base64url; pushManager.subscribe
/// wants the raw bytes.
export function base64UrlToBytes(value) {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4)
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))
}
```

- [ ] **Step 5: Run the test page to verify it passes**

Reload `http://127.0.0.1:8765/tests/push-offer.test.html`.
Expected: `PASS — 6 passed`, and `window.__results.failed === 0`.

- [ ] **Step 6: Commit**

```bash
git add app/src/push-offer.js tests/push-offer.test.html
git commit -m "Add the pure notification decisions with browser tests"
```

---

### Task 5: Service worker and the push module

**Files:**
- Create: `app/sw.js`
- Create: `app/src/push.js`
- Modify: `app/src/config.js` (append)
- Modify: `netlify.toml` (add a header rule)

**Interfaces:**
- Consumes: `shouldOffer`, `switchState`, `base64UrlToBytes` (Task 4); RPCs `save_web_push_subscription`, `delete_web_push_subscription` (Task 1); the application server key printed in Task 3 Step 6.
- Produces (from `app/src/push.js`):
  - `isSupported(): boolean`
  - `enable(): Promise<boolean>` — must be called directly from a tap; true once subscribed and saved
  - `disable({ rememberOff = true } = {}): Promise<void>`
  - `repair(): Promise<void>`
  - `pushState(): Promise<'unsupported'|'blocked'|'on'|'off'>`
  - `shouldOfferNow(): boolean`
  - `rememberLater(): void`

- [ ] **Step 1: Add the public key to `config.js`**

Append to `app/src/config.js`, pasting the key printed in Task 3 Step 6 (it starts with `B`):

```js

/// Web Push: the public half of the VAPID key pair whose private half is the
/// VAPID_KEYS secret on both Supabase projects. Public by design — every
/// browser that subscribes receives it.
export const VAPID_PUBLIC_KEY = '<the application server key from Task 3 Step 6>'
```

- [ ] **Step 2: Write the service worker**

Create `app/sw.js`:

```js
// تمرين's service worker. It exists only for notifications: no fetch handler,
// no caching, so the site behaves exactly as it does without it.
//
// Served from /app/sw.js with scope /app/. Pushes reach it whatever page is
// open, and a tap opens /event/<id>, which the site already routes.

self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

self.addEventListener('push', (event) => {
  let data = {}
  try { data = event.data ? event.data.json() : {} } catch { data = {} }
  event.waitUntil(
    self.registration.showNotification(data.title || 'تمرين', {
      body: data.body || '',
      dir: 'rtl',
      lang: 'ar',
      icon: '/assets/favicon.png',
      data: { eventId: data.event_id || null }
    })
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const eventId = event.notification.data && event.notification.data.eventId
  const target = new URL(eventId ? `/event/${encodeURIComponent(eventId)}` : '/app/', self.location.origin).href
  event.waitUntil((async () => {
    const tabs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    const open = tabs.find((tab) => tab.url === target)
    if (open) return open.focus()
    return self.clients.openWindow(target)
  })())
})
```

- [ ] **Step 3: Keep the service worker uncached**

In `netlify.toml`, add after the `/assets/*` header block:

```toml
# The service worker must never be cached, or a fix to it waits for the cache
# to expire on every phone that has it.
[[headers]]
  for = "/app/sw.js"
  [headers.values]
    Cache-Control = "no-cache"
```

- [ ] **Step 4: Write `push.js`**

Create `app/src/push.js`:

```js
import { supabase } from './supabase.js'
import { DEMO } from './fixture.js'
import { VAPID_PUBLIC_KEY } from './config.js'
import { shouldOffer, switchState, base64UrlToBytes } from './push-offer.js'

/// Notifications for the web app — everything that touches the browser's push
/// APIs lives here. send-push delivers to the subscriptions saved below, beside
/// the iPhones in device_tokens.

const SW_URL = '/app/sw.js'
const SW_SCOPE = '/app/'
const LATER_KEY = 'tamrin.push.laterAt'
const OFF_KEY = 'tamrin.push.off'

function read(key) {
  try { return localStorage.getItem(key) } catch { return null }
}
function write(key, value) {
  try { value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value) } catch {}
}

/// Feature-detected, not sniffed: this is false in Instagram's and Snapchat's
/// in-app browsers, in incognito, and in iPhone Safari outside the home screen.
export function isSupported() {
  return !DEMO &&
    typeof window !== 'undefined' &&
    window.isSecureContext &&
    'serviceWorker' in navigator &&
    'PushManager' in window &&
    'Notification' in window
}

const currentPermission = () => (isSupported() ? Notification.permission : 'default')

async function save(subscription) {
  const { endpoint, keys } = subscription.toJSON()
  const { error } = await supabase.rpc('save_web_push_subscription', {
    p_endpoint: endpoint,
    p_p256dh: keys.p256dh,
    p_auth: keys.auth
  })
  if (error) throw error
}

async function subscribe() {
  const registration = await navigator.serviceWorker.register(SW_URL, { scope: SW_SCOPE })
  await navigator.serviceWorker.ready
  const existing = await registration.pushManager.getSubscription()
  return existing ?? registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: base64UrlToBytes(VAPID_PUBLIC_KEY)
  })
}

async function existingSubscription() {
  const registration = await navigator.serviceWorker.getRegistration(SW_SCOPE)
  return (await registration?.pushManager.getSubscription()) ?? null
}

/// Call this directly from a tap: Chrome only shows its prompt in response to
/// one, so requestPermission is the first thing that happens.
export async function enable() {
  if (!isSupported()) return false
  const answer = await Notification.requestPermission()
  if (answer !== 'granted') return false
  write(OFF_KEY, null)
  await save(await subscribe())
  return true
}

/// Turning the switch off is remembered so repair() leaves it off. Signing out
/// passes rememberOff: false, so whoever signs in next is repaired normally.
export async function disable({ rememberOff = true } = {}) {
  if (!isSupported()) return
  if (rememberOff) write(OFF_KEY, '1')
  const subscription = await existingSubscription()
  if (!subscription) return
  await supabase.rpc('delete_web_push_subscription', { p_endpoint: subscription.endpoint })
  await subscription.unsubscribe()
}

/// Once signed in: if notifications are allowed but the subscription is gone
/// (site data cleared, a new account on this browser), put it back quietly.
/// Saving also refreshes last_seen_at and binds the browser to this account.
export async function repair() {
  if (!isSupported() || currentPermission() !== 'granted' || read(OFF_KEY) === '1') return
  await save(await subscribe())
}

export async function pushState() {
  if (!isSupported()) return 'unsupported'
  return switchState({
    supported: true,
    permission: currentPermission(),
    subscribed: Boolean(await existingSubscription())
  })
}

export function shouldOfferNow() {
  const laterAt = Number(read(LATER_KEY)) || null
  return shouldOffer({ supported: isSupported(), permission: currentPermission(), laterAt, now: Date.now() })
}

export function rememberLater() {
  write(LATER_KEY, String(Date.now()))
}
```

- [ ] **Step 5: Check the module loads and the worker is served uncached**

With `tools/serve.py 8765` still running, open `http://127.0.0.1:8765/app/` in the built-in browser and run in its console:

```js
const m = await import('/app/src/push.js'); [typeof m.enable, m.isSupported(), (await fetch('/app/sw.js')).headers.get('content-type')]
```

Expected: `["function", true, "text/javascript…"]` (any JavaScript content type). The Netlify header itself is checked on the deploy preview in Task 7.

- [ ] **Step 6: Commit**

```bash
git add app/sw.js app/src/push.js app/src/config.js netlify.toml
git commit -m "Add the notification service worker and push module"
```

---

### Task 6: Ask after registering, Settings switch, sign-out, repair

**Files:**
- Create: `app/src/screens/notify.js`
- Modify: `app/src/screens/event.js` (imports; the RegistrationSheet `onDone`; one new sheet)
- Modify: `app/src/screens/settings.js`
- Modify: `app/src/api.js:140-143` (`signOut`)
- Modify: `app/src/app.js` (repair effect)

**Interfaces:**
- Consumes: `enable`, `disable`, `repair`, `pushState`, `shouldOfferNow`, `rememberLater` from `app/src/push.js` (Task 5).
- Produces: `NotifySheet({ onClose, onEnabled, onFailed })` in `app/src/screens/notify.js`.

- [ ] **Step 1: Write the sheet**

Create `app/src/screens/notify.js`:

```js
import { html, useState } from '../../vendor/preact.js'
import { Sheet } from '../ui.js'
import { useDismissible } from '../motion.js'
import { enable, rememberLater } from '../push.js'

/// Shown once a registration succeeds — the moment reminders and payment
/// notices obviously matter. The browser's own prompt follows the tap on
/// «فعّل التنبيهات»; closing the sheet any other way counts as «لاحقاً».
export function NotifySheet({ onClose, onEnabled, onFailed }) {
  const { closing, dismiss } = useDismissible(null)
  const [busy, setBusy] = useState(false)

  async function turnOn() {
    setBusy(true)
    try {
      const granted = await enable()
      dismiss(() => { onClose(); if (granted) onEnabled() })
    } catch {
      dismiss(() => { onClose(); onFailed('تعذر تفعيل التنبيهات. جرّب من الإعدادات.') })
    }
  }

  const later = () => { rememberLater(); onClose() }

  return html`
    <${Sheet} title="تبي ننبهك؟" onClose=${later} closing=${closing}>
      <div class="vstack" style="gap:14px">
        <p class="confirm-message">نذكّرك قبل التمرين، ونبلغك بالدفع وبكل جديد في مجموعتك.</p>
        <button class="action action-prominent" disabled=${busy} onClick=${turnOn}>فعّل التنبيهات</button>
        <button class="action action-glass" disabled=${busy} onClick=${() => dismiss(later)}>لاحقاً</button>
      </div>
    <//>
  `
}
```

- [ ] **Step 2: Offer it after a successful registration**

In `app/src/screens/event.js`, add to the imports:

```js
import { NotifySheet } from './notify.js'
import { shouldOfferNow } from '../push.js'
```

Replace the RegistrationSheet `onDone`:

```js
        onDone=${async (message) => {
          setSheet(null)
          if (message) flash(message)
          await refresh()
        }}
```

with:

```js
        onDone=${async (message) => {
          // A fresh registration is when notifications earn their ask; adding
          // guests or paying is not.
          const offer = sheet === 'register' && shouldOfferNow()
          setSheet(offer ? 'notify' : null)
          if (message) flash(message)
          await refresh()
        }}
```

Then add, directly after the closing `/>\`}` of the `CardPaymentSheet` block:

```js
      ${sheet === 'notify' &&
      html`<${NotifySheet}
        onClose=${() => setSheet(null)}
        onEnabled=${() => flash('فعّلنا التنبيهات')}
        onFailed=${flash}
      />`}
```

- [ ] **Step 3: Add the Settings switch**

In `app/src/screens/settings.js`, change the first two import lines to:

```js
import { html, useState, useEffect } from '../../vendor/preact.js'
import { saveProfile, signOut } from '../api.js'
import { pushState, enable, disable } from '../push.js'
```

After `const [message, setMessage] = useState(null)` add:

```js
  // null while the browser is being asked; 'unsupported' hides the row.
  const [push, setPush] = useState(null)
  const [pushBusy, setPushBusy] = useState(false)
  useEffect(() => { pushState().then(setPush).catch(() => setPush('unsupported')) }, [])

  async function togglePush() {
    setPushBusy(true)
    try {
      if (push === 'on') await disable()
      else await enable()
      setPush(await pushState())
    } catch {
      setMessage('تعذر تغيير التنبيهات. حاول مرة أخرى.')
    } finally {
      setPushBusy(false)
    }
  }
```

Insert directly before `${message && html\`<div class="notice notice-error">${message}</div>\`}`:

```js
          ${push && push !== 'unsupported' && html`
            <div>
              <span class="field-label">التنبيهات</span>
              <div class="chips">
                <button class="chip" aria-pressed=${push === 'on'}
                        disabled=${push === 'blocked' || pushBusy}
                        onClick=${togglePush}>
                  ${push === 'on' ? 'مفعّلة' : 'متوقفة'}
                </button>
              </div>
              ${push === 'blocked' && html`
                <div class="notice notice-info" style="margin-top:10px">
                  التنبيهات محظورة لهذا الموقع. اضغط رمز القفل بجانب العنوان في المتصفح، واسمح بالإشعارات.
                </div>
              `}
            </div>
          `}
```

- [ ] **Step 4: Remove this browser's subscription on sign-out**

In `app/src/api.js`, add to the imports at the top:

```js
import { disable as disablePush } from './push.js'
```

Replace:

```js
export async function signOut() {
  if (DEMO) return
  await supabase.auth.signOut()
}
```

with:

```js
export async function signOut() {
  if (DEMO) return
  // While the session still exists, so the delete RPC knows who is asking.
  // Not remembered as «off»: the next account on this browser gets repaired.
  await disablePush({ rememberOff: false }).catch(() => {})
  await supabase.auth.signOut()
}
```

- [ ] **Step 5: Repair once signed in**

In `app/src/app.js`, add to the imports:

```js
import { repair as repairPush } from './push.js'
```

After the line `useEffect(() => { loadProfile() }, [loadProfile])` add:

```js
  // Notifications allowed but the subscription lost, or a new account on this
  // browser: re-save quietly. Never prompts.
  useEffect(() => { if (session) repairPush().catch(() => {}) }, [session])
```

- [ ] **Step 6: Check nothing broke in demo mode**

Open `http://127.0.0.1:8765/app/?demo=1` in the built-in browser. Open an upcoming event, register, and confirm: no console errors (`read_console_messages` with `onlyErrors`), the toast appears, and **no** «تبي ننبهك؟» sheet appears (`isSupported()` is false in demo). Open Settings: no التنبيهات row. Then run `tests/push-offer.test.html` again: `PASS — 6 passed`.

- [ ] **Step 7: Commit**

```bash
git add app/src/screens/notify.js app/src/screens/event.js app/src/screens/settings.js app/src/api.js app/src/app.js
git commit -m "Ask for notifications after registering, with a Settings switch"
```

---

### Task 7: End-to-end check against sandbox, then the PR

**Files:** none committed. `app/src/config.js` is pointed at sandbox temporarily and restored before anything is pushed.

- [ ] **Step 1: Point the local copy at sandbox (never committed)**

```bash
supabase projects api-keys --project-ref kpcdinxusxycenfnitjc | grep -E "^\s*anon"
```

In `app/src/config.js`, temporarily set `SUPABASE_HOST = 'kpcdinxusxycenfnitjc.supabase.co'` and `SUPABASE_ANON_KEY` to the **legacy anon JWT** printed above (it starts with `eyJ`; never an `sb_publishable_` key).

- [ ] **Step 2: Naif subscribes in desktop Chrome**

`127.0.0.1` counts as a secure origin, so service workers work there. Use `127.0.0.1` throughout — `localhost` is a different origin with its own permission. Naif opens `http://127.0.0.1:8765/event/<a sandbox event id he can register for>` in desktop Chrome, signs in with his sandbox account, registers, taps «فعّل التنبيهات», and allows the browser prompt.

Then in the sandbox SQL editor:

```sql
select endpoint, user_id, created_at from public.web_push_subscriptions order by created_at desc limit 3;
```

Expected: one row with an `https://fcm.googleapis.com/...` endpoint and Naif's sandbox user id.

- [ ] **Step 3: Fire a push and tap it**

In the sandbox SQL editor, replacing both ids with that row's `user_id` and the event used above:

```sql
insert into public.push_outbox (user_id, type, event_id)
values ('<naif sandbox user id>', 'event_reminder', '<sandbox event id>');
```

Expected: a desktop notification «تذكير بتمرينك ⏰» within a few seconds; clicking it opens `/event/<id>`. Then:

```sql
select status, last_error from public.push_outbox order by created_at desc limit 1;
```

Expected: `sent`, `last_error` null.

- [ ] **Step 4: Gone subscriptions are cleaned up**

In Chrome, Settings → Privacy → Site settings → `127.0.0.1:8765` → **Reset permissions** (this drops the subscription). Insert the same `push_outbox` row again. Expected: the row ends `failed` with `410:` or `404:` in `last_error`, and `web_push_subscriptions` no longer has that endpoint.

- [ ] **Step 5: Switch off from Settings**

Allow notifications again from the post-registration sheet or Settings, then switch «مفعّلة» → «متوقفة» in Settings. Expected: the row disappears from `web_push_subscriptions`; reloading the page does **not** recreate it.

- [ ] **Step 6: Restore production config and confirm**

```bash
git checkout app/src/config.js 2>/dev/null; git diff --stat
grep -n "hzsxwnmbdkrmipjtfzlp" app/src/config.js
grep -n "VAPID_PUBLIC_KEY = 'B" app/src/config.js
```

`git checkout app/src/config.js` restores the committed version, which includes `VAPID_PUBLIC_KEY` from Task 5. Expected: `git diff --stat` is empty; both greps match.

- [ ] **Step 7: Push the branch and open the PR (ask Naif first)**

Opening a PR publishes the branch. With Naif's yes:

```bash
git push -u origin feat/web-push
gh pr create --base main --head feat/web-push \
  --title "Web Push notifications for the member web app" \
  --body "$(cat <<'EOF'
Members on the web app (mostly Android) now get the same notifications as the iOS app.

- `app/sw.js`: notification-only service worker; a tap opens `/event/<id>`. No fetch handler, no caching.
- `app/src/push.js`: subscribe, save via `save_web_push_subscription`, unsubscribe, quiet repair.
- «تبي ننبهك؟» sheet after a successful registration; «لاحقاً» holds it back 14 days.
- Settings: notifications switch; explains how to unblock when the browser has blocked it.
- Sign-out removes this browser's subscription.
- Feature-detected: hidden in in-app browsers, incognito and iPhone Safari.

**Do not merge until** the production database has `web_push_subscriptions` and `send-push` with `VAPID_KEYS` is deployed to production — otherwise saving a subscription fails.

Tests: `tests/push-offer.test.html`. End-to-end verified on desktop Chrome against the sandbox project.
EOF
)"
```

Expected: a PR URL on `MrNaifpp/tamrin-landing-page`.

---

## Part C — Production release (Naif runs it, in this order)

Not part of task execution; listed so the order is not lost.

1. Production SQL editor (`hzsxwnmbdkrmipjtfzlp`): paste and run `supabase/migrations/20261008100000_web_push_subscriptions.sql`. Then confirm the function body is live, not just recorded:
   ```sql
   select proname from pg_proc where proname in ('save_web_push_subscription', 'delete_web_push_subscription');
   ```
   Expected: both names.
2. Set the same secrets on production:
   ```bash
   supabase secrets set --project-ref hzsxwnmbdkrmipjtfzlp VAPID_KEYS="$(cat vapid.json)" VAPID_SUBJECT="https://guileless-squirrel-b6537a.netlify.app"
   ```
3. Deploy the function: `supabase functions deploy send-push --project-ref hzsxwnmbdkrmipjtfzlp`. Confirm an iOS push still arrives.
4. Merge the landing-page PR. Netlify deploys it.
5. Naif tests on an Android phone in Chrome: register for a workout → «فعّل التنبيهات» → allow → wait for (or trigger) a push → tap opens the event.
