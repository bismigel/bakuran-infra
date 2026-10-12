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
| **Bitwarden Secrets Manager access token** | `bitwarden-access-token` Secret / `.env` | **root of trust** for all k8s secrets — keep in Bitwarden + offline |
| **Host SSH keys** (`/etc/ssh/ssh_host_ed25519_key`) | each box | restores SOPS age identity so `secrets/homelab.yaml` decrypts |
| **ArgoCD repo SSH keys** (`repo-bakuran-gitops`) | argocd Secret on sitaw-amd | regenerate a GitHub deploy key |
| **Sealed-secrets key** | (removed — not used) | n/a |
| **R2 creds** | `.env` | Bitwarden |
| **Cloudflare token** | `.env` | Bitwarden |

## 1. OS — the two machines
```bash
nix run github:nix-community/nixos-anywhere -- --flake .#sitaw-amd     --target-host root@192.168.2.82
nix run github:nix-community/nixos-anywhere -- --flake .#calamansi-intel --target-host root@192.168.2.81
# afterwards, day-to-day:  nix run github:serokell/deploy-rs -- .#sitaw-amd
```
Restore the host SSH keys **before** booting sops-nix, or SOPS won't decrypt.

## 2. ArgoCD (sitaw-amd) — the one manual bootstrap
```bash
kubectl create ns argocd
kubectl -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```
Add the **repo credentials** (SSH deploy key for `bismigel/bakuran-gitops`):
```bash
kubectl -n argocd create secret generic repo-bakuran-gitops \
  --from-literal=type=git \
  --from-literal=url=git@github.com:bismigel/bakuran-gitops.git \
  --from-file=sshPrivateKey=<key> \
  --from-literal=name=bakuran-gitops
kubectl -n argocd label secret repo-bakuran-gitops argocd.argoproj.io/secret-type=repository
```

## 3. Root app-of-apps
```bash
kubectl -n argocd apply -f bootstrap/root-app.yaml   # watches applications/
```

## 4. Register the media cluster (calamansi-intel)
On `.81`: create the `argocd-manager` SA + token (see `clusters/calamansi-intel.yaml`),
then create the `cluster-calamansi-intel` Secret on sitaw-amd's argocd namespace.
→ the `media` + `node-exporter` apps reconcile onto `.81`.

## 5. ESO root of trust
```bash
kubectl -n external-secrets create secret generic bitwarden-access-token \
  --from-literal=token='<Bitwarden machine-account token>'
```
→ ESO syncs `ghcr-secret` (and everything else from Bitwarden).

## 6. Media stack wiring
```bash
QBT_PASSWORD='<qbt webui password>' ./scripts/media-stack-setup.sh
```
Sets qBittorrent save path/categories, Sonarr/Radarr root folders + download
clients, and Prowlarr → Sonarr/Radarr links.

## 7. Cloudflare
Tunnel routes, DNS, and Access live **in Cloudflare** and survive a wipe. If the
tunnel ID changes, update `hosts/sitaw-amd/default.nix` + the cloudflared creds.

## What is NOT automatic (keep these in Bitwarden)
1. ArgoCD install (step 2)
2. ArgoCD repo credentials (step 2)
3. The `calamansi-intel` cluster registration (step 4)
4. The `bitwarden-access-token` (step 5)
5. The host SSH keys (step 1, for SOPS)
