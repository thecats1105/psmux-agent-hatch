# Launch (or re-attach to) a Claude / Codex / AGY session for the current pane's
# directory, shown in a popup.
#
#   launch.ps1 <claude|codex|agy>
#
# psmux does not hand a binding the pane's path, so we ask for the context ourselves.

param([ValidateSet('claude', 'codex', 'agy')][string]$Provider = 'claude')

. "$PSScriptRoot/helpers.ps1"

$context = Get-PsmuxContext
if (-not $context) { exit 0 }

# Launching from inside an agent session would recompute the very same session
# and overwrite its recorded origin with itself.
if (Get-SessionProvider $context.Session) {
    Invoke-Psmux display-message 'psmux-agent-hatch: popup window already open' | Out-Null
    exit 0
}

$p = Get-AgentProvider $Provider
$session = $p.Prefix + (Get-SessionHash $context.Path)

# A popup for this session is already open. Opening another would nest a second
# attach inside the first, and every further press nests one more.
if (Test-PsmuxSessionAttached $session) {
    Write-HatchLog "launch: $session already attached, not opening another popup"
    Invoke-Psmux display-message 'psmux-agent-hatch: popup window already open' | Out-Null
    exit 0
}

if (-not (Test-PsmuxSessionExists $session)) {
    if (-not (Test-Path -LiteralPath $context.Path -PathType Container)) {
        Invoke-Psmux display-message "psmux-agent-hatch: $($context.Path) no longer exists" | Out-Null
        exit 0
    }
    $cmd = Resolve-AgentCommandLine -Command $p.Command -ExtraArgs $p.Args
    Write-HatchLog "launch: new-session $session in $($context.Path): $cmd"
    Invoke-Psmux new-session -d -s $session -c $context.Path $cmd | Out-Null
    if (-not (Test-PsmuxSessionExists $session)) {
        Write-HatchLog "launch: session $session was not created"
        Invoke-Psmux display-message "psmux-agent-hatch: failed to start $($p.Name) (see hatch.log)" | Out-Null
        exit 0
    }
}

# Record which window launched it, so the picker can jump back here later.
Set-AgentOrigin -Session $session -Context $context
Set-AgentParent $context.Client

$size = Get-PopupSize
$root = Get-PluginRoot
Write-HatchLog "launch: popup $($size.Width)x$($size.Height) attach $session (client=$($context.Client))"
# No -T/-b: on psmux 3.4.0 a title or border option makes display-popup silently
# ignore its command (the popup opens and closes without running anything).
$popupArgs = @('display-popup', '-E', '-w', $size.Width, '-h', $size.Height)
if ($context.Client) { $popupArgs += @('-c', $context.Client) }   # the client that pressed the key
# Target the LAUNCHING session explicitly. After `new-session` the psmux CLI treats the
# new (clientless) session as current, so an untargeted display-popup is created on
# it and never shows on the user's screen.
if ($context.Session) { $popupArgs += @('-t', $context.Session) }
Invoke-Psmux @popupArgs `
    "pwsh -NoProfile -File `"$root/scripts/attach.ps1`" `"$session`"" | Out-Null
