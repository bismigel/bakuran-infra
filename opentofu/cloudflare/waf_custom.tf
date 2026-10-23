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
