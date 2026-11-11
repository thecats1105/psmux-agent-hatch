# Open the unified agent picker in a popup.

. "$PSScriptRoot/helpers.ps1"

$size = Get-PopupSize
$root = Get-PluginRoot
$context = Get-PsmuxContext

function Open-Picker {
    param([string]$HostClient)
    $cmd = "pwsh -NoProfile -File `"$root/scripts/picker.ps1`""
    # No -T/-b: they make psmux 3.4.0 ignore the popup command (see launch.ps1).
    $argv = @('display-popup', '-E', '-w', $size.Width, '-h', $size.Height)
    if ($HostClient) { $argv += @('-c', $HostClient) }
    Invoke-Psmux @argv $cmd | Out-Null
}

if ($context -and (Get-SessionProvider $context.Session)) {
    # Pressed from inside a session popup: close it, then reopen the picker on
    # the outer client. Detaching by session is safe because a popup's nested
    # attach is the only client on that session.
    Invoke-Psmux detach-client -s $context.Session | Out-Null
    Start-Sleep -Milliseconds 150
    Open-Picker (Get-AgentParent)
    exit 0
}

# Normal case: this client is the host.
if ($context) { Set-AgentParent $context.Client }
Open-Picker $(if ($context) { $context.Client } else { '' })
