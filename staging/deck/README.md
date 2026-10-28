# Steam Deck staging

Prepared scaffold, not deployed. The production cluster is untouched.

## Layout

- `flake.nix` builds the staging NixOS configuration and a raw EFI image.
- `configuration.nix` installs single-node k3s with non-overlapping pod and
  service CIDRs.
- `hardware.nix` is a placeholder for the Deck's actual disk.
- `scripts/up.sh` deploys NixOS and the staging overlay.
- `scripts/status.sh` checks the node and isolation.
- `scripts/down.sh` powers the Deck off.

## Before first use

1. Write the raw image to the microSD or USB device.
2. Replace the SSH key placeholder in `configuration.nix`.
3. Replace `hardware.nix` with the output of
   `nixos-generate-config` from the Deck.
4. Reserve the Deck IP.
5. Put it on a separate VLAN or guest SSID if possible.
6. Confirm the pod/service CIDRs do not overlap production.
7. Decide whether staging access is port-forward only or a separate tunnel.

## Run

```bash
export DECK_HOST=192.168.2.90
./scripts/up.sh
./scripts/status.sh
./scripts/down.sh
```

The staging overlay currently targets the `status-api` repository.

## Isolation checks

- Production API and NodePorts must be unreachable from the Deck.
- Staging pods must not reach `192.168.2.81`, `.82` or `.83`.
- No staging ingress is created.
- No production ArgoCD application is registered.

## Limits

This is a single-node, disposable environment. It does not test HA, etcd quorum,
node failure or hardware failure. Treat the SD card as disposable and keep no
production secrets on the Deck.
