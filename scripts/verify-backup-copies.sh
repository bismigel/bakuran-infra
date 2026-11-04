#!/usr/bin/env bash
# Verify that the offline copy of the backups matches R2 in file set and size.
#
# Why this exists (story 5.2 in homelab-context's store): "the copy exited 0" is not the same
# claim as "the copy is complete". On 2026-11-02 the USB stick holding this copy failed under
# sustained write load — it dropped five times, re-enumerated mid-copy, and because the mount was
# gone rclone wrote 12 GB into the mountpoint on the *root* filesystem and reported success.
# Nothing noticed. This is the checker that would have.
#
# What it can and cannot prove, measured on 2026-11-04 and deliberately written down:
#   CAN: every file in the offline copy is present in R2 at the same size, and every R2 file
#        *inside the retention window* is present locally at the same size. That catches
#        truncation, partial syncs and a vanished mount — the failure that actually happened.
#        The window matters: the copy job runs `--max-age 14d`, so older backups are archive-only
#        and their absence from the offline copy is the design, not a fault (learned the hard way
#        on the first run of this script, 2026-11-04).
#   CANNOT: bit-level corruption. The backups are age-encrypted, the private key is kept off-site
#        on purpose, and Cloudflare R2 does not serve SHA-256 (`hash type not supported`). So a
#        file that is the right size and wrong content passes here. That gap is closed by a
#        quarterly manual drill (story 5.3), not by pretending this checks it.
#
# Output: a textfile metric for node-exporter plus a non-zero exit, so both the pager and a human
# see it. Idempotent and read-only: it writes nothing except its own metric file.
set -uo pipefail

LOCAL="${LOCAL:-/mnt/scratch/backup-r2}"
WINDOW_DAYS="${WINDOW_DAYS:-14}"   # must match the copy job's --max-age in modules/backup-local.nix
COPY_LAG_DAYS="${COPY_LAG_DAYS:-8}" # the copy is weekly; a file younger than this has not had its
                                    # chance to become local yet, so its absence proves nothing
REQUIRE_MOUNT="${REQUIRE_MOUNT:-1}" # 0 lets the check run against a copy of the layout, which is
                                    # how its two failure directions are tested without touching the
                                    # real one (a checker nobody can test is a checker nobody trusts)
TEXTFILE="${TEXTFILE:-/var/lib/node-exporter/textfile}"
ENV_FILE="${ENV_FILE:-/root/.config/homelab-backup.env}"
METRIC="homelab_backup_copy"
PROBLEMS=0
FILES=0

write_metrics() {
  local tmp="$TEXTFILE/.${METRIC}.$$"
  {
    echo "# HELP ${METRIC}_files Number of backup files compared with R2"
    echo "# TYPE ${METRIC}_files gauge"
    echo "${METRIC}_files ${FILES}"
    echo "# HELP ${METRIC}_problems Files missing, extra, or size-mismatched"
    echo "# TYPE ${METRIC}_problems gauge"
    echo "${METRIC}_problems ${PROBLEMS}"
    echo "# HELP ${METRIC}_verified_timestamp_seconds When this check last completed"
    echo "# TYPE ${METRIC}_verified_timestamp_seconds gauge"
    echo "${METRIC}_verified_timestamp_seconds $(date -u +%s)"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$TEXTFILE/${METRIC}.prom"
}
trap write_metrics EXIT

[ -d "$LOCAL" ] || { echo "FAIL: $LOCAL missing"; PROBLEMS=1; exit 1; }
if [ "$REQUIRE_MOUNT" = 1 ]; then
  mountpoint -q "$(dirname "$LOCAL")" || { echo "FAIL: $(dirname "$LOCAL") is not a mount"; PROBLEMS=1; exit 1; }
else
  echo "note: REQUIRE_MOUNT=0 — mount check skipped (test mode)"
fi
[ -s "$ENV_FILE" ] || { echo "FAIL: $ENV_FILE missing"; PROBLEMS=1; exit 1; }
command -v rclone >/dev/null || { echo "FAIL: rclone not in PATH"; PROBLEMS=1; exit 1; }

# shellcheck source=/dev/null
set -a; . "$ENV_FILE"; set +a
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

RCLONE="rclone --config /dev/null"
remote="r2:$R2_BUCKET"

for dir in appdata credentials; do
  # One listing per directory: name + size, one line each. `lsjson` avoids parsing `ls` output.
  listing="$($RCLONE lsjson "$remote/$dir" 2>/dev/null)" || {
    echo "FAIL: cannot list $remote/$dir"; PROBLEMS=$((PROBLEMS+1)); continue; }

  printf '%s\n' "$listing" | tr '}' '\n' | grep -o '"Path":"[^"]*","Name":"[^"]*","Size":[0-9]*' \
    | sed -E 's/"Path":"[^"]*","Name":"([^"]*)","Size":([0-9]*)/\1 \2/' > "/tmp/.r2-$dir.$$"
  [ -s "/tmp/.r2-$dir.$$" ] || { echo "FAIL: R2 listing for $dir was empty"; PROBLEMS=$((PROBLEMS+1)); }

  # window = the copy job's --max-age, so "in R2 but not local" is only a fault inside it
  cutoff=$(( $(date -u +%s) - WINDOW_DAYS * 86400 ))
  stamp() { printf '%s' "$1" | grep -oE '[0-9]{8}T[0-9]{6}Z' | head -1; }

  # 1. a file held in both places must be the same size. A file only in the offline copy is a
  #    WARNING, not a fault: R2 prunes on its own schedule, and the offline copy keeping something
  #    upstream dropped is the offline copy doing its job.
  while read -r path; do
    name=$(basename "$path")
    r2size=$(grep "^$name " "/tmp/.r2-$dir.$$" | awk '{print $2}')
    if [ -z "$r2size" ]; then
      echo "warn: $dir/$name is local but no longer in R2 (upstream pruned it)"; continue
    fi
    FILES=$((FILES+1))
    localsize=$(stat -c %s "$path")
    [ "$localsize" = "$r2size" ] || {
      echo "FAIL: $dir/$name local size $localsize != R2 $r2size"; PROBLEMS=$((PROBLEMS+1)); }
  done < <(find "$LOCAL/$dir" -maxdepth 1 -type f 2>/dev/null)

  # 2. everything R2 holds *inside the window* must be present locally
  while read -r name size; do
    s=$(stamp "$name")
    [ -n "$s" ] || continue                     # not a timestamped backup: nothing to window
    ts=$(date -u -d "$(printf '%s' "$s" | sed -E 's/([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z/\1-\2-\3 \4:\5:\6/')" +%s 2>/dev/null) || continue
    [ "$ts" -ge "$cutoff" ] || continue         # archive-only, absence locally is correct
    [ "$ts" -le "$(( $(date -u +%s) - COPY_LAG_DAYS * 86400 ))" ] || continue  # not copied yet
    [ -f "$LOCAL/$dir/$name" ] || {
      echo "FAIL: $dir/$name is inside the ${WINDOW_DAYS}d window, in R2, but missing locally"
      PROBLEMS=$((PROBLEMS+1)); }
  done < "/tmp/.r2-$dir.$$"

  rm -f "/tmp/.r2-$dir.$$"
done

if [ "$FILES" -eq 0 ]; then
  echo "FAIL: compared 0 files — the layout moved, so this check proved nothing"
  PROBLEMS=$((PROBLEMS+1))
fi

if [ "$PROBLEMS" -ne 0 ]; then
  echo "verify-backup-copies: $PROBLEMS problem(s) across $FILES file(s)"
  exit 1
fi
echo "verify-backup-copies: ok — $FILES file(s) match R2 in set and size"
