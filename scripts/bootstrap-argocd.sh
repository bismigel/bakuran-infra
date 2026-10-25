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

  # ---- ArgoCD Redis: single node for now ----
  # Redis HA is prepared in scripts/argocd-redis-ha.yaml but deferred until the
  # service-label and sentinel issues are resolved. ArgoCD uses the single Redis.
  echo ">> Redis: single node"
  $KUBECTL -n argocd patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"redis.server":"argocd-redis:6379"}}' >/dev/null
  $KUBECTL -n argocd rollout restart \
    deploy/argocd-repo-server deploy/argocd-applicationset-controller \
    statefulset/argocd-application-controller >/dev/null

  # ---- ArgoCD HA: survive losing the node a component runs on ----
  # Stateless components scale to 2; the controller StatefulSet runs
  # active/standby via leader election. Redis runs in HA mode.
  #
  # Anti-affinity is REQUIRED, not preferred. With `preferred` the scheduler put
  # every replica on one node - verified 2026-10-25: all of server, repo-server,
  # applicationset and controller sat on sitaw-amd, so losing that node took
  # ArgoCD down completely while every pod still reported Ready. Only .81/.82 are
  # schedulable (.83 is tainted and these workloads have no toleration), which is
  # exactly two nodes for two replicas.
echo ">> HA: scale stateless components + controller"
$KUBECTL -n argocd scale deploy/argocd-server deploy/argocd-repo-server \
  deploy/argocd-applicationset-controller --replicas=2
$KUBECTL -n argocd scale statefulset/argocd-application-controller --replicas=2
$KUBECTL -n argocd set env statefulset/argocd-application-controller \
  ARGOCD_CONTROLLER_REPLICAS=2 >/dev/null
for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
  # NOTE: a required term takes labelSelector + topologyKey directly. The
  # `podAffinityTerm` wrapper only exists for preferred terms - nesting it here
  # is silently invalid (topologyKey resolves empty).
  $KUBECTL -n argocd patch deploy/"$d" --type merge -p \
    "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"podAntiAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":[{\"labelSelector\":{\"matchLabels\":{\"app.kubernetes.io/name\":\"$d\"}},\"topologyKey\":\"kubernetes.io/hostname\"}]}}}}}}" >/dev/null
done
  # maxSurge 0 is required *with* required anti-affinity, not a preference: a new
  # pod cannot schedule while the previous ReplicaSet's pod still holds the other
  # node, so the default surge strategy deadlocks the rollout (pods Pending).
  for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
    $KUBECTL -n argocd patch deploy/"$d" --type merge -p \
      '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}' >/dev/null
  done
$KUBECTL -n argocd patch statefulset/argocd-application-controller --type merge -p \
  '{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchLabels":{"app.kubernetes.io/name":"argocd-application-controller"}},"topologyKey":"kubernetes.io/hostname"}]}}}}}' >/dev/null

# ---- Edge exposure: HTTP behind ingress-nginx (TLS terminates at Cloudflare) ----
echo ">> ArgoCD server.insecure + ingress"
$KUBECTL -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
$KUBECTL -n argocd rollout restart deploy/argocd-server >/dev/null
$KUBECTL apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
spec:
  ingressClassName: nginx-admin
  rules:
    - host: argocd.bismigel.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

# ---- ArgoCD admin password from Bitwarden (declarative, not a random default) ----
if [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
  export NIX_CONFIG="experimental-features = nix-command flakes"
  PW="$(nix run --impure nixpkgs#bws -- secret list --output json 2>/dev/null \
        | nix run nixpkgs#jq -- -r '.[]|select(.key=="argocd-admin-password").value')"
  if [ -n "$PW" ] && [ "$PW" != "null" ]; then
    HASH="$(nix shell nixpkgs#apacheHttpd -c htpasswd -bnBC 10 "" "$PW" 2>/dev/null | tr -d ':\n')"
    $KUBECTL -n argocd patch secret argocd-secret --type merge -p \
      "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
    echo ">> ArgoCD admin password set from Bitwarden (argocd-admin-password)"
  fi
fi

echo ">> done. Next: create the BWS token Secret (REBUILD.md step 3)."
