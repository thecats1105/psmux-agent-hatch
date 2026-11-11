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
# Windows has no tty to join on, so identity comes from the process tree:
#   * Claude self-reports (~/.claude/sessions/*.json) with its own pid; we walk the
#     parent chain up from that pid until it reaches a pane's #{pane_pid}.
#   * Codex and AGY report through lifecycle hooks (codex-hook.ps1 / agy-hook.ps1),
#     which record the session name and %pane id they ran in.

. "$PSScriptRoot/helpers.ps1"
$ErrorActionPreference = 'SilentlyContinue'

# The status dot is non-ASCII; without this a cp949/cp1252 console mangles it on its way to fzf.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$esc = [char]27
$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$home_ = $HOME

# --- live panes ---------------------------------------------------------------
$paneByPid = @{}      # pane_pid -> pane
$paneByKey = @{}      # "session|%id" -> pane
foreach ($line in (Invoke-Psmux list-panes -a -F '#{pane_pid}|#{session_name}|#{window_index}|#{pane_index}|#{pane_id}|#{pane_current_path}')) {
    $f = "$line" -split '\|', 6
    if ($f.Count -lt 6) { continue }
    $pane = [pscustomobject]@{
        PanePid = [int]$f[0]
        Session = $f[1]
        Target  = "$($f[1]):$($f[2]).$($f[3])"
        PaneId  = $f[4]
        Path    = $f[5]
    }
    if ($pane.PanePid -gt 0) { $paneByPid[$pane.PanePid] = $pane }
    $paneByKey["$($f[1])|$($f[4])"] = $pane
}
if ($paneByPid.Count -eq 0 -and $paneByKey.Count -eq 0) { exit 0 }

$providers = @{}
foreach ($p in Get-AllAgentProviders) { $providers[$p.Name] = $p }

function Find-Pane {
    param([int]$ProcessId)
    $current = $ProcessId
    for ($depth = 0; $depth -lt 10; $depth++) {
        if ($paneByPid.ContainsKey($current)) { return $paneByPid[$current] }
        $proc = Get-Process -Id $current
        if (-not $proc) { return $null }
        $parent = $null
        try { $parent = $proc.Parent } catch { }
        if (-not $parent) { return $null }
        $current = $parent.Id
    }
    $null
}

$recs = [System.Collections.Generic.List[object]]::new()

# --- Claude -------------------------------------------------------------------
function Get-ClaudeTranscriptMtime {
    param([string]$SessionId)
    if (-not $SessionId) { return 0 }
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    foreach ($d in (Get-ChildItem -LiteralPath (Join-Path $base 'projects') -Directory)) {
        $f = Join-Path $d.FullName "$SessionId.jsonl"
        if (Test-Path -LiteralPath $f) {
            return [DateTimeOffset]::new((Get-Item -LiteralPath $f).LastWriteTimeUtc).ToUnixTimeSeconds()
        }
    }
    0
}

$claudeAgents = [System.Collections.Generic.List[object]]::new()
$claudeBase = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
foreach ($file in (Get-ChildItem -Path (Join-Path $claudeBase 'sessions') -Filter *.json -File)) {
    try { $s = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($s.kind -ne 'interactive' -or -not $s.pid) { continue }
    $t = if ($s.statusUpdatedAt) { $s.statusUpdatedAt } else { $s.updatedAt }
    $seen = if ($t) { [long][math]::Floor($t / 1000) } else { 0 }
    $claudeAgents.Add([pscustomobject]@{ Pid = [int]$s.pid; Status = $s.status; Sid = $s.sessionId; Cwd = $s.cwd; Seen = $seen })
}
if ($claudeAgents.Count -eq 0) {
    # Session files unreadable or absent: ask the CLI instead.
    $cmd = (Split-CommandLine (Get-PsmuxOption '@claude_command' 'claude'))[0]
    if ($cmd -and (Get-Command $cmd -CommandType Application)) {
        try {
            $json = & $cmd agents --json 2>$null | Out-String
            foreach ($a in @($json | ConvertFrom-Json | Where-Object { $_.kind -eq 'interactive' })) {
                $claudeAgents.Add([pscustomobject]@{ Pid = [int]$a.pid; Status = $a.status; Sid = $a.sessionId; Cwd = $a.cwd; Seen = (Get-ClaudeTranscriptMtime $a.sessionId) })
            }
        }
        catch { }
    }
}
foreach ($a in $claudeAgents) {
    $pane = Find-Pane -ProcessId $a.Pid
    if (-not $pane) { continue }
    $recs.Add([pscustomobject]@{ Provider = 'claude'; Pane = $pane; Pid = $a.Pid; Status = $a.Status; Cwd = $a.Cwd; Seen = $a.Seen })
}

# --- Codex / AGY (hook state files) -------------------------------------------
$serverStart = 0
[long]::TryParse(("$(Invoke-Psmux display-message -p '#{start_time}' | Select-Object -First 1)"), [ref]$serverStart) | Out-Null

foreach ($name in 'codex', 'agy') {
    $dir = Get-ProviderStateDir $name
    $prefix = $providers[$name].Prefix
    $claims = [System.Collections.Generic.List[object]]::new()

    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter *.json -File)) {
        try { $c = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { Remove-Item -LiteralPath $file.FullName -Force; continue }
        $updated = 0
        [long]::TryParse("$($c.updated_at)", [ref]$updated) | Out-Null
        # Claims older than the server belong to a previous run; claims whose pane
        # is gone belong to a dead agent.
        if ($serverStart -gt 0 -and $updated -lt $serverStart) { Remove-Item -LiteralPath $file.FullName -Force; continue }
        $key = "$($c.session)|$($c.pane)"
        if (-not $c.session -or -not $c.pane -or -not $paneByKey.ContainsKey($key)) { Remove-Item -LiteralPath $file.FullName -Force; continue }
        $claims.Add([pscustomobject]@{ Key = $key; Updated = $updated; Status = $c.status; Cwd = $c.cwd; File = $file.FullName })
    }

    # One agent per pane: newest claim wins, older ones are swept.
    $claimed = @{}
    foreach ($c in ($claims | Sort-Object Updated -Descending)) {
        if ($claimed.ContainsKey($c.Key)) { Remove-Item -LiteralPath $c.File -Force; continue }
        $claimed[$c.Key] = $true
        $pane = $paneByKey[$c.Key]
        $recs.Add([pscustomobject]@{ Provider = $name; Pane = $pane; Pid = $pane.PanePid; Status = $c.Status; Cwd = $c.Cwd; Seen = $c.Updated })
    }

    # A freshly launched dedicated session has no hook claim yet.
    foreach ($pane in $paneByKey.Values) {
        if ($pane.Session.StartsWith($prefix) -and -not $claimed.ContainsKey("$($pane.Session)|$($pane.PaneId)")) {
            $recs.Add([pscustomobject]@{ Provider = $name; Pane = $pane; Pid = $pane.PanePid; Status = '-'; Cwd = $pane.Path; Seen = 0 })
        }
    }
}

# --- render -------------------------------------------------------------------
$tags = @{
    claude = "$esc[38;5;208mclaude$esc[0m"
    codex  = "$esc[36mcodex  $esc[0m"
    agy    = "$esc[35magy    $esc[0m"
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($r in $recs) {
    if ($r.Pid -le 0) { continue }
    switch ($r.Status) {
        'waiting' { $icon = "$esc[33m●$esc[0m waiting"; $rank = 0 }
        'idle' { $icon = "$esc[32m●$esc[0m idle   "; $rank = 1 }
        { $_ -in 'busy', 'working' } { $icon = "$esc[31m●$esc[0m working"; $rank = 3 }
        default { $icon = "$esc[90m●$esc[0m   ?    "; $rank = 2 }
    }

    if ($r.Seen -gt 0) {
        $secs = [math]::Max(0, $nowEpoch - $r.Seen)
        $mins = [int][math]::Floor($secs / 60)
        $age = if ($mins -lt 60) { "${mins}m" } elseif ($mins -lt 2880) { "$([int][math]::Floor($mins / 60))h" } else { "$([int][math]::Floor($mins / 1440))d" }
    }
    else { $secs = [long]1e12; $age = '-' }

    $path = [string]$r.Cwd
    if ($home_ -and $path.StartsWith($home_, [StringComparison]::OrdinalIgnoreCase)) { $path = '~' + $path.Substring($home_.Length) }

    $kind = if ($r.Pane.Session.StartsWith($providers[$r.Provider].Prefix)) { 'dedicated' } else { 'loose' }

    $rows.Add([pscustomobject]@{
            Rank = $rank
            Secs = $secs
            Line = @($rank, $r.Pane.Target, $r.Pid, $kind, $r.Provider, $r.Pane.Session, $tags[$r.Provider], $icon, ('{0,5}' -f $age), $r.Pane.Target, $path) -join "`t"
        })
}

$sortMode = Get-FirstPsmuxOption '@agent_sort' '@claude_sort' 'status'
$sorted = if ($sortMode -eq 'recent') { $rows | Sort-Object Secs } else { $rows | Sort-Object Rank, Secs }
$sorted | ForEach-Object { $_.Line }
exit 0
