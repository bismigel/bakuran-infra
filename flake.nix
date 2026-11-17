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

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, deploy-rs, sops-nix }:
    let
      # Commands a *host* runs (ADR 0019: a command belongs to the repository that builds the closure it runs inside). They are
      # standard-library-only Go, so there is nothing to vendor and `vendorHash = null` is honest rather than a placeholder.
      eachSystem = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      mkGo = system: name: nixpkgs.legacyPackages.${system}.buildGoModule {
        pname = name;
        version = "0.1.0";
        src = ./.;
        subPackages = [ "cmd/${name}" ];
        vendorHash = null;
        env.CGO_ENABLED = "0";
        ldflags = [ "-s" "-w" ];
        meta.mainProgram = name;
      };
    in {
    packages = eachSystem (system: {
      preflight-wg = mkGo system "preflight-wg";
      verify-backup-copies = mkGo system "verify-backup-copies";
    });

    # Staging guests, from staging/cluster-3node/default.nix (2026-11-13). They used to live in a flake of their own, which
    # meant (a) their `../../modules` imports were outside that flake's root and the tunnel-rehearsal guest could not even be
    # evaluated, and (b) CI's `nix flake check` never saw them. Here they get the same lock file and the same check as
    # production, which is what makes "rehearse in staging" a thing people actually do.
    #
    # Named `staging-*` so a deploy/run command cannot be pointed at the wrong cluster by accident.
    nixosConfigurations = (let
      staging = import ./staging/cluster-3node { inherit nixpkgs; };
    in {
      staging-server = staging.mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; };
      staging-server2 = staging.mk {
        host = "server2"; tap = "agent1"; ip = "10.10.50.11"; role = "server"; mac = "52:54:00:12:36:11";
        serverAddr = "https://10.10.50.10:6443";
      };
      staging-server3 = staging.mk {
        host = "server3"; tap = "agent2"; ip = "10.10.50.12"; role = "server"; mac = "52:54:00:12:36:12";
        serverAddr = "https://10.10.50.10:6443";
      };
      # The two tunnel-rehearsal guests. They reuse tap-server and the server's address, so only one runs at a time.
      staging-native = (staging.mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; })
        .extendModules { modules = [ ./staging/cluster-3node/native-test.nix ]; };
      staging-election = (staging.mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; })
        .extendModules { modules = [ ./staging/cluster-3node/election-test.nix ]; };
          # The same guest with NetworkManager owning the LAN route - .82's shape, and the only configuration in
          # which H1 (a race with NetworkManager's proto-static default) can actually be tested.
          staging-election-nm = (staging.mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; })
            .extendModules { modules = [ ./staging/cluster-3node/election-nm.nix ]; };
    }) // {
      # .81 (Intel i5) — media / arr stack
      calamansi-intel = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit self;
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
          inherit self;
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
          inherit self;
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
    # Lenovo ThinkCentre M700 Tiny (i5-6500T, 16 GB) — replaces kamatis-mbp
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
          # Activation here can restart k3s - changing `nodeLabel` changes the k3s unit - and the default confirmation
          # window is short enough that deploy-rs calls the deploy failed while k3s is still coming back, then rolls back
          # a change that was going to work. Measured twice on 2026-11-14 (both flip attempts); the second one rolled back
          # while `systemctl is-active k3s` said "activating", and the node recovered by itself 90 s later.
          #
          # 300 s is a ceiling, not a target: a normal deploy still confirms in seconds.
          confirmTimeout = 300;
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
          wgIface = ci.networking.wireguard.interfaces.proton0;
          unitScript = ci.systemd.services."wireguard-proton0".script;
          reconcileScript = ci.systemd.services.wireguard-reconcile.script;
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
            assert msg (nixpkgs.lib.hasInfix "while [ \"$i\" -lt 60 ]" postSetup)
              "postSetup lost its retry of the endpoint route. At boot the LAN device has no address yet, `ip route ... via GATEWAY` fails with 'Nexthop has invalid gateway', and because the unit is oneshot the node then boots with no tunnel and no egress (found by rebooting .81, 2026-10-28).";
            # The IPv4-only rule and the endpoint now live in the reconciler, whose `script`
            # is a store path - hasInfix would be searching a filename - so they are read at
            # build time below, along with a guard for the bug that produced this whole detour.
            # THE DECOUPLING, asserted. A peer in the unit carries the endpoint into the unit
            # definition, so replacing a dead server makes switch-to-configuration restart the
            # link - the operation behind seven outages. 176.113.74.82 dying cost a night on
            # 2026-11-03 precisely because of that coupling.
            assert msg (wgIface.peers == [ ])
              "The unit declares a peer again. That puts the endpoint back inside the unit definition, so replacing a dead server restarts the tunnel (NETWORK.md 7.1). Peer/endpoint belong to modules/wireguard-reconcile.nix.";
            assert msg (nixpkgs.lib.hasInfix "/etc/wireguard/endpoint-ip" wgIface.postSetup)
              "postSetup no longer reads /etc/wireguard/endpoint-ip. Interpolating the endpoint IP makes the unit definition change whenever the endpoint does, and activation then restarts the tunnel.";
            # The unit's script must not mention the endpoint at all: if it does, the peer came
            # back and an endpoint change restarts the link again.
            assert msg (!(nixpkgs.lib.hasInfix "84.20.16.29" unitScript))
              "The tunnel unit's script contains the endpoint again; replacing a dead server would restart the link (NETWORK.md 7.1).";
            # The peer's public key is the other half of the same coupling: a peer in the unit
            # brings its endpoint with it. Neither value may appear in the unit's script.
            assert msg (!(nixpkgs.lib.hasInfix ci.bakuran.wireguard.peerPublicKey unitScript))
              "The tunnel unit's script contains the peer public key, so a peer is declared in the unit again - and its endpoint with it.";
            assert msg (ci.environment.etc."wireguard/endpoint-ip".text == "84.20.16.29")
              "/etc/wireguard/endpoint-ip disagrees with bakuran.wireguard.endpoint; postSetup would pin the wrong address.";
            # Tripwire, duplicated on purpose: an independent copy of a fact that also lives in
            # hosts/calamansi-intel/default.nix and NETWORK.md. A check reading the same source it
            # constrains could not fail.
            assert msg (ci.bakuran.wireguard.endpoint == "84.20.16.29:51820")
              "bakuran.wireguard.endpoint must stay the declared/live endpoint.";
            assert msg (builtins.elem "sops-nix.service" nativeUnit.wants && builtins.elem "sops-nix.service" nativeUnit.after)
              "The wireguard-proton0 sops-nix ordering is missing: the unit reads its key from SOPS and would start keyless (outage 7's failure class).";
          # Build-time reads of the generated scripts: `script` is a store path above, so grep is the
          # only way to see the text. A stale copy of this block is what a silently no-op'd edit leaves.
          nixpkgs.legacyPackages.x86_64-linux.runCommand "wireguard-invariants-ok" { } ''
            grep -q "allowed-ips 0.0.0.0/0" ${reconcileScript} || {
              echo "The reconciler no longer sets allowed-ips 0.0.0.0/0 (IPv4-only is deliberate, NETWORK.md 4)." >&2; exit 1; }
            grep -q "84.20.16.29:51820" ${reconcileScript} || {
              echo "The reconciler does not carry the current endpoint (84.20.16.29:51820, the server that answers since 176.113.74.82 died on 2026-11-03)." >&2; exit 1; }
              # An unescaped shell default expansion inside a Nix indented string silently loses
              # its braces: the reconciler's handshake guard rendered as the literal text hs:- ,
              # could never match, and made a fresh interface log 'no handshake for 1793768305s -
              # the endpoint or key is dead'. Escaping is the fix; this grep catches the next one.
            if grep -qE 'case "[a-zA-Z_]+:-' ${reconcileScript}; then
              echo "A shell default expansion lost its dollar-brace wrapper - Nix swallowed it. Escape it in the .nix source." >&2; exit 1
            fi
            touch $out
          '';
      in
      base // {
        x86_64-linux = base.x86_64-linux // { inherit wireguard-invariants; };
      };
  };
}
