# fzf preview for one picker row: the pane's screen, minus trailing blank lines
# (which would leave fzf's `follow` scrolled onto padding).

param([string]$Target)

. "$PSScriptRoot/helpers.ps1"

if (-not $Target) { exit 0 }

$esc = [char]27
$lines = @(Invoke-Psmux capture-pane -e -p -t $Target)
$last = $lines.Count - 1
# A line holding only escape codes is still blank.
while ($last -ge 0 -and (($lines[$last] -replace "$esc\[[0-9;]*m", '').Trim() -eq '')) { $last-- }
if ($last -ge 0) { $lines[0..$last] }
