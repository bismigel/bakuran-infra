# Custom WAF rules for the zone. The Free plan allows a small number of these.
#
# This is a noise/attack-surface filter: block the common scanner probes
# (.env, .git, wp-login/wp-admin, xmlrpc.php, phpmyadmin, phpunit, .aws) before
# they reach the tunnel and origin. None of those paths exist on the real
# services (static site, Jellyfin, Immich, Kavita), so legitimate traffic is
# unaffected.
resource "cloudflare_ruleset" "custom_waf" {
  zone_id = var.zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [
    {
      action      = "block"
      description = "Block common scanner paths"
      enabled     = true
      expression  = "(http.request.uri.path contains \"/.env\") or (http.request.uri.path contains \"/.git/\") or (http.request.uri.path contains \"/wp-login\") or (http.request.uri.path contains \"/wp-admin\") or (http.request.uri.path contains \"/xmlrpc.php\") or (http.request.uri.path contains \"/phpmyadmin\") or (http.request.uri.path contains \"/vendor/phpunit\") or (http.request.uri.path contains \"/.aws/\")"
    },
  ]
}

# Rate limiting for the vault's login endpoints. The vault is public on purpose - Bitwarden clients cannot answer an SSO
# redirect, so an Access policy in front of the hostname would break the thing it protects (the same constraint as the
# five PWAs). What an Access policy would have given for free is throttling, so it is declared here instead: the
# compensating controls inside Vaultwarden are `SIGNUPS_ALLOWED: "false"` and an admin token, but neither slows down
# credential stuffing against the login endpoint.
#
# `http_ratelimit` is a separate phase from the custom WAF above and the Free plan allows one rule, so it covers only
# what matters: `/identity/connect/token` (login), the registration endpoint, and `/admin`. Five attempts per
# ten-second window per source address, and the plan's own mitigation window applies.
#
# What the Free plan allows is what it allows, and a plan that only survived on a paid tier would be a plan nobody
# applies: 5 requests / 10 s, mitigation 10 s. Slow credential stuffing still has to pay this on every window rather than
# run at scrape speed, which is the whole point of measuring this against the *real* entitlement rather than the docs.
resource "cloudflare_ruleset" "vault_ratelimit" {
  zone_id = var.zone_id
  # The zone already HAS a `default` ruleset for this phase - created by hand, empty, and it stayed empty because a
  # second ruleset for the same phase is not allowed (`'zone' is not a valid value for kind because exceeded maximum
  # number of zone rulesets for phase http_ratelimit`, measured by the plan's dry run). So this resource is IMPORTED
  # rather than created, and the rule below is added to the one that exists:
  #   tofu import cloudflare_ruleset.vault_ratelimit d7786ec1130918385079b8f224f271b5/265e475826b64f09a43210603edfa8b2
  name  = "default"
  kind  = "zone"
  phase = "http_ratelimit"

  rules = [
    {
      action      = "block"
      description = "Throttle the vault's login and registration endpoints"
      enabled     = true
      expression  = "(http.host eq \"vault.bismigel.dev\") and (http.request.uri.path contains \"/identity/connect/token\" or http.request.uri.path contains \"/identity/accounts/register\" or http.request.uri.path contains \"/admin\")"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        # The Free plan allows a 10-second window only (`not entitled to use the period 60, can only use a period among
        # [10]`, measured by the dry run). Five attempts in ten seconds is far above a human unlocking a password
        # manager - the login POST, a couple of retries - and far below a credential list being tried.
        period              = 10
        requests_per_period = 5
        # The Free plan also fixes the mitigation window: `not entitled to use a mitigation timeout different from 10`.
        mitigation_timeout  = 10
      }
    },
  ]
}
