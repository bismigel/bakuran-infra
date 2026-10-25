#!/usr/bin/env bash
# Configure LazyLibrarian (SABnzbd download client + NZBGeek/Newznab provider)
# by driving its web UI with Playwright. Safe to re-run: it re-submits the same
# values. The app has no config API and drops externally-seeded config.ini
# sections, so this UI path is the only reliable one.
#
#   ./scripts/lazylibrarian-ui-setup.sh
#
# No secrets are passed from the host: SAB/NZB keys are read in-cluster from the
# `media-setup` Secret. The Job runs in the `media` namespace (to reach that
# Secret) and is pinned to sitaw-amd, which has direct internet egress for
# `npm i playwright`. HOST can override the kubectl target.
set -euo pipefail

HOST="${HOST:-192.168.2.81}"
NS="${NS:-media}"
CM_NAME="lazylibrarian-ui-setup"
JOB_NAME="lazylibrarian-ui-setup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

k() { ssh "root@$HOST" "k3s kubectl -n $NS $*"; }

echo "creating ConfigMap $CM_NAME ($NS)"
REMOTE_SCRIPT="/tmp/$CM_NAME.js"
ssh "root@$HOST" "cat > $REMOTE_SCRIPT" < "$SCRIPT_DIR/lazylibrarian-ui-setup.js"
ssh "root@$HOST" "k3s kubectl -n $NS create configmap $CM_NAME --from-file=setup.js=$REMOTE_SCRIPT --dry-run=client -o yaml | k3s kubectl apply -f -"
ssh "root@$HOST" "rm -f $REMOTE_SCRIPT"

k delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true

cat <<EOF | ssh "root@$HOST" "k3s kubectl apply -f -"
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NS
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { kubernetes.io/hostname: sitaw-amd }
      containers:
        - name: playwright
          image: mcr.microsoft.com/playwright:v1.64.1-jammy
          command: ["sh", "-c"]
          args:
            - |
              cd /tmp && npm init -y >/dev/null 2>&1 && npm i --no-audit --no-fund playwright@1.64.1 >/dev/null 2>&1
              cp /scripts/setup.js /tmp/setup.js
              cd /tmp && node setup.js
          env:
            - { name: SAB_HOST, value: sabnzbd.downloads.svc.cluster.local }
            - name: SAB_KEY
              valueFrom: { secretKeyRef: { name: media-setup, key: sabnzbd-api-key } }
            - name: NZB_KEY
              valueFrom: { secretKeyRef: { name: media-setup, key: nzbgeek-api } }
            - name: LL_API_KEY
              valueFrom: { secretKeyRef: { name: media-setup, key: lazylibrarian-api-key } }
            - { name: QBT_HOST, value: qbittorrent.downloads.svc.cluster.local }
            - { name: QBT_USER, value: admin }
            - name: QBT_PASS
              valueFrom: { secretKeyRef: { name: media-setup, key: qbt-password } }
          volumeMounts:
            - { name: script, mountPath: /scripts }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 1Gi }
      volumes:
        - name: script
          configMap: { name: $CM_NAME }
EOF

echo "waiting for job $JOB_NAME"
for _ in $(seq 1 60); do
  phase="$(ssh "root@$HOST" "k3s kubectl -n $NS get pod -l job-name=$JOB_NAME -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || true)"
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 5
done

k logs "job/$JOB_NAME" --tail=20 || true
status="$(ssh "root@$HOST" "k3s kubectl -n $NS get job $JOB_NAME -o jsonpath='{.status.succeeded}'" 2>/dev/null || true)"
k delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
k delete configmap "$CM_NAME" --ignore-not-found >/dev/null 2>&1 || true

if [ "$status" = "1" ]; then
  echo "LazyLibrarian configured; restarting it to load the new config"
  ssh "root@$HOST" "k3s kubectl -n books rollout restart deploy/lazylibrarian" >/dev/null
  echo "done"
else
  echo "error: job did not succeed (see logs above)" >&2
  exit 1
fi
