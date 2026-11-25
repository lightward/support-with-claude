#!/usr/bin/env python3
"""The shape of Help Scout conversations, as JSON lines: who spoke, as what, when, and whom a note mentions, in order.

  hs_shape.py queue           every non-closed conversation in each mailbox's Unassigned folder
  hs_shape.py <id> [<id> …]   these conversations

Each conversation also carries its mailbox's users (Help Scout's list of who can reply as it, by first name), and
each thread its author's type (user or customer): the arrow under "speaks as the mailbox", read from Help Scout
apart from the threads it licenses.

No bodies, subjects, emails or names of customers: only the shape crosses, so whatever reads it (everyoneishere's
bin/helpscout_fold.rb, for one) can fold a queue without holding anyone's words. A draft comes through as its author only: it says
nothing yet, but it shows someone has taken the conversation up.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hs_read


_users = {}


def users(mailbox_id):
    """The mailbox's users, as Help Scout says (who can speak as the mailbox), by first name, lowercase: read
    apart from the threads they license, so a reader can refuse a reply whose author isn't one of them."""
    if mailbox_id not in _users:
        names, page = set(), 1
        while True:
            r = hs_read.get(f"/users?mailbox={mailbox_id}&page={page}")
            names |= {(u.get("firstName") or "").lower() for u in r.get("_embedded", {}).get("users", [])} - {""}
            if page >= r.get("page", {}).get("totalPages", 1):
                break
            page += 1
        _users[mailbox_id] = sorted(names)
    return _users[mailbox_id]


def shape(cid):
    c = hs_read.get(f"/conversations/{cid}?embed=threads")
    threads = []
    for t in reversed(c["_embedded"]["threads"]):
        if t["type"] not in ("customer", "message", "note", "chat", "phone"):
            continue
        body = t.get("body") or ""
        if t["type"] == "note" and "Technical Information" in body:
            continue  # the apps' own support-report notes, not anyone speaking
        who = t.get("createdBy") or {}
        threads.append({
            "id": t["id"],  # Help Scout's own id for the thread: stable, where a position in this list isn't
            "kind": "customer" if t["type"] == "customer" else
                    "draft" if t.get("state") == "draft" else ("note" if t["type"] == "note" else "reply"),
            "by": "customer" if who.get("type") == "customer" else (who.get("first") or "someone").lower(),
            "who": who.get("type"),  # Help Scout's own word for the author (user, customer): a chat or phone thread can be either
            "mentions": re.findall(r'mention-highlight">@([\w.-]+)<', body) if t["type"] == "note" else [],
            "at": t.get("createdAt"),  # when, by Help Scout's clock: a time is shape, and lets other sources' answers be ordered against it
        })
    return {"id": c["id"], "number": c["number"], "mailbox": hs_read.MAILBOXES.get(c["mailboxId"], c["mailboxId"]),
            "status": c["status"], "users": users(c["mailboxId"]), "threads": threads}


def queue_ids():
    for mb in hs_read.MAILBOXES:
        folders = hs_read.get(f"/mailboxes/{mb}/folders")["_embedded"]["folders"]
        folder = next(f["id"] for f in folders if f["type"] == "open")
        convs = hs_read.get(f"/conversations?mailbox={mb}&folder={folder}&status=all").get("_embedded", {}).get("conversations", [])
        yield from (c["id"] for c in convs if c["status"] != "closed")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    for cid in (queue_ids() if args == ["queue"] else map(int, args)):
        print(json.dumps(shape(cid)))
