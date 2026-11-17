// Command verify-backup-copies checks that the offline copy of the backups matches R2 in file set and size.
//
//	verify-backup-copies            (reads LOCAL, WINDOW_DAYS, COPY_LAG_DAYS, REQUIRE_MOUNT, TEXTFILE, ENV_FILE)
//
// Read-only and idempotent: it writes nothing except its own textfile metric, and exits 1 when anything is wrong so the pager and a
// human see the same thing.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/bismigel/bakuran-infra/internal/backupcopy"
)

func main() { os.Exit(run()) }

func run() int {
	opts := backupcopy.Options{
		Local:        envOr("LOCAL", "/mnt/scratch/backup-r2"),
		WindowDays:   backupcopy.AtoiDefault(os.Getenv("WINDOW_DAYS"), 14),
		CopyLagDays:  backupcopy.AtoiDefault(os.Getenv("COPY_LAG_DAYS"), 8),
		RequireMount: envOr("REQUIRE_MOUNT", "1") != "0",
		Textfile:     envOr("TEXTFILE", "/var/lib/node-exporter/textfile"),
		EnvFile:      envOr("ENV_FILE", "/root/.config/homelab-backup.env"),
		Now:          time.Now().UTC(),
		IsMount:      isMount,
	}

	values, err := backupcopy.ParseEnvFile(opts.EnvFile)
	if err != nil {
		values = map[string]string{}
	}
	opts.Getenv = func(k string) string { return values[k] }

	rclone, err := exec.LookPath("rclone")
	if err == nil {
		bucket := values["R2_BUCKET"]
		opts.List = func(dir string) (string, error) {
			cmd := exec.Command(rclone, "--config", "/dev/null", "lsjson", "r2:"+bucket+"/"+dir)
			cmd.Env = append(os.Environ(),
				"RCLONE_CONFIG_R2_TYPE=s3",
				"RCLONE_CONFIG_R2_PROVIDER=Cloudflare",
				"RCLONE_CONFIG_R2_ACCESS_KEY_ID="+values["R2_ACCESS_KEY_ID"],
				"RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="+values["R2_SECRET_ACCESS_KEY"],
				"RCLONE_CONFIG_R2_ENDPOINT="+values["R2_ENDPOINT"],
			)
			out, err := cmd.Output()
			return string(out), err
		}
	}

	res := backupcopy.Run(opts, os.Stdout)
	writeMetric(opts.Textfile, res.Files, res.Problems, opts.Now)
	if res.Problems != 0 {
		return 1
	}
	return 0
}

// writeMetric is the textfile node-exporter reads. Failures here are silent on purpose: the metric is a convenience, and the exit code
// is the verdict.
func writeMetric(textfile string, files, problems int, at time.Time) {
	if textfile == "" {
		return
	}
	if err := os.MkdirAll(textfile, 0o755); err != nil {
		return
	}
	tmp := filepath.Join(textfile, fmt.Sprintf(".homelab_backup_copy.%d", os.Getpid()))
	if err := os.WriteFile(tmp, []byte(backupcopy.Metrics(files, problems, at)), 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp, filepath.Join(textfile, "homelab_backup_copy.prom"))
}

// isMount is `mountpoint -q`: a different device than its parent, or a mount point named in /proc/self/mountinfo.
func isMount(path string) bool {
	raw, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	want := strings.TrimSuffix(path, "/")
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 4 && strings.TrimSuffix(fields[4], "/") == want {
			return true
		}
	}
	return false
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
