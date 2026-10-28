{ pkgs, lib, ... }:
# Boots the REAL production module (modules/wireguard-native.nix) rather than a
# hand-rolled shell imitation, and answers the questions the shell test could not:
#
#   1. does the module come up correctly at BOOT, with Cilium's rule already
#      installed (the exact production failure precondition)?
#   2. does it survive 10 restarts of its own unit?
#   3. does stop/start leave stale rules or a stale table?
#   4. does it wait for sops-nix instead of starting keyless (outage 7's class)?
#   5. does the reconciler order itself after the right unit and run cleanly?
#
# Run it: /root/startvm.sh native <runner>   (reuses tap-server: one guest at a time)
let
  fakeKey = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=";
in
{
  imports = [ ../../modules/wireguard-native.nix ../../modules/wireguard-reconcile.nix ];

  # A stand-in for the real sops-nix, deliberately slow, so "the tunnel waited"
  # is observable. If the ordering is missing the tunnel starts before this and
  # comes up keyless.
  systemd.services.sops-nix = {
    description = "stand-in for sops-nix (sleeps, to prove the ordering)";
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.coreutils}/bin/sleep 20"; };
  };

  environment.etc."wg-test.key".text = fakeKey;

  bakuran.wireguard = {
    useNative = true;
    privateKeyFile = "/etc/wg-test.key";
    interface = "proton0";
    endpoint = "203.0.113.1:51820";        # TEST-NET-3: guaranteed dead
    peerPublicKey = "nLx6LJgXWOtnlKV65ruYMGjiw4DERImZGCpN3lolm1I=";
    gateway = "10.0.2.2";                  # qemu user-net gateway on eth0
    device = "eth0";
  };

  # Production order: Cilium is already numbering policy rules when the tunnel
  # comes up. Waiting for the helm install makes that deterministic instead of a
  # race, so a bad result cannot be blamed on boot timing.
  systemd.services."wireguard-proton0" = {
    after = [ "staging-cilium.service" ];
    wants = [ "staging-cilium.service" ];
  };

  systemd.services.native-test = {
    description = "Exercise the native tunnel module";
    wantedBy = [ "multi-user.target" ];
    after = [ "wireguard-proton0.service" "staging-cilium.service" ];
    wants = [ "wireguard-proton0.service" "staging-cilium.service" ];
    path = with pkgs; [ iproute2 iputils gawk gnugrep coreutils systemd wireguard-tools ];
    script = ''
      set +u
      exec > /dev/console 2>&1
      # Do NOT rely on unit ordering here: wait for the two conditions this test is
      # about. Cilium's policy rule must exist (it is what poisons `ip rule add`), and
      # the tunnel must actually be up with a key.
      n=0
      while [ $n -lt 90 ]; do ip rule show | grep -q "lookup 2004" && break; n=$((n+1)); sleep 2; done
      echo "=== cilium rule present: $(ip rule show | grep -c 'lookup 2004') after $((n*2))s ==="
      n=0
      while [ $n -lt 90 ]; do wg show proton0 private-key >/dev/null 2>&1 && break; n=$((n+1)); sleep 2; done
      echo "=== tunnel up after $((n*2))s extra ==="
      sleep 2
      echo "=== NATIVE TEST begin ==="
      echo "--- 1. boot state ---"
      ip rule show
      echo -n "203.0.113.1 : "; ip route get 203.0.113.1 | head -1
      echo -n "own ip      : "; ip route get 10.10.50.10 | head -1
      echo -n "8.8.8.8     : "; ip route get 8.8.8.8 | head -1
      echo -n "gw ping     : "; ping -c2 -W2 10.10.50.1 >/dev/null 2>&1 && echo GW-OK || echo GW-FAIL
      echo -n "tunnel key  : "; wg show proton0 private-key 2>/dev/null | cut -c1-6 | sed 's/$/…/'
      echo "--- sops ordering (start times) ---"
      systemctl show -p ExecMainStartTimestamp --value sops-nix.service
      systemctl show -p ExecMainStartTimestamp --value wireguard-proton0.service
      # Production's Cilium installs a policy rule at priority 9 and leaves `local` at
      # 100; staging's Cilium does not create it in this guest, so without this the
      # restarts below would be tested against the BENIGN precondition and prove
      # nothing. Force exactly what production has.
      if ! ip rule show | grep -q "lookup 2004"; then
        ip rule add pref 9 fwmark 0x200/0xf00 table 2004 2>/dev/null
        ip rule add pref 100 table local 2>/dev/null
        ip rule del pref 0 table local 2>/dev/null
        echo "  (forced Cilium rule 9 + local@100: the production precondition)"
      fi
      echo -n "  hostile rule present: "; ip rule show | grep -c "lookup 2004"
      echo -n "  local rule priority : "; ip rule show | awk '/lookup local/ {print $1}' | head -1
      echo "--- 2. ten restarts of the unit ---"
      ok=0; bad=0
      for i in 1 2 3 4 5 6 7 8 9 10; do
        systemctl restart wireguard-proton0
        sleep 3
        if ping -c2 -W2 10.10.50.1 >/dev/null 2>&1; then ok=$((ok+1)); else bad=$((bad+1)); fi
        echo -n "  restart $i: gw ok=$ok bad=$bad  rules: "
        ip rule show | awk '$1 ~ /^(98|99|32764|32765):$/ {printf "%s ", $1} END {print ""}'
      done
      echo "  RESULT restarts: $ok/10 good"
      echo "--- 3. stop/start leaves nothing behind ---"
      systemctl stop wireguard-proton0
      sleep 2
      echo -n "  after stop, stale rules: "; ip rule show | awk '$1 ~ /^(98|99|32764|32765):$/' | wc -l
      echo -n "  after stop, table 51820: "; ip route show table 51820 2>/dev/null | wc -l
      systemctl start wireguard-proton0
      sleep 3
      echo -n "  after start, gw ping: "; ping -c2 -W2 10.10.50.1 >/dev/null 2>&1 && echo GW-OK || echo GW-FAIL
      ip rule show
      echo "--- 4. reconciler against the native unit ---"
      systemctl start wireguard-reconcile 2>/dev/null
      sleep 2
      journalctl -u wireguard-reconcile -n 6 --no-pager 2>/dev/null
      echo "=== NATIVE TEST done ==="
    '';
    serviceConfig = { Type = "oneshot"; StandardOutput = "journal+console"; };
  };

  # One guest at a time on tap-server, so it must not collide with server.qcow2.
  virtualisation.diskImage = lib.mkForce "./native.qcow2";
}
