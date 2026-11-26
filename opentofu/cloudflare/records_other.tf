# Ciceley and Miguel zones point at the same Cloudflare Tunnel.

resource "cloudflare_dns_record" "ciceley_apex" {
  zone_id = var.ciceley_zone_id
  name    = "ciceley.cc"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Personal site"
}

resource "cloudflare_dns_record" "ciceley_www" {
  zone_id = var.ciceley_zone_id
  name    = "www.ciceley.cc"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "miguel_apex" {
  zone_id = var.miguel_zone_id
  name    = "miguelarbis.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "miguel_www" {
  zone_id = var.miguel_zone_id
  name    = "www.miguelarbis.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "miguel_webhook" {
  zone_id = var.miguel_zone_id
  name    = "webhook.miguelarbis.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "ciceley_easyshortlist" {
  zone_id = var.ciceley_zone_id
  name    = "easyshortlist.ciceley.cc"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "EasyShortlist (CV screening)"
}

# Mail for miguelarbis.dev: Proton custom domain. Interim sender for EasyShortlist (noreply@miguelarbis.dev) until it
# has a brand domain. Values from Proton's domain wizard; never proxied. Keep the verification TXT: Proton re-checks it.
resource "cloudflare_dns_record" "miguel_proton_verify" {
  zone_id = var.miguel_zone_id
  name    = "miguelarbis.dev"
  type    = "TXT"
  content = "\"protonmail-verification=1d9d4794e209cf1a1295f36c96474bc5dbb32e04\""
  ttl     = 1
  comment = "Proton domain ownership"
}

resource "cloudflare_dns_record" "miguel_mx1" {
  zone_id  = var.miguel_zone_id
  name     = "miguelarbis.dev"
  type     = "MX"
  content  = "mail.protonmail.ch"
  priority = 10
  ttl      = 1
}

resource "cloudflare_dns_record" "miguel_mx2" {
  zone_id  = var.miguel_zone_id
  name     = "miguelarbis.dev"
  type     = "MX"
  content  = "mailsec.protonmail.ch"
  priority = 20
  ttl      = 1
}

resource "cloudflare_dns_record" "miguel_spf" {
  zone_id = var.miguel_zone_id
  name    = "miguelarbis.dev"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.protonmail.ch ~all\""
  ttl     = 1
}

resource "cloudflare_dns_record" "miguel_dmarc" {
  zone_id = var.miguel_zone_id
  name    = "_dmarc.miguelarbis.dev"
  type    = "TXT"
  content = "\"v=DMARC1; p=quarantine\""
  ttl     = 1
}

# DKIM: Proton rotates these keys behind the CNAMEs (targets are per-account, from the wizard's DKIM tab).
resource "cloudflare_dns_record" "miguel_dkim1" {
  zone_id = var.miguel_zone_id
  name    = "protonmail._domainkey.miguelarbis.dev"
  type    = "CNAME"
  content = "protonmail.domainkey.dcjwlbcpko67stqlo7ennbwxp43h3ound47p67yw2bmifvy4vdqbq.domains.proton.ch"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "miguel_dkim2" {
  zone_id = var.miguel_zone_id
  name    = "protonmail2._domainkey.miguelarbis.dev"
  type    = "CNAME"
  content = "protonmail2.domainkey.dcjwlbcpko67stqlo7ennbwxp43h3ound47p67yw2bmifvy4vdqbq.domains.proton.ch"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "miguel_dkim3" {
  zone_id = var.miguel_zone_id
  name    = "protonmail3._domainkey.miguelarbis.dev"
  type    = "CNAME"
  content = "protonmail3.domainkey.dcjwlbcpko67stqlo7ennbwxp43h3ound47p67yw2bmifvy4vdqbq.domains.proton.ch"
  proxied = false
  ttl     = 1
}

# Isolated content origin for Artifact Server. Published artifacts are served from a hostname under `*.miguelarbis.dev`
# while the application itself lives on `artifact.bismigel.dev`; the two-origin split is the security boundary - content
# fetched from an artifact URL never shares an origin, cookie jar or Access session with the panel that uploaded it, so a
# hostile artifact cannot reach the API with the operator's browser session.
#
# A wildcard CNAME is what makes that boundary cheap: any subdomain of miguelarbis.dev resolves to the same tunnel and
# the same public ingress, and Artifact Server answers for whichever host the request arrived on. Cloudflare matches the
# most specific record first, so the three exact records above (`miguel_apex`, `miguel_www`, `miguel_webhook`) keep
# answering for their own hostnames; this one only covers names nothing else claims.
resource "cloudflare_dns_record" "miguel_wildcard" {
  zone_id = var.miguel_zone_id
  name    = "*.miguelarbis.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Artifact Server isolated content origin (two-origin security boundary)"
}
