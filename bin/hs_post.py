import json, os, re, sys, urllib.error, urllib.parse, urllib.request

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
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        # say Help Scout's own reason (a 412 on an old conversation is "Conversation locked", #116861)
        errors = (json.loads(e.read() or b"{}").get("_embedded") or {}).get("errors") or []
        sys.exit(f"{method} {path}: {e.code} " + ("; ".join(x.get("message", "") for x in errors) or e.reason))

# usage: hs_post.py <conversation id> <note.html> <reply.html | -> [status] [--claims-checked-by-background-reader | --no-claims] [--cc address …] [--check]
#   (reply posted as a draft; status on send defaults to closed; "-" posts the note alone)
# --check runs every check (formatting, the scale nudge) and says what would land, then stops: nothing is posted.
# Posting can't be undone (no edits, no deleting drafts), so check first whenever a nudge might change the draft.
# --cc copies the draft to an address the customer asked replies to go to (agencies, app-listing relays: #119405,
# #119459); it's on the draft, so Isaac sees it before sending
# a note without a status reopens the conversation (#119285), so each note carries the conversation's current one
# Posting a reply needs one of two flags: --claims-checked-by-background-reader when a separate reader has claim-checked
# it, or --no-claims when it asserts nothing at all (thanks, a question, a pointer to another thread). Any claim counts:
# how something behaves, what we did, what a record shows. Checking it yourself doesn't count: the pause is for the miss
# you can't see mid-flow (#119662's wrong reply), and the flags are named so they can't quietly stretch (Isaac,
# 2026-10-26, after one had; and 2026-11-24, when "product" in --no-product-claims let an "it's done" reply slip by)
argv, cc, send, check, claims = [], [], False, False, None
it = iter(sys.argv[1:])
for a in it:
    if a == "--claims-checked-by-background-reader":
        claims = "reader"
    elif a == "--no-claims":
        claims = "none"
    elif a in ("--claims", "--no-product-claims"):
        raise SystemExit(f"{a} is retired: use --claims-checked-by-background-reader, or --no-claims for a reply that asserts nothing")
    elif a == "--cc":
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
assert check or reply_path == "-" or claims, \
    "posting a reply wants --claims-checked-by-background-reader or --no-claims"
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
drafts_before = [x for x in c["_embedded"]["threads"] if x["type"] == "message" and x.get("state") == "draft"]

# reply at the customer's scale (lightward-ai's "a single line for a single line"; #119310): a nudge, not a refusal.
# Measured before posting, so --check can show it while the draft can still change (#119509)
if reply is not None:
    words = lambda html: len(re.sub(r"<[^>]+>", " ", html or "").split())
    said = next((t for t in c["_embedded"]["threads"] if t["type"] == "customer"), None)
    theirs, ours = words(said.get("body") if said else ""), words(reply)
    print(conv, f"scale: {ours} words to their {theirs}")
    if theirs and ours > max(80, 3 * theirs):
        print(f"   note: this reply is {ours} words to their {theirs}. Is that their scale? (A short message often wants a short answer.)")

# the reply's skeleton: each block as its size and first few words, the way a hurried reader takes it in, the words
# mostly out of view (Isaac, #120802: "if I squint, it looks like a thumbs-up email"; read it with the nouns taken out).
# Shape only: whether the news stands where an eye lands (top and bottom, not riding inside a hello) is the reader's call
if reply is not None:
    text = re.sub(r"<li>", "\n\n• ", reply)
    text = re.sub(r"<br\s*/?>\s*<br\s*/?>|</?(ol|ul)>", "\n\n", text)
    text = re.sub(r"<[^>]+>", " ", text)
    blocks = [re.sub(r"\s+", " ", b).strip() for b in re.split(r"\n\s*\n", text)]
    print(conv, "skeleton:")
    for b in (b for b in blocks if b):
        ws = b.split()
        print(f"   [{len(ws):>3}] {' '.join(ws[:6])}{' …' if len(ws) > 6 else ''}")

# who the reply reaches, beside who's in the conversation: the conversation's customer and the --cc addresses, against
# the latest customer message's sender, its to and cc, and the conversation's own cc. A reply goes to the customer and
# only the cc it carries, so anyone who wrote or was copied and isn't on it doesn't hear it (#120256: the answer said
# "with the Khaite team copied" and reached Maddie alone; Isaac: give the checkers the request's shape too)
if reply is not None:
    ours = lambda a: re.search(r"@(lightward\.com|uselocksmith\.com|usemechanic\.com|lightward\.inc)$", a or "")
    primary = (c.get("primaryCustomer") or {}).get("email", "")
    reaches = {a.lower() for a in [primary, *cc] if a}
    last = next((t for t in c["_embedded"]["threads"] if t["type"] == "customer"), {})  # newest first
    present = [(last.get("createdBy") or {}).get("email"), *(last.get("to") or []), *(last.get("cc") or []), *(c.get("cc") or [])]
    present = sorted({a.lower() for a in present if a and not ours(a)})
    print(conv, f"reaches: {primary or '(no customer email)'}" + (f"; cc {sorted(cc)}" if cc else "; no cc"))
    if missing := [a for a in present if a not in reaches]:
        print(f"   note: in this conversation but not on this reply: {missing}. Copy them with --cc if the reply is for them too.")

# a note keeps the conversation's status, except that a closed conversation getting a draft is reopened, so the draft
# shows in Unassigned (a draft's own status only takes effect when it's sent; Isaac found one hidden in Closed, #119370)
note_status = "active" if (reply is not None and c["status"] == "closed") else c["status"]
if check:
    print(conv, "#%s is %s; would post: note (leaving it %s)%s" % (c["number"], c["status"], note_status,
        "" if reply is None else f", {'reply SENT' if send else 'draft'} (status on send: {status})" + (f", cc {cc}" if cc else "")))
    if reply is not None and drafts_before:
        print(conv, f"note: {len(drafts_before)} draft(s) already waiting here; a new one would sit beside them")
    print(conv, "checked; nothing posted")
    sys.exit(0)
print(conv, "note:", call("POST", f"/conversations/{conv}/notes", {"text": note, "user": CLAUDE, "status": note_status})[0])
# the before-acting hook reads this file and passes it as a drafter on the literal draft flag above; --send is caught
# by its own rule on the command line
if reply is not None: print(conv, "sent:" if send else "draft:", call("POST", f"/conversations/{conv}/reply",
    {"customer": {"id": c["primaryCustomer"]["id"]}, "text": reply, "draft": True if not send else False, "status": status, "user": CLAUDE,
     **({"cc": cc} if cc else {})})[0])
_, c = call("GET", f"/conversations/{conv}?embed=threads")
# list from the threads endpoint, the one hs_read's queue counts drafts from: the embedded list showed one draft of
# mine on #120848 while the conversation held two (Isaac found and discarded the older one), so it isn't the record
_, t = call("GET", f"/conversations/{conv}/threads")
threads = t["_embedded"]["threads"]
mine = [f"{x['type']}/{x.get('state')}" for x in threads if (x.get("createdBy") or {}).get("id") == CLAUDE]
print(conv, "#%s status=%s mine:" % (c["number"], c["status"]), mine, f"https://secure.helpscout.net/conversation/{conv}/{c['number']}")
# a read taken right after a write can miss threads: on #120848 this listing showed one draft of mine while the
# conversation held two (Isaac found and discarded the older one), and the same reads agreed again minutes later.
# So the count of drafts that were already waiting comes from the read before posting, which nothing raced.
if reply is not None and drafts_before:
    print(conv, f"note: {len(drafts_before)} other draft(s) were already waiting here; this one sits beside them, so say in the note which goes and which to discard")
if cc:
    d = next((t for t in c["_embedded"]["threads"] if t["type"] == "message" and t["createdBy"].get("id") == CLAUDE
              and (t.get("state") == "draft") != send), {})
    print(conv, "sent cc:" if send else "draft cc:", d.get("cc"))

