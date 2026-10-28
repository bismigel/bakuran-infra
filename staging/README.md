# Staging

Disposable environments for changes that are too dangerous to try on the cluster
that holds etcd, the media library and every credential. Nothing here is
production, nothing here is backed up, and nothing here should be reachable from
production.

## What exists

| Directory | Shape | Use it for |
|---|---|---|
| `cluster-3node/` | 3 NixOS QEMU VMs on `10.10.50.0/24` over `br-staging`, k3s with **Cilium v1.20.3** (same digest as production), kube-proxy enabled | **datapath** changes: CNI behaviour, WireGuard, egress policy, plus control-plane work |
| `deck/` | Single-node NixOS k3s on a Steam Deck, non-overlapping pod/service CIDRs | a node you can carry, wipe and re-image without touching the rack |
| `../staging-vm/wireguard-test` (older, kept as-is) | 1 VM with **Cilium** + WireGuard client | the WireGuard question: what a `wg-quick` recreate does to a Cilium node |

`host.nix` in this directory turns a NixOS host into a **staging host**: KVM, the
`br-staging` bridge and the tap devices the VM runners expect. The MacBook
(`kamatis-mbp`, `.83`) is that host, and is no longer a cluster node.

## Why the inputs matter more than the outputs

Two facts about this lab make staging worth the effort:

1. **Production's failure modes are network-shaped.** Seven outages came from a
   `wg-quick` restart; one mysterious one came from a pod being handed an address
   the host already owned. Neither is reproducible by reading config.
2. **Every risky change is blocked on "we cannot try this anywhere".** That is
   the actual reason the WireGuard-native migration and the egress policy are
   still not done.

## Topology

```
kamatis-mbp (.83) — staging host, no longer a cluster node
  br-staging 10.10.50.1/24
    ├── stg-cp    10.10.50.10    k3s server
    ├── stg-w1    10.10.50.11    k3s agent
    └── stg-edge  10.10.50.12    WireGuard client (the .81 role)
```

CIDR discipline, and it is not optional:

| Range | Production | Staging |
|---|---|---|
| Pods | `10.42.0.0/16` | `10.52.0.0/16` |
| Services | `10.43.0.0/16` | `10.53.0.0/16` |
| Cluster addresses | `192.168.2.0/24` | `10.10.50.0/24` |

If these overlap, a stray route or a shared WireGuard config produces
intermittent "which cluster am I debugging" failures that cost days.

## Rules

- **Staging never sees production secrets.** No `sops` key from a production
  host, no BWS project with production items. Generate throwaway credentials.
- **Staging never mounts `/mnt/media` writable.** Read-only at most.
- **Staging is cattle.** Build it, break it, destroy it. Do not hand-edit a VM
  and then rely on it.
- **Nothing in staging is exposed publicly.** No tunnel, no Access application.
  If one is ever needed, use `*.stg.bismigel.dev` and a separate tunnel.

## Production parity (2026-10-28)

`cluster-3node` was rewritten to mirror production's datapath, because the
questions that matter here are all datapath questions:

| Property | Production | Staging |
|---|---|---|
| CNI | Cilium v1.20.3 `@sha256:95cfa5c…` | same digest |
| Mode | tunnel / vxlan | same |
| IPAM | kubernetes | same |
| kube-proxy | enabled (`kubeProxyReplacement=false`) | enabled |
| Pod / service CIDR | 10.42 / 10.43 | **10.52 / 10.53** (never overlapping) |
| NodePorts | loopback only | same |
| NICs | LAN + tunnel | LAN on `br-staging` + `eth0` as the WAN |

Two things that were broken until then and are worth not reintroducing:
guests were addressed `192.168.102.0/24` while the bridge is `10.10.50.0/24`
(the host could not reach its own VMs), and the guest's default route pointed at
the LAN instead of the WAN — so the guest had no internet and no tunnel path.

## Known gaps

- **No WireGuard interface yet.** `cluster-3node` has the NICs and the CNI, but not
  the `wg-quick` full-tunnel config that makes `.81` strand. That is the next piece
  needed for the WireGuard migration rehearsal.
- No ArgoCD, no application manifests: staging proves infrastructure, not apps.
- No staging automation yet: no Cloudflare tunnel, no ArgoCD, no app manifests.
  It proves *infrastructure* behaviour, not application behaviour.
- No snapshot/restore. A broken VM is deleted, not repaired.

## Running it

On the staging host (`.83`):

```bash
# bridge + taps (idempotent, runs at boot via staging-bridge.service)
systemctl status staging-bridge

# build the three VM runners
cd staging/cluster-3node
nix build --impure "path:$PWD#nixosConfigurations.server.config.system.build.vm" \
                       "path:$PWD#nixosConfigurations.agent1.config.system.build.vm" \
                       "path:$PWD#nixosConfigurations.agent2.config.system.build.vm"

# start in order; SSH on 2222/2223/2224, API on 6455
./result/bin/run-server-vm &
./result-1/bin/run-agent1-vm &
./result-2/bin/run-agent2-vm &
```

Do not run the VM runners on a production node: they create tap devices and take
memory that the kubelet does not account for.

## Rehearsal log

### 2026-10-28 — Cilium `k8sServiceHost` from a node IP to the API VIP

**Question.** Production runs `kube-vip` holding `192.168.2.100:6443`, but Cilium's
`k8sServiceHost` still names one node (`.82`). Pointing it at the VIP would make the
CNI independent of that node — but it rolls the Cilium DaemonSet, and a CNI rollout
is not something to try first in the lab.

**Setup.** The `server` VM (rebuilt with `--tls-san=10.10.50.100` and a
`rehearsal-vip` oneshot that puts `10.10.50.100/32` on `eth1`, standing in for
kube-vip's leader-elected address) + Cilium installed by Helm with
`kubeProxyReplacement=false`, matching production.

**Results.**

| Step | Outcome |
|---|---|
| Baseline `k8sServiceHost=192.168.102.10` | agent Running, `KUBERNETES_SERVICE_HOST=192.168.102.10` |
| `helm upgrade` with `k8sServiceHost=10.10.50.100` | DaemonSet rolled; agent back **Running in ~20 s**, `HOST=10.10.50.100`, node Ready |
| VIP removed while running | agent **stayed Running (0 restarts)**, node Ready, 28 error lines in the log, recovered when the VIP returned |
| **Cold start with no VIP** (delete the agent) | **stalls in `Init:0/6`** and retries (restart count 1 at +80 s) |
| VIP restored | agent **Running within 10 s**, no further restarts |

**Conclusion.** The change is safe *because* the VIP exists and is reachable:
a running agent tolerates the VIP disappearing, and a starting one waits for it.

**The one ordering constraint this creates:** on a cold cluster boot, Cilium agents
cannot finish initialising until the VIP exists. `kube-vip` runs `hostNetwork`, so
its pods start without CNI and claim the address — that is why this works, and it
is worth knowing before changing anything about how kube-vip is scheduled.

**Recovery if an agent ever stalls in `Init`:** restore the VIP, or temporarily
patch the DaemonSet's `KUBERNETES_SERVICE_HOST` back to a node IP. Both are
minutes, and neither requires rebuilding the cluster.

**Not covered by this rehearsal:** the datapath (the VM still had flannel, so this
tested the agent's API client, not CNI behaviour), multi-node VIP failover, and
the `.81` egress path.

### 2026-10-28 — the stranding reproduces in staging

**The question.** On 2026-10-25 the media node went off the network seven times,
always after a `wg-quick` link recreate: ARP still answered, nothing above L2, and
only a power-cycle recovered it. Nobody has ever explained it.

**Setup.** The `server` VM (Cilium v1.20.3, kube-proxy enabled, `10.10.50.10` on
`br-staging`, default route on `eth0` = the WAN), plus a `wg-quick` interface
matching production's shape: full tunnel, `0.0.0.0/0`, dead endpoint
(`203.0.113.1:51820`), keepalive 25.

**Safety.** A `systemd-run --on-active=150` timer inside the guest tears the tunnel
down on a schedule, so a stranding cannot lock the test out — a local timer does not
depend on the network.

**Result — reproduced, first try.**

| Observation | Value |
|---|---|
| guest process | alive (qemu running, serial console responsive) |
| LAN reachability from the host | **dead** (ping and SSH both fail) |
| L2 | MAC learned and present on the bridge, neighbour entry `DELAY`/`STALE` |
| ICMP | never returns |
| `wg-quick down` from inside (the armed timer) | **fired, and did not recover** |

That is production's symptom, in a VM, on the first attempt: **the node loses L3
while its link stays up**, and tearing the tunnel down does not bring it back.

**What this changes.** The question was previously blocked on "needs hardware we do
not have". It does not: a Cilium-bearing VM with two NICs reproduces it. The next
steps are bisection, each one run in this same guest:

1. stop Cilium (`kubectl -n kube-system scale ds/cilium --replicas=0`) → repeat
2. remove the `proton0` interface from the equation (plain `ip link add/del` of a
   dummy with the same routes and rules) → repeat
3. drop the fwmark rules only → repeat
4. drop the endpoint pin only → repeat

The first variant that does *not* strand names the component. Until that is known,
`networking.wireguard` must not be enabled in production: it replaces the unit,
which stops `wg-quick` — the same link delete — and could strand the node the same
way during the migration itself.
