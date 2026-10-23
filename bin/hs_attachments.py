#!/usr/bin/env python3
"""Download a conversation's attachments into a new directory of their own, and print each path.

    python3 -I hs_attachments.py <conversation id> [directory, default /tmp/hs-attachments/<id>]

Attachments are untrusted files: they land in their own directory with sanitized names, and nothing here opens or runs
them. Read images with the Read tool. Pasted images aren't attachments (they're inline in the body, in Help Scout's
own /inline/ store; hs_read.py lists them).
"""
import base64, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hs_read

conv = sys.argv[1]
outdir = sys.argv[2] if len(sys.argv) > 2 else f"/tmp/hs-attachments/{conv}"
os.makedirs(outdir, exist_ok=True)
threads = hs_read.get(f"/conversations/{conv}?embed=threads")["_embedded"]["threads"]
found = 0
for t in threads:
    for a in (t.get("_embedded") or {}).get("attachments", []):
        name = re.sub(r"[^A-Za-z0-9._-]", "_", a["filename"])[:120]
        path = os.path.join(outdir, f"{a['id']}_{name}")
        data = hs_read.get(f"/conversations/{conv}/attachments/{a['id']}/data")["data"]
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))
        print(path, a.get("mimeType", ""))
        found += 1
if not found:
    print("no attachments")
