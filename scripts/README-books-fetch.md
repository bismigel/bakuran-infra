# books-fetch.sh

Ebooks that no *arr can find, placed straight into the library.

## Why this exists instead of LazyLibrarian

Measured 2026-10-24 against the running stack:

| Source | Result |
|---|---|
| NZBGeek via Prowlarr, `Database Internals` by title | 0 hits |
| NZBGeek via Prowlarr, `Petrov` by author | 0 hits |
| AudioBookBay | not in Prowlarr's 663 indexer definitions |
| EBookBay (public torrent) | added, then `Search failed due to all selected indexers being unavailable` (blocks our egress) |
| Anna's Archive | a DDL site, not a Newznab indexer — Prowlarr cannot host it |
| **library mirror (`libgen.li`)** | **works**: 7 hits, direct EPUB/PDF download |

So the pipeline for these books ends at the **filesystem**, not at SAB. Kavita's
nightly scan (`books/kavita-scan`) imports whatever lands in the library, and a
forced scan takes ~8 seconds.

## Usage

```bash
./scripts/books-fetch.sh --dry-run --author "Alex Petrov" --title "Database Internals"
./scripts/books-fetch.sh --apply   --author "Alex Petrov" --title "Database Internals"
./scripts/books-fetch.sh --dry-run --wanted     # every Wanted book in LazyLibrarian
```

`--dry-run` is the default. `--apply` actually downloads and writes.

## How it works

1. Search the mirror for `"<title> <author-surname>"`.
2. Parse the result table (`mirror-parse`, Go in homelab-context — a real HTML parser; a
   shell regex over `<tr>` rows was the first version and it silently matched
   nothing).
3. Score each row: 75% core-title token overlap (the part before ` - ` or `:`,
   because LazyLibrarian stores Goodreads strings with long subtitles) + 25% for
   the author surname being present. **Threshold 0.9**, below that it does not
   grab.
4. Fetch the `get.php` link from `ads.php?md5=…`, verify the file is really
   EPUB/PDF (`file -b`), then write it to
   `/mnt/media/books/<Author>/<Title>/<Title> - <Author>.<ext>` with uid 1000 —
   the same layout LazyLibrarian uses, so Kavita's series parsing is consistent.
5. Idempotent: an existing destination file is skipped.

## Known limits

- Depends on one reachable mirror. `annas-archive.org`, `libgen.is` and
  `library.lol` are all unreachable from this network; only `libgen.li` answers.
- Some results are behind a captcha; the script reports `no download link` and
  moves on.
- It does not touch LazyLibrarian's database: a book fetched this way still shows
  as `Wanted` there until it is marked manually. Kavita is the source of truth
  for "do I have this book".
- No audiobooks. Audio needs a private tracker or a Cloudflare-bypass proxy;
  nothing reachable today serves them.
