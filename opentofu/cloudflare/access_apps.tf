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
  policies                   = [{ id = cloudflare_zero_trust_access_policy.household.id, precedence = 1 }]
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
  policies                   = [{ id = cloudflare_zero_trust_access_policy.household.id, precedence = 1 }]
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
  policies                   = [{ id = cloudflare_zero_trust_access_policy.operator.id, precedence = 1 }]
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
  policies                   = [{ id = cloudflare_zero_trust_access_policy.operator.id, precedence = 1 }]
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
  policies                   = [{ id = cloudflare_zero_trust_access_policy.household.id, precedence = 1 }]
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
  account_id = var.account_id
  name                       = "Tools (private)"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["tools.ciceley.cc/lab", "tools.ciceley.cc/api/lab"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = cloudflare_zero_trust_access_policy.household.id, precedence = 1 }]
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
  policies                   = [{ id = cloudflare_zero_trust_access_policy.household.id, precedence = 1 }]
}

# The container registry (story 15.11). Forgejo serves OCI under the SAME hostname as the git UI, and the app above puts
# that whole hostname behind Access. A registry client (buildah, docker, skopeo) discovers `https://git.bismigel.dev/v2/token`
# from the `WWW-Authenticate` header of `/v2/` and follows it - it cannot answer an SSO redirect, so today no client can
# authenticate from anywhere that is not holding a browser session. Measured 2026-11-18 from a pod in the cluster:
#
#   http://forgejo.forgejo.svc:3000/v2/  -> 401, realm = https://git.bismigel.dev/v2/token
#   https://git.bismigel.dev/v2/token    -> 302 -> bakuran.cloudflareaccess.com/.../access/login/git.bismigel.dev
#
# So: a PATH-scoped application for `/v2` with a `bypass` policy. Path scoping is the whole safety argument -
# `tools.ciceley.cc/lab` above proves the provider and the API accept it, and Cloudflare matches the most specific path
# first, so the git UI stays behind the allow policy untouched.
#
# This is not an open door: Forgejo's registry authenticates every request with its own token (`/v2/` answers 401 with no
# credentials), and a token is scoped per repository and per action (`read:package` / `write:package`). What the bypass
# removes is only the *SSO* layer, which a machine client can never satisfy.
resource "cloudflare_zero_trust_access_policy" "forgejo_registry" {
  account_id = var.account_id
  name       = "Forgejo registry (machine clients, no SSO)"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "forgejo_registry" {
  account_id                 = var.account_id
  name                       = "Forgejo container registry"
  type                       = "self_hosted"
  session_duration           = "24h"
  self_hosted_domains        = ["git.bismigel.dev/v2"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = cloudflare_zero_trust_access_policy.forgejo_registry.id, precedence = 1 }]
}

# ---- Policies, declared instead of referenced by UUID (2026-11-18) ----
#
# These seven apps pointed at bare UUIDs (`policies = [{ id = "58ec6a0b-…" }]`), which are APP-SCOPED policies: they do not
# appear in the account's policy list and their rules — which emails, and therefore who gets in — existed only in
# Cloudflare's UI. A hand edit there would never have appeared in a plan. Each block below was written from the live
# definition (`GET /accounts/{id}/access/apps`, 2026-11-18), so the import is a capture, not a guess:
#
#   Argo Workflows, Tools, Books, Homelab Media, Grafana  -> household (two addresses)
#   ArgoCD, Longhorn, Homelab Agent                       -> operator only (one address)
#
# The operator-only three are left as they are: narrower than the household list is not a finding.

resource "cloudflare_zero_trust_access_policy" "household" {
  account_id = var.account_id
  name       = "Household"
  decision   = "allow"
  include = [
    for e in var.household_emails : { email = { email = e } }
  ]
}

resource "cloudflare_zero_trust_access_policy" "operator" {
  account_id = var.account_id
  name       = "Operator"
  decision   = "allow"
  include    = [{ email = { email = var.operator_email } }]
}

# EasyShortlist: the site is public, the admin view is not. Cloudflare matches the most specific path, so
# `easyshortlist.ciceley.cc/admin` is gated and the rest of the host is untouched - the same shape as
# `tools.ciceley.cc/lab`. `operator`, not `household`: the admin view is the estate owner's.
#
# After apply, the application's AUD tag goes into Bitwarden as `easyshortlist-cf-access-aud` and the team domain
# as `easyshortlist-cf-access-team`; the app verifies `Cf-Access-Jwt-Assertion` itself, so a request that reaches
# it around the edge still gets 403 on /admin.
resource "cloudflare_zero_trust_access_application" "easyshortlist_admin" {
  account_id                 = var.account_id
  name                       = "EasyShortlist admin"
  type                       = "self_hosted"
  session_duration           = "8h"
  self_hosted_domains        = ["easyshortlist.ciceley.cc/admin"]
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  options_preflight_bypass   = false
  http_only_cookie_attribute = true
  policies                   = [{ id = cloudflare_zero_trust_access_policy.operator.id, precedence = 1 }]
}
