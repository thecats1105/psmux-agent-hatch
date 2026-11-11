# psmux-agent-hatch

A [psmux](https://github.com/psmux/psmux) plugin that runs **Claude Code**, **Codex**, and **Antigravity CLI (agy)** sessions in popups for each project directory — a native Windows / PowerShell 7 port of [`thecats1105/tmux-agent-hatch`](https://github.com/thecats1105/tmux-agent-hatch), itself forked from [`craftzdog/tmux-claude-hatch`](https://github.com/craftzdog/tmux-claude-hatch).

Open the hatch, hand an AI agent the work, close it and get back to your editor. Each session lives in its own nested psmux session, so closing the hatch never interrupts it. When you want to check in, an `fzf` picker lists every running session across **Claude, Codex, and AGY**, shows what each one is doing, and jumps you straight to it.

## Features

- **Unified picker** (`prefix` + `u`) listing every running Claude, Codex, and AGY agent — several in one project, and any running loose in ordinary panes.
- **Provider tags & status indicators** — color-coded tags and live status (`working`, `waiting`, `idle`).
- **Live preview** of each agent's screen right in the picker.
- **Smart jump** — selecting an agent switches your client to the window it was launched from, then resumes it in a popup over it.
- **Independent launchers**: `prefix` + `y` Claude · `prefix` + `o` Codex · `prefix` + `Y` AGY.
- **Quick kill** (`ctrl-x`) and **copy location** (`ctrl-y`) from the picker.
- **Bell notification** — a bell in a dedicated session shows a message on the client that launched it.
- **Cached first paint** — the picker opens from a cache and refreshes in the background.

## Prerequisites

- Windows with **psmux** and **PowerShell 7** (`pwsh`)
- **[fzf](https://github.com/junegunn/fzf)** — picker UI
- **Claude Code**, **Codex CLI**, and/or **Antigravity CLI (`agy`)**, installed natively on Windows

`jq` is not needed: PowerShell parses the JSON itself.

## Installation

### Via PPM (psmux Plugin Manager)

```tmux
set -g @plugin 'thecats1105/psmux-agent-hatch'
```

Then press `prefix` + `I`.

### Manually

Clone the repo and load it from your psmux config. Set any `@options` **before** the `run-shell` line:

```tmux
set -g @claude_command 'claude'
run-shell 'C:/Users/you/ghq/github.com/thecats1105/psmux-agent-hatch/psmux-agent-hatch.ps1'
```

Use forward slashes in paths inside psmux config. From a config file `run-shell` takes the bare `.ps1` path.

## Codex Setup

Codex lifecycle events are tracked via hooks. Print the configuration and paste it into `~/.codex/hooks.json`:

```powershell
pwsh -NoProfile -File C:/path/to/psmux-agent-hatch/scripts/codex-hook.ps1 -PrintConfig
```

It wires `codex-hook.ps1` into `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest` and `Stop`.

## AGY Setup

Print the configuration and merge the generated `psmux-agent-hatch` object into `~/.gemini/config/hooks.json`:

```powershell
pwsh -NoProfile -File C:/path/to/psmux-agent-hatch/scripts/agy-hook.ps1 -PrintConfig
```

## Claude Companion Plugin (optional)

Claude reports its own status, so the picker works without hooks. The bundled [`psmux-claude-hatch`](plugins/psmux-claude-hatch/README.md) Claude Code plugin adds bell notifications and keeps the picker cache fresh:

```
/plugin marketplace add thecats1105/psmux-agent-hatch
/plugin install psmux-claude-hatch@psmux-claude-hatch
```

## Keybindings

| Key            | Action                                               |
| -------------- | ---------------------------------------------------- |
| `prefix` + `y` | Launch / attach Claude session for current directory |
| `prefix` + `o` | Launch / attach Codex session for current directory  |
| `prefix` + `Y` | Launch / attach AGY session for current directory    |
| `prefix` + `u` | Open unified agent picker popup                      |

### Inside the Picker

| Key      | Action                                                       |
| -------- | ------------------------------------------------------------ |
| `Enter`  | Jump to selected agent session                               |
| `ctrl-x` | Kill the selected agent process                              |
| `ctrl-y` | Copy agent location (`session:window.pane`) to the clipboard |
| `Esc`    | Close picker                                                 |

## Configuration Options

All options have sensible defaults and support both the `@agent_*` / `@codex_*` / `@agy_*` naming and the legacy `@claude_*` naming. Set them before the plugin loads.

```tmux
# Key bindings
set -g @claude_launch_key 'y'
set -g @codex_launch_key 'o'
set -g @agy_launch_key 'Y'
set -g @agent_list_key 'u'          # or @claude_list_key

# Commands & arguments
set -g @claude_command 'claude'
set -g @claude_args ''
set -g @codex_command 'codex'
set -g @codex_args ''
set -g @agy_command 'agy'
set -g @agy_args ''

# Session name prefixes (dedicated sessions are <prefix><hash of directory>)
set -g @claude_session_prefix 'claude-'
set -g @codex_session_prefix 'codex-'
set -g @agy_session_prefix 'agy-'

# Sort: 'status' (waiting -> idle -> working) or 'recent' (last activity)
set -g @agent_sort 'recent'         # or @claude_sort

# Picker cache: 'on' (default) or 'off'
set -g @agent_picker_cache 'on'

# Popup size — percentages are resolved to absolute cells against the client
set -g @agent_popup_width '90%'
set -g @agent_popup_height '90%'

# Extra fzf options (quoted like a command line)
set -g @agent_fzf_options "--prompt 'nav> ' --bind 'j:down' --bind 'k:up'"

# Bell notification: 'on' (default) or 'off'
set -g @agent_forward_bell 'on'
```

`@*_command` may be a bare name (`claude`), a path, or a wrapper with arguments (`ocx claude`). A bare name is resolved to its full path so it still works where the pane's PATH is minimal.

## How it differs from the tmux version

| tmux-agent-hatch                                        | psmux-agent-hatch                                                                                                              |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| bash, `jq`, `awk`, `ps`                                 | PowerShell 7, `fzf`                                                                                                            |
| agent → pane via the pane's tty                         | agent → pane by walking the process tree up to `#{pane_pid}` (psmux's `#{pane_tty}` is synthetic)                              |
| Codex/AGY hooks key on `$TMUX_PANE`                     | hooks key on `$PSMUX_SESSION` + `$TMUX_PANE` — pane ids repeat across psmux sessions, so every target is `session:window.pane` |
| state in `$TMPDIR` files and tmux options               | `%LOCALAPPDATA%\psmux-agent-hatch` (hook state, origin window, picker cache)                                                   |
| bell forwarded by writing `\a` to the origin pane's tty | status-line message on the launching client (psmux can't ring another pane)                                                    |
| `tmux attach` inside a popup                            | `attach.ps1` clears `PSMUX_SESSION` first — psmux refuses to nest attaches otherwise                                           |

## Notes

- Hook scripts always exit `0` and never print (AGY tool-call hooks answer `{"decision": "allow"}`), so they can never block an agent.
- Hook state lives under `%LOCALAPPDATA%\psmux-agent-hatch\sessions\<provider>`; stale entries (older than the psmux server, or whose pane is gone) are swept each time the picker lists agents.
- Popups have no title or border: on psmux 3.4.0 `display-popup -T` / `-b` make psmux silently ignore the popup's command, so they are not used.
- Failures in popups and bindings are invisible, so launch/attach attempts are logged to `%LOCALAPPDATA%\psmux-agent-hatch\hatch.log`. If an attach fails the popup stays open with the error until you press Enter.
- Opening a popup for a session that already has one open is refused ("popup window already open"); otherwise a second press would nest another attach inside the first.
- `ctrl-x` kills the agent process itself: a dedicated session dies with its last process, while a loose pane keeps the shell that hosted it.

## License

MIT
