# Payment setup — Moyasar

Design: docs/superpowers/specs/2026-09-06-moyasar-payments-design.md
Plan:   docs/superpowers/plans/2026-09-19-moyasar-payments.md

## Moyasar Dashboard

Take three things from Settings → API Keys:
- `sk_test_…` / `sk_live_…` — secret key. Server only. Never in Swift, xcconfig or git.
- `pk_test_…` / `pk_live_…` — publishable key. Also stored server-side; create-payment
  returns it to the app per request, so rotation needs no App Store release.
- Confirm which payment methods are enabled on the account (mada, Visa, Mastercard, Apple Pay).

Check the account before trusting it: `./scripts/moyasar-account-check.sh`, then
`./scripts/moyasar-splits-probe.sh` once you have a real recipient id.

## Supabase secrets

Two projects, two sets. Never cross them.

    # sandbox — test keys
    supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_SECRET_KEY=sk_test_…
    supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_PUBLISHABLE_KEY=pk_test_…
    supabase secrets set --project-ref kpcdinxusxycenfnitjc MOYASAR_WEBHOOK_SECRET=$(openssl rand -hex 32)

    # production — live keys, same three names
    supabase secrets set --project-ref hzsxwnmbdkrmipjtfzlp …

Deploy: `supabase functions deploy create-payment verify-payment moyasar-webhook --project-ref <ref>`

## Webhook

Moyasar Dashboard → Settings → Webhooks → add endpoint:

    https://<project-ref>.supabase.co/functions/v1/moyasar-webhook

Secret token: the exact value set as `MOYASAR_WEBHOOK_SECRET`. Events: payment_paid,
payment_captured, payment_faild, payment_voided, payment_refunded. The function
re-fetches every payment with the secret key, so a forged body cannot settle anything.

## Onboarding a workspace for card payments

There is no API for this. Once Moyasar gives you a recipient id for an organizer:

    insert into public.workspace_moyasar_recipients
      (workspace_id, moyasar_recipient_id, recipient_type, status, verified_at)
    values ('<workspace uuid>', '<recipient uuid>', 'Beneficiary', 'verified', now());

Run it as service_role (SQL editor). The card button appears for that workspace on the
next app launch. Every other workspace keeps the manual transfer flow.

### Testing before Moyasar issues a recipient id

Splits need a recipient id and Moyasar has not given us one, so without help the whole
card and Apple Pay flow cannot be exercised at all. The escape hatch is one secret, set
on the **sandbox only**:

    supabase secrets set --project-ref kpcdinxusxycenfnitjc ALLOW_PAYMENTS_WITHOUT_RECIPIENT=true

With it, `begin_card_payment` prices the seat even when the workspace has no verified
recipient, `create-payment` sends no splits array, and the payment settles into
**Tamrin's own Moyasar account** rather than the organizer's. Everything else is
unchanged: the amount is still computed on the server, still compared with the secret
key, and still captured or voided by `verify-payment`.

**Never set this on production.** Without a split the organizer receives nothing and
Tamrin becomes the merchant of record, which is question 8 in
`docs/moyasar-support-questions.md` and is unanswered. The SQL parameter defaults to
false and the secret is absent in production, so production behaves exactly as designed.
Remove the secret the day a real recipient id exists.

## Apple Pay — done on 2026-09-20, kept here for the next account or renewal

1. Apple Developer → Identifiers → Merchant IDs → `merchant.com.businessech.tmrin`. **Done.**
2. Apple Pay Payment Processing enabled on App IDs `com.businessech.tmrin` **and**
   `com.businessech.tmrin.staging`, both selecting that Merchant ID. **Done** — both
   provisioning profiles carry `com.apple.developer.in-app-payments`.
3. Moyasar Dashboard → Settings → Apple Pay - Certificate → Add Certificate → Download CSR. **Done.**
4. Apple Developer → the Merchant ID → Apple Pay Payment Processing Certificate → Create
   Certificate → "China Mainland?" **No** → upload Moyasar's CSR → download `apple_pay.cer`. **Done.**
5. Moyasar → Upload File → `apple_pay.cer` → shows "Activated". **Done.**
6. The id lives in `Config/Base.xcconfig` as `APPLE_PAY_MERCHANT_ID` and reaches the app
   through the `ApplePayMerchantID` placeholder in `Sirr/Info.plist` (the same route as
   `SUPABASE_HOST`; `INFOPLIST_KEY_` settings do not work for custom keys). Empty hides
   the button.
7. The capability is the `com.apple.developer.in-app-payments` array in
   `Sirr/Sirr.entitlements`, listing the same id. It was added by editing that file, so
   `project.pbxproj` did not change; Xcode shows it under Signing & Capabilities anyway.

Certificates expire every **25 months**: this one around **2028-10**. Renew by uploading
the new certificate to Moyasar *before* activating it at Apple; never revoke the old one
first. The production profile also lists an older `merchant.businessech.com.test` id —
harmless, detach it from the App ID if it is not in use.

## Testing (Moyasar test mode)

Cards (any two-word name, any future expiry, any 3-digit CVC):
- `4111111111111111` Visa — paid
- `4201320111111010` mada — paid
- `4123120000000000` Visa — unspecified failure
- `5105105105105100` Mastercard — unspecified failure

Apple Pay: real device, real card in Wallet, result chosen by **amount**:
- 200–300 SAR → paid · 1101–1200 → insufficient funds · 1301–1400 → declined
- Use a 250 SAR workout; a 60 SAR seat falls outside every range.

Plan:
1. Successful card → seat confirmed, `payments.status = paid`, organizer push.
2. Failed card → seat stays pending, `payments.status = failed`.
3. Cancelled → `cancelled` state in the sheet, nothing changes server-side.
4. Duplicate webhook → replay Moyasar's delivery from the dashboard; `moyasar_webhook_events`
   has one row, seat confirmed once.
5. Tampered amount → run `verify-payment` against a payment authorized for a different
   amount (curl with the SDK-created id); expect `{"status":"failed","reason":"amount"}`,
   Moyasar shows `voided`.
6. Already paid → tap card again on the same seat; `create-payment` returns `already_paid`
   before contacting Moyasar.

SQL suites: `supabase/tests/moyasar_payments_schema_test.sql`, `card_payment_rpcs_test.sql`.
Deno suites: `supabase/functions/_shared/`, `create-payment/`, `verify-payment/`, `moyasar-webhook/`.

## Refunds

Money goes back automatically in three cases: a player withdraws before the
workout starts, a player removes a guest they paid for, or the organizer cancels.
Card payments only. A bank transfer never passed through Tamrin, so there is
nothing for the app to send back.

A refund is a row in `public.refunds` before it is an API call. The amount is
worked out in the same transaction that frees the seat, because freeing it
destroys the evidence of what it cost. An `AFTER INSERT` trigger posts the row id
to the `refund-payment` function, which holds the secret key and calls
`POST /v1/payments/{id}/refund`.

Two secrets, and they must match:

    supabase secrets set --project-ref <ref> REFUND_PAYMENT_SECRET=<value>

    select vault.create_secret('https://<ref>.supabase.co/functions/v1/refund-payment',
                               'refund_payment_url');
    select vault.create_secret('<the same value>', 'refund_payment_secret');

Without the vault entries the trigger silently does nothing, which keeps a local
stack green but means **no refund is ever sent**. If refunds sit `pending` on a
deployed project, check the vault first.

The sweep `retry_pending_refunds()` re-fires anything still waiting after three
minutes, up to five attempts. Its pg_cron schedule is created by the migration,
so there is nothing to schedule by hand. Confirm it with:

    select jobname, schedule from cron.job where jobname = 'retry-pending-refunds';

To see what is stuck:

    select status, count(*), sum(amount) from public.refunds group by status;
    select * from public.refunds where status = 'failed' order by created_at desc;

A `failed` row carries Moyasar's own message. The commonest causes are a payment
already refunded in full, and a split whose share has already been settled to the
organizer.
