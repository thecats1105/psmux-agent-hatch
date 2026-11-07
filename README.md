# tmux-agent-hatch

A tmux plugin that runs **Claude Code** and **Codex** sessions in popups for each project directory.
Forked from [`craftzdog/tmux-claude-hatch`](https://github.com/craftzdog/tmux-claude-hatch) and inspired by [`aaronvb/tmux-claude-codex-session-manager`](https://github.com/aaronvb/tmux-claude-codex-session-manager).

Open the hatch, hand an AI agent the work, close it and get back to your editor. Each session lives in its own nested tmux session, so closing the hatch never interrupts it. When you want to check in, an `fzf` picker lists every running session across **both Claude and Codex**, shows what each one is doing, and jumps you straight to it.

## Features

- **Unified picker** (`prefix` + `u`) listing every running Claude and Codex agent — several in one project, and any running loose in ordinary panes.
- **Provider tags & status indicators** — color-coded tags (`claude` in orange, `codex` in cyan) and live status (`working`, `waiting`, `idle`).
- **Live preview** of each agent's screen right in the picker.
- **Smart jump** — selecting an agent switches your client to the window it was launched from, then resumes it in a popup over it.
- **Independent launchers**:
  - `prefix` + `y` for **Claude Code**
  - `prefix` + `Y` for **Codex**
- **Quick kill** (`ctrl-x`) of a finished agent from the picker.
- **Copy location** (`ctrl-y`) — puts an agent's `session:window.pane` target on the clipboard.
- **Bell forwarding** — a bell in a dedicated session highlights the origin window.
- **High-performance session engine** — direct session state parsing with caching and instant reactivity.

## Prerequisites

- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** — picker UI
- **[jq](https://jqlang.org/)** — state parsing
- **Claude Code** and/or **Codex CLI**
- bash (Linux or macOS)

## Installation

### Via TPM (Tmux Plugin Manager)

Add to your `~/.tmux.conf` or `~/.config/tmux/tmux.conf`:

```tmux
set -g @plugin 'thecats1105/tmux-agent-hatch'
```

Then press `prefix` + `I` to fetch and load the plugin.

## Codex Setup

Codex lifecycle events are tracked via hooks. Wire `codex-hook.sh` into `~/.codex/hooks.json`.

You can automatically generate the required configuration:

```bash
~/.config/tmux/plugins/tmux-agent-hatch/scripts/codex-hook.sh --print-config
# or for ~/.tmux/plugins:
~/.tmux/plugins/tmux-agent-hatch/scripts/codex-hook.sh --print-config
```

Paste the output into `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-hatch/scripts/codex-hook.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-hatch/scripts/codex-hook.sh" }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-hatch/scripts/codex-hook.sh" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-hatch/scripts/codex-hook.sh" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-hatch/scripts/codex-hook.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-hatch/scripts/codex-hook.sh" }] }]
  }
}
```

## Keybindings

| Key | Action |
| --- | --- |
| `prefix` + `y` | Launch / attach Claude session for current directory |
| `prefix` + `Y` | Launch / attach Codex session for current directory |
| `prefix` + `u` | Open unified Agent session picker popup |

### Inside the Picker (`prefix` + `u`)

| Key | Action |
| --- | --- |
| `Enter` | Jump to selected agent session |
| `ctrl-x` | Kill the selected agent process |
| `ctrl-y` | Copy agent location (`session:window.pane`) to clipboard |
| `Esc` / `q` | Close picker |

## Configuration Options

All options have sensible defaults and support both new `@agent_*` / `@codex_*` naming and legacy `@claude_*` naming.

### Key Bindings

```tmux
set -g @claude_launch_key 'y'
set -g @codex_launch_key 'Y'
set -g @agent_list_key 'u'     # or @claude_list_key
```

### Commands & Arguments

```tmux
set -g @claude_command 'claude'
set -g @claude_args ''
set -g @codex_command 'codex'
set -g @codex_args ''
```

### Sorting & Cache

```tmux
# Sort mode: 'status' (default: waiting -> idle -> working) or 'recent' (ordered by last activity)
set -g @agent_sort 'recent'    # or @claude_sort

# Fast cache: 'on' (default) or 'off'
set -g @agent_picker_cache 'on'
```

### Popup Dimensions & FZF

```tmux
set -g @agent_popup_width '90%'
set -g @agent_popup_height '90%'
set -g @agent_fzf_options "\
  --prompt 'nav> ' \
  --bind 'j:down' \
  --bind 'k:up' \
  --bind 'q:abort' \
  --bind 'x:execute-silent(kill {3})+reload(sleep 0.3; \$AGENT_PICKER --list)' \
  --bind 'i:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'a:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'esc:rebind(j,k,q,i,a,x)+change-prompt(nav> )'"
```

### Bell Forwarding

```tmux
set -g @agent_forward_bell 'on' # or @claude_forward_bell
```

## License

MIT
