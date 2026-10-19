#!/usr/bin/env bash
set -euo pipefail

: "${DECK_HOST:?set DECK_HOST, for example 192.168.2.90}"
STAGING_KUBECONFIG="${STAGING_KUBECONFIG:-/tmp/staging-deck-kubeconfig}"
STATUS_API_DIR="${STATUS_API_DIR:-$HOME/projects/status-api}"

echo ">> checking SSH"
ssh -o BatchMode=yes "root@$DECK_HOST" true

echo ">> applying NixOS configuration"
nixos-rebuild switch --flake .#staging-deck \
  --target-host "root@$DECK_HOST" --use-remote-sudo

echo ">> fetching kubeconfig"
ssh -o BatchMode=yes "root@$DECK_HOST" \
  'cat /etc/rancher/k3s/k3s.yaml' |
  sed "s#https://127.0.0.1:6443#https://$DECK_HOST:6443#" \
  > "$STAGING_KUBECONFIG"
chmod 600 "$STAGING_KUBECONFIG"

echo ">> waiting for k3s"
KUBECONFIG="$STAGING_KUBECONFIG" timeout 180 bash -c \
  'until kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 3; done'

echo ">> applying staging overlay"
KUBECONFIG="$STAGING_KUBECONFIG" kubectl apply \
  -k "$STATUS_API_DIR/deploy/overlays/staging"

echo ">> staging is ready on $DECK_HOST"
