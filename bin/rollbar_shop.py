#!/usr/bin/env python3
"""A shop's platform errors, from Rollbar: each item's counter, title, how often and when last, never a payload.

    python3 -I rollbar_shop.py <locksmith|mechanic> <shop>[.myshopify.com] [days, default 30]

Each app tags its Rollbar items with a person: the id is the Shopify shop id, the username is the shop name. The items
endpoint's `query` doesn't filter by person, so this goes through RQL (a job, polled until it's done), matching
`person.username` as a string. (Matching `person.id` works too, but only as a string, `= '<id>'`: the numeric form
timed out. Checked 2026-10-22, #119432, against a person known to have items.)

Read-only: the token is the app's read-only Rollbar token, from 1Password. Occurrences can carry request data, so only
titles, counts and times are printed.
"""
import json, re, subprocess, sys, time, urllib.request, datetime

TOKENS = {
    "locksmith": "op://Lightward/4hnfbn3if74m63hclzipmuqlgu/secrets on tap/eye2k3sfrj5xu55y3edqwvdkcy",
    "mechanic": "op://Lightward/4hnfbn3if74m63hclzipmuqlgu/secrets on tap/vr47x4u2ho635f4umfgchsirne",
}


def call(token, path, body=None):
    r = urllib.request.Request("https://api.rollbar.com/api/1" + path, data=json.dumps(body).encode() if body else None,
                               headers={"X-Rollbar-Access-Token": token, "Content-Type": "application/json"})
    d = json.load(urllib.request.urlopen(r, timeout=30))
    if d.get("err"):
        sys.exit(f"rollbar: {d.get('message')}")
    return d["result"]


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in TOKENS:
        sys.exit(__doc__.split("\n\n")[1])
    app, shop = sys.argv[1], sys.argv[2].removesuffix(".myshopify.com")
    days = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", shop):
        sys.exit(f"not a shop name: {shop}")
    token = subprocess.run(["op", "read", TOKENS[app]], capture_output=True, text=True, check=True).stdout.strip()

    # grouped in RQL (GROUP BY with count/max) timed out, so rows come back plain and are grouped here
    query = (f"SELECT item.counter, item.title, timestamp FROM item_occurrence "
             f"WHERE person.username = '{shop}' AND timestamp > unix_timestamp() - {86400 * days} "
             f"ORDER BY timestamp DESC LIMIT 1000")
    job = call(token, "/rql/jobs", {"query_string": query})["id"]
    for _ in range(40):
        time.sleep(3)
        r = call(token, f"/rql/job/{job}?expand=result")
        if r["status"] in ("success", "failed", "timed_out", "cancelled"):
            break
    if r["status"] != "success":
        sys.exit(f"rollbar query {r['status']}: {(r.get('result') or {}).get('errors')}")

    items = {}
    occurrences = r["result"]["rows"] or []
    for counter, title, ts, *_ in occurrences:
        c, t, n, last = items.get(counter, (counter, title, 0, ts))
        items[counter] = (c, t, n + 1, max(last, ts))
    capped = " (capped at the latest 1000 occurrences)" if len(occurrences) == 1000 else ""
    print(f"{app} Rollbar, {shop}, last {days} days: {len(items)} item(s), {len(occurrences)} occurrence(s){capped}")
    for counter, title, count, last in items.values():
        when = datetime.datetime.fromtimestamp(last, datetime.UTC).strftime("%Y-%m-%d %H:%M UTC")
        print(f"  #{counter}  {count}x, last {when}  {str(title)[:140]}")


if __name__ == "__main__":
    main()
