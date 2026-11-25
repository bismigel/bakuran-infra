#!/bin/sh
# Make the LAN switch scrape-able by Prometheus — idempotent, and the only record of this configuration.
#
# The switch is a Netgear GS108Tv3 running **OpenWrt**, so none of the estate's usual machinery applies: it is not a NixOS
# host, it has no git-tracked configuration, and `opkg` state was, until 2026-11-13, hand-made and recorded nowhere. This
# script is that record. Run it after a reflash, a factory reset, or `opkg upgrade` surprises you.
#
#   ssh root@192.168.10.3 'sh -s' < switch/node-exporter.sh
#
# What it configures, and why each part is not optional:
#
#   * `prometheus-node-exporter-lua` + the netdev collector are what produce `node_*` metrics; the base package alone
#     exports no interface counters.
#   * `listen_interface 'lan'` — the package defaults to **loopback**, which is invisible to Prometheus. This is the
#     single setting most likely to be lost and hardest to notice: the exporter is running, the port is listening, and
#     nothing can scrape it.
#   * a firewall rule admitting **tcp/9100 from 192.168.10.82 only** — not the whole LAN. The metric endpoint exposes host
#     inventory (interfaces, addresses, processes), so it is scoped to the one client that needs it.
#
# Verified idempotent on 2026-11-13: a second run changes nothing. The scrape job is `switch` in
# bakuran-gitops manifests/base/monitoring/monitoring.yaml, and the dashboard is `grafana-dashboard-switch`.
set -eu

EXPECTED="${PROM_SCRAPE_SRC:-192.168.10.82}"
MISSING=$(opkg list-installed 2>/dev/null | grep -c 'prometheus-node-exporter-lua' || true)

if [ "$MISSING" -lt 1 ]; then
    echo "installing prometheus-node-exporter-lua + netdev collector"
    opkg update >/dev/null
    opkg install prometheus-node-exporter-lua prometheus-node-exporter-lua-netdev
else
    echo "packages already installed"
fi

cur=$(uci get prometheus-node-exporter-lua.main.listen_interface 2>/dev/null || echo unset)
if [ "$cur" != "lan" ]; then
    echo "listen_interface: $cur -> lan"
    uci set prometheus-node-exporter-lua.main.listen_interface='lan'
    uci commit prometheus-node-exporter-lua
    CHANGED_SVC=1
else
    echo "listen_interface already lan"
fi

# The rule is matched by name so a second run does not stack duplicates (uci would happily add another).
exists=$(uci show firewall 2>/dev/null | grep -c "name='prometheus-scrape'" || true)
if [ "$exists" -eq 0 ]; then
    echo "adding firewall rule: tcp/9100 from $EXPECTED"
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='prometheus-scrape'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].src_ip="$EXPECTED"
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='9100'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    CHANGED_FW=1
else
    echo "firewall rule already present"
fi

[ "${CHANGED_FW:-0}" = "1" ] && /etc/init.d/firewall reload >/dev/null 2>&1
if [ "${CHANGED_SVC:-0}" = "1" ] || ! pgrep -f prometheus-node-exporter-lua >/dev/null 2>&1; then
    /etc/init.d/prometheus-node-exporter-lua enable >/dev/null 2>&1
    /etc/init.d/prometheus-node-exporter-lua restart >/dev/null 2>&1
    echo "exporter (re)started"
fi

echo "--- result"
netstat -lnt 2>/dev/null | grep -E ':9100' || echo "NOT LISTENING — check /etc/init.d/prometheus-node-exporter-lua"
