#!/usr/bin/env bash
# bootstrap-argocd.sh — install ArgoCD and start the app-of-apps. Idempotent.
# Run ON the control-plane box (sitaw-amd). The only manual bootstrap step.
#
#   ARGO_REPO_SSH_KEY=/path/to/deploy_key [ROOT_APP=/path/to/root-app.yaml] ./bootstrap-argocd.sh
#
# The repo SSH key is the GitHub deploy key for bismigel/bakuran-gitops
# (kept in Bitwarden). Everything after this is GitOps.
set -euo pipefail
KUBECTL="${KUBECTL:-k3s kubectl}"
: "${ARGO_REPO_SSH_KEY:?set ARGO_REPO_SSH_KEY to the bakuran-gitops deploy key file}"
ROOT_APP="${ROOT_APP:-bootstrap/root-app.yaml}"

echo ">> install ArgoCD"
$KUBECTL create namespace argocd --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo ">> wait for argocd-server"
$KUBECTL -n argocd rollout status deploy/argocd-server --timeout=300s

echo ">> repo credentials"
$KUBECTL -n argocd create secret generic repo-bakuran-gitops \
  --from-literal=type=git \
  --from-literal=url=git@github.com:bismigel/bakuran-gitops.git \
  --from-literal=name=bakuran-gitops \
  --from-file=sshPrivateKey="$ARGO_REPO_SSH_KEY" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n argocd label secret repo-bakuran-gitops \
  argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

echo ">> root app-of-apps"
$KUBECTL -n argocd apply -f "$ROOT_APP"

echo ">> done. Next: register the media cluster + create the BWS token (REBUILD.md steps 4-5)."
