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
# server-side apply: the ApplicationSet CRD exceeds the 262144-byte annotation
# limit for client-side apply.
$KUBECTL -n argocd apply --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

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

# ---- ArgoCD HA: survive losing the node a component runs on ----
# Stateless components scale to 2 with soft anti-affinity; the controller
# StatefulSet runs active/standby via leader election. (Redis stays single and
# is a known SPOF — see REBUILD.md.)
echo ">> HA: scale stateless components + controller"
$KUBECTL -n argocd scale deploy/argocd-server deploy/argocd-repo-server \
  deploy/argocd-applicationset-controller --replicas=2
$KUBECTL -n argocd scale statefulset/argocd-application-controller --replicas=2
$KUBECTL -n argocd set env statefulset/argocd-application-controller \
  ARGOCD_CONTROLLER_REPLICAS=2 >/dev/null
for d in argocd-server argocd-repo-server; do
  $KUBECTL -n argocd patch deploy/"$d" --type merge -p \
    "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"podAntiAffinity\":{\"preferredDuringSchedulingIgnoredDuringExecution\":[{\"weight\":100,\"podAffinityTerm\":{\"labelSelector\":{\"matchLabels\":{\"app.kubernetes.io/name\":\"$d\"}},\"topologyKey\":\"kubernetes.io/hostname\"}}]}}}}}}" >/dev/null
done

echo ">> done. Next: create the BWS token Secret (REBUILD.md step 3)."
