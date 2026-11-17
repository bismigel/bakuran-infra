# Remaining Zero Trust applications. Policies are inline, app-scoped policies;
# the provider imports the application and its policy references together.

resource "cloudflare_zero_trust_access_application" "books" {
  account_id                 = var.account_id
  name                       = "Books"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["lazylibrarian.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "d367db8b-962f-4386-8fe6-70771202bc38", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "media" {
  account_id       = var.account_id
  name             = "Homelab Media"
  type             = "self_hosted"
  session_duration = "730h"
  self_hosted_domains = [
    "sonarr.bismigel.dev", "radarr.bismigel.dev", "prowlarr.bismigel.dev",
    "bazarr.bismigel.dev", "qbittorrent.bismigel.dev", "sabnzbd.bismigel.dev",
    "homepage.bismigel.dev", "prometheus.bismigel.dev",
  ]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "1f459006-367d-4964-81f7-ff1b24949fae", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "longhorn" {
  account_id                 = var.account_id
  name                       = "Longhorn"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["longhorn.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "76712f1c-3b76-43fe-8cca-29f319eecafc", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "private_api" {
  account_id                 = var.account_id
  name                       = "Private API"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["private.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "30fe9543-3604-4b09-96d5-9b8c9aad01b8", precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "agent" {
  account_id                 = var.account_id
  name                       = "Homelab Agent"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["agent.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "1b42de62-3604-42ae-b2fd-cca2879ba40d", precedence = 1 }]
}

# Reusable allow policy for the runbook (same allowlist as the other admin apps).
resource "cloudflare_zero_trust_access_policy" "runbook" {
  account_id = var.account_id
  name       = "Runbook"
  decision   = "allow"
  include = concat(
    [{ email = { email = "bismigel@pm.me" } }],
    [for e in var.household_emails : { email = { email = e } }],
  )
}

resource "cloudflare_zero_trust_access_application" "runbook" {
  account_id                 = var.account_id
  name                       = "Runbook"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["runbook.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = cloudflare_zero_trust_access_policy.runbook.id, precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "grafana" {
  account_id                 = var.account_id
  name                       = "Grafana"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["grafana.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "eccc596c-0f1a-4aa7-b284-ed91b8a32d33", precedence = 1 }]
}
resource "cloudflare_zero_trust_access_policy" "forgejo" {
  account_id = var.account_id
  name       = "Forgejo"
  decision   = "allow"
  include = concat(
    [{ email = { email = "bismigel@pm.me" } }],
    [for e in var.household_emails : { email = { email = e } }],
  )
}

resource "cloudflare_zero_trust_access_application" "forgejo" {
  account_id                 = var.account_id
  name                       = "Forgejo"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["git.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = cloudflare_zero_trust_access_policy.forgejo.id, precedence = 1 }]
}


# Live since before this directory existed, and absent from it: the tools page (path-scoped, two destinations, so a
# plain domain would gate the wrong thing) and the pane itself. Both were found by diffing the account's Access apps
# against this file - the same audit that found vault/tools missing from the tunnel.
resource "cloudflare_zero_trust_access_application" "tools" {
  account_id          = var.account_id
  name                = "Tools (private)"
  type                = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["tools.ciceley.cc/lab", "tools.ciceley.cc/api/lab"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "1b1906af-1588-4d62-ba33-2179f2d58047", precedence = 1 }]
}

# Story 7.5: Argo Workflows' own UI is the human pane for every runbook action. Behind Access like every other admin
# surface, with the same 24h session - the pane can submit a procedure, so it is not less sensitive than ArgoCD.
resource "cloudflare_zero_trust_access_application" "argo" {
  account_id                 = var.account_id
  name                       = "Argo Workflows"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["argo.bismigel.dev"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = "58ec6a0b-609d-43b0-b2c2-f17bf08c2243", precedence = 1 }]
}
