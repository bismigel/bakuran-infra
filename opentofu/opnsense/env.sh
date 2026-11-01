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

bws() { nix run --impure nixpkgs#bws -- "$@"; }
jq()  { nix run nixpkgs#jq -- "$@"; }

export TF_VAR_opnsense_api_key="$(bws secret get "$OPNSENSE_KEY_ID" -o json | jq -r .value)"
export TF_VAR_opnsense_api_secret="$(bws secret get "$OPNSENSE_SECRET_ID" -o json | jq -r .value)"
export TF_VAR_opnsense_uri="${TF_VAR_opnsense_uri:-https://192.168.2.1}"

echo "opnsense: credentials loaded into the environment (values not printed)"
