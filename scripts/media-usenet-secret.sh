#!/usr/bin/env bash
# Create/update the `usenet-frugal` Secret on the MEDIA cluster (calamansi-intel,
# .81) from Bitwarden. The media cluster has NO External Secrets operator (ESO
# runs only on .82), so this Secret is applied out of band. Re-run after any
# rebuild of the media box.
#
#   BWS_ACCESS_TOKEN=<machine-account-token> ./scripts/media-usenet-secret.sh
#
# HOST can override the target (default 192.168.2.81).
set -euo pipefail
export NIXPKGS_ALLOW_UNFREE="${NIXPKGS_ALLOW_UNFREE:-1}"
: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN to the Bitwarden machine-account token}"
HOST="${HOST:-192.168.2.81}"
NS="${NS:-downloads}"

bws() { nix run --impure nixpkgs#bws -- "$@"; }
jq()  { nix run nixpkgs#jq -- "$@"; }

secrets="$(bws secret list --output json 2>/dev/null)"
get() { printf '%s' "$secrets" | jq -r ".[]|select(.key==\"$1\").value"; }

U="$(get usenet_frugal_user)"
P="$(get usenet_frugal_pass)"
[ -n "$U" ] && [ -n "$P" ] || { echo "error: missing usenet_frugal_user/pass in Bitwarden" >&2; exit 1; }

UB="$(printf %s "$U" | base64 -w0)"
PB="$(printf %s "$P" | base64 -w0)"

cat <<EOF | ssh "root@$HOST" "k3s kubectl apply -f -"
apiVersion: v1
kind: Secret
metadata:
  name: usenet-frugal
  namespace: $NS
type: Opaque
data:
  user: $UB
  pass: $PB
EOF
echo "usenet-frugal secret applied on $HOST ($NS)"
