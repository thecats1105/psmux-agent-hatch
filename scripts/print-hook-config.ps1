# Print the hook configuration for Codex or AGY (Antigravity CLI). Read-only: it
# never touches a config file; paste the output yourself.
#
#   print-hook-config.ps1 codex   the contents of ~/.codex/hooks.json
#   print-hook-config.ps1 agy     the object to merge into ~/.gemini/config/hooks.json
#
# The hooks themselves (codex-hook.sh, agy-hook.sh) are bash, run by Git Bash.

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('codex', 'agy')]
    [string]$Provider
)

. "$PSScriptRoot/git-bash.ps1"

$bash = Find-GitBash
if (-not $bash) {
    [Console]::Error.WriteLine('Git Bash not found: install Git for Windows, or set HATCH_BASH to its usr\bin\bash.exe')
    exit 1
}

# 8.3 short name, so a path with spaces needs no quoting.
function Get-ShortPath {
    param([string]$Path)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $item = if (Test-Path -LiteralPath $Path -PathType Container) { $fso.GetFolder($Path) } else { $fso.GetFile($Path) }
        $item.ShortPath
    }
    catch { $Path }
}

# The command is handed to cmd.exe or PowerShell, depending on the agent, and only a
# command with no quotes in it means the same to both. So avoid spaces with short names;
# if one remains, fall back to the quoted form, which only cmd.exe understands.
# Backslashes, not slashes: unquoted, cmd.exe reads the `/` of C:/Git/... as a switch.
function New-HookCommand {
    param([string]$Script, [string]$ScriptArgs = '')

    $b = (Resolve-Path -LiteralPath $bash).Path
    $s = Join-Path $PSScriptRoot $Script
    if ($b -match ' ') { $b = Get-ShortPath $b }
    if ($s -match ' ') { $s = Get-ShortPath $s }
    if ($b -match ' ' -or $s -match ' ') {
        [Console]::Error.WriteLine("warning: a path contains a space and has no 8.3 short name; the quoted command works from cmd.exe only")
        $line = "`"$b`" `"$s`""
    }
    else { $line = "$b $s" }
    if ($ScriptArgs) { $line += " $ScriptArgs" }
    $line
}

if ($Provider -eq 'codex') {
    $command = New-HookCommand 'codex-hook.sh'
    $hooks = [ordered]@{}
    foreach ($ev in 'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop') {
        $hooks[$ev] = @(@{ hooks = @(@{ type = 'command'; command = $command }) })
    }
    [ordered]@{ hooks = $hooks } | ConvertTo-Json -Depth 8
}
else {
    $entry = { param($status) @{ type = 'command'; command = (New-HookCommand 'agy-hook.sh' $status) } }
    [ordered]@{
        'psmux-agent-hatch' = [ordered]@{
            enabled          = $true
            SessionStart     = @(& $entry 'idle')
            UserPromptSubmit = @(& $entry 'working')
            PreInvocation    = @(& $entry 'working')
            PreToolUse       = @(@{ matcher = 'ask_question'; hooks = @(& $entry 'waiting') })
            PostToolUse      = @(@{ matcher = '.*'; hooks = @(& $entry 'working') })
            Stop             = @(& $entry 'idle')
        }
    } | ConvertTo-Json -Depth 8
}
