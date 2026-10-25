import html as H
import re
import sys

# Parse a library-mirror search page and print "<score>\t<md5>\t<label>" for the
# best rows. Called by books-fetch.sh; kept as its own file so the shell side
# stays simple and the matching rules are readable.
raw = sys.stdin.read()
want, author = sys.argv[1], sys.argv[2]

STOP = {"the", "a", "an", "of", "and", "to", "in", "for", "on", "with", "your", "you",
        "how", "is", "be", "book", "novel", "series", "vol", "volume", "edition"}


def toks(s):
    s = re.sub(r"[^a-z0-9 ]+", " ", s.lower().replace("&", " and "))
    return {t for t in s.split() if t and t not in STOP}


core = re.split(r"\s+[-\u2013:]\s+|:\s+", want)[0]
need = toks(core)
surname = toks(author.split()[-1])

rows = []
for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", raw, re.S | re.I):
    md5 = re.search(r"md5=([a-f0-9]{32})", tr)
    if not md5:
        continue
    # the title cell is the first link text that is not purely numeric
    texts = [H.unescape(re.sub(r"<[^>]+>", "", t)).strip()
             for t in re.findall(r"<a[^>]*>(.*?)</a>", tr, re.S)]
    texts = [t for t in texts if t and not re.fullmatch(r"[\d\s.,]+", t)]
    if not texts:
        continue
    label = " | ".join(texts[:3])
    have = toks(label)
    t = len(need & have) / len(need) if need else 0.0
    a = 1.0 if surname <= have else 0.0
    size = re.search(r"(\d+(?:\.\d+)?)\s*(MB|KB|GB)", tr, re.I)
    rows.append((0.75 * t + 0.25 * a, md5.group(1),
                 label[:80] + (f" [{size.group(1)}{size.group(2)}]" if size else "")))

rows.sort(reverse=True)
for score, md5, label in rows[:5]:
    print(f"{score:.3f}\t{md5}\t{label}")
