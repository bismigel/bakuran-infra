#!/usr/bin/env bash
# lazylibrarian-setup.sh — configure LazyLibrarian's SABnzbd download client and
# a NZBGeek (Newznab) indexer so searches return releases.
#
# LazyLibrarian keeps these in /config/config.ini (sections [SABnzbd] and
# [Newznab_0]); this script appends them if missing (from the media-setup
# Secret), then restarts the pod so the app reloads the config.
#
# Requires: bash, kubectl (or KUBECTL="k3s kubectl").
#
#   ./scripts/lazylibrarian-setup.sh
set -euo pipefail

NS="${NS:-books}"; DEPLOY="${DEPLOY:-lazylibrarian}"; MEDIA_NS="${MEDIA_NS:-media}"
SAB_HOST="${SAB_HOST:-sabnzbd.downloads.svc.cluster.local}"
SAB_PORT="${SAB_PORT:-8080}"
NZB_HOST="${NZB_HOST:-https://api.nzbgeek.info}"
K="${KUBECTL:-kubectl}"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

kget() { $K -n "$MEDIA_NS" get secret media-setup -o jsonpath="{.data.$1}" | base64 -d; }
SAB_KEY="${SAB_KEY:-$(kget sabnzbd-api-key)}"
NGB_KEY="${NGB_KEY:-$(kget nzbgeek-api)}"
[ -n "$SAB_KEY" ] || { echo "missing sabnzbd-api-key in media-setup"; exit 1; }
[ -n "$NGB_KEY" ] || { echo "missing nzbgeek-api in media-setup"; exit 1; }

POD="$($K -n "$NS" get pods -l "app=$DEPLOY" -o name | head -1)"; POD="${POD#pod/}"
[ -n "$POD" ] || { echo "no $DEPLOY pod"; exit 1; }
echo ">> pod: $POD"
$K -n "$NS" exec "$POD" -- cat /config/config.ini > "$TMP/config.ini"

if grep -qi '^\[SABnzbd\]' "$TMP/config.ini"; then
  echo ">> [SABnzbd] already present"
else
  cat >> "$TMP/config.ini" <<EOF

[SABnzbd]
SAB_HOST = $SAB_HOST
SAB_PORT = $SAB_PORT
SAB_API = $SAB_KEY
SAB_CAT = books
SAB_DELETE = True
EOF
  echo ">> added [SABnzbd]"
fi

if grep -qi '^\[Newznab_0\]' "$TMP/config.ini"; then
  echo ">> [Newznab_0] already present"
else
  cat >> "$TMP/config.ini" <<EOF

[Newznab_0]
DISPNAME = NZBGeek
ENABLED = True
HOST = $NZB_HOST
API = $NGB_KEY
BOOKCAT = 7000,7020
BOOKSEARCH = book
GENERALSEARCH = search
DLTYPES = A,E,M
EOF
  echo ">> added [Newznab_0] (NZBGeek)"
fi

$K -n "$NS" cp "$TMP/config.ini" "$POD:/config/config.ini"
$K -n "$NS" exec "$POD" -- sh -c 'chown 1000:1000 /config/config.ini 2>/dev/null || true'
$K -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true
echo ">> done; LazyLibrarian restarting"
