# Start-menu launcher for the tray app.
# Creates (or refreshes) TerminalOrganizer.lnk in the user's Start Menu\Programs folder, pointing
# at this repo's bin\TerminalOrganizer.App.exe, then starts the app when it is not already running.
# -Startup : also writes the same shortcut to the user's Startup folder (the path the first-run
#            "Start with Windows" checkbox uses), so the app starts at logon.
# -NoStart : create the shortcut(s) only; do not start the app.
# Undo     : delete TerminalOrganizer.lnk from the folder(s) printed below.
param(
    [switch]$Startup,
    [switch]$NoStart
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

if (-not (Test-Path $appExe)) {
    Write-Output ('FAIL: app missing: ' + $appExe + ' (git pull --ff-only, or run build.ps1)')
    exit 1
}

function Write-Shortcut([string]$Folder) {
    $path = Join-Path $Folder 'TerminalOrganizer.lnk'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $shortcut.TargetPath = $appExe
    $shortcut.WorkingDirectory = Split-Path -Parent $appExe
    $shortcut.IconLocation = $appExe + ',0'
    $shortcut.Description = 'TerminalOrganizer tray app'
    $shortcut.Save()
    Write-Output ('shortcut: ' + $path + ' -> ' + $appExe)
}

Write-Shortcut ([Environment]::GetFolderPath('Programs'))
if ($Startup) {
    Write-Shortcut ([Environment]::GetFolderPath('Startup'))
}

if (-not $NoStart) {
    if (Get-Process -Name 'TerminalOrganizer.App' -ErrorAction SilentlyContinue) {
        Write-Output 'app: already running'
    }
    else {
        Start-Process -FilePath $appExe
        Write-Output 'app: started'
    }
}
exit 0
