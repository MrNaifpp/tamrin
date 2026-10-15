#!/usr/bin/env bash
#
# Moyasar splits — the conclusive test.
#
# The first check proved the API *knows* the `splits` field. It could not prove
# the account is *entitled* to use it, because field validation runs before
# entitlement checks: a fake recipient id fails validation either way.
#
# This settles it by finding a real recipient id and splitting to it.
#
# It also answers a second open question from the design at the same time:
# whether `splits` composes with `manual: true` (authorize without capture),
# which is the mechanism the whole security model rests on. The test payment
# is authorized, never captured, and voided at the end.
#
# Test mode only. Refuses to run with a live key.
#
# Usage: ./scripts/moyasar-splits-probe.sh

set -uo pipefail

API="https://api.moyasar.com/v1"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'
yellow=$'\033[33m'; reset=$'\033[0m'

ok()   { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$red" "$reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$1"; }
info() { printf '  %s%s%s\n' "$dim" "$1" "$reset"; }
head_() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; }

pretty() {
  if command -v python3 >/dev/null 2>&1; then python3 -m json.tool 2>/dev/null || cat
  else cat; fi
}

field() {
  printf '%s' "$1" \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

printf '%sMoyasar splits probe%s\n' "$bold" "$reset"
printf '%sThe key is not echoed, not stored, and not written anywhere.%s\n\n' \
  "$dim" "$reset"

printf 'Secret key (sk_test_… only): '
read -rs SK
printf '\n'

case "${SK:-}" in
  sk_test_*) ;;
  sk_live_*) bad "Live key refused — this script creates a payment."; exit 1 ;;
  *) bad "Need a test secret key (sk_test_…)."; exit 1 ;;
esac

call() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" "$API$path" -u "$SK:" \
      -H 'Content-Type: application/json' -d "$data" -w $'\n%{http_code}' 2>&1
  else
    curl -sS -X "$method" "$API$path" -u "$SK:" -w $'\n%{http_code}' 2>&1
  fi
}
st() { printf '%s' "$1" | tail -1; }
bd() { printf '%s' "$1" | sed '$d'; }

# --- 1. discover which recipient-bearing endpoints exist ---------------------

head_ "1. Looking for a real recipient id"

RECIPIENT=""
RTYPE=""

for path in /settlements /transfers /entities /beneficiaries /recipients /payouts/accounts; do
  RAW=$(call GET "$path?per=5")
  S=$(st "$RAW"); B=$(bd "$RAW")
  case "$S" in
    200)
      ok "GET $path → 200"
      if [ -z "$RECIPIENT" ]; then
        CAND=$(field "$B" "recipient_id")
        # An id-bearing list: fall back to the first `id` if no recipient_id.
        [ -z "$CAND" ] && CAND=$(field "$B" "id")
        if [ -n "$CAND" ]; then
          RECIPIENT="$CAND"
          T=$(field "$B" "recipient_type")
          RTYPE="${T:-Entity}"
          info "found candidate: $RECIPIENT (${RTYPE})"
        fi
      fi
      ;;
    404) info "GET $path → 404 (does not exist)" ;;
    401|403) warn "GET $path → $S (exists but not permitted)" ;;
    *) info "GET $path → $S" ;;
  esac
done

if [ -z "$RECIPIENT" ]; then
  head_ "No recipient id found automatically"
  info "A brand-new account with no activity has nothing to read one from."
  info "Get one from the Moyasar dashboard if you can find it, or leave blank"
  info "to stop here."
  printf '\n  recipient_id (blank to stop): '
  read -r RECIPIENT
  if [ -z "${RECIPIENT:-}" ]; then
    head_ "Verdict"
    warn "Inconclusive. Splits validation is reachable, but entitlement is"
    warn "unproven without a real recipient id."
    info "Ask Moyasar directly — the question is in PAYMENT_SETUP.md."
    exit 0
  fi
  printf '  recipient_type [Entity/Platform/Beneficiary, default Entity]: '
  read -r RTYPE
  RTYPE="${RTYPE:-Entity}"
fi

# --- 2. the real test --------------------------------------------------------

head_ "2. Authorizing a 1.00 SAR payment split to that recipient"
info "manual: true — authorize only. Nothing is captured."

PAYLOAD=$(cat <<JSON
{
  "amount": 100,
  "currency": "SAR",
  "description": "Tamrin splits probe",
  "callback_url": "https://example.com/callback",
  "source": {
    "type": "creditcard",
    "name": "Tamrin Probe",
    "number": "4111111111111111",
    "cvc": "123",
    "month": "12",
    "year": "2030",
    "manual": "true"
  },
  "splits": [
    { "amount": 100, "recipient_id": "$RECIPIENT", "recipient_type": "$RTYPE" }
  ]
}
JSON
)

RAW=$(call POST "/payments" "$PAYLOAD")
S=$(st "$RAW"); B=$(bd "$RAW")
PAYMENT_ID=$(field "$B" "id")
STATUS=$(field "$B" "status")
LOWER=$(printf '%s' "$B" | tr '[:upper:]' '[:lower:]')

printf '\n%s  HTTP %s%s\n' "$dim" "$S" "$reset"
printf '%s\n' "$B" | pretty

head_ "3. Verdict"

case "$S" in
  201|200)
    ok "Splits are ENABLED and accepted on this account."
    ok "Payment status: ${STATUS:-unknown}"
    case "$STATUS" in
      initiated|authorized)
        ok "manual authorization composes with splits — the design holds."
        ;;
      paid)
        warn "Status is 'paid', not 'authorized'. Manual mode may not have"
        warn "applied. Re-check how 'manual' is passed before relying on"
        warn "authorize-then-capture as the security gate."
        ;;
    esac
    ;;
  400)
    case "$LOWER" in
      *recipient_id*)
        bad "That recipient id was not accepted."
        info "It may be the wrong kind of object. Splits entitlement is still"
        info "unproven — ask Moyasar for a valid recipient id to test with." ;;
      *"not enabled"*|*"not allowed"*|*"unsupported"*|*feature*)
        bad "Splits are NOT enabled on this account."
        info "Ask Moyasar to enable split payments. Per their docs it also"
        info "requires an entity created after October 2025." ;;
      *) warn "Rejected for another reason — read the response above." ;;
    esac
    ;;
  401|403)
    bad "Not permitted ($S) — this points at entitlement, not payload."
    info "Strong signal that splits are not enabled for this account." ;;
  *) warn "Unexpected status $S — read the response above." ;;
esac

# --- 4. clean up -------------------------------------------------------------

if [ -n "$PAYMENT_ID" ] && { [ "$STATUS" = "authorized" ] || [ "$STATUS" = "initiated" ]; }; then
  head_ "4. Cleaning up"
  RAW=$(call POST "/payments/$PAYMENT_ID/void")
  S=$(st "$RAW")
  if [ "$S" = "200" ] || [ "$S" = "201" ]; then
    ok "Test payment voided. Nothing left held."
  else
    warn "Void returned $S. Payment id: $PAYMENT_ID"
    info "Harmless in test mode, but void it from the dashboard if you like."
  fi
fi

printf '\n'
