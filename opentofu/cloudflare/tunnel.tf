resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.account_id
  tunnel_id  = "8dcc83bd-eb95-4c0d-8f71-b92a27d37649"
  config = {
    ingress = [
      { hostname = "ciceley.cc", service = "http://127.0.0.1:32080" },
      { hostname = "www.ciceley.cc", service = "http://127.0.0.1:32080" },
      { hostname = "bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "www.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "miguelarbis.dev", service = "http://127.0.0.1:32080" },
      { hostname = "www.miguelarbis.dev", service = "http://127.0.0.1:32080" },
      { hostname = "status.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "jellyfin.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "immich.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "kavita.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "audiobookshelf.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "karakeep.bismigel.dev", service = "http://127.0.0.1:32080" },
      { hostname = "private.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "grafana.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "agent.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "sonarr.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "radarr.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "prowlarr.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "bazarr.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "qbittorrent.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "sabnzbd.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "homepage.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "prometheus.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "argocd.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "longhorn.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "lazylibrarian.bismigel.dev", service = "http://127.0.0.1:32081" },
      { hostname = "runbook.bismigel.dev", service = "http://127.0.0.1:32081" },
      { service = "http_status:404" },
    ]
  }
}
