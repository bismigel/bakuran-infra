#!/usr/bin/env bash
# Fill the API credentials from Bitwarden Secrets Manager, then run ansible in this directory.
#
#   ./run.sh playbooks/vnstat.yml --check --diff     # what would change
#   ./run.sh playbooks/vnstat.yml                    # do it
#
# `--check` first is not a formality: this root edits the only router in the estate, and a check that reports "no
# change" is the proof that the play agrees with reality before anything is written.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${OPNSENSE_API_KEY:-}" ]; then
  TOKEN=$(kubectl -n external-secrets get secret bitwarden-access-token -o jsonpath='{.data.token}' | base64 -d)
  ids=$(grep -oE "OPNSENSE_KEY_ID=[0-9a-f-]+" ../../opentofu/opnsense/README.md | head -1 | cut -d= -f2)
  sid=$(grep -oE "OPNSENSE_SECRET_ID=[0-9a-f-]+" ../../opentofu/opnsense/README.md | head -1 | cut -d= -f2)
  secrets=$(BWS_ACCESS_TOKEN="$TOKEN" bws secret list)
  export OPNSENSE_API_KEY=$(printf '%s' "$secrets" | jq -r --arg i "$ids" '.[] | select(.id==$i) | .value')
  export OPNSENSE_API_SECRET=$(printf '%s' "$secrets" | jq -r --arg i "$sid" '.[] | select(.id==$i) | .value')
fi
[ -n "${OPNSENSE_API_KEY:-}" ] || { echo "no OPNSENSE_API_KEY" >&2; exit 1; }

# The collection's modules need `httpx` at runtime, and they run on this controller (`ansible_connection: local`), so
# the interpreter that matters is the one ansible *executes modules with* — not the one ansible itself runs on. Two
# things are needed and both are pinned by the flake rather than by a remembered `pip install`:
#   * a python that has httpx, and
#   * `-e ansible_python_interpreter=<that python>`, because `auto_silent` otherwise discovers ansible's own python.
NIX_EXPR='let p = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}; in [ p.ansible (p.python3.withPackages (ps: [ ps.httpx ])) ]'
exec nix shell --impure --expr "$NIX_EXPR" -c bash -lc "
  cd '$PWD'
  ansible-galaxy collection install -r requirements.yml -p ./collections >/dev/null 2>&1
  exec ansible-playbook -e ansible_python_interpreter=\"\$(command -v python3)\" $*
"
