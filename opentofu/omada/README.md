# `opentofu/omada` — the wireless side, in code

The AP was the one device in this estate with **no declarative path**: its web UI is a JavaScript
app with an encrypted login, and its SSH CLI is read-only ("EAP CLI", no config verbs). Tagging an
SSID into a VLAN could only be clicked.

It can be code, through the controller. `wncservices/omada` (v0.13.2) exposes:

| resource | what it does |
|---|---|
| `omada_network` | an L2 VLAN, or a routed interface network |
| `omada_wireless_network` | an SSID, with `vlan_enable` / `vlan_id` / `lan_network_id` |
| `omada_access_point` | **adopts** a device (an AP cannot be created or destroyed) |

Use `purpose = "vlan"`, never `"interface"`: OPNsense owns `192.168.20.0/24`, the Kea scope and the
firewall rules. Omada must only know VLAN 20 exists so an SSID can bind to it.

## Two manual prerequisites

1. **Controller first-run.** The container currently reports `configured: false` — Omada will not
   answer any API call until an admin exists, so this is a browser visit to
   `https://<controller>:8043` once. Everything after it is code.
2. **Adopt the AP** (`omada_access_point` adopts by MAC). The AP has to be pointed at the controller
   first — an AP in standalone mode does not find it by itself. That is one field in the AP's UI
   (Controller Address) or a DHCP option 43, and it needs the AP's admin credentials.

## Then

```sh
export TF_VAR_omada_url=https://192.168.2.32:8043
export TF_VAR_omada_username=...      # from the vault
export TF_VAR_omada_password=...
export TF_VAR_wifi_psk=...            # write-only, never in state
tofu init && tofu plan
```

## Cautions

- **`psk` is write-only** — supplied on apply, never read back. Losing it means re-keying the SSID.
- **Renaming an SSID creates a new one.** Import the existing network before managing it, or you
  will leave the old SSID broadcasting alongside the new.
- **Radio changes drop clients.** `omada_access_point`'s radio attributes restart that band; a no-op
  apply is silent, a real change is a brief outage on that radio.
