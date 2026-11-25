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
# The state backend (R2) credential, from the same store, by key name. Until 2026-11-25 the README said to
# source ~/.config/opentofu/r2.env, a copy made 2026-11-01 that had since gone stale: `tofu plan` failed with
# SignatureDoesNotMatch before it ever reached the router.
_bws_all=$(bws secret list -o json 2>/dev/null)
_by_key() { printf '%s' "$_bws_all" | jq -r --arg k "$1" '[.[] | select(.key == $k) | .value] | if length == 1 then .[0] else error("expected one \($k)") end'; }
export AWS_ACCESS_KEY_ID="$(_by_key r2-access-key-id)"
export AWS_SECRET_ACCESS_KEY="$(_by_key r2-secret-access-key)"
export AWS_DEFAULT_REGION=auto
unset _bws_all; unset -f _by_key

export TF_VAR_opnsense_uri="${TF_VAR_opnsense_uri:-https://192.168.10.1}"

echo "opnsense: credentials loaded into the environment (values not printed)"
