resource "cloudflare_dns_record" "status" {
  zone_id = var.zone_id
  name    = "status.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  comment = "tunnel"
  ttl     = 1
}
