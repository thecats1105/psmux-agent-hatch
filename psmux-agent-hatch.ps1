# psmux-agent-hatch
#
# Run Claude Code, Codex and Antigravity CLI (agy) sessions in popups, one per
# project directory, and jump between every running agent from a single picker.
#
# psmux runs this file at config load (`run-shell '<path>/psmux-agent-hatch.ps1'`,
# or through PPM); it reads user options and installs the key bindings. Set the
# @options BEFORE the line that loads the plugin.

. "$PSScriptRoot/scripts/helpers.ps1"

$root = Get-PluginRoot

$claudeKey = Get-PsmuxOption '@claude_launch_key' 'y'
$codexKey = Get-PsmuxOption '@codex_launch_key' 'o'
$agyKey = Get-PsmuxOption '@agy_launch_key' 'Y'
$listKey = Get-FirstPsmuxOption '@agent_list_key' '@claude_list_key' 'u'

# Paths are forward-slashed so no backslash has to survive psmux's command parser.
function Get-ScriptCommand {
    param([string]$Script, [string]$ScriptArgs = '')
    "run-shell 'pwsh -NoProfile -File `"$root/scripts/$Script`" $ScriptArgs'"
}

Invoke-Psmux bind-key $claudeKey (Get-ScriptCommand 'launch.ps1' 'claude') | Out-Null
Invoke-Psmux bind-key $codexKey (Get-ScriptCommand 'launch.ps1' 'codex') | Out-Null
Invoke-Psmux bind-key $agyKey (Get-ScriptCommand 'launch.ps1' 'agy') | Out-Null
Invoke-Psmux bind-key $listKey (Get-ScriptCommand 'list.ps1') | Out-Null

# Tell the user when a dedicated session rings the bell.
if ((Get-FirstPsmuxOption '@agent_forward_bell' '@claude_forward_bell' 'on') -eq 'on') {
    Invoke-Psmux set-hook -g alert-bell "run-shell -b 'pwsh -NoProfile -File `"$root/scripts/bell.ps1`" `"#{session_name}`"'" | Out-Null
}
