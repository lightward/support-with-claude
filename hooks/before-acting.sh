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

# Help Scout: a reply that isn't a draft goes to a customer. Scripts the command runs are read too.
text="$cmd"
for f in $(grep -oE '[^[:space:]"'\'']+\.(py|rb|sh|js)\b' <<<"$cmd"); do
  f="${f/#\~/$HOME}"
  [[ -f "$f" ]] && text+=$'\n'"$(cat "$f")"
done
# /reply as the API endpoint, not the start of a filename like reply.html
if grep -q 'helpscout' <<<"$text" && grep -qE '/reply([^[:alnum:]._-]|$)' <<<"$text" \
  && ! grep -qE 'draft[\\"]*[[:space:]]*[:=]>?[[:space:]]*(true|True)' <<<"$text"; then
  stop "a Help Scout reply that isn't a draft would go to a customer"
fi

exit 0
