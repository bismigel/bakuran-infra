#!/usr/bin/env bash
# Add a non-admin Kavita user with access to the Books library.
#
# Kavita has no plain admin "create user" API: the admin sends an invite, then
# the invitee sets a password through /api/Account/confirm-email. With no mail
# server configured, this script fetches the invite URL and completes it itself.
#
#   BWS_ACCESS_TOKEN=<token> ./scripts/kavita-add-user.sh ciceley
#
# Defaults: EMAIL=<user>@bismigel.dev, PASSWORD=BWS secret jellyfin-<user>
# (same password as Jellyfin/Immich), LIBRARY_ID=1 (Books), role Login+Pleb.
# Existing users are left alone. Passwords are piped in, never put in argv.
set -euo pipefail
export NIXPKGS_ALLOW_UNFREE="${NIXPKGS_ALLOW_UNFREE:-1}"
: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN (Bitwarden machine-account token)}"

USER_NAME="${1:?usage: kavita-add-user.sh <username>}"
EMAIL="${EMAIL:-$USER_NAME@bismigel.dev}"
LIBRARY_ID="${LIBRARY_ID:-1}"
NS="${NS:-books}"; DEPLOY="${DEPLOY:-kavita}"
K="${KUBECTL:-kubectl}"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

bws() { nix run --impure nixpkgs#bws -- "$@"; }
jq()  { nix run nixpkgs#jq -- "$@"; }
secrets="$(bws secret list --output json 2>/dev/null)"
secret() { printf '%s' "$secrets" | jq -r --arg k "$1" '.[]|select(.key==$k)|.value' | head -1; }

ADMIN_PW="${KAVITA_ADMIN_PASSWORD:-$(secret kavita-admin-password)}"
PW="${KAVITA_PASSWORD:-$(secret "jellyfin-$USER_NAME")}"
[ -n "$ADMIN_PW" ] && [ -n "$PW" ] || { echo "error: missing admin or user password in Bitwarden" >&2; exit 1; }
printf '%s\n' "$ADMIN_PW" > "$TMP/admin"; printf '%s\n' "$PW" > "$TMP/user"

cat "$TMP/admin" "$TMP/user" | "$K" -n "$NS" exec -i "deploy/$DEPLOY" -- sh -c '
IFS= read -r AP; IFS= read -r UP
U="$1"; EM="$2"; LID="$3"
D=/config/tmp; mkdir -p "$D"; B=http://127.0.0.1:5000
printf "{\"username\":\"%s\",\"password\":\"%s\"}" "${ADMIN_USER:-gio}" "$AP" > "$D/a.json"
ATOK=$(curl -s -X POST $B/api/Account/login -H "Content-Type: application/json" --data-binary @"$D/a.json" | sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p")
if [ -z "$ATOK" ]; then echo "error: admin login failed" >&2; rm -f "$D/a.json"; exit 1; fi

if curl -s -H "Authorization: Bearer $ATOK" "$B/api/Users?includePending=true" | grep -q "\"username\":\"$U\""; then
  echo ">> $U already exists; nothing to do"; rm -f "$D/a.json"; exit 0
fi

IC=$(curl -s -o "$D/inv.json" -w "%{http_code}" -X POST $B/api/Account/invite \
  -H "Authorization: Bearer $ATOK" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EM\",\"roles\":[\"Login\"],\"libraries\":[$LID],\"ageRestriction\":{\"ageRating\":0,\"includeUnknowns\":true}}")
[ "$IC" = "200" ] || { echo "error: invite failed ($IC)" >&2; rm -f "$D/a.json" "$D/inv.json"; exit 1; }

UID=$(curl -s -H "Authorization: Bearer $ATOK" "$B/api/Users?includePending=true" | \
  grep -o "\"id\":[0-9]*,\"username\":\"$U[^\"]*\"" | sed -e "s/\"id\":\([0-9]*\),.*/\1/" | head -1)
LINK=$(curl -s -H "Authorization: Bearer $ATOK" "$B/api/Account/invite-url?userId=$UID&withBaseUrl=false" | \
  sed -e "s/^\"//" -e "s/\"$//" -e "s/\\\\u0026/\&/g" -e "s/&amp;/\&/g")
RAW=$(printf "%s" "$LINK" | sed -n "s/.*[?&]token=\([^&]*\).*/\1/p")
TOK=$(printf "%s" "$RAW" | sed -e "s/%2B/+/Ig" -e "s/%2F/\//Ig" -e "s/%3D/=/Ig" -e "s/%25/%/Ig")
printf "{\"email\":\"%s\",\"token\":\"%s\",\"password\":\"%s\",\"username\":\"%s\"}" "$EM" "$TOK" "$UP" "$U" > "$D/c.json"
CC=$(curl -s -o /dev/null -w "%{http_code}" -X POST $B/api/Account/confirm-email -H "Content-Type: application/json" --data-binary @"$D/c.json")
[ "$CC" = "200" ] || { echo "error: confirm failed ($CC)" >&2; rm -f "$D"/a.json "$D"/inv.json "$D"/c.json; exit 1; }

printf "{\"username\":\"%s\",\"password\":\"%s\"}" "$U" "$UP" > "$D/v.json"
LC=$(curl -s -o "$D/l.json" -w "%{http_code}" -X POST $B/api/Account/login -H "Content-Type: application/json" --data-binary @"$D/v.json")
LIB=$(sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p" "$D/l.json" | \
  xargs -I{} curl -s -H "Authorization: Bearer {}" $B/api/Library/libraries | grep -o "\"name\":\"[^\"]*\"" | tr "\n" " ")
echo ">> $U: login=$LC roles=$(sed -n "s/.*\"roles\":\(\[[^]]*\]\).*/\1/p" "$D/l.json") libraries=$LIB"
rm -f "$D"/a.json "$D"/inv.json "$D"/c.json "$D"/v.json "$D"/l.json
[ "$LC" = "200" ]
' sh "$USER_NAME" "$EMAIL" "$LIBRARY_ID"
