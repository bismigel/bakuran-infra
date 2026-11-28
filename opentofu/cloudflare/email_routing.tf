# Cloudflare Email Routing for bismigel.dev — switched OFF on 2026-11-28. This file now holds only the decision.
#
# History, because the reversal matters more than the resource: this file turned Email Routing on so `security@bismigel.dev`
# (published in SECURITY.md in three repositories) had somewhere to land. It never delivered. The destination address was never
# verified — Cloudflare mails a confirmation and nothing in this repository can click it — so the forwarding rule kept failing
# with `400 code 2054 Destination address is not verified` long after the token permission was fixed.
#
# Meanwhile the estate needed real mailboxes on its own domain (`work@bismigel.dev`), which Email Routing cannot provide: it only
# forwards to an address somebody else already hosts. So bismigel.dev mail moves to Proton, like miguelarbis.dev and jiffley.com;
# `mail_bismigel.tf` owns the Proton MX/SPF/DKIM/DMARC records. The two cannot coexist — while routing is enabled the zone's MX
# belong to Cloudflare and any MX declared here is ignored.
#
# WHY THIS IS A ONE-OFF AND NOT A RESOURCE. The provider marks `email_routing_settings.enabled` read-only, so "off" cannot be
# declared the way "on" could; destroying the settings resource does not promise to disable routing either. The disable is
# therefore a single recorded API call, made once on 2026-11-28 with the `cloudflare-apply-token` from Bitwarden:
#
#   POST https://api.cloudflare.com/client/v4/zones/d7786ec1130918385079b8f224f271b5/email/routing/disable
#   -> 200, {"enabled": false, "status": "ready"}
#
# Effects measured immediately after: the zone's Cloudflare MX (route1/2/3.mx.cloudflare.net) and Cloudflare's SPF TXT
# (`include:_spf.mx.cloudflare.net`) both disappeared on their own, leaving the Proton records in `mail_bismigel.tf` as the only
# mail path. Re-enabling, if it is ever wanted, is the mirror call with `.../email/routing/dns` plus the settings resource back.
#
# `security@bismigel.dev` becomes a Proton address on the same domain, so the published address keeps working — it lands in a
# mailbox instead of a forward that never worked. That address is created once Proton marks the domain active; until then mail to
# @bismigel.dev has no MX, which is the only window this change opens (seconds, plus Proton's verification lag).
