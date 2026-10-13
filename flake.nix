{
  description = "Bakuran SOSYAL - NixOS k3s cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix/5a7d18b5c55642df5c432aadb757140edfeb70b3";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, deploy-rs, sops-nix }: {
    nixosConfigurations = {
      # .81 (Intel i5) — media / arr stack
      calamansi-intel = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+soIiTQA3y96cqgaPluR9i9Z9qCdypdSfH/w0KiYrb labanos@bakuran";
        };
        modules = [
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/calamansi-intel/default.nix
        ];
      };

      # .82 (Ryzen 5 4600G) — hosting + ArgoCD
      sitaw-amd = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+soIiTQA3y96cqgaPluR9i9Z9qCdypdSfH/w0KiYrb labanos@bakuran";
        };
        modules = [
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/sitaw-amd/default.nix
        ];
      };
    };

    # Push-based OS deploys:  nix run github:serokell/deploy-rs -- .#sitaw-amd
    deploy = {
      sshUser = "root";
      user = "root";
      nodes = {
        calamansi-intel = {
          hostname = "192.168.2.81";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.calamansi-intel;
          };
        };
        sitaw-amd = {
          hostname = "192.168.2.82";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.sitaw-amd;
          };
        };
      };
    };

    checks = builtins.mapAttrs
      (system: deployLib: deployLib.deployChecks self.deploy)
      deploy-rs.lib;
  };
}
