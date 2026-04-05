# Service Checklist

## Deployed Services

| Service | URL | Status | Notes |
|---------|-----|--------|-------|
| Homepage | http://192.168.2.81:30080 | ✅ | Dashboard |
| Prometheus | http://192.168.2.81:30909 | ✅ | Metrics (1GB retention) |
| Grafana | http://192.168.2.81:30300 | ✅ | admin/admin |
| Jellyfin | http://192.168.2.81:30096 | ✅ | QSV transcoding |
| qBittorrent | http://192.168.2.81:30081 | ✅ | admin/jRIJqfxHS |
| OTel Collector | 10.43.2.34:4317 | ✅ | observability namespace |

## Cluster Info

- **Server**: calamansi (192.168.2.81)
- **k3s**: 1.34.5
- **NixOS**: 25.11
- **VPN**: WireGuard (ProtonVPN CH-CA#2)

## Storage

- **Root**: /dev/disk/by-uuid/3f6c1944-2b68-4426-bfcd-8888f6e4aa9c
- **Downloads**: /dev/disk/by-uuid/de9ae680-7261-4e86-8daa-54cf0c9d374b (238GB)

## TODO

- [ ] Set up SOPS for secrets management
- [ ] Configure proper Jellyfin media library
- [ ] Add arrstack (Sonarr, Radarr, Prowlarr)
- [ ] Set up GitOps (ArgoCD/Flux)
- [ ] Add Ingress controller
