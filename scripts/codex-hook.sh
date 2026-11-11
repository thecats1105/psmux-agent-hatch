#!/usr/bin/env bash
# Codex lifecycle-hook dispatcher for psmux-agent-hatch.
#
# Codex has no `claude agents --json` analogue, so status is reconstructed from its
# lifecycle hooks: wire this one script into all six events in ~/.codex/hooks.json
# (scripts/print-hook-config.ps1 codex prints the config). Each firing rewrites that session's state file with the
# status the event implies; agents.sh reads those files.
#
#   SessionStart / Stop                         -> idle
#   UserPromptSubmit / PreToolUse / PostToolUse -> busy
#   PermissionRequest                           -> waiting
#
# A no-op decision: always exits 0 with no stdout, so it can never block, deny or
# alter a Codex tool call — including on a malformed payload, an unwritable state
# dir, or a missing jq.
_s=${BASH_SOURCE[0]//\\//}; _d=${_s%/*}; [ "$_d" = "$_s" ] && _d=.
. "$_d/helpers.sh" 2>/dev/null || exit 0

main() {
  # Codex outside psmux can never appear in the picker.
  [ -n "${TMUX_PANE:-}" ] && [ -n "${PSMUX_SESSION:-}" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local payload event id cwd transcript turn status
  payload=$(cat) || return 0
  IFS=$'\x1f' read -r event id cwd transcript turn < <(
    printf '%s' "$payload" | jq -r '[.hook_event_name, .session_id, .cwd, .transcript_path, .turn_id]
      | map(. // "" | tostring | gsub("[\\n\\r]"; " ")) | join("\u001f")' 2>/dev/null
  )

  turn=${turn%$'\r'} # jq.exe ends its lines with CRLF

  # session_id becomes a filename; refuse anything that could escape the dir.
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0

  case $event in
    SessionStart | Stop) status=idle ;;
    UserPromptSubmit | PreToolUse | PostToolUse) status=busy ;;
    PermissionRequest) status=waiting ;;
    *) return 0 ;;
  esac

  provider_state_dir codex
  local dir=$REPLY tmp now
  mkdir_p "$dir" || return 0
  [ -d "$dir" ] || return 0
  printf -v now '%(%s)T' -1

  # Atomic write: readers see the complete old file or the complete new one. The dot
  # prefix keeps half-written files out of the *.state glob.
  tmp=$dir/.$id.$$
  {
    printf 'status=%s\n' "$status"
    printf 'cwd=%s\n' "$cwd"
    printf 'transcript_path=%s\n' "$transcript"
    printf 'session=%s\n' "$PSMUX_SESSION"
    printf 'pane=%s\n' "$TMUX_PANE"
    printf 'turn_id=%s\n' "$turn"
    printf 'updated_at=%s\n' "$now"
  } >"$tmp" || {
    rm -f "$tmp"
    return 0
  }
  mv -f "$tmp" "$dir/$id.state" || rm -f "$tmp"

  # Next picker open shows the latest status immediately.
  clear_picker_cache
}

main >/dev/null 2>&1
exit 0
