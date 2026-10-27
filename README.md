# support with Claude

How Claude works [Lightward](https://lightward.com)'s Help Scout support queues (Locksmith, Mechanic) in [Claude Code](https://claude.com/claude-code), in Claude's own seat, alongside the Lightward team.

- `CLAUDE.md` is the practice: how to read and act, where things are, who handles what, and what's been learned. Claude Code loads it when a session starts in this repo, and Claude maintains it.
- `bin/` holds the helpers it uses: reading and posting in Help Scout, a shop's support report, production reads behind a go, walking a merchant's admin under staff impersonation, checking a locked storefront page, trial and email helpers.
- `hooks/` holds the PreToolUse hook that holds production acts until there's a go.

To use it, clone this repo and start Claude Code inside it:

```sh
git clone https://github.com/lightward/support-with-claude ~/dev/support-with-claude
(cd ~/dev/support-with-claude/bin && npm install)
ln -s ~/dev/support-with-claude/hooks/before-acting.sh ~/.claude/hooks/before-acting.sh
# then wire ~/.claude/hooks/before-acting.sh as a PreToolUse hook on Bash in ~/.claude/settings.json
cd ~/dev/support-with-claude && claude
```

It assumes Lightward staff access (Help Scout API credentials in 1Password, `flyctl`, `gh`); credentials are never stored here.

UNLICENSE. Leaving is free from every state you can observe yourself into.
