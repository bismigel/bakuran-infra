#!/bin/sh
# Dead-man's switch for the Bakuran homelab, run FROM THE ROUTER.
#
# Why here: every other watcher lives in the cluster, so if the cluster (or its
# alerting path) dies, the watchers die with it and the silence looks exactly like
# "nothing wrong". The router is the only device in the estate outside that failure
# domain, and it is already the thing everything else depends on.
#
# Checks (both cheap, both already permitted from the LAN):
#   1. the k3s API VIP on 6443 - ANY http answer proves the control plane is alive
#      (401 is normal: /readyz needs auth; a dead cluster gives no answer at all)
#   2. the public status page - tunnel + cluster + edge, end to end
#
# Speaks only on a TRANSITION, plus one weekly "still watching" so silence has a
# meaning. Verified from the router 2026-11-02 (down + recovery messages delivered).
CHAT="${CHAT:-607008268}"
TOKEN_FILE="${TOKEN_FILE:-/usr/local/etc/homelab-heartbeat.token}"
STATE="${STATE:-/var/db/homelab-heartbeat.state}"
LOG="${LOG:-/var/log/homelab-heartbeat.log}"
API_URL="${API_URL:-https://192.168.2.100:6443/readyz}"
WEB_URL="${WEB_URL:-https://status.bismigel.dev/}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$LOG"; }

send() {
  [ -s "$TOKEN_FILE" ] || { log "no token at $TOKEN_FILE"; return 1; }
  body=$(curl -s -m 15 -X POST \
    "https://api.telegram.org/bot$(cat "$TOKEN_FILE")/sendMessage" \
    --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$1" 2>/dev/null)
  case "$body" in
    *'"ok":true'*) log "telegram sent"; return 0 ;;
    *) log "telegram FAILED: $(echo "$body" | head -c 120)"; return 1 ;;
  esac
}

api=$(curl -sk -o /dev/null -w '%{http_code}' -m 8 "$API_URL" 2>/dev/null)
web=$(curl -s  -o /dev/null -w '%{http_code}' -m 12 "$WEB_URL" 2>/dev/null)
[ "$api" = "000" ] && api_ok=0 || api_ok=1
[ "$web" = "200" ] && web_ok=1 || web_ok=0
if [ "$api_ok" = 1 ] && [ "$web_ok" = 1 ]; then now=up; else now=down; fi

prev=$(cat "$STATE" 2>/dev/null || echo unknown)
echo "$now" > "$STATE"
log "check api=$api web=$web -> $now (was $prev)"

if [ "$now" != "$prev" ]; then
  if [ "$now" = "down" ]; then
    send "🔴 HOMELAB DOWN (router check)
API VIP 6443: $api
status page:  $web
The cluster did not answer from the router. If the cluster is genuinely down, so is every alert inside it — this message exists for that case."
  else
    send "🟢 homelab back up (router check): API $api, status page $web"
  fi
fi

# Weekly proof-of-life: Monday 09:00-09:05, only while healthy.
if [ "$now" = "up" ] && [ "$(date +%u)" = "1" ] && [ "$(date +%H)" = "09" ] && [ "$(date +%M)" -lt 6 ]; then
  send "🫀 homelab heartbeat: alive at $(date '+%Y-%m-%d %H:%M %Z') (API $api, status $web). Silence from this message means the router check itself broke."
fi
