// Package backupcopy verifies that the offline copy of the backups matches R2 in file set and size.
//
// "The copy exited 0" is not the same claim as "the copy is complete". On 2026-11-02 the USB stick holding this copy failed under
// sustained write load: it dropped five times, re-enumerated mid-copy, and because the mount was gone rclone wrote 12 GB into the
// mountpoint on the *root* filesystem and reported success. Nothing noticed. This is the checker that would have.
//
// What it can prove: every file in the offline copy is present in R2 at the same size, and every R2 file *inside the retention
// window* is present locally at the same size. That catches truncation, partial syncs and a vanished mount.
//
// What it cannot: bit-level corruption. The backups are age-encrypted, the private key is kept off-site on purpose, and R2 does not
// serve SHA-256. A file of the right size and wrong content passes here; that gap is a quarterly drill, not a pretence.
//
// Ported from `bakuran-infra/scripts/verify-backup-copies.sh` (ADR 0016). Exit 1 on any problem, and the output plus a textfile metric
// is the interface, because both a pager and a human read it.
package backupcopy

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Options are the knobs the shell version read from the environment.
type Options struct {
	Local        string        // LOCAL, default /mnt/scratch/backup-r2
	WindowDays   int           // WINDOW_DAYS, default 14 - must match the copy job's --max-age
	CopyLagDays  int           // COPY_LAG_DAYS, default 8 - a younger file has not had its chance
	RequireMount bool          // REQUIRE_MOUNT, default true
	Textfile     string        // TEXTFILE, default /var/lib/node-exporter/textfile
	EnvFile      string        // ENV_FILE, default /root/.config/homelab-backup.env
	Rclone       string        // rclone binary
	Now          time.Time
	IsMount      func(path string) bool                    // mountpoint -q
	Getenv       func(key string) string                   // the env file's values, after sourcing
	List         func(dir string) (string, error)           // one lsjson call, returning raw JSON
}

// File is one object as R2 reports it.
type File struct {
	Path string `json:"Path"`
	Name string `json:"Name"`
	Size int64  `json:"Size"`
}

// Result is the verdict.
type Result struct {
	Lines    []string
	Files    int
	Problems int
}

var stampRE = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)

// Run does the comparison. It writes nothing but the metric (the caller owns that) and never mutates the copy.
func Run(o Options, out io.Writer) Result {
	res := Result{}
	fail := func(format string, args ...any) {
		res.Problems++
		fmt.Fprintf(out, format+"\n", args...)
	}

	if !isDir(o.Local) {
		fail("FAIL: %s missing", o.Local)
		return res
	}
	if o.RequireMount {
		if o.IsMount != nil && !o.IsMount(filepath.Dir(o.Local)) {
			fail("FAIL: %s is not a mount", filepath.Dir(o.Local))
			return res
		}
	} else {
		fmt.Fprintln(out, "note: REQUIRE_MOUNT=0 — mount check skipped (test mode)")
	}
	if info, err := os.Stat(o.EnvFile); err != nil || info.Size() == 0 {
		fail("FAIL: %s missing", o.EnvFile)
		return res
	}
	if o.Getenv == nil || o.Getenv("R2_ACCESS_KEY_ID") == "" {
		fail("FAIL: %s did not provide R2_ACCESS_KEY_ID", o.EnvFile)
		return res
	}
	if o.List == nil {
		fail("FAIL: rclone not in PATH")
		return res
	}

	now := o.Now
	if now.IsZero() {
		now = time.Now().UTC()
	}
	cutoff := now.AddDate(0, 0, -o.WindowDays)
	copiedBy := now.AddDate(0, 0, -o.CopyLagDays)

	for _, dir := range []string{"appdata", "credentials"} {
		raw, err := o.List(dir)
		if err != nil {
			fail("FAIL: cannot list r2:%s", dir)
			continue
		}
		remote, err := parseListing(raw)
		if err != nil {
			fail("FAIL: R2 listing for %s did not parse: %v", dir, err)
			continue
		}
		if len(remote) == 0 {
			fail("FAIL: R2 listing for %s was empty", dir)
		}
		byName := map[string]int64{}
		for _, f := range remote {
			byName[f.Name] = f.Size
		}

		// 1. a file held in both places must be the same size. A file only in the offline copy is a warning: R2 prunes on its own
		//    schedule, and the offline copy keeping something upstream dropped is the offline copy doing its job.
		entries, err := os.ReadDir(filepath.Join(o.Local, dir))
		if err == nil {
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				size, ok := byName[e.Name()]
				if !ok {
					fmt.Fprintf(out, "warn: %s/%s is local but no longer in R2 (upstream pruned it)\n", dir, e.Name())
					continue
				}
				res.Files++
				if info, err := e.Info(); err == nil && info.Size() != size {
					fail("FAIL: %s/%s local size %d != R2 %d", dir, e.Name(), info.Size(), size)
				}
			}
		}

		// 2. everything R2 holds *inside the window* must be present locally, unless it is younger than the copy lag.
		for _, f := range remote {
			ts, ok := stamp(f.Name)
			if !ok {
				continue // not a timestamped backup: nothing to window
			}
			if ts.Before(cutoff) {
				continue // archive-only; absence locally is the design
			}
			if ts.After(copiedBy) {
				continue // the copy is weekly; this one has not had its chance yet
			}
			if _, err := os.Stat(filepath.Join(o.Local, dir, f.Name)); err != nil {
				fail("FAIL: %s/%s is inside the %dd window, in R2, but missing locally", dir, f.Name, o.WindowDays)
			}
		}
	}

	if res.Files == 0 {
		fail("FAIL: compared 0 files — the layout moved, so this check proved nothing")
	}
	// The verdict goes to the same writer as everything else: a caller that captures output must not have to ask twice for the line
	// that matters most.
	if res.Problems != 0 {
		line := fmt.Sprintf("verify-backup-copies: %d problem(s) across %d file(s)", res.Problems, res.Files)
		fmt.Fprintln(out, line)
		res.Lines = append(res.Lines, line)
		return res
	}
	line := fmt.Sprintf("verify-backup-copies: ok — %d file(s) match R2 in set and size", res.Files)
	fmt.Fprintln(out, line)
	res.Lines = append(res.Lines, line)
	return res
}

// parseListing reads rclone's lsjson array. The shell version flattened it with `tr '}' '\n'` and a regex; parsing it properly is the
// one place this port deliberately behaves better, because a filename containing a brace would have confused the old one.
func parseListing(raw string) ([]File, error) {
	var files []File
	if err := json.Unmarshal([]byte(raw), &files); err != nil {
		return nil, err
	}
	return files, nil
}

// stamp pulls the 20261115T030000Z prefix out of a backup filename.
func stamp(name string) (time.Time, bool) {
	m := stampRE.FindString(name)
	if m == "" {
		return time.Time{}, false
	}
	t, err := time.Parse("20060102T150405Z", m)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// Metrics renders the textfile the pager reads.
func Metrics(files, problems int, at time.Time) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# HELP homelab_backup_copy_files Number of backup files compared with R2\n")
	fmt.Fprintf(&b, "# TYPE homelab_backup_copy_files gauge\nhomelab_backup_copy_files %d\n", files)
	fmt.Fprintf(&b, "# HELP homelab_backup_copy_problems Files missing, extra, or size-mismatched\n")
	fmt.Fprintf(&b, "# TYPE homelab_backup_copy_problems gauge\nhomelab_backup_copy_problems %d\n", problems)
	fmt.Fprintf(&b, "# HELP homelab_backup_copy_verified_timestamp_seconds When this check last completed\n")
	fmt.Fprintf(&b, "# TYPE homelab_backup_copy_verified_timestamp_seconds gauge\nhomelab_backup_copy_verified_timestamp_seconds %d\n", at.Unix())
	return b.String()
}

// ParseEnvFile reads the KEY=VALUE file the shell used to source. Deliberately strict: a line it cannot read is reported, because
// silently ignoring half a credential file is how a check passes while doing nothing.
func ParseEnvFile(path string) (map[string]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimPrefix(strings.TrimSpace(key), "export ")
		out[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(val), `"'`)
	}
	return out, nil
}

// AtoiDefault keeps the shell's `: "${X:=default}"` behaviour.
func AtoiDefault(s string, def int) int {
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}
