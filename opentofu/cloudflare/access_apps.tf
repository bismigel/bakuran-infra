# Remaining Zero Trust applications. Policies are inline, app-scoped policies;
# the provider imports the application and its policy references together.

resource "cloudflare_zero_trust_access_application" "books" {
  account_id             = var.account_id
  name                   = "Books"
  type                   = "self_hosted"
  session_duration       = "24h"
  self_hosted_domains    = ["lazylibrarian.bismigel.dev"]
  auto_redirect_to_identity = false
  enable_binding_cookie  = false
  options_preflight_bypass = false
  http_only_cookie_attribute = true
  policies = [{ id = "d367db8b-962f-4386-8fe6-70771202bc38", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "media" {
  account_id             = var.account_id
  name                   = "Homelab Media"
  type                   = "self_hosted"
  session_duration       = "730h"
  self_hosted_domains    = [
    "sonarr.bismigel.dev", "radarr.bismigel.dev", "prowlarr.bismigel.dev",
    "bazarr.bismigel.dev", "qbittorrent.bismigel.dev", "sabnzbd.bismigel.dev",
    "homepage.bismigel.dev", "prometheus.bismigel.dev",
  ]
  auto_redirect_to_identity = false
  enable_binding_cookie  = false
  options_preflight_bypass = false
  http_only_cookie_attribute = true
  policies = [{ id = "1f459006-367d-4964-81f7-ff1b24949fae", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "longhorn" {
  account_id             = var.account_id
  name                   = "Longhorn"
  type                   = "self_hosted"
  session_duration       = "24h"
  self_hosted_domains    = ["longhorn.bismigel.dev"]
  auto_redirect_to_identity = false
  enable_binding_cookie  = false
  options_preflight_bypass = false
  http_only_cookie_attribute = true
  policies = [{ id = "76712f1c-3b76-43fe-8cca-29f319eecafc", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "private_api" {
  account_id             = var.account_id
  name                   = "Private API"
  type                   = "self_hosted"
  session_duration       = "24h"
  self_hosted_domains    = ["private.bismigel.dev"]
  auto_redirect_to_identity = false
  enable_binding_cookie  = false
  options_preflight_bypass = false
  http_only_cookie_attribute = true
  policies = [{ id = "30fe9543-3604-4b09-96d5-9b8c9aad01b8", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "agent" {
  account_id             = var.account_id
  name                   = "Homelab Agent"
  type                   = "self_hosted"
  session_duration       = "24h"
  self_hosted_domains    = ["agent.bismigel.dev"]
  auto_redirect_to_identity = false
  enable_binding_cookie  = false
  options_preflight_bypass = false
  http_only_cookie_attribute = true
  policies = [{ id = "1b42de62-3604-42ae-b2fd-cca2879ba40d", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "grafana" {
  account_id             = var.account_id
  name                   = "Grafana"
  type                   = "self_hosted"
  session_duration       = "24h"
  self_hosted_domains    = ["grafana.bismigel.dev"]
  auto_redirect_to_identity = false
  enable_binding_cookie  = false
  options_preflight_bypass = false
  http_only_cookie_attribute = true
  policies = [{ id = "eccc596c-0f1a-4aa7-b284-ed91b8a32d33", precedence = 1 }]
}
