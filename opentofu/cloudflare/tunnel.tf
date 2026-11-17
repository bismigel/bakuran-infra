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
      { hostname = "status.bismigel.dev", service = var.public_target },
      { hostname = "jellyfin.bismigel.dev", service = var.public_target },
      { hostname = "immich.bismigel.dev", service = var.public_target },
      { hostname = "git.bismigel.dev", service = var.public_target },
      { hostname = "kavita.bismigel.dev", service = var.public_target },
      { hostname = "audiobookshelf.bismigel.dev", service = var.public_target },
      { hostname = "karakeep.bismigel.dev", service = var.public_target },
      { hostname = "private.bismigel.dev", service = var.admin_target },
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
      { hostname = "runbook.bismigel.dev", service = var.admin_target },
      { service = "http_status:404" },
    ]
  }
}
