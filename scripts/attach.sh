#!/usr/bin/env bash
# Attach to a session from inside a psmux popup.
#
#   attach.sh <session>
#
# psmux exports PSMUX_SESSION / PSMUX_TARGET_SESSION into a popup, and attach-session
# refuses to nest when it sees them. Clear them first, and always attach through this
# wrapper rather than calling attach-session from a popup.
#
# A popup closes the instant its command exits, taking any error with it. So the
# attempt is logged (hatch.log) and, if attach fails or returns immediately, the
# error is left on screen until Enter is pressed.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"

session=${1:-}
[ -n "$session" ] || exit 0

hatch_log "attach: session=$session PSMUX_SESSION=${PSMUX_SESSION-} TARGET=${PSMUX_TARGET_SESSION-} POPUP=${PSMUX_POPUP-} TMUX=${TMUX-}"

unset PSMUX_SESSION PSMUX_TARGET_SESSION

# Only stderr is redirected: stdout and stdin must stay on the console for the
# attach itself.
mkdir_p "$HATCH_DATA"
errfile=$HATCH_DATA/attach.$$.err
start=${EPOCHREALTIME/./}
# shellcheck disable=SC2086 # HATCH_PSMUX_FLAGS is meant to word-split
psmux ${HATCH_PSMUX_FLAGS-} attach-session -t "$session" 2>"$errfile"
code=$?
elapsed_ms=$(((${EPOCHREALTIME/./} - start) / 1000))

stderr=''
[ -f "$errfile" ] && stderr=$(<"$errfile")
rm -f "$errfile" 2>/dev/null

hatch_log "attach: exit=$code after ${elapsed_ms}ms stderr=[$stderr]"

if ((code != 0 || elapsed_ms < 1500)); then
  printf '\n\e[31mpsmux-agent-hatch: attach to %q failed (exit %s)\e[0m\n' "$session" "$code"
  [ -z "$stderr" ] || printf '%s\n' "$stderr"
  posix_to_win "$HATCH_DATA"
  printf 'Details: %s/hatch.log\nPress Enter to close...\n' "$REPLY"
  read -r _
fi
exit 0
