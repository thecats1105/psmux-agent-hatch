#!/usr/bin/env bash
# Ring the terminal bell so psmux counts it as one.
#
# psmux fires its alert-bell hook (and forwards the bell) only for a real BEL
# written to a pane's console. A hook's stdout is captured by Claude and never
# reaches the pane, so write the BEL to the console device directly: under Git Bash
# /dev/conout is the console the process is attached to (CONOUT$).
#
# Never fails and never prints: hook output lands in the transcript, and a bell
# that cannot be delivered must not fail the turn. `2>/dev/null` comes *before* the
# redirection on purpose: a failed redirection is reported by the shell itself, so a
# trailing `2>/dev/null` would be applied too late to suppress it.
printf '\a' 2>/dev/null >/dev/conout
exit 0
