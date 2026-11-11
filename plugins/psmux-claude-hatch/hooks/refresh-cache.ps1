# Refresh the picker's agent cache whenever this agent changes state.
#
#   refresh-cache.ps1 [delay-ms]   optional wait first, e.g. for the process to
#                                  exit on SessionEnd.
#
# The picker paints its first frame from the cache (unless @agent_picker_cache is
# off). Claude's hooks fire at exactly the moments status changes, so refreshing
# here keeps that first paint honest.
#
# Never fails and never prints; the refresh runs detached.

param([int]$Delay = 0)

# Outside psmux this would overwrite a good cache with an empty one.
if (-not $env:TMUX -and -not $env:PSMUX_SESSION) { exit 0 }

$candidates = @(
    if ($env:CLAUDE_PLUGIN_ROOT) { Join-Path $env:CLAUDE_PLUGIN_ROOT '../../scripts/picker.ps1' }
    Join-Path $HOME '.psmux/plugins/psmux-agent-hatch/scripts/picker.ps1'
)
$picker = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $picker) { exit 0 }

try {
    $picker = (Resolve-Path -LiteralPath $picker).Path
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @('-NoProfile', '-File', $picker, '-List', '-Delay', $Delay) | Out-Null
}
catch { }
exit 0
