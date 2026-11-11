#!/usr/bin/env bash
# Open the unified agent picker in a popup.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"

ctx_load
popup_size

# open_picker <host-client>: show the picker popup on <host>, or on the default
# client when it is empty.
open_picker() {
  local cmd
  pwsh_script_cmd cmd picker.sh
  # No -T/-b: they make psmux 3.4.0 ignore the popup command (see launch.sh).
  local popup=(display-popup -E -w "$POPUP_W" -h "$POPUP_H")
  [ -n "$1" ] && popup+=(-c "$1")
  psx "${popup[@]}" "$cmd" >/dev/null
}

if session_provider "$CTX_SESSION"; then
  # Pressed from inside a session popup: close it, then reopen the picker on the
  # outer client. Detaching by session is safe because a popup's nested attach is
  # the only client on that session.
  psx detach-client -s "$CTX_SESSION" >/dev/null
  sleep 0.15
  state_get_parent
  open_picker "$REPLY"
  exit 0
fi

# Normal case: this client is the host.
state_set_parent "$CTX_CLIENT"
open_picker "$CTX_CLIENT"
exit 0
