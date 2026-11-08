#!/usr/bin/env bash
# Emit one picker row per running Claude, Codex, or AGY agent that lives in a tmux pane.
#
#   Row: rank \t pane_id \t pid \t kind \t tag \t icon \t age \t loc \t path
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

TAB="$(printf '\t')"

# session_recs
# Reads internal Claude Code session state files for high performance.
#   Rec: pid \t status \t session-id \t cwd \t seen-at \t proc-start
session_recs() {
  local files
  files=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json)
  [ -f "${files[0]}" ] || return 1
  jq -r 'select(.kind == "interactive")
    | ((.statusUpdatedAt // .updatedAt) as $t | if $t then ($t / 1000 | floor) else "" end) as $seen
    | [.pid, .status, .sessionId, .cwd, $seen, .procStart] | @tsv' "${files[@]}" 2>/dev/null
}

# cli_recs
# Fallback when the Claude session files cannot be read.
cli_recs() {
  local cmd
  cmd="$(get_tmux_option @claude_command 'claude')"
  command -v "${cmd%% *}" >/dev/null 2>&1 || return 1
  $cmd agents --json 2>/dev/null |
    jq -r '.[] | select(.kind == "interactive") | [.pid, .status, .sessionId, .cwd] | @tsv' 2>/dev/null |
    while IFS="$TAB" read -r pid status sid cwd; do
      printf '%s\t%s\t%s\t%s\t%s\t\n' "$pid" "$status" "$sid" "$cwd" "$(claude_transcript_mtime "$sid")"
    done
}

# proc_starts <recs>
# Linux only: Claude records field 22 of /proc/<pid>/stat as proc-start there.
proc_starts() {
  printf '%s\n' "$1" | cut -f1 | while IFS= read -r pid; do
    IFS= read -r stat 2>/dev/null <"/proc/$pid/stat" || continue
    # shellcheck disable=SC2086 # deliberate split into positional parameters
    set -- ${stat##*) }
    [ $# -ge 20 ] && printf 'S\t%s\t%s\n' "$pid" "${20}"
  done
}

# codex_recs
# Reads state files written by codex-hook.sh and verifies them against live tmux panes.
#   Rec: pane_id \t status \t session-id \t cwd \t updated_at
codex_recs() {
  local state_dir cmd expected codex_prefix server_start live_panes f
  state_dir="$(codex_state_dir)"
  cmd="$(get_tmux_option @codex_command 'codex')"
  expected="${cmd%% *}"
  expected="${expected##*/}"
  codex_prefix="$(get_tmux_option @codex_session_prefix 'codex-')"

  server_start="$(tmux display-message -p '#{start_time}' 2>/dev/null || true)"
  live_panes="$(tmux list-panes -a -F "#{pane_id}${TAB}#{session_name}${TAB}#{pane_current_path}${TAB}#{pane_tty}" 2>/dev/null || true)"
  [ -n "$live_panes" ] || return 0

  local claims=""
  if [ -d "$state_dir" ]; then
    for f in "$state_dir"/*; do
      [ -f "$f" ] || continue
      codex_state_load "$f" || continue

      # Sweep claims older than server start
      if [ -n "$server_start" ] && [[ "${cs_updated_at:-0}" =~ ^[0-9]+$ ]]; then
        if [ "$cs_updated_at" -lt "$server_start" ]; then
          rm -f "$f" 2>/dev/null
          continue
        fi
      else
        rm -f "$f" 2>/dev/null
        continue
      fi

      # Sweep claims if pane no longer exists
      if [ -z "$cs_tmux_pane" ] || ! printf '%s\n' "$live_panes" | awk -F"$TAB" -v p="$cs_tmux_pane" '$1 == p { found = 1; exit } END { exit !found }'; then
        rm -f "$f" 2>/dev/null
        continue
      fi

      local id="${f##*/}"
      claims="${claims}${cs_tmux_pane}${TAB}${cs_updated_at:-0}${TAB}${id}${TAB}${cs_status}${TAB}${cs_cwd}${TAB}${f}
"
    done
  fi

  local sorted=""
  if [ -n "$claims" ]; then
    sorted="$(printf '%s' "$claims" | sort -t"$TAB" -k1,1 -k2,2nr)"
    # Clean up older claims on the same pane
    printf '%s\n' "$sorted" | awk -F"$TAB" 'NF && seen[$1]++ { print $6 }' |
      while IFS= read -r old_file; do
        [ -n "$old_file" ] && rm -f "$old_file" 2>/dev/null
      done
  fi

  # Output surviving claims
  if [ -n "$sorted" ]; then
    printf '%s\n' "$sorted" | awk -F"$TAB" 'NF && !seen[$1]++ {
      print $1 "\t" $4 "\t" $3 "\t" $5 "\t" $2
    }'
  fi

  # Dedicated fresh codex sessions without a surviving claim yet
  if [ -n "$sorted" ]; then
    local claimed_panes
    claimed_panes="$(printf '%s\n' "$sorted" | awk -F"$TAB" 'NF && !seen[$1]++ { print $1 }')"
    printf '%s\n' "$live_panes" | awk -F"$TAB" -v prefix="$codex_prefix" -v claimed="$claimed_panes" '
      BEGIN { split(claimed, c, "\n"); for (i in c) has[c[i]] = 1 }
      index($2, prefix) == 1 && !( $1 in has ) {
        print $1 "\t-\t" $2 "\t" $3 "\t0"
      }
    '
  else
    printf '%s\n' "$live_panes" | awk -F"$TAB" -v prefix="$codex_prefix" '
      index($2, prefix) == 1 {
        print $1 "\t-\t" $2 "\t" $3 "\t0"
      }
    '
  fi
}

# agy_recs
# Reads state files written by agy-hook.sh and verifies them against live tmux panes.
#   Rec: pane_id \t status \t conversation-id \t cwd \t updated_at
agy_recs() {
  local state_dir cmd expected agy_prefix server_start live_panes f
  state_dir="$(agy_state_dir)"
  cmd="$(get_tmux_option @agy_command 'agy')"
  expected="${cmd%% *}"
  expected="${expected##*/}"
  agy_prefix="$(get_tmux_option @agy_session_prefix 'agy-')"

  server_start="$(tmux display-message -p '#{start_time}' 2>/dev/null || true)"
  live_panes="$(tmux list-panes -a -F "#{pane_id}${TAB}#{session_name}${TAB}#{pane_current_path}${TAB}#{pane_tty}" 2>/dev/null || true)"
  [ -n "$live_panes" ] || return 0

  local claims=""
  if [ -d "$state_dir" ]; then
    for f in "$state_dir"/*; do
      [ -f "$f" ] || continue
      agy_state_load "$f" || continue

      # Sweep claims older than server start
      if [ -n "$server_start" ] && [[ "${as_updated_at:-0}" =~ ^[0-9]+$ ]]; then
        if [ "$as_updated_at" -lt "$server_start" ]; then
          rm -f "$f" 2>/dev/null
          continue
        fi
      else
        rm -f "$f" 2>/dev/null
        continue
      fi

      # Sweep claims if pane no longer exists
      if [ -z "$as_tmux_pane" ] || ! printf '%s\n' "$live_panes" | awk -F"$TAB" -v p="$as_tmux_pane" '$1 == p { found = 1; exit } END { exit !found }'; then
        rm -f "$f" 2>/dev/null
        continue
      fi

      local id="${f##*/}"
      claims="${claims}${as_tmux_pane}${TAB}${as_updated_at:-0}${TAB}${id}${TAB}${as_status}${TAB}${as_cwd}${TAB}${f}
"
    done
  fi

  local sorted=""
  if [ -n "$claims" ]; then
    sorted="$(printf '%s' "$claims" | sort -t"$TAB" -k1,1 -k2,2nr)"
    # Clean up older claims on the same pane
    printf '%s\n' "$sorted" | awk -F"$TAB" 'NF && seen[$1]++ { print $6 }' |
      while IFS= read -r old_file; do
        [ -n "$old_file" ] && rm -f "$old_file" 2>/dev/null
      done
  fi

  # Output surviving claims
  if [ -n "$sorted" ]; then
    printf '%s\n' "$sorted" | awk -F"$TAB" 'NF && !seen[$1]++ {
      print $1 "\t" $4 "\t" $3 "\t" $5 "\t" $2
    }'
  fi

  # Dedicated fresh agy sessions without a surviving claim yet
  if [ -n "$sorted" ]; then
    local claimed_panes
    claimed_panes="$(printf '%s\n' "$sorted" | awk -F"$TAB" 'NF && !seen[$1]++ { print $1 }')"
    printf '%s\n' "$live_panes" | awk -F"$TAB" -v prefix="$agy_prefix" -v claimed="$claimed_panes" '
      BEGIN { split(claimed, c, "\n"); for (i in c) has[c[i]] = 1 }
      index($2, prefix) == 1 && !( $1 in has ) {
        print $1 "\t-\t" $2 "\t" $3 "\t0"
      }
    '
  else
    printf '%s\n' "$live_panes" | awk -F"$TAB" -v prefix="$agy_prefix" '
      index($2, prefix) == 1 {
        print $1 "\t-\t" $2 "\t" $3 "\t0"
      }
    '
  fi
}

render() {
  local claude_recs="$1"
  local claude_verified="$2"
  local codex_recs="$3"
  local agy_recs="$4"

  local claude_pids=""
  if [ -n "$claude_recs" ]; then
    claude_pids="$(printf '%s\n' "$claude_recs" | cut -f1 | paste -sd, -)"
  fi

  local claude_cmd codex_cmd agy_cmd claude_base codex_base agy_base prefix_claude prefix_codex prefix_agy
  claude_cmd="$(get_tmux_option @claude_command 'claude')"
  codex_cmd="$(get_tmux_option @codex_command 'codex')"
  agy_cmd="$(get_tmux_option @agy_command 'agy')"
  claude_base="${claude_cmd%% *}" claude_base="${claude_base##*/}"
  codex_base="${codex_cmd%% *}" codex_base="${codex_base##*/}"
  agy_base="${agy_cmd%% *}" agy_base="${agy_base##*/}"
  prefix_claude="$(get_tmux_option @claude_session_prefix 'claude-')"
  prefix_codex="$(get_tmux_option @codex_session_prefix 'codex-')"
  prefix_agy="$(get_tmux_option @agy_session_prefix 'agy-')"

  {
    ps -Ao pid=,tty=,comm= 2>/dev/null | awk '{
      pid = $1; tty = $2
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "")
      print "P\t" pid "\t" tty "\t" $0
    }'

    if [ -n "$claude_pids" ]; then
      TZ=UTC LC_ALL=C ps -o pid=,lstart= -p "$claude_pids" 2>/dev/null |
        awk '{ print "L\t" $1 "\t" $2 " " $3 " " $4 " " $5 " " $6 }'
      [ -r /proc/self/stat ] && proc_starts "$claude_recs"
    fi

    tmux list-panes -a -F "T${TAB}#{pane_tty}${TAB}#{pane_id}${TAB}#{session_name}${TAB}#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null

    [ -n "$claude_recs" ] && printf '%s\n' "$claude_recs" | sed $'s/^/CLA\t/'
    [ -n "$codex_recs" ] && printf '%s\n' "$codex_recs" | sed $'s/^/CDX\t/'
    [ -n "$agy_recs" ] && printf '%s\n' "$agy_recs" | sed $'s/^/AGY\t/'
  } | awk -F"$TAB" -v verify="$claude_verified" -v now="$(date +%s)" -v home="$HOME" \
      -v prefix_claude="$prefix_claude" -v prefix_codex="$prefix_codex" -v prefix_agy="$prefix_agy" \
      -v cmd_claude="$claude_base" -v cmd_codex="$codex_base" -v cmd_agy="$agy_base" '
      $1 == "P" {
        sub(/^\/dev\//, "", $3)
        tty_of_pid[$2] = $3
        base = $4; sub(/.*\//, "", base)
        if (!(( $3, base ) in pid_on_tty)) pid_on_tty[$3, base] = $2
        last_pid_on_tty[$3] = $2
        next
      }
      $1 == "L" { start_of_pid[$2] = $3; next }
      $1 == "S" { start_of_pid[$2] = $3; next }
      $1 == "T" {
        sub(/^\/dev\//, "", $2)
        pane_of_tty[$2] = $3
        tty_of_pane[$3] = $2
        sess_of_tty[$2] = $4
        loc_of_tty[$2] = $5
        next
      }
      $1 == "CLA" && $2 != "" {
        pid = $2; status = $3; sid = $4; path = $5; seen = $6; proc_start = $7
        if (verify) {
          if (status == "" || path == "" || seen == "" || proc_start == "") next
          gsub(/ +/, " ", proc_start)
          if (start_of_pid[pid] != proc_start) next
        }
        tty = tty_of_pid[pid]
        if (tty == "" || !(tty in pane_of_tty)) next

        p = pane_of_tty[tty]
        loc = loc_of_tty[tty]
        sess = sess_of_tty[tty]
        kind = (index(sess, prefix_claude) == 1) ? "dedicated" : "loose"
        tag = "\033[38;5;208mclaude\033[0m"

        if      (status == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }
        else if (status == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }
        else if (status == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }
        else                          { icon = "\033[90m●\033[0m   ?    "; rank = 2 }

        secs = (seen != "") ? (now - seen) : 1e12
        if (secs < 0) secs = 0
        mins = int(secs / 60)
        if      (seen == "")  age = "-"
        else if (mins < 60)   age = mins "m"
        else if (mins < 2880) age = int(mins / 60) "h"
        else                  age = int(mins / 1440) "d"

        if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

        printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n",
          secs, rank, p, pid, kind, tag, icon, age, loc, path
        next
      }
      $1 == "CDX" && $2 != "" {
        p = $2; status = $3; sid = $4; path = $5; seen = $6
        tty = tty_of_pane[p]
        if (tty == "") next

        loc = loc_of_tty[tty]
        sess = sess_of_tty[tty]
        pid = pid_on_tty[tty, cmd_codex]
        if (pid == "") pid = last_pid_on_tty[tty]
        if (pid == "") next

        kind = (index(sess, prefix_codex) == 1) ? "dedicated" : "loose"
        tag = "\033[36mcodex  \033[0m"

        if      (status == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }
        else if (status == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }
        else if (status == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }
        else                          { icon = "\033[90m●\033[0m   ?    "; rank = 2 }

        secs = (seen != "" && seen > 0) ? (now - seen) : 1e12
        if (secs < 0) secs = 0
        mins = int(secs / 60)
        if      (seen == "" || seen <= 0) age = "-"
        else if (mins < 60)   age = mins "m"
        else if (mins < 2880) age = int(mins / 60) "h"
        else                  age = int(mins / 1440) "d"

        if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

        printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n",
          secs, rank, p, pid, kind, tag, icon, age, loc, path
        next
      }
      $1 == "AGY" && $2 != "" {
        p = $2; status = $3; sid = $4; path = $5; seen = $6
        tty = tty_of_pane[p]
        if (tty == "") next

        loc = loc_of_tty[tty]
        sess = sess_of_tty[tty]
        pid = pid_on_tty[tty, cmd_agy]
        if (pid == "") pid = last_pid_on_tty[tty]
        if (pid == "") next

        kind = (index(sess, prefix_agy) == 1) ? "dedicated" : "loose"
        tag = "\033[35magy    \033[0m"

        if      (status == "waiting")                  { icon = "\033[33m●\033[0m waiting"; rank = 0 }
        else if (status == "idle")                     { icon = "\033[32m●\033[0m idle   "; rank = 1 }
        else if (status == "busy" || status == "working") { icon = "\033[31m●\033[0m working"; rank = 3 }
        else                                           { icon = "\033[90m●\033[0m   ?    "; rank = 2 }

        secs = (seen != "" && seen > 0) ? (now - seen) : 1e12
        if (secs < 0) secs = 0
        mins = int(secs / 60)
        if      (seen == "" || seen <= 0) age = "-"
        else if (mins < 60)   age = mins "m"
        else if (mins < 2880) age = int(mins / 60) "h"
        else                  age = int(mins / 1440) "d"

        if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

        printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n",
          secs, rank, p, pid, kind, tag, icon, age, loc, path
        next
      }
  ' | sort -t"$TAB" $sort_keys | cut -f2-
}

sort_mode="$(get_first_tmux_option @agent_sort @claude_sort 'status')"
if [ "$sort_mode" = recent ]; then
  sort_keys='-k1,1n'
else
  sort_keys='-k2,2n -k1,1n'
fi

# Gather Claude recs
claude_recs=""
claude_verified=""
if claude_recs="$(session_recs 2>/dev/null)" && [ -n "$claude_recs" ]; then
  claude_verified=1
elif claude_recs="$(cli_recs 2>/dev/null)"; then
  claude_verified=""
fi

# Gather Codex recs
codex_recs="$(codex_recs 2>/dev/null || true)"

# Gather AGY recs
agy_recs="$(agy_recs 2>/dev/null || true)"

if [ -z "$claude_recs" ] && [ -z "$codex_recs" ] && [ -z "$agy_recs" ]; then
  exit 0
fi

out="$(render "$claude_recs" "$claude_verified" "$codex_recs" "$agy_recs")"
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
