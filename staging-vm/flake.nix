{
  description = "Three-node disposable staging cluster";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      mk = { host, ip, role, serverAddr ? null }: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          ({ pkgs, ... }: {
            system.stateVersion = "25.11";
            networking.hostName = host;
            networking.useDHCP = true;
            networking.interfaces.eth1.ipv4.addresses = [ { address = ip; prefixLength = 24; } ];
            networking.firewall.allowedTCPPorts = [ 22 6443 4240 ];
            networking.firewall.allowedUDPPorts = [ 8472 ];

            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "prohibit-password";
            users.users.root.openssh.authorizedKeys.keyFiles = [ ./admin.pub ];

            services.k3s = {
              enable = true;
              inherit role;
              token = "staging-only";
              serverAddr = serverAddr;
              extraFlags = [
                "--node-ip=${ip}"
                "--flannel-iface=eth1"
              ] ++ (if role == "server" then [
                "--disable" "traefik"
                "--disable" "servicelb"
                "--write-kubeconfig-mode=0644"
                "--advertise-address=${ip}"
                "--tls-san=${ip}"
              ] else [ ]);
            };

            virtualisation = {
              memorySize = 2560;
              diskSize = 16384;
              cores = 2;
              graphics = false;
              diskImage = "./${host}.qcow2";
              forwardPorts = [
                { from = "host"; host.port = (if host == "server" then 2222 else if host == "agent1" then 2223 else 2224); guest.port = 22; }
              ] ++ (if role == "server" then [ { from = "host"; host.port = 6444; guest.port = 6443; } ] else [ ]);
              qemu.options = [
                "-netdev" "tap,id=n,ifname=tap-${host},script=no,downscript=no"
                "-device" "virtio-net-pci,netdev=n"
              ];
            };
          })
        ];
      };
    in {
      nixosConfigurations.server = mk { host = "server"; ip = "192.168.102.10"; role = "server"; };
      nixosConfigurations.agent1 = mk {
        host = "agent1"; ip = "192.168.102.11"; role = "agent";
        serverAddr = "https://192.168.102.10:6443";
      };
      nixosConfigurations.agent2 = mk {
        host = "agent2"; ip = "192.168.102.12"; role = "agent";
        serverAddr = "https://192.168.102.10:6443";
      };
    };
}
