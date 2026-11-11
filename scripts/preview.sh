#!/usr/bin/env bash
# fzf preview for one picker row: the pane's screen, minus trailing blank lines
# (which would leave fzf's `follow` scrolled onto padding).
#
#   preview.sh <target>
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"

target=${1-}
[ -n "$target" ] || exit 0

shopt -s extglob
mapfile -t lines < <(psx capture-pane -e -p -t "$target")
last=$((${#lines[@]} - 1))
# A line holding only escape codes (from -e) is still blank.
while ((last >= 0)); do
  plain=${lines[last]//$'\e'\[*([0-9;])m/}
  plain=${plain//[[:space:]]/}
  [ -z "$plain" ] || break
  ((last--))
done
((last >= 0)) && printf '%s\n' "${lines[@]:0:last+1}"
exit 0
