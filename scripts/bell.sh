#!/usr/bin/env bash
# Forward a bell from a dedicated agent session to the user.
#
#   bell.sh <session-name>   bound to the alert-bell hook with #{session_name}
#
# tmux marks the origin window's bell flag; psmux offers no way to ring another
# pane, so the equivalent here is a status-line message on the client that
# launched the session.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"

session=${1-}
session_provider "$session" || exit 0
name=$P_NAME

state_get_origin "$session" || exit 0
[ -n "$ORIGIN_SESSION" ] || exit 0
# Never forward onto another dedicated session (forwarding loop).
session_provider "$ORIGIN_SESSION" && exit 0

message="🔔 $name needs you ($session)"
state_get_parent
if [ -n "$REPLY" ]; then
  notify -c "$REPLY" "$message"
else
  psx display-message "$message" >/dev/null
fi
exit 0
