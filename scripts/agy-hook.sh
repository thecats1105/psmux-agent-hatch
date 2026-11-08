#!/usr/bin/env bash
# AGY (Antigravity CLI) lifecycle-hook dispatcher for tmux-agent-hatch.
#
# AGY passes hook context as JSON on stdin with fields such as conversationId,
# workspacePaths, and transcriptPath.  Unlike Codex, AGY does NOT include a
# hook_event_name — instead the implied status is baked into the command line
# argument by the hooks.json wiring (see --print-config):
#
#   SessionStart / Stop              -> idle
#   PreInvocation / PostToolUse      -> working
#   PreToolUse (ask_question)        -> waiting
#
# For PreToolUse hooks AGY expects a JSON decision on stdout; we always emit
# {"decision":"allow"} so we never block execution.
#
# The hook is a no-op decision: it always exits 0, so it can never block, deny,
# or alter an AGY tool call — including on malformed payloads, an unwritable
# state dir, or missing jq/tmux.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh" 2>/dev/null || true

# Print the ready-to-paste ~/.gemini/config/hooks.json snippet.
# Read-only — never touches any config file.
print_config() {
  local self="$DIR/agy-hook.sh"
  cat <<EOF
{
  "tmux-agent-hatch": {
    "enabled": true,
    "SessionStart": [
      { "type": "command", "command": "$self idle" }
    ],
    "UserPromptSubmit": [
      { "type": "command", "command": "$self working" }
    ],
    "PreInvocation": [
      { "type": "command", "command": "$self working" }
    ],
    "PreToolUse": [
      {
        "matcher": "ask_question",
        "hooks": [
          { "type": "command", "command": "$self waiting" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "$self working" }
        ]
      }
    ],
    "Stop": [
      { "type": "command", "command": "$self idle" }
    ]
  }
}
EOF
}

if [ "${1:-}" = '--print-config' ]; then
  print_config
  exit 0
fi

main() {
  local status="${1:-}"
  case "$status" in
  working | waiting | idle | busy) ;;
  *) return 0 ;;
  esac

  # AGY outside tmux can never appear in the picker; don't churn the sweep.
  [ -n "${TMUX_PANE:-}" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local payload conversation_id cwd transcript_path has_tool_call
  payload="$(cat)" || return 0

  # For PreToolUse hooks, AGY expects a JSON decision on stdout.
  # Check for the toolCall field and emit the allow decision.
  has_tool_call="$(printf '%s' "$payload" | jq -r 'has("toolCall")' 2>/dev/null)" || true
  if [ "$has_tool_call" = "true" ]; then
    printf '{"decision": "allow"}\n'
  fi

  IFS=$'\t' read -r conversation_id cwd transcript_path < <(
    printf '%s' "$payload" | jq -r '[
      .conversationId // "", .workspacePaths[0] // "",
      .transcriptPath // ""
    ] | @tsv' 2>/dev/null
  ) || true

  # conversationId becomes a filename; refuse anything that could escape the dir.
  case "${conversation_id:-}" in '' | . | .. | */* | .*) return 0 ;; esac

  local state_dir tmp
  state_dir="$(agy_state_dir)" || return 0
  [ -n "$state_dir" ] || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0

  # Atomic write: readers see the complete old file or the complete new one.
  # The dot prefix keeps half-written temp files out of the provider's glob.
  tmp="$(mktemp "$state_dir/.$conversation_id.XXXXXX" 2>/dev/null)" || return 0
  {
    printf 'status=%s\n' "$status"
    printf 'cwd=%s\n' "${cwd:-}"
    printf 'transcript_path=%s\n' "${transcript_path:-}"
    printf 'tmux_pane=%s\n' "$TMUX_PANE"
    printf 'conversation_id=%s\n' "${conversation_id:-}"
    printf 'updated_at=%s\n' "$(date +%s)"
  } >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 0
  }
  mv -f "$tmp" "$state_dir/$conversation_id" 2>/dev/null || rm -f "$tmp" 2>/dev/null

  # Invalidate picker caches so next open shows the latest status immediately.
  local cache
  for cache in "${TMPDIR:-/tmp}/tmux-agent-hatch-$(id -u).cache" "${TMPDIR:-/tmp}/tmux-claude-agents-$(id -u).cache"; do
    [ -f "$cache" ] && rm -f "$cache" 2>/dev/null || true
  done

  return 0
}

main "$@" 2>/dev/null
exit 0
