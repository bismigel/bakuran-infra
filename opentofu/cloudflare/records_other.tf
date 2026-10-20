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
