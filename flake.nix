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
        hostname = "192.168.2.80";
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
          peer = builtins.head ci.networking.wireguard.interfaces.proton0.peers;
          nativeUnit = ci.systemd.services."wireguard-proton0";
          postSetup = ci.networking.wireguard.interfaces.proton0.postSetup;
          msg = nixpkgs.lib.assertMsg;
          # These replace the wg-quick seed assertions. They encode the reason the
          # seven 2026-10-25 outages happened, so a tidy-up cannot undo the fix:
          # the policy rules MUST carry explicit priorities. Without `pref` the
          # kernel derives a priority from the rule list, and with Cilium's rule at
          # 9 / `local` at 100 the tunnel's rules land at 98/99 - above `local` -
          # and the node stops answering its own IP.
          wireguard-invariants =
            assert msg ci.bakuran.wireguard.useNative
              "calamansi-intel must own the tunnel via networking.wireguard; wg-quick's rules are not priority-pinned (NETWORK.md 7.1).";
            assert msg (!(ci.networking.wg-quick.interfaces ? proton0))
              "The wg-quick interface is back. It recreates the link on every change and its rules land above `local`: the 2026-10-25 outage.";
            assert msg (nixpkgs.lib.hasInfix "rule add pref 32765" postSetup && nixpkgs.lib.hasInfix "rule add pref 32764" postSetup)
              "The tunnel's policy rules lost their explicit priorities. Without `pref` they land at 98/99, above `local` at 100, and the node stops answering its own LAN address (7 outages, 2026-10-25).";
            assert msg (peer.allowedIPs == [ "0.0.0.0/0" ])
              "The tunnel is IPv4-only on purpose (NETWORK.md 4); ::/0 blackholes.";
            assert msg (peer.endpoint == "176.113.74.82:51820")
              "bakuran.wireguard.endpoint must stay the declared/live endpoint.";
            assert msg (builtins.elem "sops-nix.service" nativeUnit.wants && builtins.elem "sops-nix.service" nativeUnit.after)
              "The wireguard-proton0 sops-nix ordering is missing: the unit reads its key from SOPS and would start keyless (outage 7's failure class).";
          nixpkgs.legacyPackages.x86_64-linux.runCommand "wireguard-invariants-ok" { } "touch $out";
      in
      base // {
        x86_64-linux = base.x86_64-linux // { inherit wireguard-invariants; };
      };
  };
}
