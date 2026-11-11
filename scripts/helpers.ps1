# Shared helpers for psmux-agent-hatch. Dot-sourced by every other script.
#
# Nothing in here may throw: these run from key bindings, hooks and popups,
# where an unhandled error is invisible to the user.

$script:PsmuxExe = $null

function Get-PsmuxExe {
    if (-not $script:PsmuxExe) {
        $cmd = Get-Command psmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:PsmuxExe = if ($cmd) { $cmd.Source } else { 'psmux' }
    }
    $script:PsmuxExe
}

# Run psmux, discarding stderr. Deliberately declares no parameters: with a
# param block psmux's own short flags (-a, -g, -p, ...) would be bound as
# PowerShell parameter names instead of being passed through.
function Invoke-Psmux {
    & (Get-PsmuxExe) @args 2>$null
}

# Plugin root as a forward-slashed path. Paths embedded in psmux command
# strings use '/' so no backslash ever has to survive psmux's command parser.
function Get-PluginRoot {
    (Split-Path -Parent $PSScriptRoot) -replace '\\', '/'
}

# Get-PsmuxOption <@name> [default]
# Global user-option lookup; empty/unset falls back to the default.
function Get-PsmuxOption {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )
    $value = (Invoke-Psmux show-options -gqv $Name | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { "$value".Trim() }
}

# Get-FirstPsmuxOption <@new> <@legacy> [default] — new naming, then legacy.
function Get-FirstPsmuxOption {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Legacy,
        [string]$Default = ''
    )
    $value = Get-PsmuxOption $Name
    if ($value) { return $value }
    Get-PsmuxOption $Legacy $Default
}

# --- providers ----------------------------------------------------------------

# One record per supported agent: name, session prefix, command, extra args.
function Get-AgentProvider {
    param([Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'agy')][string]$Name)

    $title = @{ claude = ' Claude '; codex = ' Codex '; agy = ' AGY ' }[$Name]
    [pscustomobject]@{
        Name    = $Name
        Title   = $title
        Prefix  = Get-PsmuxOption "@${Name}_session_prefix" "$Name-"
        Command = Get-PsmuxOption "@${Name}_command" $Name
        Args    = Get-PsmuxOption "@${Name}_args" ''
    }
}

function Get-AllAgentProviders {
    'claude', 'codex', 'agy' | ForEach-Object { Get-AgentProvider $_ }
}

# The provider whose dedicated-session prefix this session name carries, or $null.
function Get-SessionProvider {
    param([string]$Session)
    if ([string]::IsNullOrEmpty($Session)) { return $null }
    foreach ($p in Get-AllAgentProviders) {
        if ($Session.StartsWith($p.Prefix)) { return $p }
    }
    $null
}

# Quote for a single-quoted PowerShell string.
function ConvertTo-PsLiteral {
    param([string]$Text)
    "'" + ($Text -replace "'", "''") + "'"
}

# Turn "<command> <args>" into a line the pane's pwsh can run. The pane gets no
# interactive PATH tweaks, so an executable we can resolve here is pinned to its
# full path; anything else (aliases, wrappers) is passed through untouched.
function Resolve-AgentCommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$ExtraArgs = ''
    )

    $tokens = @(Split-CommandLine $Command)
    if ($tokens.Count -eq 0) { return $Command }
    $first = $tokens[0]
    $rest = @($tokens | Select-Object -Skip 1)

    $line = $Command
    $resolved = Get-Command $first -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolved) {
        foreach ($c in @(
                (Join-Path $HOME ".local/bin/$first.exe")
                (Join-Path $HOME ".local/bin/$first.cmd")
                (Join-Path $env:APPDATA "npm/$first.cmd")
            )) {
            if ($c -and (Test-Path -LiteralPath $c)) { $resolved = [pscustomobject]@{ Source = $c }; break }
        }
    }
    if ($resolved) {
        $path = $resolved.Source -replace '\\', '/'
        $line = '& ' + (ConvertTo-PsLiteral $path)
        foreach ($t in $rest) { $line += ' ' + (ConvertTo-PsLiteral $t) }
    }
    if ($ExtraArgs) { $line += " $ExtraArgs" }
    $line
}

# Split a user-supplied option string into argv, honouring '...' and "...".
function Split-CommandLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return @() }
    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $quote = $null
    $has = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($quote) {
            if ($ch -eq $quote) { $quote = $null } else { [void]$current.Append($ch) }
        }
        elseif ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; $has = $true }
        elseif ($ch -match '\s') {
            if ($has -or $current.Length -gt 0) { $tokens.Add($current.ToString()); [void]$current.Clear(); $has = $false }
        }
        else { [void]$current.Append($ch) }
    }
    if ($has -or $current.Length -gt 0) { $tokens.Add($current.ToString()) }
    $tokens.ToArray()
}

# --- misc ---------------------------------------------------------------------

# Short, stable 8-char hash used to derive a session name from a path. Hashes
# "<path>\n" so it matches the Unix `printf '%s\n' | md5sum` scheme.
function Get-SessionHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Path`n")
        (($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
    }
    finally { $md5.Dispose() }
}

# '90%' -> absolute cells against the client, so a popup attaching a session
# never resizes that session. Anything that is not a percentage passes through.
function Resolve-PopupSize {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('width', 'height')][string]$Dimension
    )
    if ($Value -notmatch '^\s*(\d+)\s*%\s*$') { return $Value }
    $percent = [int]$Matches[1]
    $fmt = if ($Dimension -eq 'width') { '#{client_width}' } else { '#{client_height}' }
    $size = Invoke-Psmux display-message -p $fmt | Select-Object -First 1
    if ($size -notmatch '^\d+$' -or [int]$size -le 0) { return $Value }
    $cells = [int]([int]$size * $percent / 100)
    if ($cells -lt 10) { $cells = 10 }
    "$cells"
}

function Get-PopupSize {
    $w = Get-FirstPsmuxOption '@agent_popup_width' '@claude_popup_width' '90%'
    $h = Get-FirstPsmuxOption '@agent_popup_height' '@claude_popup_height' '90%'
    @{ Width = (Resolve-PopupSize $w 'width'); Height = (Resolve-PopupSize $h 'height') }
}

# The pane/window/client the key was pressed in.
function Get-PsmuxContext {
    $fmt = '#{pane_current_path}|#{session_name}|#{window_id}|#{window_index}|#{pane_index}|#{client_name}'
    $line = Invoke-Psmux display-message -p $fmt | Select-Object -First 1
    if (-not $line) { return $null }
    $f = "$line" -split '\|'
    if ($f.Count -lt 6) { return $null }
    [pscustomobject]@{
        Path        = $f[0]
        Session     = $f[1]
        WindowId    = $f[2]
        WindowIndex = $f[3]
        PaneIndex   = $f[4]
        Client      = $f[5]
    }
}

function Test-PsmuxSessionExists {
    param([Parameter(Mandatory = $true)][string]$Session)
    Invoke-Psmux has-session -t $Session | Out-Null
    $LASTEXITCODE -eq 0
}

# True when a client is currently attached to the session. An open agent popup is
# exactly that (its attach-session is a real client), so this is how we tell the
# popup is already up — the key press that asks for a second one may arrive with
# the OUTER client's context, where checking the session name proves nothing.
function Test-PsmuxSessionAttached {
    param([Parameter(Mandatory = $true)][string]$Session)
    foreach ($line in (Invoke-Psmux list-sessions)) {
        if ("$line" -match '^([^:]+):' -and $Matches[1] -eq $Session) { return [bool]("$line" -match '\(attached\)') }
    }
    $false
}

function Get-PsmuxClientNames {
    foreach ($line in (Invoke-Psmux list-clients)) {
        $f = "$line" -split ': '
        if ($f.Count -ge 2 -and $f[0]) { $f[0] }
    }
}

# --- persistent state ---------------------------------------------------------

function Get-DataDir {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local' }
    Join-Path $base 'psmux-agent-hatch'
}

# Append a line to %LOCALAPPDATA%\psmux-agent-hatch\hatch.log. Popups and
# bindings run where errors are invisible, so this is how failures get found.
function Write-HatchLog {
    param([string]$Message)
    try {
        $dir = Get-DataDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir 'hatch.log'
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 200KB) { Remove-Item -LiteralPath $file -Force }
        Add-Content -LiteralPath $file -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message) -Encoding UTF8
    }
    catch { }
}

function Get-CachePath { Join-Path (Get-DataDir) 'picker.cache' }

function Clear-PickerCache {
    Remove-Item -LiteralPath (Get-CachePath) -Force -ErrorAction SilentlyContinue
}

# Hook state dir for codex / agy (one JSON file per session id).
function Get-ProviderStateDir {
    param([Parameter(Mandatory = $true)][string]$Provider)
    Join-Path (Join-Path (Get-DataDir) 'sessions') $Provider
}

# The launching window / client are kept in one JSON file: psmux options do not
# reliably carry a value from one session to another.
#   { "parent": "<client>", "origins": { "<session>": { "session", "window", "windowIndex" } } }
function Get-StatePath { Join-Path (Get-DataDir) 'state.json' }

function Get-State {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -is [hashtable]) { $obj } else { @{} }
    }
    catch { @{} }
}

# Temp file + move, so a concurrent reader never sees a half-written document.
function Set-State {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    $path = Get-StatePath
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$path.$PID.tmp"
        $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    }
    catch { }
}

function Set-AgentParent {
    param([string]$Client)
    if ([string]::IsNullOrWhiteSpace($Client)) { return }
    $state = Get-State
    $state['parent'] = $Client
    Set-State $state
}

# The client that last opened the launcher/picker, if it is still connected.
function Get-AgentParent {
    $client = (Get-State)['parent']
    if ([string]::IsNullOrWhiteSpace($client)) { return $null }
    if (@(Get-PsmuxClientNames) -contains $client) { $client } else { $null }
}

function Set-AgentOrigin {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)]$Context
    )
    $state = Get-State
    if ($state['origins'] -isnot [hashtable]) { $state['origins'] = @{} }
    $state['origins'][$Session] = @{
        session     = $Context.Session
        window      = $Context.WindowId
        windowIndex = $Context.WindowIndex
    }
    Set-State $state
}

function Get-AgentOrigin {
    param([Parameter(Mandatory = $true)][string]$Session)
    $origins = (Get-State)['origins']
    if ($origins -isnot [hashtable]) { return $null }
    $entry = $origins[$Session]
    if ($entry -isnot [hashtable]) { return $null }
    [pscustomobject]@{
        Session     = $entry['session']
        Window      = $entry['window']
        WindowIndex = $entry['windowIndex']
    }
}

# Copy text to the Windows clipboard (and a psmux buffer).
function Copy-ToClipboard {
    param([string]$Text)
    try { Set-Clipboard -Value $Text -ErrorAction Stop }
    catch { $Text | & clip.exe }
    Invoke-Psmux set-buffer -- $Text | Out-Null
}
