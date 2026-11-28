# jiffley.com, registered at Cloudflare Registrar on 2026-11-28 (RDAP: registration 2026-11-28T02:28:35Z, expiry
# 2027-11-28, nameservers yadiel/zariyah.ns.cloudflare.com, zone active). The product domain for Jiffley Shortlist,
# which is EasyShortlist under its own name.
#
# The zone is looked up by NAME rather than pinned as a `var.*_zone_id` like the other three: the name is the fact an
# operator knows, the id is the provider's business, and a data source has no second place to drift. The lookup also
# fails the plan loudly if the zone is ever removed or renamed, which a stale literal in variables.tf would not.
data "cloudflare_zone" "jiffley" {
  filter = {
    name = "jiffley.com"
  }
}

# Same tunnel as every other public host. The Ingress controller decides what serves it: until the application's
# Ingress host patch lands, this answers the ingress default (404) - expected, not a failure.
resource "cloudflare_dns_record" "jiffley_shortlist" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "shortlist.jiffley.com"
  type    = "CNAME"
  content = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Jiffley Shortlist (EasyShortlist), public site; /admin gated by Access"
}
