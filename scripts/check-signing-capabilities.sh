#!/bin/bash
# Guards the two settings a local simulator snapshot keeps taking out.
#
# Building for the simulator without the team's provisioning profile is done
# by emptying the entitlements and pointing the bundle id at a personal one.
# That is a fine thing to do on a laptop and a broken thing to push: it has
# reached a shared branch twice (a4d1ac1 in July, 8ae8620 in August), and both
# times it silently turned off Universal Links, push and Sign in with Apple.
# Silently, because nothing fails to build — the app just stops opening its
# own links.
#
# Run it before you push, or let CI run it for you:
#   ./scripts/check-signing-capabilities.sh

set -uo pipefail
cd "$(dirname "$0")/.."

ENTITLEMENTS="Sirr/Sirr.entitlements"
PBXPROJ="Sirr.xcodeproj/project.pbxproj"
failed=0

fail() { printf '\n  FAIL  %s\n' "$1"; failed=1; }
pass() { printf '  ok    %s\n' "$1"; }

echo "checking $ENTITLEMENTS"

# The capability has to be declared by the app itself. Without it iOS never
# registers the app as a handler for the domain and the link opens Safari.
for key in \
  "com.apple.developer.associated-domains" \
  "aps-environment" \
  "com.apple.developer.applesignin"
do
  if grep -q "$key" "$ENTITLEMENTS"; then
    pass "$key"
  else
    fail "$key is missing from $ENTITLEMENTS
        Universal Links, push and Sign in with Apple are all off without these.
        Restore them:  git checkout main -- $ENTITLEMENTS"
  fi
done

# The domain in the entitlement has to be the one serving the association
# file, so a rename on either side is caught here rather than on a device.
if grep -q "applinks:guileless-squirrel-b6537a.netlify.app" "$ENTITLEMENTS"; then
  pass "applinks domain"
else
  fail "the applinks domain in $ENTITLEMENTS is not the one that serves the
        association file. Shared links will not open the app."
fi

echo "checking $PBXPROJ"

# Signing lives in the gitignored Config/Local.xcconfig so that two developers
# can sign with different teams. A target-level value beats a project-level
# xcconfig, so any of these keys here means Local.xcconfig is read and then
# ignored — and whoever committed it has made their own signing everyone's.
# Base.xcconfig already documents this trap for CFBundleDisplayName.
for key in \
  "DEVELOPMENT_TEAM" \
  "PRODUCT_BUNDLE_IDENTIFIER" \
  "INFOPLIST_KEY_CFBundleDisplayName"
do
  count=$(grep -c "^[[:space:]]*$key = " "$PBXPROJ")
  if [ "$count" -eq 0 ]; then
    pass "$key is left to the xcconfig"
  else
    fail "$key is set on the target in $PBXPROJ ($count times)
        A target-level setting beats Config/Local.xcconfig, so this pins the
        whole team to one machine's signing. Delete the lines — they belong in
        Config/Local.xcconfig, which is gitignored for exactly this reason."
  fi
done

if [ "$failed" -ne 0 ]; then
  printf '\nsigning capabilities check failed\n'
  exit 1
fi
printf '\nsigning capabilities intact\n'
