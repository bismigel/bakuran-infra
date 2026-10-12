# AGENTS.md — instructions for AI/LLM agents (and humans)

This repo is the **NixOS machine configuration** for the Bakuran homelab.

- `calamansi-intel` (.81, Intel i5-7500T) — media / arr stack (k3s)
- `sitaw-amd` (.82, Ryzen 5 4600G) — hosting (k3s + ArgoCD + ingress-nginx + cloudflared)

Cluster *content* (what runs on top of k3s) lives in **`bakuran-gitops`**, not
here. This repo only defines the machines.

## Layout

```
flake.nix                 # inputs (nixpkgs, disko, deploy-rs) + hosts + deploy nodes
hosts/<host>/default.nix  # per-host config (imports modules/, disko.nix)
hosts/<host>/disko.nix    # disk layout (only where disko is used)
modules/                  # shared config (base.nix, k3s.nix)
deploy.sh                 # legacy: sync + nixos-rebuild over ssh
```

## Rules for agents

1. **Never hardcode secrets.** Use `sops-nix` (planned) or keep them out of the
   repo. Do not commit keys, tokens, or the cloudflared credentials JSON.
2. **One host = one `hosts/<name>/default.nix`**, registered in `flake.nix`
   under both `nixosConfigurations` and `deploy.nodes`.
3. Keep shared behaviour in `modules/`; host files override with `lib.mkForce`.
4. After edits, validate before deploying:
   ```bash
   nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
   ```
5. `hardware-configuration.nix` is **git-ignored** — inline hardware in the host
   file (see `hosts/calamansi-intel/default.nix`, `hosts/sitaw-amd/default.nix`).

## Deploy an existing host

```bash
nix run github:serokell/deploy-rs -- .#sitaw-amd
nix run github:serokell/deploy-rs -- .#calamansi-intel
```

## Install a brand-new host (wipes the target)

1. Add `hosts/<name>/default.nix` + `hosts/<name>/disko.nix`, register in the flake.
2. `nix run github:nix-community/nixos-anywhere -- --flake .#<name> --target-host root@<ip>`
3. `git add` the new files first (flakes only see tracked files).

## Common pitfalls

- Flakes ignore **untracked** files → always `git add` new host files.
- `deploy-rs` requires SSH to `root@<host>` and will **roll back** on failure.
- k3s `extraFlags` disabling traefik/servicelb is intentional (ingress-nginx is
  managed by ArgoCD).
