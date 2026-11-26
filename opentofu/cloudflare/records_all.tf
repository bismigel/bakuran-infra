resource "cloudflare_dns_record" "r_git_bismigel" {
  zone_id = var.zone_id
  name    = "git.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_5c8ee45dec" {
  zone_id = var.zone_id
  name    = "agent.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_7a55828957" {
  zone_id = var.zone_id
  name    = "argocd.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_a01e1be6db" {
  zone_id = var.zone_id
  name    = "bazarr.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_734d871adc" {
  zone_id = var.zone_id
  name    = "bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_7e5f0578d2" {
  zone_id = var.zone_id
  name    = "grafana.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

# Operations runbook: served by the site image on the admin ingress, behind Access.
resource "cloudflare_dns_record" "r_runbook" {
  zone_id = var.zone_id
  name    = "runbook.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "operator runbook (Access-gated)"
}

resource "cloudflare_dns_record" "r_05e68032e2" {
  zone_id = var.zone_id
  name    = "homepage.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_97102a29a6" {
  zone_id = var.zone_id
  name    = "immich.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_83125968ae" {
  zone_id = var.zone_id
  name    = "jellyfin.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "tunnel"
}

resource "cloudflare_dns_record" "r_f5ed136bfc" {
  zone_id = var.zone_id
  name    = "karakeep.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_a02534d7cc" {
  zone_id = var.zone_id
  name    = "kavita.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_1d028c4586" {
  zone_id = var.zone_id
  name    = "lazylibrarian.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_7846bbe14a" {
  zone_id = var.zone_id
  name    = "longhorn.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}


resource "cloudflare_dns_record" "r_3524f68bf9" {
  zone_id = var.zone_id
  name    = "prometheus.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_cebf1a6b74" {
  zone_id = var.zone_id
  name    = "prowlarr.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_f539d140a1" {
  zone_id = var.zone_id
  name    = "qbittorrent.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_5ef58ab87e" {
  zone_id = var.zone_id
  name    = "radarr.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_376d30b873" {
  zone_id = var.zone_id
  name    = "sabnzbd.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_ebc88c73eb" {
  zone_id = var.zone_id
  name    = "sonarr.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

resource "cloudflare_dns_record" "r_5f7cc0628c" {
  zone_id = var.zone_id
  name    = "www.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}


resource "cloudflare_dns_record" "r_audiobookshelf" {
  zone_id = var.zone_id
  name    = "audiobookshelf.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "tunnel"
}

resource "cloudflare_dns_record" "r_argo" {
  zone_id = var.zone_id
  name    = "argo.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

# Live since its service went up, and absent from this file until 2026-11-17: the tunnel routed it, DNS answered for it, and
# nothing here described it. A record Terraform does not know is a record `plan` can never warn about.
resource "cloudflare_dns_record" "r_vault" {
  zone_id = var.zone_id
  name    = "vault.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = null
}

# Artifact Server's own hostname: the Control API, the browser UI and the OIDC callback all live here, on the single
# public ingress. It is deliberately NOT behind a `self_hosted` Access application - see the note in tunnel.tf - because
# the same hostname serves `/mcp` to Bearer-authenticated clients, and an SSO wall would answer them with a 302 they
# cannot follow. The browser path is authenticated by the Access *SaaS OIDC* app in access_apps.tf instead, which is a
# login provider, not a gate in front of the host.
resource "cloudflare_dns_record" "artifact_bismigel" {
  zone_id = var.zone_id
  name    = "artifact.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Artifact Server application origin"
}
