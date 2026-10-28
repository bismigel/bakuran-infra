{ pkgs, ... }:
{
  networking.hostName = "staging-deck";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 6443 ];
    checkReversePath = false;
    trustedInterfaces = [ "cni+" ];
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 REPLACE_WITH_ADMIN_KEY"
  ];

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--cluster-cidr=10.52.0.0/16"
      "--service-cidr=10.53.0.0/16"
      "--disable"
      "traefik"
      "--disable"
      "servicelb"
      "--write-kubeconfig-mode=0644"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    jq
    kubectl
    k9s
  ];

  system.stateVersion = "25.11";
}
