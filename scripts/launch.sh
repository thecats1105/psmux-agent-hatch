#!/usr/bin/env bash
# Launch (or re-attach to) a Claude or Codex session for a directory, shown in a popup.
# Args: [provider] <dir> [origin-window-id]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

provider="claude"
case "${1:-}" in
codex)
  provider="codex"
  shift
  ;;
claude)
  provider="claude"
  shift
  ;;
*)
  # If 1st argument is a directory or path, keep provider as claude
  ;;
esac

path="${1:-$PWD}"
window="${2:-}"

if [ "$provider" = "codex" ]; then
  prefix="$(get_tmux_option @codex_session_prefix 'codex-')"
  cmd="$(get_tmux_option @codex_command 'codex')"
  args="$(get_tmux_option @codex_args '')"
  title=" Codex "
else
  prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
  cmd="$(get_tmux_option @claude_command 'claude')"
  args="$(get_tmux_option @claude_args '')"
  title=" Claude "
fi

[ -n "$args" ] && cmd="$cmd $args"
w="$(get_first_tmux_option @agent_popup_width @claude_popup_width '90%')"
h="$(get_first_tmux_option @agent_popup_height @claude_popup_height '90%')"

session="${prefix}$(session_hash "$path")"

# Check if currently inside an agent popup window
current_session="$(tmux display-message -p '#S' 2>/dev/null || true)"
claude_prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
codex_prefix="$(get_tmux_option @codex_session_prefix 'codex-')"

if [[ "$current_session" == "$claude_prefix"* ]] || [[ "$current_session" == "$codex_prefix"* ]]; then
  tmux display-message '🫪 Popup window already open'
  exit 0
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  [ -d "$path" ] || {
    tmux display-message "tmux-agent-hatch: $path no longer exists"
    exit 0
  }
  tmux new-session -d -s "$session" -c "$path" "$cmd"
fi

# Close the popup when agent exits, even under a global detach-on-destroy off.
tmux set-option -t "$session" detach-on-destroy on

# Record which window launched it, so the picker can jump back here later.
if [ -n "$window" ]; then
  tmux set-option -t "$session" @agent_origin "$window"
  tmux set-option -t "$session" @claude_origin "$window"
fi

tmux display-popup -w "$w" -h "$h" -b rounded -T "$title" -E "tmux attach-session -t '$session'"
