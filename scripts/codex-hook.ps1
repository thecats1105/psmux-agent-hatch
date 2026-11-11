# Codex lifecycle-hook dispatcher for psmux-agent-hatch.
#
# Codex has no `claude agents --json` analogue, so status is reconstructed from
# its lifecycle hooks: wire this one script into all six events in
# ~/.codex/hooks.json (see -PrintConfig). Each firing rewrites that session's
# state file with the status the event implies; agents.ps1 reads those files.
#
#   SessionStart / Stop                         -> idle
#   UserPromptSubmit / PreToolUse / PostToolUse -> busy
#   PermissionRequest                           -> waiting
#
# A no-op decision: always exits 0 with no stdout, so it can never block, deny or
# alter a Codex tool call — including on a malformed payload or an unwritable
# state dir.

param([switch]$PrintConfig)

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot/helpers.ps1"

if ($PrintConfig) {
    $self = (Join-Path $PSScriptRoot 'codex-hook.ps1') -replace '\\', '/'
    $hooks = [ordered]@{}
    foreach ($ev in 'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop') {
        $hooks[$ev] = @(@{ hooks = @(@{ type = 'command'; command = "pwsh -NoProfile -File `"$self`"" }) })
    }
    [ordered]@{ hooks = $hooks } | ConvertTo-Json -Depth 8
    exit 0
}

try {
    # Codex outside psmux can never appear in the picker.
    if (-not $env:TMUX_PANE -or -not $env:PSMUX_SESSION) { exit 0 }

    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $id = [string]$payload.session_id
    # session_id becomes a filename; refuse anything that could escape the dir.
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { exit 0 }

    $status = switch ([string]$payload.hook_event_name) {
        { $_ -in 'SessionStart', 'Stop' } { 'idle' }
        { $_ -in 'UserPromptSubmit', 'PreToolUse', 'PostToolUse' } { 'busy' }
        'PermissionRequest' { 'waiting' }
        default { $null }
    }
    if (-not $status) { exit 0 }

    $dir = Get-ProviderStateDir 'codex'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $state = [ordered]@{
        status          = $status
        cwd             = [string]$payload.cwd
        transcript_path = [string]$payload.transcript_path
        session         = $env:PSMUX_SESSION
        pane            = $env:TMUX_PANE
        turn_id         = [string]$payload.turn_id
        updated_at      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    # Atomic write; the dot prefix keeps half-written files out of the *.json glob.
    $tmp = Join-Path $dir ".$id.$PID.tmp"
    $state | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination (Join-Path $dir "$id.json") -Force

    # Next picker open shows the latest status immediately.
    Clear-PickerCache
}
catch { }
exit 0
