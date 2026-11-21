#!/bin/bash
# Run a Ruby script in production on a pinned web machine, the careful way.
#
#   prod_read.sh <locksmith|mechanic> <script.rb> [--write | --shopify-read] [NAME=value ...]
#
# Reads (the default): the script runs inside a transaction that's rolled back, with a 30s statement timeout and the
# query cache off, so a database write in it can't stick and a polling loop sees fresh rows. What a rollback can't take
# back is refused by bin/rolled_back_read_guard.rb: outbound HTTP (but Rollbar) and enqueueing background jobs.
# --read-only: the same, with the transaction itself READ ONLY, so Postgres refuses any write (nextval and NOTIFY too).
# Wrappers under the rolled-back standing go use it; plain read mode stays able to dry-run a write.
# --write: runs the script as is, for an act Isaac has said go to.
# --shopify-read: for scripts that read from Shopify (theme files, Admin GraphQL queries), which can't run inside the
# rolled-back transaction because getting a session can refresh the shop's token, and that refresh must stick. The
# script runs under the guards in bin/shopify_read_guard.rb instead (database, outbound HTTP, background jobs; read its
# header for exactly what each lets through). Query cache off. Locksmith only.
# NAME=value pairs become environment variables for the script (e.g. SHOP=… DAYS=15).
#
# Output is scrubbed of anything shaped like a credential (Shopify tokens, bearer tokens, client secrets, JWTs, URL
# passwords) before it reaches the terminal, and the Rails/Sidekiq boot noise is dropped. The scrub is a net, not a
# license: print the fields you need, never whole objects.
#
# The before-acting hook treats this script like `fly ssh`: it needs `# go: <Isaac's words>` as the command's first line,
# except under a standing go (CLAUDE.md, "The shop, in production").
set -euo pipefail
# siblings are found by this file's real path, so a symlink to it can't bring its own guard (a reader, 2026-11-21)
here="$(dirname "$(readlink -f "$0")")"

case "${1:-}" in
  locksmith) app=locksmith-api-production ;;
  mechanic) app=mechanic-api-production ;;
  *) echo "usage: prod_read.sh <locksmith|mechanic> <script.rb> [--read-only | --write | --shopify-read] [NAME=value ...]" >&2; exit 2 ;;
esac
script="${2:?script path}"
[[ -f "$script" ]] || { echo "no such script: $script" >&2; exit 2; }
shift 2
mode=read
envs=()
for arg in "$@"; do
  if [[ "$arg" == "--write" || "$arg" == "--shopify-read" || "$arg" == "--read-only" ]]; then
    [[ "$mode" == read ]] || { echo "--read-only, --write and --shopify-read can't be combined" >&2; exit 2; }
    mode="${arg#--}"
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

# a unique name per run: several runs can share a machine at once (parallel forks did, 2026-10-21)
run_id="cw_$(date +%s)_$$_$RANDOM"
if [[ "$mode" == read || "$mode" == read-only ]]; then
  ro=""
  [[ "$mode" == read-only ]] && ro='ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")'
  outer="$(cat "$here/rolled_back_read_guard.rb")"$'\n''ActiveRecord::Base.transaction do
  '"$ro"'
  ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '"'"'30s'"'"'")
  ActiveRecord::Base.uncached { load "/tmp/'"$run_id"'_inner.rb" }
  raise ActiveRecord::Rollback
end'
elif [[ "$mode" == shopify-read ]]; then
  [[ "$app" == locksmith-api-production ]] || { echo "--shopify-read is Locksmith-only for now" >&2; exit 2; }
  guard="$here/shopify_read_guard.rb"
  outer="$(cat "$guard")"$'\n''ActiveRecord::Base.uncached { load "/tmp/'"$run_id"'_inner.rb" }'
else
  outer='load "/tmp/'"$run_id"'_inner.rb"'
fi
inner_b64=$(base64 < "$script" | tr -d '\n')
outer_b64=$(printf '%s\n' "$outer" | base64 | tr -d '\n')
remote="echo $inner_b64 | base64 -d > /tmp/${run_id}_inner.rb && echo $outer_b64 | base64 -d > /tmp/${run_id}_outer.rb && ${envs[*]:-} timeout 240 bin/rails runner /tmp/${run_id}_outer.rb; rm -f /tmp/${run_id}_inner.rb /tmp/${run_id}_outer.rb"

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
