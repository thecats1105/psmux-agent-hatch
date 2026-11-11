# psmux-claude-hatch

A [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins) that
ships the hook configuration [psmux-agent-hatch](../../README.md) wants, so you
don't have to paste JSON into `~/.claude/settings.json`.

It does two things:

- **Rings the terminal bell** when an agent ends a turn, asks for permission, or
  asks you a question — the three moments the picker calls `idle` and `waiting`.
  psmux only raises `alert-bell` for a real BEL written to a pane's console, which
  is what makes this plugin's bell notification fire. A hook's stdout never reaches
  the pane, so the BEL is written to the console device (`/dev/conout` in Git Bash) directly.
- **Refreshes the picker's agent cache** on those same events, plus session
  start/end and prompt submit. The picker paints its first frame from that cache
  (unless `@agent_picker_cache` is `'off'`), so without this it can be stale.

## Install

```
/plugin marketplace add thecats1105/psmux-agent-hatch
/plugin install psmux-claude-hatch@psmux-claude-hatch
```

## Notes

- The hooks are bash scripts (`bash "${CLAUDE_PLUGIN_ROOT}/hooks/….sh"`); Claude Code on Windows runs hooks in Git Bash.
- Both hooks are silent and always exit `0`; the cache refresh runs detached, so a
  failure never fails a turn and nothing lands in the transcript.
- The cache refresh is skipped when the agent is not inside psmux.
- The refresh finds the plugin at `~/.psmux/plugins/psmux-agent-hatch` (where PPM
  installs it) or relative to this plugin when installed from a checkout.
