# SPEC-TRAY-020 M1 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-001/AC-005 and spec.md REQ-UPD-001/002/
# 012/013 plus plan.md section J, never from the code under test. M3 appends the app
# wiring rows (AC-002/003/004/010/011) to this file; the detached helper suite lives
# in tests/UpdateHelper.Tests.ps1 (M2). The live end-to-end round is AC-012 evidence
# in progress.md section E.2, never asserted here (the TRAY-018/019 pattern).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
# The App assembly handle is taken from a resolved type so reflection targets the same
# instance another suite byte-loaded first.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
$script:UpdateCoreAsm = [TerminalOrganizer.Core.Assignment.ManagerSelector].Assembly
$script:UpdateAppAsm = [TerminalOrganizer.App.SettingsStore].Assembly

# --- fixtures ---

function New-UpdateSettingsScratch([string]$Content) {
    $dir = Join-Path $here ('scratch-update-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    if ($null -ne $Content -and $Content.Length -gt 0) {
        [IO.File]::WriteAllText($path, $Content)
    }
    return $path
}

function Get-UpdateSettings([string]$Content) {
    $path = New-UpdateSettingsScratch $Content
    try {
        return (([TerminalOrganizer.App.SettingsStore]::new($path)).Load())
    }
    finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
}

Describe 'AC-001 update-status classifier parse table (REQ-UPD-001)' {
    It 'parses "0 0" as Synced with zero counts' {
        $r = [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList('0 0')
        $r.Kind.ToString() | Should BeExactly 'Synced'
        $r.BehindCount | Should Be 0
        $r.AheadCount | Should Be 0
    }

    It 'parses "3 0" as Behind with count 3' {
        $r = [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList('3 0')
        $r.Kind.ToString() | Should BeExactly 'Behind'
        $r.BehindCount | Should Be 3
        $r.AheadCount | Should Be 0
    }

    It 'parses "0 2" as Ahead with count 2' {
        $r = [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList('0 2')
        $r.Kind.ToString() | Should BeExactly 'Ahead'
        $r.BehindCount | Should Be 0
        $r.AheadCount | Should Be 2
    }

    It 'parses "4 1" as Diverged with behind 4 / ahead 1' {
        $r = [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList('4 1')
        $r.Kind.ToString() | Should BeExactly 'Diverged'
        $r.BehindCount | Should Be 4
        $r.AheadCount | Should Be 1
    }

    It 'parses "0 0" with a trailing newline as Synced (whitespace tolerance)' {
        $r = [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList("0 0`n")
        $r.Kind.ToString() | Should BeExactly 'Synced'
    }

    It 'parses "  3   0 " with extra internal whitespace as Behind 3' {
        $r = [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList('  3   0 ')
        $r.Kind.ToString() | Should BeExactly 'Behind'
        $r.BehindCount | Should Be 3
    }

    It 'yields Unknown for every malformed input and never throws' {
        foreach ($bad in @('', 'abc', '1', '1 2 3', '-1 0', '3 x')) {
            { [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList($bad) } | Should Not Throw
            ([TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList($bad)).Kind.ToString() | Should BeExactly 'Unknown'
            ([TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList($bad)).BehindCount | Should Be 0
            ([TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList($bad)).AheadCount | Should Be 0
        }
    }

    It 'yields Unknown for a null reference and never throws' {
        { [TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList($null) } | Should Not Throw
        ([TerminalOrganizer.Core.Update.UpdateStatus]::ParseRevList($null)).Kind.ToString() | Should BeExactly 'Unknown'
    }

    It 'the classifier type declares no process-spawn or P/Invoke member (Core purity, REQ-UPD-002)' {
        $t = $script:UpdateCoreAsm.GetType('TerminalOrganizer.Core.Update.UpdateStatus', $true)
        $flags = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly'
        $members = @($t.GetConstructors($flags)) + @($t.GetMethods($flags))
        foreach ($m in $members) {
            if ($null -ne $m.ReturnType -and $m.ReturnType.FullName -ne 'System.Void') {
                ($m.ReturnType.FullName -match 'Diagnostics|Process') | Should Be $false
            }
            foreach ($p in @($m.GetParameters())) {
                ($p.ParameterType.FullName -match 'Diagnostics|Process') | Should Be $false
            }
        }
    }

    It 'the classifier source carries no file, clock, process, or P/Invoke token (Core purity, REQ-UPD-002)' {
        $src = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.Core\Update\UpdateStatus.cs'))
        ($src -match 'System\.Diagnostics|DllImport|Process\.Start|File\.|Directory\.|DateTime|TickCount|Environment\.') | Should Be $false
    }
}

Describe 'AC-005 settings key updateAutoCheckEnabled (REQ-UPD-013)' {
    It 'absent key loads true (the D-8 default)' {
        $s = Get-UpdateSettings '{"hotkey":"Ctrl+Alt+U","schemaVersion":3}'
        $s.UpdateAutoCheckEnabled | Should Be $true
    }

    It 'boolean false loads false' {
        $s = Get-UpdateSettings '{"schemaVersion":3,"updateAutoCheckEnabled":false}'
        $s.UpdateAutoCheckEnabled | Should Be $false
    }

    It 'explicit null loads true' {
        $s = Get-UpdateSettings '{"schemaVersion":3,"updateAutoCheckEnabled":null}'
        $s.UpdateAutoCheckEnabled | Should Be $true
    }

    It 'a garbage value ("yes please") loads true (tolerant degrade)' {
        $s = Get-UpdateSettings '{"schemaVersion":3,"updateAutoCheckEnabled":"yes please"}'
        $s.UpdateAutoCheckEnabled | Should Be $true
    }

    It 'schemaVersion stays 3 with the new key present' {
        $s = Get-UpdateSettings '{"schemaVersion":3,"updateAutoCheckEnabled":false}'
        $s.SchemaVersion | Should Be 3
    }

    It 'AppSettings carries exactly 19 properties (AM-2b: 18 -> 19)' {
        ([TerminalOrganizer.App.AppSettings].GetProperties().Count) | Should Be 19
    }

    It 'an unrelated save carries the resolved switch through (a user-set false survives a read-modify-write)' {
        $path = New-UpdateSettingsScratch '{"schemaVersion":3,"updateAutoCheckEnabled":false}'
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $store.Save($store.Load())
            (([TerminalOrganizer.App.SettingsStore]::new($path)).Load()).UpdateAutoCheckEnabled | Should Be $false
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the settings save-site count in TrayContext.cs stays exactly 3 (no new save site; the D-8 file-edit-only key)' {
        $ctx = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        ([regex]::Matches($ctx, 'store\.Save\(new AppSettings')).Count | Should Be 3
    }
}

Describe 'AC-005 enum growth guards (REQ-UPD-012, plan section J AM-1/AM-2a)' {
    It 'TrayMenuEntryKind carries exactly 28 members (AM-1: 26 -> 28)' {
        $names = @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]))
        $names.Count | Should Be 28
    }

    It 'both new kinds exist and are DISMISS-classified (IsKeepOpenKind false)' {
        [Enum]::IsDefined([TerminalOrganizer.App.TrayMenuEntryKind], 'CheckForUpdates') | Should Be $true
        [Enum]::IsDefined([TerminalOrganizer.App.TrayMenuEntryKind], 'UpdateAndRestart') | Should Be $true
        [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]::CheckForUpdates) | Should Be $false
        [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]::UpdateAndRestart) | Should Be $false
    }

    It 'the keep-open set stays exactly the 8 settings-mutation kinds (both new kinds dismiss)' {
        $keep = @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]) |
            Where-Object { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]$_) })
        $keep.Count | Should Be 8
    }
}

# --- M3 wiring rows (appended per plan section F M3) ---

# The runner seam state: a planned result sequence consumed by the fake delegate, and
# the call log. The production delegate signature is UpdateGitDelegate(arguments,
# timeoutMs) -> UpdateGitResult; a planned $null result means "throw" (git unresolvable).
$script:UpdateRunnerPlan = @()
$script:UpdateRunnerCalls = @()

function Get-UpdateFakeRunner {
    return [TerminalOrganizer.App.UpdateGitDelegate]{
        param($arguments, $timeoutMs)
        $script:UpdateRunnerCalls += $arguments
        $next = $script:UpdateRunnerPlan[0]
        $script:UpdateRunnerPlan = @($script:UpdateRunnerPlan | Select-Object -Skip 1)
        if ($null -eq $next) { throw 'git.exe process start failed: file not found' }
        if ($next -is [scriptblock]) { & $next } else { return $next }
    }
}

# One scratch-log checker wired to the fake runner; the plan entries are
# [TerminalOrganizer.App.UpdateGitResult] instances (or $null to simulate a start throw).
function New-UpdateSeamChecker($Plan) {
    $dir = Join-Path $here ('scratch-update-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:UpdateRunnerPlan = @($Plan)
    $script:UpdateRunnerCalls = @()
    $checker = [TerminalOrganizer.App.UpdateChecker]::new(
        ([TerminalOrganizer.App.LogSink]::new((Join-Path $dir 'check.log'))),
        'C:\repo', (Get-UpdateFakeRunner), 20000)
    return @{ Dir = $dir; Checker = $checker; Log = (Join-Path $dir 'check.log') }
}

function Get-UpdateSeamLogLines($Seam) {
    if (-not (Test-Path $Seam.Log)) { return @() }
    return @([IO.File]::ReadAllLines($Seam.Log))
}

Describe 'AC-002 check outcome contract through the runner seam (REQ-UPD-003)' {
    It 'rev-list "3 0" resolves Behind(3) with exactly the one pinned log line' {
        $s = New-UpdateSeamChecker @(
            [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '', ''),
            [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '3 0', ''))
        try {
            $o = $s.Checker.Check()
            $o.Kind.ToString() | Should BeExactly 'Behind'
            $o.BehindCount | Should Be 3
            $o.AheadCount | Should Be 0
            $lines = @(Get-UpdateSeamLogLines $s |
                ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ', '' } |
                Where-Object { $_ -match '^update: ' })
            $lines.Count | Should Be 1
            $lines[0] | Should BeExactly 'update: check outcome=behind behind=3 ahead=0'
            $script:UpdateRunnerCalls.Count | Should Be 2
            $script:UpdateRunnerCalls[0] | Should Match ' fetch origin main$'
            $script:UpdateRunnerCalls[1] | Should Match ' rev-list --count --left-right origin/main\.\.\.HEAD$'
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }

    It 'a non-zero fetch exit resolves FetchFailed with the first stderr line as detail' {
        $s = New-UpdateSeamChecker @(
            [TerminalOrganizer.App.UpdateGitResult]::Ok(1, '', "fatal: unable to access 'https://github.com/windysky/terminal-organizer-dev/': dial timeout"))
        try {
            $o = $s.Checker.Check()
            $o.Kind.ToString() | Should BeExactly 'FetchFailed'
            $o.Detail | Should BeExactly "fatal: unable to access 'https://github.com/windysky/terminal-organizer-dev/': dial timeout"
            $line = @(Get-UpdateSeamLogLines $s | Where-Object { $_ -match 'update: check failed' })[0]
            ($line -match 'reason=fetch-failed detail="fatal: unable to access') | Should Be $true
            $script:UpdateRunnerCalls.Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }

    It 'a process-start failure (git unresolvable) resolves GitMissing' {
        $s = New-UpdateSeamChecker @($null)
        try {
            $o = $s.Checker.Check()
            $o.Kind.ToString() | Should BeExactly 'GitMissing'
            (@(Get-UpdateSeamLogLines $s) | Where-Object { $_ -match 'update: check failed reason=git-missing' }).Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }

    It 'a timed-out fetch resolves Timeout with the timeout line' {
        $s = New-UpdateSeamChecker @(
            [TerminalOrganizer.App.UpdateGitResult]::TimedOutResult())
        try {
            $o = $s.Checker.Check()
            $o.Kind.ToString() | Should BeExactly 'Timeout'
            (@(Get-UpdateSeamLogLines $s) | Where-Object { $_ -match 'update: check failed reason=timeout' }).Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }

    It 'rev-list "0 0" / "0 2" / "4 1" resolve Synced / Ahead(2) / Diverged(4,1), one log line each' {
        foreach ($pair in @(
                @('0 0', 'Synced', 'update: check outcome=synced'),
                @('0 2', 'Ahead', 'update: check outcome=ahead behind=0 ahead=2'),
                @('4 1', 'Diverged', 'update: check outcome=diverged behind=4 ahead=1'))) {
            $s = New-UpdateSeamChecker @(
                [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '', ''),
                [TerminalOrganizer.App.UpdateGitResult]::Ok(0, $pair[0], ''))
            try {
                $o = $s.Checker.Check()
                $o.Kind.ToString() | Should BeExactly $pair[1]
                $lines = @(Get-UpdateSeamLogLines $s |
                    ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ', '' } |
                    Where-Object { $_ -match '^update: ' })
                $lines.Count | Should Be 1
                ($lines[0] -match [regex]::Escape($pair[2])) | Should Be $true
            }
            finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
        }
    }

    It 'a failed rev-list (non-zero exit, empty output) resolves Unknown, never throws' {
        $s = New-UpdateSeamChecker @(
            [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '', ''),
            [TerminalOrganizer.App.UpdateGitResult]::Ok(128, '', 'fatal: bad revision'))
        try {
            $o = $s.Checker.Check()
            $o.Kind.ToString() | Should BeExactly 'Unknown'
            (@(Get-UpdateSeamLogLines $s) | Where-Object { $_ -match 'update: check outcome=unknown' }).Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }

    It 'a request arriving while one is in flight is ignored with one line and starts no second chain' {
        # The fetch-serving delegate call RE-ENTERS Check(): the nested request must hit
        # the in-flight guard, log the ignored line, and never invoke the runner again.
        $inner = {
            $script:UpdateNestedOutcome = $script:UpdateSeamNested.Check()
            return [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '', '')
        }
        $plan = @($inner, [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '3 0', ''))
        $s = New-UpdateSeamChecker $plan
        $script:UpdateSeamNested = $s.Checker
        $script:UpdateNestedOutcome = 'not-run'
        try {
            $o = $s.Checker.Check()
            $o.Kind.ToString() | Should BeExactly 'Behind'
            ($null -eq $script:UpdateNestedOutcome) | Should Be $true
            $script:UpdateRunnerCalls.Count | Should Be 2
            $lines = @(Get-UpdateSeamLogLines $s |
                ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ', '' } |
                Where-Object { $_ -match '^update: ' })
            $lines.Count | Should Be 2
            (@($lines | Where-Object { $_ -match 'update: check ignored reason=in-flight' })).Count | Should Be 1
            (@($lines | Where-Object { $_ -match 'update: check outcome=behind behind=3 ahead=0' })).Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }
}

Describe 'AC-003 manual-check notice mapping (REQ-UPD-004)' {
    # ASCII-only file (PS 5.1 reads a no-BOM .ps1 as ANSI): the em dash comes from its
    # code point, the App.Tests B2Em pattern.
    $script:UpdateEm = [string][char]0x2014

    It 'the section-J texts and levels map per outcome (pure function of the outcome)' {
        $cases = @(
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Synced, 0, 0, $null)),
                'TerminalOrganizer is up to date (origin/main).', 'Information'),
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Behind, 3, 0, $null)),
                'Update available: 3 commit(s) behind origin/main. Tray menu: Update and restart.', 'Information'),
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Ahead, 0, 2, $null)),
                'Local checkout is 2 commit(s) ahead of origin/main (not pushed).', 'Information'),
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Diverged, 4, 1, $null)),
                ('Checkout diverged from origin/main (4 behind, 1 ahead). Manual judgement needed ' + $script:UpdateEm + ' no update applied.'), 'Warning'),
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::GitMissing, 0, 0, $null)),
                'Update check failed (git-missing). See the log for detail.', 'Error'),
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::FetchFailed, 0, 0, 'x')),
                'Update check failed (fetch-failed). See the log for detail.', 'Error'),
            @(([TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Timeout, 0, 0, $null)),
                'Update check failed (timeout). See the log for detail.', 'Error'))
        foreach ($case in $cases) {
            [TerminalOrganizer.App.UpdateNotices]::TextFor($case[0]) | Should BeExactly $case[1]
            [TerminalOrganizer.App.UpdateNotices]::LevelFor($case[0]).ToString() | Should BeExactly $case[2]
        }
    }

    It 'the already-up-to-date update-and-restart text is pinned' {
        [TerminalOrganizer.App.UpdateNotices]::AlreadyUpToDateText |
            Should BeExactly ('Already up to date ' + $script:UpdateEm + ' nothing to update.')
    }
}

Describe 'AC-004 startup auto-check: delayed, background, behind-only notify, never mutating (REQ-UPD-005/006)' {
    It 'a behind startup outcome notifies once (the section-J behind text) and logs its one line' {
        $s = New-UpdateSeamChecker @(
            [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '', ''),
            [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '2 0', ''))
        $script:UpdateNotified = @()
        $notify = [Action[TerminalOrganizer.App.UpdateCheckOutcome]]{ param($o) $script:UpdateNotified += $o }
        try {
            $o = $s.Checker.RunStartupCheck($notify)
            $o.Kind.ToString() | Should BeExactly 'Behind'
            $script:UpdateNotified.Count | Should Be 1
            $script:UpdateNotified[0].BehindCount | Should Be 2
            (@(Get-UpdateSeamLogLines $s) | Where-Object { $_ -match 'update: check outcome=behind behind=2 ahead=0' }).Count | Should Be 1
        }
        finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
    }

    It 'every non-behind startup outcome logs its one line and notifies nothing' {
        foreach ($plan in @(
                @('0 0', 'synced'), @('0 2', 'ahead'), @('4 1', 'diverged'))) {
            $s = New-UpdateSeamChecker @(
                [TerminalOrganizer.App.UpdateGitResult]::Ok(0, '', ''),
                [TerminalOrganizer.App.UpdateGitResult]::Ok(0, $plan[0], ''))
            $script:UpdateNotified = @()
            $notify = [Action[TerminalOrganizer.App.UpdateCheckOutcome]]{ param($o) $script:UpdateNotified += $o }
            try {
                $null = $s.Checker.RunStartupCheck($notify)
                $script:UpdateNotified.Count | Should Be 0
                (@(Get-UpdateSeamLogLines $s) | Where-Object { $_ -match ('update: check outcome=' + $plan[1]) }).Count | Should Be 1
            }
            finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
        }
        foreach ($failed in @(
                @($null, 'git-missing'),
                @([TerminalOrganizer.App.UpdateGitResult]::TimedOutResult(), 'timeout'))) {
            $s = New-UpdateSeamChecker @($failed[0])
            $script:UpdateNotified = @()
            $notify = [Action[TerminalOrganizer.App.UpdateCheckOutcome]]{ param($o) $script:UpdateNotified += $o }
            try {
                $null = $s.Checker.RunStartupCheck($notify)
                $script:UpdateNotified.Count | Should Be 0
                (@(Get-UpdateSeamLogLines $s) | Where-Object { $_ -match ('update: check failed reason=' + $failed[1]) }).Count | Should Be 1
            }
            finally { Remove-Item -Recurse -Force $s.Dir -ErrorAction SilentlyContinue }
        }
    }

    It 'the startup source path never spawns the helper: SpawnUpdateHelper appears exactly once, only in the update-and-restart handler' {
        $ctx = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        ([regex]::Matches($ctx, 'SpawnUpdateHelper\(\)')).Count | Should Be 2
        ([regex]::Matches($ctx, 'private bool SpawnUpdateHelper')).Count | Should Be 1
        ([regex]::Matches($ctx, 'if \(SpawnUpdateHelper\(\)\)')).Count | Should Be 1
        # The only call site lives inside HandleUpdateAndRestartCompleted (the constructor
        # and the startup/manual handlers carry no spawn token).
        $start = $ctx.IndexOf('HandleStartupUpdateCheckCompleted')
        $span = $ctx.Substring($start, [Math]::Min(900, $ctx.Length - $start))
        ($span -match 'SpawnUpdateHelper') | Should Be $false
    }

    It 'the shell constructor arms the startup check only when the setting resolves true, on a WinForms timer, with no blocking git wait' {
        $ctx = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $ctorStart = $ctx.IndexOf('internal TrayShell()')
        $ctorEnd = $ctx.IndexOf('private void Notice(')
        ($ctorStart -ge 0 -and $ctorEnd -gt $ctorStart) | Should Be $true
        $ctor = $ctx.Substring($ctorStart, $ctorEnd - $ctorStart)
        ($ctor -match 'if \(current\.UpdateAutoCheckEnabled\)') | Should Be $true
        ($ctor -match 'ArmStartupUpdateCheck\(\)') | Should Be $true
        ($ctor -match 'WaitForExit') | Should Be $false
        ($ctor -match 'SpawnUpdateHelper') | Should Be $false
        # The timer is a WinForms one-shot on the section-J delay (C3: WinForms timers only).
        $armStart = $ctx.IndexOf('private void ArmStartupUpdateCheck')
        $armSpan = $ctx.Substring($armStart, [Math]::Min(1200, $ctx.Length - $armStart))
        ($armSpan -match 'System\.Windows\.Forms\.Timer') | Should Be $true
        ($armSpan -match 'UpdateChecker\.StartupCheckDelayMs') | Should Be $true
    }
}

Describe 'AC-005 update-era menu rows, era-scoping, busy flags (REQ-UPD-012)' {
    function New-UpdateWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height) {
        New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, 96
    }

    function New-UpdateMenuState([bool]$Busy) {
        $monitors = @(New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
            'PCI\VEN_00&DEV_0M', 'MON-1', '0', 'SN-1', 1, 0, 0, 1920, 1152, (New-UpdateWorkArea 0 0 1920 1152))
        $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
        $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
            ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
        $windows = [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@()
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, $windows,
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null,
            $true, 'mixed', 10, $false, $true, $true
    }

    It 'the update-era root order carries both rows between Settings and Version' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-UpdateMenuState $false))
        ($entries | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly ('Status,Separator,OrganizeUnderCursor,Separator,OrganizeMonitorRoot,Separator,ManagerRoot,' +
                'Separator,OverflowRoot,Separator,AttentionRoot,Separator,LabelsAndPrioritiesRoot,Separator,LastResult,' +
                'OpenLog,Settings,CheckForUpdates,UpdateAndRestart,Version,Exit')
    }

    It 'both rows carry their exact labels; Check stays enabled while busy, Update disables' {
        foreach ($busy in @($false, $true)) {
            $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-UpdateMenuState $busy))
            $check = @($entries | Where-Object { $_.Kind.ToString() -eq 'CheckForUpdates' })[0]
            $update = @($entries | Where-Object { $_.Kind.ToString() -eq 'UpdateAndRestart' })[0]
            $check.Label | Should BeExactly 'Check for updates'
            $update.Label | Should BeExactly 'Update and restart'
            $check.Enabled | Should Be $true
            $update.Enabled | Should Be (-not $busy)
        }
    }

    It 'a pre-update-era state renders its pinned shape: no update rows in the attention-era root order' {
        $monitors = @()
        $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
        $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
            ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
        $state = New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $false, 'Ctrl+Alt+O', $monitors,
            ([TerminalOrganizer.Core.Windows.WindowSnapshot[]]@()), $selector, $resolution, $null, $false,
            ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null, $true, 'mixed', 10, $false, $true
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($state)
        $kinds = ($entries | ForEach-Object { $_.Kind.ToString() }) -join ','
        ($kinds -match 'CheckForUpdates|UpdateAndRestart') | Should Be $false
        ($kinds -replace 'AttentionRoot,Separator,', '') | Should BeExactly 'Status,Separator,OrganizeUnderCursor,Separator,OrganizeMonitorRoot,Separator,ManagerRoot,Separator,OverflowRoot,Separator,LabelsAndPrioritiesRoot,Separator,LastResult,OpenLog,Settings,Version,Exit'
    }
}

Describe 'AC-010 update-and-restart gating and the App git vocabulary (REQ-UPD-007/008)' {
    It 'the decision mapping: Behind spawns+exits, Synced already-up-to-date, every other outcome surfaces the reason, null is ignored' {
        $behind = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Behind, 2, 0, $null)
        $synced = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Synced, 0, 0, $null)
        $ahead = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Ahead, 0, 1, $null)
        $diverged = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Diverged, 1, 1, $null)
        $missing = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::GitMissing, 0, 0, $null)
        $fetchFailed = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::FetchFailed, 0, 0, 'x')
        $timeout = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Timeout, 0, 0, $null)
        $unknown = [TerminalOrganizer.App.UpdateCheckOutcome]::new([TerminalOrganizer.App.UpdateCheckOutcomeKind]::Unknown, 0, 0, $null)
        [TerminalOrganizer.App.UpdateDecision]::For($behind).ToString() | Should BeExactly 'SpawnHelperAndExit'
        [TerminalOrganizer.App.UpdateDecision]::For($synced).ToString() | Should BeExactly 'AlreadyUpToDate'
        foreach ($other in @($ahead, $diverged, $missing, $fetchFailed, $timeout, $unknown)) {
            [TerminalOrganizer.App.UpdateDecision]::For($other).ToString() | Should BeExactly 'SurfaceReason'
        }
        [TerminalOrganizer.App.UpdateDecision]::For($null).ToString() | Should BeExactly 'IgnoreInFlight'
    }

    It 'the App git vocabulary: fetch and rev-list present, zero destructive git invocations (AC-009 App half)' {
        foreach ($file in @('src\TerminalOrganizer.App\UpdateChecker.cs', 'src\TerminalOrganizer.App\TrayContext.cs')) {
            $src = [IO.File]::ReadAllText((Join-Path $repoRoot $file))
            ($src -match '\bgit\b[^"\r\n]*\b(pull|merge|reset|clean|stash|checkout|push)\b') | Should Be $false
        }
        $checker = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\UpdateChecker.cs'))
        ($checker -match 'fetch ') | Should Be $true
        ($checker -match 'rev-list --count --left-right') | Should Be $true
    }

    It 'the update-and-restart handler surfaces the already-up-to-date and reason notices, never spawning or exiting for them' {
        $ctx = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $start = $ctx.IndexOf('private void HandleUpdateAndRestartCompleted')
        ($start -ge 0) | Should Be $true
        $span = $ctx.Substring($start, [Math]::Min(1600, $ctx.Length - $start))
        ($span -match 'UpdateDecisionAction\.AlreadyUpToDate') | Should Be $true
        ($span -match 'UpdateNotices\.TextFor') | Should Be $true
        # The one spawn call and the exit call sit in the SpawnHelperAndExit arm.
        $spawnIndex = $span.IndexOf('SpawnUpdateHelper()')
        $exitIndex = $span.IndexOf('RequestApplicationExit()')
        ($spawnIndex -ge 0 -and $exitIndex -gt $spawnIndex) | Should Be $true
    }
}

Describe 'AC-011 detached spawn choreography source contract (REQ-UPD-007/009)' {
    It 'the spawn site constructs the process from the %SystemRoot%-rooted powershell constant with the pinned argument tokens' {
        $ctx = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $start = $ctx.IndexOf('private bool SpawnUpdateHelper')
        ($start -ge 0) | Should Be $true
        $end = $ctx.IndexOf('private void', $start + 10)
        $span = $ctx.Substring($start, $end - $start)
        ($span -match [regex]::Escape('UpdateChecker.HelperPowerShellExe')) | Should Be $true
        ($span -match [regex]::Escape('ExpandEnvironmentVariables')) | Should Be $true
        foreach ($token in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '-RepoPath', '-ExePath', '-AppPid', '-LogPath')) {
            ($span.Contains($token)) | Should Be $true
        }
        ($span -match 'CreateNoWindow = true') | Should Be $true
        ($span -match 'UseShellExecute = false') | Should Be $true
        ($span -match 'update: helper spawned pid=') | Should Be $true
    }

    It 'the pinned powershell constant carries the %SystemRoot%-rooted absolute path (section J)' {
        $checker = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\UpdateChecker.cs'))
        ($checker.Contains('%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe')) | Should Be $true
    }

    It 'the section-J App constants are pinned (remote/branch, timeouts, startup delay, helper bounds)' {
        $checker = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\UpdateChecker.cs'))
        ($checker.Contains('RemoteName = "origin"')) | Should Be $true
        ($checker.Contains('BranchName = "main"')) | Should Be $true
        ($checker.Contains('FetchTimeoutMs = 20000')) | Should Be $true
        ($checker.Contains('StartupCheckDelayMs = 8000')) | Should Be $true
        ($checker.Contains('HelperPidWaitSeconds = 60')) | Should Be $true
        ($checker.Contains('HelperLockWaitSeconds = 30')) | Should Be $true
        ($checker.Contains('HelperLockPollMs = 250')) | Should Be $true
    }

    It 'the repo root derivation is the normalized parent of the base directory with the .git check (A3)' {
        $checkerSrc = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\UpdateChecker.cs'))
        ($checkerSrc -match 'Path\.GetFullPath\(Path\.Combine\([^)]*"\.\."\)') | Should Be $true
        ($checkerSrc -match '\.git') | Should Be $true
    }
}
