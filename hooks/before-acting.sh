#!/bin/bash
# PreToolUse on Bash. Reading reveals nothing; acting reveals that you could.
# Reads pass. An act that reaches past this machine stops, whatever the permission mode,
# until it's been said in chat and Isaac has said go. His go travels as the command's first line,
# `# go: <his words>`, so the act carries its own receipt.

cmd=$(jq -r '.tool_input.command // ""')

grep -qE '^#[[:space:]]*go:[[:space:]]*[^[:space:]]' <<<"$(head -1 <<<"$cmd")" && exit 0

stop() {
  jq -n --arg r "Stopped before acting: $1. Say in chat what this does and why. If Isaac says go, run it again with \`# go: <his words>\` as its first line." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# fly: anything but a known read stops. Only where a command starts (a line, or after ; & | ( or `,
# maybe under timeout), so the word in prose or a quoted string isn't the CLI.
reads='logs|status|releases|version|doctor|auth|apps list|machines? (list|status)|certs (list|show|check)|secrets list|ips list|volumes list|config (show|validate)|platform|orgs list|regions list|image show'
at_start='(^|[;&|(`])[[:space:]]*(timeout[[:space:]]+[0-9]+[[:space:]]+)?(fly|flyctl)[[:space:]]+'
# a quoted heredoc's body is text, not commands (a note saying "…; flyctl shows v373", 2026-11-05)
code=$(awk '
  inbody { if ($0 == tag) inbody = 0; next }
  { print }
  match($0, /<<-?[[:space:]]*'\''[A-Za-z_]+'\''/) { t = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*'\''/, "", t); sub(/'\''$/, "", t); tag = t; inbody = 1 }
' <<<"$cmd")
while read -r sub; do
  [[ -z "$sub" ]] && continue
  grep -qE "^($reads)([[:space:]]|$)" <<<"$sub" || stop "fly acts here: \`fly $sub\`"
done < <(grep -oE "${at_start}[a-z-]+([[:space:]]+[a-z-]+)?" <<<"$code" | sed -E 's/^.*(fly|flyctl)[[:space:]]+//')

# prod_read.sh runs fly ssh where the check above can't see it, so calling it counts the same.
# (support_shop.sh also calls it, from inside, and passes on purpose: Isaac's standing go covers that one read.)
# One more standing go (Isaac, 2026-11-21, on "the geometry of the you+me+readers proof"): prod_read.sh locksmith
# <script> --shopify-read, when the script is in this repo's bin/ and the script, the guard and prod_read.sh itself are
# all tracked and unmodified. The guard (bin/shopify_read_guard.rb) is what holds a committed script to reading.
# Anything else about the call (a second prod_read.sh, --write, mechanic, a script outside bin/, an uncommitted edit,
# a path that doesn't resolve from this repo) falls through to the stop below.
repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
shopify_read_ok() {
  [[ $(grep -oE 'prod_read\.sh' <<<"$cmd" | wc -l) -eq 1 ]] || return 1
  local seg w pr app script f
  seg=$(grep -oE '[^[:space:];&|(`]*prod_read\.sh[^;&|]*' <<<"$code") || return 1
  read -r -a w <<<"$seg"
  pr="${w[0]/#\~/$HOME}"; app="${w[1]:-}"; script="${w[2]:-}"
  [[ "$app" == locksmith ]] || return 1
  grep -qE '(^|[[:space:]])--shopify-read([[:space:]]|$)' <<<"$seg" || return 1
  grep -qE '(^|[[:space:]])--write([[:space:]]|$)' <<<"$seg" && return 1
  script="${script/#\~/$HOME}"
  [[ "$pr" == /* ]] || pr="$repo/$pr"
  [[ "$script" == /* ]] || script="$repo/$script"
  pr=$(readlink -f "$pr" 2>/dev/null) || return 1
  script=$(readlink -f "$script" 2>/dev/null) || return 1
  [[ "$pr" == "$repo/bin/prod_read.sh" ]] || return 1
  [[ "$script" == "$repo"/bin/*.rb && "${script#"$repo"/bin/}" != */* ]] || return 1
  for f in "$script" "$repo/bin/shopify_read_guard.rb" "$repo/bin/prod_read.sh"; do
    git -C "$repo" ls-files --error-unmatch "$f" >/dev/null 2>&1 || return 1
    git -C "$repo" diff --quiet HEAD -- "$f" 2>/dev/null || return 1
  done
}
grep -qE '(^|[;&|(`])[[:space:]]*((ba)?sh[[:space:]]+)?[^[:space:];&|]*prod_read\.sh([[:space:]]|$)' <<<"$cmd" && ! shopify_read_ok && stop "production via prod_read.sh"
# So does a script that calls it from inside (find_shop.sh, say): without this, any new wrapper would be a quiet
# standing go. support_shop.sh is the one named exception; comment lines that mention prod_read.sh don't count.
# Only a script being run counts (where a command starts, maybe under sh/bash/python3/ruby/node), so naming one
# in git add, cat or chmod doesn't.
runner='(^|[;&|(`])[[:space:]]*(((ba)?sh|python3|ruby|node)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?'
for f in $(grep -oE "${runner}[^[:space:];&|\"']+\.(py|rb|sh|js)\b" <<<"$cmd" | sed -E 's/^.*[[:space:];&|(`]//; s/^.*[[:space:]]//'); do
  f="${f/#\~/$HOME}"
  case "$f" in *support_shop.sh | *prod_read.sh | *before-acting.sh) continue ;; esac
  [[ -f "$f" ]] && grep -vE '^[[:space:]]*#' "$f" | grep -q 'prod_read\.sh' && stop "production via ${f##*/}, which runs prod_read.sh"
done

# Help Scout: a reply that isn't a draft goes to a customer. Scripts the command runs are read too.
# Only a script being run counts, as above: reading one (sed, cat, grep over this hook) isn't an act (2026-11-05).
text="$cmd"
for f in $(grep -oE "${runner}[^[:space:];&|\"']+\.(py|rb|sh|js)\b" <<<"$cmd" | sed -E 's/^.*[[:space:];&|(`]//; s/^.*[[:space:]]//'); do
  f="${f/#\~/$HOME}"
  # this hook's own tests hold sample acts as strings; running them is not an act
  [[ "$f" == *before-acting.sh ]] && continue
  [[ -f "$f" ]] && text+=$'\n'"$(cat "$f")"
done
# /reply as the API endpoint, not the start of a filename like reply.html
if grep -q 'helpscout' <<<"$text" && grep -qE '/reply([^[:alnum:]._-]|$)' <<<"$text" \
  && ! grep -qE 'draft[\\"]*[[:space:]]*[:=]>?[[:space:]]*(true|True)' <<<"$text"; then
  stop "a Help Scout reply that isn't a draft would go to a customer"
fi

# hs_post.py drafts by default; --send sends to the customer, and the script's own draft flag can't speak for it
grep -qE 'hs_post\.py([[:space:]].*)?[[:space:]]--send([[:space:]]|$)' <<<"$cmd" && stop "hs_post.py --send would send a reply to a customer"

# Help Scout: changing a conversation's status (closing it, say) is an act at the team's seat. hs_close.py carries
# the PATCH in its own code, so reading the scripts a command runs catches it too.
if grep -q 'helpscout' <<<"$text" && grep -qE '["'\'']/status["'\'']' <<<"$text"; then
  stop "a Help Scout status change (closing a conversation, say)"
fi

exit 0
