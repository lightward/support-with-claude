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
reads='logs|status|releases|version|doctor|auth|apps list|machines? (list|status)|certs (list|show)|secrets list|ips list|volumes list|config (show|validate)|platform|orgs list|regions list|image show'
at_start='(^|[;&|(`])[[:space:]]*(timeout[[:space:]]+[0-9]+[[:space:]]+)?(fly|flyctl)[[:space:]]+'
while read -r sub; do
  [[ -z "$sub" ]] && continue
  grep -qE "^($reads)([[:space:]]|$)" <<<"$sub" || stop "fly acts here: \`fly $sub\`"
done < <(grep -oE "${at_start}[a-z-]+([[:space:]]+[a-z-]+)?" <<<"$cmd" | sed -E 's/^.*(fly|flyctl)[[:space:]]+//')

# prod_read.sh runs fly ssh where the check above can't see it, so calling it counts the same.
# (support_shop.sh also calls it, from inside, and passes on purpose: Isaac's standing go covers that one read.)
grep -qE '(^|[;&|(`])[[:space:]]*((ba)?sh[[:space:]]+)?[^[:space:];&|]*prod_read\.sh([[:space:]]|$)' <<<"$cmd" && stop "production via prod_read.sh"
# So does a script that calls it from inside (find_shop.sh, say): without this, any new wrapper would be a quiet
# standing go. support_shop.sh is the one named exception; comment lines that mention prod_read.sh don't count.
# Only a script being run counts (where a command starts, maybe under sh/bash/python3/ruby/node), so naming one
# in git add, cat or chmod doesn't.
runner='(^|[;&|(`])[[:space:]]*(((ba)?sh|python3|ruby|node)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?'
for f in $(grep -oE "${runner}[^[:space:];&|\"']+\.(py|rb|sh|js)\b" <<<"$cmd" | sed -E 's/^.*[[:space:];&|(`]//; s/^.*[[:space:]]//'); do
  f="${f/#\~/$HOME}"
  case "$f" in *support_shop.sh | *prod_read.sh | *test-before-acting.sh) continue ;; esac
  [[ -f "$f" ]] && grep -vE '^[[:space:]]*#' "$f" | grep -q 'prod_read\.sh' && stop "production via ${f##*/}, which runs prod_read.sh"
done

# Help Scout: a reply that isn't a draft goes to a customer. Scripts the command runs are read too.
text="$cmd"
for f in $(grep -oE '[^[:space:]"'\'']+\.(py|rb|sh|js)\b' <<<"$cmd"); do
  f="${f/#\~/$HOME}"
  # this hook's own tests hold sample acts as strings; running them is not an act
  [[ "$f" == *test-before-acting.sh ]] && continue
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
