#!/usr/bin/env bash
# AGY (Antigravity CLI) lifecycle-hook dispatcher for psmux-agent-hatch.
#
# AGY passes hook context as JSON on stdin (conversationId, workspacePaths,
# transcriptPath) but no event name — the status is baked into the command line by
# the hooks.json wiring (scripts/print-hook-config.ps1 agy prints it):
#
#   agy-hook.sh idle      SessionStart / Stop
#   agy-hook.sh working   UserPromptSubmit / PreInvocation / PostToolUse
#   agy-hook.sh waiting   PreToolUse (ask_question)
#
# For tool-call payloads AGY expects a JSON decision on stdout; we always answer
# {"decision": "allow"} so we never block anything. Always exits 0.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh" 2>/dev/null || exit 0

main() {
  local status=${1-}
  case $status in working | waiting | idle | busy) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0

  local payload id cwd transcript has_tool_call
  payload=$(cat) || return 0

  # PreToolUse hooks expect a decision on stdout, whether or not we track this run.
  has_tool_call=$(printf '%s' "$payload" | jq -r 'has("toolCall")' 2>/dev/null)
  has_tool_call=${has_tool_call%$'\r'}
  [ "$has_tool_call" = true ] && printf '{"decision": "allow"}\n'

  # AGY outside psmux can never appear in the picker.
  [ -n "${TMUX_PANE:-}" ] && [ -n "${PSMUX_SESSION:-}" ] || return 0

  IFS=$'\x1f' read -r id cwd transcript < <(
    printf '%s' "$payload" | jq -r '[.conversationId, .workspacePaths[0]?, .transcriptPath]
      | map(. // "" | tostring | gsub("[\\n\\r]"; " ")) | join("\u001f")' 2>/dev/null
  )

  transcript=${transcript%$'\r'} # jq.exe ends its lines with CRLF

  # conversationId becomes a filename; refuse anything that could escape the dir.
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0

  provider_state_dir agy
  local dir=$REPLY tmp now
  mkdir_p "$dir"
  [ -d "$dir" ] || return 0
  printf -v now '%(%s)T' -1

  tmp=$dir/.$id.$$
  {
    printf 'status=%s\n' "$status"
    printf 'cwd=%s\n' "$cwd"
    printf 'transcript_path=%s\n' "$transcript"
    printf 'session=%s\n' "$PSMUX_SESSION"
    printf 'pane=%s\n' "$TMUX_PANE"
    printf 'conversation_id=%s\n' "$id"
    printf 'updated_at=%s\n' "$now"
  } >"$tmp" || {
    rm -f "$tmp"
    return 0
  }
  mv -f "$tmp" "$dir/$id.state" || rm -f "$tmp"

  clear_picker_cache
}

# stdout must reach AGY (the allow decision); only errors are discarded.
main "$@" 2>/dev/null
exit 0
