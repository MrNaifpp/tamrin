# Payment setup — MyFatoorah Apple Pay

Design: docs/superpowers/specs/2026-11-11-myfatoorah-apple-pay-design.md
Plan:   docs/superpowers/plans/2026-11-11-myfatoorah-apple-pay.md

Apple Pay only. The app shows Apple's own sheet and sends the token to
`pay-apple-pay`; the server charges it through MyFatoorah with a key the app never
holds. Members without Apple Pay keep the manual transfer. All money lands in
Tamrin's MyFatoorah account.

## MyFatoorah portal (sa.myfatoorah.com)

**API key** — Integration Settings → API Keys → Add. Permissions: create payments,
get payment details, refunds. Nothing else. Set an expiry date. Copy it into the
password manager; it never goes in Swift, xcconfig, git or chat.

**Check what the account has** (asks for the key without showing it):

    read -rs MF_KEY && curl -s https://api-sa.myfatoorah.com/v3/payment-methods -H "Authorization: Bearer $MF_KEY"; unset MF_KEY

Apple Pay must be in the list.

**Ask MyFatoorah's tech team (tech@myfatoorah.com)** to confirm in writing:
1. Apple Pay native (in-app) integration, and send the **CSR file**.
2. Auto Refund — on or off. Off means every refund waits for their finance team.
3. Webhook V2 enabled.

## Apple Pay certificate

Merchant ID `merchant.com.businessech.tmrin`, already on both App IDs
(`com.businessech.tmrin`, `com.businessech.tmrin.staging`) since 2026-09-20.

1. Get the CSR file from MyFatoorah (email, not the portal).
2. Apple Developer → Identifiers → Merchant IDs → `merchant.com.businessech.tmrin` →
   Apple Pay Payment Processing Certificate → Create Certificate → "China Mainland?" **No**
   → upload MyFatoorah's CSR → download `apple_pay.cer`.
3. Email `apple_pay.cer` back to MyFatoorah and wait for them to confirm it is installed.
4. Do not revoke the old Moyasar certificate until that confirmation arrives.

Until step 3 is confirmed, real Apple Pay payments are declined. Everything else works.

The id reaches the app through `APPLE_PAY_MERCHANT_ID` in `Config/Base.xcconfig` and the
`ApplePayMerchantID` placeholder in `Sirr/Info.plist`. The capability is
`com.apple.developer.in-app-payments` in `Sirr/Sirr.entitlements`.

## Supabase secrets

Two projects, two sets. Never cross them. While testing (option A, 2026-11-11) the
**live** key goes on the **sandbox** only; production gets it at go-live.

    supabase secrets set --project-ref kpcdinxusxycenfnitjc \
      MYFATOORAH_API_KEY='…' \
      MYFATOORAH_BASE_URL='https://api-sa.myfatoorah.com' \
      MYFATOORAH_WEBHOOK_SECRET='…the portal webhook secret key…' \
      PAYMENT_SWEEP_SECRET="$(openssl rand -hex 32)" \
      REFUND_PAYMENT_SECRET='…same value as the vault refund_payment_secret…'

Remove the Moyasar ones once the switch is live:

    supabase secrets unset --project-ref kpcdinxusxycenfnitjc MOYASAR_SECRET_KEY MOYASAR_PUBLISHABLE_KEY MOYASAR_WEBHOOK_SECRET ALLOW_PAYMENTS_WITHOUT_RECIPIENT

## Vault (SQL editor)

The refund trigger and the two sweeps read their URL and secret from the vault. Without
them they do nothing, silently.

    select vault.create_secret('https://<ref>.supabase.co/functions/v1/refund-payment', 'refund_payment_url');
    select vault.create_secret('<REFUND_PAYMENT_SECRET>', 'refund_payment_secret');
    select vault.create_secret('https://<ref>.supabase.co/functions/v1/payment-sweep', 'payment_sweep_url');
    select vault.create_secret('<PAYMENT_SWEEP_SECRET>', 'payment_sweep_secret');
    select vault.create_secret('<your auth.users id>', 'ops_user_id');  -- who gets "refund failed" pushes

The refund ones already exist on the sandbox from the Moyasar work; only add what is
missing (`select name from vault.secrets;`).

A function secret and its vault twin must match. The vault is readable, function
secrets are not, so compare digests instead of retyping:

    select name, encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex')
    from vault.decrypted_secrets where name in ('refund_payment_secret','payment_sweep_secret');

against the DIGEST column of `supabase secrets list --project-ref <ref>`.

## Migrations and functions

Migrations, applied by hand in the SQL editor in this order (never `db push` from a branch):

    supabase/migrations/20261111100000_myfatoorah_payments.sql
    supabase/migrations/20261111110000_myfatoorah_refunds.sql
    supabase/migrations/20261111120000_payment_sweep.sql

Functions:

    supabase functions deploy create-payment pay-apple-pay myfatoorah-webhook refund-payment payment-sweep send-push --project-ref <ref>

Then delete the old ones from the dashboard: `verify-payment`, `moyasar-webhook`.

## Webhook

Portal → Integration Settings → Webhook Settings:
- Enable, URL `https://<ref>.supabase.co/functions/v1/myfatoorah-webhook`
- Version **V2**, events: Payment Status Changed, Refund Status Changed
- Retries 5, delay up to 180 s
- Copy the **secret key** into `MYFATOORAH_WEBHOOK_SECRET`

The function checks the `MyFatoorah-Signature` HMAC and re-fetches every payment or
refund before acting, so a forged body cannot settle anything.

## How a payment can end

| Where it stops | What finishes it |
|---|---|
| `pay-apple-pay` gets MyFatoorah's answer | settles at once |
| app closes, timeout, no answer | row stays `processing`; webhook, or `payment-sweep` within ~5 min |
| MyFatoorah never created a payment | sweep marks it `failed` after 30 min (nothing was charged) |

    select status, count(*) from public.payments group by status;
    select jobname, schedule from cron.job where jobname in ('retry-processing-payments','retry-pending-refunds');

## Refunds

Automatic in three cases: a player withdraws before the start, a player removes a
guest they paid for, the organizer cancels. Also when a paid seat was already gone by
the time the money arrived. Apple Pay payments only; a bank transfer never passed
through Tamrin.

| Refund status | Meaning |
|---|---|
| `pending` | row written, request not sent yet |
| `processing` | sent; MyFatoorah said Pending (finance team, unless Auto Refund) |
| `waiting_balance` | refused for balance (same-day money isn't refundable yet); retried daily for 7 days |
| `done` | money returned; the payer got a push |
| `failed` | refused, cancelled by MyFatoorah, or 7 days without balance; `ops_user_id` got a push |

    select status, count(*), sum(amount) from public.refunds group by status;
    select * from public.refunds where status in ('failed','waiting_balance') order by created_at desc;

A refund done by hand in the MyFatoorah portal is **not** reflected in seats; mirror it
by hand.

## Testing (live account, 1-riyal workouts, refund everything)

Before the certificate is confirmed:
- Deno suites: `supabase/functions/_shared/`, `create-payment/`, `pay-apple-pay/`,
  `myfatoorah-webhook/`, `refund-payment/`, `payment-sweep/`, `send-push/copy_test.ts`.
- SQL suites: `supabase/tests/myfatoorah_payments_test.sql`, `refunds_test.sql`.
- `payment-sweep` answers `{"checked":0,"settled":0}` when called with its secret.

After MyFatoorah confirms the certificate, on a phone, sandbox-pinned build:
1. Pay 1 SAR with a real mada card in Wallet → seat confirmed, organizer push.
2. Withdraw → refund row; note how long until `done` (expect `waiting_balance` same day).
3. Pay for yourself + a guest, remove the guest → partial refund.
4. Organizer cancels → full refund.
5. Kill the app right after Face ID → seat still confirms (webhook or sweep).
6. Add a guest while paying → that guest stays unpaid and owes their own payment.
