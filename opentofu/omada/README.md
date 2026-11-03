# RETIRED 2026-11-03 — Wi-Fi is hand-managed. See RETIRED.md. Do not run tofu apply here.

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

## Planned: move the controller off the laptop and into the cluster

The controller currently runs in rootless podman **on the admin laptop**, which is the one thing in
this design that moves: its address has already changed twice in a day (Bell island `.32`, OPNsense
island `.150`). A Kea reservation pins it while it is on the management network, and
`omada.internal` (an unbound override) is what the AP should be pointed at — so a change of address
costs one record rather than a trip to the AP's web UI, which has no automation path.

The durable fix is to run it where everything else runs, and the AP's controller address becomes a
node IP that never changes.

**Shape:** an ArgoCD app in `bakuran-gitops`, `hostNetwork: true`, pinned with a `nodeSelector` to
the platform node, and a Longhorn PVC mounted at `/opt/tplink/EAPController/data`.

`hostNetwork` is not laziness — the controller is discovered by **UDP broadcast** (29810/udp) and
managed over four more fixed ports, so a NodePort/ClusterIP design would need a UDP
LoadBalancer plus one port per function, for no benefit.

| port | proto | what |
|---|---|---|
| 8043 | tcp | management UI (HTTPS) |
| 8088 | tcp | management UI (HTTP) |
| 8843 | tcp | user portal (HTTPS) |
| 27001 | udp | Omada **app** discovery |
| 29810 | udp | controller ↔ device **discovery** |
| 29811–29814 | tcp | manage / adopt / upgrade / v5 manage |

**What it changes:** the AP's controller address becomes `192.168.2.82` (or `omada.internal`
repointed to it). Nothing else in the design moves — `omada_network`, `omada_wlan_group` and
`omada_wireless_network` keep working, they just talk to a different `TF_VAR_omada_url`.

**What it costs:** hostNetwork bypasses NetworkPolicy, so those ports are open on the platform node
and should be scoped by the node firewall if that ever matters. The controller is not on the
critical path — if it is down the AP keeps running its last configuration — so a single replica on
one node is the right availability target, not HA.

**Migration order:** adopt the AP against the current controller first (so the wireless config
exists), then move the controller, then repoint `omada.internal` and the provider's URL. Moving it
first would mean adopting twice.

---

## Parked 2026-11-01

The controller was removed from the laptop and this root was **not** applied beyond
`omada_network.clients`. The wireless side is being configured by hand on the AP instead.

What was learned, so it is not re-learned:

- **The provider needs the site name exactly.** A site at the controller is often not *primary*,
  and the provider refuses to guess. The log truncates names, so it read `bakuran` when the site
  was `bakuransite` — an hour lost to a guess that looked confirmed.
- **Site listing came back empty until the site existed.** Fine now, but it made "no site named"
  look like an auth failure when the credentials were valid all along.
- **`wlan_group` cannot be created when the site already has a `Default` group**
  (`omada api error -33200`), and importing it needs `<site>/<group-uuid>` — the uuid is not
  exposed by any data source, so it has to come from the browser's network tab or the Open API.
  The Open API needs its **own** app credential (Client ID + Secret, mode *Client Credentials*),
  which the UI shows only at creation.
- **Mongo is wire version 6** (MongoDB ≤ 4.0), and every `mongosh` in nixpkgs refuses it, so the
  controller's database cannot be read for ids either.
- If this is ever revived: **run the controller in the cluster** (hostNetwork, node pin, Longhorn
  PVC) rather than on a laptop — the address moved three times in one day and took the UI with it.
