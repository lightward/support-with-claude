#!/bin/bash
# Feeds sample commands to before-acting.sh and checks each verdict. Run after changing the hook.
H="$(dirname "$0")/before-acting.sh"
fail=0
R="$(cd "$(dirname "$0")/.." && pwd)"
printf '#!/bin/bash\nbin/prod_read.sh locksmith /tmp/x.rb\n' > /tmp/unmarked_wrapper.sh
mkdir -p /tmp/elsewhere
t() {
  local want="$1" label="$2" cmd="$3" out got
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$H")
  [[ -n "$out" ]] && got=deny || got=pass
  if [[ "$got" == "$want" ]]; then echo "ok    $got  $label"; else echo "FAIL  $got  $label (wanted $want)"; fail=1; fi
}
t pass "reply.html path next to a helpscout link" 'cat /tmp/drafts/x/reply.html # https://secure.helpscout.net/conversation/1/2'
t pass "hs_post.py by ~ path, reply.html argument" 'python3 -I ~/dev/support-with-claude/bin/hs_post.py 1 /tmp/n.html /tmp/reply.html'
t deny "curl reply that isn't a draft" 'curl -X POST https://api.helpscout.net/v2/conversations/1/reply -d {"text":"hi"}'
t pass "curl draft reply" 'curl -X POST https://api.helpscout.net/v2/conversations/1/reply -d {"text":"hi","draft":true}'
t deny "fly ssh without go" 'flyctl ssh console -a x'
t pass "fly ssh with go" $'# go: yes\nflyctl ssh console -a x'
t pass "fly machines list" 'flyctl machines list -a x --json'
t deny "prod_read.sh without go" 'bin/prod_read.sh locksmith /tmp/x.rb'
t deny "prod_read.sh by ~ path without go" '~/dev/support-with-claude/bin/prod_read.sh mechanic /tmp/x.rb'
t pass "prod_read.sh with go" $'# go: yes, read\n~/dev/support-with-claude/bin/prod_read.sh locksmith /tmp/x.rb'
t pass "prod_read.sh named in prose" 'grep -n prod_read SKILL.md'
t pass "chmod of prod_read.sh" 'chmod +x bin/prod_read.sh && ls'
t pass "support_shop.sh: standing go" '~/dev/support-with-claude/bin/support_shop.sh 9yytey-2f info@example.com'
t pass "standing go: find_shop.sh by its absolute path" "$R/bin/find_shop.sh rankandrally.com"
t pass "standing go: find_shop.sh under bash, by ~" "bash ~/dev/support-with-claude/bin/find_shop.sh rankandrally.com"
t pass "find_shop.sh with go" $'# go: look them up\n'"$R/bin/find_shop.sh rankandrally.com"
t deny "find_shop.sh by a relative path (it could be another checkout's)" "cd /tmp/elsewhere && bash bin/find_shop.sh rankandrally.com"
ln -sf "$R/bin/find_shop.sh" /tmp/find_shop_link_$$.sh
t deny "find_shop.sh through a symlink (it would run the prod_read.sh beside the link)" "bash /tmp/find_shop_link_$$.sh rankandrally.com"
t deny "an env prefix doesn't hide a wrapper" "X=1 bash /tmp/unmarked_wrapper.sh"
t deny "timeout doesn't hide a wrapper" "timeout 60 bash /tmp/unmarked_wrapper.sh"
t deny "then doesn't hide a wrapper" "if true; then bash /tmp/unmarked_wrapper.sh; fi"
t deny "an env prefix doesn't hide prod_read.sh" "X=1 bin/prod_read.sh locksmith /tmp/x.rb"
marked=/tmp/marked_wrapper_$$.sh; printf '#!/bin/bash\n# standing go: rolled-back read\nbin/prod_read.sh locksmith /tmp/x.rb --read-only\n' > "$marked"
t deny "a wrapper outside bin/ carrying the marker" "bash $marked"
writer=/tmp/marked_writer_$$.sh; printf '#!/bin/bash\n# standing go: rolled-back read\nbin/prod_read.sh locksmith /tmp/x.rb --write\n' > "$writer"
t deny "a marked wrapper that uses --write" "bash $writer"
t pass "git add of find_shop.sh" "git add $(dirname "$0")/../bin/find_shop.sh CLAUDE.md && git commit -q -m x"
t pass "a .rb that only mentions prod_read.sh in comments" 'ruby -c ~/dev/support-with-claude/bin/mechanic_dev_trial.rb'
t deny "hs_close.py without go" 'python3 -I ~/dev/support-with-claude/bin/hs_close.py 3490759643'
t pass "hs_close.py with go" $'# go: yup close\npython3 -I ~/dev/support-with-claude/bin/hs_close.py 3490759643'
t deny "inline status PATCH without go" $'python3 -c \'urllib.request.Request("https://api.helpscout.net/v2/conversations/1", method="PATCH", data=json.dumps({"op":"replace","path":"/status","value":"closed"}))\''
t pass "hs_read.py queue" 'python3 -I ~/dev/support-with-claude/bin/hs_read.py queue'
t pass "hs_post.py note and draft" 'python3 -I ~/dev/support-with-claude/bin/hs_post.py 1 /tmp/n.html /tmp/r.html --cc a@example.com'
t pass "running these tests" 'bash hooks/test-before-acting.sh | grep -c "^ok"'
t deny "hs_post.py --send without go" 'python3 -I ~/dev/support-with-claude/bin/hs_post.py 1 /tmp/n.html /tmp/r.html --send'
t pass "hs_post.py --send with go" $'# go: php replies, send them\npython3 -I ~/dev/support-with-claude/bin/hs_post.py 1 /tmp/n.html /tmp/r.html --send'
t pass "reading hs_close.py with sed" 'sed -n 1,60p bin/hs_close.py'
t pass "grep over the hook itself" 'grep -n hs_close hooks/before-acting.sh'
t deny "hs_close.py run directly" 'bin/hs_close.py 3490759643 --spam'
t pass "fly named in a quoted heredoc body" $'cat > /tmp/n.html <<\'EOF\'\nreleased at 15:30 UTC; flyctl shows v373\nEOF'
t deny "fly after a quoted heredoc ends" $'cat > /tmp/n.html <<\'EOF\'\nnote\nEOF\nflyctl ssh console -a x'
t pass "standing go: a committed bin/ helper under --shopify-read" "$R/bin/prod_read.sh locksmith $R/bin/locksmith_customer_tags.rb --shopify-read SHOP=x.myshopify.com KEY=1 EMAILS=a@b.co 2>&1 | tail -4"
t pass "standing go: by ~ paths" '~/dev/support-with-claude/bin/prod_read.sh locksmith ~/dev/support-with-claude/bin/locksmith_theme_compare.rb --shopify-read SHOP=x.myshopify.com OLD=1 NEW=2'
t pass "standing go: a committed bin/ script that writes is still held by the guard" "$R/bin/prod_read.sh locksmith $R/bin/locksmith_trial_extend.rb --shopify-read SHOP=x DAYS=15"
t deny "--shopify-read by relative paths" 'bin/prod_read.sh locksmith bin/locksmith_customer_tags.rb --shopify-read SHOP=x'
t deny "--shopify-read with a /tmp script" "$R/bin/prod_read.sh locksmith /tmp/x.rb --shopify-read SHOP=x.myshopify.com"
t deny "--shopify-read with --write" "$R/bin/prod_read.sh locksmith $R/bin/locksmith_customer_tags.rb --shopify-read --write SHOP=x"
t deny "--shopify-read against mechanic" "$R/bin/prod_read.sh mechanic $R/bin/locksmith_customer_tags.rb --shopify-read SHOP=x"
t deny "committed bin/ helper without --shopify-read" "$R/bin/prod_read.sh locksmith $R/bin/locksmith_customer_tags.rb SHOP=x"
t deny "two prod_read.sh calls" "$R/bin/prod_read.sh locksmith $R/bin/locksmith_customer_tags.rb --shopify-read SHOP=x; $R/bin/prod_read.sh locksmith /tmp/x.rb --write"
t deny "a script outside this repo's bin/" "$R/bin/prod_read.sh locksmith $R/../locksmith-api/bin/x.rb --shopify-read SHOP=x"
exit $fail
