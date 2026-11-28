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

# Mail for jiffley.com: Proton custom domain (added to Proton 2026-11-28; the plan allows 3 domains, miguelarbis.dev is
# the other one). Values from Proton's domain wizard, mirroring the miguelarbis.dev block because it is the same Proton
# account and therefore the same MX/SPF/DMARC targets. Never proxied. The verification TXT stays: Proton re-checks it.
#
# DKIM is account-scoped in Proton (the CNAME targets carry the account key, not the domain), and its tab unlocks only
# after verification, so those three records are added in a follow-up commit once the wizard shows them.
resource "cloudflare_dns_record" "jiffley_proton_verify" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "jiffley.com"
  type    = "TXT"
  content = "\"protonmail-verification=80abe4ac3378fd39ec776127e9666ec957a45c4a\""
  ttl     = 1
  comment = "Proton domain ownership (re-checked: do not remove)"
}

resource "cloudflare_dns_record" "jiffley_mx1" {
  zone_id  = data.cloudflare_zone.jiffley.zone_id
  name     = "jiffley.com"
  type     = "MX"
  content  = "mail.protonmail.ch"
  priority = 10
  ttl      = 1
}

resource "cloudflare_dns_record" "jiffley_mx2" {
  zone_id  = data.cloudflare_zone.jiffley.zone_id
  name     = "jiffley.com"
  type     = "MX"
  content  = "mailsec.protonmail.ch"
  priority = 20
  ttl      = 1
}

resource "cloudflare_dns_record" "jiffley_spf" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "jiffley.com"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.protonmail.ch ~all\""
  ttl     = 1
}

resource "cloudflare_dns_record" "jiffley_dmarc" {
  zone_id = data.cloudflare_zone.jiffley.zone_id
  name    = "_dmarc.jiffley.com"
  type    = "TXT"
  content = "\"v=DMARC1; p=quarantine\""
  ttl     = 1
}

# DKIM for jiffley.com is NOT declared yet, deliberately. Proton's DKIM targets are per-domain (see mail_bismigel.tf),
# and the DKIM tab is still locked because Proton has not activated jiffley.com, so the three target values cannot be read.
# What was here first used miguelarbis.dev's targets on the wrong assumption that they were account-scoped; publishing
# CNAMEs that point at another domain's keys is worse than declaring nothing, because receiving servers would fail every
# signature. Add the three records from Proton's DKIM tab when the domain activates.
