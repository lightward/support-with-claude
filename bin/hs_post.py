import json, os, sys, urllib.parse, urllib.request

VAULT_ITEM = "op://t7mb6kqfnvc5jigfevgvn7k35a/4hnfbn3if74m63hclzipmuqlgu"  # Lightward / HelpScout - claude@lightward.com

def _credentials():
    import subprocess
    try:
        read = lambda f: subprocess.run(["op", "read", f"{VAULT_ITEM}/{f}"], capture_output=True, text=True, check=True).stdout.strip()
        return read("app id"), read("app secret")
    except (OSError, subprocess.CalledProcessError):
        env = dict(l.strip().split("=", 1) for l in open(os.path.expanduser("~/dev/mechanic-api/.env")) if l.startswith("CLAUDE_HELPSCOUT_"))
        return env["CLAUDE_HELPSCOUT_APP_ID"], env["CLAUDE_HELPSCOUT_APP_SECRET"]

def _token():
    app_id, app_secret = _credentials()
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": app_id, "client_secret": app_secret}).encode()
    return json.load(urllib.request.urlopen("https://api.helpscout.net/v2/oauth2/token", data))["access_token"]

TOKEN = _token()
CLAUDE = 908315

def call(method, path, body=None):
    r = urllib.request.Request("https://api.helpscout.net/v2" + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(r) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw else None)

# usage: hs_post.py <conversation id> <note.html> <reply.html | -> [status]   (reply posted as a draft; status on send defaults to closed; "-" posts the note alone)
# a note without a status reopens the conversation (#119285), so each note carries the conversation's current one
conv, note_path, reply_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
status = sys.argv[4] if len(sys.argv) > 4 else "closed"
assert status in ("active", "pending", "closed"), status
note = open(note_path).read().strip()
reply = None if reply_path == "-" else open(reply_path).read().strip()
for name, html in (("note", note), ("reply", reply or "")):
    assert "<p>" not in html and "<p " not in html, f"{name} has <p>; use <br><br>"

_, c = call("GET", f"/conversations/{conv}")
print(conv, "note:", call("POST", f"/conversations/{conv}/notes", {"text": note, "user": CLAUDE, "status": c["status"]})[0])
if reply is not None: print(conv, "draft:", call("POST", f"/conversations/{conv}/reply",
    {"customer": {"id": c["primaryCustomer"]["id"]}, "text": reply, "draft": True, "status": status, "user": CLAUDE})[0])
_, c = call("GET", f"/conversations/{conv}?embed=threads")
mine = [f"{t['type']}/{t['state']}" for t in c["_embedded"]["threads"] if t["createdBy"].get("id") == CLAUDE]
print(conv, "#%s status=%s mine:" % (c["number"], c["status"]), mine, f"https://secure.helpscout.net/conversation/{conv}/{c['number']}")
