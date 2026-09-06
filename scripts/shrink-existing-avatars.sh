#!/usr/bin/env bash
#
# One-off backfill: shrink the avatars already sitting in tamrin-stg.
#
# The app now downsamples before upload, but that only helps photos picked from
# here on. The 16 objects already in the bucket stay full-res — and keep their
# one-hour cache header — until something rewrites them. This is that something.
#
# Paths are unchanged, so the URLs stored in `users.avatar_url` stay valid and
# no database write is needed. Originals are kept under ./backup in case a
# result looks wrong.
#
# Usage:
#   export SUPABASE_SECRET_KEY=eyJ...    # the service_role key, from
#                                         # Settings > API Keys > Legacy API
#                                         # keys. This project still validates
#                                         # keys as JWTs, so the newer
#                                         # sb_secret_... value is rejected.
#   ./scripts/shrink-existing-avatars.sh                    # dry run, sandbox
#   ./scripts/shrink-existing-avatars.sh --apply            # re-upload, sandbox
#   ./scripts/shrink-existing-avatars.sh --project prod     # dry run, prod
#   ./scripts/shrink-existing-avatars.sh --project prod --apply
#
# The key must belong to the project being targeted; the script refuses to run
# if it does not, so a prod key can never be pointed at sandbox or vice versa.
set -euo pipefail

# Sandbox holds the 11 testers and all of the egress. Prod is the older project
# Release pointed at before the Aug 31 builds, so its avatars may belong to real
# App Store users — which is why choosing it has to be deliberate rather than a
# hand-edit of this line.
SANDBOX_REF="kpcdinxusxycenfnitjc"
PROD_REF="hzsxwnmbdkrmipjtfzlp"

PROJECT_REF="$SANDBOX_REF"
PROJECT_NAME="sandbox"
BUCKET="tamrin-stg"
MAX_PIXELS=512      # matches AvatarImage.maxPixelSize
QUALITY=80          # matches AvatarImage.compressionQuality (0.8)
MAX_AGE=31536000    # one year, matches the uploadAvatar change

APPLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --project)
      case "$2" in
        prod)    PROJECT_REF="$PROD_REF";    PROJECT_NAME="prod" ;;
        sandbox) PROJECT_REF="$SANDBOX_REF"; PROJECT_NAME="sandbox" ;;
        *) echo "--project takes 'sandbox' or 'prod', not '$2'" >&2; exit 1 ;;
      esac
      shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${SUPABASE_SECRET_KEY:?set SUPABASE_SECRET_KEY first (the sb_secret_... key from Settings > API Keys)}"

# This project is still on the legacy key scheme: Storage validates the key as a
# JWT and answers "Invalid Compact JWS" to anything that is not one. Checking the
# shape here turns a confusing 403 into an instruction.
case "$SUPABASE_SECRET_KEY" in
  eyJ*) : ;;  # legacy JWT, which is what this project wants
  sb_publishable_*)
    echo "That is the publishable key — it cannot overwrite storage objects." >&2
    echo "Use service_role from Settings > API Keys > Legacy API keys." >&2
    exit 1 ;;
  sb_secret_*)
    echo "This project has not moved to the new API keys: Storage rejects" >&2
    echo "sb_secret_... with 'Invalid Compact JWS'." >&2
    echo "Use service_role (a long eyJ... JWT) from Settings > API Keys >" >&2
    echo "Legacy API keys." >&2
    exit 1 ;;
  *)
    echo "That does not look like a Supabase key. Expected the service_role" >&2
    echo "JWT (starts with eyJ) from Settings > API Keys > Legacy API keys." >&2
    exit 1 ;;
esac

# Listing goes through RLS and downloads use the public URL, so an anon key
# survives the whole dry run and only fails on the first PUT — halfway through,
# with some avatars replaced and some not. The claims say up front which key
# this is. Only ref and role are read; the signature is never printed.
claims=$(SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" python3 - <<'PYEOF'
import base64, json, os
tok = os.environ["SUPABASE_SECRET_KEY"]
try:
    part = tok.split(".")[1]
    c = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    print(c.get("ref", "?"), c.get("role", "?"))
except Exception:
    print("? ?")
PYEOF
)
key_ref=${claims%% *}
key_role=${claims##* }

if [[ "$key_ref" != "$PROJECT_REF" ]]; then
  echo "Refusing to run: this key belongs to project '$key_ref', but the" >&2
  echo "target is $PROJECT_NAME ('$PROJECT_REF'). Export the key for the" >&2
  echo "project you actually mean to change." >&2
  exit 1
fi

if [[ "$key_role" != "service_role" ]]; then
  echo "This key's role is '$key_role'. Overwriting storage objects needs" >&2
  echo "service_role — an anon key lists and downloads fine, then fails on the" >&2
  echo "first upload. Use service_role from Settings > API Keys > Legacy." >&2
  exit 1
fi

API="https://${PROJECT_REF}.supabase.co/storage/v1"
WORK="$(mktemp -d)"
# .avatar-backup/ rather than backup/, because .gitignore ignores that name and
# these are real users' photos. An ignore rule that does not match the directory
# it names is worse than none: it reads as protection that is not there.
BACKUP="$(pwd)/.avatar-backup/avatars-$PROJECT_NAME-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"

$APPLY || echo "DRY RUN — nothing will be uploaded. Re-run with --apply."
echo "project: $PROJECT_NAME ($PROJECT_REF)   bucket: $BUCKET"
echo "key:     ref=$key_ref role=$key_role"
echo

response=$(curl -sS -X POST "$API/object/list/$BUCKET" \
  -H "apikey: $SUPABASE_SECRET_KEY" \
  -H "Authorization: Bearer $SUPABASE_SECRET_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prefix":"","limit":1000}')

# On anything but success the API answers with a JSON error object, not a list.
# Piping that straight into jq buries the reason under a type error, so check
# the shape first and show what actually came back.
if [[ "$(jq -r 'type' <<< "$response")" != "array" ]]; then
  echo "Storage refused the listing:" >&2
  jq . <<< "$response" >&2 2>/dev/null || echo "$response" >&2
  exit 1
fi

objects=$(jq -r '.[] | select(.id != null) | .name' <<< "$response")

if [[ -z "$objects" ]]; then
  echo "Bucket '$BUCKET' listed fine but holds no files. Wrong bucket or ref?" >&2
  exit 1
fi

before_total=0
after_total=0

while IFS= read -r name; do
  src="$WORK/$name"
  dst="$WORK/small-$name"

  # The bucket is public, so reading needs no key.
  curl -sS -o "$src" "$API/object/public/$BUCKET/$name"
  cp "$src" "$BACKUP/$name"

  # -Z resamples so the longest edge is MAX_PIXELS, preserving aspect ratio.
  sips -Z "$MAX_PIXELS" -s format jpeg -s formatOptions "$QUALITY" \
       "$src" --out "$dst" >/dev/null 2>&1

  before=$(stat -f%z "$src")
  after=$(stat -f%z "$dst")
  before_total=$((before_total + before))
  after_total=$((after_total + after))

  printf '  %-42s %6s kB -> %5s kB\n' "$name" $((before / 1024)) $((after / 1024))

  if $APPLY; then
    # PUT replaces the object at the same path. cache-control is sent the way
    # the client libraries send it: as a full max-age directive.
    curl -sS -X PUT "$API/object/$BUCKET/$name" \
      -H "apikey: $SUPABASE_SECRET_KEY" \
      -H "Authorization: Bearer $SUPABASE_SECRET_KEY" \
      -H "Content-Type: image/jpeg" \
      -H "cache-control: max-age=$MAX_AGE" \
      -H "x-upsert: true" \
      --data-binary "@$dst" > /dev/null
  fi
done <<< "$objects"

echo
printf 'bucket: %s kB -> %s kB  (%.1fx smaller)\n' \
  $((before_total / 1024)) $((after_total / 1024)) \
  "$(echo "scale=2; $before_total / $after_total" | bc)"
echo "originals kept in: $BACKUP"
$APPLY && echo "uploaded." || echo "(dry run — nothing uploaded)"
rm -rf "$WORK"
