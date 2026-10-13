# Service Checklist

## Deployed Services

| Service | URL | Status | Notes |
|---------|-----|--------|-------|
| Homepage | http://192.168.2.82:30080 | ✅ | AMD · dashboard |
| Prometheus | http://192.168.2.82:30909 | ✅ | AMD · metrics (1GB retention) |
| Grafana | https://grafana.bismigel.dev | ✅ | AMD · user `admin` · Access-gated |
| OTel Collector | 192.168.2.82 (observability) | ✅ | AMD |
| Jellyfin | https://jellyfin.bismigel.dev | ✅ | Intel · QSV (privileged); users anton/delfin/ciceley; lib `/media/tv` · Access-gated |
| qBittorrent | http://192.168.2.81:30081 | ✅ | Intel · user `admin`; save path `/downloads` |
| Prowlarr | http://192.168.2.81:30069 | ✅ | Intel · indexer manager (syncs to Sonarr/Radarr) |
| Sonarr | http://192.168.2.81:30089 | ✅ | Intel · root `/tv` + qBittorrent client (cat `tv`) |
| Radarr | http://192.168.2.81:30078 | ✅ | Intel · root `/movies` + qBittorrent client (cat `movies`) |
| Bazarr | http://192.168.2.81:30067 | ✅ | Intel · subtitle management |
| ZeroClaw | https://agent.bismigel.dev | ✅ | AMD · homelab agent (DeepSeek + local LLM) · Access-gated · Telegram |

**Auth:** Grafana ships `admin`/`admin` (behind Cloudflare Access). Jellyfin and
qBittorrent use the standard homelab password (qBittorrent's is set by
`media-stack-setup.sh`). The *arr apps (Sonarr/Radarr/Prowlarr/Bazarr) use `Forms`
auth **disabled for local addresses** — login-free on the LAN. Public hosts are
gated by **Cloudflare Access** (see below).

## Cluster placement

- **Intel `calamansi-intel` (192.168.2.81)** — media only: Jellyfin, arr
  (Sonarr/Radarr/Prowlarr/Bazarr), qBittorrent, node-exporter.
  ArgoCD apps: `applications/calamansi-intel/` → `manifests/media`, `manifests/node-exporter`.
- **AMD `sitaw-amd` (192.168.2.82)** — everything else **and the single ArgoCD
  control plane**: sites (ciceley, miguelarbis), APIs (private-api, status-api),
  homepage, monitoring (prometheus/grafana/ksm), observability (OTel collector +
  operator), cert-manager, external-secrets, ingress-nginx, zeroclaw.
  ArgoCD apps: `applications/sitaw/`.

## Secrets & exposure

- **Cluster secrets:** Bitwarden Secrets Manager + External Secrets Operator
  (`ClusterSecretStore/bitwarden`). **Host secrets:** SOPS/age (`sops-nix`).
- **Ingress:** `ingress-nginx` (NodePort 32080/32443 on **both** boxes) reached by a
  **Cloudflare Tunnel** with a connector on each host (edge HA). Public hostnames live under `*.bismigel.dev`;
  `grafana`/`jellyfin`/`status`/`private`/`agent` are gated by **Cloudflare Access**
  (Zero Trust).

## Cluster Info

- **Servers**: calamansi-intel (192.168.2.81, Intel) · sitaw-amd (192.168.2.82, AMD)
- **k3s**: 1.34.5
- **NixOS**: 25.11
- **VPN**: WireGuard (ProtonVPN, US-NJ endpoint) on calamansi-intel — key is a SOPS secret

## Storage

- **Root**: /dev/disk/by-uuid/3f6c1944-2b68-4426-bfcd-8888f6e4aa9c
- **Downloads**: /dev/disk/by-uuid/de9ae680-7261-4e86-8daa-54cf0c9d374b (238GB)

## Media stack

Deployments are **GitOps-managed**: the manifests live in `bakuran-gitops`
(`manifests/media/`, apps under `applications/calamansi-intel/`) and are reconciled
by ArgoCD on **sitaw-amd** (.82). `.81` is media-only; the sites run on `.82`.

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

- [x] Secrets management (Bitwarden + ESO; host SOPS/age)
- [x] Configure Jellyfin media library paths
- [x] Add arrstack (Prowlarr, Sonarr, Radarr, Bazarr)
- [x] Set up GitOps for the media stack (manifests in bakuran-gitops)
- [x] Split placement: media on Intel (.81), everything else on AMD (.82)
- [x] Add Ingress controller (ingress-nginx + Cloudflare Tunnel/Access)
- [x] Connect arr apps to qBittorrent download client
- [ ] Add more indexers (most public trackers need FlareSolverr)
- [ ] Move the WireGuard key in `modules/k3s.nix` into SOPS
