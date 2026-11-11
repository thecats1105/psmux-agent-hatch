# psmux-agent-hatch
#
# Run Claude Code, Codex and Antigravity CLI (agy) sessions in popups, one per
# project directory, and jump between every running agent from a single picker.
#
# psmux runs this file at config load (`run-shell '<path>/psmux-agent-hatch.ps1'`,
# or through PPM). It is the only PowerShell in the plugin: it finds Git Bash and
# hands over to scripts/setup.sh, which does the real work. Everything after that
# runs in Git Bash, because starting pwsh for every key press and hook was the slow
# part. Set the @options BEFORE the line that loads the plugin.

$ErrorActionPreference = 'SilentlyContinue'

function Find-GitBash {
    $candidates = [System.Collections.Generic.List[string]]::new()

    # Explicit overrides: environment, then the psmux option.
    if ($env:HATCH_BASH) { $candidates.Add($env:HATCH_BASH) }
    $opt = (& psmux show-options -gqv '@agent_bash' 2>$null | Select-Object -First 1)
    if ($opt) { $candidates.Add("$opt".Trim()) }

    # Git for Windows records where it lives.
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $installPath = (Get-ItemProperty "$hive\SOFTWARE\GitForWindows").InstallPath
        if ($installPath) { $candidates.Add((Join-Path $installPath 'usr\bin\bash.exe')) }
    }

    # Wherever git.exe says its exec path is: <root>\mingw64\libexec\git-core.
    $git = Get-Command git -CommandType Application | Select-Object -First 1
    if ($git) {
        $execPath = (& $git.Source --exec-path 2>$null | Select-Object -First 1)
        if ($execPath -match '^(.*?)[\\/](mingw(32|64)[\\/])?libexec[\\/]git-core$') {
            $candidates.Add((Join-Path $Matches[1] 'usr\bin\bash.exe'))
        }
    }

    # Common install locations (scoop included).
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'), (Join-Path $HOME 'scoop\apps\git\current')) {
        if ($base) {
            $candidates.Add((Join-Path $base 'Git\usr\bin\bash.exe'))
            $candidates.Add((Join-Path $base 'usr\bin\bash.exe'))
        }
    }

    # Deliberately not Get-Command bash: on a machine with WSL that finds
    # C:\Windows\System32\bash.exe, the WSL launcher, not Git Bash.
    $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}

$bash = Find-GitBash
if (-not $bash) {
    & psmux display-message 'psmux-agent-hatch: Git Bash not found (install Git for Windows, or set @agent_bash)' 2>$null
    exit 0
}

$env:HATCH_BASH = (Resolve-Path -LiteralPath $bash).Path -replace '\\', '/'
& $env:HATCH_BASH ("$PSScriptRoot/scripts/setup.sh" -replace '\\', '/')
exit 0
