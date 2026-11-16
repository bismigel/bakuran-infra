#!/usr/bin/env bash
# Push the estate's CI secrets from Bitwarden into Forgejo, so the vault is the only place they are authored.
#
# Why a script and not an operator: Forgejo Actions secrets live in Forgejo's own database and have no external source -
# there is no ExternalSecret equivalent for a git server's CI. The alternative is typing values into a web form, which is
# how a copy drifts from the vault and nobody notices until a token is revoked in one place and not the other.
#
#   BWS_ACCESS_TOKEN=... FORGEJO_TOKEN=... scripts/forgejo-sync-secrets.sh [--dry-run]
set -euo pipefail

: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN (machine-account token)}"
: "${FORGEJO_TOKEN:?set FORGEJO_TOKEN (a Forgejo token with write:repository)}"
api="${FORGEJO_URL:-http://127.0.0.1:18080}/api/v1"
dry=${1:-}

map=(
  "bismigel-site:REPO_READ_TOKEN:forgejo-read-token"
  "media-mcp:REPO_READ_TOKEN:forgejo-read-token"
  "bakuran-gitops:SITE_TOKEN:forgejo-read-token"
  "media-mcp:REGISTRY_PASSWORD:registry-password"
  # The site's deploy workflow pushes the image and merges its own tag-bump PR, so it needs a token that can write.
  # Separate from the read token on purpose: a build that is compromised should not be able to read every repository.
  "bismigel-site:REGISTRY_PASSWORD:registry-password"
  "bismigel-site:FORGEJO_WRITE_TOKEN:forgejo-write-token"
)

for entry in "${map[@]}"; do
  IFS=: read -r repo name key <<<"$entry"
  id=$(bws secret list | jq -r --arg k "$key" '.[] | select(.key==$k) | .id')
  value=$(bws secret get "$id" | jq -r .value)
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "  $repo/$name: $key is EMPTY in Bitwarden - refusing to write a blank secret" >&2
    exit 1
  fi
  if [ "$dry" = "--dry-run" ]; then
    printf '  %-18s %-20s would set from %s (%s chars)\n' "$repo" "$name" "$key" "${#value}"
    continue
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: token $FORGEJO_TOKEN" \
    -H 'Content-Type: application/json' -d "{\"data\":\"$value\"}" \
    "$api/repos/bismigel/$repo/actions/secrets/$name")
  printf '  %-18s %-20s %s\n' "$repo" "$name" "$code"
done

echo "  done. Bitwarden is the source; Forgejo holds the copy the runner reads."
