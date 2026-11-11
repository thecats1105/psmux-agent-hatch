# Attach to a session from inside a psmux popup.
#
# psmux exports PSMUX_SESSION / PSMUX_TARGET_SESSION into a popup, and
# attach-session refuses to nest when it sees them. Clear them first, and always
# attach through this wrapper rather than calling attach-session from a popup.
#
# A popup closes the instant its command exits, taking any error with it. So the
# attempt is logged (hatch.log) and, if attach fails or returns immediately, the
# error is left on screen until a key is pressed.

param([Parameter(Mandatory = $true)][string]$Session)

. "$PSScriptRoot/helpers.ps1"

Write-HatchLog "attach: session=$Session PSMUX_SESSION=$env:PSMUX_SESSION TARGET=$env:PSMUX_TARGET_SESSION POPUP=$env:PSMUX_POPUP TMUX=$env:TMUX exe=$(Get-PsmuxExe)"

Remove-Item env:PSMUX_SESSION -ErrorAction SilentlyContinue
Remove-Item env:PSMUX_TARGET_SESSION -ErrorAction SilentlyContinue

# Only stderr is redirected: stdout must stay on the console for the attach itself.
$errFile = Join-Path (Get-DataDir) "attach.$PID.err"
$started = Get-Date
$failure = $null
try {
    & (Get-PsmuxExe) attach-session -t $Session 2>$errFile
    $code = $LASTEXITCODE
}
catch {
    $code = -1
    $failure = $_.Exception.Message
}
$elapsed = ((Get-Date) - $started).TotalSeconds
$stderr = if (Test-Path -LiteralPath $errFile) { (Get-Content -LiteralPath $errFile -Raw) } else { '' }
Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue

Write-HatchLog ("attach: exit=$code after {0:N1}s stderr=[{1}] exception=[{2}]" -f $elapsed, "$stderr".Trim(), $failure)

if ($code -ne 0 -or $elapsed -lt 1.5) {
    Write-Host ''
    Write-Host "psmux-agent-hatch: attach to '$Session' failed (exit $code)" -ForegroundColor Red
    if ($stderr) { Write-Host $stderr }
    if ($failure) { Write-Host $failure }
    Write-Host "Details: $(Join-Path (Get-DataDir) 'hatch.log')"
    Write-Host 'Press Enter to close...'
    [void][Console]::ReadLine()
}
