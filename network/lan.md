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
| Ollama host (ZeroClaw fallback) | 192.168.2.12 | — | — |

> The three cluster hosts set their IP **statically** in NixOS (`hosts/*/default.nix`),
> so the reservations are belt-and-braces (keep the router DHCP pool from handing
> those addresses out). `.245` and `.12` are DHCP/external.
