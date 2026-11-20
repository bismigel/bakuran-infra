# A second, independent offsite: the irreplaceable set to Proton Drive, weekly, **age-encrypted**.
#
# Why Proton at all: every other copy — Longhorn (a node), /mnt/media (a disk), the SD mirror (the same host), R2 (one
# provider) — breaks with one account or one company. On 2026-11-19 a single Cloudflare account-token roll silently
# invalidated the R2 access key and took out tofu state, the nightly copy and the database backups at once. Proton is a
# different company with different auth, so it fails independently.
#
# WHAT is copied: books, immich (photos), cnpg (database WAL + base backups) and credentials — the ~3.9 GiB that cannot be
# re-downloaded. `appdata` (50 GiB of rebuildable config) is deliberately NOT here.
#
# ENCRYPTION, by the owner's choice (2026-11-19): Proton holds ciphertext only. The archive is `tar | age -r $AGE_RECIPIENT`,
# where AGE_RECIPIENT is the **same backup key the other backups already use** (`age15hzlt…`, private half on this host at
# /root/.config/homelab-backup.agekey and in BWS `backup-age-key`). Reusing it means encrypting Proton adds **no new key to
# lose** — the owner has a physical cold copy, and the existing `homelab-backup-verify` unit already decrypts with it weekly.
#
# 2FA at rest, by the owner's explicit choice ("OTP seed at rest cause im lazy"): the rclone config in SOPS
# (`proton_rclone_conf`) holds the Proton username, an obscured password and the obscured TOTP seed, so rclone generates
# the code itself. The trade (seed becomes as sensitive as the password on the same disk) is accepted and recorded.
#
# Safety model:
#   * the source is R2 (the single aggregation point), so the archive is a consistent snapshot and the local disks are not
#     read — a half-finished nightly R2 run or a stale local file cannot leak into the offsite.
#   * the archive is decrypted-and-listed BEFORE upload: a corrupt or empty archive is refused rather than trusted.
#   * `copy`, never `sync`; the archive filename is timestamped, so each week is a new immutable object.
#   * retention is deliberate and bounded: only archives older than 60 days are deleted, so a bug can never touch the
#     recent copies.
#   * OnFailure -> homelab-alert, so an expired Proton session pages instead of going silent.
{ config, lib, pkgs, ... }:

let
  cfgFile = "/root/.config/rclone/proton.conf";
  envFile = "/root/.config/homelab-backup.env";
  ageKey = "/root/.config/homelab-backup.agekey";
  prefixes = [ "books" "immich" "cnpg" "credentials" ];
in
{
  sops.secrets."proton_rclone_conf" = {
    path = cfgFile;
    owner = "root";
    mode = "0600";
  };

  systemd.services.homelab-backup-proton = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Weekly age-encrypted copy of the irreplaceable set to Proton Drive";
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "6h";
      Nice = 15;
      IOSchedulingClass = "idle";
    };
    script = ''
      set -euo pipefail
      set -a; . ${envFile}; set +a
      export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
      RCLONE=${pkgs.rclone}/bin/rclone
      AGE=${pkgs.age}/bin/age
      TAR=${pkgs.gnutar}/bin/tar
      GREP=${pkgs.gnugrep}/bin/grep
      DATE=${pkgs.coreutils}/bin/date
      MKTEMP=${pkgs.coreutils}/bin/mktemp

      # Force a full re-auth from the seed every run: rclone persists its session tokens back into the
      # config, and stale ones 401-loop instead of falling back to the password. The seed
      # (otp_secret_key) is what authenticates; the session tokens then live only in memory for this run.
      clean_cfg=$("$MKTEMP")
      "$GREP" -vE '^(client_uid|client_access_token|client_refresh_token|client_salted_key_pass)' ${cfgFile} > "$clean_cfg"

      stamp=$("$DATE" -u +%Y%m%dT%H%M%SZ)
      stage=$("$MKTEMP" -d)
      archive="/tmp/proton-$stamp.tar.age"
      trap 'rm -rf "$stage" "$archive" "$clean_cfg"' EXIT

      # A consistent snapshot from R2 (the one place every prefix already lands).
      for d in ${lib.concatStringsSep " " prefixes}; do
        "$RCLONE" --config /dev/null copy "r2:$R2_BUCKET/$d" "$stage/$d" \
          --stats-one-line --log-level INFO
      done

      # Encrypt to the existing backup key; no new key to lose.
      "$TAR" -C "$stage" -cf - ${lib.concatStringsSep " " prefixes} \
        | "$AGE" -r "$AGE_RECIPIENT" -o "$archive"

      # Refuse a corrupt or empty archive before it becomes the offsite copy.
      "$AGE" -d -i ${ageKey} "$archive" | "$TAR" -t >/dev/null

      # Append-only upload, then prove the copy matches.
      "$RCLONE" --config "$clean_cfg" copy "$archive" proton:homelab-backups/ \
        --immutable --transfers 2 --contimeout 30s --timeout 5m --retries 3 \
        --stats-one-line --log-level INFO
      # `check --one-way` takes a DIRECTORY as the destination, not the full object path - the first
      # version passed the file and died with 'is a file not a directory' after the upload had already
      # succeeded. Pass the directory; rclone compares by name + size against the archive.
      "$RCLONE" --config "$clean_cfg" check --one-way \
        "$archive" "proton:homelab-backups"

      # Deliberate, bounded retention: only archives older than 60 days.
      "$RCLONE" --config "$clean_cfg" delete proton:homelab-backups/ \
        --min-age 60d --include 'proton-*.tar.age'
    '';
  };

  systemd.timers.homelab-backup-proton = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Sunday 02:30, after the nightly R2 run (01:40) and away from the media mirror (Sun 04:30).
      OnCalendar = "Sun 02:30";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
