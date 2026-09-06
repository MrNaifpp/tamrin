#!/usr/bin/env bash
#
# Moyasar account readiness check.
#
# Answers, against the live API rather than the dashboard:
#   1. Is the secret key valid and the account reachable?
#   2. Which mode is it — test or live?
#   3. Can the account actually create a payable object in test mode?
#   4. Is the `splits` feature enabled? (the one Tamrin's design depends on)
#
# The key is read from a hidden prompt, never passed as an argument. Arguments
# land in `ps` output and in shell history; a read -s prompt does not.
#
# Usage: ./scripts/moyasar-account-check.sh

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
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool 2>/dev/null || cat
  else
    cat
  fi
}

# Extract a top-level JSON string field without requiring jq.
field() {
  local body="$1" key="$2"
  printf '%s' "$body" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -1
}

# --- key ---------------------------------------------------------------------

printf '%sMoyasar account check%s\n' "$bold" "$reset"
printf '%sThe key is not echoed, not stored, and not written anywhere.%s\n\n' \
  "$dim" "$reset"

printf 'Secret key (sk_test_… or sk_live_…): '
read -rs SK
printf '\n'

if [ -z "${SK:-}" ]; then
  bad "No key entered."
  exit 1
fi

case "$SK" in
  sk_test_*) MODE="test" ;;
  sk_live_*) MODE="live" ;;
  pk_*)
    bad "That is a publishable key. This check needs the SECRET key (sk_…)."
    exit 1 ;;
  *)
    bad "Key does not start with sk_test_ or sk_live_."
    exit 1 ;;
esac

if [ "$MODE" = "live" ]; then
  head_ "LIVE KEY"
  warn "This is a live key. Read-only checks are safe, but the write probes"
  warn "below would create real objects. They will be skipped."
fi

# curl helper: prints "<status>\n<body>"
call() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" "$API$path" -u "$SK:" \
      -H 'Content-Type: application/json' -d "$data" \
      -w $'\n%{http_code}' 2>&1
  else
    curl -sS -X "$method" "$API$path" -u "$SK:" -w $'\n%{http_code}' 2>&1
  fi
}

split_status() { printf '%s' "$1" | tail -1; }
split_body()   { printf '%s' "$1" | sed '$d'; }

# --- 1. auth -----------------------------------------------------------------

head_ "1. Key and account"

RAW=$(call GET "/payments?per=1")
STATUS=$(split_status "$RAW")
BODY=$(split_body "$RAW")

case "$STATUS" in
  200)
    ok "Key is valid — the account answered."
    ok "Mode: ${MODE}"
    ;;
  401)
    bad "401 Unauthorized — the key is wrong, revoked, or from another account."
    info "Get a fresh one: Dashboard → Settings → API Keys"
    exit 1 ;;
  403)
    bad "403 Forbidden — the key is recognised but the account is not permitted."
    info "This usually means the account is not activated yet. Contact Moyasar."
    printf '%s\n' "$BODY" | pretty
    exit 1 ;;
  000|"")
    bad "Could not reach api.moyasar.com. Check your connection."
    exit 1 ;;
  *)
    bad "Unexpected status $STATUS"
    printf '%s\n' "$BODY" | pretty
    exit 1 ;;
esac

# --- 2. what the account can see ---------------------------------------------

head_ "2. Existing activity"

COUNT=$(printf '%s' "$BODY" \
  | sed -n 's/.*"total_count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
if [ -n "$COUNT" ]; then
  info "Payments on this account so far: $COUNT"
else
  info "Could not read a payment count from the response."
fi

RAW=$(call GET "/invoices?per=1")
STATUS=$(split_status "$RAW")
if [ "$STATUS" = "200" ]; then
  ok "Invoices API reachable."
else
  warn "Invoices API returned $STATUS (not required for the card flow)."
fi

# --- 3. can it create something payable? -------------------------------------

head_ "3. Test-mode liveness"

if [ "$MODE" != "test" ]; then
  info "Skipped — live key."
else
  printf '  Create a 1.00 SAR test invoice to prove the account can take a\n'
  printf '  payment? Nothing real is charged in test mode. [y/N] '
  read -r REPLY
  if [ "${REPLY:-}" = "y" ] || [ "${REPLY:-}" = "Y" ]; then
    RAW=$(call POST "/invoices" \
      '{"amount":100,"currency":"SAR","description":"Tamrin account check"}')
    STATUS=$(split_status "$RAW")
    BODY=$(split_body "$RAW")
    if [ "$STATUS" = "201" ] || [ "$STATUS" = "200" ]; then
      ok "Account can create payable objects in test mode."
      URL=$(field "$BODY" "url")
      [ -n "$URL" ] && info "Open it and pay with 4111111111111111 to test end to end:" \
        && printf '  %s\n' "$URL"
    else
      bad "Invoice creation returned $STATUS"
      printf '%s\n' "$BODY" | pretty
    fi
  else
    info "Skipped."
  fi
fi

# --- 4. splits ---------------------------------------------------------------

head_ "4. Split payments (Tamrin depends on this)"

if [ "$MODE" != "test" ]; then
  info "Skipped — live key."
else
  printf '  Probe whether `splits` is enabled? This sends one payment request\n'
  printf '  with a deliberately invalid recipient; the error tells us which\n'
  printf '  of the two answers it is. It cannot succeed. [y/N] '
  read -r REPLY
  if [ "${REPLY:-}" = "y" ] || [ "${REPLY:-}" = "Y" ]; then
    PROBE='{"amount":100,"currency":"SAR","callback_url":"https://example.com/cb",
      "source":{"type":"creditcard","name":"Tamrin Check",
      "number":"4111111111111111","cvc":"123","month":"12","year":"2030"},
      "splits":[{"amount":100,"recipient_id":"00000000-0000-0000-0000-000000000000",
      "recipient_type":"Beneficiary"}]}'
    RAW=$(call POST "/payments" "$PROBE")
    STATUS=$(split_status "$RAW")
    BODY=$(split_body "$RAW")

    LOWER=$(printf '%s' "$BODY" | tr '[:upper:]' '[:lower:]')
    case "$LOWER" in
      *"not enabled"*|*"not allowed"*|*"unsupported"*|*"unauthorized to use"*|*"feature"*)
        bad "Splits appear NOT enabled on this account."
        info "Ask Moyasar to enable split payments. Per their docs it also"
        info "requires an entity created after October 2025." ;;
      *recipient*|*"invalid"*)
        ok "Splits appear ENABLED — the API validated the recipient and"
        ok "rejected the fake id, which means it understood the field."
        info "Next question for Moyasar: can individual organisers (no CR)"
        info "be onboarded as Beneficiaries?" ;;
      *)
        warn "Inconclusive — read the response yourself:" ;;
    esac
    printf '\n%s  HTTP %s%s\n' "$dim" "$STATUS" "$reset"
    printf '%s\n' "$BODY" | pretty
  else
    info "Skipped."
  fi
fi

# --- done --------------------------------------------------------------------

head_ "Summary"
info "Anything above marked ✗ blocks the Moyasar integration."
info "Design: docs/superpowers/specs/2026-09-06-moyasar-payments-design.md"
printf '\n'
