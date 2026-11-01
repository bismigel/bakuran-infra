# `network/ansible` — the devices that have no Terraform provider

Two of the three network devices cannot be Terraformed, and this is where that is
handled. See `homelab-context/NETWORK-AS-CODE.md` §2 for the evidence.

| device | tool | why |
|---|---|---|
| OPNsense (`gw-opnsense`, `.1`) | **OpenTofu** — `bakuran-infra/opentofu/opnsense/` | a provider exists (`browningluke/opnsense` 0.26.0) |
| **GS108T v3 switch** (`.3`, now OpenWrt 24.10.4) | **Ansible — this directory** | no OpenWrt provider on the registry (checked 2026-11-01), but **UCI is fully scriptable**, which is exactly what OpenWrt bought us |
| Omada AP (`.151`) | controller API later | standalone firmware has no config CLI; needs an Omada controller first |

## What changed with OpenWrt

On Netgear firmware, RSTP, IGMP snooping, `cloudAgent` and SNMP were **web-UI only** — the
CLI had no verbs for them, so the honest answer was "documented manual config". Under
OpenWrt every one of those is a `uci` value, over SSH. The switch moved from "cannot be
automated" to "auditable in one command".

## Use

```bash
cd network/ansible
ansible-playbook playbooks/switch.yml              # apply the baseline
ansible-playbook playbooks/switch.yml -e audit=1   # read-only; exits non-zero on drift
```

Auth is **key-based** (`~/.ssh/id_ed25519`); the root password is only for recovery and is
kept in Bitwarden, not here.

## Design notes that matter

- **No Python on the target**, so every task is `script`/`raw`. Nothing here needs an
  interpreter on the switch.
- **Idempotency lives in the script**, not in Ansible: each `uci` value is compared before
  it is written, and the script prints `OK:` / `CHANGED:` / `DRIFT:`. That is what makes
  `-e audit=1` a real drift check rather than a no-op.
- **The switch is not a router**: `dnsmasq` and `odhcpd` stay disabled. It bridges the
  OPNsense LAN, so a DHCP server here would be a rogue one.
- **STP and IGMP snooping are on** — loop protection and sane multicast for the AP.

## The router (`playbooks/opnsense.yml`)

The OpenTofu provider has **no `system` resource**, so SSH keys, the password-auth policy and the
WebGUI session policy have no declarative home except this playbook. It edits `config.xml`
through OPNsense's own PHP library, which is the supported way to change those fields.

```sh
ansible-playbook -i inventory.yml playbooks/opnsense.yml              # apply
ansible-playbook -i inventory.yml playbooks/opnsense.yml -e audit=1   # drift report, fails on drift
```

State lives in `group_vars/all.yml` under `opnsense_baseline:` — **public** keys only (public keys
are not secrets), plus `disable_password_auth`, `webgui_session_timeout`, `webgui_auth_timeout`.

**The interlock is the important part.** Turning password auth off is the one dangerous thing this
does, so it refuses unless at least one authorized key would remain afterwards. On 2026-11-01 the
switch proved exactly why: a factory reset removed the key while its baseline would have disabled
passwords in the same run — a device nobody could log into, with nothing in git to fix it.

**Deliberately not automated:**

- **TOTP.** A seed has to be enrolled in a human's authenticator. Automating it either locks
  someone out or writes a secret that cannot be verified — it stays a documented manual step.
- **VLAN / interface objects.** Writing them into `config.xml` produces something OPNsense does
  not enumerate as an interface (see `homelab-context/ROUTER.md` §7c), so Kea and the UI ignore
  it. Create those in the UI, then the OpenTofu resources downstream start matching.
