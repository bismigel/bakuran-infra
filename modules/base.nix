{ config, pkgs, lib, sshPubKey, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      # Key-only. Root login is allowed, but only with an authorized key —
      # no passwords anywhere.
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.calamansi = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [ sshPubKey ];
  };

  # Root SSH access for the admin workstation (rebuild-safe: must be declarative,
  # otherwise a fresh install is unreachable).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILj/syjQTnLwTGNHC4IKec2QXJpzXOExBQKGJI6/p4Mz nix-station-opencode"
  ];

  environment.systemPackages = with pkgs; [
    vim
    curl
    git
    htop
    tree
    wget
    age
    rclone
    openiscsi
    nfs-utils
    util-linux
    e2fsprogs
    xfsprogs
  ];

  # ---- Longhorn (distributed storage) prerequisites ----
  # open-iscsi initiator + iscsid; Longhorn attaches volumes over iSCSI.
  boot.kernelModules = [ "iscsi_tcp" "msr" "cpuid" ];
  services.openiscsi = {
    enable = true;
    name = "iqn.2026-10.dev.bismigel:${config.networking.hostName}";
  };
  # Longhorn network ports (iSCSI engine + manager + instance-manager), plus
  # node-exporter (9100): it runs hostNetwork, so Prometheus on another node
  # scrapes it over the LAN at <node>:9100 — open it on every host (incl. the
  # MacBook).
  networking.firewall.allowedTCPPorts = [
    3260 3261 3262 3263 3264
    9500 9501 9502 9503 9504 9505
    9100               # node-exporter (scraped cross-node)
    9102               # kepler (hostNetwork power exporter, scraped cross-node)
    9962               # Cilium agent metrics (hostNetwork, scraped cross-node)
  ];

  # Cilium native routing forwards pod traffic through the host. Trust the
  # veth interfaces and relax reverse-path filtering, as the Cilium NixOS
  # module does.
  networking.firewall.checkReversePath = false;
  networking.firewall.trustedInterfaces = [ "cni+" ];
    # etcd metrics relay (hostNetwork socat on :9101). This host runs the
    # iptables-based NixOS firewall, so extraCommands (not extraInputRules)
    # applies. Accept only the pod CIDR: Prometheus scrapes it, the LAN cannot.
    networking.firewall.extraCommands = ''
      # flannel SNATs cross-node pod egress to the node IP, so allow the three
      # nodes as well as the pod CIDR. Other LAN hosts stay blocked.
      iptables -I nixos-fw 1 -p tcp -m iprange --src-range 192.168.2.81-192.168.2.83 --dport 9101 -j nixos-fw-accept
      iptables -I nixos-fw 1 -p tcp -s 10.42.0.0/16 --dport 9101 -j nixos-fw-accept
    '';

    # Longhorn's containers nsenter into the host and call iscsiadm from PATH;
  # NixOS keeps it in /run/current-system/sw/bin, so expose it under /usr/bin too.
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm  - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/sbin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "d /root/.config 0700 root root -"
  ];

  # R2 credential-backup config (creds + backup age recipient), rendered from
  # SOPS so it survives a rebuild instead of being hand-placed per host.
  sops.secrets."homelab_backup_env" = {
    path = "/root/.config/homelab-backup.env";
    owner = "root";
    mode = "0600";
  };

  system.stateVersion = "24.05";
}
