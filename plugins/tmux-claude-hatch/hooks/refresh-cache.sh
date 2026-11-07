#!/usr/bin/env bash
# Refresh the picker's agent cache whenever this agent changes state.
#
#   refresh-cache.sh [delay]   optional seconds to wait first, e.g. for the
#                              process to exit on SessionEnd.
#
# picker.sh paints its first frame from the cache (unless @agent_picker_cache is off).
# Claude's hooks fire at exactly the moments that status changes, so refreshing
# here keeps that first paint honest.
#
# Never fails and never prints: hook output lands in the transcript, and a failed
# refresh must not fail the turn.

[ -n "${TMUX:-}" ] || exit 0

for candidate in \
  "${CLAUDE_PLUGIN_ROOT:-}/../../scripts/picker.sh" \
  "$HOME/.tmux/plugins/tmux-agent-hatch/scripts/picker.sh" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-agent-hatch/scripts/picker.sh" \
  "$HOME/.tmux/plugins/tmux-claude-hatch/scripts/picker.sh" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-claude-hatch/scripts/picker.sh"; do
  if [ -x "$candidate" ]; then
    picker="$candidate"
    break
  fi
done
[ -n "${picker:-}" ] || exit 0

delay="${1:-0}"
( { [ "$delay" != 0 ] && sleep "$delay"; "$picker" --list; } >/dev/null 2>&1 & )

exit 0
