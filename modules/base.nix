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
  boot.kernelModules = [ "iscsi_tcp" ];
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
    9100
  ];
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
