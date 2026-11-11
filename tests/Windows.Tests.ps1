# SPEC-WIN-004 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md and plan.md section J, never from the code under test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$dllPath = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'

# Byte-load keeps the DLL file unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dllPath))

# Pinned command lines (plan.md J.1, from product.md recorded shapes) and titles (J.2).
$CMD_LOCAL = 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1 20'
$CMD_REMOTE = 'wsl.exe -d Ubuntu --exec /tmp/rdl_attach.sh user@host YODA2'
$CMD_NATIVE = 'powershell.exe -NoProfile -Command "& { $env:LAUNCHER_SESSION=''OPS1''; Get-Date }"'
$CMD_NATIVE_DQ = 'powershell.exe -NoProfile -Command "& { $env:LAUNCHER_SESSION="OPS9"; Get-Date }"'
$CMD_LOCAL_EXTRA = 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1 EXTRA'
$CMD_LOCAL_INTERVENING = 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach EXTRA YODA1'
$CMD_CMD_EXE = 'cmd.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach NOPE'
$CMD_WSL_LIST = 'wsl.exe --list'

function Strip-Title([string]$Title) {
    [TerminalOrganizer.Core.Windows.TitleNormalizer]::StripPrefix($Title)
}

function New-ChildProcess([string]$Image, [string]$CommandLine) {
    New-Object TerminalOrganizer.Core.Windows.ChildProcess -ArgumentList $Image, $CommandLine
}

function Classify-Line([string]$Image, [string]$CommandLine) {
    [TerminalOrganizer.Core.Windows.CommandLineClassifier]::Classify($Image, $CommandLine)
}

function Classify-All($Processes) {
    [TerminalOrganizer.Core.Windows.CommandLineClassifier]::ClassifyAll($Processes)
}

Describe 'AC-001 Prefix stripping' {
    It 'strips exactly one leading prefix per the pinned rows' {
        $rows = @(
            @('OC_YODA1', 'YODA1'),
            @('WD_AB_X', 'AB_X'),
            @('Plain Title', 'Plain Title'),
            @('oc_yoda1', 'oc_yoda1'),
            @('XY_YODA1', 'XY_YODA1')
        )
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $actual = Strip-Title $rows[$i][0]
            ('row {0} [{1}] -> [{2}] expected [{3}]' -f $i, $rows[$i][0], $actual, $rows[$i][1]) |
                Should BeExactly ('row {0} [{1}] -> [{2}] expected [{2}]' -f $i, $rows[$i][0], $rows[$i][1])
        }
    }

    It 'a second prefix survives: NG_AB_X strips to AB_X, not X' {
        Strip-Title 'NG_AB_X' | Should BeExactly 'AB_X'
        Strip-Title 'NG_AB_X' | Should Not BeExactly 'X'
    }
}

# --- C1: declared-rank title grammar (night-design-2026-09-25 unit C1) ---
# Grammar: [OHNW][CGDA] + optional single digit + '_', then a NON-EMPTY session title.

Describe 'C1 declared-rank title grammar' {
    It 'C1 parses legacy prefix without rank' {
        $n = [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse('OC_YODA1')
        $n.Original | Should BeExactly 'OC_YODA1'
        $n.SessionTitle | Should BeExactly 'YODA1'
        $n.PrefixPresent | Should Be $true
        $n.DeclaredRank | Should BeNullOrEmpty
    }

    It 'C1 parses HG2 rank token' {
        $n = [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse('HG2_YODA1')
        $n.SessionTitle | Should BeExactly 'YODA1'
        $n.PrefixPresent | Should Be $true
        $n.DeclaredRank | Should Be 2
    }

    It 'C1 parses the Antigravity model letter A (launcher v0.59.0 agyD)' {
        $n = [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse('OA_YODA1')
        $n.SessionTitle | Should BeExactly 'YODA1'
        $n.PrefixPresent | Should Be $true
        $n.DeclaredRank | Should BeNullOrEmpty
        $n = [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse('HA2_YODA1')
        $n.SessionTitle | Should BeExactly 'YODA1'
        $n.DeclaredRank | Should Be 2
        # A lowercase or unknown model letter still does not count as a prefix.
        foreach ($bad in @('Oa_YODA1', 'OB_YODA1')) {
            [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse($bad).PrefixPresent | Should Be $false
        }
    }

    It 'C1 strips exactly one prefix' {
        $n = [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse('HG2_OC_YODA1')
        $n.SessionTitle | Should BeExactly 'OC_YODA1'
        $n.DeclaredRank | Should Be 2
        # StripPrefix delegates to Parse: matcher consumers see the same strip.
        Strip-Title 'HG2_OC_YODA1' | Should BeExactly 'OC_YODA1'
        Strip-Title 'HG2_YODA1' | Should BeExactly 'YODA1'
    }

    It 'C1 rejects lowercase and malformed rank' {
        # hg2_ lowercase family; HG10_ multi-digit; HGx_ non-digit rank; HG2 no underscore;
        # HG2_/OC_ empty session title after the prefix (invalid, never stripped).
        foreach ($bad in @('hg2_', 'HG10_', 'HGx_', 'HG2', 'HG2_', 'OC_')) {
            $n = [TerminalOrganizer.Core.Windows.TitleNormalizer]::Parse($bad)
            ('[{0}] prefixPresent={1}' -f $bad, $n.PrefixPresent) | Should BeExactly ('[{0}] prefixPresent=False' -f $bad)
            $n.SessionTitle | Should BeExactly $bad
            $n.DeclaredRank | Should BeNullOrEmpty
        }
    }
}

Describe 'AC-002 Classification' {
    It 'the three section J.1 command lines classify to Local/YODA1, Remote/YODA2, WindowsNative/OPS1' {
        $rows = @(
            @('wsl.exe', $CMD_LOCAL, 'Local', 'YODA1'),
            @('wsl.exe', $CMD_REMOTE, 'Remote', 'YODA2'),
            @('powershell.exe', $CMD_NATIVE, 'WindowsNative', 'OPS1')
        )
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $record = Classify-Line $rows[$i][0] $rows[$i][1]
            if ($null -eq $record) {
                ('row {0}: null' -f $i) | Should BeExactly ('row {0}: kind={1} session={2}' -f $i, $rows[$i][2], $rows[$i][3])
            }
            else {
                ('row {0}: kind={1} session={2}' -f $i, $record.Kind.ToString(), $record.Name) |
                    Should BeExactly ('row {0}: kind={1} session={2}' -f $i, $rows[$i][2], $rows[$i][3])
            }
        }
    }

    It 'LAUNCHER_SESSION with double quotes captures OPS9' {
        $record = Classify-Line 'powershell.exe' $CMD_NATIVE_DQ
        $record | Should Not BeNullOrEmpty
        $record.Kind.ToString() | Should BeExactly 'WindowsNative'
        $record.Name | Should BeExactly 'OPS9'
    }

    It 'tokens after the session are tolerated: --attach YODA1 EXTRA stays Local/YODA1' {
        $record = Classify-Line 'wsl.exe' $CMD_LOCAL_EXTRA
        $record | Should Not BeNullOrEmpty
        $record.Kind.ToString() | Should BeExactly 'Local'
        $record.Name | Should BeExactly 'YODA1'
    }

    It 'the session is the token immediately after --attach: --attach EXTRA YODA1 gives Local/EXTRA' {
        $record = Classify-Line 'wsl.exe' $CMD_LOCAL_INTERVENING
        $record | Should Not BeNullOrEmpty
        $record.Kind.ToString() | Should BeExactly 'Local'
        $record.Name | Should BeExactly 'EXTRA'
    }

    It 'cmd.exe invoking the launcher shape gives null (image must be wsl.exe)' {
        Classify-Line 'cmd.exe' $CMD_CMD_EXE | Should BeNullOrEmpty
    }

    It 'wsl.exe --list gives null' {
        Classify-Line 'wsl.exe' $CMD_WSL_LIST | Should BeNullOrEmpty
    }
}

Describe 'AC-003 Verbatim capture and dedupe' {
    It 'the Local record carries the full command line byte-for-byte, including the trailing 20' {
        $record = Classify-Line 'wsl.exe' $CMD_LOCAL
        $record | Should Not BeNullOrEmpty
        $record.CommandLine | Should BeExactly $CMD_LOCAL
        $record.CommandLine.EndsWith(' 20') | Should Be $true
    }

    It 'two Local records for YODA1 keep the FIRST command line and yield one session' {
        $first = New-ChildProcess 'wsl.exe' $CMD_LOCAL
        $second = New-ChildProcess 'wsl.exe' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1 99'
        $records = Classify-All @($first, $second)
        $records.Length | Should Be 1
        $records[0].Name | Should BeExactly 'YODA1'
        $records[0].CommandLine | Should BeExactly $CMD_LOCAL
    }
}

Describe 'AC-004 Tolerance' {
    It 'empty, whitespace-only and binary-noise command lines return null without throwing' {
        $noise = -join (1..16 | ForEach-Object { [char]$_ })
        foreach ($bad in @('', "`t  `r`n ", $noise)) {
            $caught = $null
            $record = $null
            try { $record = Classify-Line 'wsl.exe' $bad } catch { $caught = $_ }
            $caught | Should BeNullOrEmpty
            $record | Should BeNullOrEmpty
        }
    }

    It 'a null command line and a null image return null without throwing' {
        $caught = $null
        $record = $null
        try { $record = Classify-Line $null $null } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        $record | Should BeNullOrEmpty
    }
}

function New-SessionRecord([string]$Name, [string]$Kind, [string]$CommandLine) {
    $kindEnum = [TerminalOrganizer.Core.Windows.SessionKind]::Parse([TerminalOrganizer.Core.Windows.SessionKind], $Kind)
    New-Object TerminalOrganizer.Core.Windows.SessionRecord -ArgumentList $Name, $kindEnum, $CommandLine
}

# The standing session set (acceptance.md Conventions): YODA1 Local, YODA2 Remote, OPS1 WindowsNative.
function New-StandingSessions {
    @(
        (New-SessionRecord 'YODA1' 'Local' $CMD_LOCAL),
        (New-SessionRecord 'YODA2' 'Remote' $CMD_REMOTE),
        (New-SessionRecord 'OPS1' 'WindowsNative' $CMD_NATIVE)
    )
}

function Match-Window($Titles, $Sessions) {
    [TerminalOrganizer.Core.Windows.SessionMatcher]::Match([string[]]$Titles, $Sessions)
}

Describe 'AC-005 Window-session matching' {
    It 'W1[OC_YODA1] is identified with tab 0 matched to YODA1' {
        $result = Match-Window @('OC_YODA1') (New-StandingSessions)
        $result.Identified | Should Be $true
        $result.Tabs.Length | Should Be 1
        $result.Tabs[0].Session | Should Not BeNullOrEmpty
        $result.Tabs[0].Session.Name | Should BeExactly 'YODA1'
        $result.UnmatchedTitles.Length | Should Be 0
    }

    It 'W2[NG_AB_X, HC_YODA2]: tab 0 strips to AB_X and is UNMATCHED, tab 1 matches YODA2, window unidentified with AB_X listed' {
        $result = Match-Window @('NG_AB_X', 'HC_YODA2') (New-StandingSessions)
        $result.Tabs.Length | Should Be 2
        $result.Tabs[0].StrippedTitle | Should BeExactly 'AB_X'
        $result.Tabs[0].Matched | Should Be $false
        $result.Tabs[0].Session | Should BeNullOrEmpty
        $result.Tabs[1].Session | Should Not BeNullOrEmpty
        $result.Tabs[1].Session.Name | Should BeExactly 'YODA2'
        $result.Identified | Should Be $false
        $result.UnmatchedTitles.Length | Should Be 1
        $result.UnmatchedTitles[0] | Should BeExactly 'AB_X'
    }

    It 'W3[✳ Claude Code] is unidentified with the unmatched title listed' {
        $result = Match-Window @('✳ Claude Code') (New-StandingSessions)
        $result.Identified | Should Be $false
        $result.UnmatchedTitles.Length | Should Be 1
        $result.UnmatchedTitles[0] | Should BeExactly '✳ Claude Code'
    }

    It 'matching does not mutate the input title or session arrays, and tab order is preserved' {
        $sessions = New-StandingSessions
        $titles = [string[]]@('NG_AB_X', 'HC_YODA2')
        $titlesBefore = ($titles -join '|')
        $sessionsBefore = ($sessions | ForEach-Object { $_.Name }) -join '|'
        $result = Match-Window $titles $sessions
        ($titles -join '|') | Should BeExactly $titlesBefore
        (($sessions | ForEach-Object { $_.Name }) -join '|') | Should BeExactly $sessionsBefore
        $result.Tabs[0].Title | Should BeExactly 'NG_AB_X'
        $result.Tabs[1].Title | Should BeExactly 'HC_YODA2'
    }
}

Describe 'AC-006 Merge eligibility' {
    It 'W1 (single tab, identified, Local) is mergeable' {
        $result = Match-Window @('OC_YODA1') (New-StandingSessions)
        $result.Mergeable | Should Be $true
    }

    It 'a single-tab window hosting OPS1 (WindowsNative) is not mergeable' {
        $result = Match-Window @('NC_OPS1') (New-StandingSessions)
        $result.Identified | Should Be $true
        $result.Tabs[0].Session.Name | Should BeExactly 'OPS1'
        $result.Mergeable | Should Be $false
    }

    It 'a single-tab unidentified window is not mergeable' {
        $result = Match-Window @('WD_AB_X') (New-StandingSessions)
        $result.Identified | Should Be $false
        $result.Mergeable | Should Be $false
    }

    It 'a two-tab identified window [OC_YODA1, HC_YODA2] is not mergeable (multi-tab)' {
        $result = Match-Window @('OC_YODA1', 'HC_YODA2') (New-StandingSessions)
        $result.Identified | Should Be $true
        $result.Mergeable | Should Be $false
    }
}

function New-TabSuccess([string[]]$Titles) {
    [TerminalOrganizer.Core.Windows.TabTitleResult]::Ok($Titles)
}

function New-AcquiredWindow($Handle, $Titles, $Monitor, $Desktop) {
    $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new($Handle, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', 'fixture')
    New-Object TerminalOrganizer.Core.Windows.AcquiredWindow -ArgumentList $identity, $Titles, $Monitor, $Desktop
}

function New-TestMonitor {
    $wa = New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList 0, 0, 1920, 1200, 96
    New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList '\\?\PATH', 'DELA07B', 'INST', 'SER', 2, 0, 0, 1920, 1200, $wa
}

function Compose-Snapshots($Acquired, $Sessions) {
    [TerminalOrganizer.Core.Windows.WindowSnapshotBuilder]::Compose($Acquired, $Sessions)
}

Describe 'AC-007 Wrapper surface and degradation' {
    It 'the built DLL exposes Win32WindowEnumerator, UiaTabTitleReader and ProcessSessionQuery, constructed with dependencies as parameters' {
        $enum = New-Object TerminalOrganizer.Core.Windows.Win32WindowEnumerator
        ($enum -is [TerminalOrganizer.Core.Windows.Win32WindowEnumerator]) | Should Be $true
        $reader = New-Object TerminalOrganizer.Core.Windows.UiaTabTitleReader
        ($reader -is [TerminalOrganizer.Core.Windows.UiaTabTitleReader]) | Should Be $true
        $query = New-Object TerminalOrganizer.Core.Windows.ProcessSessionQuery
        ($query -is [TerminalOrganizer.Core.Windows.ProcessSessionQuery]) | Should Be $true
        $seamReader = New-Object TerminalOrganizer.Core.Windows.UiaTabTitleReader -ArgumentList ([Func[IntPtr,string]]{ param($h) 'SEAM' })
        ($seamReader -is [TerminalOrganizer.Core.Windows.UiaTabTitleReader]) | Should Be $true
    }

    It 'a UIA failure path returns a failure result carrying the injected GetWindowText fallback title, never an exception' {
        $fallback = [Func[IntPtr,string]]{ param($h) 'FALLBACK-TITLE' }
        $reader = New-Object TerminalOrganizer.Core.Windows.UiaTabTitleReader -ArgumentList $fallback
        $caught = $null
        $result = $null
        try { $result = $reader.ReadTabs([IntPtr]::Zero) } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        $result | Should Not BeNullOrEmpty
        $result.Success | Should Be $false
        $result.FallbackTitle | Should BeExactly 'FALLBACK-TITLE'
    }

    It 'a WMI query for a pid set with no matching children returns an empty set, never an exception' {
        $query = New-Object TerminalOrganizer.Core.Windows.ProcessSessionQuery
        $caught = $null
        $children = $null
        try { $children = $query.QueryChildren(@(999999)) } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        @($children).Length | Should Be 0
        $query.QueryChildren(@()).Length | Should Be 0
    }

    It 'an enumeration with a bogus pid set, a null desktop reader and a null monitor set yields zero windows, never an exception' {
        $enum = New-Object TerminalOrganizer.Core.Windows.Win32WindowEnumerator
        $caught = $null
        $windows = $null
        try { $windows = $enum.Enumerate(@(-1), $null, $null) } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        @($windows).Length | Should Be 0
    }
}

Describe 'AC-008 Snapshot composition' {
    It 'fake acquisition outputs compose into three ordered snapshots with AC-005 identification, AC-006 eligibility and passed-through attribution' {
        $mon = New-TestMonitor
        $desktop = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true)
        $sessions = Classify-All @(
            (New-ChildProcess 'wsl.exe' $CMD_LOCAL),
            (New-ChildProcess 'wsl.exe' $CMD_REMOTE),
            (New-ChildProcess 'powershell.exe' $CMD_NATIVE)
        )
        $acquired = @(
            (New-AcquiredWindow ([IntPtr]101) (New-TabSuccess @('OC_YODA1')) $mon $desktop),
            (New-AcquiredWindow ([IntPtr]102) (New-TabSuccess @('NG_AB_X', 'HC_YODA2')) $mon $desktop),
            (New-AcquiredWindow ([IntPtr]103) (New-TabSuccess @('✳ Claude Code')) $mon $desktop)
        )
        $shots = Compose-Snapshots $acquired $sessions
        $shots.Length | Should Be 3
        $shots[0].Handle | Should Be ([IntPtr]101)
        $shots[0].Identified | Should Be $true
        $shots[0].Mergeable | Should Be $true
        $shots[0].Tabs[0].Session.Name | Should BeExactly 'YODA1'
        $shots[1].Handle | Should Be ([IntPtr]102)
        $shots[1].Identified | Should Be $false
        $shots[1].UnmatchedTitles[0] | Should BeExactly 'AB_X'
        $shots[1].Mergeable | Should Be $false
        $shots[2].Handle | Should Be ([IntPtr]103)
        $shots[2].Identified | Should Be $false
        $shots[2].UnmatchedTitles[0] | Should BeExactly '✳ Claude Code'
        $shots[2].Mergeable | Should Be $false
        ([object]::ReferenceEquals($shots[0].Monitor, $mon)) | Should Be $true
        $shots[0].DesktopStatus.Success | Should Be $true
        $shots[0].DesktopStatus.Value | Should Be $true
    }

    It 'a UIA failure result composes to a single fallback-title tab, keeping the window placed and classifiable' {
        $mon = New-TestMonitor
        $desktop = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true)
        $sessions = Classify-All @((New-ChildProcess 'wsl.exe' $CMD_LOCAL))
        $failed = [TerminalOrganizer.Core.Windows.TabTitleResult]::Failure('OC_YODA1', 'simulated UIA failure')
        $acquired = @((New-AcquiredWindow ([IntPtr]201) $failed $mon $desktop))
        $shots = Compose-Snapshots $acquired $sessions
        $shots.Length | Should Be 1
        $shots[0].Tabs.Length | Should Be 1
        $shots[0].Tabs[0].Title | Should BeExactly 'OC_YODA1'
        $shots[0].Identified | Should Be $true
        $shots[0].Mergeable | Should Be $false
        $shots[0].TabReadQuality.ToString() | Should BeExactly 'Fallback'
    }
}

Describe 'A1 incomplete and synthetic acquisition' {
    It 'A3 a shared desktop session serves two windows and disposes exactly once' {
        if (-not ('A3DesktopSession' -as [type])) {
            Add-Type -ReferencedAssemblies $dllPath -TypeDefinition @'
using System;
using TerminalOrganizer.Core.Monitors;
public sealed class A3DesktopSession : IWindowDesktopSession {
    public int Queries;
    public int Disposals;
    public DesktopFlagResult IsWindowOnCurrentVirtualDesktop(IntPtr window) { Queries++; return DesktopFlagResult.Ok(true); }
    public DesktopIdResult GetWindowDesktopId(IntPtr window) { return DesktopIdResult.Ok(Guid.Empty); }
    public void Dispose() { Disposals++; }
}
'@
        }
        $fake = New-Object A3DesktopSession
        $source = [TerminalOrganizer.Core.Monitors.WindowDesktopSessionSource]::new($fake)
        $source.IsWindowOnCurrentVirtualDesktop([IntPtr]1).Value | Should Be $true
        $source.IsWindowOnCurrentVirtualDesktop([IntPtr]2).Value | Should Be $true
        $source.Dispose()
        $source.Dispose()
        $fake.Queries | Should Be 2
        $fake.Disposals | Should Be 1
        $source.IsWindowOnCurrentVirtualDesktop([IntPtr]3).Success | Should Be $false
    }
    It 'A3 foreground desktop fallback is third after valid registry values' {
        $one = '11111111-1111-4111-8111-111111111111'
        $two = '22222222-2222-4222-8222-222222222222'
        $three = '33333333-3333-4333-8333-333333333333'
        [TerminalOrganizer.Core.Monitors.DesktopIdResolver]::Resolve('invalid', $null, $three).ToString() | Should BeExactly $three
        [TerminalOrganizer.Core.Monitors.DesktopIdResolver]::Resolve($one, $two, $three).ToString() | Should BeExactly $one
        [TerminalOrganizer.Core.Monitors.DesktopIdResolver]::Resolve($null, $two, $three).ToString() | Should BeExactly $two
    }
    It 'partial multi-tab UIA result remains displayable but unmergeable' {
        $read = [TerminalOrganizer.Core.Windows.TabTitleResult]::Incomplete(@([TerminalOrganizer.Core.Windows.TabEvidence]::new('1.2', 'OC_YODA1')), 2, 'OC_YODA1', 'unnamed tab')
        $read.ObservedTabItemCount | Should Be 2
        $read.Trusted | Should Be $false
        $sessions = Classify-All @((New-ChildProcess 'wsl.exe' $CMD_LOCAL))
        $shots = Compose-Snapshots @((New-AcquiredWindow ([IntPtr]201) $read (New-TestMonitor) $null)) $sessions
        $shots[0].Mergeable | Should Be $false
        $shots[0].TabReadQuality.ToString() | Should BeExactly 'Incomplete'
    }
    It 'legacy snapshot constructor never supplies mutation identity' {
        $shot = [TerminalOrganizer.Core.Windows.WindowSnapshot]::new([IntPtr]201, $null, $null, @(), $true, @(), $true)
        $shot.Mergeable | Should Be $false
        $shot.Identity.EqualsForMutation($shot.Identity) | Should Be $false
    }
}

# --- B4: bounded WMI and hard UIA timeout (night-design-2026-09-25 unit B4) ---

Describe 'B4 bounded WMI' {
    It 'B4 WMI searcher receives two-second timeout' {
        [TerminalOrganizer.Core.Windows.ProcessSessionQuery]::DefaultTimeoutMilliseconds | Should Be 2000
        $options = [TerminalOrganizer.Core.Windows.ProcessSessionQuery]::BuildOptions(2000)
        $options.Timeout.TotalMilliseconds | Should Be 2000
        $options.ReturnImmediately | Should Be $false
        $options.Rewindable | Should Be $false
    }

    It 'B4 WMI timeout returns degraded empty result' {
        $runner = [TerminalOrganizer.Core.Windows.SearcherRun] {
            param($searcher)
            throw (New-Object System.Management.ManagementException -ArgumentList 'timed out')
        }
        $query = [TerminalOrganizer.Core.Windows.ProcessSessionQuery]::new(2000, $runner)
        $result = $query.QueryChildren(@(4242), [System.Threading.CancellationToken]::None)
        $result | Should Not BeNullOrEmpty
        @($result.Children).Length | Should Be 0
        $result.TimedOut | Should Be $true
        $result.Error | Should Not BeNullOrEmpty
        # The old array surface delegates to the result method (same degraded empty set).
        @($query.QueryChildren(@(4242))).Length | Should Be 0
    }
}

# B4 helper-process fake (PS class = compiled IL, invoked by UiaProbeClient on the
# calling thread). "Never exits" is a STATE, never a parked real process with a
# waiting thread — a blocking worker freezes this host's pump (A5 fixture comment).
# The try/catch keeps a not-yet-implemented interface failing per-It instead of
# aborting the whole file (RED-phase hygiene).
try {
    if (-not ('B4FakeHelper' -as [type])) {
        Invoke-Expression @'
    class B4FakeHelper : TerminalOrganizer.Core.Windows.IHelperProcess {
        [System.Collections.Hashtable]$State
        B4FakeHelper([System.Collections.Hashtable]$s) { $this.State = $s }
        [bool] WaitForExit([int]$milliseconds) { $this.State['Actions'].Enqueue('wait'); return (-not [bool]$this.State['NeverExits']) }
        [void] Kill() { $this.State['Kills'] = [int]$this.State['Kills'] + 1; $this.State['Actions'].Enqueue('kill') }
        [string] ReadStandardOutput() { $this.State['Actions'].Enqueue('stdout'); return [string]$this.State['Stdout'] }
        [string] ReadStandardError() { $this.State['Actions'].Enqueue('stderr'); return '' }
        [void] Dispose() { $this.State['Actions'].Enqueue('dispose') }
    }
'@
    }
}
catch { }

function New-B4HelperState {
    param([bool]$NeverExits = $true, [string]$Stdout = '')
    [hashtable]::Synchronized(@{
        NeverExits = $NeverExits
        Stdout     = $Stdout
        Kills      = 0
        Actions    = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
    })
}

function New-B4ProbeClient([hashtable]$State, [int]$TimeoutMs) {
    # Delegates resolve dynamically, so the factory body touches only $script:-scoped
    # state (the factory closes over $script:B4FactoryState, never a local).
    $script:B4FactoryState = $State
    $factory = [TerminalOrganizer.Core.Windows.HelperProcessStart] {
        param($arguments)
        $script:B4SeenArguments = $arguments
        [B4FakeHelper]::new($script:B4FactoryState)
    }
    [TerminalOrganizer.Core.Windows.UiaProbeClient]::new('C:\b4-fake\TerminalOrganizer.UiaProbe.exe', $TimeoutMs, $factory)
}

Describe 'B4 hard UIA timeout via helper process' {
    It 'B4 UIA helper timeout returns TimedOut quality' {
        # Deterministic fallback: a hidden form with a pinned title is a REAL hwnd,
        # so the client's production GetWindowText fallback resolves it when the
        # helper never answers (the suite host has no console window).
        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'B4-PROBE-HOST'
        $form.Visible = $false
        $null = $form.Handle
        try {
            $state = New-B4HelperState
            $client = New-B4ProbeClient $state 120
            $result = $client.ReadTabs($form.Handle, [System.Threading.CancellationToken]::None)
            $result.Quality.ToString() | Should BeExactly 'TimedOut'
            $result.FallbackTitle | Should BeExactly 'B4-PROBE-HOST'
            $state.Kills | Should Be 1
            $script:B4SeenArguments | Should BeExactly ('--hwnd ' + $form.Handle.ToInt64())
            $actions = @($state['Actions'].ToArray())
            ($actions -contains 'stdout') | Should Be $false   # timed-out read never parses partial output
            # Timeout policy: the fallback display title survives, the window stays
            # placeable through composition but is ALWAYS unmergeable.
            $timedOut = [TerminalOrganizer.Core.Windows.TabTitleResult]::TimedOut('FB-TITLE', 'helper timeout')
            $shots = Compose-Snapshots @((New-AcquiredWindow ([IntPtr]201) $timedOut (New-TestMonitor) $null)) @()
            $shots[0].Tabs.Length | Should Be 1
            $shots[0].Tabs[0].Title | Should BeExactly 'FB-TITLE'
            $shots[0].TabReadQuality.ToString() | Should BeExactly 'TimedOut'
            $shots[0].Mergeable | Should Be $false
        }
        finally {
            $form.Dispose()
        }
    }

    It 'B4 cancellation terminates only owned UIA helper' {
        $state = New-B4HelperState
        $client = New-B4ProbeClient $state 5000
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.Cancel()
        $result = $client.ReadTabs([IntPtr]772, $cts.Token)
        $result.Quality.ToString() | Should BeExactly 'TimedOut'
        $state.Kills | Should Be 1
        # Only owned-helper operations ever run: one poll, kill, the brief post-kill
        # wait, dispose. No terminal/native-window action exists on the client.
        ($state['Actions'].ToArray() -join ',') | Should BeExactly 'wait,kill,wait,dispose'
    }

    It 'B4 malformed helper output fails closed' {
        $bad = [TerminalOrganizer.Core.Windows.UiaProbeClient]::ParseOutput('NONSENSE-not-a-protocol-line', 'FB')
        $bad.Quality.ToString() | Should BeExactly 'Fallback'
        $shots = Compose-Snapshots @((New-AcquiredWindow ([IntPtr]202) $bad (New-TestMonitor) $null)) @()
        $shots[0].Mergeable | Should Be $false
        # Well-formed grammar roundtrips (helper output contract).
        $id = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('1.2'))
        $title = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('OC_YODA1'))
        $err = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('boom'))
        $ok = [TerminalOrganizer.Core.Windows.UiaProbeClient]::ParseOutput(('OK|1|' + $id + ':' + $title), $null)
        $ok.Quality.ToString() | Should BeExactly 'Trusted'
        $ok.Titles[0] | Should BeExactly 'OC_YODA1'
        $ok.Evidence[0].IdentityKey | Should BeExactly '1.2'
        $incomplete = [TerminalOrganizer.Core.Windows.UiaProbeClient]::ParseOutput(
            ('INCOMPLETE|2|' + $id + ':' + $title + '|' + $err), 'FB')
        $incomplete.Quality.ToString() | Should BeExactly 'Incomplete'
        $incomplete.ObservedTabItemCount | Should Be 2
        $incomplete.FallbackTitle | Should BeExactly 'FB'
        $errorLine = [TerminalOrganizer.Core.Windows.UiaProbeClient]::ParseOutput(('ERROR|0||' + $err), 'FB')
        $errorLine.Quality.ToString() | Should BeExactly 'Fallback'
        $errorLine.Error | Should BeExactly 'boom'
        $garbage64 = [TerminalOrganizer.Core.Windows.UiaProbeClient]::ParseOutput(
            ('OK|1|!!!not-base64!!!:' + $title), 'FB')
        $garbage64.Quality.ToString() | Should BeExactly 'Fallback'
    }
}

Describe 'B4 dynamic raw-title length' {
    It 'B4 long raw title is not truncated at 511' {
        $script:B4MaxCount = 0
        $readProbe = [TerminalOrganizer.Core.Windows.TitleBufferRead] {
            param($h, $sb, $max)
            $script:B4MaxCount = $max
            $sb.Length = 0
            [void]$sb.Append('x' * 700)
            700
        }
        $reader = [TerminalOrganizer.Core.Windows.UiaTabTitleReader]::new(
            [TerminalOrganizer.Core.Windows.TitleLengthProbe] { param($h) 700 }, $readProbe)
        $title = $reader.ReadWindowTitle([IntPtr]5)
        $title.Length | Should Be 700
        $script:B4MaxCount | Should Be 701

        # Cap at 32767: allocate capped-length + 1, never a runaway buffer.
        $script:B4MaxCount = 0
        $capped = [TerminalOrganizer.Core.Windows.UiaTabTitleReader]::new(
            [TerminalOrganizer.Core.Windows.TitleLengthProbe] { param($h) 40000 }, $readProbe)
        $null = $capped.ReadWindowTitle([IntPtr]5)
        $script:B4MaxCount | Should Be 32768

        # Zero-length title still attempts a one-character-safe read.
        $script:B4MaxCount = 0
        $empty = [TerminalOrganizer.Core.Windows.UiaTabTitleReader]::new(
            [TerminalOrganizer.Core.Windows.TitleLengthProbe] { param($h) 0 }, $readProbe)
        $null = $empty.ReadWindowTitle([IntPtr]5)
        $script:B4MaxCount | Should Be 2
    }
}

Describe 'AC-009 Dump tool self-test' {
    It 'tools/dump-windows.ps1 -SelfTest exits 0 with one PASS/FAIL line per check and zero FAILs' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $dump = Join-Path $repoRoot 'tools\dump-windows.ps1'
        $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $dump -SelfTest
        $code = $LASTEXITCODE
        $lines = @($output | Where-Object { $_ -cmatch '^(PASS|FAIL):' })
        $lines.Count | Should BeGreaterThan 0
        @($lines | Where-Object { $_ -cmatch '^FAIL:' }).Count | Should Be 0
        $code | Should Be 0
    }
}

Describe 'AC-010 Dump tool live mode' {
    It 'with -Monitor 1 it prints a report and exits 0 even with zero windows (informational)' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $dump = Join-Path $repoRoot 'tools\dump-windows.ps1'
        $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $dump -Monitor 1
        $code = $LASTEXITCODE
        $code | Should Be 0
        @($output).Length | Should BeGreaterThan 0
    }
}

# --- B5: tool scope/error semantics (night-design-2026-09-25 unit B5) ---
# The pinned fixture (tests/fixtures/window-inventory.json) is the SSOT for these rows:
# 4101 monitor 1 current, 4102 monitor 2 current, 4103 monitor 1 other-desktop,
# 4104 monitor 1 unknown-desktop, 4105 unattributed. Deterministic; the live desktop
# is never enumerated.

function New-B5FixtureMonitors {
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $repoRoot 'tests\fixtures\window-inventory.json')))
    @($doc.monitors | ForEach-Object {
        $wa = New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList `
            $_.workLeft, $_.workTop, $_.workWidth, $_.workHeight, $_.dpi
        New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
            $_.interfacePath, $_.monitorId, $_.instance, $_.serial, $_.number,
            $_.left, $_.top, $_.width, $_.height, $wa
    })
}

function New-B5FixtureWindows {
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $repoRoot 'tests\fixtures\window-inventory.json')))
    $byNumber = @{}
    foreach ($m in (New-B5FixtureMonitors)) { $byNumber[$m.Number] = $m }
    @(foreach ($row in $doc.windows) {
        $monitor = $null
        if ($null -ne $row.monitor) { $monitor = $byNumber[[int]$row.monitor] }
        $status = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true)
        if ($row.desktop -ceq 'other') { $status = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($false) }
        if ($row.desktop -ceq 'unknown') { $status = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Failure('fixture: unknown desktop') }
        [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]$row.handle, $monitor, $status)
    })
}

# Runs dump-windows.ps1 in a fresh PS 5.1 child; merges stderr; returns text + exit code.
function Invoke-B5Dump {
    param([string[]]$ToolArgs)
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $dump = Join-Path $repoRoot 'tools\dump-windows.ps1'
    $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $dump @ToolArgs 2>&1
    @{ Text = ($output | Out-String); Code = $LASTEXITCODE }
}

# The included window handles from a dump report ('window <handle>:' lines).
function Get-B5IncludedHandles([string]$Text) {
    $handles = @()
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -cmatch '^window (\d+):') { $handles += [long]$Matches[1] }
    }
    ,@($handles)
}

Describe 'B5 dump tool scope semantics' {
    $fixturePath = Join-Path $repoRoot 'tests\fixtures\window-inventory.json'

    It 'B5 dump monitor filter includes only requested stable monitor' {
        $r = Invoke-B5Dump @('-Monitor', '1', '-InventoryPath', $fixturePath)
        $r.Code | Should Be 0
        $included = Get-B5IncludedHandles $r.Text
        $included.Length | Should Be 1
        $included[0] | Should Be 4101
    }

    It 'B5 dump AllMonitors includes both current-desktop windows only' {
        $r = Invoke-B5Dump @('-AllMonitors', '-InventoryPath', $fixturePath)
        $r.Code | Should Be 0
        $included = Get-B5IncludedHandles $r.Text
        $included.Length | Should Be 2
        ($included -join ',') | Should BeExactly '4101,4102'
    }

    It 'B5 unknown monitor exits one' {
        $r = Invoke-B5Dump @('-Monitor', '9', '-InventoryPath', $fixturePath)
        $r.Code | Should Be 1
        $r.Text.Contains('ERROR:') | Should Be $true
    }

    It 'B5 injected acquisition failure exits two' {
        $failPath = Join-Path $TestDrive 'b5-fail-inventory.json'
        [IO.File]::WriteAllText($failPath, ([IO.File]::ReadAllText($fixturePath).Replace('"failAcquisition": false', '"failAcquisition": true')))
        $r = Invoke-B5Dump @('-Monitor', '1', '-InventoryPath', $failPath)
        $r.Code | Should Be 2
        $r.Text.Contains('ERROR:') | Should Be $true
    }

    It 'B5 dry-run scoping matches WindowScope production result' {
        # Pure WindowScope over the same fixture rows (the production scope rule).
        $monitors = New-B5FixtureMonitors
        $windows = New-B5FixtureWindows
        $scope = [TerminalOrganizer.Core.Windows.WindowScope]::Filter($windows, $monitors[0].StableKey, $false)
        $expected = @($scope.Included | ForEach-Object { $_.Handle.ToInt64() })
        # The tool's deterministic inventory mode prints exactly those included handles.
        $r = Invoke-B5Dump @('-Monitor', '1', '-InventoryPath', (Join-Path $repoRoot 'tests\fixtures\window-inventory.json'))
        $r.Code | Should Be 0
        $actual = Get-B5IncludedHandles $r.Text
        ($actual -join ',') | Should BeExactly ($expected -join ',')
    }
}
