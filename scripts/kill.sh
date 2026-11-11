#!/usr/bin/env bash
# Kill the agent behind a picker row (fzf's ctrl-x).
#
#   kill.sh <pid> <provider> [kind]
#
# Claude rows carry the claude process itself. Codex / AGY rows carry the pane's
# shell: kill the shell's children (the agent), not the shell — a dedicated session
# then dies with its last process, and a loose pane keeps its shell. A dedicated
# session whose pane process has no children runs the agent directly: kill that.
_d=${BASH_SOURCE[0]%/*}; [ "$_d" = "${BASH_SOURCE[0]}" ] && _d=.
. "$_d/helpers.sh"

pid=${1-}
provider=${2:-claude}
kind=${3-}
[[ $pid =~ ^[0-9]+$ ]] && ((pid > 0)) || exit 0

if [ "$provider" = claude ]; then
  taskkill.exe /PID "$pid" /T /F >/dev/null 2>&1
  exit 0
fi

# Git Bash cannot see the parent of a native Windows process (`ps -W` reports 0), so
# finding the shell's children takes one WMI query. Only this rare, explicit action
# pays for it.
children=$(powershell.exe -NoProfile -NonInteractive -Command \
  "Get-CimInstance Win32_Process -Filter 'ParentProcessId=$pid' | ForEach-Object { \$_.ProcessId; & taskkill.exe /PID \$_.ProcessId /T /F | Out-Null }" 2>/dev/null)
children=${children//$'\r'/}
if [ -z "$children" ] && [ "$kind" = dedicated ]; then
  taskkill.exe /PID "$pid" /T /F >/dev/null 2>&1
fi
exit 0
