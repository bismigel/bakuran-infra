# Email for the estate, because SECURITY.md now publishes an address and an address that bounces is worse than none.
#
# Why here and not in cloudflare/sync.sh (deleted 2026-11-17): the edge has one owner - this directory - and a routing rule created
# by a script would be the second declaration that ADR 0019 and the OpenTofu migration exist to prevent.

# Turn routing on for the zone. Enabling this creates the MX, SPF and DKIM records Cloudflare needs; they are managed by the zone
# (and appear in the DNS API) rather than by `cloudflare_dns_record` resources here, so they are deliberately not re-declared.
resource "cloudflare_email_routing_settings" "bismigel" {
  zone_id = var.zone_id
}

# Where mail actually lands. Cloudflare sends a verification message to this mailbox; until somebody clicks it, `verified` is false and
# every rule that forwards to it silently fails. Nothing here can click it.
resource "cloudflare_email_routing_address" "security" {
  account_id = var.account_id
  email      = var.security_mailbox
}

# security@bismigel.dev is published in SECURITY.md in three repositories. One literal matcher, one forward - deliberately not a
# catch-all: an estate with one operator does not want every typo'd address arriving in a personal inbox.
#
# BLOCKED 2026-11-18: the token in `secrets/homelab.yaml` (read it per README.md; the host copy went away on 2026-11-19) can enable routing and create a destination address, but every
# call to `/zones/<id>/email/routing/rules` returns `Authentication error` (10000). That is a token *permission*, not a rule problem -
# Email Routing rules are their own scope. So this resource is declared and cannot be applied until the token is reissued with it, or
# the rule is created once in the dashboard and imported. Plan currently reports `1 to add` for exactly this resource.
#
# Until then `security@bismigel.dev` does NOT deliver: the destination address is also **unverified**, which needs a click in that
# mailbox. Both gaps are in story 15.10.
resource "cloudflare_email_routing_rule" "security" {
  zone_id = var.zone_id
  name    = "security@bismigel.dev"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = "security@bismigel.dev"
  }]

  actions = [{
    type  = "forward"
    value = [cloudflare_email_routing_address.security.email]
  }]
}
