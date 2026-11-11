# Kill the agent behind a picker row (fzf's ctrl-x).
#
#   kill.ps1 <pid> <provider>
#
# Claude rows carry the claude process itself. Codex / AGY rows carry the pane's
# shell: kill the shell's children (the agent), not the shell — a dedicated
# session then dies with its last process, and a loose pane keeps its shell.

param(
    [int]$ProcessId,
    [string]$Provider = 'claude'
)

if ($ProcessId -le 0) { exit 0 }

if ($Provider -eq 'claude') {
    & taskkill.exe /PID $ProcessId /T /F *>$null
    exit 0
}

$children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
foreach ($child in $children) {
    & taskkill.exe /PID $child.ProcessId /T /F *>$null
}
