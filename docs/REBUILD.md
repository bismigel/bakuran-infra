# REBUILD.md — disaster recovery

Everything lives in **git** (NixOS flake + `bakuran-gitops`) and **Bitwarden
Secrets Manager**. A clean rebuild is ~1–2 hours and mostly automated.

```
Notion/Org ─▶ app repos ─▶ CI (image + tag bump) ─▶ GHCR
                                   │
                                   ▼
                    ArgoCD (sitaw-amd) ─▶ both clusters
```

## 0. Prerequisites — have these in hand (back them up NOW)

| Secret | Where | Recovery if lost |
| --- | --- | --- |
| **Bitwarden SM access token** | admin box `.env` (`k8s-eso-machineaccount`) + Bitwarden | **root of trust** for all k8s secrets |
| **Host SSH keys** (`/etc/ssh/ssh_host_ed25519_key`) | R2 `creds-<host>-*.tar.gz.age` | restores the **SOPS age identity** |
| **Backup age key** | `~/homelab-backup.agekey` on the admin box + Bitwarden (`backup-age-key`) | decrypts the R2 backups |
| **ArgoCD repo deploy keys** | Bitwarden (`argocd-repo-bakuran-gitops`, `argocd-repo-private-api`) | recreate a GitHub deploy key |
| **Cloudflare tunnel creds** | `~/cloudflare-backup/` (admin box) + SOPS | re-download from Cloudflare |
| **R2 / CF token / GH PAT** | Bitwarden (`r2-*`, `cloudflare-api-token`, `github-pat`) | — |

## Storage layout (as of 2026-10-12)

Each host: **100 GiB root** on the NVMe + a **media data** partition (NVMe rest)
+ the whole **SATA** disk. `.82` exports its two media partitions over **NFSv4**;
`.81` **mergerfs**-unions all four into **`/mnt/media`** (~1.2 TB) which Jellyfin
+ the *arrs mount. Defined in `hosts/<host>/disko.nix` and
`hosts/calamansi-intel/default.nix`.

## 1. OS — the two machines

```bash
cd bakuran-infra
nix run github:nix-community/nixos-anywhere -- --flake .#sitaw-amd \
  --target-host root@192.168.2.82 \
  --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
# repeat for .#calamansi-intel -> root@192.168.2.81
```

**⚠ Gotcha — stale Proxmox LVM.** If a machine previously ran Proxmox, a `pve`
LVM VG can survive the wipe, so a freshly-partitioned `p2` reads as `LVM2_member`
and `mkfs` fails. In the installer shell (after kexec, before disko):
```bash
vgchange -an pve; vgremove -f pve; dmsetup remove_all
for d in /dev/nvme0n1 /dev/sda; do
  wipefs -a "$d"; dd if=/dev/zero of="$d" bs=1M count=2048 conv=notrunc
  dd if=/dev/zero of="$d" bs=1M count=64 seek=$(( $(blockdev --getsize64 "$d")/1048576-64 )) conv=notrunc
done
```

## 2. Restore the host SSH keys (do this before the box reboots into sops use)

The R2 backup holds the host keys. Restore them so **SOPS** decrypts
(cloudflared creds, WireGuard key). Without them the box still boots, but
`sops-install-secrets` fails and cloudflared/VPN won't run.
```bash
# on the admin box: decrypt + extract, then push into /etc/ssh on the host, reboot
age -d -i ~/homelab-backup.agekey creds-<host>-*.tar.gz.age | tar xz
```

## 3. ArgoCD (sitaw-amd) — the one manual bootstrap

```bash
# from bakuran-infra, with the repo deploy key from Bitwarden:
ARGO_REPO_SSH_KEY=/path/to/key ./scripts/bootstrap-argocd.sh
```
- The script installs ArgoCD with **`--server-side`** (the ApplicationSet CRD
  exceeds the 262144-byte limit for client-side apply).
- **Before ESO is needed**, create the `bitwarden-access-token` Secret in the
  `external-secrets` namespace from the Bitwarden SM token (no trailing newline!):
  ```bash
  k3s kubectl -n external-secrets create secret generic bitwarden-access-token \
    --from-literal=token="$BWS_TOKEN"
  ```
  The store (`manifests/external-secrets/secretstore.yaml`) uses **`caProvider`**
  (live `bitwarden-tls-certs` ca.crt), so there is **no pinned caBundle** to fix
  after a reinstall.

## 4. Additional server nodes (calamansi-intel, kamatis-mbp)

There is **one cluster**, not two. After the first server (`sitaw-amd`,
`clusterInit`) is up, the other hosts join as servers using the **cluster token**
(SOPS secret `k3s_cluster_token`) via `serverAddr`:
- `.81`/`.83`: `services.k3s = { role = "server"; serverAddr = "https://192.168.2.82:6443";
  tokenFile = config.sops.secrets."k3s_cluster_token".path; }`.
- Open etcd ports **2379/2380** between nodes (firewall).
- Install a fresh host with
  `nixos-anywhere --flake .#<host> --target-host root@<ip>` (for the 2012 Mac:
  GRUB `efiInstallAsRemovable`, lid/suspend disabled).
No external-cluster registration — all workloads run in-cluster; the media stack
is pinned to `.81` via `nodeSelector`.

## 5. Media hostPath dirs

`.81` creates `/mnt/media-sda/{tv,movies,downloads,temp}` via the `media-dirs`
systemd service (hostPath mounts surface these at `/mnt/media/{...}`).

## 6. Media stack wiring (declarative)

The media cluster has **no External Secrets operator**, so two Secrets are seeded
out of band from Bitwarden, then one script wires everything:

```bash
# from the admin box (has the BWS token):
./scripts/media-usenet-secret.sh    # usenet-frugal  (Frugal provider creds)
./scripts/media-setup-secret.sh     # media-setup    (qbt pass, NZBGeek key, jellyfin creds)
./scripts/lazylibrarian-secrets.sh  # books/lazylibrarian-secrets (Prowlarr key for the books indexer)
# then on the media box (or over ssh):
HOST=127.0.0.1 KUBECTL="k3s kubectl" ./scripts/media-stack-setup.sh
```

`media-stack-setup.sh` re-creates: qBittorrent save path + categories, Sonarr/Radarr
root folders + download clients (**qBittorrent and SABnzbd**), Prowlarr apps,
**indexers (Nyaa.si + NZBGeek)**, and **Jellyfin users** (anton/delfin/ciceley).
All values come from the `media-setup` Secret (no hardcoded secrets). The
`*-api-key` entries are read from Bitwarden Secrets Manager first (`prowlarr-api-key`,
`sonarr-api-key`, `radarr-api-key`, `sabnzbd-api-key`); if a BWS secret is missing the
script falls back to scraping the running pods, so a fresh stack still bootstraps.

## 7. Cloudflare

Tunnel routes, DNS, and Access live **in Cloudflare** and survive a wipe. If the
tunnel ID changes, update `hosts/sitaw-amd/default.nix` + the cloudflared creds.

## What is NOT automatic (keep these in Bitwarden / on the admin box)
1. ArgoCD install + repo credentials (`bootstrap-argocd.sh`, incl. the HA scaling)
2. The `bitwarden-access-token` Secret
3. Host SSH keys (SOPS identity) + the backup age key + the SOPS **admin key**
   (`~/.config/sops/age/homelab.txt`, also in Bitwarden)
4. Cloudflare tunnel creds

Note: **ArgoCD HA** (server/repo-server/appset ×2 + controller ×2) is applied by
`bootstrap-argocd.sh`; **Redis is a single replica (SPOF)** — full HA needs
redis-ha (3 nodes + tolerations). Stateful PVCs are `local-path` (node-pinned) —
Longhorn would be needed for stateful rescheduling.

## ⚠️ Do NOT seed Bitwarden with PushSecrets
A leftover `PushSecret` (e.g. `seed-deepseek`, `seed-telegram`) keeps pushing its
value on a timer and will **clobber the real secret** in Bitwarden — this actually
happened (the DeepSeek key + Telegram token were reverted to dummies). Create/rotate
secret values **directly in the vault**; never leave a seeding PushSecret running.
