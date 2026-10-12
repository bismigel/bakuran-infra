# Homelab Migration Plan — Proxmox → NixOS + ArgoCD

> **STATUS (current):** executed.
> - `bakuran-homelab` (Proxmox/Flux) — **archived/retired**.
> - `bakuran-infra` (this repo) — NixOS machines (`calamansi-intel` .81 media, `sitaw-amd` .82 hosting) + `deploy-rs` + SOPS/age.
> - `bakuran-gitops` — ArgoCD desired state for **both** clusters (app-of-apps under `applications/{sitaw,calamansi-intel}` + `manifests/`).
> - **One ArgoCD control plane on sitaw-amd**; `calamansi-intel` is a registered external cluster.
> - `homelab-app-template` — new-app scaffold; `Ciceley/ciceleywebsite` — app repo.
> - Secrets: **Bitwarden Secrets Manager + ESO** (cluster) and **SOPS/age** (host). Sealed Secrets retired.
> - Cloudflare Tunnel + Access serving `*.bismigel.dev`; ingress-nginx adopted under ArgoCD; `miguelarbis.dev` deployed.
>
> The original plan text below is kept for history.

---

## 1. Goals

1. **Retire Proxmox.** One physical node (`calamansi-intel`, NixOS) runs everything.
2. **Keep Kubernetes (k3s).** Reuse existing manifests and knowledge.
3. **GitOps with ArgoCD** as the single source of truth for cluster state.
4. **Ingress + tunnel:** `ingress-nginx` exposed to a Cloudflare tunnel serving
   `ciceley.cc` and `miguelarbis.dev`.
5. **Ship the website** `Ciceley/ciceleywebsite` via CI → GHCR → ArgoCD → `ciceley.cc`.
6. **No self-hosted GitHub runner** (rationale in §4.6).

---

## 2. Current state

There are effectively two parallel homelabs today.

### 2.1 Proxmox path — `bakuran-homelab` (working)

| Item | Value |
| --- | --- |
| Host | Proxmox `192.168.2.82`; k3s inside LXC/VM `101` |
| Config | Imperative (shell scripts, `deploy-site.sh`, `create-secret.py`) |
| GitOps | **Flux** (`flux/clusters/proxmox`, `flux/apps/{personal-site,discord-bot}`) |
| Images | GHCR via Actions → tag committed back → Flux reconciles |
| Ingress | `ingressClassName: nginx`, ClusterIP service + ingress |
| Exposure | Cloudflare tunnel (`config/cloudflare/config.yml`) `miguelarbis.dev` → `http://192.168.2.247:31914` (ingress NodePort) |
| Secret | `ghcr-secret` (docker-registry, `fish-vendor-1731`) |

### 2.2 NixOS path — `bakuran-infra` (in progress)

| Item | Value |
| --- | --- |
| Host | `calamansi-intel` `192.168.2.81`, bare-metal NixOS |
| Declared | `flake.nix` → `hosts/calamansi-intel/default.nix` + `modules/{base,k3s}.nix` |
| k3s | server, `--disable traefik`, `--disable servicelb` |
| Firewall | `22 6443 80 443` TCP, `8472` UDP |
| Storage | root ext4, `/boot` vfat, `/mnt/downloads` (238 GB media) |
| GitOps | **none** — `manifests/*.yaml` applied by hand |
| Ingress | **none** (`TODO: ingress controller`) |
| Secrets | **none** (`TODO: SOPS`) |
| Apps (declared) | homepage, jellyfin, arr-stack, qbittorrent, monitoring, exporters |

### 2.3 Gap

`calamansi-intel` runs k3s but has **no GitOps, no ingress, no secrets management**.
The website currently has no path to it.

---

## 3. Target architecture

```
                          Internet
                             │
                   Cloudflare DNS + Tunnel
                     (ciceley.cc, miguelarbis.dev)
                             │  CNAME → <tunnel>.cfargotunnel.com
                             ▼
                     cloudflared (NixOS service on calamansi-intel)
                             │  http → 127.0.0.1:<ingress NodePort>
                             ▼
calamansi-intel (NixOS, single node) ─────────────────────────────────────────────┐
│  k3s (traefik/servicelb disabled)                                          │
│   ├── ingress-nginx            (NodePort, class "nginx")                   │
│   ├── argocd                   (namespace argocd, self-managed)           │
│   ├── apps/  ← reconciled by ArgoCD from Git                              │
│   │    ├── homepage, jellyfin, arr-stack, qbittorrent, monitoring          │
│   │    └── ciceley-site  (ghcr.io/ciceley/ciceleywebsite)  → ciceley.cc    │
│   └── secrets: SOPS/age (host) + sealed-secret or SOPS-plugin (cluster)    │
└────────────────────────────────────────────────────────────────────────────┘
```

**Namespaces:** `kube-system`, `ingress-nginx`, `argocd`, `apps`, `monitoring`.

---

## 4. Decisions & rationale

1. **Single node (`calamansi-intel`).** Simplest way to remove Proxmox; matches current
   usage. Revisit 2-node only if resource pressure appears.
2. **Keep k3s.** Existing app manifests are reusable; no rewrite to `oci-containers`.
3. **ArgoCD over Flux.** Chosen for the UI. Trade-off: new install + we rewrite the
   app wiring. (The old Proxmox Flux config is retired, not migrated.)
4. **`ingress-nginx`, NodePort.** Traefik/servicelb are disabled; the tunnel reaches
   the cluster via a NodePort. `ingress-nginx` is what the existing `miguelarbis.dev`
   ingress already targets.
5. **Cloudflare tunnel stays** as the single ingress to the world (no port-forwarding).
6. **No self-hosted GitHub runner.**
   - GitOps removes the need for a runner to deploy — ArgoCD pulls and reconciles.
   - CI only builds/pushes an image; GH-hosted runners do this fine (public repo =
     free minutes, ~2s Hugo build).
   - A runner on a **public** repo is a code-execution risk inside the LAN (fork PRs).
   - If ever needed: containerize it, minimal token scope, **never** run on
     `pull_request` from forks.
7. **Secrets:** `sops-nix` for host secrets (cloudflared creds, age key);
   **Sealed Secrets** for in-cluster secrets (GHCR pull secret, app creds).

---

## 5. Repository strategy

| Repo | Role after migration |
| --- | --- |
| `bakuran-infra` | **NixOS host config + ArgoCD bootstrap + ArgoCD `Application`s** |
| `bakuran-homelab` | Archived/retired (Flux path). Keep for reference. |
| `Ciceley/ciceleywebsite` | Website app; keeps its own k8s manifests under `deploy/` |

Recommended: keep GitOps manifests **in `bakuran-infra`** under `gitops/`
(one repo to rule the cluster). The website manifests can either live here in
`bakuran-infra/gitops/apps/ciceley-site/`, or stay in `ciceleywebsite/deploy/`
and be referenced by a second ArgoCD `Application`. This doc assumes **apps live in
`bakuran-infra/gitops/`**, with the website image built by `ciceleywebsite` CI.

---

## 6. Phased migration checklist

> Every phase is reversible. **Do not decommission Proxmox until Phase 8.**

### Phase 0 — Prep
- [ ] Full backup of `bakuran-homelab` repo + any data not in git.
- [ ] Confirm `calamansi-intel` hardware headroom (CPU/RAM/disk) for all apps.
- [ ] Inventory Cloudflare: zone(s), tunnel id `8dcc83bd-…`, DNS records.

### Phase 1 — NixOS host
- [ ] Adopt `bakuran-infra` as source of truth; commit any drift from the live box.
- [ ] Harden SSH (`base.nix` currently allows root + password login — restrict it).
- [ ] Set `system.stateVersion` intentionally; pin `nixpkgs` (25.11) for reproducibility.
- [ ] `nixos-rebuild switch --flake .#calamansi-intel` (or `./deploy.sh calamansi-intel`).

### Phase 2 — k3s + ingress
- [ ] Keep k3s `--disable traefik --disable servicelb`.
- [ ] Install **ingress-nginx** (Phase 3/ArgoCD, or via a `HelmChart` CR).
- [ ] Expose it as **NodePort** (fixed port, e.g. `32080`) and record it.
- [ ] Decide ingress class name (`nginx`) and default.

### Phase 3 — ArgoCD bootstrap
- [ ] Install ArgoCD (namespace `argocd`) — options:
  - k3s `HelmChart` CR dropped into `/var/lib/rancher/k3s/server/manifests/`
    (declarable from Nix), or
  - one-time `kubectl apply -n argocd -f .../install.yaml`, then self-manage.
- [ ] Expose ArgoCD UI via ingress-nginx (`argocd.<domain>`), TLS via Cloudflare.
- [ ] Create an `Application` of `Application`s pointing at `bakuran-infra/gitops`
      (app-of-apps pattern) so the cluster is fully declared.

### Phase 4 — Secrets
- [ ] `sops-nix` on the host; store the **age** key on `calamansi-intel`.
- [ ] Encrypt: cloudflared tunnel credentials, GHCR pull token (if private).
- [ ] Install **Sealed Secrets** controller (via ArgoCD); seal the GHCR `ghcr-secret`
      for namespace `apps`.
- [ ] (Alt) `argocd-vault-plugin` if you prefer Vault/age at sync time.

### Phase 5 — Migrate apps to ArgoCD
- [ ] Convert `manifests/*.yaml` into `gitops/apps/<name>/` with kustomize.
- [ ] Move data concerns first: Jellyfin media paths (`/mnt/downloads`).
- [ ] Verify each app on `calamansi-intel` before touching Proxmox.

### Phase 6 — Cloudflare tunnel + DNS
- [ ] Run `cloudflared` as a **NixOS systemd service** (credentials via `sops-nix`).
- [ ] Tunnel ingress rules:
      `ciceley.cc` → `http://127.0.0.1:<ingress NodePort>`
      `miguelarbis.dev` → same.
- [ ] DNS: create `CNAME` records → `<tunnel-id>.cfargotunnel.com` (proxied).
- [ ] TLS terminates at Cloudflare; ingress serves HTTP.

### Phase 7 — Website (`ciceley.cc`)
See §7.

### Phase 8 — Decommission Proxmox
- [ ] Freeze writes, snapshot, keep 1–2 weeks.
- [ ] Re-point any remaining tunnel routes.
- [ ] Power off; later wipe and (optionally) reinstall as NixOS for a 2nd node.

---

## 7. Website deployment (`ciceley.cc`)

### 7.1 Current state (already built, in PR `Ciceley/ciceleywebsite#1`)
- Hugo + Stack theme; content synced from Notion.
- CI: `notion-sync` (opens PR with new content), `build` (PR check).
- `deploy.yml`: builds site → nginx image → GHCR `ghcr.io/ciceley/ciceleywebsite`
  → commits image tag.
- `deploy/flux/*`: **Flux** CRs (Deployment/Service/Ingress + `ImageRepository`/`ImagePolicy`).

### 7.2 Adjustments for ArgoCD
Flux-specific objects must change:

| Flux today | ArgoCD equivalent |
| --- | --- |
| `ImageRepository` / `ImagePolicy` | CI already commits the image tag → delete these |
| `ImageUpdateAutomation` | none (CI commits tag) — or ArgoCD Image Updater |
| Flux `Kustomization` | ArgoCD `Application` |

**Result:** `deploy/k8s/` = `Deployment` + `Service` + `Ingress` (+ `kustomization.yaml`).
CI keeps bumping the image tag in the `Deployment`.

### 7.3 Where the manifests live
Option A (recommended): move them to `bakuran-infra/gitops/apps/ciceley-site/`
and open a small PR in `ciceleywebsite` that only bumps the tag there (cross-repo
token needed) — more moving parts.
Option B: keep them in `ciceleywebsite/deploy/k8s/` and add an ArgoCD `Application`
in `bakuran-infra` pointing at
`repoURL: https://github.com/Ciceley/ciceleywebsite`, `path: deploy/k8s`,
`targetRevision: main`. **Simplest; recommended.**

### 7.4 Image pull
- The repo is **public**. Make the GHCR package **public** (once) → no pull secret.
- Else: create `ghcr-secret` in `apps` (sealed), reference in the Deployment.

### 7.5 Ingress
- `Ingress` with `ingressClassName: nginx`, host `ciceley.cc`.
- Set Hugo `baseURL = https://ciceley.cc` (repo var `SITE_BASEURL`).

### 7.6 Flow
```
merge PR → deploy.yml: hugo build → docker build → push GHCR → commit tag
        → ArgoCD sees git change → sync → new pod on calamansi-intel
        → ingress-nginx → cloudflared → https://ciceley.cc
```

---

## 8. Risks, rollback, open questions

**Risks**
- Proxmox retirement risks media/data — migrate `/mnt/downloads` expectations first.
- ArgoCD + k3s on one node = single point of failure; keep the Proxmox box until stable.
- Cloudflare tunnel is the only ingress — if it breaks, the site is down.
- `base.nix` currently has weak SSH settings.

**Rollback**
- Each phase is git-revertible. Keep Proxmox powered and tunnel config backed up.

**Open questions**
- [ ] Is `calamansi-intel` the *only* disk we trust, or will the ex-Proxmox box become node 2?
- [ ] One Cloudflare tunnel for all hostnames, or one per service?
- [ ] Keep `miguelarbis.dev` on `calamansi-intel`, or leave it on Proxmox during transition?
- [ ] Fully Nix-managed k3s install of ArgoCD, or bootstrap-then-self-manage?
- [ ] SOPS-only, or Sealed Secrets for in-cluster secrets?

---

## 9. Suggested order of work (short)

1. Harden `base.nix` + commit drift.
2. ingress-nginx (NodePort) on `calamansi-intel`.
3. ArgoCD bootstrap + app-of-apps.
4. SOPS + sealed-secrets.
5. Migrate media stack.
6. cloudflared service + DNS for `ciceley.cc`.
7. Website: convert `deploy/flux` → `deploy/k8s`, add ArgoCD `Application`, merge PR #1, make GHCR package public.
8. Decommission Proxmox after soak period.
