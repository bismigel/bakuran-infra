# ProtonVPN fallback configs: encrypted in SOPS, rendered to /root/wg-configs, switchable in place.
#
# Why: on 2026-11-03 proton0 stopped handshaking (its peer went silent) and the node lost all
# egress for hours. The key fingerprint never changed, so the config was the suspect, and the
# only way to test another one was to paste it in by hand. Four alternate configs had been
# downloaded and were sitting *untracked-but-unignored* in a git working tree.
#
# What this does NOT do: it does not rotate anything on a schedule (a router outage would drain
# four configs in four hours and then nothing would be left), and it does not fix a dead peer.
# It makes "try the next config" a single command with a verified outcome.
#
# The switch is an in-place `wg set` on the existing link. It must not restart wg-quick: that
# unit deletes and recreates the interface, which has stranded this node (NETWORK.md §7.1).
{ config, pkgs, lib, ... }:
let
  fallbacks = {
    "Bakuran3-CA-883" = "wg_fallback_bakuran3ca883";
    "Bakuran-CA-939" = "wg_fallback_bakuranca939";
    "wg-CA-1228" = "wg_fallback_wgca1228";
    "wg-CA-164" = "wg_fallback_wgca164";
  };

  wgSwitch = pkgs.writeShellApplication {
    name = "wg-switch";
    runtimeInputs = with pkgs; [ wireguard-tools iproute2 gawk coreutils ];
    text = ''
      set -euo pipefail
      DIR=/root/wg-configs
      IF=proton0

      field() { sed -n "s/^$2 *= *//p" "$1" | head -1; }
      current_pub() {
        local priv; priv=$(wg show "$IF" private-key 2>/dev/null || true)
        [ -n "$priv" ] && printf '%s\n' "$priv" | wg pubkey
      }
      conf_pub() { field "$1" PrivateKey | wg pubkey; }
      hs() { wg show "$IF" latest-handshakes | awk 'NR==1{print $2+0}'; }

      list() {
        local f p cur; cur=$(current_pub || true)
        printf '   %-18s %-24s %s\n' config endpoint state
        for f in "$DIR"/*.conf; do
          [ -e "$f" ] || continue
          p=$(conf_pub "$f")
          if [ "$p" = "$cur" ]; then s="* active"; else s=""; fi
          printf '   %-18s %-24s %s\n' "$(basename "$f" .conf)" "$(field "$f" Endpoint)" "$s"
        done
      }

      # Re-apply a known-good tuple. Used both for the switch and for reverting it.
      apply() {
        local priv=$1 pub=$2 aips=$3 ep=$4 addr=$5 tmp gw epip old
        # The endpoint must be reachable OUTSIDE the tunnel. main has `default dev proton0`,
        # so without this host route the marked WireGuard packets follow it and vanish into the
        # tunnel they are trying to build. wg-quick puts an equivalent route in place for the
        # endpoint it was configured with; a fallback endpoint needs its own.
        epip=''${ep%:*}
        gw=$(ip route show default | awk '/via/ && !/proton0/ {print $3; exit}')
        ip route replace "$epip/32" via "$gw" dev "$(ip route show default | awk '/via/ && !/proton0/ {print $5; exit}')"

        tmp=$(mktemp); printf '%s\n' "$priv" > "$tmp"; chmod 600 "$tmp"
        old=$(wg show "$IF" peers | head -1 || true)
        wg set "$IF" private-key "$tmp"; rm -f "$tmp"
        if [ -n "$old" ] && [ "$old" != "$pub" ]; then wg set "$IF" peer "$old" remove; fi
        wg set "$IF" peer "$pub" allowed-ips "$aips" endpoint "$ep" persistent-keepalive 25
        [ -n "$addr" ] && ip -4 addr replace "$addr" dev "$IF" 2>/dev/null || true
      }

      case "''${1:-list}" in
        list|-l) list; exit 0 ;;
      esac

      conf="$DIR/$1.conf"
      [ -r "$conf" ] || { echo "no such config: $1 (try: wg-switch list)" >&2; exit 2; }

      prev_priv=$(wg show "$IF" private-key); prev_pub=$(wg show "$IF" peers | head -1)
      prev_ep=$(wg show "$IF" endpoints | awk 'NR==1{print $2}')
      prev_aips=$(wg show "$IF" allowed-ips | awk 'NR==1{print $2}')
      before=$(hs)

      new_priv=$(field "$conf" PrivateKey); new_pub=$(field "$conf" PublicKey)
      new_aips=$(field "$conf" AllowedIPs); new_ep=$(field "$conf" Endpoint)
      new_addr=$(field "$conf" Address)

      echo "switching $IF to $1 (endpoint $new_ep)"
      apply "$new_priv" "$new_pub" "$new_aips" "$new_ep" "$new_addr"

      # A handshake that is newer than the one we started with, within 20s. The old handshake
      # stays in the interface's history, so "non-zero" alone would pass on a dead switch.
      for _ in $(seq 1 20); do
        sleep 1
        now=$(hs)
        if [ "$now" -gt "$before" ]; then
          age=$(( $(date +%s) - now )); [ "$age" -lt 0 ] && age=0
          echo "ok: handshake ''${age}s ago via $new_ep"
          exit 0
        fi
      done

      echo "FAILED: no handshake from $new_ep in 20s - reverting to the previous peer" >&2
      apply "$prev_priv" "$prev_pub" "$prev_aips" "$prev_ep" "" || true
      exit 1
    '';
  };
in
{
  systemd.tmpfiles.rules = [ "d /root/wg-configs 0700 root root -" ];

  sops.secrets = builtins.listToAttrs (map (name: {
    name = fallbacks.${name};
    value = {
      path = "/root/wg-configs/${name}.conf";
      owner = "root";
      group = "root";
      mode = "0600";
    };
  }) (builtins.attrNames fallbacks));

  environment.systemPackages = [ wgSwitch ];
}
