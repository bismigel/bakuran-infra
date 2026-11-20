#!/usr/bin/env bash
# Source before running tofu: exports the Checkly + Grafana tokens from SOPS (encrypted at rest).
#   . ./env.sh && tofu plan
# Nothing is printed; values stay in the environment.
set -euo pipefail
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/homelab.txt"
# Absolute path to the repo root, WITHOUT changing the caller's cwd - tofu must run in
# this directory, not the repo root (an earlier `cd` made `tofu plan` find no config).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sopsval() { sops -d --output-type json "$REPO_ROOT/secrets/homelab.yaml" 2>/dev/null | jq -r ".$1"; }

export TF_VAR_checkly_api_key;    TF_VAR_checkly_api_key="$(sopsval checkly_api_key)"
export TF_VAR_checkly_account_id; TF_VAR_checkly_account_id="$(sopsval checkly_account_id)"
export TF_VAR_grafana_auth;       TF_VAR_grafana_auth="$(sopsval grafana_instance_token)"
export TF_VAR_sm_access_token;    TF_VAR_sm_access_token="$(sopsval grafana_sm_token)"

python3 - <<'PY'
import os
for v in ("TF_VAR_checkly_api_key","TF_VAR_checkly_account_id","TF_VAR_grafana_auth","TF_VAR_sm_access_token"):
    print(f"  {v}: {'set ('+str(len(os.environ.get(v,'')))+' chars)' if os.environ.get(v) else 'MISSING'}")
PY
