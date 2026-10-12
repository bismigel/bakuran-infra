#!/usr/bin/env bash
# backup-credentials.sh — bank the recovery-critical material to Cloudflare R2,
# age-encrypted to a dedicated key whose private half lives in Bitwarden/offline.
#
#   AGE_RECIPIENT=age1... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
#   R2_ENDPOINT=https://<acct>.r2.cloudflarestorage.com ./backup-credentials.sh
#
# Run on each node (host keys differ). Requires: age, rclone, k3s.
set -euo pipefail
: "${AGE_RECIPIENT:?set AGE_RECIPIENT (backup age public key)}"
: "${R2_ACCESS_KEY_ID:?}"; : "${R2_SECRET_ACCESS_KEY:?}"; : "${R2_ENDPOINT:?}"
R2_BUCKET="${R2_BUCKET:-homelab-backups}"

export RCLONE_CONFIG_R2_TYPE=s3 \
       RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
       RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
       RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
       RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT

# host SSH keys = the SOPS age identity
cp /etc/ssh/ssh_host_ed25519_key* "$w"/ 2>/dev/null || true
cp /etc/ssh/ssh_host_rsa_key*     "$w"/ 2>/dev/null || true
# k3s admin kubeconfig
cp /etc/rancher/k3s/k3s.yaml "$w/k3s.yaml" 2>/dev/null || true
# ESO root of trust (the Bitwarden machine-account token)
k3s kubectl -n external-secrets get secret bitwarden-access-token -o yaml \
  > "$w/bws-access-token.yaml" 2>/dev/null || true
# (sealed-secrets key only if that controller is still present)
k3s kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > "$w/sealed-secrets-keys.yaml" 2>/dev/null || true

out="/tmp/creds-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
tar czf - -C "$w" . | age -r "$AGE_RECIPIENT" > "$out"
rclone copy "$out" "r2:$R2_BUCKET/credentials/"
rm -f "$out"
echo "uploaded $(basename "$out") to r2:$R2_BUCKET/credentials/"
