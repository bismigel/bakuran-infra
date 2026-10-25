# LAN / DHCP

Declares the home network layout so it's reproducible (the router's DHCP
reservations are otherwise live-only).

- **LAN:** `192.168.2.0/24`, gateway `192.168.2.1`
- **DNS:** `1.1.1.1`, `8.8.8.8` (set per-host; no local resolver)
- **No inbound port-forwards** — the edge is the Cloudflare Tunnel only.

## Static hosts (create these as DHCP reservations on the router)

| Host | IP | MAC | NIC |
| --- | --- | --- | --- |
| `sitaw-amd` | 192.168.2.82 | `b4:2e:99:d6:84:29` | `enp8s0` |
| `calamansi-intel` | 192.168.2.81 | `10:62:e5:18:d9:43` | `eno1` |
| `kamatis-mbp` | 192.168.2.83 | `40:6c:8f:4c:7f:0c` | `enp1s0f0` |
| `nix-station` (admin box) | 192.168.2.245 | — | — |
| Ollama host (homelab agent fallback) | 192.168.2.12 | — | — |

> The three cluster hosts set their IP **statically** in NixOS (`hosts/*/default.nix`),
> so the reservations are belt-and-braces (keep the router DHCP pool from handing
> those addresses out). `.245` and `.12` are DHCP/external.

## Unknown devices (2026-10-26)

- `192.168.2.32` `fc:b0:de:18:16:5b` — seen on the LAN, **not in the table above**.
  Identify it (smart device / TV / old host?) and either reserve it or remove it.

## Router config backup (single point of failure)

The router at `192.168.2.1` (MAC `0c:ac:8a:d8:49:1a`) is a **SPOF** and its config
is not backed up. Close it:

1. Admin UI → screenshot/export: DHCP reservations (must match the table above),
   any port-forwards (should be **none**), WAN/DDNS settings.
2. Save to `bakuran-infra/network/router/` (gitignore if it holds credentials).
3. Recovery path if it dies: flash the same model, re-enter the reservations
   above, restore **no** port-forwards, then the Cloudflare Tunnel connectors
   re-establish egress on their own (they need no inbound rules).

## DNS correction

"no local resolver" was not quite right: each host runs **systemd-resolved**
(`127.0.0.53`) forwarding to `1.1.1.1`/`8.8.8.8`; cluster pods use CoreDNS, which
forwards to the node's `/etc/resolv.conf`.
