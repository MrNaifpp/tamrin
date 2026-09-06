#!/usr/bin/env bash
#
# Re-encode every avatar already sitting in the tamrin-stg bucket.
#
# The app uploads whatever PhotosPicker hands back — `loadTransferable(type:
# Data.self)` in LoginView/SignupView/EditProfileSheet/ProfileSettingsView is the
# untouched original, so each object is a 2-4 MB camera photo being rendered into
# a 40pt circle. That is what ran the org past its cached-egress quota: 26 MB of
# bucket served ~260 times over.
#
# Fixing the upload path only helps the *next* photo somebody picks. This shrinks
# what is already there, so phones running the current TestFlight binary start
# pulling ~40 KB instead of ~2.4 MB without waiting for a release.
#
# Three things happen per object:
#
#   1. the bytes are downscaled to 512px and re-encoded as real JPEG,
#   2. they go back at the same path with a one-year Cache-Control (safe: the
#      URL carries a ?v= stamp, so it is already immutable per upload), and
#   3. public.users.avatar_url gets a fresh ?v= so clients see a new URL and
#      refetch rather than sitting on the 2.4 MB copy in their disk cache.
#
# Step 3 is why the DB is touched at all. Without it the object changes but every
# cached URL stays byte-identical, and the phones that already have the big one
# never ask again.
#
# Dry run by default. Nothing is written until --apply, and originals are copied
# to a local backup directory first — the upload is an upsert and overwrites in
# place, so there is no undo on the Supabase side.
#
# Usage:
#   export SUPABASE_URL=https://<project-ref>.supabase.co
#   export SUPABASE_SERVICE_ROLE_KEY=<service role key>
#   scripts/shrink-avatars.sh              # report only
#   scripts/shrink-avatars.sh --apply      # actually rewrite

set -euo pipefail

BUCKET="tamrin-stg"
MAX_DIM=512           # avatars render at 40pt; 512 covers 3x plus any future larger view
JPEG_QUALITY=80
SKIP_UNDER=150000     # bytes; anything already this small is done or was never the problem
CACHE_CONTROL="31536000"
BACKUP_DIR="${BACKUP_DIR:-.avatar-backup/$(date +%Y%m%d-%H%M%S)}"

APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

: "${SUPABASE_URL:?set SUPABASE_URL to the project you mean to rewrite}"
: "${SUPABASE_SERVICE_ROLE_KEY:?set SUPABASE_SERVICE_ROLE_KEY (service_role, not anon)}"

SUPABASE_URL="${SUPABASE_URL%/}"
PROJECT_REF="$(sed -E 's#https://([^.]+)\..*#\1#' <<<"$SUPABASE_URL")"

auth=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")

echo "project   : $PROJECT_REF"
echo "bucket    : $BUCKET"
echo "mode      : $($APPLY && echo 'APPLY — will overwrite objects and rows' || echo 'dry run')"
echo

# You have two projects and only one of them holds the 11 users. Overwriting the
# wrong bucket is not recoverable, so the ref is confirmed out loud, not assumed.
if $APPLY; then
  read -r -p "Rewrite avatars in '$PROJECT_REF'? [y/N] " ok
  [[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "aborted"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  echo "backups   : $BACKUP_DIR"
  echo
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The storage list endpoint pages; 100 objects is far above the 11 users here but
# keeps this honest if the bucket grows before anyone runs it again.
objects="$(curl -fsS "${auth[@]}" \
  -H "Content-Type: application/json" \
  -X POST "$SUPABASE_URL/storage/v1/object/list/$BUCKET" \
  -d '{"prefix":"","limit":100,"sortBy":{"column":"name","order":"asc"}}' \
  | jq -r '.[] | select(.name != ".emptyFolderPlaceholder") | .name')"

[[ -n "$objects" ]] || { echo "bucket is empty — nothing to do"; exit 0; }

total_before=0; total_after=0; touched=0; skipped=0

while IFS= read -r name; do
  [[ -n "$name" ]] || continue

  src="$work/$name"
  # Signed download rather than the public URL: the public one goes through the
  # CDN, which would both bill this cleanup as egress and hand back the stale copy.
  curl -fsS "${auth[@]}" -o "$src" "$SUPABASE_URL/storage/v1/object/$BUCKET/$name"

  before=$(stat -f%z "$src")
  total_before=$((total_before + before))

  if (( before < SKIP_UNDER )); then
    printf '  skip   %-44s %6s KB (already small)\n' "$name" "$((before / 1024))"
    total_after=$((total_after + before))
    skipped=$((skipped + 1))
    continue
  fi

  out="$work/out-$name"
  # sips also rescues a second, quieter bug: PhotosPicker returns HEIC bytes for
  # most modern photos, and uploadAvatar labels them image/jpeg regardless. This
  # writes an actual JPEG, so the content type stops being a lie.
  sips -Z "$MAX_DIM" \
       --setProperty format jpeg \
       --setProperty formatOptions "$JPEG_QUALITY" \
       "$src" --out "$out" >/dev/null 2>&1

  after=$(stat -f%z "$out")
  total_after=$((total_after + after))
  touched=$((touched + 1))

  printf '  shrink %-44s %6s KB -> %5s KB\n' "$name" "$((before / 1024))" "$((after / 1024))"
  $APPLY || continue

  cp "$src" "$BACKUP_DIR/$name"

  curl -fsS "${auth[@]}" \
    -H "Content-Type: image/jpeg" \
    -H "Cache-Control: max-age=$CACHE_CONTROL" \
    -H "x-upsert: true" \
    -X PUT "$SUPABASE_URL/storage/v1/object/$BUCKET/$name" \
    --data-binary "@$out" >/dev/null

  # Object names are "<uuid>.jpg" from Swift's uppercase UUID.uuidString; Postgres
  # parses either case into the same uuid, so this matches without folding.
  uid="${name%.jpg}"

  # Only rows that already point at an avatar are restamped. A user who removed
  # their photo has a null column and a leftover object, and must not get it back.
  current="$(curl -fsS "${auth[@]}" \
    "$SUPABASE_URL/rest/v1/users?user_id=eq.$uid&select=avatar_url" | jq -r '.[0].avatar_url // empty')"

  if [[ -z "$current" ]]; then
    echo "         (users.avatar_url is null — object rewritten, row left alone)"
    continue
  fi

  new_url="$SUPABASE_URL/storage/v1/object/public/$BUCKET/$name?v=$(date +%s)"
  curl -fsS "${auth[@]}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -X PATCH "$SUPABASE_URL/rest/v1/users?user_id=eq.$uid" \
    -d "$(jq -nc --arg u "$new_url" '{avatar_url: $u}')" >/dev/null
done <<<"$objects"

echo
printf 'objects   : %d rewritten, %d skipped\n' "$touched" "$skipped"
printf 'bucket    : %d KB -> %d KB\n' "$((total_before / 1024))" "$((total_after / 1024))"
if (( total_after > 0 )); then
  printf 'per fetch : %sx less egress from here on\n' "$((total_before / total_after))"
fi
$APPLY || { echo; echo "dry run — nothing written. re-run with --apply"; }
