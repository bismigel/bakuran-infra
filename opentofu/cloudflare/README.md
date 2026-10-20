# Cloudflare OpenTofu

Planning scaffold for replacing `cloudflare/sync.sh` with provider-managed state.
DNS, the tunnel config, security zone settings, all seven Access applications and
the R2 lifecycle are managed here.

## Credentials

Use the Cloudflare token from SOPS. Never write it into a file or shell history.

```bash
export TF_VAR_cloudflare_api_token="$(sudo cat /run/secrets/cloudflare_api_token)"
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

Keep `cloudflare/sync.sh` as the rollback path until the OpenTofu state covers
the full edge and a `tofu plan` is clean.

## State

Local encrypted storage is acceptable for the first import. Back it up with the
host. Do not commit `*.tfstate`.

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
