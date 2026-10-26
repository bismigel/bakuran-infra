#!/usr/bin/env bash
# Seed the `lazylibrarian-secrets` Secret in the `books` namespace on calamansi-intel
# (.81) from Bitwarden. LazyLibrarian searches through Prowlarr instead of talking to
# NZBGeek directly (Cloudflare rejects its python-requests signature with HTTP 403
# `error code: 1010`), and the Prowlarr Newznab endpoint needs that API key.
#
# The books namespace has NO External Secrets operator, so this is applied out of
# band -- same story as `media-setup` on the media namespace. The key itself is
# canonically in Bitwarden as `prowlarr-api-key` (see media-setup-secret.sh).
#
# The init container in bakuran-gitops/manifests/books/lazylibrarian.yaml reads the
# Secret (optional) on every pod start and rewrites [Newznab_*] host/api in
# /config/config.ini. Restart the deployment after changing it.
#
#   BWS_ACCESS_TOKEN=<machine-account-token> ./scripts/lazylibrarian-secrets.sh
set -euo pipefail
export NIXPKGS_ALLOW_UNFREE="${NIXPKGS_ALLOW_UNFREE:-1}"
: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN to the Bitwarden machine-account token}"
HOST="${HOST:-192.168.2.81}"
NS="${NS:-books}"
NAME="${NAME:-lazylibrarian-secrets}"

bws() { nix run --impure nixpkgs#bws -- "$@"; }
jq()  { nix run nixpkgs#jq -- "$@"; }
b64() { printf %s "$1" | base64 -w0; }

sec="$(bws secret list --output json 2>/dev/null)"
get() { printf '%s' "$sec" | jq -r --arg k "$1" '.[]|select(.key==$k).value'; }

prowlarr_key="$(get prowlarr-api-key)"
[ -n "$prowlarr_key" ] && [ "$prowlarr_key" != "null" ] ||
  { echo "ERROR: prowlarr-api-key missing from Bitwarden" >&2; exit 1; }

# qBittorrent's WebUI authenticates everyone who is not on localhost, and
# LazyLibrarian connects from a pod IP. Same item media/media-mcp uses for the
# QBITTORRENT_PASSWORD env (media/media-setup -> qbt-password).
qbt_pass="$(get qbittorrent-password)"
[ -n "$qbt_pass" ] && [ "$qbt_pass" != "null" ] ||
  { echo "ERROR: qbittorrent-password missing from Bitwarden" >&2; exit 1; }

# Usenet client for ebooks; same item media-setup uses as sabnzbd-api-key.
sab_key="$(get sabnzbd-api-key)"
[ -n "$sab_key" ] && [ "$sab_key" != "null" ] ||
  { echo "ERROR: sabnzbd-api-key missing from Bitwarden" >&2; exit 1; }

# LazyLibrarian's own API (32 chars). media/media-mcp already requires this key
# as LAZYLIBRARIAN_API_KEY; the app only serves it when [API] API_ENABLED=1.
ll_key="$(get lazylibrarian-api-key)"
[ -n "$ll_key" ] && [ "$ll_key" != "null" ] ||
  { echo "ERROR: lazylibrarian-api-key missing from Bitwarden" >&2; exit 1; }

cat <<EOF | ssh "root@$HOST" "k3s kubectl apply -f -"
apiVersion: v1
kind: Secret
metadata:
  name: $NAME
  namespace: $NS
type: Opaque
data:
  prowlarr-api-key: $(b64 "$prowlarr_key")
  qbt-password: $(b64 "$qbt_pass")
  lazylibrarian-api-key: $(b64 "$ll_key")
  sabnzbd-api-key: $(b64 "$sab_key")
EOF
echo "secret $NS/$NAME applied on $HOST"
echo "now restart so the init container rewrites config.ini:"
echo "  ssh root@$HOST 'k3s kubectl -n $NS rollout restart deploy/lazylibrarian'"

# --- books/kavita-secrets -----------------------------------------------------
# The nightly `kavita-scan` CronJob (bakuran-gitops manifests/books/kavita-scan.yaml)
# logs in as admin to force a library scan: Kavita's own "daily" task does not
# reliably pick up what LazyLibrarian imports. There is no service account, so
# this is the admin password.
kavita_pass="$(get kavita-admin-password)"
[ -n "$kavita_pass" ] && [ "$kavita_pass" != "null" ] ||
  { echo "ERROR: kavita-admin-password missing from Bitwarden" >&2; exit 1; }

cat <<EOF | ssh "root@$HOST" "k3s kubectl apply -f -"
apiVersion: v1
kind: Secret
metadata:
  name: kavita-secrets
  namespace: $NS
type: Opaque
data:
  kavita-admin-password: $(b64 "$kavita_pass")
EOF
echo "secret $NS/kavita-secrets applied on $HOST"
