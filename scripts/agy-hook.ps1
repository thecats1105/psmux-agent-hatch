# AGY (Antigravity CLI) lifecycle-hook dispatcher for psmux-agent-hatch.
#
# AGY passes hook context as JSON on stdin (conversationId, workspacePaths,
# transcriptPath) but no event name — the status is baked into the command line
# by the hooks.json wiring (see -PrintConfig):
#
#   agy-hook.ps1 idle      SessionStart / Stop
#   agy-hook.ps1 working   UserPromptSubmit / PreInvocation / PostToolUse
#   agy-hook.ps1 waiting   PreToolUse (ask_question)
#
# For tool-call payloads AGY expects a JSON decision on stdout; we always answer
# {"decision": "allow"} so we never block anything. Always exits 0.

param(
    [string]$Status = '',
    [switch]$PrintConfig
)

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot/helpers.ps1"

if ($PrintConfig) {
    $self = (Join-Path $PSScriptRoot 'agy-hook.ps1') -replace '\\', '/'
    $cmd = { param($s) @{ type = 'command'; command = "pwsh -NoProfile -File `"$self`" $s" } }
    [ordered]@{
        'psmux-agent-hatch' = [ordered]@{
            enabled          = $true
            SessionStart     = @(& $cmd 'idle')
            UserPromptSubmit = @(& $cmd 'working')
            PreInvocation    = @(& $cmd 'working')
            PreToolUse       = @(@{ matcher = 'ask_question'; hooks = @(& $cmd 'waiting') })
            PostToolUse      = @(@{ matcher = '.*'; hooks = @(& $cmd 'working') })
            Stop             = @(& $cmd 'idle')
        }
    } | ConvertTo-Json -Depth 8
    exit 0
}

try {
    if ($Status -notin 'working', 'waiting', 'idle', 'busy') { exit 0 }

    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json

    # PreToolUse hooks expect a decision on stdout, whether or not we track this run.
    if ($payload.PSObject.Properties.Name -contains 'toolCall') {
        [Console]::Out.Write("{`"decision`": `"allow`"}`n")
    }

    if (-not $env:TMUX_PANE -or -not $env:PSMUX_SESSION) { exit 0 }

    $id = [string]$payload.conversationId
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { exit 0 }

    $dir = Get-ProviderStateDir 'agy'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $state = [ordered]@{
        status          = $Status
        cwd             = [string]@($payload.workspacePaths)[0]
        transcript_path = [string]$payload.transcriptPath
        session         = $env:PSMUX_SESSION
        pane            = $env:TMUX_PANE
        conversation_id = $id
        updated_at      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $tmp = Join-Path $dir ".$id.$PID.tmp"
    $state | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination (Join-Path $dir "$id.json") -Force

    Clear-PickerCache
}
catch { }
exit 0
