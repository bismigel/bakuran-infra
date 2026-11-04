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

### The backend now works — state lives in R2

`tofu init` initially failed with `no EC2 IMDS role found` because the S3 backend had no
credentials. It needs the **same R2 key the backup job already uses** (`homelab-backups` bucket,
same endpoint) mapped onto the AWS variable names:

```sh
set -a; . ~/.config/opentofu/r2.env; set +a      # R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
```

Verified 2026-11-01: `init` succeeds, `plan` locks and unlocks state in R2, and a second `plan`
reports **no changes** (idempotent).

### Two provider limitations worth knowing before writing rules

1. **`dns_servers` is a `Set`, so order is not preserved.** Asking for
   `["192.168.2.1", "1.1.1.1"]` applies as `1.1.1.1,192.168.2.1`, and Kea sends them in that
   order — clients try `1.1.1.1` first, which on `.81` is routed inside the WireGuard tunnel.
   There is no ordered alternative in the provider (no `opnsense_kea_dhcpv4_option` resource),
   so the subnet hands out a **single** resolver and the fallback lives in unbound's upstreams.
2. **`auto_collect` must be `false`** or `routers`, `dns_servers` and `ntp_servers` are ignored
   while the apply reports success — a change that cannot fail is a change that never happened.

### Adoption is `import`, not `create`

The subnet and its four reservations already existed; `import` blocks take them into state so
the first apply is a no-op plus the intended change. Read the first plan: it named the live
`description` (`"homelab LAN"`) and normalised the pool format to the provider's spaced style —
both worth knowing rather than discovering later.
```

**Never** `tofu apply -auto-approve`. The workflow is in `NETWORK-AS-CODE.md` §6:
export `config.xml` → edit → plan (expect exactly N changes) → apply → verify from a
*second* host → commit.

## Phase

This root currently contains **no resources** — provider, variables and the credential
wrapper only. It is phase 2 of the plan (read-only inventory); resources get adopted in
phase 3 with `import` blocks, and the first `plan` must be empty before anything is owned.

### What OpenTofu can and cannot own here

`tofu plan` must report **No changes** — that covers everything the provider owns. Two things on
this router are outside it and are load-bearing, so they get their own check:

```sh
./verify-state.sh      # exit 0 = complete, 1 = something needs the UI (runbook 23)
```

| checked | why it is not in code |
|---|---|
| VLAN 20 device exists with tag 20 | the object is (`opnsense_interfaces_vlan`), the *assignment* is not |
| `192.168.20.1` on that interface | no provider resource for interface addresses |
| an interface is assigned to it | same |
| Kea serves the VLAN interface | the model's selection flag, UI-only (`/api/kea/dhcpv4/set` returns `Unexpected error`) |
| Kea has the clients subnet | covered by tofu — checked here because it is cheap |

Lose any of the middle three and every declarative resource still looks correct while the VLAN has
no address and no DHCP. The script exists so that failure is visible rather than discovered by a
phone that will not connect. Verified in both directions: it passes against the live router and
fails cleanly against an address that is not it.

## Running it

Credentials are not in this repo. Two Bitwarden Secrets Manager items in project
`homelab-kube` hold them, and `env.sh` reads them by **secret id** (ids are not secrets):

```sh
export BWS_ACCESS_TOKEN=...                      # machine account token
export OPNSENSE_KEY_ID=0f4b304a-d1d9-4e42-9442-b4f701525ee2
export OPNSENSE_SECRET_ID=9b0905e5-665d-4146-8e70-b4f701525f36
. ./env.sh && tofu plan
```

The state backend is S3 (R2), so `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` must also be
set — they are the `r2-access-key-id` / `r2-secret-access-key` items in the same project.

**How the key was created (2026-11-03):** OPNsense had *no* API keys, and its UI login for
`root` requires TOTP, so there was no non-interactive way in. The key was minted by calling
the same model the UI calls, from a root shell on the router:

```php
$model = new \OPNsense\Auth\User();
$model->getUserByName('root')->apikeys->add();   // returns key + secret
$model->serializeToConfig(false, true);
\OPNsense\Core\Config::getInstance()->save();
```

**Rotated 2026-11-04** — the procedure, with the two things that bite:

```bash
# 1. mint, from a root shell on the router (same model the UI calls)
cd /usr/local && /usr/local/bin/php -r '
require_once("config.inc");
$u = new OPNsense\Auth\User(); $user = $u->getUserByName("root");
$k = $user->apikeys->add(); $u->serializeToConfig(false, true);
OPNsense\Core\Config::getInstance()->save();
echo $k["key"] . "|" . $k["secret"] . PHP_EOL;'

# 2. store both values in Bitwarden Secrets Manager (`opnsense-api-key`, `opnsense-api-secret`)
# 3. prove the stored pair before touching the old one:
#      tofu plan  ->  "No changes. Your infrastructure matches the configuration."
# 4. only then delete the old key
```

- **`delApiKey` takes URL-safe base64 of the key, unpadded.** `base64 -w0 | tr '+/' '-_' | tr -d '='`
  → `200 deleted`. Standard base64 gave **404**, which reads like a missing endpoint rather than a
  wrong encoding.
- **The key list is a `key|hash` string, not an object.** `root.apikeys` comes back as
  `"<key>|<hash>
<key>|<hash>"`, so a `keys[]` over it fails; split on newlines, then on `|`.

The API's 200 is not the proof — `tofu plan` answering "No changes" with the **new** pair from
Secrets Manager is. The old key was deleted only after that.

## What `plan` cannot see

`tofu plan` reporting "No changes" means *nothing this stack manages differs* — verified
2026-11-03. It says nothing about settings the stack does not manage, and several are
hand-applied today, so they are invisible to it:

| setting | where it lives | why it matters |
|---|---|---|
| dpinger monitor IP (`1.1.1.1`) | `System → Gateways` | WAN loss/latency only works because it points at a public responder; the ISP gateway drops ICMP |
| Unbound DNSBL + DNSSEC + cache TTL | `Services → Unbound` | ad-blocking and validation |
| `/etc/cron.d/dnsbl` | router filesystem | refreshes the blocklists |
| heartbeat cron + token | `/usr/local/etc/homelab-heartbeat.sh` | the dead-man's switch that pages when the cluster is gone. **Not expressible here even in principle:** `opnsense_cron_job` exists, but its `command` must be a registered OPNsense *command key* ("e.g. `firmware poll`"), and the provider has no resource for a file, a script or an `actions.d` key — checked against the pinned provider's schema on 2026-11-04. Declaring it needs the Ansible path or a decision to keep it manual. |

None of these appear as drift, because drift is measured against what the code claims.
Closing them means either adding them to the stack or accepting, in writing, that they are
manual — the failure mode to avoid is believing `plan` is clean therefore the router is
fully described.
