#!/usr/bin/env bash
# Launch (or re-attach to) a Claude / Codex / AGY session for the current pane's
# directory, shown in a popup.
#
#   launch.sh <claude|codex|agy>
_d=${BASH_SOURCE[0]%/*}; [ "$_d" = "${BASH_SOURCE[0]}" ] && _d=.
. "$_d/helpers.sh"

provider=${1:-claude}
case $provider in claude | codex | agy) ;; *) exit 0 ;; esac

ctx_load || exit 0

# Launching from inside an agent session would recompute the very same session
# and overwrite its recorded origin with itself.
if session_provider "$CTX_SESSION"; then
  notify 'popup window already open'
  exit 0
fi

provider_load "$provider"
session_hash "$CTX_PATH"
session=$P_PREFIX$REPLY

# A popup for this session is already open. Opening another would nest a second
# attach inside the first, and every further press nests one more.
session_state "$session"
if ((SESSION_ATTACHED)); then
  hatch_log "launch: $session already attached, not opening another popup"
  notify 'popup window already open'
  exit 0
fi

if ((!SESSION_EXISTS)); then
  win_to_posix "$CTX_PATH"
  if [ ! -d "$REPLY" ]; then
    notify "$CTX_PATH no longer exists"
    exit 0
  fi
  resolve_agent_line "$P_CMD" "$P_ARGS"
  hatch_log "launch: new-session $session in $CTX_PATH: $AGENT_LINE"
  psx new-session -d -s "$session" -c "$CTX_PATH" "$AGENT_LINE" >/dev/null
  session_state "$session"
  if ((!SESSION_EXISTS)); then
    hatch_log "launch: session $session was not created"
    notify "failed to start $P_NAME (see hatch.log)"
    exit 0
  fi
fi

# Record which window launched it, so the picker can jump back here later.
state_set_origin "$session"
state_set_parent "$CTX_CLIENT"

popup_size
pwsh_script_cmd cmd attach.sh "$session"
hatch_log "launch: popup ${POPUP_W}x${POPUP_H} attach $session (client=$CTX_CLIENT)"

# No -T/-b: on psmux 3.4.0 a title or border option makes display-popup silently
# ignore its command (the popup opens and closes without running anything).
popup=(display-popup -E -w "$POPUP_W" -h "$POPUP_H")
[ -n "$CTX_CLIENT" ] && popup+=(-c "$CTX_CLIENT") # the client that pressed the key
# Target the LAUNCHING session explicitly. After `new-session` the psmux CLI treats
# the new (clientless) session as current, so an untargeted display-popup is created
# on it and never shows on the user's screen.
[ -n "$CTX_SESSION" ] && popup+=(-t "$CTX_SESSION")
psx "${popup[@]}" "$cmd" >/dev/null
exit 0
