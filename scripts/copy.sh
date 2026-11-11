#!/usr/bin/env bash
# Copy a picker row's location (session:window.pane) to the clipboard (fzf's ctrl-y).
#
#   copy.sh <text>
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"

if [ -n "${1-}" ]; then
  copy_to_clipboard "$1"
  notify "copied $1"
fi
exit 0
