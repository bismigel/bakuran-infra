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

  # The OPNsense WebGUI certificate is self-signed and carries **no IP SAN**, so TLS
  # verification against https://192.168.2.1 cannot succeed:
  #     x509: cannot validate certificate for 192.168.2.1 because it doesn't contain any
  #     IP SANs
  # Verified 2026-11-01 against the live box with a read-only interfaces data source.
  #
  # This flag is acceptable *for a tool run from the LAN against the router's own cert*
  # (which is what the WebGUI itself does). The real fix is a certificate with a SAN for
  # the address - recorded in homelab-context/NETWORK-AS-CODE.md. Flip this off when that
  # exists; it is not a licence to talk to other hosts this way.
  insecure = true
}
