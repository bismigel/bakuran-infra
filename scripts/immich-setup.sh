#!/usr/bin/env bash
# immich-setup.sh — idempotently onboard Immich and create the household accounts.
#
# Immich accounts can't be declared through GitOps, so this script makes them
# reproducible after a rebuild:
#   * onboards the admin account
#   * creates the household users with the same passwords as Jellyfin
#
# Credentials come from Bitwarden Secrets Manager (jellyfin-admin-user /
# jellyfin-admin-pass, and jellyfin-<user> per account), so no secrets live here.
#
# Run ON a k3s node — the ingress NodePort is bound to loopback by design, so it
# isn't reachable from other machines:
#   BWS_ACCESS_TOKEN=... ./scripts/immich-setup.sh
#
# Requires: bash, curl, jq and bws (jq/bws fall back to `nix run`).
set -euo pipefail
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
export NIXPKGS_ALLOW_UNFREE=1

HOST="${HOST:-127.0.0.1}"
IMMICH_URL="${IMMICH_URL:-http://${HOST}:32080}"
IMMICH_HOST="${IMMICH_HOST:-immich.bismigel.dev}"
DOMAIN="${DOMAIN:-bismigel.dev}"
USERS="${USERS:-anton ciceley delfin guest}"

run_jq()  { if command -v jq  >/dev/null 2>&1; then jq  "$@"; else nix run --impure nixpkgs#jq  -- "$@"; fi; }
run_bws() { if command -v bws >/dev/null 2>&1; then bws "$@"; else nix run --impure nixpkgs#bws -- "$@"; fi; }

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
api() { curl -sS --max-time 30 -H "Host: ${IMMICH_HOST}" -H "Content-Type: application/json" "$@"; }

# Pull all secrets once to avoid repeated (slow) Bitwarden calls.
SECRETS="$(run_bws secret list --output json 2>/dev/null)"
secret() { run_jq -r --arg k "$1" '([.[] | select(.key==$k) | .value][0]) // empty' <<<"${SECRETS}"; }

ADMIN_USER="${ADMIN_USER:-$(secret jellyfin-admin-user)}"; ADMIN_USER="${ADMIN_USER:-gio}"
ADMIN_EMAIL="${ADMIN_EMAIL:-${ADMIN_USER}@${DOMAIN}}"

log "Onboard admin (${ADMIN_EMAIL})"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(secret jellyfin-admin-pass)}"
[ -n "$ADMIN_PASSWORD" ] || { echo "  no admin password (set ADMIN_PASSWORD or Bitwarden jellyfin-admin-pass)"; exit 1; }
api -X POST "${IMMICH_URL}/api/auth/admin-sign-up" \
  -d "$(run_jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg n "$ADMIN_USER" '{email:$e,password:$p,name:$n}')" \
  | run_jq -r 'if .id then "  created \(.email)" elif .message then "  \(.message)" else "  \(.)" end'

log "Log in as admin"
TOKEN="$(api -X POST "${IMMICH_URL}/api/auth/login" \
  -d "$(run_jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email:$e,password:$p}')" \
  | run_jq -r '.accessToken // empty')"
[ -n "$TOKEN" ] || { echo "  login failed"; exit 1; }
echo "  ok"

log "Create household users"
EXISTING="$(api -H "Authorization: Bearer ${TOKEN}" "${IMMICH_URL}/api/admin/users")"
for u in $USERS; do
  email="${u}@${DOMAIN}"
  if run_jq -e --arg e "$email" 'any(.[]; .email==$e)' <<<"${EXISTING}" >/dev/null 2>&1; then
    printf '  %-8s exists\n' "$u"; continue
  fi
  pw="$(secret "jellyfin-$u")"
  [ -n "$pw" ] || { printf '  %-8s SKIP (no jellyfin-%s secret)\n' "$u" "$u"; continue; }
  api -H "Authorization: Bearer ${TOKEN}" -X POST "${IMMICH_URL}/api/admin/users" \
    -d "$(run_jq -nc --arg e "$email" --arg p "$pw" --arg n "$u" '{email:$e,password:$p,name:$n}')" \
    | run_jq -r --arg u "$u" 'if .id then "  \($u) created" else "  \($u) FAILED: \(.)" end'
done

log "Accounts now"
api -H "Authorization: Bearer ${TOKEN}" "${IMMICH_URL}/api/admin/users" \
  | run_jq -r '.[] | "  \(.name)  \(.email)  admin=\(.isAdmin)"'
