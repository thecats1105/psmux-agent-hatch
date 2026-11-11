# Interactive picker for running Claude, Codex and AGY agents. Runs in a popup.
#
#   picker.ps1                fzf picker; on enter, jumps to the chosen agent.
#   picker.ps1 -List          print the rows and refresh the cache (used by fzf's
#                             async initial load, the ctrl-x reload, and the hooks).
#     -Delay <ms>             wait first, e.g. for a killed process to disappear.
#
# Rows come from agents.ps1. Two kinds of row jump differently:
#   dedicated  an agent in a `claude-*` / `codex-*` / `agy-*` session this plugin
#              launched — resumed in the popup, over the window it was launched from.
#   loose      an agent running in any other pane — focused in place.

param(
    [switch]$List,
    [int]$Delay = 0
)

. "$PSScriptRoot/helpers.ps1"

# agents.ps1 emits UTF-8; read it as such (and hand it to fzf as such).
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Get-PluginRoot
$cache = Get-CachePath

function Update-Rows {
    $rows = @(& pwsh -NoProfile -File "$root/scripts/agents.ps1")
    try {
        $dir = Split-Path -Parent $cache
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$cache.$PID.tmp"
        Set-Content -LiteralPath $tmp -Value $rows -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $cache -Force
    }
    catch { }
    $rows
}

if ($List) {
    if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }
    Update-Rows
    exit 0
}

if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Invoke-Psmux display-message 'psmux-agent-hatch: fzf is required for the picker' | Out-Null
    exit 0
}

$env:FZF_DEFAULT_OPTS = ''

# fzf runs --preview / execute-silent through cmd.exe, so each is a complete
# command line with its script path quoted.
$ps = "pwsh -NoProfile -File"
$previewCmd = "$ps `"$root/scripts/preview.ps1`" {2}"
$killCmd = "$ps `"$root/scripts/kill.ps1`" {3} {5}"
$copyCmd = "$ps `"$root/scripts/copy.ps1`" {10}"
$reloadCmd = "$ps `"$root/scripts/picker.ps1`" -List -Delay 300"

$fzfArgs = @(
    '--ansi'
    '--delimiter', '\t'
    '--with-nth', '7,8,9,10,11'
    '--reverse'
    '--cycle'
    '--header', 'Agents · enter: jump · ctrl-x: kill · ctrl-y: copy'
    '--preview', $previewCmd
    '--preview-window', 'up,70%,follow'
    '--bind', "ctrl-x:execute-silent($killCmd)+reload($reloadCmd)"
    '--bind', "ctrl-y:execute-silent($copyCmd)+abort"
    '--bind', 'change:first'
)

# Paint the first frame from the cache when it is fresh, then reload in the
# background; otherwise gather the rows up front.
$useCache = (Get-FirstPsmuxOption '@agent_picker_cache' '@claude_picker_cache' 'on') -eq 'on'
$rows = $null
if ($useCache -and (Test-Path -LiteralPath $cache) -and
    ((Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime).TotalMinutes -lt 60) {
    $rows = @(Get-Content -LiteralPath $cache -Encoding UTF8 | Where-Object { $_ })
    if ($rows.Count -gt 0) {
        $fzfArgs += @('--bind', "load:unbind(load)+reload-sync($reloadCmd)")
    }
}
if (-not $rows -or $rows.Count -eq 0) { $rows = @(Update-Rows) }

if ($rows.Count -eq 0) {
    Invoke-Psmux display-message 'psmux-agent-hatch: no agents running in psmux' | Out-Null
    exit 0
}

$fzfArgs += Split-CommandLine (Get-FirstPsmuxOption '@agent_fzf_options' '@claude_fzf_options' '')

$selection = $rows | & fzf @fzfArgs | Select-Object -First 1
if (-not $selection) { exit 0 }

$f = $selection -split "`t"
if ($f.Count -lt 6) { exit 0 }
$target = $f[1]
$kind = $f[3]
$session = $f[5]

$parent = Get-AgentParent

function Switch-Parent {
    param([string]$Session)
    if ($parent) { Invoke-Psmux switch-client -c $parent -t $Session | Out-Null }
    else { Invoke-Psmux switch-client -t $Session | Out-Null }
}

$windowTarget = $target -replace '\.\d+$', ''

if ($kind -eq 'loose') {
    # Focus the pane in place on the outer client; this popup closes when we exit.
    # Targets stay session-qualified: psmux reuses %n and @n across sessions.
    Switch-Parent $session
    Invoke-Psmux select-window -t $windowTarget | Out-Null
    Invoke-Psmux select-pane -t $target | Out-Null
    exit 0
}

# Never nest a second attach on a session whose popup is already open.
if (Test-PsmuxSessionAttached $session) {
    Write-HatchLog "picker: $session already attached, not attaching again"
    Invoke-Psmux display-message 'psmux-agent-hatch: popup window already open' | Out-Null
    exit 0
}

# Move the parent client to the window the session was launched from
# (best-effort): switch session first, then pick the window as a separate call.
$origin = Get-AgentOrigin $session
if ($origin -and $parent -and $origin.Session -and $origin.WindowIndex) {
    Invoke-Psmux switch-client -c $parent -t $origin.Session | Out-Null
    Invoke-Psmux select-window -t "$($origin.Session):$($origin.WindowIndex)" | Out-Null
}

Invoke-Psmux select-window -t $windowTarget | Out-Null
Invoke-Psmux select-pane -t $target | Out-Null

# Resume the agent in THIS popup over the top (see attach.ps1 for why the env is cleared).
Remove-Item env:PSMUX_SESSION -ErrorAction SilentlyContinue
Remove-Item env:PSMUX_TARGET_SESSION -ErrorAction SilentlyContinue
& (Get-PsmuxExe) attach-session -t $session
