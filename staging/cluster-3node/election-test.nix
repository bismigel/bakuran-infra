{ pkgs, ... }:
# Boots the REAL tunnel module WITH the lease election enabled (story 10.14), so the thing staging has not rehearsed can be:
# the ACTIVATION.
#
# The prototype proved the mechanism (lease, fencing, teardown) with a dummy interface. What it could not prove is the
# transition: turning election on changes the definition of `wireguard-proton0.service` (the key moves from a file to /run,
# the boot pull moves from the target to the elector), so `switch-to-configuration` will RESTART that unit - and that restart
# is the operation that stranded `.81` seven times (NETWORK.md §7.1). It is why `preflight-wg.sh` refuses the flip on a
# running node.
#
# Run it:   nix build ".#nixosConfigurations.staging-election.config.system.build.vm" -o result
#           ./result/bin/run-*-vm
# Then:
#   k3s kubectl -n kube-system create secret generic wg-proton-private-key \
#     --from-literal=private-key="$(cat /etc/wg-test.key)"
#   systemctl start tunnel-election && journalctl -fu tunnel-election
#
# What to look for:
#   * the guest stays reachable over the tap while activation restarts the tunnel unit (the stranding failure);
#   * `systemctl show wireguard-proton0 -p WantedBy` no longer pulls it in at boot, and the elector starts it instead;
#   * with the DEAD endpoint below, the handshake gate refuses `egress-node` and stops the tunnel - correct, and it is what
#     keeps a bad key from pointing the egress policy at a tunnel-less node;
#   * with a live peer (point `endpoint` at the workstation's wireguard interface) the label appears and `wg show` reports a
#     handshake: the success path.
{
  imports = [ ./native-test.nix ../../modules/wireguard-election.nix ];

  bakuran.wireguard.election = {
    enable = true;
    # One node, so there is nothing to contend with - the point is the transition, not the arbitration.
    duration = 10;
  };

  # The elector needs the API; make the ordering explicit rather than implied by k3s.
  systemd.services.tunnel-election.wants = [ "k3s.service" ];

  environment.systemPackages = with pkgs; [ kubectl jq wireguard-tools ];
}
