#!/usr/bin/env bash
# media-stack-setup.sh — idempotently wire up the *arr media stack over APIs.
#
# Configures:
#   qBittorrent : default save path /downloads + tv/movies categories
#   Sonarr      : root folder /tv      + qBittorrent download client (category tv)
#   Radarr      : root folder /movies  + qBittorrent download client (category movies)
#   Prowlarr    : links Sonarr & Radarr (fullSync) and pushes indexers to them
#
# It reads the *arr API keys straight from the running pods (config.xml), so no
# secrets live in this repo. Only the qBittorrent WebUI password is passed in.
#
# Usage (on a k3s node, or anywhere with the NodePorts reachable + kubectl):
#   QBT_PASSWORD='<webui password>' ./scripts/media-stack-setup.sh
#   # remote:
#   HOST=192.168.2.81 QBT_PASSWORD='...' ./scripts/media-stack-setup.sh
#
# Requires: bash, curl, and jq (falls back to `nix run nixpkgs#jq`).
set -euo pipefail
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

HOST="${HOST:-127.0.0.1}"
QBT_USER="${QBT_USER:-admin}"

PROWLARR="http://${HOST}:30069"
SONARR="http://${HOST}:30089"
RADARR="http://${HOST}:30078"
QBIT="http://${HOST}:30081"
JELLYFIN="${JELLYFIN:-http://${HOST}:30096}"

# qBittorrent is reachable from the *arr pods by this in-cluster DNS name.
QBT_INTERNAL="${QBT_INTERNAL:-qbittorrent.downloads.svc.cluster.local}"
SAB_INTERNAL="${SAB_INTERNAL:-sabnzbd.downloads.svc.cluster.local}"
PROWLARR_INTERNAL="${PROWLARR_INTERNAL:-http://prowlarr.media.svc.cluster.local:9696}"
SONARR_INTERNAL="${SONARR_INTERNAL:-http://sonarr.media.svc.cluster.local:8989}"
RADARR_INTERNAL="${RADARR_INTERNAL:-http://radarr.media.svc.cluster.local:7878}"

KUBECTL="${KUBECTL:-k3s kubectl}"
log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

resolve_jq() {
  if command -v jq >/dev/null 2>&1; then command -v jq; return; fi
  # NixOS nodes often have jq only in the nix store (not on PATH).
  ls -1 /nix/store/*-jq-*/bin/jq 2>/dev/null | head -1
}
JQ="$(resolve_jq)"
[ -n "$JQ" ] || { echo "error: jq not found (install jq or add it to PATH)" >&2; exit 1; }
jqr() { "$JQ" "$@"; }

# --- secrets: read from the `media-setup` Secret (ns media) unless the env var is
#     already set. The media cluster has no Bitwarden access, so this Secret is
#     seeded from Bitwarden out of band (see scripts/media-usenet-secret.sh).
secret_get() { # <secret-key>
  $KUBECTL -n media get secret media-setup -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d
}
load_secret() { # <ENV_VAR> <secret-key>
  [ -n "${!1:-}" ] && return 0
  printf -v "$1" '%s' "$(secret_get "$2")"
}
load_secret QBT_PASSWORD         qbt-password
load_secret NZBGEEK_API          nzbgeek-api
load_secret JELLYFIN_ADMIN_USER  jellyfin-admin-user
load_secret JELLYFIN_ADMIN_PASS  jellyfin-admin-pass
load_secret JELLYFIN_ANTON       jellyfin-anton
load_secret JELLYFIN_DELFIN      jellyfin-delfin
load_secret JELLYFIN_CICELEY     jellyfin-ciceley
: "${QBT_PASSWORD:?set QBT_PASSWORD, or seed the 'media-setup' Secret (ns media)}"

# Read an app's API key from its config.xml inside the running pod.
api_key() { # <deploy> [namespace]
  $KUBECTL -n "${2:-media}" exec "deploy/$1" -- \
    sh -c "grep -o '<ApiKey>[^<]*' /config/config.xml" 2>/dev/null | sed 's/<ApiKey>//'
}

# SABnzbd API key from its config (downloads ns).
sab_key() {
  $KUBECTL -n downloads exec deploy/sabnzbd -- \
    sh -c "grep '^api_key' /config/sabnzbd.ini" 2>/dev/null | sed 's/.*= *//' | tr -d ' \r'
}

SO_KEY="$(api_key sonarr)"
RA_KEY="$(api_key radarr)"
PW_KEY="$(api_key prowlarr)"
[ -n "$SO_KEY" ] && [ -n "$RA_KEY" ] && [ -n "$PW_KEY" ] || {
  echo "error: could not read API keys from pods (is kubectl wired up?)" >&2; exit 1; }

qbt() { curl -sf -b "$QBT_COOKIE" "$@"; }

# ---------------------------------------------------------------- qBittorrent
log "qBittorrent"
QBT_COOKIE="$(mktemp)"
trap 'rm -f "$QBT_COOKIE"' EXIT

curl -sf -c "$QBT_COOKIE" "$QBIT/api/v2/auth/login" \
  --data "username=$QBT_USER&password=$QBT_PASSWORD" >/dev/null

qbt -X POST "$QBIT/api/v2/app/setPreferences" \
  --data-urlencode 'json={"save_path":"/downloads","temp_path_enabled":false}' >/dev/null
echo "  default save path -> /downloads"

for c in tv movies; do
  if qbt -X POST "$QBIT/api/v2/torrents/createCategory" --data "category=$c" >/dev/null 2>&1; then
    echo "  category '$c' created"
  else
    echo "  category '$c' already present"
  fi
done

# --------------------------------------------------------------------- Sonarr
# ensure_rootfolder <base> <key> <path>
ensure_rootfolder() {
  local base="$1" k="$2" path="$3"
  if curl -sf -H "X-Api-Key: $k" "$base/api/v3/rootfolder" \
       | jqr -e --arg p "$path" 'any(.[]; .path==$p)' >/dev/null 2>&1; then
    echo "  root folder $path already present"
  else
    curl -sf -X POST "$base/api/v3/rootfolder" -H "X-Api-Key: $k" \
      -H 'Content-Type: application/json' --data "{\"path\":\"$path\"}" >/dev/null
    echo "  root folder $path added"
  fi
}

# ensure_qbt_client <base> <key> <category>
ensure_qbt_client() {
  local base="$1" k="$2" cat="$3"
  local payload
  payload="$(curl -sf -H "X-Api-Key: $k" "$base/api/v3/downloadclient/schema" | jqr \
    --arg cat "$cat" --arg pw "$QBT_PASSWORD" --arg user "$QBT_USER" --arg host "$QBT_INTERNAL" '
      .[] | select(.implementation=="QBittorrent")
      | .name="qBittorrent" | .enable=true | .priority=1 | .tags=[]
      | (.fields[]|select(.name=="host").value)=$host
      | (.fields[]|select(.name=="port").value)=8080
      | (.fields[]|select(.name=="username").value)=$user
      | (.fields[]|select(.name=="password").value)=$pw
      | (.fields[]|select(.name=="tvCategory" or .name=="movieCategory").value)=$cat
      | (.fields[]|select(.name=="contentLayout").value)=0')"
  local id
  id="$(curl -sf -H "X-Api-Key: $k" "$base/api/v3/downloadclient" \
        | jqr -r '.[] | select(.implementation=="QBittorrent") | .id' | head -1)"
  if [ -n "$id" ]; then
    curl -sf -X PUT "$base/api/v3/downloadclient/$id" -H "X-Api-Key: $k" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  download client qBittorrent updated (category $cat)"
  else
    curl -sf -X POST "$base/api/v3/downloadclient" -H "X-Api-Key: $k" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  download client qBittorrent added (category $cat)"
  fi
}

# ensure_sab_client <base> <key> <api-version> <category>   (Usenet via SABnzbd)
ensure_sab_client() {
  local base="$1" k="$2" api="$3" cat="$4"
  local sab; sab="$(sab_key)"
  [ -n "$sab" ] || { echo "  (SABnzbd api key not found; skipping)"; return; }
  local payload
  payload="$(curl -sf -H "X-Api-Key: $k" "$base/api/$api/downloadclient/schema" | jqr \
    --arg sab "$sab" --arg cat "$cat" --arg host "$SAB_INTERNAL" '
      .[] | select(.implementation=="Sabnzbd")
      | .name="SABnzbd" | .enable=true | .priority=1 | .tags=[]
      | (.fields[]|select(.name=="host").value)=$host
      | (.fields[]|select(.name=="port").value)=8080
      | (.fields[]|select(.name=="apiKey").value)=$sab
      | (.fields[]|select(.name=="tvCategory" or .name=="movieCategory" or .name=="category").value)=$cat')"
  local id
  id="$(curl -sf -H "X-Api-Key: $k" "$base/api/$api/downloadclient" \
        | jqr -r '.[] | select(.implementation=="Sabnzbd") | .id' | head -1)"
  if [ -n "$id" ]; then
    curl -sf -X PUT "$base/api/$api/downloadclient/$id" -H "X-Api-Key: $k" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  download client SABnzbd updated (category $cat)"
  else
    curl -sf -X POST "$base/api/$api/downloadclient" -H "X-Api-Key: $k" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  download client SABnzbd added (category $cat)"
  fi
}

# ensure_prowlarr_indexer <name> [api-key]   (name must match Prowlarr's definition)
ensure_prowlarr_indexer() {
  local name="$1" key="${2:-}"
  local payload
  payload="$(curl -sf -H "X-Api-Key: $PW_KEY" "$PROWLARR/api/v1/indexer/schema" | jqr \
    --arg n "$name" --arg k "$key" '
      .[] | select(.name==$n) | .enable=true | .appProfileId=1 | .priority=25 | .tags=[]
      | (if $k != "" then (.fields[]|select(.name=="apiKey").value)=$k else . end)
      | del(.id)')"
  [ -n "$payload" ] || { echo "  indexer $name: definition not found"; return; }
  local id
  id="$(curl -sf -H "X-Api-Key: $PW_KEY" "$PROWLARR/api/v1/indexer" \
        | jqr -r --arg n "$name" '.[]|select(.name==$n).id' | head -1)"
  if [ -n "$id" ]; then
    curl -sf -X PUT "$PROWLARR/api/v1/indexer/$id" -H "X-Api-Key: $PW_KEY" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  indexer $name updated"
  else
    curl -sf -X POST "$PROWLARR/api/v1/indexer" -H "X-Api-Key: $PW_KEY" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  indexer $name added"
  fi
}

# ensure_jellyfin_user <name> <password>   (idempotent; needs the admin creds)
ensure_jellyfin_user() {
  local name="$1" pw="$2"
  [ -n "$name" ] && [ -n "$pw" ] || { echo "  (skip jellyfin user: missing name/password)"; return; }
  [ -n "${JELLYFIN_ADMIN_USER:-}" ] || { echo "  (no jellyfin admin creds; skipping)"; return; }
  local tok
  tok="$(curl -sf -X POST "$JELLYFIN/Users/AuthenticateByName" -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' \
    -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" | jqr -r '.AccessToken')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || { echo "  (jellyfin admin auth failed; skipping)"; return; }
  if curl -sf "$JELLYFIN/Users" -H "Authorization: MediaBrowser Token=$tok" \
       | jqr -e --arg n "$name" 'any(.[]; .Name==$n)' >/dev/null 2>&1; then
    echo "  jellyfin user $name exists"
  else
    curl -sf -X POST "$JELLYFIN/Users/New" -H "Content-Type: application/json" \
      -H "Authorization: MediaBrowser Token=$tok" \
      -d "{\"Name\":\"$name\",\"Password\":\"$pw\"}" >/dev/null
    echo "  jellyfin user $name created"
  fi
}

# ensure_jellyfin_library <display-name> <url-name> <collectionType> <path>
ensure_jellyfin_library() {
  local name="$1" urlname="$2" type="$3" path="$4"
  [ -n "${JELLYFIN_ADMIN_USER:-}" ] || return 0
  local tok
  tok="$(curl -sf -X POST "$JELLYFIN/Users/AuthenticateByName" -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' \
    -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" | jqr -r '.AccessToken')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || return 0
  if curl -sf "$JELLYFIN/Library/VirtualFolders" -H "Authorization: MediaBrowser Token=$tok" \
       | jqr -e --arg n "$name" 'any(.[]; .Name==$n)' >/dev/null 2>&1; then
    echo "  jellyfin library $name exists"
  else
    curl -sf -X POST "$JELLYFIN/Library/VirtualFolders?name=$urlname&collectionType=$type&refreshLibrary=true" \
      -H "Authorization: MediaBrowser Token=$tok" -H 'Content-Type: application/json' \
      -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$path\"}]}}" >/dev/null
    echo "  jellyfin library $name created"
  fi
}

# ensure_jellyfin_hwaccel   (idempotent; enable Intel QuickSync hardware transcoding)
ensure_jellyfin_hwaccel() {
  [ -n "${JELLYFIN_ADMIN_USER:-}" ] || return 0
  local tok cfg
  tok="$(curl -sf -X POST "$JELLYFIN/Users/AuthenticateByName" -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' \
    -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" | jqr -r '.AccessToken')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || { echo "  (jellyfin admin auth failed; skipping hw accel)"; return; }
  cfg="$(curl -sf "$JELLYFIN/System/Configuration/encoding" -H "Authorization: MediaBrowser Token=$tok")"
  # NOTE: low-power (VDENC) QSV encoding needs GuC/HuC loaded; on this Kaby Lake
  # host i915 GuC isn't enabled, so low-power fails with "ratecontrol mode
  # unsupported". Keep it OFF — standard QSV (PAK) encoding works fine.
  local want
  want="$(printf '%s' "$cfg" | jqr -c '.HardwareAccelerationType="qsv" | .EnableHardwareEncoding=true | .EnableVppTonemapping=true | .EnableIntelLowPowerH264HwEncoder=false | .EnableIntelLowPowerHevcHwEncoder=false | .HardwareDecodingCodecs=["h264","hevc","mpeg2video","vc1","vp9"] | .EnableThrottling=true | .EnableSegmentDeletion=true | .TranscodingTempPath="/cache/transcodes"')"
  # HEVC is most of the library: without hardware HEVC decode it runs on the CPU.
  # Throttling stops a transcode from pinning the box once it's ahead of playback.
  if [ "$(printf '%s' "$cfg" | jqr -c '[.HardwareAccelerationType,.EnableVppTonemapping,.EnableIntelLowPowerH264HwEncoder,.EnableIntelLowPowerHevcHwEncoder,.EnableThrottling,.TranscodingTempPath,(.HardwareDecodingCodecs|sort)]')" = '["qsv",true,false,false,true,"/cache/transcodes",["h264","hevc","mpeg2video","vc1","vp9"]]' ]; then
    echo "  jellyfin transcoding already tuned (qsv; hevc decode; throttled)"
    return
  fi
  printf '%s' "$want" >/tmp/jfenc.json
  curl -sf -o /dev/null -X POST "$JELLYFIN/System/Configuration/encoding" \
    -H "Authorization: MediaBrowser Token=$tok" -H 'Content-Type: application/json' --data @/tmp/jfenc.json
  echo "  jellyfin transcoding set to qsv (+vpp; low-power off)"
}

# ensure_jellyfin_subtitle_mode   (idempotent; default subtitle mode "Only forced")
# Prevents Jellyfin from auto-loading full subtitles, which forces a software
# subtitle burn-in (overlay) transcode on clients that can't render them.
ensure_jellyfin_subtitle_mode() {
  [ -n "${JELLYFIN_ADMIN_USER:-}" ] || return 0
  local tok
  tok="$(curl -sf -X POST "$JELLYFIN/Users/AuthenticateByName" -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' \
    -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" | jqr -r '.AccessToken')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || return 0
  curl -sf "$JELLYFIN/Users" -H "Authorization: MediaBrowser Token=$tok" \
    | jqr -r '.[] | "\(.Name)\t\(.Id)"' | while IFS="$(printf '\t')" read -r name id; do
      local conf
      conf="$(curl -sf "$JELLYFIN/Users/$id" -H "Authorization: MediaBrowser Token=$tok" \
        | jqr -c '.Configuration | .SubtitleMode="OnlyForced"')"
      curl -sf -o /dev/null -X POST "$JELLYFIN/Users/$id/Configuration" \
        -H "Authorization: MediaBrowser Token=$tok" -H 'Content-Type: application/json' --data "$conf"
      echo "  subtitle mode OnlyForced: $name"
    done
}

# ensure_jellyfin_scan_interval   (idempotent; make Jellyfin auto-import new media)
# Jellyfin's live file-watching doesn't work across mergerfs (no inotify), so new
# files are only picked up by the scheduled library scan. Default is 12h; drop it
# to 15m so freshly imported media shows up on its own.
ensure_jellyfin_scan_interval() {
  [ -n "${JELLYFIN_ADMIN_USER:-}" ] || return 0
  local tok tid
  tok="$(curl -sf -X POST "$JELLYFIN/Users/AuthenticateByName" -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' \
    -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" | jqr -r '.AccessToken')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || return 0
  tid="$(curl -sf "$JELLYFIN/ScheduledTasks" -H "Authorization: MediaBrowser Token=$tok" \
    | jqr -r '.[]|select(.Name=="Scan Media Library")|.Id')"
  [ -n "$tid" ] || { echo "  (scan task not found)"; return; }
  curl -sf -o /dev/null -X POST "$JELLYFIN/ScheduledTasks/$tid/Triggers" \
    -H "Authorization: MediaBrowser Token=$tok" -H 'Content-Type: application/json' \
    -d '[{"Type":"IntervalTrigger","IntervalTicks":9000000000}]'
  echo "  jellyfin library scan every 15m"
}

log "Sonarr"
ensure_rootfolder "$SONARR" "$SO_KEY" /tv
ensure_qbt_client "$SONARR" "$SO_KEY" tv
ensure_sab_client "$SONARR" "$SO_KEY" v3 tv
# Prefer Usenet (SABnzbd) over torrents — it proved the reliable path here (S1
# 24/24), while qBittorrent/Nyaa was fiddly. Idempotent: sets the default delay
# profile's preferred protocol.
ensure_sonarr_delay_profile() {
  local dp
  dp="$(curl -sf -H "X-Api-Key: $SO_KEY" "$SONARR/api/v3/delayprofile/1" \
        | jqr '.preferredProtocol="usenet"')" || return 0
  curl -sf -o /dev/null -X PUT -H "X-Api-Key: $SO_KEY" -H 'Content-Type: application/json' \
    "$SONARR/api/v3/delayprofile/1" -d "$dp" && echo "  delay profile: usenet-first"
}
ensure_sonarr_delay_profile

log "Radarr"
ensure_rootfolder "$RADARR" "$RA_KEY" /movies
ensure_qbt_client "$RADARR" "$RA_KEY" movies
ensure_sab_client "$RADARR" "$RA_KEY" v3 movies

# ------------------------------------------------------------------- Prowlarr
# ensure_prowlarr_app <impl> <internal-base-url> <api-key>
ensure_prowlarr_app() {
  local impl="$1" base_url="$2" apikey="$3"
  local payload
  payload="$(curl -sf -H "X-Api-Key: $PW_KEY" "$PROWLARR/api/v1/applications/schema" | jqr \
    --arg impl "$impl" --arg base "$base_url" --arg k "$apikey" --arg pwurl "$PROWLARR_INTERNAL" '
      .[] | select(.implementation==$impl)
      | .name=$impl | .syncLevel="fullSync" | .tags=[]
      | (.fields[]|select(.name=="prowlarrUrl").value)=$pwurl
      | (.fields[]|select(.name=="baseUrl").value)=$base
      | (.fields[]|select(.name=="apiKey").value)=$k')"
  local id
  id="$(curl -sf -H "X-Api-Key: $PW_KEY" "$PROWLARR/api/v1/applications" \
        | jqr -r --arg impl "$impl" '.[] | select(.implementation==$impl) | .id' | head -1)"
  if [ -n "$id" ]; then
    curl -sf -X PUT "$PROWLARR/api/v1/applications/$id" -H "X-Api-Key: $PW_KEY" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  app $impl updated"
  else
    curl -sf -X POST "$PROWLARR/api/v1/applications" -H "X-Api-Key: $PW_KEY" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null
    echo "  app $impl linked"
  fi
}

log "Prowlarr"
ensure_prowlarr_app Sonarr "$SONARR_INTERNAL" "$SO_KEY"
ensure_prowlarr_app Radarr "$RADARR_INTERNAL" "$RA_KEY"
ensure_sab_client "$PROWLARR" "$PW_KEY" v1 tv

log "Prowlarr indexers"
ensure_prowlarr_indexer "Nyaa.si"
[ -n "${NZBGEEK_API:-}" ] && ensure_prowlarr_indexer "NZBgeek" "$NZBGEEK_API"

echo "  pushing indexers to Sonarr/Radarr..."
curl -sf -X POST "$PROWLARR/api/v1/command" -H "X-Api-Key: $PW_KEY" \
  -H 'Content-Type: application/json' --data '{"name":"ApplicationIndexerSync"}' >/dev/null

log "Jellyfin users"
ensure_jellyfin_user anton   "${JELLYFIN_ANTON:-}"
ensure_jellyfin_user delfin  "${JELLYFIN_DELFIN:-}"
ensure_jellyfin_user ciceley "${JELLYFIN_CICELEY:-}"

log "Jellyfin libraries"
ensure_jellyfin_library "TV Shows" "TV%20Shows" tvshows /media/tv
ensure_jellyfin_library "Movies"   "Movies"     movies  /media/movies

log "Jellyfin transcoding"
ensure_jellyfin_hwaccel
ensure_jellyfin_subtitle_mode
ensure_jellyfin_scan_interval

log "App auth (*arrs: login for remote, LAN bypass; Bazarr/SABnzbd: no auth)"
# *arrs: Forms auth with a shared admin account (skipped for local/LAN).
for spec in "sonarr $SONARR v3" "radarr $RADARR v3" "prowlarr $PROWLARR v1"; do
  set -- $spec; app=$1; base=$2; ver=$3
  k="$(api_key "$app")"; [ -n "$k" ] || continue
  curl -sf "$base/api/$ver/config/host" -H "X-Api-Key: $k" \
    | "$JQ" -c --arg pw "$QBT_PASSWORD" \
        '.authenticationMethod="forms" | .username="admin" | .password=$pw | .passwordConfirmation=$pw | .authenticationRequired="disabledForLocalAddresses"' \
    | curl -sf -o /dev/null -X PUT "$base/api/$ver/config/host" \
        -H "X-Api-Key: $k" -H 'Content-Type: application/json' --data-binary @-
  echo "  $app login -> admin"
done
# Bazarr: no auth. Bazarr has no per-IP bypass, so a login would prompt on LAN
# *and* behind the tunnel (Sonarr/Radarr/Prowlarr use DisabledForLocalAddresses).
# LAN is trusted and Cloudflare Access gates the public hostname, so drop it.
# The settings API takes the literal "None" to clear auth.type.
BAZ_KEY="$($KUBECTL -n media exec deploy/bazarr -- sh -c "grep -oE 'apikey: [a-f0-9]+' /config/config/config.yaml | head -1" 2>/dev/null | awk '{print $2}' | tr -d '\r')"
if [ -n "$BAZ_KEY" ]; then
  curl -sf -o /dev/null -X POST "http://127.0.0.1:30067/api/system/settings" -H "X-API-KEY: $BAZ_KEY" \
    --data "settings-auth-type=None"
  echo "  bazarr login disabled"
fi
# SABnzbd: no auth (same reasoning — no per-IP bypass). Clear username/password.
SAB_KEY="$($KUBECTL -n downloads exec deploy/sabnzbd -- sh -c 'grep ^api_key /config/sabnzbd.ini' 2>/dev/null | sed 's/.*= *//' | tr -d '\r')"
if [ -n "$SAB_KEY" ]; then
  curl -sf -o /dev/null "http://127.0.0.1:30082/api?mode=set_config&section=misc&keyword=username&value=&apikey=$SAB_KEY"
  curl -sf -o /dev/null "http://127.0.0.1:30082/api?mode=set_config&section=misc&keyword=password&value=&apikey=$SAB_KEY"
  echo "  sabnzbd login disabled"
fi

log "Done"
echo "Indexers are managed in Prowlarr; add trackers there and they will sync."
