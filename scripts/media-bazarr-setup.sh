#!/usr/bin/env bash
# media-bazarr-setup.sh — idempotently configure Bazarr (subtitles) over its API.
#
# Bazarr ships unconfigured, so it never fetches subtitles. This wires it to
# Sonarr/Radarr, adds an OpenSubtitles provider, and creates an English language
# profile, so text (SRT) subtitles get downloaded next to the media files.
#
# No secrets live in this repo:
#   * Sonarr/Radarr/Bazarr API keys are read from the running pods (config.xml).
#   * OpenSubtitles user/password come from the `media-setup` Secret (ns media),
#     which is seeded from Bitwarden (scripts/media-setup-secret.sh).
#
# Usage (on a k3s node, or with the NodePorts reachable + kubectl):
#   HOST=192.168.2.81 KUBECTL="k3s kubectl" ./scripts/media-bazarr-setup.sh
#
# Requires: bash, curl, and jq (falls back to a nix-store jq).
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
BAZARR="http://${HOST}:30067"
KUBECTL="${KUBECTL:-k3s kubectl}"
log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

resolve_jq() {
  if command -v jq >/dev/null 2>&1; then command -v jq; return; fi
  ls -1 /nix/store/*-jq-*/bin/jq 2>/dev/null | head -1
}
JQ="$(resolve_jq)"; [ -n "$JQ" ] || { echo "jq required" >&2; exit 1; }
jqr() { "$JQ" "$@"; }

secret_get() { $KUBECTL -n media get secret media-setup -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d; }
api_key() { $KUBECTL -n media exec "deploy/$1" -- \
  sh -c "grep -o '<ApiKey>[^<]*' /config/config.xml" 2>/dev/null | sed 's/<ApiKey>//'; }

BAZ_KEY="$(api_key bazarr)"
SO_KEY="$(api_key sonarr)"
RA_KEY="$(api_key radarr)"
OS_USER="$(secret_get opensubtitles-user)"
OS_PASS="$(secret_get opensubtitles-pass)"

# Bazarr's settings endpoint takes individual form fields, dash-joined, prefixed
# with "settings-" (e.g. settings-general-use_sonarr, settings-sonarr-apikey).
baz() { curl -sf -o /dev/null -X POST "$BAZARR/api/system/settings" -H "X-API-KEY: $BAZ_KEY" "$@"; }
baz_task() { curl -sf -o /dev/null -X POST "$BAZARR/api/system/tasks" \
  -H "X-API-KEY: $BAZ_KEY" -H 'Content-Type: application/json' -d "{\"taskid\":\"$1\"}"; }

log "Bazarr ↔ Sonarr/Radarr + provider"
baz \
  --data "settings-general-use_sonarr=true" \
  --data "settings-general-use_radarr=true" \
  --data "settings-general-serie_default_enabled=true" \
  --data "settings-general-movie_default_enabled=true" \
  --data "settings-general-use_embedded_subs=false" \
  --data "settings-general-ignore_pgs_subs=true" \
  --data "settings-sonarr-ip=sonarr.media.svc.cluster.local" --data "settings-sonarr-port=8989" \
  --data "settings-sonarr-apikey=$SO_KEY" \
  --data "settings-radarr-ip=radarr.media.svc.cluster.local" --data "settings-radarr-port=7878" \
  --data "settings-radarr-apikey=$RA_KEY" \
  --data "settings-general-enabled_providers=opensubtitlescom" \
  --data-urlencode "settings-opensubtitlescom-username=$OS_USER" \
  --data-urlencode "settings-opensubtitlescom-password=$OS_PASS"
echo "  settings applied"

log "Bazarr English language profile"
prof='[{"profileId":1,"name":"English","cutoff":null,"items":[{"id":1,"language":"en","audio_exclude":"False","hi":"False","forced":"False"}],"mustContain":[],"mustNotContain":[],"originalFormat":0,"tag":null}]'
baz --data-urlencode "languages-profiles=$prof" --data "languages-enabled=en"
echo "  profile 'English' ensured"

# NOTE: we deliberately do NOT set general.{serie,movie}_default_profile. In this
# Bazarr build that makes the next series insert fail with
# "FOREIGN KEY constraint failed" (profileId doesn't resolve). Instead, assign the
# profile directly to any synced series/movies that don't have one yet.
log "Assign synced library to the English profile"
for t in 1 2 3; do
  $KUBECTL -n media exec deploy/bazarr -- python3 -c "
import sqlite3
c = sqlite3.connect('/config/db/bazarr.db')
n = c.execute(\"update table_shows set profileId=1 where profileId is null\").rowcount
m = c.execute(\"update table_movies set profileId=1 where profileId is null\").rowcount
c.commit()
print('  assigned:', n, 'series /', m, 'movies')
" 2>/dev/null && break
  sleep 5
done

log "Trigger sync + missing-subtitle search"
baz_task update_series
baz_task update_movies
sleep 10
baz_task wanted_search_missing_subtitles_series
baz_task wanted_search_missing_subtitles_movies

log "Done"
echo "Bazarr is configured. Text subtitles (.srt) will download next to media files."
echo "Run a Jellyfin library scan afterwards so it picks up the new subtitle files."
