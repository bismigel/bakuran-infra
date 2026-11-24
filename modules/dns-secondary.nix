# A second DNS resolver, so name resolution does not depend on the router staying up.
#
# The plan is ADR 0020 in `homelab-context`: the router's Unbound is the only resolver DHCP advertises, on a box with no
# out-of-band console, and one Unbound restart degrades every app that resolves a name — including the cluster, whose
# `coredns` is `forward . /etc/resolv.conf`. This host (.80) runs an identical second one.
#
# Why a host and not a pod: the cluster already depends on DNS, so a resolver inside it would depend on the thing whose
# failure produces the symptom. Why .80 and not .82: .82 is already the single point for the media pool, an ingress
# replica, two CNPG instances and the Argo pane; the fallback belongs somewhere that carries no stateful role.
#
# PHASE 1 OF STORY 4.8 — this resolver is advertised by **nobody**. Kea still hands out 192.168.2.254 only, so this changes
# nothing until that line in `opentofu/opnsense/kea.tf` changes, which is gated on a read-back (see the ADR: `dns_servers`
# is a Set in the provider, so order is not preserved and the router must come first).
{ config, lib, ... }:

let
  listen = "192.168.2.80";

  # Who may ask. The whole point of this resolver is that it can be used *while diagnosing*, so the operator's own segment
  # has to be in here: `192.168.20.0/24` is VLAN 20, where the admin laptop sits (measured 2026-11-19: this workstation is
  # 192.168.20.50, and the first version of this module accepted only the LAN — every query from it timed out).
  #
  # One list drives both the ACL and the firewall rule below, so they cannot drift apart.
  clients = [ "192.168.2.0/24" "192.168.20.0/24" ];

  # The internal names. This is the only part that has to exist in two places, and it is the reason story 4.8 was never a
  # one-liner: the router answers these from `host_entries.conf` (explicit overrides, plus `dhcpleases.conf` for names it
  # learned from the Kea lease table).
  #
  # Measured on the router 2026-11-19, and each line is traceable to a declared source rather than to a rumour:
  #   * the four hosts — `facts hosts` prints exactly these addresses, from this repository;
  #   * the AP, the Omada controller and the laptop — `opentofu/opnsense/dhcp.tf` reservations;
  #   * jellyfin.lan — `opentofu/opnsense/unbound.tf`, and it points at the kube-vip LoadBalancer address, not a pod.
  #
  # What cannot be reproduced here is the lease-derived half: a client with no reservation is named only because the router
  # saw it ask for an address. A name that exists only as a lease is not one an outage-critical query depends on, and the
  # failover test asks for `jellyfin.lan` and an external name — both declared. That asymmetry is written down in ADR 0020
  # rather than hidden here.
  internalNames = {
    "jellyfin.lan" = "192.168.2.84";
    "patola-thinkcentre.internal" = "192.168.2.80";
    "calamansi-intel.internal" = "192.168.2.81";
    "sitaw-amd.internal" = "192.168.2.82";
    "kamatis-mbp.internal" = "192.168.2.83";
    "eap650.internal" = "192.168.2.2";
    "omada-controller.internal" = "192.168.2.60";
    "admin-laptop.internal" = "192.168.20.50";
  };
in {
  services.unbound = {
    enable = true;

    # This host keeps using the router for its own lookups. Pointing the host at its own resolver would mean a bug in this
    # unit takes the node's resolution with it — and on an etcd member that is a way to lose quorum to a DNS change.
    resolveLocalQueries = false;

    settings.server = {
      interface = [ "127.0.0.1" listen ];

      # Only the LAN and itself. The firewall below already drops everything else; this is the second lock, because a
      # resolver that answers recursion to strangers is an amplifier.
      access-control = [ "127.0.0.0/8 allow" ] ++ map (c: "${c} allow") clients ++ [ "0.0.0.0/0 refuse" ];

      # The same kind of resolver as the router's: recursive, DNSSEC-validating (the module sets
      # auto-trust-anchor-file with `enableRootTrustAnchor`), no forwarders. That is what makes the two interchangeable —
      # either can be the only resolver and the behaviour does not change.
      qname-minimisation = true;
      hide-identity = true;
      hide-version = true;

      # `transparent`, matching the router's `local-zone: "internal" transparent`: names in `local-data` answer locally,
      # anything else still resolves upstream. A `static` zone here would answer NXDOMAIN for a name the router knows
      # better, which is a behaviour difference exactly when the router is the one that is down.
      local-zone = [ "\"internal.\" transparent" "\"lan.\" transparent" ];
      # The quotes are required, not decorative: unbound takes the whole `name IN A addr` as one value and refuses an
      # unquoted one ("unknown keyword '192.168.2.80'"). The NixOS renderer does not add them, and `unbound-checkconf`
      # on the generated file is what caught it before this unit ever started on the host.
      local-data = lib.mapAttrsToList (name: ip: "\"${name} IN A ${ip}\"") internalNames;
    };
  };

  # 53 from the declared clients, and from nowhere else. The base module keeps `allowedTCPPorts` empty on purpose
  # (2026-10-29): a port list accepts from any source, including a compromised container on the pod network.
  networking.firewall.extraCommands = lib.concatMapStrings (c: ''
    iptables -I nixos-fw 1 -p udp -s ${c} --dport 53 -j nixos-fw-accept
    iptables -I nixos-fw 1 -p tcp -s ${c} --dport 53 -j nixos-fw-accept
  '') clients;
}
