{ pkgs, ... }:
# The 10.15 rehearsal, with the one difference the first attempt could not cover: **NetworkManager** owning the
# node's default route, as it does on `.82`.
#
# Why this variant exists: on 2026-11-15 the activation was rehearsed against a static default route and the
# node never stranded (120/120 pings, rules at the explicit priorities throughout). But that guest used
# scripted networking, and H1 is specifically a race between the tunnel unit's two rules and NetworkManager
# re-installing a proto-static default. Same routing shape, different owner of the route - so the first
# rehearsal tested the shape without testing the suspect.
#
# What is still not covered: a real Proton endpoint. Proton allows one session per account (10.13) and
# production holds it, so this guest keeps the placeholder endpoint and therefore never handshakes. That means
# this guest can disprove H1 (rules/routes) and still cannot exercise the datapath.
{
  imports = [ ./election-test.nix ];

  networking.networkmanager = {
    enable = true;
    # NetworkManager must own the LAN interface, or it is not the actor H1 accuses.
    unmanaged = [ "lo" "tap*" ];
  };

  # eth1 is the LAN side (.82 has one interface; this guest has user-net plus the bridge, so eth1 is the
  # analogue of enp8s0). A static default route through it is what .82 has and what the report will compare.
  networking.networkmanager.ensureProfiles.profiles.lan = {
    connection = {
      id = "lan-static";
      type = "ethernet";
      interface-name = "eth1";
      autoconnect = "true";
    };
    ipv4 = {
      method = "manual";
      address1 = "10.10.50.10/24,10.10.50.1";
      dns = "10.10.50.1;";
      "route1" = "0.0.0.0/0,10.10.50.1";
      never-default = "false";
    };
  };

  # Scripted networking would fight NetworkManager for eth1; leave it to NM. The base guest sets useDHCP,
  # so it has to be forced rather than unset - NetworkManager refuses to run alongside it.
  networking.useDHCP = pkgs.lib.mkForce false;
  networking.interfaces = { };
}
