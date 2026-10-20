# Cloudflare OpenTofu

Planning scaffold for replacing `cloudflare/sync.sh` with provider-managed state.
Nothing is imported or applied yet.

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

All 21 DNS records in `bismigel.dev` are imported. `tofu plan` is clean. The
other zones, tunnel configuration, Access apps, R2 lifecycle and zone settings
remain on `cloudflare/sync.sh`.

## Tunnel

The remote-managed tunnel ingress configuration is imported as
`cloudflare_zero_trust_tunnel_cloudflared_config.main`. `tofu plan` is clean.
Access apps, R2 lifecycle and the other zones still use `cloudflare/sync.sh`.
