#!/usr/bin/env bash
# Open the agent session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

claude_prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
codex_prefix="$(get_tmux_option @codex_session_prefix 'codex-')"
w="$(get_first_tmux_option @agent_popup_width @claude_popup_width '90%')"
h="$(get_first_tmux_option @agent_popup_height @claude_popup_height '90%')"

me="${1:-}"
my_session="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
  awk -v me="$me" '$1 == me { print $2; exit }')"

title=" Agents "

# open_picker <host> — show the picker popup on <host>, or on the default client
# when <host> is empty. Returns display-popup's own exit status.
open_picker() {
  if [ -n "$1" ]; then
    tmux display-popup -b rounded -T "$title" -c "$1" -w "$w" -h "$h" -E "$DIR/picker.sh"
  else
    tmux display-popup -b rounded -T "$title" -w "$w" -h "$h" -E "$DIR/picker.sh"
  fi
}

case "$my_session" in
"$claude_prefix"* | "$codex_prefix"*)
  # Inside a session popup: close it, then reopen the picker on the outer client.
  tmux detach-client -s "$my_session"
  for _ in $(seq 1 100); do
    tmux list-clients -F '#{session_name}' 2>/dev/null | grep -qx "$my_session" || break
    sleep 0.05
  done
  host="$(get_first_tmux_option @agent_parent @claude_parent '')"
  if [ -n "$host" ] && ! tmux list-clients -F '#{client_name}' 2>/dev/null | grep -qx "$host"; then
    host=''
  fi

  sleep 0.1
  rc=0
  for _ in $(seq 1 40); do
    before=$SECONDS
    open_picker "$host"
    rc=$?
    { [ "$rc" -eq 0 ] || [ $((SECONDS - before)) -ge 1 ]; } && break
    sleep 0.1
  done
  exit "$rc"
  ;;
*)
  # Normal case: this client is already the host, with no overlay to race.
  host="$me"
  tmux set-option -g @agent_parent "$host"
  tmux set-option -g @claude_parent "$host"
  ;;
esac

open_picker "$host"
