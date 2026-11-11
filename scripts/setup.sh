#!/usr/bin/env bash
# Install the key bindings and the bell hook. Run once per psmux start by
# psmux-agent-hatch.ps1, which is only there to find Git Bash.
#
# Read the @options BEFORE the plugin loads: they are looked at once, here.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"

# Keep the log from growing without bound.
if [ -f "$HATCH_DATA/hatch.log" ]; then
  log_size=$(stat -c %s "$HATCH_DATA/hatch.log" 2>/dev/null || echo 0)
  ((log_size > 204800)) && rm -f "$HATCH_DATA/hatch.log"
fi

get_opt claude_key @claude_launch_key y
get_opt codex_key @codex_launch_key o
get_opt agy_key @agy_launch_key Y
get_opt2 list_key @agent_list_key @claude_list_key u

# The binding runs the script through run-shell, which psmux parses as PowerShell.
bind_script() { # <key> <script> [arg...]
  local key=$1 cmd
  shift
  pwsh_script_cmd cmd "$@"
  psx bind-key "$key" "run-shell \"$cmd\"" >/dev/null
}

bind_script "$claude_key" launch.sh claude
bind_script "$codex_key" launch.sh codex
bind_script "$agy_key" launch.sh agy
bind_script "$list_key" list.sh

# Tell the user when a dedicated session rings the bell.
get_opt2 forward_bell @agent_forward_bell @claude_forward_bell on
if [ "$forward_bell" = on ]; then
  pwsh_script_cmd cmd bell.sh '#{session_name}'
  psx set-hook -g alert-bell "run-shell -b \"$cmd\"" >/dev/null
fi
exit 0
