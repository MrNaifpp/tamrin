#!/usr/bin/env bash
# Send a test deep-link push to a booted iOS Simulator.
# Usage: scripts/push-sim.sh <event-uuid> [device-udid]
#   <event-uuid>  a real event id so the detail screen can load it
#   [device-udid] optional; defaults to the booted simulator
set -euo pipefail

EVENT_ID="${1:?Usage: scripts/push-sim.sh <event-uuid> [device-udid]}"
DEVICE="${2:-booted}"
BUNDLE_ID="com.businessech.tmrin"

PAYLOAD="$(mktemp /tmp/sirr-push.XXXXXX.apns)"
cat > "$PAYLOAD" <<JSON
{
  "aps": { "alert": { "title": "طلب انضمام جديد 🎉", "body": "وصلك طلب دفع جديد. راجعه وأكّده 👍" }, "sound": "default" },
  "event_id": "$EVENT_ID"
}
JSON

echo "Pushing event_id=$EVENT_ID to $DEVICE ($BUNDLE_ID)…"
xcrun simctl push "$DEVICE" "$BUNDLE_ID" "$PAYLOAD"
rm -f "$PAYLOAD"
echo "Sent. Tap the banner to test the deep link."
