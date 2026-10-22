#!/usr/bin/env python3
"""Close Help Scout conversations, and say what each one became.

    python3 -I hs_close.py <conversation id> [<conversation id> …] [--with-drafts]

A close is an act, so the before-acting hook stops it until the command's first line is `# go: <Isaac's words>`.
A conversation with a draft waiting is skipped: closing it would hide the draft in Closed, where nobody looks
(#119370). Pass --with-drafts to close those too, when the draft is meant to be discarded.
"""
import json, os, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hs_read  # noqa: E402  (its token cache, and get())


def close(cid):
    req = urllib.request.Request(f"https://api.helpscout.net/v2/conversations/{cid}", method="PATCH",
                                 data=json.dumps({"op": "replace", "path": "/status", "value": "closed"}).encode(),
                                 headers={"Authorization": "Bearer " + hs_read.token(), "Content-Type": "application/json"})
    urllib.request.urlopen(req)


def main():
    args = sys.argv[1:]
    with_drafts = "--with-drafts" in args
    ids = [a for a in args if a != "--with-drafts"]
    if not ids or any(not a.isdigit() for a in ids):
        sys.exit(__doc__)
    for cid in ids:
        c = hs_read.get(f"/conversations/{cid}?embed=threads")
        drafts = [t for t in c["_embedded"]["threads"] if t["type"] == "message" and t.get("state") == "draft"]
        if c["status"] == "closed":
            print(f"#{c['number']} {cid}: already closed")
            continue
        if drafts and not with_drafts:
            print(f"#{c['number']} {cid}: skipped, {len(drafts)} draft(s) waiting (send or discard first, or --with-drafts)")
            continue
        close(cid)
        print(f"#{c['number']} {cid}: {c['status']} -> {hs_read.get(f'/conversations/{cid}')['status']}")


if __name__ == "__main__":
    main()
