# psmux-agent-hatch
#
# Run Claude Code, Codex and Antigravity CLI (agy) sessions in popups, one per
# project directory, and jump between every running agent from a single picker.
#
# psmux runs this file at config load (`run-shell '<path>/psmux-agent-hatch.ps1'`,
# or through PPM). It finds Git Bash and
# hands over to scripts/setup.sh, which does the real work. Everything after that
# runs in Git Bash, because starting pwsh for every key press and hook was the slow
# part. Set the @options BEFORE the line that loads the plugin.

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/scripts/git-bash.ps1"

$bash = Find-GitBash
if (-not $bash) {
    & psmux display-message 'psmux-agent-hatch: Git Bash not found (install Git for Windows, or set @agent_bash)' 2>$null
    exit 0
}

$env:HATCH_BASH = (Resolve-Path -LiteralPath $bash).Path -replace '\\', '/'
& $env:HATCH_BASH ("$PSScriptRoot/scripts/setup.sh" -replace '\\', '/')
exit 0
