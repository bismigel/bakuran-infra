# Credentials come from the environment, never from a file in this repo:
#
#   export OPNSENSE_API_KEY="$(bws secret get <id> -o json | jq -r .value)"
#   export OPNSENSE_API_SECRET="$(bws secret get <id> -o json | jq -r .value)"
#
# See ../network/opnsense/env.sh (no values in it) and
# homelab-context/NETWORK-AS-CODE.md §9 for the vault layout and rotation order.
provider "opnsense" {
  uri        = var.opnsense_uri
  api_key    = var.opnsense_api_key
  api_secret = var.opnsense_api_secret
}
