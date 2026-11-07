# v0.2.10: deploys the RUNNING copy of TerminalOrganizer outside the git repo.
#
# Why: anything executing inside the repo (the tray app, its exe in bin\) races every
# git pull that touches bin\ — our own updater AND wip-snapshot's hourly pull. With
# the running exe in a per-machine run dir, no pull can ever fight a running exe.
#
# What it does (idempotent, safe to re-run):
#   1. copies bin\TerminalOrganizer.{App.exe,Core.dll,UiaProbe.exe} into the run dir
#      (default %LOCALAPPDATA%\Programs\TerminalOrganizer);
#   2. writes repo-path.txt there so the app's updater finds the distribution repo
#      (UpdateChecker.DeriveRepoRoot falls back to this marker);
#   3. repoints the Start-menu and Startup shortcuts at the run-dir exe (the same
#      TerminalOrganizer.lnk names install-start-menu-shortcut.ps1 created).
#
# The repo stays the distribution channel (home builds and commits bin\; receivers
# fast-forward); the run dir is a local cache only. Run once per machine; afterwards
# the tray's Update and restart keeps the run dir fresh by itself.
param(
    [string]$RunDir = (Join-Path $env:LOCALAPPDATA 'Programs\TerminalOrganizer'),
    [string]$RepoPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$NoShortcuts,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$bin = Join-Path $RepoPath 'bin'
$appExe = Join-Path $RunDir 'TerminalOrganizer.App.exe'

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
foreach ($name in @('TerminalOrganizer.App.exe', 'TerminalOrganizer.Core.dll', 'TerminalOrganizer.UiaProbe.exe')) {
    $src = Join-Path $bin $name
    if (-not (Test-Path -LiteralPath $src)) { throw "missing $src - build first" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $RunDir $name) -Force
}
[IO.File]::WriteAllText((Join-Path $RunDir 'repo-path.txt'), $RepoPath)
Write-Output ('run dir: ' + $RunDir)
Write-Output ('repo:    ' + $RepoPath)

function Write-Shortcut([string]$Folder) {
    $path = Join-Path $Folder 'TerminalOrganizer.lnk'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $shortcut.TargetPath = $appExe
    $shortcut.WorkingDirectory = $RunDir
    $shortcut.IconLocation = $appExe + ',0'
    $shortcut.Description = 'TerminalOrganizer tray app'
    $shortcut.Save()
    Write-Output ('shortcut: ' + $path + ' -> ' + $appExe)
}

if (-not $NoShortcuts) {
    Write-Shortcut ([Environment]::GetFolderPath('Programs'))
    Write-Shortcut ([Environment]::GetFolderPath('Startup'))
}

if (-not $NoStart) {
    if (Get-Process -Name 'TerminalOrganizer.App' -ErrorAction SilentlyContinue) {
        Write-Output 'app: already running (stop it, then re-run to start from the run dir)'
    }
    else {
        Start-Process -FilePath $appExe -WorkingDirectory $RunDir
        Write-Output 'app: started from the run dir'
    }
}
exit 0
