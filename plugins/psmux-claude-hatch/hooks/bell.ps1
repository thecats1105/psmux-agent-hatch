# Ring the terminal bell so psmux counts it as one.
#
# psmux fires its alert-bell hook (and forwards the bell) only for a real BEL
# written to a pane's console. A hook's stdout is captured by Claude and never
# reaches the pane, so write the BEL to the console device directly.
#
# Never fails and never prints: hook output lands in the transcript, and a bell
# that cannot be delivered must not fail the turn.

try {
    $fs = [System.IO.FileStream]::new('CONOUT$', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $fs.WriteByte(7) } finally { $fs.Dispose() }
}
catch { }
exit 0
