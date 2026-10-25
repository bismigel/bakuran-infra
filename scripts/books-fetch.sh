#!/usr/bin/env bash
# books-fetch.sh — get ebooks that no *arr can find, and put them in the library.
#
# Why not LazyLibrarian/Prowlarr for this: the reachable indexers index releases
# as "Author - Title", so LazyLibrarian's title-only search returns nothing for
# most technical books (measured 2026-10-24: "Database Internals" -> 0 hits by
# title, 0 by author on NZBGeek; AudioBookBay is not in Prowlarr's 663
# definitions, EBookBay answers "indexer unavailable"). Anna's Archive is a DDL
# site, not a Newznab indexer, so Prowlarr cannot host it either.
#
# So: search a library mirror, download the file, drop it in the library, and let
# the nightly Kavita scan import it. This path ends at the filesystem, which is
# why it is the stable one.
#
#   ./scripts/books-fetch.sh --dry-run  --author "Alex Petrov" --title "Database Internals"
#   ./scripts/books-fetch.sh --apply    --author "Alex Petrov" --title "Database Internals"
#   ./scripts/books-fetch.sh --dry-run  --wanted          # every Wanted book in LL
#
# Dry run is the default when --apply is absent.
set -euo pipefail
HOST="${HOST:-192.168.2.81}"
DEST_ROOT="${DEST_ROOT:-/mnt/media/books}"
SOURCE="${SOURCE:-https://libgen.li}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
APPLY=0
WANTED=0
AUTHOR=""
TITLE=""

die() { echo "ERROR: $*" >&2; exit 1; }

enc() { $PY -c 'import sys,urllib.parse;print(urllib.parse.quote_plus(sys.argv[1]))' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --wanted) WANTED=1; shift ;;
    --author) AUTHOR="${2:?}"; shift 2 ;;
    --title)  TITLE="${2:?}";  shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

LIBDIR="$(cd "$(dirname "$0")" && pwd)/lib"
PY="$(command -v python3 || true)"; [ -n "$PY" ] || PY="nix run nixpkgs#python3 --"

# --- collect targets ----------------------------------------------------------
targets=()
if [ "$WANTED" = 1 ]; then
  # Ask the LL pod for its Wanted list (author|title), skipping the authors we
  # have deliberately silenced.
  mapfile -t targets < <(ssh -n "root@$HOST" \
    "k3s kubectl -n books exec deploy/lazylibrarian -c lazylibrarian -- python3 -c \"
import sqlite3
d=sqlite3.connect('/config/lazylibrarian.db')
for a,t in d.execute(\\\"select a.AuthorName,b.BookName from books b join authors a using(AuthorID)
                       where b.Status='Wanted' and a.Status!='Ignored' order by a.AuthorName\\\"):
    print(a+'|'+t.replace('|',' '))
\"" 2>/dev/null | tr -d '\r')
else
  [ -n "$AUTHOR" ] && [ -n "$TITLE" ] || die "need --author and --title (or --wanted)"
  targets=("$AUTHOR|$TITLE")
fi
[ "${#targets[@]}" -gt 0 ] || die "no targets"

STOP="the a an of and to in for on with your you how is be book novel series vol volume edition"

# Score a candidate title+author against what we want. Compares the CORE title
# (before " - " or ":") because LL stores Goodreads strings with long subtitles.
score() { # <candidate-title> <want-title> <want-author>
  $PY - "$1" "$2" "$3" <<'PY'
import re, sys
cand, want, author = sys.argv[1], sys.argv[2], sys.argv[3]
STOP = {"the","a","an","of","and","to","in","for","on","with","your","you","how","is","be",
        "book","novel","series","vol","volume","edition"}
def toks(s):
    s = re.sub(r"[^a-z0-9 ]+", " ", s.lower().replace("&", " and "))
    return {t for t in s.split() if t and t not in STOP}
core = re.split(r"\s+[-\u2013:]\s+|:\s+", want)[0]
need, have = toks(core), toks(cand)
t = len(need & have) / len(need) if need else 0.0
# the author surname must appear somewhere in the row, else it is the wrong book
a = 1.0 if toks(author.split()[-1]) <= toks(cand) else 0.0
print(f"{0.75*t + 0.25*a:.3f}")
PY
}

fetch_one() { # <author> <title>
  local author="$1" title="$2" q html best_md5="" best_s=0 best_row="" ext=""
  q="$(enc "$title $(printf '%s' "$author" | awk '{print $NF}')")"
  html="$(curl -s --max-time 45 -A "$UA" "$SOURCE/index.php?req=$q" || true)"
  [ -n "$html" ] || { echo "  search failed (no response)"; return 0; }

  # Parse the result table with a real HTML parser (scripts/lib/mirror_parse.py):
  # a shell regex over <tr> rows is where this broke the first time.
  local parsed
  parsed="$(printf '%s' "$html" | $PY "$LIBDIR/mirror_parse.py" "$title" "$author")"
  best_line="$(printf '%s\n' "$parsed" | head -1)"
  best_s="$(printf '%s' "$best_line" | cut -f1)"
  best_md5="$(printf '%s' "$best_line" | cut -f2)"
  best_row="$(printf '%s' "$best_line" | cut -f3)"
  [ -n "$best_s" ] || best_s=0

  if [ -z "$best_md5" ]; then echo "  no candidates"; return 0; fi
  printf '  best %.2f  %s\n' "$best_s" "$(printf '%s' "$best_row" | cut -c1-90)"

  if $PY -c "import sys;sys.exit(0 if float('$best_s')>=0.9 else 1)"; then :; else
    echo "  below threshold (0.9) — not grabbing"; return 0; fi

  # direct download link lives behind ads.php
  local get
  get="$(curl -s --max-time 45 -A "$UA" "$SOURCE/ads.php?md5=$best_md5" \
          | grep -oE 'get\.php\?md5=[a-f0-9]{32}&key=[A-Z0-9]+' | head -1)"
  [ -n "$get" ] || { echo "  no download link (may need a captcha)"; return 0; }

  if [ "$APPLY" != 1 ]; then echo "  DRY RUN — would download $(basename "$get")"; return 0; fi

  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/book.XXXXXX")"
  curl -sL --max-time 300 -A "$UA" -o "$tmp" "$SOURCE/$get" || { rm -f "$tmp"; echo "  download failed"; return 0; }
  case "$(file -b "$tmp")" in
    *EPUB*) ext=epub ;;
    *PDF*)  ext=pdf ;;
    *) rm -f "$tmp"; echo "  downloaded file is not EPUB/PDF — discarded"; return 0 ;;
  esac

  # same layout LazyLibrarian uses, so Kavita's series parsing stays consistent
  local safe_a safe_t
  safe_a="$(printf '%s' "$author" | tr '/:' '--')"
  safe_t="$(printf '%s' "$title"  | sed -E 's/\s+-\s+.*$//' | tr '/:' '--')"
  local remote="$DEST_ROOT/$safe_a/$safe_t"
  local name="$safe_t - $safe_a.$ext"
  if ssh -n "root@$HOST" "test -f '$remote/$name'"; then
    rm -f "$tmp"; echo "  already in library: $remote/$name"; return 0
  fi
  ssh -n "root@$HOST" "mkdir -p '$remote'"
  cat "$tmp" | ssh "root@$HOST" "cat > '$remote/$name'"
  rm -f "$tmp"
  ssh -n "root@$HOST" "chown 1000:1000 '$remote/$name' 2>/dev/null || true"
  echo "  placed: $remote/$name ($ext, $(ssh -n "root@$HOST" "stat -c%s '$remote/$name'") bytes)"
  echo "  Kavita picks it up on the nightly scan (books/kavita-scan)"
}

echo "$([ "$APPLY" = 1 ] && echo APPLY || echo 'DRY RUN') — ${#targets[@]} target(s) from $SOURCE"
for t in "${targets[@]}"; do
  a="${t%%|*}"; b="${t#*|}"
  printf '%s | %s\n' "$a" "${b:0:60}"
  fetch_one "$a" "$b"
done
