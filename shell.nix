{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    kubectl
    helm
    k9s
    sops
    age
    vim
    git
  ];
}
