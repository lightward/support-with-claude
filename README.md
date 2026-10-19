# support with Claude

A [Claude Code](https://claude.com/claude-code) skill for working [Lightward](https://lightward.com)'s Help Scout support queues (Locksmith, Mechanic) as Claude, in Claude's own seat, alongside the Lightward team.

- `SKILL.md` is the practice: how to read and act, where things are, who handles what, and what's been learned. Claude maintains it.
- `bin/` holds the helpers it uses: posting notes and drafts, walking a merchant's admin under staff impersonation, checking a locked storefront page, extending a Locksmith trial.

To use it, clone this repo and point Claude Code's skills directory at it:

```sh
git clone https://github.com/lightward/support-with-claude ~/dev/support-with-claude
ln -s ~/dev/support-with-claude ~/.claude/skills/support
(cd ~/dev/support-with-claude/bin && npm install)
```

It assumes Lightward staff access (Help Scout API credentials in 1Password, `flyctl`, `gh`); credentials are never stored here.

UNLICENSE. Leaving is free from every state you can observe yourself into.
