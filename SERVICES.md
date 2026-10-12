# Service Checklist

## Deployed Services

| Service | URL | Status | Notes |
|---------|-----|--------|-------|
| Homepage | http://192.168.2.81:30080 | ✅ | Dashboard |
| Prometheus | http://192.168.2.81:30909 | ✅ | Metrics (1GB retention) |
| Grafana | http://192.168.2.81:30300 | ✅ | user `admin` (password in local notes) |
| Jellyfin | http://192.168.2.81:30096 | ✅ | QSV transcoding; user `root`; lib `/media/tv` |
| qBittorrent | http://192.168.2.81:30081 | ✅ | user `admin`; save path `/downloads` |
| Prowlarr | http://192.168.2.81:30069 | ✅ | Indexer manager (syncs to Sonarr/Radarr) |
| Sonarr | http://192.168.2.81:30089 | ✅ | root `/tv` + qBittorrent client (cat `tv`) |
| Radarr | http://192.168.2.81:30078 | ✅ | root `/movies` + qBittorrent client (cat `movies`) |
| Bazarr | http://192.168.2.81:30067 | ✅ | subtitle management (auth: form) |
| OTel Collector | 10.43.2.34:4317 | ✅ | observability namespace |

## Cluster Info

- **Server**: calamansi (192.168.2.81)
- **k3s**: 1.34.5
- **NixOS**: 25.11
- **VPN**: WireGuard (ProtonVPN CH-CA#2)

## Storage

- **Root**: /dev/disk/by-uuid/3f6c1944-2b68-4426-bfcd-8888f6e4aa9c
- **Downloads**: /dev/disk/by-uuid/de9ae680-7261-4e86-8daa-54cf0c9d374b (238GB)

## Media stack

Deployments are **GitOps-managed**: the manifests live in `bakuran-gitops`
(`manifests/media/`, app set `applications-calamansi/`) and are reconciled by
ArgoCD on calamansi (.81). `.81` is media-only; the sites run on sitaw (.82).

The *arr apps keep their config in SQLite, so the wiring (root folders,
download clients, Prowlarr apps) is applied with an idempotent script rather
than declarative manifests:

```bash
QBT_PASSWORD='<qbt webui password>' ./scripts/media-stack-setup.sh
# from another host: HOST=192.168.2.81 KUBECTL="ssh root@192.168.2.81 k3s kubectl" ...
```

It derives the Sonarr/Radarr/Prowlarr API keys from the running pods, so no
secrets are committed. Re-running is safe.

- qBittorrent: default save path `/downloads`; categories `tv`, `movies`.
- Sonarr: root `/tv` + qBittorrent client (category `tv`).
- Radarr: root `/movies` + qBittorrent client (category `movies`).
- Prowlarr: links Sonarr + Radarr (`fullSync`); add indexers in Prowlarr and
  they sync to both apps automatically.

## TODO

- [ ] Set up SOPS for secrets management
- [x] Configure Jellyfin media library paths
- [x] Add arrstack (Prowlarr, Sonarr, Radarr, Bazarr)
- [x] Set up GitOps for the media stack (manifests in bakuran-gitops)
- [ ] Add Ingress controller
- [x] Connect arr apps to qBittorrent download client
- [ ] Add more indexers (most public trackers need FlareSolverr)
