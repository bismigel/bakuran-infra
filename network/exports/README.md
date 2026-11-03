# Network configuration exports

Encrypted backups of the configuration of devices that are **not** reproducible from this
repo. SOPS + age (see `.sops.yaml`): every host key plus the admin key can decrypt.

| file | device | taken |
|---|---|---|
| `opnsense-config-2026-11-01T0914.xml` | OPNsense on `sitaw-amd`'s OptiPlex (`.1`) | 2026-11-01 09:14 |
| `gs108tv3-oem-running-config-2026-11-01.txt` | Netgear GS108Tv3 before the OpenWrt flash | 2026-11-01 |

## Why these exist

The OPNsense config is *mostly* in code (`opentofu/opnsense`), but only for what that stack
manages: VLAN 20, the Kea subnet/pool/DNS, DHCP reservations, and the CLIENTS firewall
rules. Everything else lives only in this file — password hashes, Wi-Fi PSKs, the
WireGuard key, the Unbound settings, the crontab, and the four settings listed in
`opentofu/opnsense/README.md` as deliberately unmanaged.

Before this directory existed, the only copy was a plaintext file on one admin laptop,
alongside the SSH keys that reach everything. A dead OptiPlex SSD would have meant
reconstructing the router from memory.

## Encrypt / decrypt

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/homelab.txt   # admin key, also in Bitwarden
sops --encrypt --in-place network/exports/<file>          # after refreshing an export
sops --decrypt network/exports/<file> > /tmp/<file>       # to read one
```

## Refreshing

Take a new export after any change that the OpenTofu stack does not manage — the four
unmanaged settings, DNS/DHCP outside Kea, WireGuard, or anything done by hand in the UI:

1. `System → Diagnostics → Backup` on the router → download the config XML
2. `cp` it here with the timestamp in the name, `sops --encrypt --in-place` it
3. `git add` the **encrypted** file only — CI's secret scanner will fail the build if a
   plaintext export slips in

Delete the plaintext download from wherever it landed (a `~/Downloads` copy with password
hashes in it is how this problem started).
