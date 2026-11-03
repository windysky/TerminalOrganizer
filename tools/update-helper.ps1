# SPEC-TRAY-020 detached update helper (M2; REQ-UPD-009/010/011, plan section J).
# Spawned by the tray app right before it exits: waits out the app process and the exe
# lock, runs the ONE state-changing git verb of this whole feature (the ff-only form
# below), then restarts the app — on success AND on every failure (D-4 restart-always;
# a failed run leaves the old app running and the reason in the log).
# @MX:WARN: [AUTO] detached update surface: it mutates the repo work tree through git and restarts the app.
# @MX:REASON: a wrong verb or a missing restart here is data loss or a machine left without its organizer.
#
# Safety lines (REQ-UPD-010): the single git invocation below is the only one; the
# helper deletes or modifies no file itself (the work tree changes only as that verb's
# own effect); every failure is logged with git's first stderr line and still restarts.
#
# PowerShell parses this file fully before executing it, so the pull may rewrite the
# file mid-run without affecting this running instance (D-2) — this is why the helper
# is a repo-local script, not a repo-local exe (D-1).

param(
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][int]$AppPid,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [int]$PidWaitSeconds = 60,
    [int]$LockWaitSeconds = 30,
    [int]$LockPollMs = 250
)

function Add-HelperLog([string]$Line) {
    # LogSink line format (LogSink.cs): 'yyyy-MM-dd HH:mm:ss' + one space + the line.
    # A write failure drops the line silently; logging must never take the helper down.
    try {
        $stamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::AppendAllText($LogPath, $stamp + ' ' + $Line + [Environment]::NewLine)
    }
    catch { }
}

function Get-HelperGitExe {
    # Absolute-path resolution first (the helper runs detached without an inherited
    # interactive context), PATH resolution second, well-known install roots third.
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $roots = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LocalAppData 'Programs\Git\cmd\git.exe'))
    foreach ($one in $roots) {
        if ($one -and (Test-Path -LiteralPath $one)) { return $one }
    }
    return $null
}

function Wait-HelperPidExit([int]$TargetPid, [int]$Seconds) {
    # True when the process is gone (an already-exited PID is the fast no-op path);
    # false when the bound expires. Never throws on a missing PID.
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        $live = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
        if ($null -eq $live) { return $true }
        if ([DateTime]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 250
    }
}

function Wait-HelperLock([string]$Target, [int]$Seconds, [int]$PollMs) {
    # The real precondition for the pull: exclusive write access to the exe file.
    # True once granted (the probe handle is released immediately); false at the bound.
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        try {
            $probe = [IO.File]::Open($Target, 'Open', 'ReadWrite', 'None')
            $probe.Close()
            return $true
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { return $false }
            Start-Sleep -Milliseconds $PollMs
        }
        catch {
            return $false
        }
    }
}

function Start-HelperRestart {
    Add-HelperLog 'update: helper restarting'
    try {
        $exeDir = Split-Path -Parent $ExePath
        Start-Process -FilePath $ExePath -WorkingDirectory $exeDir
    }
    catch { }
}

$skipPull = $false

try {
    # Step 1 (REQ-UPD-009): wait for the app process to exit, bounded. On timeout the
    # pull is skipped and the restart is still attempted — through the app's single-
    # instance gate that attempt is a silent no-op while the original app still lives.
    if (Wait-HelperPidExit $AppPid $PidWaitSeconds) {
        Add-HelperLog 'update: helper app-exit wait done'
    }
    else {
        Add-HelperLog ('update: helper app-exit wait timeout after ' + $PidWaitSeconds + 's')
        $skipPull = $true
    }

    # Step 2: wait for the exe lock to release, bounded. Same skip-and-restart rule.
    if (-not $skipPull) {
        if (Wait-HelperLock $ExePath $LockWaitSeconds $LockPollMs) {
            Add-HelperLog 'update: helper lock released'
        }
        else {
            Add-HelperLog ('update: helper lock wait timeout after ' + $LockWaitSeconds + 's')
            $skipPull = $true
        }
    }

    # Step 3 (REQ-UPD-010): the single git invocation of this helper. The old..new
    # short SHAs ride the verb's own "Updating a1b2c3d..e4f5a6b" output line, so no
    # second read-only git call is needed for the log shape.
    if (-not $skipPull) {
        $gitExe = Get-HelperGitExe
        if ($null -eq $gitExe) {
            Add-HelperLog 'update: helper pull failed: git.exe not resolvable'
        }
        else {
            $output = & $gitExe -C $RepoPath pull --ff-only origin main 2>&1
            if ($LASTEXITCODE -eq 0) {
                $text = @($output) -join "`n"
                $span = [regex]::Match($text, 'Updating ([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})')
                if ($span.Success) {
                    Add-HelperLog ('update: helper pull ok ' + $span.Groups[1].Value.Substring(0, 7) + '..' + $span.Groups[2].Value.Substring(0, 7))
                }
                else {
                    Add-HelperLog 'update: helper pull ok'
                }
            }
            else {
                # git's fetch progress ("From ...", "* branch main -> FETCH_HEAD") also
                # arrives on stderr, so the recorded reason is the first TRUE error line
                # (the "error:" / "fatal:" prefixes), not merely the first stderr line.
                $errLines = @($output |
                    Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                    ForEach-Object { $_.ToString().Trim() } |
                    Where-Object { $_.Length -gt 0 })
                $firstErr = @($errLines | Where-Object { $_ -match '^(error|fatal):' })
                if ($firstErr.Count -gt 0) {
                    Add-HelperLog ('update: helper pull failed: ' + $firstErr[0])
                }
                elseif ($errLines.Count -gt 0) {
                    Add-HelperLog ('update: helper pull failed: ' + $errLines[0])
                }
                else {
                    Add-HelperLog ('update: helper pull failed: exit ' + $LASTEXITCODE)
                }
            }
        }
    }
}
catch {
    Add-HelperLog ('update: helper pull failed: ' + $_.Exception.Message)
}

# Step 4 (D-4): restart regardless of the pull outcome. The restarted app's own
# startup check re-surfaces any behind state; its log carries the failure line above.
Start-HelperRestart
Add-HelperLog 'update: helper done'
exit 0
