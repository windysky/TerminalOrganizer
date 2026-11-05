# SPEC-TRAY-020 M2 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-006/007/008/009-half and spec.md
# REQ-UPD-009/010/011 plus plan.md section J, never from the code under test.
# The fixture builds LOCAL repositories under the Pester scratch dir (bare origin +
# clone + pusher; no network). The helper is invoked through the same absolute
# powershell.exe path production uses (plan section B, the full-path discipline).
# The live end-to-end round is AC-012 evidence in progress.md section E.2, never here.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$script:HelperPs51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:HelperScript = Join-Path $repoRoot 'tools\update-helper.ps1'

# --- fixtures ---

# One local git fixture: bare origin, an app clone at commit A (tracking the stand-in
# bin\app.exe), and a pusher clone used to advance the origin to A+1. Identity rides
# per-invocation -c args so no global git config is touched (plan section B).
function New-UpdateFixture {
    $scratch = Join-Path $here ('scratch-updatehelper-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $origin = Join-Path $scratch 'origin.git'
    $clone = Join-Path $scratch 'clone'
    $pusher = Join-Path $scratch 'pusher'
    git -c init.defaultBranch=main init --bare $origin 2>&1 | Out-Null
    git clone $origin $clone 2>&1 | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $clone 'bin') | Out-Null
    [IO.File]::WriteAllText((Join-Path $clone 'bin\app.exe'), 'stand-in binary A')
    git -C $clone add bin/app.exe 2>&1 | Out-Null
    git -C $clone -c user.email=t@t -c user.name=t commit -m A 2>&1 | Out-Null
    git -C $clone push origin main 2>&1 | Out-Null
    git clone $origin $pusher 2>&1 | Out-Null

    # The restart stand-in exe: a cmd that appends one line to the marker file, so a
    # helper restart is measurable evidence (Start-Process on a .cmd runs it).
    $markerFile = Join-Path $scratch 'restart-marker.txt'
    $markerCmd = Join-Path $scratch 'restart-marker.cmd'
    [IO.File]::WriteAllText($markerCmd, "@echo restarted>>`"$markerFile`"`r`n")

    return @{ Scratch = $scratch; Origin = $origin; Clone = $clone; Pusher = $pusher
        Exe = $markerCmd; MarkerFile = $markerFile; Log = (Join-Path $scratch 'app.log') }
}

# Advances the fixture origin by one commit touching the tracked stand-in exe and,
# optionally, adding one extra tracked path (the untracked-collision row plants a
# local file there).
function Push-UpdateFixtureCommit($Fixture, [string]$ExtraPath) {
    [IO.File]::WriteAllText((Join-Path $Fixture.Pusher 'bin\app.exe'), 'stand-in binary B')
    git -C $Fixture.Pusher add bin/app.exe 2>&1 | Out-Null
    if ($ExtraPath) {
        $full = Join-Path $Fixture.Pusher $ExtraPath
        $dir = Split-Path -Parent $full
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        [IO.File]::WriteAllText($full, 'incoming tracked content')
        git -C $Fixture.Pusher add $ExtraPath 2>&1 | Out-Null
    }
    git -C $Fixture.Pusher -c user.email=t@t -c user.name=t commit -m B 2>&1 | Out-Null
    git -C $Fixture.Pusher push origin main 2>&1 | Out-Null
}

# Invokes the helper exactly the way the app will: absolute powershell.exe, -NoProfile
# -ExecutionPolicy Bypass -File, the four pinned parameters plus the optional bounds.
function Invoke-UpdateHelper($Fixture, [int]$AppPid,
    [int]$PidWaitSeconds = 60, [int]$LockWaitSeconds = 30, [int]$LockPollMs = 250) {
    & $script:HelperPs51 -NoProfile -ExecutionPolicy Bypass -File $script:HelperScript `
        -RepoPath $Fixture.Clone -ExePath $Fixture.Exe -AppPid $AppPid -LogPath $Fixture.Log `
        -PidWaitSeconds $PidWaitSeconds -LockWaitSeconds $LockWaitSeconds -LockPollMs $LockPollMs
    return $LASTEXITCODE
}

# Same launch, detached from the test runspace, for the rows where the TEST must act
# on the stand-in exe while the helper runs (hold/release choreography).
function Start-UpdateHelper($Fixture, [int]$AppPid,
    [int]$PidWaitSeconds = 60, [int]$LockWaitSeconds = 30, [int]$LockPollMs = 250) {
    return Start-Process -FilePath $script:HelperPs51 -ArgumentList '-NoProfile', `
        '-ExecutionPolicy', 'Bypass', '-File', $script:HelperScript, `
        '-RepoPath', $Fixture.Clone, '-ExePath', $Fixture.Exe, '-AppPid', $AppPid, '-LogPath', $Fixture.Log, `
        '-PidWaitSeconds', $PidWaitSeconds, '-LockWaitSeconds', $LockWaitSeconds, '-LockPollMs', $LockPollMs -PassThru
}

function Get-UpdateLogLines($Fixture) {
    if (-not (Test-Path $Fixture.Log)) { return @() }
    return @([IO.File]::ReadAllLines($Fixture.Log))
}

function Get-UpdateHead($Fixture) {
    return (git -C $Fixture.Clone rev-parse HEAD).Trim()
}

# The helper's restart is fire-and-forget by design (the production restart must
# outlive the helper), so the marker evidence becomes visible asynchronously:
# bounded wait before asserting (plan section B: handle the detached timing).
function Wait-UpdateMarker($Fixture, [int]$Seconds = 5) {
    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-Path $Fixture.MarkerFile) {
            $hit = @(Get-Content $Fixture.MarkerFile -ErrorAction SilentlyContinue) |
                Where-Object { $_ -match 'restarted' }
            if ($hit.Count -ge 1) { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# A process that is ALREADY gone when the helper starts (the fast PID path).
function New-UpdateDeadPid {
    $p = Start-Process -FilePath $script:HelperPs51 -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru
    $p.WaitForExit()
    return $p.Id
}

Describe 'AC-006 helper happy path on a local fixture repo (REQ-UPD-009/011)' {
    It 'waits out the PID and the lock, advances the clone, restarts the exe, and logs each step in order' {
        $f = New-UpdateFixture
        $lockStream = $null
        try {
            Push-UpdateFixtureCommit $f
            $before = Get-UpdateHead $f
            $after = (git -C $f.Pusher rev-parse HEAD).Trim()
            $deadPid = New-UpdateDeadPid

            # The stand-in exe stays exclusively locked until the test releases it
            # 300 ms in: the helper must wait out the lock, then pull, then restart.
            $lockStream = [IO.File]::Open($f.Exe, 'Open', 'ReadWrite', 'None')
            $proc = Start-UpdateHelper $f $deadPid 60 10 250
            Start-Sleep -Milliseconds 300
            $lockStream.Close()
            $proc.WaitForExit()
            $rc = $proc.ExitCode

            $rc | Should Be 0
            (Get-UpdateHead $f) | Should BeExactly $after

            $lines = @(Get-UpdateLogLines $f | Where-Object { $_ -match 'update: helper' })
            ($lines | Where-Object { $_ -match ' update: helper app-exit wait done$' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' update: helper lock released$' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match (' update: helper pull ok ' + $before.Substring(0, 7) + '\.\.' + $after.Substring(0, 7) + '$') }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' update: helper restarting$' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' update: helper done$' }).Count | Should Be 1
            # The section-J order: wait done, lock released, pull ok, restarting, done.
            $iWait = [array]::IndexOf($lines, @($lines | Where-Object { $_ -match ' update: helper app-exit wait done$' })[0])
            $iLock = [array]::IndexOf($lines, @($lines | Where-Object { $_ -match ' update: helper lock released$' })[0])
            $iPull = [array]::IndexOf($lines, @($lines | Where-Object { $_ -match ' update: helper pull ok ' })[0])
            $iRestart = [array]::IndexOf($lines, @($lines | Where-Object { $_ -match ' update: helper restarting$' })[0])
            $iDone = [array]::IndexOf($lines, @($lines | Where-Object { $_ -match ' update: helper done$' })[0])
            ($iWait -lt $iLock) | Should Be $true
            ($iLock -lt $iPull) | Should Be $true
            ($iPull -lt $iRestart) | Should Be $true
            ($iRestart -lt $iDone) | Should Be $true
            # Every helper line carries the LogSink timestamp prefix (LogSink.cs format).
            foreach ($line in $lines) {
                ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} update: helper') | Should Be $true
            }
        }
        finally {
            if ($null -ne $lockStream) { $lockStream.Close() }
            Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue
        }
    }
}

Describe 'AC-007 helper failure paths: surfaced, never destructive (REQ-UPD-010)' {
    It 'an untracked collision aborts the pull with git first error line logged, restarts anyway, changes nothing' {
        $f = New-UpdateFixture
        try {
            Push-UpdateFixtureCommit $f 'bin/new-stuff.txt'
            $before = Get-UpdateHead $f
            # The orphaned local file at a path the incoming commit writes.
            [IO.File]::WriteAllText((Join-Path $f.Clone 'bin\new-stuff.txt'), 'orphaned local content')
            $deadPid = New-UpdateDeadPid

            $rc = Invoke-UpdateHelper $f $deadPid 30 10 250

            $rc | Should Be 0
            (Get-UpdateHead $f) | Should BeExactly $before
            (Test-Path (Join-Path $f.Clone 'bin\new-stuff.txt')) | Should Be $true
            ([IO.File]::ReadAllText((Join-Path $f.Clone 'bin\new-stuff.txt'))) | Should BeExactly 'orphaned local content'
            $lines = @(Get-UpdateLogLines $f)
            ($lines | Where-Object { $_ -match ' update: helper pull failed: ' }) | Should Not BeNullOrEmpty
            ($lines | Where-Object { $_ -match 'untracked working tree files would be overwritten' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' update: helper restarting$' }).Count | Should Be 1
            (Wait-UpdateMarker $f) | Should Be $true
        }
        finally { Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue }
    }

    It 'a diverged clone fails the ff-only pull with git error logged, restarts anyway, keeps the local commit' {
        $f = New-UpdateFixture
        try {
            # Local commit in the clone, then the origin advances: divergence.
            [IO.File]::WriteAllText((Join-Path $f.Clone 'bin\app.exe'), 'local change')
            git -C $f.Clone -c user.email=t@t -c user.name=t commit -a -m LOCAL 2>&1 | Out-Null
            Push-UpdateFixtureCommit $f
            $localHead = Get-UpdateHead $f
            $deadPid = New-UpdateDeadPid

            $rc = Invoke-UpdateHelper $f $deadPid 30 10 250

            $rc | Should Be 0
            (Get-UpdateHead $f) | Should BeExactly $localHead
            $lines = @(Get-UpdateLogLines $f)
            ($lines | Where-Object { $_ -match ' update: helper pull failed: ' }) | Should Not BeNullOrEmpty
            ($lines | Where-Object { $_ -match 'fast-forward' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' update: helper restarting$' }).Count | Should Be 1
            (Wait-UpdateMarker $f) | Should Be $true
        }
        finally { Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue }
    }
}

Describe 'AC-008 helper lock-wait bounds and PID handling (REQ-UPD-009)' {
    It 'a lock held past the bound: timeout line, pull skipped, restart still attempted' {
        $f = New-UpdateFixture
        $holder = $null
        try {
            Push-UpdateFixtureCommit $f
            $before = Get-UpdateHead $f
            $deadPid = New-UpdateDeadPid

            # Held the way a RUNNING exe is held (read access, read+delete sharing,
            # write stays exclusive): the helper's exclusive probe fails while the
            # restart (a cmd read open) still succeeds past the bound.
            $holder = [IO.File]::Open($f.Exe, 'Open', 'Read', 'Read, Delete')
            $proc = Start-UpdateHelper $f $deadPid 30 1 250
            Start-Sleep -Milliseconds 2500
            $holder.Close()
            $proc.WaitForExit()

            (Get-UpdateHead $f) | Should BeExactly $before
            $lines = @(Get-UpdateLogLines $f)
            ($lines | Where-Object { $_ -match ' update: helper lock wait timeout after 1s$' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' pull ' }) | Should BeNullOrEmpty
            ($lines | Where-Object { $_ -match ' update: helper restarting$' }).Count | Should Be 1
            (Wait-UpdateMarker $f) | Should Be $true
        }
        finally {
            if ($null -ne $holder) { $holder.Close() }
            Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue
        }
    }

    It 'a live PID is waited out before the lock probe (the lock-released stamp follows the dummy exit)' {
        $f = New-UpdateFixture
        $dummy = $null
        try {
            Push-UpdateFixtureCommit $f
            $after = (git -C $f.Pusher rev-parse HEAD).Trim()
            $dummy = Start-Process -FilePath $script:HelperPs51 -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 4' -PassThru
            $startedAt = [DateTime]::Now

            $rc = Invoke-UpdateHelper $f $dummy.Id 30 10 250
            $rc | Should Be 0

            (Get-UpdateHead $f) | Should BeExactly $after
            $lockLine = @(@(Get-UpdateLogLines $f) | Where-Object { $_ -match ' update: helper lock released$' })
            $lockLine.Count | Should Be 1
            $stamp = [DateTime]::ParseExact($lockLine[0].Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $null)
            ($stamp -ge $startedAt.AddSeconds(3)) | Should Be $true
            (Wait-UpdateMarker $f) | Should Be $true
        }
        finally {
            if ($null -ne $dummy) { try { $dummy.Kill() } catch { } }
            Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue
        }
    }

    It 'an already-exited PID is a no-op wait: the flow proceeds and completes' {
        $f = New-UpdateFixture
        try {
            $deadPid = New-UpdateDeadPid
            $rc = Invoke-UpdateHelper $f $deadPid 30 10 250
            $rc | Should Be 0
            $lines = @(Get-UpdateLogLines $f)
            ($lines | Where-Object { $_ -match ' update: helper app-exit wait done$' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' update: helper done$' }).Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue }
    }

    It 'a PID that never exits within the bound: timeout line, pull skipped, restart still attempted' {
        $f = New-UpdateFixture
        $dummy = $null
        try {
            Push-UpdateFixtureCommit $f
            $before = Get-UpdateHead $f
            $dummy = Start-Process -FilePath $script:HelperPs51 -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 30' -PassThru

            $rc = Invoke-UpdateHelper $f $dummy.Id 1 10 250

            $rc | Should Be 0
            (Get-UpdateHead $f) | Should BeExactly $before
            $lines = @(Get-UpdateLogLines $f)
            ($lines | Where-Object { $_ -match ' update: helper app-exit wait timeout after 1s$' }).Count | Should Be 1
            ($lines | Where-Object { $_ -match ' pull ' }) | Should BeNullOrEmpty
            ($lines | Where-Object { $_ -match ' update: helper restarting$' }).Count | Should Be 1
            (Wait-UpdateMarker $f) | Should Be $true
        }
        finally {
            if ($null -ne $dummy) { try { $dummy.Kill() } catch { } }
            Remove-Item -Recurse -Force $f.Scratch -ErrorAction SilentlyContinue
        }
    }
}

Describe 'AC-009 helper git safety vocabulary (REQ-UPD-010, source-scan half)' {
    It 'the script contains exactly one git invocation and it is the pinned pull --ff-only form' {
        $src = [IO.File]::ReadAllText($script:HelperScript)
        ([regex]::Matches($src, 'pull --ff-only origin main')).Count | Should Be 1
        ([regex]::Matches($src, '(?m)&\s*\$gitExe\b')).Count | Should Be 1
    }

    It 'the script carries zero destructive git tokens (clean/stash/reset/checkout/push/force)' {
        $src = [IO.File]::ReadAllText($script:HelperScript)
        foreach ($token in @('clean', 'stash', 'reset', 'checkout', 'push', 'force')) {
            ([regex]::Matches($src, $token)).Count | Should Be 0
        }
    }

    It 'the restart step is a working-directory-qualified Start-Process on the passed exe (AC-011 script half)' {
        $src = [IO.File]::ReadAllText($script:HelperScript)
        ($src -match 'Start-Process -FilePath \$ExePath -WorkingDirectory') | Should Be $true
    }
}

Describe 'F3 helper log lines are sanitized like LogSink (REQ-LOG-001/002 parity, t16)' {
    # Extracts ONLY Add-HelperLog from the helper script through the PowerShell AST, so the
    # test never executes the script body (no pull, no restart, no required parameters).
    function Import-HelperLogFunction {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HelperScript, [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-HelperLog' }, $true)
        return [scriptblock]::Create($fn.Extent.Text)
    }

    It 'a line with CR, LF, a control char, DEL and a tab is written as ONE line matching the LogSink mapping' {
        $scratch = Join-Path $here ('scratch-helperlog-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratch | Out-Null
        try {
            $LogPath = Join-Path $scratch 'app.log'
            . (Import-HelperLogFunction)
            $nl = [char]10
            $cr = [char]13
            $ctl = [char]7
            $del = [char]127
            $tab = [char]9
            Add-HelperLog ('update: helper pull failed: a' + $cr + 'b' + $nl + 'c' + $ctl + 'd' + $del + 'e' + $tab + 'f')
            $raw = [IO.File]::ReadAllText($LogPath)
            $lines = @($raw -split "`r`n" | Where-Object { $_.Length -gt 0 })
            $lines.Count | Should Be 1
            $fffd = [string][char]0xFFFD
            $expected = 'update: helper pull failed: a' + '\r' + 'b' + '\n' + 'c' + $fffd + 'd' + $fffd + 'e' + $tab + 'f'
            $lines[0].Substring(20) | Should BeExactly $expected
            # The stamp is the LogSink shape: 'yyyy-MM-dd HH:mm:ss' + one space.
            ($lines[0] -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} update: ') | Should Be $true
        }
        finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
    }

    It 'the helper mapping equals the app LogSink.Sanitize output for the same input (parity with the real sink)' {
        $coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
        $appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'
        [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
        [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
        $scratch = Join-Path $here ('scratch-helperlog-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratch | Out-Null
        try {
            $probeText = 'x' + [char]13 + [char]10 + 'y' + [char]1 + 'z' + [char]127 + [char]9 + 'w'
            $sinkPath = Join-Path $scratch 'sink.log'
            $sink = [TerminalOrganizer.App.LogSink]::new($sinkPath)
            $sink.Append($probeText)
            $sinkLine = @([IO.File]::ReadAllLines($sinkPath))[0]
            $LogPath = Join-Path $scratch 'helper.log'
            . (Import-HelperLogFunction)
            Add-HelperLog $probeText
            $helperLine = @([IO.File]::ReadAllLines($LogPath))[0]
            $helperLine.Substring(20) | Should BeExactly $sinkLine.Substring(20)
        }
        finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
    }
}
