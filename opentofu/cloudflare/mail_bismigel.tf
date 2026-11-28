# Mail for bismigel.dev is moving from Cloudflare Email Routing to Proton, because the estate now needs real mailboxes
# on its own domain (`work@bismigel.dev`) and Cloudflare Email Routing only forwards to an existing inbox.
#
# This is a deliberate reversal of the 2026-11-18 Email Routing plan: `cloudflare_email_routing_settings.bismigel`,
# `cloudflare_email_routing_rule.security` and `cloudflare_email_routing_address.security` stop being the shape of this
# zone's mail. The rule never applied anyway (400 `code 2054 Destination address is not verified` - the token was not the
# obstacle), and the settings resource hit a provider bug. Proton needs its own MX, and Cloudflare refuses to coexist:
# while Email Routing is on, the zone's MX records belong to Cloudflare.
#
# Order matters and it is encoded here step by step:
#   1. this file: the ownership TXT (harmless while Email Routing is still on);
#   2. Proton verifies ownership, and the addresses `work@` and `security@` are created there, so the published
#      security address has somewhere to land before the switch;
#   3. a later commit turns Email Routing off and adds the Proton MX/SPF/DKIM/DMARC records in one apply - the only
#      window with no MX is the seconds between those two API calls.
resource "cloudflare_dns_record" "bismigel_proton_verify" {
  zone_id = var.zone_id
  name    = "bismigel.dev"
  type    = "TXT"
  content = "\"protonmail-verification=c66eb4404d21057e598821959186a835f2b7977f\""
  ttl     = 1
  comment = "Proton domain ownership (re-checked: do not remove)"
}

# DKIM for bismigel.dev, same account-scoped targets as the other two domains (see records_jiffley.tf). These CNAMEs are
# additive and harmless while Cloudflare Email Routing is still on - only MX and SPF conflict.

resource "cloudflare_dns_record" "bismigel_dkim1" {
  zone_id = var.zone_id
  name    = "protonmail._domainkey.bismigel.dev"
  type    = "CNAME"
  content = "protonmail.domainkey.dcjwlbcpko67stqlo7ennbwxp43h3ound47p67yw2bmifvy4vdqbq.domains.proton.ch"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "bismigel_dkim2" {
  zone_id = var.zone_id
  name    = "protonmail2._domainkey.bismigel.dev"
  type    = "CNAME"
  content = "protonmail2.domainkey.dcjwlbcpko67stqlo7ennbwxp43h3ound47p67yw2bmifvy4vdqbq.domains.proton.ch"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "bismigel_dkim3" {
  zone_id = var.zone_id
  name    = "protonmail3._domainkey.bismigel.dev"
  type    = "CNAME"
  content = "protonmail3.domainkey.dcjwlbcpko67stqlo7ennbwxp43h3ound47p67yw2bmifvy4vdqbq.domains.proton.ch"
  proxied = false
  ttl     = 1
}

# Step 3 of the switch, applied after Email Routing is off (see email_routing.tf). These are the records miguelarbis.dev and
# jiffley.com already run on, read off Proton's wizard rather than copied from memory.
resource "cloudflare_dns_record" "bismigel_mx1" {
  zone_id  = var.zone_id
  name     = "bismigel.dev"
  type     = "MX"
  content  = "mail.protonmail.ch"
  priority = 10
  ttl      = 1
}

resource "cloudflare_dns_record" "bismigel_mx2" {
  zone_id  = var.zone_id
  name     = "bismigel.dev"
  type     = "MX"
  content  = "mailsec.protonmail.ch"
  priority = 20
  ttl      = 1
}

# The SPF record: Cloudflare Email Routing creates its own (`include:_spf.mx.cloudflare.net`) and removing it is part of
# switching routing off. Two SPF records on one name is a permanent error, so this must be the only one.
resource "cloudflare_dns_record" "bismigel_spf" {
  zone_id = var.zone_id
  name    = "bismigel.dev"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.protonmail.ch ~all\""
  ttl     = 1
}

resource "cloudflare_dns_record" "bismigel_dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc.bismigel.dev"
  type    = "TXT"
  content = "\"v=DMARC1; p=quarantine\""
  ttl     = 1
}
