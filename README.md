# bakuran-infra — the hosts, and the way back

NixOS configuration and disaster recovery for a three-node homelab: three Intel machines running k3s, one OPNsense router, one
OpenWrt switch, and the encrypted exports that let all of it be rebuilt.

### Start here

| if you have | read |
|---|---|
| 2 minutes | `hosts/*/default.nix` — every host is one file, and nothing is configured by hand on a machine |
| 10 minutes | [`docs/legacy-scripts.md`](docs/legacy-scripts.md) — 33 scripts, classified: 29 tools, 2 deleted, and the rule each remaining shell file satisfies |
| an hour | [`docs/REBUILD.md`](docs/REBUILD.md) — the actual restore procedure, in order, including the one manual step |
| a question | `modules/` — one module per concern (wireguard, backups, monitoring), each with the incident that shaped it in a comment |

### What is deliberately *not* here

Router and switch state is **OpenTofu** (`opentofu/`), not shell: `config.xml` is off limits and a change that cannot be declared is
said out loud. Application state is not here either — that is a separate repository of Kubernetes desired state, reconciled by ArgoCD.
And the checks are Go, in `homelab-context`; this repository's own CI runs one of them.

> **This repository's origin is Forgejo** ([git.bismigel.dev](https://git.bismigel.dev)). GitHub receives a push mirror,
> so what you read here is current, but pull requests, CI and reviews happen there. Everything below describes the
> repository itself and is the same on both sides.


## Why "Bakuran"

Bakuran is Tagalog for the yard or enclosure behind a house, from *bakod*, a
fence. It is the space where things get built, repaired, and occasionally taken
apart to see how they work. This repo is part of that backyard lab: small,
personal, and safe to break on purpose.

## Which tool owns what

Five toolchains live here. The map exists because "change the router" should not require a search.

| what you want to change | where it lives | how it is applied |
|---|---|---|
| a host: packages, services, disks, kernel, mounts | `flake.nix` → `hosts/<host>/`, `modules/` | `deploy-rs` (`nix run github:serokell/deploy-rs -- .#<host>`) |
| the router: firewall rules, VLANs, DHCP, DNS overrides | `opentofu/opnsense/` | `tofu plan` then `tofu apply` (runbook 22) |
| the router's **unmodelled** half: IDS state, plugins, cron | `ansible/` | `./ansible/run.sh playbooks/<x>.yml --check` first |
| a rehearsal before touching production | `staging/` | QEMU guests on `br-staging`; `.#nixosConfigurations.staging-*` |
| how to rebuild a machine from scratch | `docs/` | read, then follow |

Two rules that decide arguments between them:

- **OpenTofu owns everything the provider can model**; Ansible owns what it cannot. The boundary is written in
  `opentofu/opnsense/README.md` and `ansible/README.md`, and neither is allowed to grow into the other's territory.
- **Nothing on the router is hand-edited.** `config.xml` is off limits; a change that cannot be declared is said out loud and
  recorded (`homelab-context/docs/reference/network-as-code.md` names which is which).

**NixOS machine configuration** for the Bakuran homelab. This repo defines the
*machines*; what runs on top of them (k3s workloads) lives in
[`bakuran-gitops`](../bakuran-gitops) and is reconciled by ArgoCD.

## Hosts

| Host | Addr | Hardware | Role |
| --- | --- | --- | --- |
| `sitaw-amd` | 192.168.2.82 | Ryzen 5 4600G | Platform: k3s server + **the single ArgoCD**, ingress-nginx, cloudflared connector #1, the daily Cloudflare-edge reconcile timer |
| `calamansi-intel` | 192.168.2.81 | Intel i5-7500T | Media worker: Jellyfin (QSV), *arr stack, download clients, cloudflared connector #2; ProtonVPN + **kill switch** |
| `patola-thinkcentre` | 192.168.2.80 | Intel i5-6500T, 16 GB | k3s **server**, third etcd member, schedulable; Immich Postgres + Redis |
| `kamatis-mbp` | 192.168.2.83 | Intel i5 (MacBook 13" 2012) | **Not a cluster node** since 2026-10-28: the staging host, QEMU guests on `br-staging` (10.10.50.0/24) for datapath rehearsals |

All four run NixOS 25.11. Three of them - `.80`, `.81`, `.82` - form **one 3-node k3s cluster**
(embedded etcd, 3 members, each `control-plane` and schedulable; traefik and servicelb disabled).
`kamatis-mbp` left the cluster on 2026-10-28 and is now the staging host: a deploy-rs target, not a
member, so what is rehearsed there cannot be depended on by the cluster.

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
scripts/
  bootstrap-argocd.sh        # one-time ArgoCD bootstrap + repo/cluster secrets
  media-stack-setup.sh       # idempotent *arr ↔ qBittorrent wiring + Jellyfin settings
  immich-setup.sh            # Immich admin + household accounts (from Bitwarden)
  backup-credentials.sh      # host keys + kubeconfigs + BWS token → R2 (age-encrypted)
opentofu/cloudflare/         # declared Cloudflare edge (DNS, tunnel, Access, R2) — tofu
secrets/homelab.yaml         # SOPS/age-encrypted host secrets
docs/REBUILD.md              # disaster recovery
docs/HOMELAB-MIGRATION.md    # historical: Proxmox → NixOS migration plan
SERVICES.md                  # what's deployed + where
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
  - **Immich is backed up** with a local database dump and file archive, plus an
    offsite copy in R2 `homelab-backups/immich-manual/`. The restore path was tested.

## Known issues

  - **Cloudflare:** `min_tls_version` is 1.2, HSTS is on, and Bot Fight Mode is on.
- The live inventory/roadmap lives in `homelab-context/` (local-only);
  `SERVICES.md` here is a summary and may lag.

## Related

- `bakuran-gitops` — cluster desired state (ArgoCD).
- `homelab-app-template` — scaffold for a new app.
- `docs/REBUILD.md` — rebuild from scratch. `SERVICES.md` — service inventory.
