{ pkgs ? import <nixpkgs> { } }:
# Single disposable guest that answers one question:
#
#   When wg-quick activates a FULL-TUNNEL interface whose endpoint is dead, does
#   the host lose IP connectivity entirely (kill-switch rules survive with no
#   working tunnel), or does it merely lose internet?
#
# Production symptom on 2026-10-25: ARP answered, ICMP/TCP/SSH did not, and only
# a power-cycle recovered it - on a node with no out-of-band access.
#
# Build:  NIX_PATH=nixpkgs=channel:nixos-unstable nix-build default.nix -o result
# Run:    ./result/bin/run-nixos-vm -nographic      (serial console carries the test)
let
  # throwaway key; the endpoint is TEST-NET-3 so nothing ever answers
  fakeKey = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=";
  config = { lib, ... }: {
    imports = [ <nixpkgs/nixos/modules/virtualisation/qemu-vm.nix> ];

    networking.wg-quick.interfaces.proton0 = {
      privateKeyFile = "/etc/wg-test.key";
      address = [ "10.2.0.2/32" ];
      autostart = true;
      peers = [{
        # arbitrary but valid public key; the endpoint never answers
        publicKey = "nLx6LJgXWOtnlKV65ruYMGjiw4DERImZGCpN3lolm1I=";
        allowedIPs = [ "0.0.0.0/0" ];       # same shape as production
        endpoint = "203.0.113.1:51820";     # TEST-NET-3: guaranteed dead
        persistentKeepalive = 25;
      }];
    };
    environment.etc."wg-test.key".text = fakeKey;

    networking.firewall.enable = false;     # keep nftables out of the experiment
    services.openssh.enable = true;

    systemd.services.wgtest = {
      wantedBy = [ "multi-user.target" ];
      after = [ "wg-quick-proton0.service" "network-online.target" ];
      wants = [ "wg-quick-proton0.service" ];
      script = ''
        set +e
        sleep 20
        exec > /dev/console 2>&1
        echo "=== WGTEST baseline ==="
        ip rule show
        ip route get 203.0.113.1
        ip -br addr
        echo "=== WGTEST restart wg-quick-proton0 ==="
        systemctl restart wg-quick-proton0 && echo "restart: ok" || echo "restart: FAILED"
        sleep 20
        echo "=== WGTEST after ==="
        echo "--- ip rule ---"; ip rule show
        echo "--- table 51820 ---"; ip route show table 51820
        echo "--- main default ---"; ip route show default table main
        echo "--- link ---"; ip link show proton0 2>&1 | head -2
        echo "--- ping gateway from guest ---"
        gw=$(ip route show default table main | awk '{print $3; exit}')
        ping -c 2 -W 2 "$gw" >/dev/null 2>&1 && echo "LAN: reachable" || echo "LAN: DEAD"
        echo "=== WGTEST done ==="
        poweroff
      '';
      serviceConfig.Type = "oneshot";
      # systemd units get a minimal PATH: without this the script dies with
      # "ip: command not found" and the test never runs
      path = with pkgs; [ iproute2 iputils gawk coreutils wireguard-tools systemd ];
    };

    virtualisation = { memorySize = 1024; cores = 2; diskSize = 2048; graphics = false; };
    system.stateVersion = "25.11";
  };
in
  (import <nixpkgs/nixos> { configuration = config; }).config.system.build.vm
