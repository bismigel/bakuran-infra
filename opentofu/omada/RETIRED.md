# Retired 2026-11-03 — Wi-Fi is hand-managed

**This stack is not a control plane and will not be maintained.** Wi-Fi settings are
configured by hand on the EAP650. The decision was made explicitly: the Omada provider is
pre-1.0, the SSID→VLAN binding is two fields in a web UI, and keeping a second Terraform
stack alive for it costs more attention than it saves.

`wireless.tf` and `network.tf` are kept **as a record of intended state** (SSID
`Master Siomai`, `vlan_enable = true`, `vlan_id = 20`), not as something to apply. Do not
run `tofu apply` here; treat any output from it as a suggestion, because the AP has been
edited by hand since these files were last accurate.

## What replaces it

The AP's own configuration is the source of truth, so **its backup matters**:

- export the config from the EAP650 UI after any change, and store it with the encrypted
  network backups
- a factory reset loses the SSID→VLAN 20 binding, which is the only thing keeping Wi-Fi
  clients off the trusted LAN

## What is still declarative

- **OPNsense**: `opentofu/opnsense` — VLAN 20, Kea subnet/pool/DNS, reservations, and the
  four CLIENTS firewall rules
- **Switch**: `network/ansible` — `switch_baseline.vlans` drives the 802.1Q layout

If the AP is ever replaced with something the estate can drive from code (a controller with
a documented API, or a device in `bakuran-infra`'s NixOS set), this directory is the place
to start again — but only with evidence that the tooling is stable enough to run on every
change.
