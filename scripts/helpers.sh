#!/usr/bin/env bash
# Shared helpers for psmux-agent-hatch. Sourced by every other script.
#
# Everything runs under Git Bash (MSYS2) on native Windows and talks to the native
# psmux.exe. Two habits keep it fast:
#   * no command substitution where a global will do: a fork is the expensive
#     thing on MSYS, so helpers hand results back in globals (REPLY, CTX_*, ...);
#   * one `psmux show-options -g` per script instead of one call per option.
#
# Nothing in here may fail loudly: scripts run from key bindings, hooks and popups,
# where an error is invisible to the user. Source this file; do not `set -e`.
[ -n "${HATCH_HELPERS_LOADED-}" ] && return 0
HATCH_HELPERS_LOADED=1

# psmux, fzf and taskkill are native programs: hand them their arguments untouched
# (no POSIX -> Windows rewriting of "session:0.1", "#{...}" formats or "/PID").
export MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV=1
# Non-ASCII arguments (icons, messages) must reach native programs as UTF-8.
export LC_ALL=C.UTF-8
case ":$PATH:" in *:/usr/bin:*) ;; *) PATH="/usr/bin:$PATH" ;; esac

# Directory of the scripts as a forward-slashed Windows path (C:/.../scripts) and
# the plugin root above it. Such paths are what gets embedded in psmux commands, so
# no backslash ever has to survive psmux's command parser.
HATCH_SCRIPTS=$(cd "${BASH_SOURCE[0]%/*}" && pwd -W)
HATCH_ROOT=${HATCH_SCRIPTS%/*}

# --- paths --------------------------------------------------------------------

# win_to_posix <path> -> REPLY    C:\Users\me -> /c/Users/me
win_to_posix() {
  local p=${1//\\//}
  if [[ $p =~ ^([A-Za-z]):(/.*)?$ ]]; then
    local d=${BASH_REMATCH[1]}
    REPLY="/${d,,}${BASH_REMATCH[2]}"
  else
    REPLY=$p
  fi
}

# posix_to_win <path> -> REPLY    /c/Users/me -> C:/Users/me
posix_to_win() {
  local p=$1
  if [[ $p =~ ^/([A-Za-z])(/.*)?$ ]]; then
    local d=${BASH_REMATCH[1]}
    REPLY="${d^^}:${BASH_REMATCH[2]:-/}"
  else
    REPLY=${p//\\//}
  fi
}

# Persistent state: hook state files, the launching window/client, the picker
# cache and hatch.log all live here.
if [ -n "${HATCH_DATA_DIR:-}" ]; then
  HATCH_DATA=$HATCH_DATA_DIR
elif [ -n "${LOCALAPPDATA:-}" ]; then
  win_to_posix "$LOCALAPPDATA"
  HATCH_DATA="$REPLY/psmux-agent-hatch"
else
  HATCH_DATA="$HOME/.local/share/psmux-agent-hatch"
fi

mkdir_p() { [ -d "$1" ] || mkdir -p "$1" 2>/dev/null; }

# Popups and bindings run where errors are invisible, so this is how failures get
# found. The log is rotated by setup.sh.
hatch_log() {
  mkdir_p "$HATCH_DATA"
  printf '%(%H:%M:%S)T %s\n' -1 "$*" >>"$HATCH_DATA/hatch.log" 2>/dev/null
}

# --- psmux --------------------------------------------------------------------

# psx <args...>: psmux with stderr discarded. HATCH_PSMUX_FLAGS lets the tests
# aim every call at an isolated `-L <namespace>` server.
# shellcheck disable=SC2086 # the flags are meant to word-split
psx() { psmux ${HATCH_PSMUX_FLAGS-} "$@" 2>/dev/null; }

# notify [-c client] <message>: a status-line message.
notify() {
  if [ "${1-}" = -c ]; then
    psx display-message -c "$2" "psmux-agent-hatch: $3" >/dev/null
  else
    psx display-message "psmux-agent-hatch: $1" >/dev/null
  fi
}

# --- options ------------------------------------------------------------------

# Load every global option once; `show-options -g` prints `name "value"` lines,
# user (@) options included.
hatch_load_options() {
  [ -n "${HATCH_OPTS_LOADED-}" ] && return 0
  HATCH_OPTS_LOADED=1
  declare -gA HATCH_OPT=()
  local line key val
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    key=${line%% *}
    val=${line#"$key"}
    val=${val# }
    if [[ ${#val} -ge 2 && $val == \"*\" ]]; then val=${val:1:${#val}-2}; fi
    HATCH_OPT[$key]=$val
  done < <(psx show-options -g)
}

# get_opt <var> <@name> [default]: empty/unset falls back to the default.
get_opt() {
  hatch_load_options
  local -n _opt_out=$1
  _opt_out=${HATCH_OPT[$2]-}
  [ -n "$_opt_out" ] || _opt_out=${3-}
}

# get_opt2 <var> <@new> <@legacy> [default]: new naming, then the legacy one.
get_opt2() {
  hatch_load_options
  local -n _opt_out=$1
  _opt_out=${HATCH_OPT[$2]-}
  [ -n "$_opt_out" ] || _opt_out=${HATCH_OPT[$3]-}
  [ -n "$_opt_out" ] || _opt_out=${4-}
}

# --- providers ----------------------------------------------------------------

HATCH_PROVIDERS=(claude codex agy)

# provider_load <claude|codex|agy>: sets P_NAME P_PREFIX P_CMD P_ARGS.
provider_load() {
  P_NAME=$1
  get_opt P_PREFIX "@${1}_session_prefix" "$1-"
  get_opt P_CMD "@${1}_command" "$1"
  get_opt P_ARGS "@${1}_args" ''
}

# session_provider <session>: loads the provider whose dedicated-session prefix
# the name carries (P_*) and returns 0; returns 1 when it is not an agent session.
session_provider() {
  local n
  [ -n "${1-}" ] || return 1
  for n in "${HATCH_PROVIDERS[@]}"; do
    provider_load "$n"
    [[ $1 == "$P_PREFIX"* ]] && return 0
  done
  return 1
}

# split_words <array-var> <string>: split an option string honouring '...' and "...".
split_words() {
  local -n _words=$1
  local s=${2-} ch q='' cur='' has=0 i
  _words=()
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    if [ -n "$q" ]; then
      if [ "$ch" = "$q" ]; then q=''; else cur+=$ch; fi
    elif [ "$ch" = '"' ] || [ "$ch" = "'" ]; then
      q=$ch has=1
    elif [[ $ch == [[:space:]] ]]; then
      if ((has)) || [ -n "$cur" ]; then _words+=("$cur"); cur='' has=0; fi
    else
      cur+=$ch
    fi
  done
  if ((has)) || [ -n "$cur" ]; then _words+=("$cur"); fi
}

# pwsh_quote <var> <text>: a single-quoted PowerShell string literal.
pwsh_quote() {
  local -n _pq=$1
  _pq="'${2//\'/\'\'}'"
}

# find_executable <var> <name>: the Windows executable <name> resolves to, as a
# forward-slashed Windows path. PATH is walked by hand (no forks), trying the
# extensions cmd.exe would; a bare `claude` shim script written for bash is skipped.
find_executable() {
  local -n _exe=$1
  local name=$2 dir ext IFS=:
  _exe=''
  case $name in
    */* | *\\*)
      posix_to_win "$name"
      _exe=$REPLY
      return 0
      ;;
  esac
  win_to_posix "${APPDATA:-}"
  for dir in $PATH "$HOME/.local/bin" "$REPLY/npm"; do
    [ -n "$dir" ] || continue
    for ext in exe cmd bat com; do
      if [ -f "$dir/$name.$ext" ]; then
        posix_to_win "$dir/$name.$ext"
        _exe=$REPLY
        return 0
      fi
    done
  done
  return 1
}

# resolve_agent_line <command> <extra-args>: sets AGENT_LINE, the line the pane's
# shell (pwsh) runs. The pane gets no interactive PATH tweaks, so an executable we
# can resolve here is pinned to its full path; anything else (aliases, wrappers)
# is passed through untouched.
resolve_agent_line() {
  local words exe q w
  split_words words "$1"
  AGENT_LINE=$1
  if [ "${#words[@]}" -gt 0 ] && find_executable exe "${words[0]}"; then
    pwsh_quote q "$exe"
    AGENT_LINE="& $q"
    for w in "${words[@]:1}"; do
      pwsh_quote q "$w"
      AGENT_LINE+=" $q"
    done
  fi
  if [ -n "${2-}" ]; then AGENT_LINE+=" $2"; fi
}

# --- launching our own scripts -------------------------------------------------

# hatch_bash_exe: sets HATCH_BASH to this Git Bash as a forward-slashed Windows path.
hatch_bash_exe() {
  [ -n "${HATCH_BASH-}" ] && return 0
  HATCH_BASH=$(cygpath -m /usr/bin/bash.exe)
}

# pwsh_script_cmd <var> <script> [arg...]: the command line to hand to psmux
# (run-shell, display-popup, hooks), which parses it as PowerShell:
#   & '<Git Bash>' '<scripts>/<script>' 'arg'...
pwsh_script_cmd() {
  local -n _cmd=$1
  local script=$2 a q
  shift 2
  hatch_bash_exe
  pwsh_quote q "$HATCH_BASH"
  _cmd="& $q"
  pwsh_quote q "$HATCH_SCRIPTS/$script"
  _cmd+=" $q"
  for a in "$@"; do
    pwsh_quote q "$a"
    _cmd+=" $q"
  done
}

# hook_command <var> <script> [arg...]: the command line to paste into another tool's
# hook config (Codex, AGY). Those tools hand it to cmd.exe or PowerShell, and only a
# command with no quotes in it means the same to both, so spaces are avoided with
# 8.3 short names. If a path still has a space the quoted form is cmd.exe-only.
hook_command() {
  local -n _hook=$1
  local script=$2 b s a
  shift 2
  hatch_bash_exe
  b=$HATCH_BASH
  s="$HATCH_SCRIPTS/$script"
  [[ $b == *' '* ]] && b=$(cygpath -m -s "$b" 2>/dev/null || printf '%s' "$b")
  [[ $s == *' '* ]] && s=$(cygpath -m -s "$s" 2>/dev/null || printf '%s' "$s")
  if [[ $b == *' '* || $s == *' '* ]]; then
    _hook="\"$b\" \"$s\""
  else
    _hook="$b $s"
  fi
  for a in "$@"; do _hook+=" $a"; done
}

# cmd_script_cmd <var> <script> [raw-arg...]: the same for fzf, which runs its
# --preview/--bind commands through cmd.exe. Arguments are passed through raw so
# fzf's {n} placeholders survive.
cmd_script_cmd() {
  local -n _cmd=$1
  local script=$2
  shift 2
  hatch_bash_exe
  _cmd="\"$HATCH_BASH\" \"$HATCH_SCRIPTS/$script\""
  [ $# -eq 0 ] || _cmd+=" $*"
}

# --- misc ---------------------------------------------------------------------

# session_hash <string> -> REPLY: short, stable 8-char hash used to derive a session
# name from a path. The trailing newline matches the conventional
# `echo "$path" | md5sum` scheme, so sessions created earlier are found again.
session_hash() {
  local out
  out=$(printf '%s\n' "$1" | md5sum)
  REPLY=${out:0:8}
}

# '90%' -> absolute cells against the client, so a popup attaching a session never
# resizes that session. Anything that is not a percentage passes through.
# _popup_cells <value> <client-size> -> REPLY
_popup_cells() {
  local pct
  if [[ $1 =~ ^[[:space:]]*([0-9]+)[[:space:]]*%[[:space:]]*$ ]]; then
    pct=${BASH_REMATCH[1]}
  else
    REPLY=$1
    return
  fi
  if [[ ${2-} =~ ^[0-9]+$ ]] && (($2 > 0)); then
    REPLY=$(($2 * pct / 100))
    ((REPLY < 10)) && REPLY=10
  else
    REPLY=$1
  fi
}

# popup_size: sets POPUP_W / POPUP_H (call ctx_load first).
popup_size() {
  local w h
  get_opt2 w @agent_popup_width @claude_popup_width '90%'
  get_opt2 h @agent_popup_height @claude_popup_height '90%'
  _popup_cells "$w" "${CTX_WIDTH-}"
  POPUP_W=$REPLY
  _popup_cells "$h" "${CTX_HEIGHT-}"
  POPUP_H=$REPLY
}

# ctx_load: the pane/window/client the key was pressed in -> CTX_*. psmux does not
# hand a binding the pane's path, so we ask for the context ourselves.
ctx_load() {
  CTX_SESSION='' CTX_WINDOW_ID='' CTX_WINDOW_INDEX='' CTX_PANE_INDEX=''
  CTX_CLIENT='' CTX_WIDTH='' CTX_HEIGHT='' CTX_PATH=''
  local line
  line=$(psx display-message -p '#{session_name}|#{window_id}|#{window_index}|#{pane_index}|#{client_name}|#{client_width}|#{client_height}|#{pane_current_path}')
  line=${line%$'\r'}
  [ -n "$line" ] || return 1
  IFS='|' read -r CTX_SESSION CTX_WINDOW_ID CTX_WINDOW_INDEX CTX_PANE_INDEX \
    CTX_CLIENT CTX_WIDTH CTX_HEIGHT CTX_PATH <<<"$line"
}

# session_state <name>: sets SESSION_EXISTS / SESSION_ATTACHED (0|1) from one
# list-sessions call. An open agent popup is exactly a client attached to the
# session, so SESSION_ATTACHED is how we tell the popup is already up: the key
# press that asks for a second one may arrive with the OUTER client's context,
# where checking the session name proves nothing.
session_state() {
  SESSION_EXISTS=0 SESSION_ATTACHED=0
  local line
  while IFS= read -r line; do
    [[ ${line%%:*} == "$1" ]] || continue
    SESSION_EXISTS=1
    [[ $line == *'(attached'* ]] && SESSION_ATTACHED=1
    break
  done < <(psx list-sessions)
}

# client_connected <name>
client_connected() {
  local line
  while IFS= read -r line; do
    [[ ${line%%: *} == "$1" ]] && return 0
  done < <(psx list-clients)
  return 1
}

# --- persistent state ---------------------------------------------------------

# The launching window and client are kept in plain files: psmux options do not
# reliably carry a value from one session to another.
#   parent            the client that last opened the launcher / picker
#   origin/<session>  three lines: session, window id, window index

state_set_parent() {
  [ -n "${1-}" ] || return 0
  mkdir_p "$HATCH_DATA"
  printf '%s\n' "$1" >"$HATCH_DATA/parent" 2>/dev/null
}

# state_get_parent: REPLY is the parent client if it is still connected, else ''.
state_get_parent() {
  local c=''
  REPLY=''
  [ -f "$HATCH_DATA/parent" ] && IFS= read -r c <"$HATCH_DATA/parent"
  c=${c%$'\r'}
  if [ -n "$c" ] && client_connected "$c"; then REPLY=$c; fi
  return 0
}

# state_set_origin <agent-session>: record the window ctx_load found.
state_set_origin() {
  mkdir_p "$HATCH_DATA/origin"
  printf '%s\n%s\n%s\n' "$CTX_SESSION" "$CTX_WINDOW_ID" "$CTX_WINDOW_INDEX" \
    >"$HATCH_DATA/origin/$1" 2>/dev/null
}

# state_get_origin <agent-session>: sets ORIGIN_SESSION / ORIGIN_WINDOW / ORIGIN_INDEX.
state_get_origin() {
  ORIGIN_SESSION='' ORIGIN_WINDOW='' ORIGIN_INDEX=''
  local f=$HATCH_DATA/origin/$1
  [ -f "$f" ] || return 1
  {
    IFS= read -r ORIGIN_SESSION
    IFS= read -r ORIGIN_WINDOW
    IFS= read -r ORIGIN_INDEX
  } <"$f"
  ORIGIN_SESSION=${ORIGIN_SESSION%$'\r'} ORIGIN_INDEX=${ORIGIN_INDEX%$'\r'}
  return 0
}

HATCH_CACHE=$HATCH_DATA/picker.cache

clear_picker_cache() { [ -f "$HATCH_CACHE" ] && rm -f "$HATCH_CACHE" 2>/dev/null; return 0; }

# provider_state_dir <provider> -> REPLY: hook state for codex / agy, one
# key=value file per session id.
provider_state_dir() { REPLY="$HATCH_DATA/sessions/$1"; }

# copy_to_clipboard <text>: the Windows clipboard, plus a psmux buffer.
copy_to_clipboard() {
  printf '%s' "$1" | clip.exe 2>/dev/null
  psx set-buffer -- "$1" >/dev/null
}
