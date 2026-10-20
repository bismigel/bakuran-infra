resource "cloudflare_zero_trust_access_application" "argocd" {
  account_id                = var.account_id
  name                      = "ArgoCD"
  type                      = "self_hosted"
  session_duration          = "24h"
  self_hosted_domains       = ["argocd.bismigel.dev"]
  auto_redirect_to_identity = false
  enable_binding_cookie     = false
  options_preflight_bypass  = false
  policies = [
    {
      id         = "230d07e8-9a63-4451-a7dd-2a84392a5012"
      precedence = 1
    }
  ]
}
