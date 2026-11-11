# Copy a picker row's location (session:window.pane) to the clipboard (fzf's ctrl-y).

param([string]$Text)

. "$PSScriptRoot/helpers.ps1"

if ($Text) {
    Copy-ToClipboard $Text
    Invoke-Psmux display-message "psmux-agent-hatch: copied $Text" | Out-Null
}
