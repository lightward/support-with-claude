#!/bin/bash
# Run a Ruby script in production on a pinned web machine, the careful way.
#
#   prod_read.sh <locksmith|mechanic> <script.rb> [--write] [NAME=value ...]
#
# Reads (the default): the script runs inside a transaction that's rolled back, with a 30s statement timeout and the
# query cache off, so a database write in it can't stick and a polling loop sees fresh rows. (A call out to Shopify or
# anywhere else is not rolled back: a "read" that calls a mutation is a write.)
# --write: runs the script as is, for an act Isaac has said go to.
# NAME=value pairs become environment variables for the script (e.g. SHOP=… DAYS=15).
#
# Output is scrubbed of anything shaped like a credential (Shopify tokens, bearer tokens, client secrets, JWTs, URL
# passwords) before it reaches the terminal, and the Rails/Sidekiq boot noise is dropped. The scrub is a net, not a
# license: print the fields you need, never whole objects.
#
# The before-acting hook treats this script like `fly ssh`: it needs `# go: <Isaac's words>` as the command's first line.
set -euo pipefail

case "${1:-}" in
  locksmith) app=locksmith-api-production ;;
  mechanic) app=mechanic-api-production ;;
  *) echo "usage: prod_read.sh <locksmith|mechanic> <script.rb> [--write] [NAME=value ...]" >&2; exit 2 ;;
esac
script="${2:?script path}"
[[ -f "$script" ]] || { echo "no such script: $script" >&2; exit 2; }
shift 2
mode=read
envs=()
for arg in "$@"; do
  if [[ "$arg" == "--write" ]]; then mode=write
  elif [[ "$arg" =~ ^[A-Z_][A-Z0-9_]*=[A-Za-z0-9._:@/-]*$ ]]; then envs+=("$arg")
  else echo "unexpected argument: $arg (env values are limited to [A-Za-z0-9._:@/-])" >&2; exit 2
  fi
done

# a started web machine, cached for the day; an unpinned console usually lands on a worker
cache_dir="$HOME/.cache/support-with-claude"; mkdir -p "$cache_dir"; chmod 700 "$cache_dir"
cache="$cache_dir/machine-$app-$(date +%F)"
pick_machine() {
  flyctl machines list -a "$app" --json 2>/dev/null | python3 -c '
import sys, json
for m in json.load(sys.stdin):
    if m["state"] == "started" and m.get("config", {}).get("metadata", {}).get("fly_process_group") == "web":
        print(m["id"]); break'
}
machine=$(cat "$cache" 2>/dev/null || true)
if [[ -z "$machine" ]]; then machine=$(pick_machine); echo "$machine" > "$cache"; fi
[[ -n "$machine" ]] || { echo "no started web machine found for $app" >&2; exit 1; }

if [[ "$mode" == read ]]; then
  outer='ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '"'"'30s'"'"'")
  ActiveRecord::Base.uncached { load "/tmp/cw_inner.rb" }
  raise ActiveRecord::Rollback
end'
else
  outer='load "/tmp/cw_inner.rb"'
fi
inner_b64=$(base64 < "$script" | tr -d '\n')
outer_b64=$(printf '%s\n' "$outer" | base64 | tr -d '\n')
remote="echo $inner_b64 | base64 -d > /tmp/cw_inner.rb && echo $outer_b64 | base64 -d > /tmp/cw_outer.rb && ${envs[*]:-} timeout 240 bin/rails runner /tmp/cw_outer.rb; rm -f /tmp/cw_inner.rb /tmp/cw_outer.rb"

run() { flyctl ssh console -a "$app" --machine "$machine" -C "sh -c '$remote'" 2>&1; }
out=$(run) || true
if grep -qiE "machine .*(not found|not started|stopped)|could not find machine" <<<"$out"; then
  machine=$(pick_machine); echo "$machine" > "$cache"; out=$(run) || true
fi

python3 -I -c '
import re, sys
text = sys.stdin.read()
scrub = [
    (r"\bshp(at|ca|ss|ua|pa)_[A-Za-z0-9]+", "shp\\1_[redacted]"),
    (r"(?i)bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer [redacted]"),
    (r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "[jwt redacted]"),
    (r"(\w+://[^:/\s@]+:)[^@\s]+@", r"\1[redacted]@"),
    (r"(?i)([\"\x27]?[a-z_]*(secret|password|passwd|api_key|access_token|refresh_token|private_key)[a-z_]*[\"\x27]?\s*(=>|:|=)\s*[\"\x27]?)[^\"\x27,\s}]{6,}", r"\1[redacted]"),
    (r"\b[A-Za-z0-9_-]{3,8}~[A-Za-z0-9_.~-]{20,}", "[secret-shaped redacted]"),
]
for pattern, repl in scrub:
    text = re.sub(pattern, repl, text)
noise = re.compile(r"^(Connecting to |.*image_processing.*|.*Sidekiq \S+ connecting to Redis.*|\s+from /app/\.bundle/.*)")
kept = "\n".join(l for l in text.splitlines() if not noise.match(l))
# keep blank lines from the output itself (Markdown needs them), but not runs of them
print(re.sub(r"\n{3,}", "\n\n", kept).strip("\n"))
' <<<"$out"
