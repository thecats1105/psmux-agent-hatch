#!/usr/bin/env bash
# Refresh the picker's agent cache whenever this agent changes state.
#
#   refresh-cache.sh [delay-ms]   optional wait first, e.g. for the process to exit
#                                 on SessionEnd.
#
# The picker paints its first frame from the cache (unless @agent_picker_cache is
# off). Claude's hooks fire at exactly the moments status changes, so refreshing
# here keeps that first paint honest.
#
# Never fails and never prints; the refresh runs detached.

# Outside psmux this would overwrite a good cache with an empty one.
[ -n "${TMUX:-}" ] || [ -n "${PSMUX_SESSION:-}" ] || exit 0

# CLAUDE_PLUGIN_ROOT is a Windows path; Git Bash accepts it once the slashes agree.
plugin_root=${CLAUDE_PLUGIN_ROOT:-}
plugin_root=${plugin_root//\\//}

picker=''
for candidate in \
  "$plugin_root/../../scripts/picker.sh" \
  "$HOME/.psmux/plugins/psmux-agent-hatch/scripts/picker.sh"; do
  if [ -f "$candidate" ]; then
    picker=$candidate
    break
  fi
done
[ -n "$picker" ] || exit 0

delay=${1:-0}
[[ $delay =~ ^[0-9]+$ ]] || delay=0
( bash "$picker" --list --delay "$delay" >/dev/null 2>&1 & )

exit 0
