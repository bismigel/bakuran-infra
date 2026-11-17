# bakuran-infra

NixOS configuration for the Bakuran homelab: three machines in one k3s cluster, plus the router, the switch and the disaster-recovery
exports that let all of it be rebuilt.

## Why "Bakuran"

Bakuran is Tagalog for the yard or enclosure behind a house, from *bakod*, a
fence. It is the space where things get built, repaired, and occasionally taken
apart to see how they work. This repo is part of that backyard lab: small,
personal, and safe to break on purpose.

## Which tool owns what

| what you want to change | where it lives | how it is applied |
|---|---|---|
| a host: packages, services, disks, mounts | `flake.nix` → `hosts/<host>/`, `modules/` | `nix run github:serokell/deploy-rs -- .#<host>` |
| the router: firewall, VLANs, DHCP, DNS | `opentofu/opnsense/` | `tofu plan`, then `tofu apply` |
| the router's unmodelled half: IDS, plugins, cron | `network/ansible/` | `./network/ansible/run.sh playbooks/<x>.yml --check` first |
| the Cloudflare edge: DNS, tunnel, Access | `opentofu/cloudflare/` | `terraform plan`, then `apply` |
| a rehearsal before production | `staging/` | QEMU guests; `.#nixosConfigurations.staging-*` |
| rebuilding a machine from scratch | `docs/REBUILD.md` | read, then follow |

Two rules decide arguments between them: **OpenTofu owns what the provider can model**, Ansible owns what it cannot; and **nothing on
the router is hand-edited** — `config.xml` is off limits.

## Hosts

| host | address | role |
|---|---|---|
| `sitaw-amd` | .82 | platform: k3s server, ArgoCD, ingress, cloudflared, the NFS server |
| `calamansi-intel` | .81 | media: the stack pinned here, `/mnt/media`, the WireGuard tunnel |
| `patola-thinkcentre` | .80 | third etcd member, Immich (server, Postgres, Redis) |
| `kamatis-mbp` | .83 | **not a cluster node**: the staging host for datapath rehearsals |

The first three form **one 3-node k3s cluster** (embedded etcd, all schedulable, traefik and servicelb disabled). `.83` is a deploy-rs
target, not a member, so nothing rehearsed there can be depended on by the cluster.

## Layout

```
flake.nix                  # inputs, hosts, deploy.nodes
hosts/<host>/              # one file per machine, plus disko.nix where declared
modules/                   # base, k3s, backups, wireguard, monitoring — one concern each
cmd/, internal/            # Go commands that run ON a host (see ADR 0019 in homelab-context)
opentofu/{opnsense,cloudflare,omada,media}/
network/ansible/           # router + switch plays (API and ssh modes); collection pinned in requirements.yml
network/switch/            # the OpenWrt switch's exporter
staging/                   # the rehearsal cluster and its harness
scripts/                   # 30 shell scripts, each with its reason in docs/legacy-scripts.md
secrets/homelab.yaml       # SOPS/age host secrets
docs/REBUILD.md            # disaster recovery, in order
```

## Deploy

```bash
nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath   # does it evaluate?
nix run github:serokell/deploy-rs -- .#<host>                                 # build here, activate there
```

A **new** machine: add `hosts/<name>/default.nix` (and `disko.nix`), `git add` it, then
`nix run github:nix-community/nixos-anywhere -- --flake .#<name> --target-host root@<ip>`.

## Secrets

Host secrets (cloudflared credentials, the WireGuard key, the age identity) are **SOPS/age** via `sops-nix`; cluster secrets live in
Bitwarden and arrive through External Secrets in `bakuran-gitops`. No plaintext secret is committed — `check-repo-hygiene` fails the
build on the shapes it knows.

## Backups

Daily systemd timers push age-encrypted copies to R2: host keys and kubeconfigs (`modules/backup.nix`), config PVCs
(`modules/backup-apps.nix`), and Immich's own dump plus an offsite copy. `verify-backup-copies` compares the offline copy against R2
by set and size, weekly, and writes a metric.

## Checks

CI runs on the estate's own Forgejo: `check-repo-hygiene` — no tracked credentials, key material or disk images. The rest of the
estate's checks are Go, in `homelab-context`, and run from a workstation with `verify-all`.

## Where the reasoning lives

Design decisions, incident write-ups and the operational runbook are in `homelab-context` (private) and at
**[bismigel.dev](https://bismigel.dev)**, which is public. This repository holds the machines; it does not argue for them.
