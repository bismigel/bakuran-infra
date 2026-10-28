#!/usr/bin/env bash
set -euo pipefail

: "${DECK_HOST:?set DECK_HOST}"
STAGING_KUBECONFIG="${STAGING_KUBECONFIG:-/tmp/staging-deck-kubeconfig}"

KUBECONFIG="$STAGING_KUBECONFIG" kubectl get nodes
KUBECONFIG="$STAGING_KUBECONFIG" kubectl -n staging get pods,svc

ssh -o BatchMode=yes "root@$DECK_HOST" \
  'echo -n "production API: "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 https://192.168.2.82:6443 || echo blocked'
