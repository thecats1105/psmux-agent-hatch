#!/usr/bin/env bash
# Interactive picker for running Claude, Codex and AGY agents. Runs in a popup.
#
#   picker.sh                       fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list [--delay <ms>] print the rows and refresh the cache (used by
#                                   fzf's async initial load, the ctrl-x reload, and
#                                   the Claude plugin's hooks). --delay waits first,
#                                   e.g. for a killed process to disappear.
#
# Rows come from agents.sh. Two kinds of row jump differently:
#   dedicated  an agent in a `claude-*` / `codex-*` / `agy-*` session this plugin
#              launched — resumed in the popup, over the window it was launched from.
#   loose      an agent running in any other pane — focused in place.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh"
. "$_d/agents.sh"

update_rows() {
  local tmp=$HATCH_CACHE.$$.tmp
  mkdir_p "$HATCH_DATA"
  agents_main >"$tmp" 2>/dev/null
  mv -f "$tmp" "$HATCH_CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  cat "$HATCH_CACHE" 2>/dev/null
}

if [ "${1-}" = --list ]; then
  if [ "${2-}" = --delay ] && [[ ${3-} =~ ^[0-9]+$ ]]; then
    ms=$3
    printf -v delay '%d.%03d' $((ms / 1000)) $((ms % 1000))
    sleep "$delay"
  fi
  update_rows
  exit 0
fi

for tool in fzf jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    notify "$tool is required for the picker"
    exit 0
  }
done

export FZF_DEFAULT_OPTS=''
# fzf runs --preview / --bind commands through $SHELL when it is set; under Git Bash
# that is the POSIX path /usr/bin/bash, which a native Windows program cannot start.
# Unset, fzf falls back to cmd.exe, which is what the commands below are written for.
unset SHELL

# Each is a complete cmd.exe command line with its script path quoted.
cmd_script_cmd preview_cmd preview.sh '{2}'
cmd_script_cmd kill_cmd kill.sh '{3} {5} {4}'
cmd_script_cmd copy_cmd copy.sh '{10}'
cmd_script_cmd reload_cmd picker.sh '--list --delay 300'
cmd_script_cmd load_cmd picker.sh '--list'

fzf_args=(
  --ansi
  --delimiter '\t'
  --with-nth '7,8,9,10,11'
  --reverse
  --cycle
  --header 'Agents · enter: jump · ctrl-x: kill · ctrl-y: copy'
  --preview "$preview_cmd"
  --preview-window 'up,70%,follow'
  # ctrl-x kills the agent process itself: a dedicated session dies with its last
  # process, while a loose pane keeps the shell that hosted it. The reload waits a
  # beat so the process is gone by the time agents.sh looks for it.
  --bind "ctrl-x:execute-silent($kill_cmd)+reload($reload_cmd)"
  # ctrl-y copies the agent's location (session:window.pane) and closes the picker.
  --bind "ctrl-y:execute-silent($copy_cmd)+abort"
  --bind 'change:first'
)

# Paint the first frame from the cache when it is fresh, then reload in the
# background; otherwise gather the rows up front.
get_opt2 use_cache @agent_picker_cache @claude_picker_cache on
rows=''
if [ "$use_cache" = on ] && [ -s "$HATCH_CACHE" ]; then
  mtime=$(stat -c %Y "$HATCH_CACHE" 2>/dev/null || echo 0)
  printf -v now '%(%s)T' -1
  if ((now - mtime < 3600)); then
    rows=$(<"$HATCH_CACHE")
    [ -z "$rows" ] || fzf_args+=(--bind "load:unbind(load)+reload-sync($load_cmd)")
  fi
fi
[ -n "$rows" ] || rows=$(update_rows)

if [ -z "$rows" ]; then
  notify 'no agents running in psmux'
  exit 0
fi

# Arbitrary user fzf options (e.g. custom --bind or --preview-window).
get_opt2 fzf_options @agent_fzf_options @claude_fzf_options ''
split_words extra_opts "$fzf_options"
fzf_args+=("${extra_opts[@]}")

selection=$(printf '%s\n' "$rows" | fzf "${fzf_args[@]}")
[ -n "$selection" ] || exit 0

IFS=$'\t' read -r _ target _ kind _ session _ <<<"$selection"
[ -n "$target" ] || exit 0

state_get_parent
parent=$REPLY

switch_parent() { # <session>
  if [ -n "$parent" ]; then
    psx switch-client -c "$parent" -t "$1" >/dev/null
  else
    psx switch-client -t "$1" >/dev/null
  fi
}

# Targets stay session-qualified: psmux reuses %n and @n across sessions.
window_target=${target%.*}

if [ "$kind" = loose ]; then
  # Focus the pane in place on the outer client; this popup closes when we exit.
  switch_parent "$session"
  psx select-window -t "$window_target" >/dev/null
  psx select-pane -t "$target" >/dev/null
  exit 0
fi

# Never nest a second attach on a session whose popup is already open.
session_state "$session"
if ((SESSION_ATTACHED)); then
  hatch_log "picker: $session already attached, not attaching again"
  notify 'popup window already open'
  exit 0
fi

# Move the parent client to the window the session was launched from (best-effort):
# switch session first, then pick the window as a separate call.
if state_get_origin "$session" && [ -n "$parent" ] && [ -n "$ORIGIN_SESSION" ] && [ -n "$ORIGIN_INDEX" ]; then
  psx switch-client -c "$parent" -t "$ORIGIN_SESSION" >/dev/null
  psx select-window -t "$ORIGIN_SESSION:$ORIGIN_INDEX" >/dev/null
fi

psx select-window -t "$window_target" >/dev/null
psx select-pane -t "$target" >/dev/null

# Resume the agent in THIS popup over the top (see attach.sh for why the env is cleared).
unset PSMUX_SESSION PSMUX_TARGET_SESSION
# shellcheck disable=SC2086 # HATCH_PSMUX_FLAGS is meant to word-split
exec psmux ${HATCH_PSMUX_FLAGS-} attach-session -t "$session"
