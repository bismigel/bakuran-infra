# jiffley.com: the Jiffley Labs company site, on Cloudflare Pages (decided 2026-11-28).
#
# Why Pages and not the cluster: the public face of a company that sells self-hostable software should not inherit the
# homelab's single power/ISP/ThinkCentre failure modes. Pages is declarable here (so the edge keeps one owner, ADR 0019),
# it costs nothing, and TLS/DNS are already Cloudflare's. Publishing is DIRECT UPLOAD from Forgejo CI (`wrangler pages
# deploy`) rather than Pages' Git integration, because Forgejo is the origin and GitHub is only a mirror: a Git integration
# would make the mirror the publisher, and publishing from a mirror is the wrong direction of trust.
#
# The owner's decisions of 2026-11-28 that shape this file:
#   - the previously approved 301 of jiffley.com/www -> shortlist.jiffley.com is CANCELLED. The apex serves this site.
#   - www.jiffley.com 301s to the apex (one canonical hostname), which is what the redirect rule below does.
#   - no analytics, no cookies, no Web Analytics beacon - a claim the site copy can safely make.
resource "cloudflare_pages_project" "jiffley_site" {
  account_id        = var.account_id
  name              = "jiffley-site"
  production_branch = "main"
  # No `source` block: direct upload, no Git integration on purpose (see the comment above).
}

# Both hostnames belong to the same Pages project. The apex is a CNAME to the project's pages.dev hostname, which
# Cloudflare flattens; that is the supported way to serve an apex on Pages.
resource "cloudflare_pages_domain" "jiffley_apex" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.jiffley_site.name
  name         = "jiffley.com"
}

resource "cloudflare_pages_domain" "jiffley_www" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.jiffley_site.name
  name         = "www.jiffley.com"
}

resource "cloudflare_dns_record" "jiffley_apex" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "jiffley.com"
  type    = "CNAME"
  content = cloudflare_pages_project.jiffley_site.subdomain
  proxied = true
  ttl     = 1
  comment = "Jiffley Labs site (Cloudflare Pages, direct upload from Forgejo CI)"
}

resource "cloudflare_dns_record" "jiffley_www" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "www.jiffley.com"
  type    = "CNAME"
  content = "jiffley.com"
  proxied = true
  ttl     = 1
  comment = "www -> apex; the redirect rule below makes it canonical"
}

# One canonical hostname: www 301s to the apex. This is the first dynamic-redirect ruleset in this module (the WAF ruleset
# in waf_custom.tf is a different phase), so it is deliberately the only rule on it.
#
# OPEN, measured 2026-11-28 13:35Z: the ruleset and its one rule exist (entrypoint returns it, rule enabled, expression
# matches `http.host eq "www.jiffley.com"`), but a request to www still gets a 200 from Pages instead of a 301. Tested with
# both a dynamic (`concat(...)`) and a static target_url, so the target is not the cause. The likely reason is ordering: a
# Pages custom domain is served by a Worker on that hostname, and the worker answers before the dynamic-redirect phase is
# consulted. Until that is resolved, www serves duplicate content of the apex - it is NOT canonical, and the site copy must
# not link it. Candidate fixes, each its own change: (a) drop the www Pages custom domain and answer www from a Worker that
# 301s to the apex, (b) keep the domain and move the redirect into Pages' own `_worker.js`, (c) check with Cloudflare
# support whether a zone-level dynamic redirect is expected to win over a Pages custom domain.
resource "cloudflare_ruleset" "jiffley_www_redirect" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "jiffley.com canonical hostname"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [{
    action      = "redirect"
    description = "www.jiffley.com -> jiffley.com (301, keep path and query)"
    enabled     = true
    expression  = "(http.host eq \"www.jiffley.com\")"
    action_parameters = {
      from_value = {
        status_code           = 301
        preserve_query_string = true
        target_url            = { expression = "concat(\"https://jiffley.com\", http.request.uri.path)" }
      }
    }
  }]
}
