#!/usr/bin/env bash
# tmux-agent-hatch
#
# List, monitor status, and jump across nested Claude Code and Codex sessions
# from a single popup. tpm runs this file as an executable on tmux startup; it
# reads user options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

claude_launch_key="$(get_tmux_option @claude_launch_key 'y')"
codex_launch_key="$(get_tmux_option @codex_launch_key 'Y')"
list_key="$(get_first_tmux_option @agent_list_key @claude_list_key 'u')"

# Launch (or re-attach to) a Claude session for the current pane's directory.
tmux bind-key "$claude_launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh claude '#{q:pane_current_path}' '#{q:window_id}'"

# Launch (or re-attach to) a Codex session for the current pane's directory.
tmux bind-key "$codex_launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh codex '#{q:pane_current_path}' '#{q:window_id}'"

# Open the unified agent session picker.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh '#{q:client_name}'"

# Forward a bell from a dedicated session to its origin window's pane.
if [ "$(get_first_tmux_option @agent_forward_bell @claude_forward_bell 'on')" = 'on' ]; then
  tmux set-hook -g alert-bell \
    "run-shell -b \"$CURRENT_DIR/scripts/bell.sh '#{q:hook_session_name}'\""
fi
