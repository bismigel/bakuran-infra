# bakuran-infra

**NixOS machine configuration** for the Bakuran homelab. This repo defines the
*machines*; what runs on top of them (k3s workloads) lives in
[`bakuran-gitops`](../bakuran-gitops) and is reconciled by ArgoCD.

## Hosts

| Host | Addr | Hardware | Role |
| --- | --- | --- | --- |
| `sitaw-amd` | 192.168.2.82 | Ryzen 5 4600G | Platform: k3s server + **the single ArgoCD**, ingress-nginx, cloudflared connector #1, the daily Cloudflare-edge reconcile timer |
| `calamansi-intel` | 192.168.2.81 | Intel i5-7500T | Media worker: Jellyfin (QSV), *arr stack, download clients, cloudflared connector #2; ProtonVPN + **kill switch** |
| `kamatis-mbp` | 192.168.2.83 | Intel i5 (MacBook Pro 13" 2012) | 3rd k3s **server (etcd quorum)**, tainted; runs **Immich** (storage on `/mnt/data`) |

All run NixOS 25.11 and form **one 3-node k3s cluster** (embedded etcd, 3 members;
traefik + servicelb disabled). `kamatis-mbp` is `NoSchedule`-tainted except the
`immich` app, which tolerates it.

## Layout

```
flake.nix                    # inputs (nixpkgs, disko, deploy-rs, sops-nix) + hosts + deploy.nodes
hosts/<host>/default.nix     # per-host config (imports modules/, inlines hardware)
hosts/<host>/disko.nix       # disk layout (only where disko is used)
modules/
  base.nix                   # shared: SSH (key-only), users, packages, sops-nix, backup tooling
  k3s.nix                    # k3s server config (ProtonVPN key + VPN kill switch on .81)
  backup.nix                 # daily R2 credential backup (systemd timer)
  backup-apps.nix            # daily R2 app-data backup (config PVCs, via kubectl exec)
  cloudflare-sync.nix        # daily Cloudflare edge reconcile (tunnel/DNS/Access) on .82
scripts/
  bootstrap-argocd.sh        # one-time ArgoCD bootstrap + repo/cluster secrets
  media-stack-setup.sh       # idempotent *arr ↔ qBittorrent wiring + Jellyfin settings
  immich-setup.sh            # Immich admin + household accounts (from Bitwarden)
  backup-credentials.sh      # host keys + kubeconfigs + BWS token → R2 (age-encrypted)
cloudflare/sync.sh           # declared Cloudflare edge (hostnames, DNS, Access apps)
secrets/homelab.yaml         # SOPS/age-encrypted host secrets
docs/REBUILD.md              # disaster recovery
docs/HOMELAB-MIGRATION.md    # historical: Proxmox → NixOS migration plan
SERVICES.md                  # what's deployed + where
deploy.sh                    # legacy: sync + nixos-rebuild over ssh (prefer deploy-rs)
```

## Deploy a host

```bash
nix run github:serokell/deploy-rs -- .#sitaw-amd
nix run github:serokell/deploy-rs -- .#calamansi-intel
nix run github:serokell/deploy-rs -- .#kamatis-mbp
```

Validate before deploying:

```bash
nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
```

Install a **brand-new** host (wipes the target): add `hosts/<name>/default.nix`
(+ `disko.nix`), `git add` it, then
`nix run github:nix-community/nixos-anywhere -- --flake .#<name> --target-host root@<ip>`.

## Secrets

- **Host secrets** (cloudflared credentials, ProtonVPN key, Cloudflare API token,
  age identity) are **SOPS/age** (`sops-nix`); the age identity is the host's SSH key.
- **Cluster secrets** (GHCR pull, tokens) live in **Bitwarden Secrets Manager** and
  are synced by External Secrets Operator — see `bakuran-gitops`.
- Never commit plaintext secrets.

## Backups

Daily systemd timers push age-encrypted data to R2:
- `modules/backup.nix` → `r2:homelab-backups/credentials/` (host keys, kubeconfigs, BWS token).
- `modules/backup-apps.nix` → `r2:homelab-backups/appdata/` (config PVCs:
  *arrs/Jellyfin/Grafana/Prometheus/homelab agent).
- **Immich is NOT backed up** (DB + photo library) — known gap.

## Known issues

- **Immich is not backed up** (Postgres DB + photo library) — see
  `homelab-context/NEXT-STEPS.md`.
- **Cloudflare:** `min_tls_version` is still 1.0 and Bot Fight Mode is off (the API
  token lacks those scopes) — set these in the dashboard.
- The live inventory/roadmap lives in `homelab-context/` (local-only);
  `SERVICES.md` here is a summary and may lag.

## Related

- `bakuran-gitops` — cluster desired state (ArgoCD).
- `homelab-app-template` — scaffold for a new app.
- `docs/REBUILD.md` — rebuild from scratch. `SERVICES.md` — service inventory.
