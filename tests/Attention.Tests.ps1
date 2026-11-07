# SPEC-TRAY-013 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md and plan.md section J, never from the code under test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
# The App assembly handle is taken from a resolved type (not the Load call) so that when
# another suite byte-loads the same exe first, reflection targets the same instance.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
$script:AttentionAppAsm = [TerminalOrganizer.App.SettingsStore].Assembly

# --- shared fixtures ---

# The plan.md section J signal payload P1 (field order fixed so per-case Replace-free variants stay readable).
$script:P1 = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'

function New-AttentionScratchDir {
    $dir = Join-Path $here ('scratch-attention-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

function New-AttentionClock([long]$NowMs) {
    # GetNewClosure snapshots $NowMs into the delegate; a bare scriptblock would lose
    # the function-local variable when C# invokes it later (dynamic scoping).
    return [Func[long]]{ param() $NowMs }.GetNewClosure()
}

function New-AttentionStore([string]$Dir, [long]$NowMs) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionSignalStore -ArgumentList $Dir, (New-AttentionClock $NowMs)
}

function Write-AttentionFile([string]$Dir, [string]$Name, [string]$Content) {
    [IO.File]::WriteAllText((Join-Path $Dir $Name), $Content)
}

Describe 'AC-001 Signal parser (REQ-SIG-001)' {
    It 'P1 the plan section J payload is accepted with event stop and needle hooks' {
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($script:P1)
        $result.Accepted | Should Be $true
        $result.Signal.Event | Should BeExactly 'stop'
        $result.Signal.Needle | Should BeExactly 'hooks'
    }

    It 'P1 recorded fields carry session_id s-1, cwd /home/j/hooks and the ISO timestamp' {
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($script:P1)
        $result.Signal.SessionId | Should BeExactly 's-1'
        $result.Signal.Cwd | Should BeExactly '/home/j/hooks'
        $result.Signal.Timestamp | Should BeExactly '2026-10-31T09:00:00Z'
        $result.Signal.Version | Should Be 1
    }

    It 'P2 a notification event with notification_type permission is accepted and records the type' {
        $json = '{"version":1,"event":"notification","notification_type":"permission","session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Event | Should BeExactly 'notification'
        $result.Signal.Needle | Should BeExactly 'hooks'
        $result.Signal.NotificationType | Should BeExactly 'permission'
    }

    It 'R1 a remote-pushed payload (wsl-toast v1.6.1 carries "remote": true) records Remote true' {
        $json = '{"version":1,"event":"stop","needle":"hooks","remote":true}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Remote | Should Be $true
    }

    It 'R2 a local payload (no remote key) records Remote false' {
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($script:P1)
        $result.Accepted | Should Be $true
        $result.Signal.Remote | Should Be $false
    }

    It 'R3 an explicit remote false records Remote false' {
        $json = '{"version":1,"event":"stop","needle":"hooks","remote":false}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Remote | Should Be $false
    }

    It 'R4 a non-bool remote value degrades to false and never rejects (additive-field rule)' {
        $json = '{"version":1,"event":"stop","needle":"hooks","remote":"yes"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Remote | Should Be $false
    }

    It 'P3 version 2 is rejected with the version reason' {
        $json = '{"version":2,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'version'
    }

    It 'P4 a payload without the version key is rejected with the version reason' {
        $json = '{"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'version'
    }

    It 'P5 an unknown event idle is rejected with the event reason' {
        $json = '{"version":1,"event":"idle","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'event'
    }

    It 'P6 malformed JSON is rejected with the parse reason' {
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse('{oops')
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'parse'
    }

    It 'P7 a JSON array is rejected with the shape reason' {
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse('[1,2]')
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'shape'
    }

    It 'P8 a whitespace-only needle is rejected with the needle reason' {
        $json = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"   ","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'needle'
    }

    It 'P9 a payload without the needle key is rejected with the needle reason' {
        $json = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $false
        $result.Reason | Should BeExactly 'needle'
    }

    It 'P10 an unknown extra key is ignored and the payload is accepted' {
        $json = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z","extra":123}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Event | Should BeExactly 'stop'
        $result.Signal.Needle | Should BeExactly 'hooks'
    }

    It 'P11 a mixed-case needle with an inner space is stored verbatim' {
        $json = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"Hooks two","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Needle | Should BeExactly 'Hooks two'
    }

    It 'P12 a notification without the notification_type key records the type as null' {
        $json = '{"version":1,"event":"notification","session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $result = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $result.Accepted | Should Be $true
        $result.Signal.Event | Should BeExactly 'notification'
        $result.Signal.NotificationType | Should Be $null
    }

    It 'null and empty content are rejected with a reason, never an exception' {
        $nullResult = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($null)
        $nullResult.Accepted | Should Be $false
        $nullResult.Reason | Should Not Be $null
        $emptyResult = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse('')
        $emptyResult.Accepted | Should Be $false
        $emptyResult.Reason | Should Not Be $null
    }

    It 'the parser is a pure function: the same text accepted twice yields equal recorded fields' {
        $first = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($script:P1)
        $second = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($script:P1)
        $first.Signal.Event | Should Be $second.Signal.Event
        $first.Signal.Needle | Should Be $second.Signal.Needle
        $first.Signal.NotificationType | Should Be $second.Signal.NotificationType
        $first.Signal.SessionId | Should Be $second.Signal.SessionId
        $first.Signal.Cwd | Should Be $second.Signal.Cwd
        $first.Signal.Timestamp | Should Be $second.Signal.Timestamp
        $first.Signal.Version | Should Be $second.Signal.Version
    }
}

Describe 'AC-002 Signal store: pattern, age, consume (REQ-SIG-002)' {
    It 'one poll considers the four matching files, accepts the fresh two and consumes exactly them' {
        $dir = New-AttentionScratchDir
        try {
            Write-AttentionFile $dir 'att-100000-a.json' $script:P1
            Write-AttentionFile $dir 'att-70000-b.json' $script:P1
            Write-AttentionFile $dir 'att-69999-c.json' $script:P1
            Write-AttentionFile $dir 'att-99999-d.json' '{oops'
            Write-AttentionFile $dir 'notes.txt' $script:P1
            Write-AttentionFile $dir 'att-abc-e.json' $script:P1
            $store = New-AttentionStore $dir 100000
            $result = $store.Poll()
            $result.Accepted.Length | Should Be 2
            ($result.Accepted | ForEach-Object { $_.Event + '/' + $_.Needle }) -join ',' |
                Should BeExactly 'stop/hooks,stop/hooks'
            $result.Rejected.Length | Should Be 1
            $result.Rejected[0].FileName | Should BeExactly 'att-99999-d.json'
            $result.Rejected[0].Reason | Should BeExactly 'parse'
            $result.Stale.Length | Should Be 1
            $result.Stale[0].FileName | Should BeExactly 'att-69999-c.json'
            $result.Stale[0].AgeMs | Should Be 30001
        }
        finally {
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'the stale file at age 30001 is never parsed while age exactly 30000 stays fresh' {
        $dir = New-AttentionScratchDir
        try {
            Write-AttentionFile $dir 'att-100000-a.json' $script:P1
            Write-AttentionFile $dir 'att-70000-b.json' $script:P1
            Write-AttentionFile $dir 'att-69999-c.json' '{oops'
            $store = New-AttentionStore $dir 100000
            $result = $store.Poll()
            # att-69999-c.json carries malformed content: had it been parsed it would be
            # rejected; its absence from Rejected proves it was never parsed (stale path).
            $result.Rejected.Length | Should Be 0
            $result.Stale.Length | Should Be 1
            $result.Stale[0].FileName | Should BeExactly 'att-69999-c.json'
        }
        finally {
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'exactly the four considered files are deleted; the pattern mismatches stay on disk' {
        $dir = New-AttentionScratchDir
        try {
            Write-AttentionFile $dir 'att-100000-a.json' $script:P1
            Write-AttentionFile $dir 'att-70000-b.json' $script:P1
            Write-AttentionFile $dir 'att-69999-c.json' $script:P1
            Write-AttentionFile $dir 'att-99999-d.json' '{oops'
            Write-AttentionFile $dir 'notes.txt' $script:P1
            Write-AttentionFile $dir 'att-abc-e.json' $script:P1
            $store = New-AttentionStore $dir 100000
            [void]$store.Poll()
            (Test-Path (Join-Path $dir 'att-100000-a.json')) | Should Be $false
            (Test-Path (Join-Path $dir 'att-70000-b.json')) | Should Be $false
            (Test-Path (Join-Path $dir 'att-69999-c.json')) | Should Be $false
            (Test-Path (Join-Path $dir 'att-99999-d.json')) | Should Be $false
            (Test-Path (Join-Path $dir 'notes.txt')) | Should Be $true
            (Test-Path (Join-Path $dir 'att-abc-e.json')) | Should Be $true
        }
        finally {
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'a second poll of the same directory returns an empty result and deletes nothing' {
        $dir = New-AttentionScratchDir
        try {
            Write-AttentionFile $dir 'att-100000-a.json' $script:P1
            $store = New-AttentionStore $dir 100000
            [void]$store.Poll()
            $second = $store.Poll()
            $second.Accepted.Length | Should Be 0
            $second.Rejected.Length | Should Be 0
            $second.Stale.Length | Should Be 0
        }
        finally {
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'a poll of a missing directory returns an empty result without an exception' {
        $missing = Join-Path $here ('scratch-attention-missing-' + [Guid]::NewGuid().ToString('N'))
        $store = New-AttentionStore $missing 100000
        $result = $store.Poll()
        $result.Accepted.Length | Should Be 0
        $result.Rejected.Length | Should Be 0
        $result.Stale.Length | Should Be 0
    }
}

# --- AC-003 fixtures ---

# The em dash of the plan.md section J table, built from [char] codes (the BOM rule).
$script:EmDash = [string][char]0x2014

function New-AttentionCandidate([long]$Handle, [string]$Title, [string[]]$Tabs) {
    if ($null -eq $Tabs) { $Tabs = @() }
    return New-Object TerminalOrganizer.Core.Attention.AttentionCandidate -ArgumentList ([IntPtr]$Handle), $Title, $Tabs
}

function New-FixtureM {
    # The acceptance.md AC-004 candidate fixture, in the pinned input order.
    # SPEC-TRAY-019 (plan.md A-4 AM-1a): matchable titles are launcher-prefixed session
    # tabs; the path-shaped window titles of 4102/4106 stay as the incident-shape negatives.
    return @(
        (New-AttentionCandidate 4101 'HG_ClaudeWSL2Notification' @('HG_Hooks', 'HG_Pwsh')),
        (New-AttentionCandidate 4102 'claude ~ hooks' @('HG_ClaudeHooks')),
        (New-AttentionCandidate 4103 'PowerShell' @('HG_Wsl2')),
        (New-AttentionCandidate 4104 '' @()),
        (New-AttentionCandidate 4105 'HG_MyProject' @()),
        (New-AttentionCandidate 4106 'dev hooks' @('HG_DevHooks'))
    )
}

Describe 'AC-003 Normalizer and needle tokens (REQ-MAT-001)' {
    $cases = @(
        @{ Input = 'HG_ClaudeWSL2Notification'; Expected = 'hgclaudewsl2notification' },
        @{ Input = 'PowerShell'; Expected = 'powershell' },
        @{ Input = 'PowerShell 7.3.4'; Expected = 'powershell734' },
        @{ Input = 'claude ~ hooks'; Expected = 'claudehooks' },
        @{ Input = '~ hooks'; Expected = 'hooks' },
        @{ Input = 'OC_YODA1'; Expected = 'ocyoda1' },
        @{ Input = 'alpha2omega'; Expected = 'alpha2omega' },
        @{ Input = 'HG_MyProject'; Expected = 'hgmyproject' },
        @{ Input = 'hooks 42!'; Expected = 'hooks42' },
        @{ Input = '___'; Expected = '' },
        @{ Input = ''; Expected = '' }
    )
    foreach ($case in $cases) {
        It ("normalizes '" + $case.Input + "' to '" + $case.Expected + "'") {
            [TerminalOrganizer.Core.Attention.AttentionMatcher]::Normalize($case.Input) |
                Should BeExactly $case.Expected
        }
    }

    It 'normalizes the pwsh em-dash title to pwshdevhooks (em dash built from char codes)' {
        $title = 'pwsh ' + $script:EmDash + ' ~/dev/hooks'
        [TerminalOrganizer.Core.Attention.AttentionMatcher]::Normalize($title) |
            Should BeExactly 'pwshdevhooks'
    }

    It 'prepares needle tokens as pinned: split, normalized, empty-normalized dropped' {
        $tokens = [TerminalOrganizer.Core.Attention.AttentionMatcher]::NeedleTokens('claude notification wsl2')
        ($tokens -join '|') | Should BeExactly 'claude|notification|wsl2'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::NeedleTokens('Hooks') -join '|') |
            Should BeExactly 'hooks'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::NeedleTokens('a - b') -join '|') |
            Should BeExactly 'a|b'
    }

    It 'a needle of only separators yields zero tokens (the pinned no-match divergence)' {
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::NeedleTokens('---').Length) | Should Be 0
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::NeedleTokens('   ').Length) | Should Be 0
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::NeedleTokens('').Length) | Should Be 0
    }

    It 'NO camel-case or digit-boundary splitting occurs anywhere (the producer-exact rule)' {
        # The revision-0.1.0 camel rule would have split PowerShell into power|shell;
        # the producer source refuted it (plan.md A-3). One token out, one string.
        [TerminalOrganizer.Core.Attention.AttentionMatcher]::Normalize('PowerShell') |
            Should BeExactly 'powershell'
        [TerminalOrganizer.Core.Attention.AttentionMatcher]::Normalize('HG_ClaudeWSL2Notification') |
            Should BeExactly 'hgclaudewsl2notification'
    }

    It 'the same input normalizes identically on a second call (pure function)' {
        $first = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Normalize('HG_ClaudeWSL2Notification')
        $second = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Normalize('HG_ClaudeWSL2Notification')
        $first | Should Be $second
    }
}

Describe 'AC-004 Matcher (REQ-MAT-002)' {
    # Card t17 re-based one expected value of this table (HG_MyProject): it is a single-token needle naming the
    # whole session of tab 4105 (HG_MyProject), so the reverse rule now matches it. Multi-token needles keep the
    # forward all-tokens rule only; the reverse rule's own rows live in AttentionSessionMatch.Tests.ps1.
    $rows = @(
        @{ Needle = 'hooks'; Expected = '4101,4102,4106' },
        @{ Needle = 'claude notification wsl2'; Expected = '4101' },
        @{ Needle = 'claude'; Expected = '4101,4102' },
        @{ Needle = 'wsl2'; Expected = '4101,4103' },
        @{ Needle = 'powershell'; Expected = '' },
        @{ Needle = 'pwsh'; Expected = '4101' },
        @{ Needle = 'notification'; Expected = '4101' },
        @{ Needle = 'hooks pwsh'; Expected = '' },
        @{ Needle = 'hooks claude'; Expected = '4102' },
        @{ Needle = 'hooks hooks'; Expected = '4101,4102,4106' },
        @{ Needle = 'Hooks'; Expected = '4101,4102,4106' },
        @{ Needle = 'HG_MyProject'; Expected = '4105' },
        @{ Needle = 'myproject'; Expected = '4105' },
        @{ Needle = 'vhook'; Expected = '4106' },
        @{ Needle = 'dev hooks'; Expected = '4106' },
        @{ Needle = 'hooks yoda'; Expected = '' },
        @{ Needle = 'zzz'; Expected = '' },
        @{ Needle = '---'; Expected = '' },
        @{ Needle = '   '; Expected = '' },
        @{ Needle = ''; Expected = '' }
    )
    foreach ($row in $rows) {
        It ("needle '" + $row.Needle + "' matches [" + $row.Expected + "] over fixture M") {
            $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match($row.Needle, (New-FixtureM))
            ($handles -join ',') | Should BeExactly $row.Expected
        }
    }

    It 'an empty needle matches nothing' {
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('', (New-FixtureM))
        $handles.Length | Should Be 0
    }

    It 'supplying the candidates in reverse order yields the same handle SET' {
        $forward = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hooks', (New-FixtureM))
        $reversedCandidates = New-FixtureM
        [Array]::Reverse($reversedCandidates)
        $reversed = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hooks', $reversedCandidates)
        (($forward | Sort-Object) -join ',') | Should BeExactly ((($reversed | Sort-Object) -join ','))
    }

    It 'a null candidate list or a null needle yields an empty result, never an exception' {
        $nullNeedle = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match($null, (New-FixtureM))
        $nullNeedle.Length | Should Be 0
        $nullCandidates = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hooks', $null)
        $nullCandidates.Length | Should Be 0
    }

    It '4104 never matches (empty title, no tabs) while 4105 matches on the window title and 4106 on its session tab' {
        foreach ($needle in @('hooks', 'myproject', 'dev', 'zzzbad')) {
            $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match($needle, (New-FixtureM))
            ($handles -contains 4104) | Should Be $false
        }
    }
}

# --- AC-005 / AC-006 fixtures ---

# The common v3 base of acceptance.md AC-005. The persisted overflow-policy text is the
# enum name the store round-trips ("Stack"; "stackOnly" is a menu-row id, never a file value).
$script:AttentionV3Base = '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\attn\\log.txt","managerWindowName":"X","mergeEnabled":true,"overflowPolicy":"Stack","schemaVersion":3}'

function New-AttentionSettingsScratch([string]$Content) {
    $dir = Join-Path $here ('scratch-attention-settings-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    if ($null -ne $Content) {
        [IO.File]::WriteAllText($path, $Content)
    }
    return $path
}

function Get-AttentionShellMethod([string]$Name) {
    $shell = $script:AttentionAppAsm.GetType('TerminalOrganizer.App.TrayShell', $true)
    $shell.GetMethod($Name, [Reflection.BindingFlags]'NonPublic,Static')
}

function New-AttentionWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, 96
}

function New-AttentionMenuState([bool]$Busy, [bool]$AttentionOverlay, [switch]$Legacy) {
    $monitors = @(New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        'PCI\VEN_00&DEV_0M', 'MON-1', '0', 'SN-1', 1, 0, 0, 1920, 1152, (New-AttentionWorkArea 0 0 1920 1152))
    $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
        ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
    $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
    if ($Legacy) {
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null
    }
    return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
        $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null, $AttentionOverlay
}

Describe 'AC-005 Settings key (REQ-SET-001)' {
    It 'a v3 file without the attentionOverlay key loads true with schema 3' {
        $path = New-AttentionSettingsScratch $script:AttentionV3Base
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionOverlay | Should Be $true
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'attentionOverlay true loads true and false loads false' {
        $truePath = New-AttentionSettingsScratch ($script:AttentionV3Base.TrimEnd('}') + ',"attentionOverlay":true}')
        $falsePath = New-AttentionSettingsScratch ($script:AttentionV3Base.TrimEnd('}') + ',"attentionOverlay":false}')
        try {
            (([TerminalOrganizer.App.SettingsStore]::new($truePath)).Load()).AttentionOverlay | Should Be $true
            (([TerminalOrganizer.App.SettingsStore]::new($falsePath)).Load()).AttentionOverlay | Should Be $false
        }
        finally {
            Remove-Item -Recurse -Force (Split-Path $truePath) -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force (Split-Path $falsePath) -ErrorAction SilentlyContinue
        }
    }

    It 'attentionOverlay null loads true (absent-equivalent)' {
        $path = New-AttentionSettingsScratch ($script:AttentionV3Base.TrimEnd('}') + ',"attentionOverlay":null}')
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionOverlay | Should Be $true
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'a legacy 3-field file loads attentionOverlay true with schema 3' {
        $path = New-AttentionSettingsScratch '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\attn\\log.txt","managerWindowName":"X"}'
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionOverlay | Should Be $true
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'saving back with only the attention-overlay field changed keeps every other field' {
        $path = New-AttentionSettingsScratch $script:AttentionV3Base
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $current = $store.Load()
            $store.Save([TerminalOrganizer.App.AppSettings]::new(
                $current.Hotkey, $current.LogPath, $current.ManagerWindowName, $current.MergeEnabled,
                $current.FirstRunCompleted, $current.StartWithWindows, $current.ManagerSelector,
                $current.PriorityOverrides, $current.SchemaVersion, $current.OverflowPolicy,
                $current.CrossMonitorRedistribution, $current.TitleRules, $false))
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.Hotkey | Should BeExactly 'Ctrl+Alt+T'
            $s.LogPath | Should BeExactly 'C:\attn\log.txt'
            $s.ManagerWindowName | Should BeExactly 'X'
            $s.MergeEnabled | Should Be $true
            $s.OverflowPolicy.ToString() | Should BeExactly 'Stack'
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'an UNRELATED save through the manager-selector helper never reverts attentionOverlay false' {
        $path = New-AttentionSettingsScratch ($script:AttentionV3Base.TrimEnd('}') + ',"attentionOverlay":false}')
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
                [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'YODA1', 'OC_YODA1')
            $null = (Get-AttentionShellMethod 'SaveManagerSelectorTo').Invoke($null, @($store, $selector))
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.ManagerSelector.Value | Should BeExactly 'YODA1'
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'an UNRELATED save through the overflow-policy helper never reverts attentionOverlay false' {
        $path = New-AttentionSettingsScratch ($script:AttentionV3Base.TrimEnd('}') + ',"attentionOverlay":false}')
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-AttentionShellMethod 'SaveOverflowPolicyTo').Invoke($null,
                @($store, [TerminalOrganizer.App.OverflowPolicy]::Merge))
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.OverflowPolicy.ToString() | Should BeExactly 'Merge'
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'a missing file loads the defaults and the defaults carry attentionOverlay true' {
        $missing = Join-Path $here ('scratch-attention-settings-none-' + [Guid]::NewGuid().ToString('N') + '.json')
        $s = ([TerminalOrganizer.App.SettingsStore]::new($missing)).Load()
        $s.AttentionOverlay | Should Be $true
    }
}

Describe 'AC-006 Menu row (REQ-UI-001)' {
    It 'the model carries exactly one Attention overlay row, checked, enabled, between Overflow and Labels' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-AttentionMenuState $false $true))
        $rows = @($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionOverlay' })
        $rows.Count | Should Be 1
        $rows[0].Label | Should BeExactly 'Attention overlay'
        $rows[0].Checked | Should Be $true
        $rows[0].Enabled | Should Be $true
        $kinds = @($entries | ForEach-Object { $_.Kind.ToString() })
        $attentionIndex = [Array]::IndexOf($kinds, 'AttentionOverlay')
        $overflowIndex = [Array]::IndexOf($kinds, 'OverflowRoot')
        $labelsIndex = [Array]::IndexOf($kinds, 'LabelsAndPrioritiesRoot')
        ($attentionIndex -gt $overflowIndex) | Should Be $true
        ($attentionIndex -lt $labelsIndex) | Should Be $true
    }

    It 'building with attentionOverlay false yields the same row unchecked' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-AttentionMenuState $false $false))
        $rows = @($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionOverlay' })
        $rows.Count | Should Be 1
        $rows[0].Checked | Should Be $false
        $rows[0].Enabled | Should Be $true
    }

    It 'the legacy state constructor (no attention flag) yields the row checked true (default ON)' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-AttentionMenuState $false $true -Legacy))
        $rows = @($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionOverlay' })
        $rows.Count | Should Be 1
        $rows[0].Checked | Should Be $true
    }

    It 'busy true keeps the attention row enabled while the organize root disables in the same build' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-AttentionMenuState $true $true))
        $attention = @($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionOverlay' })[0]
        $attention.Enabled | Should Be $true
        $organize = @($entries | Where-Object { $_.Kind.ToString() -eq 'OrganizeUnderCursor' })[0]
        $organize.Enabled | Should Be $false
    }

    It 'the shell toggle save flips the value both ways and keeps every other field' {
        $path = New-AttentionSettingsScratch ($script:AttentionV3Base.TrimEnd('}') + ',"attentionOverlay":true}')
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $off = (Get-AttentionShellMethod 'ToggleAttentionOverlayTo').Invoke($null, @($store))
            $off | Should Be $false
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.Hotkey | Should BeExactly 'Ctrl+Alt+T'
            $s.ManagerWindowName | Should BeExactly 'X'
            $s.OverflowPolicy.ToString() | Should BeExactly 'Stack'
            $s.SchemaVersion | Should Be 3
            $on = (Get-AttentionShellMethod 'ToggleAttentionOverlayTo').Invoke($null, @($store))
            $on | Should Be $true
            ($store.Load()).AttentionOverlay | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }
}

# --- AC-007 to AC-011 fixtures: the controller test rig ---

function New-AttentionTestSignal([string]$Event, [string]$Needle) {
    $signal = New-Object TerminalOrganizer.Core.Attention.AttentionSignal
    $signal.Version = 1
    $signal.Event = $Event
    $signal.Needle = $Needle
    return $signal
}

function New-AttentionTestPollResult($Accepted = @(), $Rejected = @(), $Stale = @(), $IoErrors = @()) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]$Accepted), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]$Rejected), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]$Stale), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]$IoErrors)
}

function Reset-AttentionRig {
    $script:AttentionLog = New-Object 'System.Collections.Generic.List[string]'
    $script:FactoryCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:MarshalCount = 0
    $script:InsideMarshal = $false
    $script:ProbeCount = 0
    $script:PollCount = 0
    $script:ForegroundHandle = [IntPtr]::Zero
    $script:RectFeed = @(100, 200, 900, 700)
    $script:AliveOverrides = @{}
    $script:MinimizedOverrides = @{}
    $script:NextPoll = New-AttentionTestPollResult
}

function New-AttentionTestController([bool]$Enabled = $true, [scriptblock]$ProbeOverride = $null, [scriptblock]$QueueOverride = $null, $DesktopSource = $null) {
    Reset-AttentionRig
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:PollCount++; $script:NextPoll }
    $probe = if ($null -ne $ProbeOverride) { [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]$ProbeOverride }
        else { [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param() $script:ProbeCount++; New-FixtureM } }
    $queue = if ($null -ne $QueueOverride) { [System.Action[System.Threading.WaitCallback]]$QueueOverride }
        else { [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) } }
    $marshal = [System.Action[System.Action]]{
        param($a)
        $script:MarshalCount++
        $script:InsideMarshal = $true
        try { $a.Invoke() } finally { $script:InsideMarshal = $false }
    }
    $foreground = [Func[IntPtr]]{ param() $script:ForegroundHandle }
    $alive = [Func[IntPtr,bool]]{ param($h)
        $key = $h.ToInt64()
        if ($script:AliveOverrides.ContainsKey($key)) { return $script:AliveOverrides[$key] }
        return $true }
    $minimized = [Func[IntPtr,bool]]{ param($h)
        $key = $h.ToInt64()
        if ($script:MinimizedOverrides.ContainsKey($key)) { return $script:MinimizedOverrides[$key] }
        return $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) $script:RectFeed }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r)
            if (-not $script:InsideMarshal) { $script:FactoryCalls.Add('FACTORY-OUTSIDE-MARSHAL') }
            $script:FactoryCalls.Add('create ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r)
            if (-not $script:InsideMarshal) { $script:FactoryCalls.Add('FACTORY-OUTSIDE-MARSHAL') }
            $script:FactoryCalls.Add('restart ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:FactoryCalls.Add('tick ' + $h.ToInt64() + ' ' + ($r -join '/')) }), `
        ([System.Action[IntPtr]]{ param($h) $script:FactoryCalls.Add('stop ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:FactoryCalls.Add('hide ' + $h.ToInt64()) })
    $log = [System.Action[string]]{ param($line) $script:AttentionLog.Add($line) }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $DesktopSource, $Enabled
}

function Wait-AttentionTrue([scriptblock]$Condition, [int]$TimeoutMs = 8000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while (-not (& $Condition) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 20
    }
    return (& $Condition)
}

Describe 'AC-007 Controller: poll, consume, suppression, log lines (REQ-CTL-001, REQ-CTL-003)' {
    It 'one stop/hooks signal over fixture M logs matched=3 and creates exactly three overlays after the run' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        # SPEC-TRAY-019 AM-3: primary + one match line per matched window (hooks matches 4101/4102/4106).
        $script:AttentionLog.Count | Should Be 4
        $script:AttentionLog[0] | Should BeExactly 'attention: event=stop needle="hooks" matched=3'
        ($script:FactoryCalls -join '|') | Should BeExactly 'create 4101|create 4102|create 4106'
        $script:MarshalCount | Should Be 1
        ($script:FactoryCalls -contains 'FACTORY-OUTSIDE-MARSHAL') | Should Be $false
    }

    It 'an empty poll tick after a run writes no log line and makes no factory call' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        $script:AttentionLog.Clear()
        $script:FactoryCalls.Clear()
        $script:NextPoll = New-AttentionTestPollResult
        $controller.PollTick()
        $script:AttentionLog.Count | Should Be 0
        $script:FactoryCalls.Count | Should Be 0
    }

    It 'a rejected file logs its own single line beside the signal line' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult `
            @((New-AttentionTestSignal 'stop' 'pwsh')) `
            @((New-Object TerminalOrganizer.Core.Attention.AttentionRejectedFile -ArgumentList 'att-999999-z.json', 'version'))
        $controller.PollTick()
        # SPEC-TRAY-019 AM-3: rejected + primary + one match line (pwsh matches 4101 only).
        $script:AttentionLog.Count | Should Be 3
        $script:AttentionLog[0] | Should BeExactly 'attention: rejected att-999999-z.json: version'
        $script:AttentionLog[1] | Should BeExactly 'attention: event=stop needle="pwsh" matched=1'
    }

    It 'a stale deletion logs its 40000 ms line' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult `
            @() @() `
            @((New-Object TerminalOrganizer.Core.Attention.AttentionStaleFile -ArgumentList 'att-99996000-z.json', 40000))
        $controller.PollTick()
        $script:AttentionLog.Count | Should Be 1
        $script:AttentionLog[0] | Should BeExactly 'attention: stale att-99996000-z.json (40000 ms old; deleted)'
    }

    It 'a zero-match signal logs the taskbar-flash fallback line and creates no overlay' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'zzz'))
        $controller.PollTick()
        # SPEC-TRAY-019 AM-3: primary + one no-match line per session-bearing window
        # (the re-based fixture M has five: 4101/4102/4103/4105/4106).
        $script:AttentionLog.Count | Should Be 6
        $script:AttentionLog[0] | Should BeExactly 'attention: event=stop needle="zzz" matched=0 (no window; no tray notice)'
        $script:FactoryCalls.Count | Should Be 0
    }

    It 'while disabled the store is still consumed, no overlay is created, one suppressed line per signal' {
        $controller = New-AttentionTestController -Enabled $false
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'notification' 'hooks'))
        $controller.PollTick()
        $script:PollCount | Should Be 1
        $script:AttentionLog.Count | Should Be 1
        $script:AttentionLog[0] | Should BeExactly 'attention: suppressed (disabled) event=notification needle="hooks"'
        $script:FactoryCalls.Count | Should Be 0
    }
}

Describe 'AC-008 Single-flight and coalescing (REQ-CTL-002)' {
    It 'a second tick during an in-flight run only accumulates; completion marshals and starts one new run' {
        # The queue-work seam CAPTURES the run callbacks instead of executing them, so the
        # test controls when each run executes (the in-flight window is real controller
        # state; the production pool wiring is source-verified by AC-011).
        $script:QueuedRuns = New-Object 'System.Collections.Generic.List[System.Threading.WaitCallback]'
        $script:ProbeInside = $false
        $script:ProbeReentered = $false
        $trackingProbe = {
            param()
            if ($script:ProbeInside) { $script:ProbeReentered = $true }
            $script:ProbeInside = $true
            try { $script:ProbeCount++; New-FixtureM } finally { $script:ProbeInside = $false }
        }
        $capturingQueue = {
            param($cb)
            $script:QueuedRuns.Add($cb)
        }
        $controller = New-AttentionTestController -ProbeOverride $trackingProbe -QueueOverride $capturingQueue

        # tick 1 consumes signal A and queues run A (in flight: captured, not executed)
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        $script:QueuedRuns.Count | Should Be 1
        $script:ProbeCount | Should Be 0
        $script:MarshalCount | Should Be 0

        # tick 2 while the run for A is in flight: signal B only accumulates as pending
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'notification' 'wsl2'))
        $controller.PollTick()
        $script:QueuedRuns.Count | Should Be 1
        $script:ProbeCount | Should Be 0
        $script:MarshalCount | Should Be 0

        # release run A: it completes, marshals A's overlays, and starts one new run covering B
        $script:QueuedRuns[0].Invoke($null)
        $script:QueuedRuns.Count | Should Be 2
        $script:ProbeCount | Should Be 1
        $script:MarshalCount | Should Be 1
        ($script:AttentionLog -contains 'attention: event=stop needle="hooks" matched=3') | Should Be $true

        # B's run executes: exactly one more probe, one more marshal; the active 4101 restarts
        $script:QueuedRuns[1].Invoke($null)
        $script:ProbeCount | Should Be 2
        $script:MarshalCount | Should Be 2
        $script:ProbeReentered | Should Be $false
        ($script:AttentionLog -contains 'attention: event=notification needle="wsl2" matched=2') | Should Be $true
        ($script:AttentionLog -contains 'attention: overlay restarted hwnd=4101') | Should Be $true
        ($script:FactoryCalls -contains 'FACTORY-OUTSIDE-MARSHAL') | Should Be $false

        # a further tick with nothing pending queues nothing
        $script:NextPoll = New-AttentionTestPollResult
        $controller.PollTick()
        $script:QueuedRuns.Count | Should Be 2
        $controller.Dispose()
    }

    It 'a run whose probe throws logs one failure line and leaves the controller able to run again' {
        $script:ProbeThrowOnce = $true
        $throwingProbe = {
            param()
            $script:ProbeCount++
            if ($script:ProbeThrowOnce) {
                $script:ProbeThrowOnce = $false
                throw 'probe exploded'
            }
            New-FixtureM
        }
        $controller = New-AttentionTestController -ProbeOverride $throwingProbe
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        $script:AttentionLog.Count | Should Be 1
        $script:AttentionLog[0] | Should BeExactly 'attention: match run failed: probe exploded'
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        # SPEC-TRAY-019 AM-3: match-run-failed + primary + three match lines (hooks matches 4101/4102/4106).
        $script:AttentionLog.Count | Should Be 5
        $script:AttentionLog[1] | Should BeExactly 'attention: event=stop needle="hooks" matched=3'
        $controller.Dispose()
    }
}

Describe 'AC-009 Overlay lifecycle, no time cap (REQ-CTL-004)' {
    It 'D-10: a rect change between ticks stops the overlay immediately as moved (following superseded)' {
        # The M4-era row asserted the changed rect passed through to Tick (the follow
        # behavior). D-10 supersedes it: moving or resizing the target IS attention, so a
        # changed quad stops the ring with reason=moved and no further positioning happens.
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:FactoryCalls[0] | Should BeExactly 'create 4101'
        $script:RectFeed = @(100, 200, 900, 700)
        $controller.BlinkTick()
        $script:FactoryCalls[1] | Should BeExactly 'tick 4101 100/200/900/700'
        $script:AttentionLog.Clear()
        $script:RectFeed = @(150, 250, 950, 750)
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 150*' }).Count) | Should Be 0
        $script:FactoryCalls[-1] | Should BeExactly 'stop 4101'
        $script:AttentionLog.Count | Should Be 1
        $script:AttentionLog[0] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=moved'
        $controller.Dispose()
    }

    It 'D-10: unchanged ticks keep the overlay alive and blinking; a restart re-seeds the quad' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:RectFeed = @(100, 200, 900, 700)
        $controller.BlinkTick()
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 100/200/900/700' }).Count) | Should Be 2
        (@($script:FactoryCalls | Where-Object { $_ -like 'stop *' }).Count) | Should Be 0
        # a restart (new signal for the active handle) re-seeds: the rect changed to B is
        # read AT the restart, so the next B tick keeps blinking instead of stopping
        $script:RectFeed = @(150, 250, 950, 750)
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        (@($script:FactoryCalls | Where-Object { $_ -eq 'restart 4101' }).Count) | Should Be 1
        $script:AttentionLog.Clear()
        $script:FactoryCalls.Clear()
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 150/250/950/750' }).Count) | Should Be 1
        (@($script:FactoryCalls | Where-Object { $_ -like 'stop *' }).Count) | Should Be 0
        # a LATER change still stops it
        $script:RectFeed = @(160, 260, 960, 760)
        $controller.BlinkTick()
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=moved'
        $controller.Dispose()
    }

    It 'there is NO time cap: ticks far past any former 30 s cap keep blinking with no stop and no log' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:AttentionLog.Clear()
        for ($i = 0; $i -lt 130; $i++) { $controller.BlinkTick() }
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 *' }).Count) | Should Be 130
        (@($script:FactoryCalls | Where-Object { $_ -like 'stop *' }).Count) | Should Be 0
        $script:AttentionLog.Count | Should Be 0
        $controller.Dispose()
    }

    It 'a foreground tick at that same late time stops the overlay with the foreground reason' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        for ($i = 0; $i -lt 130; $i++) { $controller.BlinkTick() }
        $script:AttentionLog.Clear()
        $script:ForegroundHandle = [IntPtr]4101
        $controller.BlinkTick()
        $script:AttentionLog.Count | Should Be 1
        $script:AttentionLog[0] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=foreground'
        $script:FactoryCalls[-1] | Should BeExactly 'stop 4101'
        # silent steady state after the stop
        $script:AttentionLog.Clear()
        $script:FactoryCalls.Clear()
        $controller.BlinkTick()
        $script:AttentionLog.Count | Should Be 0
        $script:FactoryCalls.Count | Should Be 0
        $controller.Dispose()
    }

    It 'a dead target stops with reason closed; a minimized target stops with reason minimized' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:AliveOverrides[[long]4101] = $false
        $controller.BlinkTick()
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=closed'

        $controller2 = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller2.PollTick()
        $script:MinimizedOverrides[[long]4101] = $true
        $controller2.BlinkTick()
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=minimized'
        $controller.Dispose()
        $controller2.Dispose()
    }

    It 'a second signal for an active handle restarts the blink window instead of creating a second overlay' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'create 4101' }).Count) | Should Be 1
        (@($script:FactoryCalls | Where-Object { $_ -like 'restart 4101' }).Count) | Should Be 1
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay restarted hwnd=4101'
        # SPEC-TRAY-019 AM-3: the match detail line sits between the primary and the restart.
        $script:AttentionLog[-2] | Should BeExactly 'attention: match hwnd=4101 session-tab="Pwsh"'
        $script:AttentionLog[-3] | Should BeExactly 'attention: event=notification needle="pwsh" matched=1'
        # after the restart the overlay keeps blinking until a stop condition fires
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 *' }).Count) | Should Be 1
        $controller.Dispose()
    }

    It 'one signal matching two windows creates one overlay per handle; both stop independently' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'claude'))
        $controller.PollTick()
        ($script:FactoryCalls -join '|') | Should BeExactly 'create 4101|create 4102'
        $script:ForegroundHandle = [IntPtr]4101
        $controller.BlinkTick()
        $script:FactoryCalls[-1] | Should BeExactly 'stop 4101'
        # D-10 re-derivation: the rect change now stops 4102 as moved (the M4 row asserted
        # the changed rect ticked through; moving IS attention now)
        $script:ForegroundHandle = [IntPtr]::Zero
        $script:RectFeed = @(0, 0, 800, 600)
        $controller.BlinkTick()
        $script:FactoryCalls[-1] | Should BeExactly 'stop 4102'
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4102 reason=moved'
        $controller.Dispose()
    }

    It 'disabling stops every active overlay with the disabled reason' {
        $controller = New-AttentionTestController
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'claude'))
        $controller.PollTick()
        $script:AttentionLog.Clear()
        $controller.SetEnabled($false)
        (@($script:FactoryCalls | Where-Object { $_ -eq 'stop 4101' }).Count) | Should Be 1
        (@($script:FactoryCalls | Where-Object { $_ -eq 'stop 4102' }).Count) | Should Be 1
        (@($script:AttentionLog | Where-Object { $_ -like 'attention: overlay stopped hwnd=* reason=disabled' }).Count) | Should Be 2
        $controller.Dispose()
    }
}

Describe 'AC-010 Overlay geometry (REQ-OVL-001, pure part)' {
    $rows = @(
        @{ Rect = @(100, 200, 900, 700); Expected = '94,194,812,512' },
        @{ Rect = @(0, 0, 1920, 1080); Expected = '-6,-6,1932,1092' },
        @{ Rect = @(-1920, 0, -1, 1080); Expected = '-1926,-6,1931,1092' },
        @{ Rect = @(10, 10, 10, 10); Expected = '4,4,12,12' }
    )
    foreach ($row in $rows) {
        It ("target rect " + ($row.Rect -join ',') + " with ring thickness 6 yields overlay " + $row.Expected) {
            $overlay = [TerminalOrganizer.App.AttentionOverlayGeometry]::OverlayRect($row.Rect[0], $row.Rect[1], $row.Rect[2], $row.Rect[3], 6)
            ($overlay -join ',') | Should BeExactly $row.Expected
        }
    }

    It 'the geometry is a pure function: the same rect yields the same result twice' {
        $first = [TerminalOrganizer.App.AttentionOverlayGeometry]::OverlayRect(100, 200, 900, 700, 6)
        $second = [TerminalOrganizer.App.AttentionOverlayGeometry]::OverlayRect(100, 200, 900, 700, 6)
        ($first -join ',') | Should Be ($second -join ',')
    }
}

Describe 'AC-011 Static safety and wiring guards (REQ-OVL-002, REQ-CTL-001, REQ-CTL-002, NFR-7)' {
    $sourcePaths = @(
        (Join-Path $repoRoot 'src\TerminalOrganizer.Core\Attention\AttentionModels.cs'),
        (Join-Path $repoRoot 'src\TerminalOrganizer.Core\Attention\AttentionSignalParser.cs'),
        (Join-Path $repoRoot 'src\TerminalOrganizer.Core\Attention\AttentionSignalStore.cs'),
        (Join-Path $repoRoot 'src\TerminalOrganizer.Core\Attention\AttentionMatcher.cs'),
        (Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'),
        (Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'),
        (Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionWindowProbe.cs')
    )
    $banned = @('SetForegroundWindow', 'SetActiveWindow', 'AttachThreadInput', 'FileSystemWatcher',
        'ReadDirectoryChangesW', '.Focus(', '.Activate(', 'Process.Start')
    foreach ($path in $sourcePaths) {
        $name = [IO.Path]::GetFileName($path)
        $lines = [IO.File]::ReadAllLines($path)
        foreach ($token in $banned) {
            It ("$name contains no banned token '$token'") {
                @($lines | Where-Object { $_.Contains($token) }).Count | Should Be 0
            }
        }
        It "$name positions only through the no-activate flag: every SetWindowPos line carries SWP_NOACTIVATE" {
            $offenders = @($lines | Where-Object { $_.Contains('SetWindowPos') -and $_ -notmatch '(?i)SWP_NOACTIVATE|SwpNoactivate' })
            $offenders.Count | Should Be 0
        }
        foreach ($token in @('MoveWindow', '.Location =', '.Size =', '.Bounds =')) {
            It ("$name contains no other positioning API '$token'") {
                @($lines | Where-Object { $_.Contains($token) }).Count | Should Be 0
            }
        }
    }

    It 'the overlay source pins SW_SHOWNOACTIVATE and applies the three ex-style values in CreateParams' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'))
        $text.Contains('SwShownoactivate') | Should Be $true
        $text.Contains('= 4') | Should Be $true
        $text.Contains('0x08000000') | Should Be $true
        $text.Contains('0x00000080') | Should Be $true
        $text.Contains('0x00000020') | Should Be $true
        $text.Contains('CreateParams') | Should Be $true
    }

    It 'the controller source carries the production queue-work and marshal wiring' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'))
        $text.Contains('ThreadPool.QueueUserWorkItem') | Should Be $true
        $text.Contains('BeginInvoke') | Should Be $true
    }
}

Describe 'Production clock (live-smoke fix: epoch ms, not ticks-ms)' {
    It 'the production clock returns a plausible present-day Unix epoch in milliseconds' {
        # A ms-since-YEAR-1 value (~6.4e13, the live-smoke regression) fails this window;
        # real epoch ms for 2020..2035 stays inside 1.6e12..2.1e12.
        $clock = [TerminalOrganizer.App.AttentionController]::UtcNowEpochMs()
        ($clock -gt 1600000000000) | Should Be $true
        ($clock -lt 2100000000000) | Should Be $true
    }
}

Describe 'Post-audit fix A: the overlay rect hugs the visible frame (DWM bounds, GetWindowRect fallback)' {
    # The auditor's measured reproduction (repro-rect-delta.log, 11/11 windows at 100% DPI):
    # GetWindowRect sticks +7 px out on LEFT/RIGHT/BOTTOM vs the visible DWM frame bounds.
    It 'a successful DWM frame-bounds read is the rect used; GetWindowRect is not consulted' {
        $script:FixADwmCalls = 0
        $script:FixARectCalls = 0
        $dwm = [Func[IntPtr,int[]]]{ param($h) $script:FixADwmCalls++; @(1411, 5, 1915, 1027) }
        $rect = [Func[IntPtr,int[]]]{ param($h) $script:FixARectCalls++; @(1404, 5, 1922, 1034) }
        $result = [TerminalOrganizer.App.AttentionWindowProbe]::TargetRect(([IntPtr]722684), $dwm, $rect)
        ($result -join ',') | Should BeExactly '1411,5,1915,1027'
        $script:FixADwmCalls | Should Be 1
        $script:FixARectCalls | Should Be 0
    }

    It 'a failed DWM read (null) falls back to the GetWindowRect rect' {
        $rect = [Func[IntPtr,int[]]]{ param($h) @(1404, 5, 1922, 1034) }
        $result = [TerminalOrganizer.App.AttentionWindowProbe]::TargetRect(([IntPtr]722684), $null, $rect)
        ($result -join ',') | Should BeExactly '1404,5,1922,1034'
    }

    It 'a throwing DWM read degrades to the GetWindowRect fallback, never an exception' {
        $dwm = [Func[IntPtr,int[]]]{ param($h) throw 'dwm unavailable' }
        $rect = [Func[IntPtr,int[]]]{ param($h) @(1404, 5, 1922, 1034) }
        $result = [TerminalOrganizer.App.AttentionWindowProbe]::TargetRect(([IntPtr]722684), $dwm, $rect)
        ($result -join ',') | Should BeExactly '1404,5,1922,1034'
    }
}

# Post-audit fix B fake: an IDesktopSource whose current-desktop answer is scripted
# (the B4FakeHelper pattern -- PS class, compiled, invoked by the controller directly).
try {
    if (-not ('AttentionDesktopFake' -as [type])) {
        Invoke-Expression @'
    class AttentionDesktopFake : TerminalOrganizer.Core.Monitors.IDesktopSource {
        [System.Collections.Hashtable]$State
        AttentionDesktopFake([System.Collections.Hashtable]$s) { $this.State = $s }
        [TerminalOrganizer.Core.Monitors.DesktopReadResult] TryReadWin10SessionValue() { return [TerminalOrganizer.Core.Monitors.DesktopReadResult]::Failed() }
        [TerminalOrganizer.Core.Monitors.DesktopReadResult] TryReadWin11Value() { return [TerminalOrganizer.Core.Monitors.DesktopReadResult]::Failed() }
        [TerminalOrganizer.Core.Monitors.DesktopIdResult] GetWindowDesktopId([IntPtr]$window) { return [TerminalOrganizer.Core.Monitors.DesktopIdResult]::Failure('unused') }
        [TerminalOrganizer.Core.Monitors.DesktopFlagResult] IsWindowOnCurrentVirtualDesktop([IntPtr]$window) {
            $this.State['Calls'] = [int]$this.State['Calls'] + 1
            if (-not [bool]$this.State['Success']) { return [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Failure([string]$this.State['Error']) }
            return [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok([bool]$this.State['OnCurrent'])
        }
    }
'@
    }
}
catch { }

Describe 'Post-audit fix B: the overlay follows the target virtual desktop' {
    It 'an off-desktop target hides its ring without stopping the overlay' {
        $state = @{ Success = $true; OnCurrent = $false; Calls = 0; Error = '' }
        $desktop = [AttentionDesktopFake]::new($state)
        $controller = New-AttentionTestController -DesktopSource $desktop
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:FactoryCalls.Clear()
        $script:AttentionLog.Clear()
        $controller.BlinkTick()
        ($script:FactoryCalls -contains 'hide 4101') | Should Be $true
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 *' }).Count) | Should Be 0
        (@($script:FactoryCalls | Where-Object { $_ -like 'stop *' }).Count) | Should Be 0
        $script:AttentionLog.Count | Should Be 0
        $state['Calls'] | Should Be 1
        $controller.Dispose()
    }

    It 'back on the desktop the ring reappears on the very next tick, and focus still stops it' {
        $state = @{ Success = $true; OnCurrent = $false; Calls = 0; Error = '' }
        $desktop = [AttentionDesktopFake]::new($state)
        $controller = New-AttentionTestController -DesktopSource $desktop
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 *' }).Count) | Should Be 0
        $state['OnCurrent'] = $true
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 *' }).Count) | Should Be 1
        # the until-focus semantics are unchanged: after the switch back, focus stops it
        $script:ForegroundHandle = [IntPtr]4101
        $controller.BlinkTick()
        $script:FactoryCalls[-1] | Should BeExactly 'stop 4101'
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=foreground'
        $controller.Dispose()
    }

    It 'a desktop-query failure keeps the ring visible and logs exactly one line per handle' {
        $state = @{ Success = $false; OnCurrent = $false; Calls = 0; Error = 'boom' }
        $desktop = [AttentionDesktopFake]::new($state)
        $controller = New-AttentionTestController -DesktopSource $desktop
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:AttentionLog.Clear()
        $controller.BlinkTick()
        $controller.BlinkTick()
        (@($script:FactoryCalls | Where-Object { $_ -like 'tick 4101 *' }).Count) | Should Be 2
        (@($script:AttentionLog | Where-Object { $_ -like 'attention: desktop check failed*' }).Count) | Should Be 1
        $script:AttentionLog[-1] | Should BeExactly 'attention: desktop check failed hwnd=4101 (boom); overlay kept visible'
        $controller.Dispose()
    }

    It 'D-10: a rect change while off-desktop stops the overlay as moved (any stop wins over the desktop gate)' {
        $state = @{ Success = $true; OnCurrent = $false; Calls = 0; Error = '' }
        $desktop = [AttentionDesktopFake]::new($state)
        $controller = New-AttentionTestController -DesktopSource $desktop
        $script:NextPoll = New-AttentionTestPollResult @((New-AttentionTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $script:RectFeed = @(100, 200, 900, 700)
        $controller.BlinkTick()
        ($script:FactoryCalls -contains 'hide 4101') | Should Be $true
        (@($script:FactoryCalls | Where-Object { $_ -like 'stop *' }).Count) | Should Be 0
        $script:RectFeed = @(150, 250, 950, 750)
        $controller.BlinkTick()
        $script:FactoryCalls[-1] | Should BeExactly 'stop 4101'
        $script:AttentionLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=moved'
        $controller.Dispose()
    }
}

Describe 'Post-audit fix round 2: the form is sized from extents (R-L, B-T), never the raw right/bottom' {
    # Live-measured regression (repro-overlay-pos.{ps1,log}): the target DWM frame quad
    # (474, 5, 940, 1027) reached the SetWindowPos (x, y, cx, cy) slots unchanged, so the
    # ring landed at (474, 5) sized 940x1027 -- R in cx, B in cy, 474 px over the neighbor.
    It 'PlaceRect converts the target quad with thickness 6 to inflated x, y and EXTENTS' {
        $place = [TerminalOrganizer.App.AttentionOverlayGeometry]::PlaceRect(@(100, 200, 900, 700), 6)
        ($place -join ',') | Should BeExactly '94,194,812,512'
    }

    It 'PlaceRect pins the live-measured case: extents, not the raw right and bottom' {
        $place = [TerminalOrganizer.App.AttentionOverlayGeometry]::PlaceRect(@(474, 5, 940, 1027), 6)
        # Extents: 478 = (940-474)+12, 1034 = (1027-5)+12 -- the buggy raw pass-through
        # would read 940/1027 and grow the ring by the target's own origin.
        ($place -join ',') | Should BeExactly '468,-1,478,1034'
    }

    It 'PlaceRect degrades a null or short quad to zeros, never throws' {
        $nullPlace = [TerminalOrganizer.App.AttentionOverlayGeometry]::PlaceRect($null, 6)
        ($nullPlace -join ',') | Should BeExactly '0,0,0,0'
        $shortPlace = [TerminalOrganizer.App.AttentionOverlayGeometry]::PlaceRect(@(1, 2), 6)
        ($shortPlace -join ',') | Should BeExactly '0,0,0,0'
    }

    It 'PlaceRect delegates to the AC-010 helper, so the pinned geometry stays the single live source' {
        # The round-2 root cause was a correct-but-dead helper: nothing in the live path
        # called OverlayRect. PlaceRect IS the wiring -- this row pins that its math is the
        # AC-010 helper's math, so the two can never drift and OverlayRect can never go dead.
        $delegated = [TerminalOrganizer.App.AttentionOverlayGeometry]::PlaceRect(@(474, 5, 940, 1027), 6)
        $pinned = [TerminalOrganizer.App.AttentionOverlayGeometry]::OverlayRect(474, 5, 940, 1027, 6)
        ($delegated -join ',') | Should BeExactly ($pinned -join ',')
        $delegatedSecond = [TerminalOrganizer.App.AttentionOverlayGeometry]::PlaceRect(@(-1920, 0, -1, 1080), 6)
        $pinnedSecond = [TerminalOrganizer.App.AttentionOverlayGeometry]::OverlayRect(-1920, 0, -1, 1080, 6)
        ($delegatedSecond -join ',') | Should BeExactly ($pinnedSecond -join ',')
    }

    It 'AC-011-style guard: the LIVE path consumes the tested helper at the sizing call site' {
        $overlayPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'
        $lines = [IO.File]::ReadAllLines($overlayPath)
        $callLines = @($lines | Where-Object { $_.Contains('Native.SetWindowPos(') })
        $callLines.Count | Should Be 1
        # The sizing line must CONSUME the conversion result (place[ slots), never a raw
        # rect[ slot -- the exact shape of the live-measured regression.
        @($callLines | Where-Object { $_ -notmatch 'place\[' }).Count | Should Be 0
        @($callLines | Where-Object { $_.Contains('rect[') }).Count | Should Be 0
        # The helper is WIRED, not merely correct in isolation: a live assignment call of
        # PlaceRect must exist in the form (a comment-only reference cannot satisfy this).
        @($lines | Where-Object { $_.Contains('= AttentionOverlayGeometry.PlaceRect(') }).Count |
            Should BeGreaterThan 0
    }
}

Describe 'Post-audit fix round 3 (D-6): the ring rides just above the target, never topmost' {
    # User decision D-6 (the user's words are quoted verbatim in progress.md E.4; this file
    # stays pure ASCII per the BOM rule): the overlay must NOT be topmost -- a covering
    # window must cover the ring too. Default z-order: directly above the TARGET window.
    It 'D-6 guard: no topmost token anywhere in the overlay source' {
        $overlayPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'
        $lines = [IO.File]::ReadAllLines($overlayPath)
        foreach ($token in @('HwndTopmost', 'HWND_TOPMOST', 'WsExTopmost', 'WS_EX_TOPMOST', '0x00000008')) {
            @($lines | Where-Object { $_.Contains($token) }).Count | Should Be 0
        }
    }

    It 'D-6 guard: the sizing call inserts the ring directly above the TARGET window' {
        $overlayPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'
        $lines = [IO.File]::ReadAllLines($overlayPath)
        $callLines = @($lines | Where-Object { $_.Contains('Native.SetWindowPos(') })
        $callLines.Count | Should Be 1
        # The hWndInsertAfter slot must be the target handle (word boundary: target, not
        # targetRect) so every positioning path re-asserts just-above-target z-order.
        @($callLines | Where-Object { $_ -notmatch '\btarget\b' }).Count | Should Be 0
        # The round-2 extents guard still holds on the same line.
        @($callLines | Where-Object { $_ -notmatch 'place\[' }).Count | Should Be 0
    }
}

