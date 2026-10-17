#!/usr/bin/env bash
# kavita-setup.sh — reset the Kavita admin password to the value in Bitwarden.
#
# Kavita has no user-creation API: accounts live in its SQLite DB
# (/config/kavita.db, table AspNetUsers). This script:
#   1. reads the desired password from Bitwarden (`kavita-admin-password`)
#   2. copies the DB out of the pod, writes an ASP.NET Identity V3 hash
#      (SHA-512, 100k iterations) for the admin user, checkpoints, copies back
#   3. restarts Kavita
# It RESETS an existing account; if the admin does not exist yet, open Kavita
# and register it once (first user = admin), then run this.
#
# Requires: bash, kubectl (or KUBECTL="k3s kubectl"), bws, sqlite3, python3.
# Run from nix-station (bws works there) or anywhere with those tools.
#
#   BWS_ACCESS_TOKEN=... ./scripts/kavita-setup.sh
set -euo pipefail

NS="${NS:-books}"; DEPLOY="${DEPLOY:-kavita}"; USER_NAME="${USER_NAME:-gio}"
K="${KUBECTL:-kubectl}"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SQLITE="${SQLITE:-sqlite3}"; PYTHON="${PYTHON:-python3}"

secret() { bws secret list --output json 2>/dev/null | jq -r --arg k "$1" '.[]|select(.key==$k)|.value' | head -1; }
PW="${KAVITA_PASSWORD:-$(secret kavita-admin-password)}"
[ -n "$PW" ] || { echo "no password (set KAVITA_PASSWORD or Bitwarden kavita-admin-password)"; exit 1; }

POD="$($K -n "$NS" get pods -l "app=$DEPLOY" -o name | head -1)"; POD="${POD#pod/}"
[ -n "$POD" ] || { echo "no $DEPLOY pod in $NS"; exit 1; }
echo ">> pod: $POD"

$K -n "$NS" exec "$POD" -- tar cf - -C /config kavita.db kavita.db-wal kavita.db-shm 2>/dev/null | tar xf - -C "$TMP"
if ! "$SQLITE" "$TMP/kavita.db" "select 1 from AspNetUsers where UserName='$USER_NAME';" 2>/dev/null | grep -q 1; then
  echo ">> $USER_NAME does not exist — open Kavita and register the admin first"; exit 1
fi

NEWHASH="$("$PYTHON" - "$PW" <<'PY'
import sys, base64, hashlib, os, struct
pw = sys.argv[1].encode()
salt = os.urandom(16); iters, prf, fmt, keylen = 100_000, 2, 1, 32
sub = hashlib.pbkdf2_hmac({0:"sha1",1:"sha256",2:"sha512"}[prf], pw, salt, iters, keylen)
out = bytes([fmt]) + prf.to_bytes(4,"big") + iters.to_bytes(4,"big") + len(salt).to_bytes(4,"big") + salt + sub
print(base64.b64encode(out).decode())
PY
)"

"$SQLITE" "$TMP/kavita.db" "update AspNetUsers set PasswordHash='$NEWHASH' where UserName='$USER_NAME';"
"$SQLITE" "$TMP/kavita.db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
rm -f "$TMP/kavita.db-wal" "$TMP/kavita.db-shm"

$K -n "$NS" cp "$TMP/kavita.db" "$POD:/config/kavita.db"
$K -n "$NS" exec "$POD" -- sh -c 'rm -f /config/kavita.db-wal /config/kavita.db-shm; chown 1000:1000 /config/kavita.db 2>/dev/null || true'
$K -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true
echo ">> reset $USER_NAME's password; Kavita restarting"

# Ensure the Books library exists and is configured (idempotent). Done through
# the app's own API from inside the pod: Kavita lists libraries at
# /api/Library/libraries (GET /api/Library returns one by id) and creates with
# an UpdateLibraryDto. A Book library (type 2) scans Epub+Pdf (2,3) and uses
# Hardcover (2); the host folder is mounted at /books.
#
# EnableMetadata MUST be true: with it off Kavita parses series names from the
# filename, which yields an empty series for "Title - Author.epub" and the scan
# logs "Unable to parse any meaningful information out of file" and imports
# nothing. With it on, the EPUB's own metadata is used.
"$K" -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1 || true
{ printf '%s\n%s' "$USER_NAME" "$PW"; } | "$K" -n "$NS" exec -i "deploy/$DEPLOY" -- sh -c '
IFS= read -r U
IFS= read -r P
D=/config/tmp; mkdir -p "$D"
# Wait until the restarted app actually serves requests (rollout status can
# return before the HTTP listener is up).
i=0; until curl -sf -o /dev/null http://127.0.0.1:5000/api/Health; do
  i=$((i+1)); [ "$i" -gt 60 ] && break; sleep 2
done
printf "{\"username\":\"%s\",\"password\":\"%s\"}" "$U" "$P" > "$D/b.json"
TOK=$(curl -s -X POST http://127.0.0.1:5000/api/Account/login -H "Content-Type: application/json" --data-binary @"$D/b.json" | sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p")
if [ -z "$TOK" ]; then echo "error: admin login failed" >&2; rm -f "$D/b.json"; exit 1; fi
LIBS=$(curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:5000/api/Library/libraries)
N=$(printf "%s" "$LIBS" | grep -o "\"id\"" | wc -l)
ID=$(printf "%s" "$LIBS" | sed -n "s/.*\"id\":\([0-9]*\).*/\1/p" | head -1)
SETTINGS="\"name\":\"Books\",\"type\":2,\"folders\":[\"/books\"],\"folderWatching\":true,\"includeInDashboard\":true,\"includeInSearch\":true,\"manageCollections\":true,\"manageReadingLists\":true,\"allowScrobbling\":false,\"allowMetadataMatching\":true,\"enableMetadata\":true,\"removePrefixForSortName\":false,\"inheritWebLinksFromFirstChapter\":false,\"defaultLanguage\":\"en\",\"metadataProvider\":2,\"fileGroupTypes\":[2,3],\"excludePatterns\":[]"
if [ "$N" -eq 0 ]; then
  C=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:5000/api/Library/create \
    -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d "{$SETTINGS}")
  echo ">> created library Books ($C)"
else
  C=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:5000/api/Library/update \
    -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d "{\"id\":$ID,$SETTINGS}")
  echo ">> library Books present, settings refreshed ($C)"
fi
rm -f "$D/b.json"
'
