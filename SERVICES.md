# Service Checklist

## Deployed Services

| Service | URL | Node | Notes |
|---------|-----|------|-------|
| ArgoCD | https://argocd.bismigel.dev | AMD | GitOps · Access (24h) |
| Grafana | https://grafana.bismigel.dev | AMD | `homelab-overview` + `homelab-power` · Access (24h) |
| Prometheus | https://prometheus.bismigel.dev | AMD | metrics · Access (730h) |
| Alertmanager | (loopback `30903`) | AMD | Telegram alerts |
| Longhorn | https://longhorn.bismigel.dev | AMD | storage · Access (24h) |
| Homepage | https://homepage.bismigel.dev | AMD | dashboard · Access |
| homelab agent | https://agent.bismigel.dev | AMD | agent (DeepSeek 64k) · Access + Telegram |
| Jellyfin | https://jellyfin.bismigel.dev · LAN `:8096` | Intel | 12.2.0 QSV; remote capped 12 Mbps · **public** (own auth) |
| Immich | https://immich.bismigel.dev | MacBook | photos; ML on AMD · **public** (own auth) |
| Sonarr | LAN `:8989` / sonarr.bismigel.dev | Intel | root `/tv` |
| Radarr | LAN `:7878` / radarr.bismigel.dev | Intel | root `/movies` |
| Prowlarr | LAN `:9696` / prowlarr.bismigel.dev | Intel | indexers |
| Bazarr | LAN `:6767` / bazarr.bismigel.dev | Intel | subtitles |
| qBittorrent | LAN `:8081` / qbittorrent.bismigel.dev | Intel | download client |
| SABnzbd | LAN `:8082` / sabnzbd.bismigel.dev | Intel | Usenet |
| media-mcp | (loopback `30097`) | Intel | MCP for homelab agent (incl. add movie/series) |
| Kavita | https://kavita.bismigel.dev | Intel | books (EPUB/PDF) · **public** (own auth) |
| LazyLibrarian | https://lazylibrarian.bismigel.dev | Intel | book manager, searches via Prowlarr · Access (24h) |
| Audiobookshelf | https://audiobookshelf.bismigel.dev | Intel | audiobooks + podcasts, library `/mnt/media/audiobooks` · **public** (own auth) |
| Kepler | (metrics `:9102`) | all | power/RAPL |

**Auth:** Grafana has a real admin password (Bitwarden). **Jellyfin and Immich are
public** and use their own logins (no Access — native apps can't do the email OTP).
The *arrs are login-free on the LAN (hostPorts) and behind Cloudflare Access when
remote. Admin apps behind Access use a **24h** session; media **730h**.

## Cluster placement

- **Intel `calamansi-intel` (192.168.2.81)** — media: Jellyfin, arr
  (Sonarr/Radarr/Prowlarr/Bazarr), download clients, media-mcp, kepler, node-exporter;
  host services: cloudflared, ProtonVPN + kill switch.
- **AMD `sitaw-amd` (192.168.2.82)** — the single ArgoCD control plane +
  sites/APIs, homepage, monitoring (prometheus/grafana/alertmanager/ksm/kepler,
  login watchers), observability, cert-manager, external-secrets, ingress-nginx,
  duwende, and the daily Cloudflare-edge reconcile timer.
- **MacBook `kamatis-mbp` (192.168.2.83)** — 3rd k3s server (etcd), tainted except
  **Immich** (server/postgres/valkey on `/mnt/data`; ML runs on `.82`).

## Secrets & exposure

- **Cluster secrets:** Bitwarden Secrets Manager + External Secrets Operator
  (`ClusterSecretStore/bitwarden`). **Host secrets:** SOPS/age (`sops-nix`).
- **Ingress:** `ingress-nginx` (NodePort 32080/32443 on **both** boxes) reached by a
  **Cloudflare Tunnel** with a connector on each host (edge HA). Public hostnames live under `*.bismigel.dev`;
  `grafana`/`jellyfin`/`status`/`private`/`agent` are gated by **Cloudflare Access**
  (Zero Trust).

## Cluster Info

- **Servers** (one cluster, 3-member etcd): calamansi-intel (192.168.2.81, Intel) ·
  sitaw-amd (192.168.2.82, AMD) · kamatis-mbp (192.168.2.83, MacBook)
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
- [x] WireGuard key -> SOPS (done)
- [ ] Back up Immich (DB + photo library) to R2
- [ ] Set Cloudflare min TLS 1.2 + Bot Fight Mode (dashboard; API token lacks scope)
