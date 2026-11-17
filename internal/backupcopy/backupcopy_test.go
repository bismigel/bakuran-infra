package backupcopy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)

// fixture builds a local copy plus a canned R2 listing. The shell version's own header says REQUIRE_MOUNT=0 exists so its two failure
// directions can be tested "without touching the real one" - this is that test, in the port.
func fixture(t *testing.T, local map[string]int64, r2 map[string]string) Options {
	t.Helper()
	root := t.TempDir()
	for name, size := range local {
		p := filepath.Join(root, "local", name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, make([]byte, size), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, dir := range []string{"local/appdata", "local/credentials"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env := filepath.Join(root, "backup.env")
	if err := os.WriteFile(env, []byte("R2_ACCESS_KEY_ID=x\nR2_BUCKET=b\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return Options{
		Local:       filepath.Join(root, "local"),
		WindowDays:  14,
		CopyLagDays: 8,
		EnvFile:     env,
		Textfile:    filepath.Join(root, "metrics"),
		Now:         now,
		Getenv:      func(k string) string { return map[string]string{"R2_ACCESS_KEY_ID": "x"}[k] },
		List:        func(dir string) (string, error) { return r2[dir], nil },
	}
}

const (
	inWindow   = "20261110T030000Z" // 8 days old: inside the 14d window, older than the 8d copy lag
	archive    = "20261001T030000Z"
	tooYoung   = "20261117T030000Z"
)

func TestRun(t *testing.T) {
	cases := []struct {
		name     string
		local    map[string]int64
		r2       map[string]string
		wantCode int
		contains []string
	}{
		{
			name:     "everything matches",
			local:    map[string]int64{"appdata/app-" + inWindow + ".age": 100},
			r2:       map[string]string{"appdata": `[{"Name":"app-` + inWindow + `.age","Size":100}]`, "credentials": `[{"Name":"x","Size":1}]`},
			wantCode: 0,
			contains: []string{"ok — 1 file(s) match R2 in set and size"},
		},
		{
			name:     "a truncated copy is the failure that happened",
			local:    map[string]int64{"appdata/app-" + inWindow + ".age": 999},
			r2:       map[string]string{"appdata": `[{"Name":"app-` + inWindow + `.age","Size":100}]`, "credentials": `[{"Name":"x","Size":1}]`},
			wantCode: 1,
			contains: []string{"local size 999 != R2 100"},
		},
		{
			name:     "in the window and missing locally",
			local:    map[string]int64{},
			r2:       map[string]string{"appdata": `[{"Name":"app-` + inWindow + `.age","Size":100}]`, "credentials": `[{"Name":"x","Size":1}]`},
			wantCode: 1,
			contains: []string{"inside the 14d window, in R2, but missing locally"},
		},
		{
			name:     "archive-only absence is the design, not a fault",
			local:    map[string]int64{"appdata/app-" + inWindow + ".age": 100},
			r2:       map[string]string{"appdata": `[{"Name":"app-` + inWindow + `.age","Size":100},{"Name":"app-` + archive + `.age","Size":5}]`, "credentials": `[{"Name":"x","Size":1}]`},
			wantCode: 0,
			contains: []string{"ok — 1 file(s)"},
		},
		{
			name:     "a file younger than the copy lag proves nothing",
			local:    map[string]int64{"appdata/app-" + inWindow + ".age": 100},
			r2:       map[string]string{"appdata": `[{"Name":"app-` + inWindow + `.age","Size":100},{"Name":"app-` + tooYoung + `.age","Size":5}]`, "credentials": `[{"Name":"x","Size":1}]`},
			wantCode: 0,
			contains: []string{"ok — 1 file(s)"},
		},
		{
			name:     "a pruned upstream file is a warning",
			local:    map[string]int64{"appdata/app-" + inWindow + ".age": 100, "appdata/old.age": 5},
			r2:       map[string]string{"appdata": `[{"Name":"app-` + inWindow + `.age","Size":100}]`, "credentials": `[{"Name":"x","Size":1}]`},
			wantCode: 0,
			contains: []string{"warn: appdata/old.age is local but no longer in R2"},
		},
		{
			name:     "reading nothing must fail",
			local:    map[string]int64{},
			r2:       map[string]string{"appdata": `[]`, "credentials": `[]`},
			wantCode: 1,
			contains: []string{"compared 0 files — the layout moved, so this check proved nothing"},
		},
		{
			name:     "an unparsable listing fails rather than passing",
			local:    map[string]int64{},
			r2:       map[string]string{"appdata": `not json`, "credentials": `[]`},
			wantCode: 1,
			contains: []string{"did not parse"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			opts := fixture(t, tc.local, tc.r2)
			var b strings.Builder
			res := Run(opts, &b)
			code := 0
			if res.Problems != 0 {
				code = 1
			}
			if code != tc.wantCode {
				t.Fatalf("exit %d, want %d:\n%s", code, tc.wantCode, b.String())
			}
			for _, want := range tc.contains {
				if !strings.Contains(b.String(), want) {
					t.Fatalf("output missing %q:\n%s", want, b.String())
				}
			}
		})
	}
}

// A missing local directory is the vanished-mount case: the mount is gone, so the directory is gone.
func TestMissingLocal(t *testing.T) {
	opts := fixture(t, nil, nil)
	opts.Local = filepath.Join(t.TempDir(), "gone")
	var b strings.Builder
	res := Run(opts, &b)
	if res.Problems == 0 || !strings.Contains(b.String(), "missing") {
		t.Fatalf("a missing copy must fail:\n%s", b.String())
	}
}
