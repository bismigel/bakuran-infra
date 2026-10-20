# Three-node staging cluster

This is the disposable cluster base used to validate control-plane changes
before production. It is three NixOS QEMU VMs on a private `192.168.102.0/24`
bridge, with one k3s server and two agents.

It needs a Linux host with KVM and root for the bridge and tap devices. Do not
run it on the production cluster.

## Build

```bash
nix build --impure \
  "path:$PWD#nixosConfigurations.server.config.system.build.vm" \
  "path:$PWD#nixosConfigurations.agent1.config.system.build.vm" \
  "path:$PWD#nixosConfigurations.agent2.config.system.build.vm" \
  -o result
```

The build creates `server.qcow2`, `agent1.qcow2` and `agent2.qcow2` in this
directory.

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

SSH is forwarded on `2222`, `2223` and `2224`; the API is on `6444`.

## Why Flannel is explicit

The VMs have two interfaces. Without `--flannel-iface=eth1`, k3s picked the QEMU
NAT interface and cross-node pod traffic broke. Keep that flag.

## Intended use

- reproduce a control-plane or CNI change;
- test an upgrade before production;
- run destructive experiments with no production data.

`admin.pub` is a public key only. Replace it with your own before using the
cluster for anything beyond testing.
