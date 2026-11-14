# Three-node staging cluster

This is the disposable cluster base used to validate control-plane changes
before production. It is three NixOS QEMU VMs on a private `192.168.102.0/24`
bridge, with one k3s server and two agents.

It needs a Linux host with KVM and root for the bridge and tap devices. Do not
run it on the production cluster.

## Build

The guests are configurations of the **repo-root flake** since 2026-11-13. They used to live here as their own flake, which
had two consequences: `native-test.nix` imports `../../modules/*` — outside that flake's root — so the tunnel-rehearsal
guest could not be evaluated at all, and CI's `nix flake check` never saw any of them.

```bash
nix build .#nixosConfigurations.staging-server.config.system.build.vm
nix build .#nixosConfigurations.staging-server2.config.system.build.vm
nix build .#nixosConfigurations.staging-server3.config.system.build.vm
nix build .#nixosConfigurations.staging-native.config.system.build.vm    # real tunnel module, dead endpoint
nix build .#nixosConfigurations.staging-election.config.system.build.vm  # the same, with lease election (10.14)
```

One lock file, one `nix flake check`, and the modules are simply inside the root. Production derivations are unchanged by
this move — verified by comparing `drvPath` for all three hosts before and after.

## Network

On the VM host, as root:

```bash
ip link add br-staging type bridge
ip addr add 192.168.102.1/24 dev br-staging
ip link set br-staging up
for t in tap-server tap-agent1 tap-agent2; do
  ip tuntap add "$t" mode tap
  ip link set "$t" master br-staging
  ip link set "$t" up
done
```

Start the outputs in order: server, then agents.

```bash
./result/bin/run-server-vm
./result-1/bin/run-agent1-vm
./result-2/bin/run-agent2-vm
```

SSH is forwarded on `2222`, `2223` and `2224`; the API is on `6455`.

## Why Flannel is explicit

The VMs have two interfaces. Without `--flannel-iface=eth1`, k3s picked the QEMU
NAT interface and cross-node pod traffic broke. Keep that flag.

## Intended use

- reproduce a control-plane or CNI change;
- test an upgrade before production;
- run destructive experiments with no production data.

`admin.pub` is a public key only. Replace it with your own before using the
cluster for anything beyond testing.
