{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    k3s
    kubectl
    helm
    k9s
  ];
}
