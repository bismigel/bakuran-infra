#!/usr/bin/env bash
# Rebuild the books stack configuration in one command (idempotent).
#
#   BWS_ACCESS_TOKEN=<machine-token> ./scripts/books-bootstrap.sh
#
# Runs: media-setup secret (if missing) -> Kavita admin/library -> ciceley ->
# LazyLibrarian (SABnzbd, NZBGeek, API key, Wanted defaults, download dir).
# Safe to re-run. Needs nix, kubectl, ssh root@.81/.82.
set -euo pipefail
export NIXPKGS_ALLOW_UNFREE="${NIXPKGS_ALLOW_UNFREE:-1}"
: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use the host tools when present; otherwise fall back to `nix run` wrappers so
# this works on a bare nix-station.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
wrap() { # <bin> <attr> [extra nix args...]
  local bin="$1" attr="$2"; shift 2
  printf '#!/bin/sh\nexec nix run %s nixpkgs#%s -- "$@"\n' "$*" "$attr" > "$tmp/$bin"
  chmod +x "$tmp/$bin"
}
for b in sqlite3:sqlite python3:python3 jq:jq bws:bws; do
  bin="${b%%:*}"; attr="${b##*:}"
  command -v "$bin" >/dev/null 2>&1 || wrap "$bin" "$attr" --impure
done
export PATH="$tmp:$PATH"

kubectl -n media get secret media-setup >/dev/null 2>&1 \
  || "$HERE/media-setup-secret.sh"

echo ">> Kavita: admin + library"
"$HERE/kavita-setup.sh"
echo ">> Kavita: ciceley"
"$HERE/kavita-add-user.sh" ciceley
echo ">> LazyLibrarian: clients, provider, defaults, API"
"$HERE/lazylibrarian-ui-setup.sh"
echo ">> books stack configured"
