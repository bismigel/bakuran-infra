# bakuran-infra

**NixOS machine configuration** for the Bakuran homelab. This repo defines the
*machines*; what runs on top of them (k3s workloads) lives in
[`bakuran-gitops`](../bakuran-gitops) and is reconciled by ArgoCD.

## Hosts

| Host | Addr | Hardware | Role |
| --- | --- | --- | --- |
| `sitaw-amd` | 192.168.2.82 | Ryzen 5 4600G | Hosting + platform: k3s, the single ArgoCD control plane, ingress-nginx (NodePort 32080/32443), cloudflared |
| `calamansi-intel` | 192.168.2.81 | Intel i5-7500T | Media only: Jellyfin (QSV), *arr stack, qBittorrent (registered as an external cluster in the one ArgoCD) |

Both run NixOS 25.11 with single-node k3s (traefik + servicelb disabled).

## Layout

```
flake.nix                    # inputs (nixpkgs, disko, deploy-rs, sops-nix) + hosts + deploy.nodes
hosts/<host>/default.nix     # per-host config (imports modules/, inlines hardware)
hosts/<host>/disko.nix       # disk layout (only where disko is used)
modules/
  base.nix                   # shared: SSH, users, packages, sops-nix, backup tooling
  k3s.nix                    # k3s server config (⚠ contains a WireGuard key — see below)
  backup.nix                 # daily R2 credential backup (systemd timer)
scripts/
  bootstrap-argocd.sh        # one-time ArgoCD bootstrap + repo/cluster secrets
  media-stack-setup.sh       # idempotent *arr ↔ qBittorrent wiring
  backup-credentials.sh      # host keys + kubeconfigs + BWS token → R2 (age-encrypted)
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
```

Validate before deploying:

```bash
nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
```

Install a **brand-new** host (wipes the target): add `hosts/<name>/default.nix`
(+ `disko.nix`), `git add` it, then
`nix run github:nix-community/nixos-anywhere -- --flake .#<name> --target-host root@<ip>`.

## Secrets

- **Host secrets** (cloudflared credentials, age identity) are **SOPS/age**
  (`sops-nix`); the age identity is the host's SSH key.
- **Cluster secrets** (GHCR pull, tokens) live in **Bitwarden Secrets Manager** and
  are synced by External Secrets Operator — see `bakuran-gitops`.
- Never commit plaintext secrets.

## Backups

A daily systemd timer (`modules/backup.nix`) pushes age-encrypted host keys,
kubeconfigs, and the Bitwarden access token to `r2:homelab-backups/credentials/`.

## Known issues

- `modules/k3s.nix` still contains a **plaintext WireGuard key**. A replacement is
  held in **Bitwarden** (to be rotated there); move it into `secrets/homelab.yaml`
  (SOPS) and read from `/run/secrets/…` instead. See `homelab-context/NEXT-STEPS.md`.

## Related

- `bakuran-gitops` — cluster desired state (ArgoCD).
- `homelab-app-template` — scaffold for a new app.
- `docs/REBUILD.md` — rebuild from scratch. `SERVICES.md` — service inventory.
