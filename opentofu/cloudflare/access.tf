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
      id         = cloudflare_zero_trust_access_policy.operator.id
      precedence = 1
    }
  ]
}
