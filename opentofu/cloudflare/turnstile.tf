# Turnstile for Jiffley Shortlist, added 2026-11-28 with the domain move.
#
# Why declared here rather than created in the dashboard: the token is host-bound - a widget issued for one hostname
# refuses verification on another - so it is part of the edge this repository owns (ADR 0019), not an app setting. The
# existing widget for `easyshortlist.ciceley.cc` was created by hand and is not declared anywhere; this one is.
#
# The secret is sensitive and therefore lives in OpenTofu state (the R2 bucket, `use_lockfile`), not in git. Read it
# once and put it where the app expects it:
#
#   tofu output -raw turnstile_jiffley_shortlist_secret
#
# into Bitwarden `easyshortlist-secrets` as `turnstile-secret` (the key the ExternalSecret already reads), and the
# site key (public, `tofu output -raw turnstile_jiffley_shortlist_sitekey`) into the app's `TURNSTILE_SITE_KEY`.
#
# `mode = "managed"` matches Cloudflare's default and the shape the app expects (a widget it renders itself). Change it
# only if the existing widget is `invisible`, in which case the app's markup is different too.
resource "cloudflare_turnstile_widget" "jiffley_shortlist" {
  account_id = var.account_id
  name       = "Jiffley Shortlist"
  domains    = ["shortlist.jiffley.com"]
  mode       = "managed"
}
