#!/bin/bash
# Feeds sample commands to before-acting.sh and checks each verdict. Run after changing the hook.
H="$(dirname "$0")/before-acting.sh"
fail=0
t() {
  local want="$1" label="$2" cmd="$3" out got
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$H")
  [[ -n "$out" ]] && got=deny || got=pass
  if [[ "$got" == "$want" ]]; then echo "ok    $got  $label"; else echo "FAIL  $got  $label (wanted $want)"; fail=1; fi
}
t pass "reply.html path next to a helpscout link" 'cat /tmp/drafts/x/reply.html # https://secure.helpscout.net/conversation/1/2'
t pass "hs_post.py by ~ path, reply.html argument" 'python3 -I ~/.claude/skills/support/bin/hs_post.py 1 /tmp/n.html /tmp/reply.html'
t deny "curl reply that isn't a draft" 'curl -X POST https://api.helpscout.net/v2/conversations/1/reply -d {"text":"hi"}'
t pass "curl draft reply" 'curl -X POST https://api.helpscout.net/v2/conversations/1/reply -d {"text":"hi","draft":true}'
t deny "fly ssh without go" 'flyctl ssh console -a x'
t pass "fly ssh with go" $'# go: yes\nflyctl ssh console -a x'
t pass "fly machines list" 'flyctl machines list -a x --json'
t deny "prod_read.sh without go" 'bin/prod_read.sh locksmith /tmp/x.rb'
t deny "prod_read.sh by ~ path without go" '~/.claude/skills/support/bin/prod_read.sh mechanic /tmp/x.rb'
t pass "prod_read.sh with go" $'# go: yes, read\n~/.claude/skills/support/bin/prod_read.sh locksmith /tmp/x.rb'
t pass "prod_read.sh named in prose" 'grep -n prod_read SKILL.md'
t pass "chmod of prod_read.sh" 'chmod +x bin/prod_read.sh && ls'
t pass "support_shop.sh: standing go" '~/.claude/skills/support/bin/support_shop.sh 9yytey-2f info@example.com'
t deny "hs_close.py without go" 'python3 -I ~/.claude/skills/support/bin/hs_close.py 3490759643'
t pass "hs_close.py with go" $'# go: yup close\npython3 -I ~/.claude/skills/support/bin/hs_close.py 3490759643'
t deny "inline status PATCH without go" $'python3 -c \'urllib.request.Request("https://api.helpscout.net/v2/conversations/1", method="PATCH", data=json.dumps({"op":"replace","path":"/status","value":"closed"}))\''
t pass "hs_read.py queue" 'python3 -I ~/.claude/skills/support/bin/hs_read.py queue'
t pass "hs_post.py note and draft" 'python3 -I ~/.claude/skills/support/bin/hs_post.py 1 /tmp/n.html /tmp/r.html --cc a@example.com'
t pass "running these tests" 'bash hooks/test-before-acting.sh | grep -c "^ok"'
t deny "hs_post.py --send without go" 'python3 -I ~/.claude/skills/support/bin/hs_post.py 1 /tmp/n.html /tmp/r.html --send'
t pass "hs_post.py --send with go" $'# go: php replies, send them\npython3 -I ~/.claude/skills/support/bin/hs_post.py 1 /tmp/n.html /tmp/r.html --send'
exit $fail
