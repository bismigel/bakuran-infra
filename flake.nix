{
  description = "Bakuran SOSYAL - NixOS k3s cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix/49087bdf94a2";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, deploy-rs, sops-nix }: {
    nixosConfigurations = {
      # .81 (Intel i5) — media / arr stack
      calamansi-intel = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+soIiTQA3y96cqgaPluR9i9Z9qCdypdSfH/w0KiYrb labanos@bakuran";

          unstable = nixpkgs-unstable;
        };
          modules = [
            ({ pkgs, ... }: {
              sops.package = pkgs.callPackage "${sops-nix}/pkgs/sops-install-secrets" {
                vendorHash = "sha256-SXOd+0yh0DQr3uLVQBdw07J9j5HNuFJSOajDul1B1qo=";
              };
            })
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

          unstable = nixpkgs-unstable;
        };
          modules = [
            ({ pkgs, ... }: {
              sops.package = pkgs.callPackage "${sops-nix}/pkgs/sops-install-secrets" {
                vendorHash = "sha256-SXOd+0yh0DQr3uLVQBdw07J9j5HNuFJSOajDul1B1qo=";
              };
            })
            sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/sitaw-amd/default.nix
        ];
      };

      # MacBook Pro 13" Mid-2012 (kamatis-mbp) — 3rd k3s server (etcd quorum)
      kamatis-mbp = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+soIiTQA3y96cqgaPluR9i9Z9qCdypdSfH/w0KiYrb labanos@bakuran";

          unstable = nixpkgs-unstable;
        };
          modules = [
            ({ pkgs, ... }: {
              sops.package = pkgs.callPackage "${sops-nix}/pkgs/sops-install-secrets" {
                vendorHash = "sha256-SXOd+0yh0DQr3uLVQBdw07J9j5HNuFJSOajDul1B1qo=";
              };
            })
            sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/kamatis-mbp/default.nix
        ];
      };
    # Lenovo ThinkCentre M900 Tiny (i5-6500T, 16 GB) — replaces kamatis-mbp
    # as the 3rd k3s server / etcd member. Deliberately not tainted: schedulable.
    patola-thinkcentre = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+soIiTQA3y96cqgaPluR9i9Z9qCdypdSfH/w0KiYrb labanos@bakuran";

        unstable = nixpkgs-unstable;
      };
        modules = [
          ({ pkgs, ... }: {
            sops.package = pkgs.callPackage "${sops-nix}/pkgs/sops-install-secrets" {
              vendorHash = "sha256-SXOd+0yh0DQr3uLVQBdw07J9j5HNuFJSOajDul1B1qo=";
            };
          })
          sops-nix.nixosModules.sops
        disko.nixosModules.disko
        ./hosts/patola-thinkcentre/default.nix
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
      patola-thinkcentre = {
        hostname = "192.168.2.84";
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.patola-thinkcentre;
        };
      };
        kamatis-mbp = {
          hostname = "192.168.2.83";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.kamatis-mbp;
          };
        };
      };
    };

    # Invariants that have cost real outages. These are assertions, not prose:
    # they fail `nix flake check` (and therefore CI) if a well-meaning "tidy up"
    # changes them. See NETWORK.md 7.1/7.4 and runbook 14.
    checks =
      let
        base = builtins.mapAttrs
          (system: deployLib: deployLib.deployChecks self.deploy)
          deploy-rs.lib;
        ci = self.nixosConfigurations.calamansi-intel.config;
        seed = builtins.head ci.networking.wg-quick.interfaces.proton0.peers;
        wgOverride = ci.systemd.services."wg-quick-proton0";
        msg = nixpkgs.lib.assertMsg;
        wireguard-invariants =
          assert msg (seed.allowedIPs == [ "0.0.0.0/0" "::/0" ])
            "The wg-quick seed must keep ::/0. It has to stay byte-identical to the running generation, otherwise activation restarts wg-quick and strands .81 (7 outages). The reconciler enforces IPv4-only at runtime.";
          assert msg (seed.endpoint == "205.142.240.210:51820")
            "The wg-quick seed must stay on the previous endpoint; the reconciler owns the live one (176.113.74.82).";
          assert msg (seed.publicKey == "/HvEnSU5JaswyBC/YFs74eGLXqLdzsaFeVT8SD1KYAc=")
            "The wg-quick seed peer changed. It must match the running generation or activation restarts the tunnel.";
          assert msg (builtins.elem "sops-nix.service" wgOverride.wants && builtins.elem "sops-nix.service" wgOverride.after)
            "The wg-quick-proton0 sops-nix ordering is missing. Dropping it changes the unit, restarts wg-quick and strands .81 (this was outage 7).";
          assert msg (ci.bakuran.wireguard.endpoint == "176.113.74.82:51820")
            "bakuran.wireguard.endpoint must stay the declared/live endpoint.";
          assert msg (ci.bakuran.wireguard.useNative == false)
            "The networking.wireguard migration must stay inert until its maintenance window (runbook 14).";
          nixpkgs.legacyPackages.x86_64-linux.runCommand "wireguard-invariants-ok" { } "touch $out";
      in
      base // {
        x86_64-linux = base.x86_64-linux // { inherit wireguard-invariants; };
      };
  };
}
