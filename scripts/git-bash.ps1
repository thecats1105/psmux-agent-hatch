# Find Git for Windows' bash.exe. Dot-sourced by psmux-agent-hatch.ps1 and
# print-hook-config.ps1 — the only PowerShell in the plugin.

function Find-GitBash {
    $candidates = [System.Collections.Generic.List[string]]::new()

    # Explicit overrides: environment, then the psmux option.
    if ($env:HATCH_BASH) { $candidates.Add($env:HATCH_BASH) }
    if (Get-Command psmux -CommandType Application -ErrorAction SilentlyContinue) {
        $opt = (& psmux show-options -gqv '@agent_bash' 2>$null | Select-Object -First 1)
        if ($opt) { $candidates.Add("$opt".Trim()) }
    }

    # Git for Windows records where it lives.
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $installPath = (Get-ItemProperty "$hive\SOFTWARE\GitForWindows" -ErrorAction SilentlyContinue).InstallPath
        if ($installPath) { $candidates.Add((Join-Path $installPath 'usr\bin\bash.exe')) }
    }

    # Wherever git.exe says its exec path is: <root>\mingw64\libexec\git-core.
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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
