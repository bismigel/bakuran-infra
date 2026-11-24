#!/usr/bin/env bash
# Source this before running tofu. It fetches the API credential from Bitwarden
# Secrets Manager and puts it in the environment - nothing is written to disk.
#
#   . ./env.sh && tofu plan
#
# Requires: BWS_ACCESS_TOKEN (machine account) and the secret IDs below.
# The IDs are not secrets; the values never touch this repo or the shell history.
set -euo pipefail

: "${BWS_ACCESS_TOKEN:?set BWS_ACCESS_TOKEN (machine-account token) first}"
: "${OPNSENSE_KEY_ID:?set OPNSENSE_KEY_ID to the BWS secret id of the API key}"
: "${OPNSENSE_SECRET_ID:?set OPNSENSE_SECRET_ID to the BWS secret id of the API secret}"

# Prefer what is on PATH (both are in the user profile); fall back to nix with the unfree
# flag that `bws` needs. The original `nix run --impure nixpkgs#bws` could never work:
# --impure only allows the env var, it does not set it, and bws is unfree.
bws() { if command -v bws >/dev/null 2>&1; then command bws "$@"; else NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#bws -- "$@"; fi; }
jq()  { if command -v jq >/dev/null 2>&1; then command jq "$@"; else nix run nixpkgs#jq -- "$@"; fi; }

export TF_VAR_opnsense_api_key="$(bws secret get "$OPNSENSE_KEY_ID" -o json | jq -r .value)"
export TF_VAR_opnsense_api_secret="$(bws secret get "$OPNSENSE_SECRET_ID" -o json | jq -r .value)"
export TF_VAR_opnsense_uri="${TF_VAR_opnsense_uri:-https://192.168.2.254}"

echo "opnsense: credentials loaded into the environment (values not printed)"
