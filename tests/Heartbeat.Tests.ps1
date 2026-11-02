# SPEC-TRAY-016 M1 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md and plan.md section J, never from the code
# under test. This file is the ONLY test change of milestone M1: every pinned suite
# stays unedited (the three AM-4 numeral rows belong to M2, not M1).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# --- fixtures ---

function Reset-HbRig {
    $script:HbLog = New-Object 'System.Collections.Generic.List[string]'
    $script:HbWriteCount = 0
    $script:HbThrowCount = 0
    $script:HbPollCount = 0
    $script:HbNextOutcome = $true
}

function New-HbPollResult {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]@())
}

# The suite-driven controller seam (the injected poll/log seam pattern): the write
# delegate records one call per heartbeat write and returns the rigged outcome; a
# WriteOverride replaces it wholesale (the throwing-seam row). The 16-argument
# options constructor carries the heartbeat seam (null would mean "no heartbeat";
# every row here passes a live delegate).
function New-HbController([scriptblock]$WriteOverride = $null) {
    Reset-HbRig
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:HbPollCount++; return New-HbPollResult }
    $probe = [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param() @() }
    $queue = [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) }
    $marshal = [System.Action[System.Action]]{ param($a) $a.Invoke() }
    $foreground = [Func[IntPtr]]{ param() [IntPtr]::Zero }
    $alive = [Func[IntPtr,bool]]{ param($h) $true }
    $minimized = [Func[IntPtr,bool]]{ param($h) $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) @(0, 0, 0, 0) }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) }), `
        ([System.Action[IntPtr]]{ param($h) }), `
        ([System.Action[IntPtr]]{ param($h) })
    $log = [System.Action[string]]{ param($line) $script:HbLog.Add($line) }
    $write = if ($null -ne $WriteOverride) { [Func[bool]]$WriteOverride }
        else { [Func[bool]]{ param() $script:HbWriteCount++; return $script:HbNextOutcome } }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $null, $true, 'all', 10, $false, $write
}

function Get-HbFailureLines {
    # The comma keeps the array intact through PowerShell's function-output unrolling
    # (a one-line result would otherwise come back as a scalar string, whose [0] is a char).
    $found = @($script:HbLog | Where-Object { $_ -like 'attention: heartbeat*' })
    return ,$found
}

Describe 'AC-001 Heartbeat payload contract (REQ-HB-001)' {
    It 'a fixed DateTimeOffset builds exactly the pinned round-trip payload, no other key' {
        # acceptance.md AC-001: the exact-string equality IS the executable oracle.
        $fixed = [DateTimeOffset]::new(2026, 11, 1, 9, 54, 51, [TimeSpan]::FromHours(-5)).AddTicks(1234567)
        [TerminalOrganizer.Core.Attention.AttentionHeartbeat]::Payload($fixed) |
            Should BeExactly '{"timestamp":"2026-11-01T09:54:51.1234567-05:00"}'
    }

    It 'a second fixed offset (non-whole-hour, zero fraction) keeps the tz offset form' {
        $second = [DateTimeOffset]::new(2026, 10, 31, 23, 59, 59, [TimeSpan]::FromMinutes(150))
        [TerminalOrganizer.Core.Attention.AttentionHeartbeat]::Payload($second) |
            Should BeExactly '{"timestamp":"2026-10-31T23:59:59.0000000+02:30"}'
    }

    It 'the payload builder is byte-deterministic and always the one-key o-shape (pure function)' {
        foreach ($t in @(
            [DateTimeOffset]::new(2026, 11, 1, 9, 54, 51, [TimeSpan]::FromHours(-5)).AddTicks(1234567),
            [DateTimeOffset]::new(2026, 10, 31, 23, 59, 59, [TimeSpan]::FromMinutes(150)),
            [DateTimeOffset]::new(2000, 1, 2, 3, 4, 5, [TimeSpan]::Zero))) {
            $first = [TerminalOrganizer.Core.Attention.AttentionHeartbeat]::Payload($t)
            $again = [TerminalOrganizer.Core.Attention.AttentionHeartbeat]::Payload($t)
            $first | Should BeExactly $again
            $first | Should Match '^\{"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}[+-]\d{2}:\d{2}"\}$'
        }
    }

    It 'HeartbeatIntervalMs is the pinned 5000 ms cadence' {
        [TerminalOrganizer.Core.Attention.AttentionConstants]::HeartbeatIntervalMs | Should Be 5000
    }
}

Describe 'AC-002 Heartbeat cadence, start-write, teardown order, no delete (REQ-HB-001, REQ-HB-003)' {
    It 'Start() writes exactly once before any tick; each driven HeartbeatTick writes once more' {
        $controller = New-HbController
        try {
            $controller.Start()
            $script:HbWriteCount | Should Be 1
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $script:HbWriteCount | Should Be 4
            $script:HbLog.Count | Should Be 0
        }
        finally {
            $controller.Dispose()
        }
    }

    It 'Start wires a third WinForms timer at HeartbeatIntervalMs whose Tick drives HeartbeatTick' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'))
        $text.Contains('heartbeatTimer.Interval = AttentionConstants.HeartbeatIntervalMs') | Should Be $true
        $text.Contains('heartbeatTimer.Tick += delegate { HeartbeatTick(); }') | Should Be $true
        $text.Contains('heartbeatTimer.Start()') | Should Be $true
    }

    It 'Dispose tears down poll, then blink, then heartbeat, then the disposed flag, then overlays (AM-5 source order)' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'))
        $start = $text.IndexOf('public void Dispose()')
        $start | Should BeGreaterThan -1
        $end = $text.IndexOf('private static void CollectStop', $start)
        $end | Should BeGreaterThan $start
        $body = $text.Substring($start, $end - $start)
        foreach ($token in @('pollTimer', 'blinkTimer', 'heartbeatTimer', 'disposed = true', 'overlays.Stop')) {
            $body.Contains($token) | Should Be $true
        }
        $body.IndexOf('pollTimer') | Should BeLessThan $body.IndexOf('blinkTimer')
        $body.IndexOf('blinkTimer') | Should BeLessThan $body.IndexOf('heartbeatTimer')
        $body.IndexOf('heartbeatTimer') | Should BeLessThan $body.IndexOf('disposed = true')
        $body.IndexOf('disposed = true') | Should BeLessThan $body.IndexOf('overlays.Stop')
    }

    It 'no heartbeat source ever deletes: the controller and the writer expose no delete path' {
        $controllerText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'))
        $writerText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionHeartbeatWriter.cs'))
        $controllerText.Contains('Delete') | Should Be $false
        $writerText.Contains('Delete') | Should Be $false
        $writerText.Contains('organizer.json') | Should Be $true
    }
}

Describe 'AC-003 Heartbeat IO failure degradation (REQ-HB-002)' {
    It 'a consecutive failing run logs exactly one failure line and retries unconditionally every tick' {
        $controller = New-HbController
        try {
            $script:HbNextOutcome = $false
            $controller.Start()
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $script:HbWriteCount | Should Be 4
            $lines = Get-HbFailureLines
            $lines.Count | Should Be 1
            $lines[0] | Should BeExactly 'attention: heartbeat write failed (will retry next tick)'
        }
        finally {
            $controller.Dispose()
        }
    }

    It 'a failing heartbeat never stops other attention work: poll ticks still run beside it' {
        $controller = New-HbController
        try {
            $script:HbNextOutcome = $false
            $controller.Start()
            $controller.PollTick()
            $controller.PollTick()
            $script:HbPollCount | Should Be 2
            $controller.HeartbeatTick()
            $controller.PollTick()
            $script:HbPollCount | Should Be 3
        }
        finally {
            $controller.Dispose()
        }
    }

    It 'a throwing write seam is swallowed as one failure: no exception escapes any tick' {
        $throwing = { param() $script:HbThrowCount++; throw [InvalidOperationException]::new('disk on fire') }
        $controller = New-HbController -WriteOverride $throwing
        try {
            $controller.Start()
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $script:HbThrowCount | Should Be 3
            (Get-HbFailureLines).Count | Should Be 1
        }
        finally {
            $controller.Dispose()
        }
    }

    It 'a success ends the failure run; a NEW consecutive failure run logs exactly one new line' {
        $controller = New-HbController
        try {
            $script:HbNextOutcome = $false
            $controller.Start()
            $controller.HeartbeatTick()
            (Get-HbFailureLines).Count | Should Be 1
            $script:HbNextOutcome = $true
            $controller.HeartbeatTick()
            $script:HbWriteCount | Should Be 3
            (Get-HbFailureLines).Count | Should Be 1
            $script:HbNextOutcome = $false
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $controller.HeartbeatTick()
            $script:HbWriteCount | Should Be 6
            (Get-HbFailureLines).Count | Should Be 2
        }
        finally {
            $controller.Dispose()
        }
    }
}

Describe 'Heartbeat writer and production path wiring (REQ-HB-001, REQ-HB-002)' {
    It 'the writer builds the organizer.json path, creates the directory idempotently, writes a fresh payload' {
        $dir = Join-Path $here ('scratch-hb-' + [Guid]::NewGuid().ToString('N'))
        $path = [TerminalOrganizer.App.AttentionHeartbeatWriter]::HeartbeatPath($dir)
        $path | Should BeExactly (Join-Path $dir 'organizer.json')
        try {
            [TerminalOrganizer.App.AttentionHeartbeatWriter]::Write($path) | Should Be $true
            (Test-Path $path) | Should Be $true
            [IO.File]::ReadAllText($path) |
                Should Match '^\{"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}[+-]\d{2}:\d{2}"\}$'
            Start-Sleep -Milliseconds 20
            [TerminalOrganizer.App.AttentionHeartbeatWriter]::Write($path) | Should Be $true
            [IO.File]::ReadAllText($path) |
                Should Match '^\{"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}[+-]\d{2}:\d{2}"\}$'
        }
        finally {
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'a write whose directory cannot exist fails softly returning false, never throwing' {
        $blocker = Join-Path $here ('scratch-hb-blocked-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($blocker, 'not a directory')
        try {
            [TerminalOrganizer.App.AttentionHeartbeatWriter]::Write((Join-Path $blocker 'organizer.json')) |
                Should Be $false
        }
        finally {
            Remove-Item -Force $blocker -ErrorAction SilentlyContinue
        }
    }

    It 'CreateProduction wires the writer into the signal directory; the file is never att-*.json' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'))
        $text.Contains('AttentionHeartbeatWriter.Write') | Should Be $true
        $text.Contains('HeartbeatPath(signalDirectory)') | Should Be $true
        $trayText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $trayText.Contains('wsl-toast') | Should Be $true
        $trayText.Contains('AttentionSignalDirectory()') | Should Be $true
        $name = [TerminalOrganizer.App.AttentionHeartbeatWriter]::HeartbeatFileName
        $name | Should BeExactly 'organizer.json'
        ($name -match '^att-') | Should Be $false
    }
}
