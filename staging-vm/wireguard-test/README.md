# WireGuard full-tunnel activation test

One disposable guest, one question:

> When `wg-quick` activates a full-tunnel interface whose **endpoint is dead**,
> does the host lose all IP connectivity (kill-switch rules survive with no
> working tunnel), or only the internet?

Context: on 2026-10-25 the media node became unreachable five times with the
signature "ARP answers, nothing above L2", and only a power-cycle recovered it.
Every one of those followed a `wg-quick-proton0` activation during a window when
Proton's endpoint had rotated and stopped answering.

## Run

```bash
NIX_PATH=nixpkgs=channel:nixos-unstable nix-build default.nix -o result
./result/bin/run-nixos-vm -nographic      # serial console carries the whole test
```

The guest boots, waits 20 s, dumps `ip rule`, the route to the dead endpoint and
the addresses, **restarts `wg-quick-proton0`**, waits again, then dumps the
ruleset, routes, link state and a ping to its gateway, and powers off.

## Reading it

| Result | Meaning |
|---|---|
| `LAN: reachable` after the restart | activation is safe; the production outage was something else |
| `LAN: DEAD` + rules present in `51820` with no working link | **kill-switch confirmed**: `wg-quick` leaves the host unusable when the tunnel cannot come up |
| no output at all | the guest hung during the restart — the kernel-hang hypothesis |

Nothing here touches the homelab; the endpoint is TEST-NET-3 and the key is a
throwaway.

## Result (2026-10-25, first run)

```
=== WGTEST restart wg-quick-proton0 ===
restart: ok
=== WGTEST after ===
--- ip rule ---             (unchanged: suppress_prefixlength 0 still present)
--- table 51820 ---         default dev proton0 scope link
--- main default ---        default via 10.0.2.2 dev eth0     (intact)
--- link ---                proton0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420
--- ping gateway ---        LAN: reachable
```

**The guest keeps its LAN after restarting a full-tunnel interface whose endpoint
is dead.** So the kill-switch hypothesis is wrong: on plain NixOS, `wg-quick`
activation during a dead-endpoint window costs egress, not connectivity.

That means the production outages came from something this guest does not have:

1. **k3s / Cilium / kube-proxy** - Cilium owns the datapath (eBPF) and kube-proxy
   rewrites iptables; `wg-quick` runs `iptables-restore -n` on every activation,
   which is exactly the kind of thing that can leave a half-synced ruleset. This
   is the top suspect and it is the reason the three-node `staging-vm` cluster
   exists.
2. cloudflared, or the IO load of the media stack - both absent here.

Next iteration: run the same experiment inside a single-node k3s + Cilium guest.
Until that reproduces, no further `deploy-rs` on the media node.

## Result 2: with k3s running (2026-10-25)

Same experiment, guest now running `services.k3s` (server, kube-proxy active,
flannel up — note `flannel.1` in the interface list):

```
restart: ok
--- ip rule ---     unchanged
--- table 51820 --- default dev proton0 scope link
--- main default --- default via 10.0.2.2 dev eth0   (intact)
--- ping gateway --- LAN: reachable
```

**Still no reproduction.** So kube-proxy rewriting iptables is not the trigger
either.

That leaves exactly one meaningful datapath difference between this guest and the
production media node: **Cilium** (eBPF, kube-proxy replacement), plus the
environmental factors the guest has none of — cloudflared, and the IO load of the
media stack.

Next iteration: add Cilium to this guest (`--flannel-backend=none`,
`--disable-kube-proxy`, helm install) and rerun. Until then the honest position is
that the 2026-10-25 outages are **unexplained**, and no change should be deployed
to the media node on the strength of a theory.
