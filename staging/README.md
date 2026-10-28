# Staging

Disposable environments for changes that are too dangerous to try on the cluster
that holds etcd, the media library and every credential. Nothing here is
production, nothing here is backed up, and nothing here should be reachable from
production.

## What exists

| Directory | Shape | Use it for |
|---|---|---|
| `cluster-3node/` | 3 NixOS QEMU VMs (server + 2 agents) on `192.168.102.0/24`, k3s with **flannel** | control-plane changes that are not about the CNI: k3s flags, etcd behaviour, upgrades, ArgoCD |
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

## Known gaps

- `cluster-3node` uses **flannel**, production uses **Cilium**. It is fine for
  control-plane work and wrong for CNI work — for those, start from the
  `wireguard-test` VM's Cilium setup instead.
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
