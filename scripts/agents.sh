#!/usr/bin/env bash
# Emit one picker row per running Claude, Codex or AGY agent that lives in a psmux pane.
#
#   Row (tab-separated):
#     rank, target, pid, kind, provider, session, tag, icon, age, loc, path
#   Columns 1-6 are hidden from the display via fzf's --with-nth.
#     target   session:window.pane (pane ids repeat across sessions in psmux)
#     pid      Claude: the claude process. Codex/AGY: the pane's shell, whose
#              children are the agent (that is what ctrl-x kills).
#     kind     dedicated (a session this plugin launched) | loose (any other pane)
#
# Windows has no tty to join on, so identity comes from where each agent reports it:
#   * Claude self-reports (~/.claude/sessions/*.json), including the psmux session and
#     %pane id it runs in (the "tmux" field); `ps -W` confirms the process is alive.
#   * Codex and AGY report through lifecycle hooks (codex-hook.sh / agy-hook.sh), which
#     record the session name and %pane id they ran in.
#
# Run it directly, or source it and call agents_main (picker.sh does, saving a bash start).
_d=${BASH_SOURCE[0]%/*}; [ "$_d" = "${BASH_SOURCE[0]}" ] && _d=.
. "$_d/helpers.sh"

# state_read <file>: parse a key=value hook state file into ST_*.
state_read() {
  ST_status='' ST_cwd='' ST_session='' ST_pane='' ST_updated=''
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      status=*) ST_status=${line#status=} ;;
      cwd=*) ST_cwd=${line#cwd=} ;;
      session=*) ST_session=${line#session=} ;;
      pane=*) ST_pane=${line#pane=} ;;
      updated_at=*) ST_updated=${line#updated_at=} ;;
    esac
  done <"$1"
}

agents_main() {
  local TAB=$'\t' ESC=$'\e' US=$'\x1f' # US: internal field separator (never IFS-whitespace)
  local now
  printf -v now '%(%s)T' -1

  # --- live panes -------------------------------------------------------------
  local -A pane_target pane_session pane_path pane_pid pane_created
  local -a pane_keys=()
  local line ppid psess pwin pidx pid_ created ppath key
  while IFS= read -r line; do
    line=${line%$'\r'}
    IFS='|' read -r ppid psess pwin pidx pid_ created ppath <<<"$line"
    [ -n "$pid_" ] || continue
    key="$psess|$pid_"
    pane_target[$key]="$psess:$pwin.$pidx"
    pane_session[$key]=$psess
    pane_path[$key]=${ppath//\\//}
    pane_pid[$key]=$ppid
    pane_created[$key]=$created
    pane_keys+=("$key")
  done < <(psx list-panes -a -F '#{pane_pid}|#{session_name}|#{window_index}|#{pane_index}|#{pane_id}|#{session_created}|#{pane_current_path}')
  [ "${#pane_keys[@]}" -gt 0 ] || return 0

  local -A prefix
  local n
  for n in "${HATCH_PROVIDERS[@]}"; do
    provider_load "$n"
    prefix[$n]=$P_PREFIX
  done

  # recs: provider, pane-key, pid, status, cwd, seen (joined with US)
  local -a recs=()

  # --- Claude -----------------------------------------------------------------
  # jq is a native Windows program (argument conversion is off, see helpers.sh), so it
  # is handed C:/... paths; bash globs them just as well.
  local claude_dir
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    claude_dir=${CLAUDE_CONFIG_DIR//\\//}
  else
    posix_to_win "$HOME/.claude"
    claude_dir=$REPLY
  fi
  local -a files=("$claude_dir"/sessions/*.json)
  if [ -f "${files[0]}" ] && command -v jq >/dev/null 2>&1; then
    local psw='' cpid cstatus csid ccwd ctmux cseen
    psw=$(ps -W 2>/dev/null)
    local re_tmux='^(.+):@[0-9]+\.(%[0-9]+)$' re_alive
    while IFS=$US read -r cpid cstatus csid ccwd ctmux cseen; do
      cseen=${cseen%$'\r'} # jq.exe ends its lines with CRLF
      [ -n "$cpid" ] || continue
      # Only sessions that name their pane can be placed.
      [[ $ctmux =~ $re_tmux ]] || continue
      key="${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
      [ -n "${pane_target[$key]-}" ] || continue
      # A crashed Claude leaves its session file behind; the process must be alive.
      # ps -W columns: PID PPID PGID WINPID ...
      re_alive="(^|"$'\n'")[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+${cpid}[[:space:]]"
      [[ $psw =~ $re_alive ]] || continue
      recs+=("claude$US$key$US$cpid$US$cstatus$US$ccwd$US$cseen")
    done < <(jq -r 'select(.kind == "interactive" and .pid != null)
      | [.pid, (.status // ""), (.sessionId // ""),
         ((.cwd // "") | gsub("\\\\"; "/")), (.tmux // ""),
         (((.statusUpdatedAt // .updatedAt // 0) / 1000) | floor)] | map(tostring) | join("\u001f")' "${files[@]}" 2>/dev/null)
  fi

  # --- Codex / AGY (hook state files) -----------------------------------------
  local name dir f prev_updated
  local -A claim_file claim_updated claim_status claim_cwd
  for name in codex agy; do
    provider_state_dir "$name"
    dir=$REPLY
    claim_file=() claim_updated=() claim_status=() claim_cwd=()

    for f in "$dir"/*.state; do
      [ -f "$f" ] || continue
      state_read "$f"
      key="$ST_session|$ST_pane"
      # Claims whose pane is gone belong to a dead agent. So do claims older than
      # their session: they were written for an earlier session of the same name
      # (a previous psmux run). Not #{start_time}: psmux reports the start of whichever
      # session the query lands in, not of the server.
      if [[ ! $ST_updated =~ ^[0-9]+$ ]] || [ -z "$ST_session" ] || [ -z "$ST_pane" ] ||
        [ -z "${pane_target[$key]-}" ]; then
        rm -f "$f" 2>/dev/null
        continue
      fi
      if ((ST_updated < ${pane_created[$key]:-0})); then
        rm -f "$f" 2>/dev/null
        continue
      fi
      # One agent per pane: the newest claim wins, older ones are swept.
      if [ -n "${claim_file[$key]-}" ]; then
        prev_updated=${claim_updated[$key]}
        if ((ST_updated > prev_updated)); then
          rm -f "${claim_file[$key]}" 2>/dev/null
        else
          rm -f "$f" 2>/dev/null
          continue
        fi
      fi
      claim_file[$key]=$f
      claim_updated[$key]=$ST_updated
      claim_status[$key]=$ST_status
      claim_cwd[$key]=${ST_cwd//\\//}
    done

    for key in "${!claim_file[@]}"; do
      recs+=("$name$US$key$US${pane_pid[$key]}$US${claim_status[$key]}$US${claim_cwd[$key]}$US${claim_updated[$key]}")
    done

    # A freshly launched dedicated session has no hook claim yet.
    for key in "${pane_keys[@]}"; do
      if [[ ${pane_session[$key]} == "${prefix[$name]}"* && -z "${claim_file[$key]-}" ]]; then
        recs+=("$name$US$key$US${pane_pid[$key]}$US-$US${pane_path[$key]}${US}0")
      fi
    done
  done

  [ "${#recs[@]}" -gt 0 ] || return 0

  # --- render -----------------------------------------------------------------
  local -A tags=(
    [claude]="${ESC}[38;5;208mclaude${ESC}[0m"
    [codex]="${ESC}[36mcodex  ${ESC}[0m"
    [agy]="${ESC}[35magy    ${ESC}[0m"
  )
  local home=${USERPROFILE//\\//} home_lc
  home_lc=${home,,}

  local -a rows=()
  local rec provider rkey rpid rstatus rcwd rseen
  local rank icon secs mins age path path_lc kind
  for rec in "${recs[@]}"; do
    IFS=$US read -r provider rkey rpid rstatus rcwd rseen <<<"$rec"
    [[ $rpid =~ ^[0-9]+$ ]] && ((rpid > 0)) || continue

    case $rstatus in
      waiting) icon="${ESC}[33m●${ESC}[0m waiting" rank=0 ;;
      idle) icon="${ESC}[32m●${ESC}[0m idle   " rank=1 ;;
      busy | working) icon="${ESC}[31m●${ESC}[0m working" rank=3 ;;
      *) icon="${ESC}[90m●${ESC}[0m   ?    " rank=2 ;;
    esac

    if [[ $rseen =~ ^[0-9]+$ ]] && ((rseen > 0)); then
      secs=$((now - rseen))
      ((secs < 0)) && secs=0
      mins=$((secs / 60))
      if ((mins < 60)); then
        age="${mins}m"
      elif ((mins < 2880)); then
        age="$((mins / 60))h"
      else
        age="$((mins / 1440))d"
      fi
    else
      secs=1000000000000
      age='-'
    fi
    printf -v age '%5s' "$age"

    path=$rcwd
    path_lc=${path,,}
    if [ -n "$home_lc" ] && [[ $path_lc == "$home_lc"* ]]; then path="~${path:${#home}}"; fi

    if [[ ${pane_session[$rkey]} == "${prefix[$provider]}"* ]]; then kind=dedicated; else kind=loose; fi

    # rank, secs: sort keys, dropped again below.
    rows+=("$rank$TAB$secs$TAB$rank$TAB${pane_target[$rkey]}$TAB$rpid$TAB$kind$TAB$provider$TAB${pane_session[$rkey]}$TAB${tags[$provider]}$TAB$icon$TAB$age$TAB${pane_target[$rkey]}$TAB$path")
  done
  [ "${#rows[@]}" -gt 0 ] || return 0

  local sort_mode
  get_opt2 sort_mode @agent_sort @claude_sort status
  if [ "$sort_mode" = recent ]; then
    printf '%s\n' "${rows[@]}" | sort -t "$TAB" -k2,2n | cut -f3-
  else
    printf '%s\n' "${rows[@]}" | sort -t "$TAB" -k1,1n -k2,2n | cut -f3-
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  agents_main
  exit 0
fi
