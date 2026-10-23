import json, os, re, sys, urllib.parse, urllib.request

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

# usage: hs_post.py <conversation id> <note.html> <reply.html | -> [status] [--cc address …] [--check]
#   (reply posted as a draft; status on send defaults to closed; "-" posts the note alone)
# --check runs every check (formatting, the scale nudge) and says what would land, then stops: nothing is posted.
# Posting can't be undone (no edits, no deleting drafts), so check first whenever a nudge might change the draft.
# --cc copies the draft to an address the customer asked replies to go to (agencies, app-listing relays: #119405,
# #119459); it's on the draft, so Isaac sees it before sending
# a note without a status reopens the conversation (#119285), so each note carries the conversation's current one
argv, cc, send, check = [], [], False, False
it = iter(sys.argv[1:])
for a in it:
    if a == "--cc":
        cc.append(next(it))
    elif a == "--check":
        check = True
    elif a == "--send":
        # sends the reply instead of drafting it: only under a standing go Isaac has given for a kind of reply (the
        # PHP-CVE wave, 2026-10-22), and the before-acting hook stops it without a go line on the command
        send = True
    else:
        argv.append(a)
for addr in cc:
    assert re.fullmatch(r"[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+", addr), f"--cc wants one address: {addr!r}"
conv, note_path, reply_path = int(argv[0]), argv[1], argv[2]
status = argv[3] if len(argv) > 3 else "closed"
assert not (cc and reply_path == "-"), "--cc needs a reply to copy"
assert not (send and reply_path == "-"), "--send needs a reply to send"
assert status in ("active", "pending", "closed"), status
note = open(note_path).read().strip()
reply = None if reply_path == "-" else open(reply_path).read().strip()
for name, html in (("note", note), ("reply", reply or "")):
    assert "<p>" not in html and "<p " not in html, f"{name} has <p>; use <br><br>"
    # a list gets a full blank line before and after it (Isaac, 2026-10-20): <br><br><ol> … </ol><br>
    for m in re.finditer(r"<(ol|ul)[ >]", html):
        assert m.start() == 0 or html[:m.start()].endswith(("<br><br>", "<li>")), \
            f"{name}: a list needs <br><br> before it: …{html[max(0, m.start() - 40):m.start() + 4]}"
    for m in re.finditer(r"</(ol|ul)>", html):
        rest = html[m.end():]
        assert rest == "" or rest.startswith("<br>"), f"{name}: a list needs <br> after it: …{html[m.start():m.end() + 30]}"

_, c = call("GET", f"/conversations/{conv}?embed=threads")

# reply at the customer's scale (lightward-ai's "a single line for a single line"; #119310): a nudge, not a refusal.
# Measured before posting, so --check can show it while the draft can still change (#119509)
if reply is not None:
    words = lambda html: len(re.sub(r"<[^>]+>", " ", html or "").split())
    said = next((t for t in c["_embedded"]["threads"] if t["type"] == "customer"), None)
    theirs, ours = words(said.get("body") if said else ""), words(reply)
    print(conv, f"scale: {ours} words to their {theirs}")
    if theirs and ours > max(80, 3 * theirs):
        print(f"   note: this reply is {ours} words to their {theirs}. Is that their scale? (A short message often wants a short answer.)")

# a note keeps the conversation's status, except that a closed conversation getting a draft is reopened, so the draft
# shows in Unassigned (a draft's own status only takes effect when it's sent; Isaac found one hidden in Closed, #119370)
note_status = "active" if (reply is not None and c["status"] == "closed") else c["status"]
if check:
    print(conv, "#%s is %s; would post: note (leaving it %s)%s" % (c["number"], c["status"], note_status,
        "" if reply is None else f", {'reply SENT' if send else 'draft'} (status on send: {status})" + (f", cc {cc}" if cc else "")))
    print(conv, "checked; nothing posted")
    sys.exit(0)
print(conv, "note:", call("POST", f"/conversations/{conv}/notes", {"text": note, "user": CLAUDE, "status": note_status})[0])
# the before-acting hook reads this file and passes it as a drafter on the literal draft flag above; --send is caught
# by its own rule on the command line
if reply is not None: print(conv, "sent:" if send else "draft:", call("POST", f"/conversations/{conv}/reply",
    {"customer": {"id": c["primaryCustomer"]["id"]}, "text": reply, "draft": True if not send else False, "status": status, "user": CLAUDE,
     **({"cc": cc} if cc else {})})[0])
_, c = call("GET", f"/conversations/{conv}?embed=threads")
mine = [f"{t['type']}/{t.get('state')}" for t in c["_embedded"]["threads"] if t["createdBy"].get("id") == CLAUDE]
print(conv, "#%s status=%s mine:" % (c["number"], c["status"]), mine, f"https://secure.helpscout.net/conversation/{conv}/{c['number']}")
if cc:
    d = next((t for t in c["_embedded"]["threads"] if t.get("state") == "draft" and t["createdBy"].get("id") == CLAUDE), {})
    print(conv, "draft cc:", d.get("cc"))

