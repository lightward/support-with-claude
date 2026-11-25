#!/bin/zsh
# one round of accumulating blind readers: every reader who has come so far is resumed with the newest stretch,
# and one new reader arrives cold with the whole draft. blind: a fresh `claude -p` with no tools, started in a
# working directory with no CLAUDE.md above it (BLOG_WORK, default /tmp/blog-work; never inside a repo), so each
# reader has nothing but the text. resumed readers keep their own memory of the earlier stretches.
# usage: readers.sh N   (in BLOG_WORK: draft.md is the whole draft so far; stretch.md is what's new since round N-1,
# with any revisions to earlier lines said in a sentence at its top). prints each reader's response.
n=$1; mkdir -p "${BLOG_WORK:-/tmp/blog-work}"; cd "${BLOG_WORK:-/tmp/blog-work}"
case "$PWD" in "$HOME"/dev/*) echo "BLOG_WORK is inside ~/dev: a reader there would carry a CLAUDE.md" >&2; exit 1;; esac
mkdir -p sessions out
ask='I am hoping to read *you*, reading it, as your own kind of reader, not simulating any particular other reader: your thoughts as you go, where it lands, where you slow down or stop, what you wonder. A ████ marks something not said yet; react to it however it strikes you.'
for f in sessions/*(N); do
  id=$(cat $f)
  timeout 240 claude -p --tools "" --output-format json --resume "$id" -- "The writer kept going. Here is what is new since you last read (earlier lines may have been revised a little):

---
$(cat stretch.md)
---

$ask" < /dev/null > out/$n-$(basename $f).json &
done
timeout 240 claude -p --tools "" --output-format json -- "May I run some writing by you? It is a piece in progress, and you are arriving with no other context. Here is everything written so far:

---
$(cat draft.md)
---

$ask" < /dev/null > out/$n-new.json &
wait
python3 - "$n" <<'PY'
import json, sys, glob, os
n = sys.argv[1]
for p in sorted(glob.glob(f"out/{n}-*.json")):
    who = p.split(f"{n}-",1)[1][:-5]
    try: d = json.load(open(p))
    except Exception as e: print(f"## {who}: unreadable ({e})"); continue
    if who == "new":
        k = len(glob.glob("sessions/*")) + 1
        open(f"sessions/r{k}", "w").write(d["session_id"]); who = f"r{k} (new)"
    print(f"## {who}\n{d.get('result','').strip()}\n")
PY
