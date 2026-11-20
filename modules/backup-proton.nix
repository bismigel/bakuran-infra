# A second, independent offsite: the irreplaceable set to Proton Drive, weekly.
#
# Why Proton at all: every other copy — Longhorn (a node), /mnt/media (a disk), the SD mirror (the same host), R2 (one
# provider) — breaks with one account or one company. On 2026-11-19 a single Cloudflare account-token roll silently
# invalidated the R2 access key and took out tofu state, the nightly copy and the database backups at once. Proton is a
# different company with different auth, so it fails independently.
#
# WHAT is copied: books, immich (photos), cnpg (database WAL + base backups) and credentials — the ~3.8 GiB that cannot be
# re-downloaded. `appdata` (50 GiB of rebuildable config) is deliberately NOT here.
#
# The source is R2, not the local disks: R2 is already the aggregation point (books/photos upload nightly, CNPG archives
# to it continuously), so this unit is one `rclone copy r2:… proton:…` per prefix, and it inherits everything R2 holds
# without re-tarring. Consequence, stated not hidden: books and photos are plaintext in Proton exactly as they are in R2.
# Age-encrypting them before Proton is a follow-up if the owner wants a second provider to hold ciphertext only.
#
# 2FA, at rest, by the owner's explicit choice (2026-11-19, "OTP seed at rest cause im lazy"): the rclone config in SOPS
# holds the Proton username, an obscured password and the obscured TOTP seed, so rclone generates the 6-digit code itself.
# The trade is that the seed becomes as sensitive as the password on the same disk — SOPS encrypts both, and a host
# compromise is a total compromise, but 2FA no longer stops it. Accepted rather than relitigated; recorded rather than
# hidden.
#
# Safety model:
#   * `copy`, never `sync`, and no `--delete-*`: a bad local/R2 state cannot delete or overwrite Proton. The offsite is
#     append-only by construction.
#   * `--immutable`: files are treated as fixed, so rclone skips re-hashing and only ships new objects.
#   * OnFailure -> homelab-alert, so a Proton session that expired (which it eventually will) pages instead of going
#     silent — the exact failure that made the R2 roll invisible.
{ config, lib, pkgs, ... }:

let
  cfgFile = "/root/.config/rclone/proton.conf";
  envFile = "/root/.config/homelab-backup.env";
  prefixes = [ "books" "immich" "cnpg" "credentials" ];
in
{
  sops.secrets."proton_rclone_conf" = {
    path = cfgFile;
    owner = "root";
    mode = "0600";
  };

  systemd.services.homelab-backup-proton = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Weekly copy of the irreplaceable set to Proton Drive (independent second offsite)";
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
      for d in ${lib.concatStringsSep " " prefixes}; do
        ${pkgs.rclone}/bin/rclone --config ${cfgFile} \
          copy "r2:$R2_BUCKET/$d" "proton:homelab-backups/$d" \
          --immutable --transfers 2 --contimeout 30s --timeout 5m --retries 3 \
          --stats-one-line --log-level INFO
      done
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
