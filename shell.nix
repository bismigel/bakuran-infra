{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    k9s
    helm
    kubectl
    sops
    age
    vim
    curl
    git
    nixos-rebuild
  ];
}
