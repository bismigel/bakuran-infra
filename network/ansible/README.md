# `network/ansible` — the devices, in two modes

One Ansible tree for the router and the switch. There are **two ways in**, and the playbook name says which:

| playbook | mode | why |
|---|---|---|
| `playbooks/ids.yml`, `playbooks/vnstat.yml` | OPNsense **API** (`ansible_connection: local`) | the `ansibleguy.opnsense` collection is an API client; the modules run here and talk HTTPS to the firewall. No shell is opened on the router. |
| `playbooks/opnsense-baseline.yml` | **ssh + script** | identity, access and IDS settings live in `config.xml`, edited through OPNsense's own library (`files/opnsense_baseline.sh.j2`). Idempotency lives in the script. |
| `playbooks/switch.yml` | **ssh + script** | the switch runs OpenWrt, which has no Python at all — every task is raw/script level (`files/switch_baseline.sh.j2`). |

## Running one

```bash
./run.sh playbooks/vnstat.yml --check --diff   # what would change
./run.sh playbooks/vnstat.yml                   # do it
```

`run.sh` fills the API credentials from Bitwarden Secrets Manager, so the API plays need nothing in your shell. The ssh plays use
`~/.ssh/id_ed25519` and read their settings from the inventory.

`--check` first is not a formality: these plays edit the only router and the only switch in the estate, and a check that reports "no
change" is the proof that the play agrees with reality before anything is written.

## What is not here

Everything the OPNsense provider can model — firewall rules, VLANs, DHCP, DNS overrides — is **OpenTofu** in
`opentofu/opnsense/`, not a play. This tree exists for the half no provider covers, and neither is allowed to grow into the other's
territory.

## The collection

`requirements.yml` pins `ansibleguy.opnsense` exactly, because it manages the only router and an unpinned bump could change what a play
does. It installs into `collections/`, which is ignored — three hundred vendored files were tracked for weeks because the ignore pattern
resolved to `ansible/ansible/collections`. See `../../docs/legacy-scripts.md`.
