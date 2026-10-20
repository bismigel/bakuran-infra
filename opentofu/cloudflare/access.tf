resource "cloudflare_zero_trust_access_application" "argocd" {
  account_id          = var.account_id
  name                = "ArgoCD"
  type                = "self_hosted"
  session_duration    = "24h"
  self_hosted_domains = ["argocd.bismigel.dev"]
}
