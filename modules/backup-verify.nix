# Weekly proof that the offline copy of the backups is complete.
#
# The backups are age-encrypted and the private key is kept off-site on purpose, so a real
# restore cannot happen here — and "the copy job exited 0" is not the same claim as "the copy is
# complete". On 2026-11-02 the USB stick holding that copy failed under sustained write load: it
# dropped five times, re-enumerated mid-copy, and because the mount was gone rclone wrote 12 GB
# into the mountpoint on the root filesystem and reported success.
#
# So this checks what is checkable from here: every file in the offline copy is in R2 at the same
# size, and every R2 file inside the 14-day window (the copy job's `--max-age`) is present locally.
# It writes a textfile metric and exits non-zero, so the gap is loud rather than silent. The bit-
# level gap — right size, wrong content — is closed by a manual drill with the off-site key, which
# is story 5.3 in homelab-context's store, not something this unit pretends to do.
{ config, pkgs, lib, self, ... }:
let
  cfg = config.bakuran.backupVerify;
in
{
  options.bakuran.backupVerify = {
    enable = lib.mkEnableOption "weekly verification that the offline backup copy is complete";
    localPath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/scratch/backup-r2";
      description = "The offline copy to compare against R2.";
    };
    windowDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = "Must match the copy job's --max-age in modules/backup-local.nix.";
    };
    textfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter/textfile";
      description = "Where node-exporter's textfile collector reads metrics from.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.backup-copy-verify = {
      description = "Verify the offline backup copy is complete (set + size vs R2)";
      # The env file holds the R2 credentials and lives on the host, not in the store. The check is Go and is built by this
      # repository's flake (ADR 0019: a command belongs to the repository that builds the closure it runs inside), so the unit
      # needs no interpreter and no path outside the store.
      script = ''
        export LOCAL=${lib.escapeShellArg cfg.localPath}
        export WINDOW_DAYS=${toString cfg.windowDays}
        export TEXTFILE=${lib.escapeShellArg cfg.textfileDirectory}
        exec ${self.packages.${pkgs.system}.verify-backup-copies}/bin/verify-backup-copies
      '';
      # `rclone` is the only external tool left: the Go command reads its JSON, and mount detection reads /proc/self/mountinfo.
      path = with pkgs; [ rclone ];
      serviceConfig = {
        Type = "oneshot";
        # A verification that fails must not take the timer with it: the metric and the exit code
        # are the alarm, and the next run should still happen.
        SuccessExitStatus = [ 0 1 ];
      };
    };

    systemd.timers.backup-copy-verify = {
      description = "Weekly offline-copy verification";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun 05:30";   # after the weekly copy job, and after the nightly appdata run
        Persistent = true;          # a host that was off still gets its check
        RandomizedDelaySec = "10m";
      };
    };
  };
}
