# Cloudflare OpenTofu

OpenTofu state for the Cloudflare edge. DNS, the tunnel config, security zone
settings, all seven Access applications and the R2 lifecycle are managed here.

## Credentials

Use the Cloudflare token from SOPS. Never write it into a file or shell history.

The token is **not** at `/run/secrets/cloudflare_api_token` any more: the `cloudflare-sync` module that declared it was
deleted on 2026-11-17 (a daily reconciler holding a broad token), and the next activation removed the file. The value is
still in `secrets/homelab.yaml`, so read it there with the admin age key:

```bash
export TF_VAR_cloudflare_api_token="$(SOPS_AGE_KEY_FILE=~/.config/sops/age/homelab.txt \
  sops -d secrets/homelab.yaml | yq -r .cloudflare_api_token)"
# Access allowlist for the second household member (Bitwarden: access-household-emails).
export TF_VAR_household_emails='["<from Bitwarden>"]'
```

## Where the state lives

**In R2**, not on a workstation:

```
backend "s3"  bucket = homelab-backups
              key    = opentofu/cloudflare/terraform.tfstate
              use_lockfile = true
```

Plus an age-encrypted snapshot (`opentofu/cloudflare-*.tfstate.age`) in the same
prefix. Credentials for the backend come from `~/.config/homelab-backup.env`
(`R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`), exported as
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` before `tofu init`.

### If `tofu init` offers to "migrate" local state

**Say no.** A `terraform.tfstate` file left in this directory is a *stale copy from
an older lineage* — it is gitignored, and it exists only because a plugin wrote it
before the backend was configured. On 2026-10-28 one such file (serial 39, lineage
`0b6df55c`) was offered for migration into the live state (serial 6, lineage
`6d4a0793`, 45 resources). Accepting would have replaced the current edge state
with a six-day-old copy.

Check before you let anything move:

```bash
tofu state pull | grep -oE '"serial":[0-9]+|"lineage":"[^"]*"' | head -2
```

If a local file is in the way, move it aside rather than migrating it:

```bash
mv terraform.tfstate /tmp/terraform.tfstate.old
```

## First import, one resource at a time

The existing edge includes:

- one remote-managed tunnel and its ingress config;
- DNS records in `bismigel.dev`, `ciceley.cc` and `miguelarbis.dev`;
- Access applications and policies;
- R2 lifecycle settings;
- zone settings.

Do not import all of them in one state. Start with a single DNS record, run
`tofu plan`, and confirm the plan is a no-op before expanding.

```bash
tofu init
tofu plan
```

## Suggested order

1. one DNS record in `bismigel.dev`;
2. all DNS records for that zone;
3. the tunnel configuration;
4. Access applications and policies;
5. R2 lifecycle;
6. zone settings.

The rollback path is `git revert` of this directory plus `tofu apply` — one declaration, one owner.

## State

State lives in the S3-compatible R2 backend:

- bucket `homelab-backups`;
- key `opentofu/cloudflare/terraform.tfstate`;
- endpoint `https://c13ab6fbc2a53cfe719bca75fdc825c2.r2.cloudflarestorage.com`;
- `use_lockfile = true` for native S3 state locking.

Credentials are R2 access keys in `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`, sourced from the backup env. They are never written to
this repo. Migrate an existing local state with:

```bash
tofu init -migrate-state
```

Keep an encrypted copy of the state in `r2:homelab-backups/opentofu/` for
recovery. Do not commit `*.tfstate`.

## Why this is not automatic

`cf-terraforming` could read the account, but its bundled Terraform installer
rejected an expired signing key, and its provider-registry lookup failed. Manual
imports are the safe path until that tooling works.

## Current scope

All 21 DNS records in `bismigel.dev`, both `ciceley.cc` records and all three
`miguelarbis.dev` records are imported. The tunnel ingress config and the ArgoCD
Access application are imported. Targeted DNS and tunnel plans are clean.

All seven Access applications are imported. Their policies are app-scoped inline
references, so no separate reusable policy resource is needed. The R2 lifecycle
rules for `homelab-backups` are adopted by creating the resource over the
existing rules; the provider does not support import. The full `tofu plan` is
clean. Zone settings `ssl`, `min_tls_version`, `always_use_https` and
`security_header` are imported and plan clean.

`cloudflare_r2_bucket_lifecycle` cannot be destroyed through OpenTofu. Removing
it from configuration and applying would drop it from state, not delete the
rules; delete the lifecycle manually through the API if that is ever needed.

## Tunnel

The remote-managed tunnel ingress configuration is imported as
`cloudflare_zero_trust_tunnel_cloudflared_config.main`. `tofu plan` is clean.
R2 lifecycle is now managed by OpenTofu.

## One owner

This directory is the only declaration of the Cloudflare edge. `cloudflare/sync.sh` was a second one and was deleted on
2026-11-17 after it was found stale in three ways at once (dead targets, four undeclared hostnames, two undeclared Access
apps) — see [`../../cloudflare/README.md`](../../cloudflare/README.md). Two reconcilers do not make an edge more reliable;
they make it possible for one of them to be wrong without anyone noticing.

## Two things that are true and worth knowing

- **The tunnel targets are ClusterIPs, not host ports** (`var.public_target` / `var.admin_target`). The connectors run as
  host units on .81 and .82 but reach the ingress controllers through the cluster's service network; the
  `127.0.0.1:3208x` NodePorts this file named until 2026-11-17 no longer listen. Verified: `ss -ltn | grep -cE ':32080|:32081'`
  = 0 on .82, and `curl -H 'Host: argocd.bismigel.dev' http://10.43.15.7/` = 200.
- **Seven Access policies are referenced by id**, not declared here (`books`, `media`, `longhorn`, `private_api`, `agent`,
  `grafana`, and now `tools`/`argo`). The application's policy list takes ids, and modelling an app-scoped policy as a
  resource needs an import shape this directory has not used yet. The two newest — `runbook` and `forgejo` — do declare
  their policy. Recorded as debt, not as a finished state.
