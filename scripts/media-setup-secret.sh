#!/usr/bin/env bash
# Seed the `media-setup` Secret on the MEDIA cluster (calamansi-intel, .81) from
# Bitwarden. The media cluster has NO External Secrets operator, so this is applied
# out of band. media-stack-setup.sh reads these values to wire the *arr stack.
#
#   BWS_ACCESS_TOKEN=<machine-account-token> ./scripts/media-setup-secret.sh
set -euo pipefail
export NIXPKGS_ALLOW_UNFREE="${NIXPKGS_ALLOW_UNFREE:-1}"
: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN to the Bitwarden machine-account token}"
HOST="${HOST:-192.168.2.81}"
NS="${NS:-media}"

bws() { nix run --impure nixpkgs#bws -- "$@"; }
jq()  { nix run nixpkgs#jq -- "$@"; }
b64() { printf %s "$1" | base64 -w0; }

sec="$(bws secret list --output json 2>/dev/null)"
get() { printf '%s' "$sec" | jq -r --arg k "$1" '.[]|select(.key==$k).value'; }

cat <<EOF | ssh "root@$HOST" "k3s kubectl apply -f -"
apiVersion: v1
kind: Secret
metadata:
  name: media-setup
  namespace: $NS
type: Opaque
data:
  qbt-password: $(b64 "$(get qbittorrent-password)")
  nzbgeek-api: $(b64 "$(get nzbgeek_api)")
  jellyfin-admin-user: $(b64 "$(get jellyfin-admin-user)")
  jellyfin-admin-pass: $(b64 "$(get jellyfin-admin-pass)")
  jellyfin-anton: $(b64 "$(get jellyfin-anton)")
  jellyfin-delfin: $(b64 "$(get jellyfin-delfin)")
  jellyfin-ciceley: $(b64 "$(get jellyfin-ciceley)")
  opensubtitles-user: $(b64 "$(get opensubtitles-user)")
  opensubtitles-pass: $(b64 "$(get opensubtitles-pass)")
EOF
echo "media-setup secret applied on $HOST ($NS)"
