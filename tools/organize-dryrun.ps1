# SPEC-ZONE-005 dry-run tool (plan.md F file 7; acceptance AC-010).
# -SelfTest     : exercises the pure planning rows (AC-001..AC-006) against the pinned
#                 zone/window values from acceptance.md and plan.md section J; prints one
#                 PASS/FAIL line per check and exits 0 only when every check passes.
# No switch     : live mode - computes and PRINTS the plan for the real screen without
#                 moving any window (the dry-run never applies a plan, ever). Prints the
#                 resolved zones, the persisted manager choice, and one row per window:
#                 target zone/rect, no-move / restore-first / stacked / full-screen-skip
#                 markers, plus the manager pin or skip reason. Live output is
#                 informational (morning checklist), NOT an acceptance claim.
#                 SPEC-MON-011: the applied-layouts row is decided with the FancyZones log hint
#                 (-FancyZonesLogs <path>, default: the real FancyZones Logs folder) and a
#                 'row decided by: <rule>' line is printed per planned monitor.
param(
    [switch]$SelfTest,
    [int]$Monitor = 1,
    [switch]$AllMonitors,
    [string]$SettingsPath,
    [string]$AppliedLayoutsPath,
    [string]$CustomLayoutsPath,
    [string]$FancyZonesLogs
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$dllPath = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'

if (-not $SettingsPath) {
    $SettingsPath = Join-Path $env:LOCALAPPDATA 'TerminalOrganizer\settings.json'
}
$fancyZonesDir = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\FancyZones'
if (-not $FancyZonesLogs) {
    # SPEC-MON-011: the FancyZones Logs folder that holds the live-row hint (Logs\<version>\log_YYYY-MM-DD.log).
    $FancyZonesLogs = Join-Path $fancyZonesDir 'Logs'
}
if (-not $AppliedLayoutsPath) {
    $AppliedLayoutsPath = Join-Path $fancyZonesDir 'applied-layouts.json'
}
if (-not $CustomLayoutsPath) {
    $CustomLayoutsPath = Join-Path $fancyZonesDir 'custom-layouts.json'
}

if (-not (Test-Path $dllPath)) {
    Write-Output ('FAIL: build output missing: ' + $dllPath + ' (run build.ps1 first)')
    exit 1
}
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dllPath))
# C2: the App assembly carries the snapshot composer and the physical-label derivation
# the cross-monitor preview needs (pure types; no WinForms dependency is touched).
$appDllPath = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'
if (-not (Test-Path $appDllPath)) {
    Write-Output ('FAIL: build output missing: ' + $appDllPath + ' (run build.ps1 first)')
    exit 1
}
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appDllPath))

# Pinned values (acceptance.md Conventions; plan.md J.1/J.2) - never re-derived from code under test.
# Standing zone set: z0 456x1120 @ 16,16; z1 944x1120 @ 488,16 (largest, first in ZoneOrdering order); z2 456x1120 @ 1448,16.
function New-StandingZones {
    @(
        [TerminalOrganizer.Core.Geometry.Zone]::new(0, 16, 16, 456, 1120),
        [TerminalOrganizer.Core.Geometry.Zone]::new(1, 488, 16, 944, 1120),
        [TerminalOrganizer.Core.Geometry.Zone]::new(2, 1448, 16, 456, 1120)
    )
}

$script:FactHandleSeed = 1000

function New-Fact {
    param(
        [string]$Id,
        [int]$Left = 0,
        [int]$Top = 0,
        [int]$Width = 400,
        [int]$Height = 300,
        [switch]$Maximized,
        [switch]$Minimized,
        [switch]$FullScreen
    )
    $script:FactHandleSeed = $script:FactHandleSeed + 1
    [TerminalOrganizer.Core.Assignment.WindowFact]::new(
        $Id, [IntPtr]$script:FactHandleSeed, $Id, $true,
        $Left, $Top, $Width, $Height,
        [bool]$Maximized.IsPresent, [bool]$Minimized.IsPresent, [bool]$FullScreen.IsPresent)
}

function Invoke-Assign($Zones, $Facts, [string]$ManagerName) {
    [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($Zones, $Facts, $ManagerName)
}

# SPEC-RULES-009 REQ-ID-004: the local plan pins what the organize run pins - the selector is resolved
# against the discovered windows (the same resolution the menu uses) and the ZoneAssigner resolution
# overload receives it; any status other than Resolved falls back to raw-title matching (today's reasons).
function Invoke-ManagerAssign($Zones, $Facts, $Snapshots, $Selector) {
    $resolution = [TerminalOrganizer.Core.Assignment.ManagerResolver]::Resolve($Selector, [TerminalOrganizer.Core.Assignment.WindowFact[]]@($Facts), [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($Snapshots))
    if ($resolution.Status.ToString() -eq 'Resolved') {
        return [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($Zones, [TerminalOrganizer.Core.Assignment.WindowFact[]]@($Facts), $resolution)
    }
    $fallback = $null
    if (-not $Selector.IsEmpty) { $fallback = $Selector.RawTitleFallback }
    Invoke-Assign $Zones $Facts $fallback
}

# SPEC-MON-011 REQ-TOOL-002: the rule that decided the applied-layouts row (LiveHint, HintUnmatched or DocumentOrder).
function Get-DecidedLine($Decision) {
    'row decided by: ' + $Decision.Rule.ToString()
}

function Get-Move($Plan, [string]$WindowId) {
    @($Plan.Moves | Where-Object { $_.WindowId -eq $WindowId })[0]
}

$script:FailCount = 0
$script:CheckCount = 0

function Assert-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    $script:CheckCount++
    if ($Ok) {
        Write-Output ('PASS: ' + $Name)
    }
    else {
        $script:FailCount++
        Write-Output ('FAIL: ' + $Name + ' - expected ' + $Detail)
    }
}

if ($SelfTest) {
    # --- AC-001 manager pin ---
    $zones = New-StandingZones
    $plan = Invoke-Assign $zones @(
        (New-Fact 'MGR' -Left 100 -Top 100),
        (New-Fact 'A'),
        (New-Fact 'B' -Left 500)
    ) 'MGR'
    $ok = $plan.ManagerPinned -and (Get-Move $plan 'MGR').ZoneId -eq 1 -and
        (Get-Move $plan 'A').ZoneId -eq 0 -and (Get-Move $plan 'B').ZoneId -eq 2
    Assert-Check 'ac001/manager-pin' $ok 'MGR->z1, A->z0, B->z2, pinned'

    # --- AC-002 position fill order + tie ---
    $plan = Invoke-Assign (New-StandingZones) @(
        (New-Fact 'A'),
        (New-Fact 'B' -Left 500),
        (New-Fact 'C' -Top 400)
    ) $null
    $ok = (Get-Move $plan 'A').ZoneId -eq 1 -and (Get-Move $plan 'B').ZoneId -eq 0 -and
        (Get-Move $plan 'C').ZoneId -eq 2
    Assert-Check 'ac002/position-order' $ok 'A,B,C -> z1,z0,z2 (z1 first: largest)'

    $plan = Invoke-Assign (New-StandingZones) @((New-Fact 'E'), (New-Fact 'D')) $null
    $ok = (Get-Move $plan 'D').ZoneId -eq 1 -and (Get-Move $plan 'E').ZoneId -eq 0
    Assert-Check 'ac002/tie-id-ordinal' $ok 'D before E at the same top-left'

    # --- AC-003 overflow stacking ---
    $plan = Invoke-Assign (New-StandingZones) @(
        (New-Fact 'MGR' -Left 100 -Top 100),
        (New-Fact 'A'),
        (New-Fact 'B' -Left 500),
        (New-Fact 'C' -Top 400),
        (New-Fact 'D' -Top 800)
    ) 'MGR'
    $stacked = @($plan.Moves | Where-Object { $_.Stacked })
    $ok = (Get-Move $plan 'A').ZoneId -eq 0 -and (Get-Move $plan 'B').ZoneId -eq 2 -and
        $stacked.Count -eq 2 -and $stacked[0].WindowId -ceq 'C' -and $stacked[1].WindowId -ceq 'D' -and
        $stacked[0].ZoneId -eq 2
    Assert-Check 'ac003/overflow-stack' $ok 'C,D stacked in z2, C then D'

    # --- AC-004 manager skipped ---
    $plan = Invoke-Assign (New-StandingZones) @((New-Fact 'A'), (New-Fact 'B' -Left 500)) 'GHOST'
    Assert-Check 'ac004/ghost-reason' ($plan.ManagerSkippedReason -ceq 'window not found') 'window not found'

    $plan = Invoke-Assign (New-StandingZones) @((New-Fact 'A'), (New-Fact 'B' -Left 500)) $null
    Assert-Check 'ac004/no-choice-reason' ($plan.ManagerSkippedReason -ceq 'no choice') 'no choice'

    # --- AC-005 idempotent no-move ---
    $plan = Invoke-Assign (New-StandingZones) @((New-Fact 'A' -Left 488 -Top 16 -Width 944 -Height 1120)) $null
    Assert-Check 'ac005/exact-rect-no-move' (-not (Get-Move $plan 'A').MoveRequired) 'no-move at the exact z1 rect'

    $plan = Invoke-Assign (New-StandingZones) @((New-Fact 'A' -Left 489 -Top 16 -Width 944 -Height 1120)) $null
    $move = Get-Move $plan 'A'
    Assert-Check 'ac005/one-pixel-move' ($move.MoveRequired -and $move.TargetLeft -eq 488) 'move to z1 rect from 1px off'

    # --- AC-006 restore-first and full-screen ---
    $plan = Invoke-Assign (New-StandingZones) @(
        (New-Fact 'MGR' -Left 700 -Top 700),
        (New-Fact 'A' -Width 1920 -Height 1040 -Maximized)
    ) 'MGR'
    $move = Get-Move $plan 'A'
    Assert-Check 'ac006/maximized-restore-first' ($move.ZoneId -eq 0 -and $move.RestoreFirst -and $move.MoveRequired) 'restore-first + target for a maximized window in z0'

    $plan = Invoke-Assign (New-StandingZones) @(
        (New-Fact 'MGR' -Left 700 -Top 700),
        (New-Fact 'A' -Left 16 -Top 16 -Width 456 -Height 1120 -Maximized)
    ) 'MGR'
    $move = Get-Move $plan 'A'
    Assert-Check 'ac006/state-outranks-rect' ($move.RestoreFirst -and $move.MoveRequired) 'restore-first even at the exact target rect'

    $plan = Invoke-Assign (New-StandingZones) @(
        (New-Fact 'MGR' -Left 700 -Top 700),
        (New-Fact 'A' -FullScreen)
    ) 'MGR'
    $move = Get-Move $plan 'A'
    Assert-Check 'ac006/full-screen-skipped' ((-not $move.MoveRequired) -and $move.FullScreenSkipped -and $move.ZoneId -eq -1 -and (-not $move.OccupiesZone)) 'unzoned no-move with FullScreenSkipped'

    # --- B5: scoping parity (a monitor's plan consumes only that monitor's windows,
    # through the shared WindowScope.Filter - never re-implemented in PowerShell) ---
    $b5WorkA = New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList 0, 0, 1920, 1152, 96
    $b5MonA = New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        '\\?\DISPLAY#DELA0B5#b5inst1', 'DELA0B5', 'b5inst1', 'B5DRY1', 1, 0, 0, 1920, 1200, $b5WorkA
    $b5MonB = New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        '\\?\DISPLAY#DELA0B5#b5inst2', 'DELA0B5', 'b5inst2', 'B5DRY2', 2, 1920, 0, 1920, 1200, $b5WorkA
    $b5Current = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true)
    $b5Rows = @(
        (New-Object TerminalOrganizer.Core.Windows.EnumeratedWindow -ArgumentList ([IntPtr]4201), $b5MonA, $b5Current),
        (New-Object TerminalOrganizer.Core.Windows.EnumeratedWindow -ArgumentList ([IntPtr]4202), $b5MonB, $b5Current),
        (New-Object TerminalOrganizer.Core.Windows.EnumeratedWindow -ArgumentList ([IntPtr]4203), $b5MonB, $b5Current)
    )
    $b5Scoped = [TerminalOrganizer.Core.Windows.WindowScope]::Filter($b5Rows, $b5MonA.StableKey, $false)
    $b5Facts = @()
    foreach ($b5Window in $b5Scoped.Included) { $b5Facts += , (New-Fact ('B5W' + $b5Window.Handle)) }
    $b5Plan = Invoke-Assign (New-StandingZones) $b5Facts $null
    $b5Ok = $b5Scoped.Included.Length -eq 1 -and $b5Scoped.SkippedOtherMonitor -eq 2 -and
        $b5Facts.Length -eq 1 -and $b5Plan.Moves.Count -eq 1 -and $b5Plan.Moves[0].WindowId -ceq 'B5W4201'
    Assert-Check 'b5/no-cross-monitor-facts' $b5Ok 'monitor 1 scopes to window 4201 only and plans exactly one move'

    # --- SPEC-RULES-009 AC-011 rows: rule-set composition and the shared provenance formatter ---
    # The preset-none fixture of plan.md J.3 (rule list U, default rank 450) goes through the same single
    # settings read, rule-set composition and identity-name facts the live path uses.
    $ac11Dot = ' ' + [char]0x00B7 + ' '
    $ac11ListU = '{"match":"PowerShell*","rank":200},{"match":"regex:^ssh (?<name>[^ ]+)","rank":400},{"match":"regex:^(?<rank>[0-9]{1,4})-(?<name>.+)$"},{"marker":"#"},{"match":"*--attach YODA*","on":"commandline","rank":250}'
    $ac11Json = '{"hotkey":"Ctrl+Alt+O","schemaVersion":3,"titleRules":{"preset":"none","defaultRank":450,"rules":[' + $ac11ListU + ']}}'
    $ac11File = Join-Path ([IO.Path]::GetTempPath()) ('ac11-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($ac11File, $ac11Json)
    try { $ac11Settings = [TerminalOrganizer.App.SettingsStore]::new($ac11File).Load() }
    finally { Remove-Item -LiteralPath $ac11File -Force -ErrorAction SilentlyContinue }

    $ac11WorkArea = New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList 0, 0, 1920, 1152, 96
    $ac11Mon1 = New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        '\\?\DISPLAY#DELA0C1#ac11inst1', 'DELA0C1', 'ac11inst1', 'AC11A', 1, 0, 0, 1920, 1200, $ac11WorkArea
    $ac11Mon2 = New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        '\\?\DISPLAY#DELA0C1#ac11inst2', 'DELA0C1', 'ac11inst2', 'AC11B', 2, 1920, 0, 1920, 1200, $ac11WorkArea
    $ac11Current = [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true)
    $ac11Cmd = 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1'
    $ac11Session = New-Object TerminalOrganizer.Core.Windows.SessionRecord -ArgumentList 'YODA1', ([TerminalOrganizer.Core.Windows.SessionKind]::Local), $ac11Cmd

    function New-Ac11Acquired([long]$Handle, [string]$Title) {
        $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]$Handle, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', $Title)
        [TerminalOrganizer.Core.Windows.AcquiredWindow]::new($identity,
            [TerminalOrganizer.Core.Windows.TabTitleResult]::Ok([string[]]@($Title)), $ac11Mon1, $ac11Current)
    }

    # Line check: W-PS, W-L, W-SSH composed through the rule-set overload; every per-window line equals two
    # spaces, 'window: ' and the menu row text; facts are built from identity names.
    $ac11Snaps = [TerminalOrganizer.Core.Windows.WindowSnapshotBuilder]::Compose(
        [TerminalOrganizer.Core.Windows.AcquiredWindow[]]@((New-Ac11Acquired 9001 'powershell'), (New-Ac11Acquired 9002 'OC_YODA1'), (New-Ac11Acquired 9003 'ssh server1')),
        [TerminalOrganizer.Core.Windows.SessionRecord[]]@($ac11Session), $ac11Settings.TitleRules.RuleSet)
    $ac11NamedAll = $true
    foreach ($ac11Snap in $ac11Snaps) {
        if (-not [TerminalOrganizer.Core.Assignment.ManagerResolver]::HasIdentityName($ac11Snap)) { $ac11NamedAll = $false }
    }
    $ac11Overrides = [TerminalOrganizer.App.PriorityOverride[]]@($ac11Settings.PriorityOverrides)
    $ac11Rank = [int]$ac11Settings.TitleRules.DefaultRank
    $ac11Lines = [TerminalOrganizer.App.RuleProvenance]::LineTexts($ac11Snaps, $ac11Overrides, $ac11Rank)
    $ac11Texts = [TerminalOrganizer.App.RuleProvenance]::RowTexts($ac11Snaps, $ac11Overrides, $ac11Rank)
    $ac11State = [TerminalOrganizer.App.TrayMenuState]::new($false, 'Ctrl+Alt+O',
        [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($ac11Mon1), $ac11Snaps,
        [TerminalOrganizer.Core.Assignment.ManagerSelector]::None(), $null, $null, $false,
        [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'), [string[]]@($ac11Texts))
    $ac11Root = @([TerminalOrganizer.App.TrayMenuBuilder]::Build($ac11State) | Where-Object { $_.Kind.ToString() -eq 'LabelsAndPrioritiesRoot' })[0]
    $ac11LinesOk = $ac11NamedAll -and $ac11Lines.Length -eq 3 -and @($ac11Root.Children).Count -eq 3
    for ($ac11I = 0; $ac11LinesOk -and $ac11I -lt 3; $ac11I++) {
        if ($ac11Lines[$ac11I] -cne ('  window: ' + $ac11Root.Children[$ac11I].Label)) { $ac11LinesOk = $false }
    }
    $ac11WlLine = '  window: OC_YODA1' + $ac11Dot + 'rank 250' + $ac11Dot + 'rule 5: *--attach YODA*'
    $ac11LinesOk = $ac11LinesOk -and $ac11Lines[1] -ceq $ac11WlLine
    Assert-Check 'ac011/lines' $ac11LinesOk 'every line equals two spaces, window: and the menu row text; W-L reads OC_YODA1 / rank 250 / rule 5'

    # Preview check: the one-overflow fixture with the loaded default rank 450; the single planned move is
    # Untitled tab and carries 'derived rank 450'.
    $ac11Handles = @(9101, 9102, 9103, 9104)
    $ac11Titles = @('OC_YODA1', 'powershell', 'ssh server1', 'Untitled tab')
    $ac11Rects = @(@(0, 0, 960, 1040), @(100, 500, 400, 300), @(100, 600, 400, 300), @(100, 700, 400, 300))
    $ac11Acq = @()
    for ($ac11I = 0; $ac11I -lt 4; $ac11I++) { $ac11Acq += , (New-Ac11Acquired $ac11Handles[$ac11I] $ac11Titles[$ac11I]) }
    $ac11PSnaps = [TerminalOrganizer.Core.Windows.WindowSnapshotBuilder]::Compose(
        [TerminalOrganizer.Core.Windows.AcquiredWindow[]]$ac11Acq,
        [TerminalOrganizer.Core.Windows.SessionRecord[]]@($ac11Session), $ac11Settings.TitleRules.RuleSet)
    $ac11PFacts = @()
    $ac11PRows = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.EnumeratedWindow]'
    for ($ac11I = 0; $ac11I -lt 4; $ac11I++) {
        $ac11PFacts += , [TerminalOrganizer.Core.Assignment.WindowFact]::new(('ac11-' + $ac11I), [IntPtr]$ac11Handles[$ac11I], $ac11Titles[$ac11I],
            [TerminalOrganizer.Core.Assignment.ManagerResolver]::HasIdentityName($ac11PSnaps[$ac11I]),
            $ac11Rects[$ac11I][0], $ac11Rects[$ac11I][1], $ac11Rects[$ac11I][2], $ac11Rects[$ac11I][3], $false, $false, $false)
        $ac11PRows.Add([TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]$ac11Handles[$ac11I], $ac11Mon1, $ac11Current, $ac11PSnaps[$ac11I].Identity))
    }
    $ac11Z1 = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 0, 0, 960, 1040))
    $ac11Z2 = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 1920, 0, 960, 1040))
    $ac11Plan1 = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($ac11Z1, [TerminalOrganizer.Core.Assignment.WindowFact[]]$ac11PFacts, $null)
    $ac11Plan2 = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($ac11Z2, [TerminalOrganizer.Core.Assignment.WindowFact[]]@(), $null)
    $ac11ZoneSets = New-Object 'TerminalOrganizer.Core.Geometry.Zone[][]' 2
    $ac11ZoneSets[0] = $ac11Z1
    $ac11ZoneSets[1] = $ac11Z2
    $ac11Composed = [TerminalOrganizer.App.CrossMonitorSnapshotComposer]::Compose('ac11-desktop',
        [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($ac11Mon1, $ac11Mon2), $ac11ZoneSets, [string[]]@('M1', 'M2'),
        [TerminalOrganizer.Core.Assignment.AssignmentPlan[]]@($ac11Plan1, $ac11Plan2), $ac11PRows.ToArray(),
        [TerminalOrganizer.Core.Assignment.WindowFact[]]$ac11PFacts, $ac11PSnaps, $ac11Overrides, $ac11Mon1.StableKey, $ac11Rank)
    $ac11Move = [TerminalOrganizer.Core.Overflow.CrossMonitorPlanner]::Plan($ac11Composed)
    $ac11PreviewOk = @($ac11Move.Moves).Count -eq 1 -and $ac11Move.Moves[0].WindowId -ceq 'ac11-3' -and $ac11Move.Moves[0].PriorityReason -ceq 'derived rank 450'
    Assert-Check 'ac011/preview' $ac11PreviewOk 'one planned move for Untitled tab carrying derived rank 450'

    # --- SPEC-MON-011 row: the rule line of the hinted row decision (inputs pinned here, never derived from the code under test) ---
    # SF-STALE rows 0 (stale: number 2, D2U) and 2 (live: number 1, EHU) of UID4352 on D1; the log hint is (1, XPG0H42JBEHU).
    $m11Inst = '5&22cafbe4&0&UID4352'
    $m11Desktop = '{9089F388-5216-49EA-9CD4-07E910D817EB}'
    $m11Json = '{"applied-layouts":[' +
        '{"device":{"monitor":"DEL4091","monitor-instance":"' + $m11Inst + '","monitor-number":2,"serial-number":"XPG0H42JBD2U","virtual-desktop":"' + $m11Desktop + '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0,"zone-count":2}},' +
        '{"device":{"monitor":"DEL4091","monitor-instance":"' + $m11Inst + '","monitor-number":1,"serial-number":"XPG0H42JBEHU","virtual-desktop":"' + $m11Desktop + '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0,"zone-count":2}}]}'
    $m11Doc = [TerminalOrganizer.Core.Layouts.FancyZonesJsonReader]::ParseAppliedLayouts($m11Json)
    $m11Identity = New-Object TerminalOrganizer.Core.Monitors.MonitorIdentity -ArgumentList 'DEL4091', $m11Inst, 1, 'XPG0H42JBD2U'
    $m11Hint = New-Object TerminalOrganizer.Core.Monitors.LiveRowHint -ArgumentList 1, 'XPG0H42JBEHU', 'log_2026-10-23.log'
    $m11Decision = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Decide($m11Doc, $m11Identity, $m11Desktop, $m11Hint)
    $m11Line = Get-DecidedLine $m11Decision
    Assert-Check 'mon011/row-decided-by' ($m11Line -ceq 'row decided by: LiveHint' -and $null -ne $m11Decision.Entry -and $m11Decision.Entry.Position -eq 1) 'row decided by: LiveHint at position 1'
    Write-Output $m11Line

    Write-Output ('SelfTest summary: ' + $script:CheckCount + ' checks, ' + $script:FailCount + ' failed')
    if ($script:FailCount -gt 0) { exit 1 }
    exit 0
}

# --- Live mode (morning checklist; informational only; no window is ever moved) ---
# Exit codes (B5): 0 success or valid no-windows; 1 invalid args / missing required
# file / missing requested monitor; 2 acquisition exception; 3 invalid/unsupported
# layout when a plan was explicitly requested. -AllMonitors only PRINTS per-monitor
# plans (a monitor without a usable layout prints a note and the sweep continues);
# every per-monitor scope is WindowScope.Filter with that monitor's stable key.
function Fail-Dry([string]$Message, [int]$Code) {
    [Console]::Error.WriteLine('ERROR: ' + $Message)
    exit $Code
}

try {
    $provider = New-Object TerminalOrganizer.Core.Monitors.Win32MonitorProvider
    $desktopReader = New-Object TerminalOrganizer.Core.Monitors.VirtualDesktopReader
    $titleReader = New-Object TerminalOrganizer.Core.Windows.UiaTabTitleReader
    $enumerator = New-Object TerminalOrganizer.Core.Windows.Win32WindowEnumerator
    $sessionQuery = New-Object TerminalOrganizer.Core.Windows.ProcessSessionQuery
    $stateReader = New-Object TerminalOrganizer.Core.Assignment.WindowStateReader

    $desktopText = $null
    $win10 = $desktopReader.TryReadWin10SessionValue()
    if ($win10.Status.ToString() -eq 'Present') {
        $desktopText = $win10.Value
    }
    else {
        $win11 = $desktopReader.TryReadWin11Value()
        if ($win11.Status.ToString() -eq 'Present') { $desktopText = $win11.Value }
    }

    $monitors = $provider.GetMonitors()
    if ($AllMonitors) {
        $plannedMonitors = @($monitors)
    }
    else {
        $chosen = @($monitors | Where-Object { $_.Number -eq $Monitor }) | Select-Object -First 1
        if ($null -eq $chosen) {
            Fail-Dry ('requested monitor ' + $Monitor + ' not found among ' + $monitors.Length + ' monitor(s)') 1
        }
        $plannedMonitors = @($chosen)
    }

    if (-not (Test-Path -LiteralPath $AppliedLayoutsPath) -or -not (Test-Path -LiteralPath $CustomLayoutsPath)) {
        Fail-Dry ('required FancyZones documents not found; expected ' + $AppliedLayoutsPath + ' and ' + $CustomLayoutsPath) 1
    }
    $appliedJson = [IO.File]::ReadAllText($AppliedLayoutsPath)
    $customJson = [IO.File]::ReadAllText($CustomLayoutsPath)
    $appliedDoc = [TerminalOrganizer.Core.Layouts.FancyZonesJsonReader]::ParseAppliedLayouts($appliedJson)
    if (-not $appliedDoc.IsValid) {
        Fail-Dry ('applied-layouts document invalid: ' + $appliedDoc.Detail) 3
    }

    # SPEC-RULES-009 REQ-UI-002: ONE settings read, before any window is composed. It supplies the manager
    # selector, the manual overrides, the rule set and the default rank for every site below.
    $settings = [TerminalOrganizer.App.SettingsStore]::new($SettingsPath).Load()
    $selector = $settings.ManagerSelector
    $managerName = $settings.ManagerWindowName
    Write-Output ('dry run: manager choice from ' + $SettingsPath + ': ' + $(if ($null -ne $managerName) { $managerName } else { '<no choice>' }))

    $wtProcs = @([System.Diagnostics.Process]::GetProcessesByName('WindowsTerminal'))
    $wtPids = @($wtProcs | ForEach-Object { $_.Id })
    $children = $sessionQuery.QueryChildren([int[]]$wtPids)
    $sessions = [TerminalOrganizer.Core.Windows.CommandLineClassifier]::ClassifyAll($children)
    $windows = $enumerator.Enumerate([int[]]$wtPids, $desktopReader, $monitors)
    Write-Output ('dry run: ' + $windows.Length + ' WT window(s), ' + $sessions.Length + ' open session(s)')

    # C2 accumulators: every planned monitor's layout/facts/plan feed the cross-monitor
    # snapshot once the per-monitor sweep completes.
    $cmMonitors = New-Object 'System.Collections.Generic.List[object]'
    $cmZones = New-Object 'System.Collections.Generic.List[object]'
    $cmLabels = New-Object 'System.Collections.Generic.List[string]'
    $cmPlans = New-Object 'System.Collections.Generic.List[object]'
    $cmFacts = New-Object 'System.Collections.Generic.List[object]'
    $cmSnaps = New-Object 'System.Collections.Generic.List[object]'

    foreach ($target in $plannedMonitors) {
        # SPEC-MON-011: the live-row hint from the FancyZones log decides among the instance-exact rows (the app's path).
        $logRead = [TerminalOrganizer.Core.Monitors.FancyZonesLogReader]::Read($FancyZonesLogs, $target.MonitorId, $target.Instance)
        $decision = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Decide($appliedDoc, $target.ToIdentity(), $desktopText, $logRead.Hint)
        $selected = $decision.Entry
        Write-Output (Get-DecidedLine $decision)
        if ($null -eq $selected) {
            $note = 'no applied-layouts entry matches monitor #' + $target.Number + '; nothing to plan'
            if ($AllMonitors) { Write-Output ('note: ' + $note); continue }
            Fail-Dry $note 3
        }
        $context = [TerminalOrganizer.Core.Monitors.OrganizerContext]::Build($selected, $target)
        $layout = [TerminalOrganizer.Core.Layouts.LayoutResolver]::ResolveByDeviceKey($appliedJson, $customJson, $context.Key, $context.WorkArea)
        if ($layout.Kind.ToString() -ne 'Supported') {
            $note = 'layout not resolved for monitor #' + $target.Number + ': kind=' + $layout.Kind.ToString() + ' reason=' + $layout.Reason.ToString() + ' detail=' + $layout.Detail
            if ($AllMonitors) { Write-Output ('note: ' + $note); continue }
            Fail-Dry $note 3
        }
        $zones = $layout.Zones
        Write-Output ('dry run: monitor #' + $target.Number + ', layout type=' + $layout.LayoutType + ' name=' + $layout.LayoutName + ', ' + $zones.Length + ' zone(s)')
        foreach ($z in $zones) {
            Write-Output ('  ' + $z.ToString())
        }

        # B5: THIS monitor's stable key through the shared production scope rule.
        $scope = [TerminalOrganizer.Core.Windows.WindowScope]::Filter($windows, $target.StableKey, $false)
        Write-Output ('  scope: included=' + $scope.Included.Length + ' other-monitor=' + $scope.SkippedOtherMonitor +
            ' other-desktop=' + $scope.SkippedOtherDesktop + ' unknown-desktop=' + $scope.SkippedUnknownDesktop +
            ' unattributed=' + $scope.SkippedUnattributed)

        $acquired = @()
        foreach ($w in $scope.Included) {
            $titles = $titleReader.ReadTabs($w.Handle)
            $acquired += , (New-Object TerminalOrganizer.Core.Windows.AcquiredWindow -ArgumentList $w.Handle, $titles, $w.Monitor, $w.DesktopStatus)
        }
        $snapshots = [TerminalOrganizer.Core.Windows.WindowSnapshotBuilder]::Compose($acquired, $sessions, $settings.TitleRules.RuleSet)

        $facts = @()
        foreach ($snap in $snapshots) {
            $state = $stateReader.Read($snap.Handle)
            $name = [TerminalOrganizer.Core.Windows.UiaTabTitleReader]::GetWindowTextTitle($snap.Handle)
            if ([string]::IsNullOrEmpty($name) -and $snap.Tabs.Length -gt 0) { $name = $snap.Tabs[0].Title }
            $facts += , [TerminalOrganizer.Core.Assignment.WindowFact]::new(
                ('w' + $snap.Handle), $snap.Handle, $name, [TerminalOrganizer.Core.Assignment.ManagerResolver]::HasIdentityName($snap),
                $state.Left, $state.Top, $state.Width, $state.Height,
                $state.Maximized, $state.Minimized, $state.FullScreen)
        }

        $plan = Invoke-ManagerAssign $zones $facts $snapshots $selector
        if ($plan.ManagerPinned) {
            Write-Output ('  plan: manager pinned: ' + $plan.ManagerWindowId)
        }
        else {
            Write-Output ('  plan: manager skipped: ' + $plan.ManagerSkippedReason)
        }
        foreach ($move in $plan.Moves) {
            Write-Output ('  ' + $move.ToString())
        }
        if ($facts.Length -eq 0) {
            Write-Output ('  dry run: no windows in scope on monitor #' + $target.Number + ' (valid empty result)')
        }
        # SPEC-RULES-009 REQ-UI-002: one line per window, the same text the tray menu rows show (shared formatter).
        foreach ($providerLine in [TerminalOrganizer.App.RuleProvenance]::LineTexts([TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($snapshots),
                [TerminalOrganizer.App.PriorityOverride[]]@($settings.PriorityOverrides), [int]$settings.TitleRules.DefaultRank)) {
            Write-Output $providerLine
        }

        $cmMonitors.Add($target)
        $cmZones.Add($zones)
        $cmLabels.Add([TerminalOrganizer.App.TrayMenuBuilder]::DerivePhysicalLabel($target, $monitors))
        $cmPlans.Add($plan)
        foreach ($cmFact in $facts) { $cmFacts.Add($cmFact) }
        foreach ($cmSnap in $snapshots) { $cmSnaps.Add($cmSnap) }
    }

    # C2: the pure cross-monitor redistribution preview over the planned monitors. The
    # dry run never mutates anything - this plan is computed, printed, and never applied.
    if ($cmMonitors.Count -gt 0) {
        $cmOverrides = $settings.PriorityOverrides
        # Sources are only the organized monitor's own overflow; -AllMonitors organizes
        # every monitor, so the null key keeps every monitor's overflow as a source.
        $cmOrganizedKey = $null
        if (-not $AllMonitors) { $cmOrganizedKey = $chosen.StableKey }
        $cmSnapshot = [TerminalOrganizer.App.CrossMonitorSnapshotComposer]::Compose(
            $desktopText, $cmMonitors.ToArray(), $cmZones.ToArray(), $cmLabels.ToArray(),
            $cmPlans.ToArray(), $windows, $cmFacts.ToArray(), $cmSnaps.ToArray(),
            [TerminalOrganizer.App.PriorityOverride[]]@($cmOverrides), $cmOrganizedKey, [int]$settings.TitleRules.DefaultRank)
        $cmPlan = [TerminalOrganizer.Core.Overflow.CrossMonitorPlanner]::Plan($cmSnapshot)
        Write-Output ('dry run: redistribute planned=' + $cmPlan.Moves.Length + ' applied=0 (pure plan; C3 selects policy)')
        foreach ($cmMove in $cmPlan.Moves) {
            Write-Output ('  ' + $cmMove.ToWhatIfText().Replace("`n", "`n  "))
        }
    }
}
catch {
    Fail-Dry ('acquisition failed: ' + $_.Exception.Message) 2
}
Write-Output 'dry run is informational (morning checklist); it is NOT an acceptance claim and never moves a window'
exit 0
