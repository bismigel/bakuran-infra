# `opentofu/opnsense` — the gateway, as code (narrow slice)

Design: **`homelab-context/NETWORK-AS-CODE.md`**. Device facts: **`homelab-context/ROUTER.md`**.
This file only says what the root is for and how to run it without hurting anything.

## What this root will own

Only objects the provider actually supports and that are safe to own
(`NETWORK-AS-CODE.md` §4):

| yes | no — manual, forever |
|---|---|
| firewall aliases | interface assignment (`em0`/`em1`) |
| firewall filter rules (**disabled first**) | the LAN IP and the anti-lockout rule |
| Kea subnets + reservations | the admin GUI/SSH access rule |
| VLAN interfaces | root user / SSH keys (`Auth/User` unsupported) |
| | Unbound, ntpd, IDS, firmware |

## Why here and not `bakuran-gitops`

`bakuran-gitops` is ArgoCD's desired state **inside** the cluster. The router, switch and AP
are the environment the cluster runs *in* — the same category as the Cloudflare edge, which
already lives in `opentofu/cloudflare/`. Keeping them together means one PR can change a
host firewall rule and the router rule that has to match it (`HARDENING.md`'s iSCSI/NFS
scoping was exactly that pair).

A separate `bakuran-network` repo would be right when the network has its own contributors,
release cadence or state lifecycle. For three devices it would add a fourth place to look
and a second CI/secret path for no isolation benefit.

## Running it

```bash
. ./env.sh                 # pulls the API key from BWS into the environment
tofu init -backend=false   # provider only; no credentials needed for validate
tofu validate
tofu plan                  # needs state (backend) + credentials
```

**Never** `tofu apply -auto-approve`. The workflow is in `NETWORK-AS-CODE.md` §6:
export `config.xml` → edit → plan (expect exactly N changes) → apply → verify from a
*second* host → commit.

## Phase

This root currently contains **no resources** — provider, variables and the credential
wrapper only. It is phase 2 of the plan (read-only inventory); resources get adopted in
phase 3 with `import` blocks, and the first `plan` must be empty before anything is owned.
