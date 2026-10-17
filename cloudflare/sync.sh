#!/usr/bin/env bash
# sync.sh — declarative-ish reconcile of the Cloudflare edge from this file.
#
# The edge (tunnel ingress, DNS, Access) is otherwise live-only in Cloudflare.
# This encodes the desired state and makes it reproducible. Idempotent.
#
#   CF_API_TOKEN=<cfat_...> ./cloudflare/sync.sh
#
# Token = Bitwarden `cloudflare-api-token` (DNS Write, Tunnel Write, Access). # docs
set -euo pipefail

ACCT="c13ab6fbc2a53cfe719bca75fdc825c2"
TUN="8dcc83bd-eb95-4c0d-8f71-b92a27d37649"
API="https://api.cloudflare.com/client/v4"
: "${CF_API_TOKEN:?set CF_API_TOKEN (Cloudflare API token)}"
cf() { curl -sf --max-time 30 -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
DOMAINS=(
  d7786ec1130918385079b8f224f271b5:bismigel.dev
  bfca3075a1f1d5d2836aca7f4558af0b:ciceley.cc
  0ee0ef4302ab23094e39aae78ca9492e:miguelarbis.dev
)

# --- desired state ---------------------------------------------------------
# Every public hostname routes to the box-local ingress (NodePorts are loopback).
HOSTNAMES=(
  ciceley.cc www.ciceley.cc
  bismigel.dev www.bismigel.dev
  miguelarbis.dev www.miguelarbis.dev
  status.bismigel.dev private.bismigel.dev grafana.bismigel.dev agent.bismigel.dev
  jellyfin.bismigel.dev sonarr.bismigel.dev radarr.bismigel.dev prowlarr.bismigel.dev
  bazarr.bismigel.dev qbittorrent.bismigel.dev sabnzbd.bismigel.dev
  homepage.bismigel.dev prometheus.bismigel.dev
  argocd.bismigel.dev longhorn.bismigel.dev
  immich.bismigel.dev
  kavita.bismigel.dev lazylibrarian.bismigel.dev
  # Public (no Access) so the Karakeep iOS/Android apps can reach its API; it has
  # its own NextAuth login.
  karakeep.bismigel.dev
)

# Access apps: "Name|domain1,domain2|email1,email2[|session]"; add "*" to gate a
# wildcard. Admin-only apps get a short (24h) session; media keeps 730h so TVs/
# phones don't have to re-auth constantly.
# NOTE: jellyfin.bismigel.dev is intentionally NOT gated by Access — it is served
# publicly by the reverse proxy (ingress-nginx) and Jellyfin does its own auth.
# (LAN viewers use the hostPort :8096; remote clients that can't complete an
# interactive Access challenge use the public hostname.)
ACCESS=(
  "Grafana|grafana.bismigel.dev|bismigel@pm.me,family-member@example.com|24h"
  "ZeroClaw|agent.bismigel.dev|bismigel@pm.me|24h"
  "Private API|private.bismigel.dev|bismigel@pm.me|24h"
  "ArgoCD|argocd.bismigel.dev|bismigel@pm.me|24h"
  "Longhorn|longhorn.bismigel.dev|bismigel@pm.me|24h"
  # NOTE: immich.bismigel.dev is intentionally NOT gated by Access either — the
  # native phone app (background backup) can't complete an interactive Access
  # challenge. Served publicly by the reverse proxy; Immich does its own auth.
  "Homelab Media|sonarr.bismigel.dev,radarr.bismigel.dev,prowlarr.bismigel.dev,bazarr.bismigel.dev,qbittorrent.bismigel.dev,sabnzbd.bismigel.dev,homepage.bismigel.dev,prometheus.bismigel.dev|bismigel@pm.me,family-member@example.com"
  "Books|kavita.bismigel.dev,lazylibrarian.bismigel.dev|bismigel@pm.me,family-member@example.com|24h"
)
SESSION=730h

# --- tunnel ingress --------------------------------------------------------
echo ">> tunnel ingress"
ING=$(for h in "${HOSTNAMES[@]}"; do jq -nc --arg h "$h" '{hostname:$h,service:"http://127.0.0.1:32080"}'; done | jq -sc '. + [{service:"http_status:404"}]')
cf -X PUT "$API/accounts/$ACCT/cfd_tunnel/$TUN/configurations" --data "$(jq -nc --argjson i "$ING" '{config:{ingress:$i}}')" >/dev/null \
  && echo "   ok"

# --- DNS -------------------------------------------------------------------
echo ">> DNS CNAMEs"
for h in "${HOSTNAMES[@]}"; do
  for z in "${DOMAINS[@]}"; do
    zid=${z%%:*}; zname=${z##*:}
    # only the zone that owns the name (Cloudflare would otherwise create a
    # bogus "<host>.<zone>" record in every zone).
    [ "$h" = "$zname" ] || [[ "$h" == *."$zname" ]] || continue
    if cf "$API/zones/$zid/dns_records?name=$h" | jq -e '.result|length>0' >/dev/null 2>&1; then continue; fi
    if cf -X POST "$API/zones/$zid/dns_records" --data "$(jq -nc --arg n "$h" --arg c "$TUN.cfargotunnel.com" '{type:"CNAME",name:$n,content:$c,proxied:true}')" >/dev/null 2>&1; then
      echo "   + $h"
    fi
  done
done || true

# --- zone settings (hardening) --------------------------------------------
echo ">> zone settings"
for z in "${DOMAINS[@]}"; do
  zid=${z%%:*}
  cf -X PATCH "$API/zones/$zid/settings/min_tls_version" --data '{"value":"1.2"}' >/dev/null 2>&1 \
    && echo "   min_tls_version=1.2 ($zid)" || echo "   (min_tls skipped for $zid)"
  cf -X PATCH "$API/zones/$zid/settings/always_use_https" --data '{"value":"on"}' >/dev/null 2>&1 || true
  # Bot Fight Mode requires JS detections; set both together (a zone with
  # EnableJS off rejects fight_mode alone).
  cf -X PUT "$API/zones/$zid/bot_management" --data '{"enable_js":true,"fight_mode":true}' >/dev/null 2>&1 \
    && echo "   bot_fight_mode=on ($zid)" || echo "   (bot fight skipped for $zid)"
done

# --- Access apps + policies ------------------------------------------------
echo ">> Access apps"
for spec in "${ACCESS[@]}"; do
  IFS='|' read -r name domains emails sess <<<"$spec"
  sess="${sess:-$SESSION}"
  id=$(cf "$API/accounts/$ACCT/access/apps" | jq -r --arg n "$name" '.result[]?|select(.name==$n)|.id')
  body=$(jq -nc --arg n "$name" --arg d "$domains" --arg s "$sess" \
    '{name:$n,type:"self_hosted",session_duration:$s,self_hosted_domains:($d|split(","))}')
  if [ -n "$id" ]; then
    cf -X PUT "$API/accounts/$ACCT/access/apps/$id" --data "$body" >/dev/null && echo "   ~ $name"
  else
    id=$(cf -X POST "$API/accounts/$ACCT/access/apps" --data "$body" | jq -r '.result.id')
    echo "   + $name"
  fi
  # policy (replace)
  pol=$(jq -nc --argjson inc "$(jq -nc --arg e "$emails" '$e|split(",")|map({email:{email:.}})')" \
    '{name:"Household",decision:"allow",include:$inc}')
  pid=$(cf "$API/accounts/$ACCT/access/apps/$id/policies" | jq -r '.result[0].id // empty')
  if [ -n "$pid" ]; then cf -X PUT "$API/accounts/$ACCT/access/apps/$id/policies/$pid" --data "$pol" >/dev/null
  else cf -X POST "$API/accounts/$ACCT/access/apps/$id/policies" --data "$pol" >/dev/null; fi
done

# --- prune ----------------------------------------------------------------
# Delete Access apps that are no longer declared above (e.g. Jellyfin moved off
# Zero Trust). Scoped to Access apps, which are all managed by this file.
echo ">> prune stale Access apps"
want=$(printf '%s\n' "${ACCESS[@]}" | sed 's/|.*//')
while IFS=$'\t' read -r aid aname; do
  [ -n "$aid" ] || continue
  grep -qxF "$aname" <<<"$want" || { cf -X DELETE "$API/accounts/$ACCT/access/apps/$aid" >/dev/null 2>&1 && echo "   - $aname"; }
done < <(cf "$API/accounts/$ACCT/access/apps" | jq -r '.result[]|"\(.id)\t\(.name)"')

echo ">> done"
