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

resource "cloudflare_dns_record" "r_1ea06ef71d" {
  zone_id = var.zone_id
  name    = "private.bismigel.dev"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "tunnel"
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
