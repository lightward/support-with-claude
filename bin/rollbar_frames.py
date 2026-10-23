#!/usr/bin/env python3
"""An item's latest occurrence, as a backtrace: title, request method and path, and the app's own frames.

    python3 -I rollbar_frames.py <locksmith|mechanic|lightward-ai|yours> <item counter> [...]

Counters are the #numbers rollbar_shop.py lists. Read-only, with the app's read-only token from 1Password (a read may
ask Isaac for Touch ID). Prints no headers, no bodies, no query strings, no person data: those can carry content about
whoever sent the request. Frames from gems are skipped; the first app frame is usually where to look.
"""
import json, subprocess, sys, urllib.request

TOKENS = {
    "locksmith": "eye2k3sfrj5xu55y3edqwvdkcy",
    "mechanic": "vr47x4u2ho635f4umfgchsirne",
    "lightward-ai": "otvcbtocp7wuynqlmuidjact7a",
    "yours": "7zvcur6qepyx2rcdoriq6rth6u",
}

app, counters = sys.argv[1], sys.argv[2:]
token = subprocess.run(["op", "read", f"op://Lightward/4hnfbn3if74m63hclzipmuqlgu/secrets on tap/{TOKENS[app]}"],
                       capture_output=True, text=True, check=True).stdout.strip()


def get(path):
    r = urllib.request.Request("https://api.rollbar.com/api/1" + path, headers={"X-Rollbar-Access-Token": token})
    d = json.load(urllib.request.urlopen(r, timeout=30))
    if d.get("err"):
        sys.exit(f"rollbar: {d.get('message')}")
    return d["result"]


for n in counters:
    item = get(f"/item_by_counter/{n}")
    instances = get(f"/item/{item['id']}/instances/")["instances"]
    print(f"== #{n} {item.get('title')} ({item.get('total_occurrences')}x, {item.get('status')})")
    if not instances:
        continue
    d = instances[0]["data"]
    req = d.get("request") or {}
    if req:
        print(f"   {req.get('method')} {(req.get('url') or '').split('?')[0]}")
    body = d.get("body", {})
    traces = body.get("trace_chain") or ([body["trace"]] if "trace" in body else [])
    for trace in traces:
        exc = trace.get("exception", {})
        print(f"   {exc.get('class')}: {(exc.get('message') or '')[:200]}")
        for f in reversed(trace.get("frames", [])):
            fn = f.get("filename", "")
            if "/gems/" in fn or "/ruby/" in fn or "/node_modules/" in fn:
                continue
            print(f"     {fn}:{f.get('lineno')} {f.get('method')}")
