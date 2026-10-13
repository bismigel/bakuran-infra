#!/usr/bin/env bash
# Set a space-saving quality balance on Sonarr + Radarr:
#   - cap size per quality (MB/min): 1080p<=45, 720p<=22, SD<=8  -> rejects oversized
#   - no 4K / no Remux (already default in the profile)
#   - prefer x265/HEVC via a custom format (score +100)  -> smaller encodes
# Idempotent.  Run on the media box (or over ssh):
#   HOST=127.0.0.1 KUBECTL="k3s kubectl" ./media-quality-setup.sh
set -euo pipefail
HOST="${HOST:-127.0.0.1}"
KUBECTL="${KUBECTL:-k3s kubectl}"
SONARR="http://${HOST}:30089"
RADARR="http://${HOST}:30078"

resolve_jq() { command -v jq >/dev/null 2>&1 && command -v jq || ls -1 /nix/store/*-jq-*/bin/jq 2>/dev/null | head -1; }
JQ="$(resolve_jq)"; [ -n "$JQ" ] || { echo "jq required" >&2; exit 1; }
jqr() { "$JQ" "$@"; }
api_key() { $KUBECTL -n media exec "deploy/$1" -- sh -c "grep -o '<ApiKey>[^<]*' /config/config.xml" 2>/dev/null | sed 's/<ApiKey>//'; }

setup() { # <base-url> <api-key> <api-version>
  local base="$1" k="$2" api="$3"
  # --- size caps ---
  curl -sf -H "X-Api-Key: $k" "$base/api/$api/qualitydefinition" | jqr -c '.[]' | while read -r d; do
    local n id m
    n=$(printf '%s' "$d" | jqr -r '.quality.name')
    case "$n" in *2160p*) continue;; *Remux*) m=100;; *1080p*) m=45;; *720p*) m=22;; *) m=8;; esac
    id=$(printf '%s' "$d" | jqr -r '.id')
    printf '%s' "$d" | jqr --argjson m "$m" '.maxSize=$m | .preferredSize=($m/2|floor)' > /tmp/qd.json
    curl -sf -o /dev/null -X PUT -H "X-Api-Key: $k" -H 'Content-Type: application/json' \
      --data @/tmp/qd.json "$base/api/$api/qualitydefinition/$id"
  done
  echo "  caps applied"
  # --- x265 custom format ---
  local cf
  cf=$(curl -sf -H "X-Api-Key: $k" "$base/api/$api/customformat" | jqr -r '.[]|select(.name=="x265").id' | head -1)
  if [ -z "$cf" ]; then
    cf=$(curl -sf -X POST -H "X-Api-Key: $k" -H 'Content-Type: application/json' \
      "$base/api/$api/customformat" -d '{"name":"x265","specifications":[{"name":"x265","implementation":"ReleaseTitleSpecification","negate":false,"required":false,"fields":[{"name":"value","value":"(?i)\\b(x265|h\\.?265|hevc)\\b"}]}]}' | jqr -r '.id')
    echo "  custom format x265 created (id $cf)"
  else
    echo "  custom format x265 exists (id $cf)"
  fi
  # --- score it on every quality profile ---
  curl -sf -H "X-Api-Key: $k" "$base/api/$api/qualityprofile" | jqr -r '.[].id' | while read -r pid; do
    local P
    P=$(curl -sf -H "X-Api-Key: $k" "$base/api/$api/qualityprofile/$pid" \
      | jqr --argjson cf "$cf" '.formatItems=((.formatItems//[])|map(select(.format!=$cf)))+[{"format":$cf,"score":100}]')
    curl -sf -o /dev/null -X PUT -H "X-Api-Key: $k" -H 'Content-Type: application/json' \
      "$base/api/$api/qualityprofile/$pid" -d "$P"
    echo "  profile $pid: prefer x265"
  done
}

echo "== Sonarr =="
setup "$SONARR" "$(api_key sonarr)" v3
echo "== Radarr =="
setup "$RADARR" "$(api_key radarr)" v3
echo "done"
