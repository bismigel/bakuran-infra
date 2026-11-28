# The tunnel's routing table: every hostname the estate answers on, and which ingress controller serves it.
#
# The two targets are variables because they are the one part of this file that is not a name: the connectors run as host
# units on .81 and .82 (`cloudflared-tunnel-<id>.service`) and reach the ingress controllers by **ClusterIP**. The
# `127.0.0.1:3208x` NodePorts this file named until 2026-11-16 no longer listen anywhere - measured:
#
#   ss -ltn | grep -cE ':32080|:32081'                     -> 0      (on .82)
#   curl -H 'Host: status.bismigel.dev' http://10.43.46.55/  -> 200
#   curl -H 'Host: argocd.bismigel.dev' http://10.43.15.7/   -> 200
#
# A hostname route that points at a dead port still resolves and still gets an Access challenge, so this drifts silently
# until someone opens the page. Story: the edge has one owner (bakuran-infra#11's finding, terraform side).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.account_id
  tunnel_id  = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649"
  config = {
    ingress = [
      { hostname = "ciceley.cc", service = var.public_target },
      { hostname = "www.ciceley.cc", service = var.public_target },
      { hostname = "bismigel.dev", service = var.public_target },
      { hostname = "www.bismigel.dev", service = var.public_target },
      { hostname = "miguelarbis.dev", service = var.public_target },
      { hostname = "www.miguelarbis.dev", service = var.public_target },
      # Artifact Server, added 2026-11-25. Both hostnames point at the SAME target on purpose, and neither gets a
      # `self_hosted` Access application in front of it:
      #
      #   - the browser UI and the Control API authenticate through the Access *SaaS OIDC* app (`artifact_server` in
      #     access_apps.tf), where Cloudflare is the identity provider the application redirects to. That is a login
      #     flow the app initiates, so it works whether or not Cloudflare also gates the hostname;
      #   - `/mcp` authenticates machine clients with a Bearer API key. A `self_hosted` wall on this hostname would
      #     answer an unauthenticated request with a 302 to the SSO login and the key would never be seen - the same
      #     constraint that keeps the vault public (waf_custom.tf) and the forgejo registry on a bypass policy.
      #
      # `*.miguelarbis.dev` is the isolated content origin: the same tunnel and the same public ingress, a different
      # registrable domain from the panel, which is what makes the two-origin split a security boundary rather than a
      # naming convention. It sits HERE - after `miguelarbis.dev` and `www.miguelarbis.dev` - because cloudflared takes
      # the first matching rule and a wildcard placed earlier would swallow those two exact hostnames.
      { hostname = "artifact.bismigel.dev", service = var.public_target },
      { hostname = "*.miguelarbis.dev", service = var.public_target },
      { hostname = "status.bismigel.dev", service = var.public_target },
      { hostname = "jellyfin.bismigel.dev", service = var.public_target },
      { hostname = "immich.bismigel.dev", service = var.public_target },
      { hostname = "git.bismigel.dev", service = var.public_target },
      { hostname = "kavita.bismigel.dev", service = var.public_target },
      { hostname = "audiobookshelf.bismigel.dev", service = var.public_target },
      { hostname = "karakeep.bismigel.dev", service = var.public_target },
      { hostname = "grafana.bismigel.dev", service = var.admin_target },
      { hostname = "agent.bismigel.dev", service = var.admin_target },
      { hostname = "sonarr.bismigel.dev", service = var.admin_target },
      { hostname = "radarr.bismigel.dev", service = var.admin_target },
      { hostname = "prowlarr.bismigel.dev", service = var.admin_target },
      { hostname = "bazarr.bismigel.dev", service = var.admin_target },
      { hostname = "qbittorrent.bismigel.dev", service = var.admin_target },
      { hostname = "sabnzbd.bismigel.dev", service = var.admin_target },
      { hostname = "homepage.bismigel.dev", service = var.admin_target },
      { hostname = "prometheus.bismigel.dev", service = var.admin_target },
      { hostname = "argocd.bismigel.dev", service = var.admin_target },
      { hostname = "longhorn.bismigel.dev", service = var.admin_target },
      { hostname = "lazylibrarian.bismigel.dev", service = var.admin_target },
      { hostname = "argo.bismigel.dev", service = var.admin_target },
      # Live until 2026-11-16 without a declaration anywhere in this directory - found by diffing the tunnel's own
      # configuration against the file that was supposed to describe it.
      { hostname = "vault.bismigel.dev", service = var.public_target },
      { hostname = "tools.ciceley.cc", service = var.public_target },
      # EasyShortlist is PUBLIC: only its /admin path is gated (the Access application below), not the ingress.
      # Same target as the other public hosts; routing it to admin_target would put the whole site behind Access.
      { hostname = "easyshortlist.ciceley.cc", service = var.public_target },
      # Jiffley Shortlist from 2026-11-28: the product domain for the same app, public for the same reason - the
      # Access application gates `/admin`, not the hostname. The old host stays routed until its 301 lands.
      { hostname = "shortlist.jiffley.com", service = var.public_target },
      { hostname = "runbook.bismigel.dev", service = var.admin_target },
      { service = "http_status:404" },
    ]
  }
}
