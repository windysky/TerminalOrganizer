# SPEC-TRAY-007 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md and plan.md section J, never from the code under test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# B3 pinned copy characters, built from [char] codes so this file stays pure ASCII
# (same rule as the B2 block below; PS 5.1 reads a BOM-less .ps1 as ANSI).
$script:B3Lq = [string][char]0x201C        # left curly double quote
$script:B3Rq = [string][char]0x201D        # right curly double quote
$script:B3Em = [string][char]0x2014        # em dash
$script:B3Times = [string][char]0x00D7     # multiplication sign

# --- shared fixtures (Core shapes per prior suites; App shapes per plan.md F) ---

function New-TWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height, [int]$Dpi = 96) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, $Dpi
}

function New-TMonitor([int]$Number) {
    New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        ('PCI\VEN_00&DEV_0' + $Number), ('MON-' + $Number), '0', ('SN-' + $Number), $Number, `
        (($Number - 1) * 1920), 0, 1920, 1152, (New-TWorkArea (($Number - 1) * 1920) 0 1920 1152)
}

function New-TTab([string]$Title) {
    New-Object TerminalOrganizer.Core.Windows.TabSnapshot -ArgumentList $Title, $Title, $null
}

function New-TWindow([string]$Title, [bool]$Identified, [long]$Handle) {
    $tabs = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.TabSnapshot]'
    $tabs.Add((New-TTab $Title))
    $unmatched = @()
    if (-not $Identified) { $unmatched = @($Title) }
    New-Object TerminalOrganizer.Core.Windows.WindowSnapshot -ArgumentList `
        ([IntPtr]$Handle), $null, $null, $tabs.ToArray(), $Identified, [string[]]$unmatched, $Identified
}

Describe 'AC-001 Menu model (REQ-SHELL-001)' {
    It '2 monitors + 3 identified + 1 unidentified window produce the pinned entry order as a pure data list' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build(
            @((New-TMonitor 2), (New-TMonitor 1)),  # deliberately unsorted input
            @(
                (New-TWindow 'w-A' $true 101),
                (New-TWindow 'w-B' $true 102),
                (New-TWindow 'w-C' $true 103),
                (New-TWindow 'unk-D' $false 104)
            ))
        $entries.Length | Should Be 7
        ($entries | ForEach-Object { $_.Label }) -join '|' |
            Should BeExactly 'Organize on Monitor 1|Organize on Monitor 2|w-A|w-B|w-C|unk-D|Exit'
        ($entries | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'OrganizeMonitor,OrganizeMonitor,SetManager,SetManager,SetManager,LabelWindow,Exit'
        $entries[0].MonitorNumber | Should Be 1
        $entries[1].MonitorNumber | Should Be 2
        $entries[2].WindowHandle.ToInt64() | Should Be 101
        $entries[5].WindowHandle.ToInt64() | Should Be 104
        # Pure data list: the model type lives in the App assembly, carrying no WinForms type.
        $entries[0].GetType().Assembly.GetName().Name | Should BeExactly 'TerminalOrganizer.App'
    }
}

Describe 'AC-004 Settings store (REQ-SET-001)' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('tray007-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $missingPath = Join-Path $tempDir 'missing-settings.json'
    $settingsPath = Join-Path $tempDir 'settings.json'

    It 'a missing file loads the defaults (hotkey Ctrl+Alt+O, default log path, no manager)' {
        $store = New-Object TerminalOrganizer.App.SettingsStore -ArgumentList $missingPath
        $s = $store.Load()
        $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
        $s.LogPath | Should BeExactly (Join-Path $env:LOCALAPPDATA 'TerminalOrganizer\terminal-organizer.log')
        $s.ManagerWindowName | Should BeNullOrEmpty
    }

    It 'a malformed file loads the defaults without throwing' {
        Set-Content -Path $settingsPath -Value '{"hotkey": "Ctrl' -Encoding ASCII
        $store = New-Object TerminalOrganizer.App.SettingsStore -ArgumentList $settingsPath
        $s = $store.Load()
        $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
        $s.LogPath | Should BeExactly (Join-Path $env:LOCALAPPDATA 'TerminalOrganizer\terminal-organizer.log')
        $s.ManagerWindowName | Should BeNullOrEmpty
    }

    It 'a legacy ManagerStore-shaped file keeps the field defaults and reads the manager choice' {
        Set-Content -Path $settingsPath -Value '{"managerWindowName":"OLD-MGR"}' -Encoding ASCII
        $store = New-Object TerminalOrganizer.App.SettingsStore -ArgumentList $settingsPath
        $s = $store.Load()
        $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
        $s.LogPath | Should BeExactly (Join-Path $env:LOCALAPPDATA 'TerminalOrganizer\terminal-organizer.log')
        $s.ManagerWindowName | Should BeExactly 'OLD-MGR'
    }

    It 'save -> load roundtrip preserves hotkey, logPath and manager; the Core ManagerStore reads the same file' {
        $store = New-Object TerminalOrganizer.App.SettingsStore -ArgumentList $settingsPath
        $store.Save((New-Object TerminalOrganizer.App.AppSettings -ArgumentList 'Ctrl+Shift+T', 'C:\temp\my.log', 'MGR-X'))
        $s = $store.Load()
        $s.Hotkey | Should BeExactly 'Ctrl+Shift+T'
        $s.LogPath | Should BeExactly 'C:\temp\my.log'
        $s.ManagerWindowName | Should BeExactly 'MGR-X'
        # Sole-file rule (spec D-3): the ZONE-005 ManagerStore semantics ride the same file.
        $coreStore = New-Object TerminalOrganizer.Core.Assignment.ManagerStore -ArgumentList $settingsPath
        $coreStore.Load() | Should BeExactly 'MGR-X'
    }

    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

Describe 'AC-005 Hotkey parser (REQ-SET-002)' {
    function Invoke-TryParse([string]$Text) {
        $caught = $null
        $result = $null
        try { $result = [TerminalOrganizer.App.HotkeyParser]::Parse($Text) } catch { $caught = $_ }
        @{ Result = $result; Caught = $caught }
    }

    It 'plan.md J.2 rows: Ctrl+Alt+O and Ctrl+Shift+F5 parse to the pinned flag/vk pairs' {
        $r = Invoke-TryParse 'Ctrl+Alt+O'
        $r.Caught | Should BeNullOrEmpty
        $r.Result.Success | Should Be $true
        $r.Result.ModifierFlags | Should Be 3   # MOD_CONTROL 0x2 | MOD_ALT 0x1
        $r.Result.VirtualKey | Should Be 0x4F
        $r2 = Invoke-TryParse 'Ctrl+Shift+F5'
        $r2.Caught | Should BeNullOrEmpty
        $r2.Result.Success | Should Be $true
        $r2.Result.ModifierFlags | Should Be 6  # MOD_CONTROL 0x2 | MOD_SHIFT 0x4
        $r2.Result.VirtualKey | Should Be 0x74
    }

    It 'unknown modifier, missing key and empty input yield a failure result, never an exception' {
        foreach ($bad in @('Hotkey+O', 'Ctrl+Alt', '')) {
            $r = Invoke-TryParse $bad
            $r.Caught | Should BeNullOrEmpty
            $r.Result.Success | Should Be $false
        }
    }

    It 'modifier and key tokens are case-insensitive: ctrl+alt+o == Ctrl+Alt+O' {
        $r = Invoke-TryParse 'ctrl+alt+o'
        $r.Caught | Should BeNullOrEmpty
        $r.Result.Success | Should Be $true
        $r.Result.ModifierFlags | Should Be 3
        $r.Result.VirtualKey | Should Be 0x4F
    }
}

Describe 'AC-009 Notice table (REQ-NOTI-001)' {
    It 'each plan.md J.1 kind maps to its exact string (8 kinds)' {
        # B3: MergeNotConfirmed and ManagerSkipped carry the new concise copy; the
        # ManagerSkipped {monitor} placeholder arrives through the 3-argument Text form.
        $cases = @(
            @{ Kind = 'UnsupportedLayout';       Arg = 'focus';           Monitor = $null; Expected = "FancyZones layout 'focus' is not supported on this monitor; nothing was changed." },
            @{ Kind = 'InvalidLayout';           Arg = 'malformed-json';  Monitor = $null; Expected = 'The FancyZones layout data on this monitor is invalid (malformed-json); nothing was changed.' },
            @{ Kind = 'NoAppliedLayout';         Arg = $null;             Monitor = $null; Expected = 'No FancyZones layout is applied to this monitor; nothing was changed.' },
            @{ Kind = 'MergeNotConfirmed';       Arg = 'YODA3';           Monitor = $null; Expected = 'Merge for ' + $script:B3Lq + 'YODA3' + $script:B3Rq + ' was not confirmed. The original window remains open.' },
            @{ Kind = 'MergeConfirmedNotClosed'; Arg = 'YODA4';           Monitor = $null; Expected = "The tab for 'YODA4' was created but its old window could not be closed; close it by hand." },
            @{ Kind = 'HelperMissing';           Arg = 'OC_YODA2';        Monitor = $null; Expected = "Attach helper not found for 'OC_YODA2'; the merge was skipped." },
            @{ Kind = 'HotkeyConflict';          Arg = 'Ctrl+Alt+O';      Monitor = $null; Expected = "Hotkey 'Ctrl+Alt+O' is already taken; use the tray menu." },
            @{ Kind = 'ManagerSkipped';          Arg = 'MGR';             Monitor = 'Center ' + $script:B3Em + ' 1920' + $script:B3Times + '1152'; Expected = 'Manager ' + $script:B3Lq + 'MGR' + $script:B3Rq + ' is not open on Center ' + $script:B3Em + ' 1920' + $script:B3Times + '1152. Other windows were organized.' }
        )
        $cases.Count | Should Be 8
        foreach ($c in $cases) {
            $kind = [TerminalOrganizer.App.NoticeKind]::Parse([TerminalOrganizer.App.NoticeKind], $c.Kind)
            [TerminalOrganizer.App.NoticeTable]::Text($kind, $c.Arg, $c.Monitor) | Should BeExactly $c.Expected
        }
    }
}

# --- AC-006/007/008: the controller under fake ports (plan.md B.1) ---

# Standing zone set (plan.md J.1, same as prior suites).
function New-CZones {
    @(
        [TerminalOrganizer.Core.Geometry.Zone]::new(0, 16, 16, 456, 1120),
        [TerminalOrganizer.Core.Geometry.Zone]::new(1, 488, 16, 944, 1120),
        [TerminalOrganizer.Core.Geometry.Zone]::new(2, 1448, 16, 456, 1120)
    )
}

$script:CHandles = @{}
$script:CSeed = 5000
function New-CFact {
    param([string]$Id, [int]$Top = 0, [int]$Left = 0, [bool]$Identified = $true,
          [int]$Width = 400, [int]$Height = 300)
    $script:CSeed = $script:CSeed + 1
    $script:CHandles[$Id] = [IntPtr]$script:CSeed
    [TerminalOrganizer.Core.Assignment.WindowFact]::new(
        $Id, $script:CHandles[$Id], $Id, $Identified,
        $Left, $Top, $Width, $Height, $false, $false, $false)
}

function New-CSession([string]$Name, [string]$Kind, [string]$CommandLine) {
    $kindEnum = [TerminalOrganizer.Core.Windows.SessionKind]::Parse([TerminalOrganizer.Core.Windows.SessionKind], $Kind)
    New-Object TerminalOrganizer.Core.Windows.SessionRecord -ArgumentList $Name, $kindEnum, $CommandLine
}

function New-CSnap {
    param([string]$Id, [string[]]$TabTitles, $TabSessions, [bool]$Identified, [bool]$Mergeable)
    $tabs = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.TabSnapshot]'
    for ($i = 0; $i -lt $TabTitles.Count; $i++) {
        $raw = $TabTitles[$i]
        $stripped = [TerminalOrganizer.Core.Windows.TitleNormalizer]::StripPrefix($raw)
        $session = $null
        if ($i -lt $TabSessions.Count) { $session = $TabSessions[$i] }
        $tabs.Add((New-Object TerminalOrganizer.Core.Windows.TabSnapshot -ArgumentList $raw, $stripped, $session))
    }
    $unmatched = @()
    if (-not $Identified) { $unmatched = @($tabs | ForEach-Object { $_.StrippedTitle }) }
    New-Object TerminalOrganizer.Core.Windows.WindowSnapshot -ArgumentList `
        ([TerminalOrganizer.Core.Windows.WindowIdentity]::new($script:CHandles[$Id], 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', $TabTitles[0])), $null, $null, $tabs.ToArray(), $Identified, [string[]]$unmatched, $Mergeable, ([TerminalOrganizer.Core.Windows.TabReadQuality]::Trusted)
}

# The AC-006 standing scenario: 3 zones + 7 windows (MGR, A..F). Zone z2 stacks B(base), C,
# D, E, F; the merge planner plans E (Local) and F (Remote) into B.
function New-CScenario {
    $yoda3Cmd = 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA3 20'
    $remoteCmd = 'wsl.exe -d Ubuntu --exec /tmp/rdl_attach.sh user@host YODA2'
    $script:CFacts = @(
        (New-CFact 'MGR' -Top 600 -Left 100),
        (New-CFact 'A'   -Top 0   -Left 0),
        (New-CFact 'B'   -Top 0   -Left 500),
        (New-CFact 'C'   -Top 400 -Left 0),
        (New-CFact 'D'   -Top 800 -Left 0 -Identified:$false),
        (New-CFact 'E'   -Top 900 -Left 0),
        (New-CFact 'F'   -Top 1000 -Left 0)
    )
    $script:CSnaps = @(
        (New-CSnap 'MGR' @('OC_MGR')  @((New-CSession 'MGR' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach MGR 20')) $true $true),
        (New-CSnap 'A'   @('OC_YODA1') @((New-CSession 'YODA1' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1 20')) $true $true),
        (New-CSnap 'B'   @('OC_YODA2B') @((New-CSession 'YODA2B' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA2B 20')) $true $true),
        (New-CSnap 'C'   @('NC_OPS1')  @((New-CSession 'OPS1' 'WindowsNative' 'powershell.exe -NoProfile -Command "echo hi"')) $true $false),
        (New-CSnap 'D'   @('WD_UNK1')  @() $false $false),
        (New-CSnap 'E'   @('OC_YODA3') @((New-CSession 'YODA3' 'Local' $yoda3Cmd)) $true $true),
        (New-CSnap 'F'   @('OC_YODA2') @((New-CSession 'YODA2' 'Remote' $remoteCmd)) $true $true)
    )
}

# Fake-port controller harness. Modes: LayoutMode supported|unsupported|invalid;
# ProbeMode true|false|throw; MergeMode merged|confirm-timeout|confirmed-not-closed.
function New-CController {
    New-CScenario
    $script:Seq = New-Object 'System.Collections.Generic.List[string]'
    $script:Notices = New-Object 'System.Collections.Generic.List[string]'
    $script:AssignedRows = New-Object 'System.Collections.Generic.List[string]'
    $script:LayoutMode = 'supported'
    $script:ProbeMode = 'true'
    $script:MergeMode = 'merged'
    $script:Zones = New-CZones
    $script:A4Guard = $null

    $desktopSrc = [TerminalOrganizer.App.CurrentDesktopSource] {
        $script:Seq.Add('desktop'); '{00000000-0000-4000-8000-000000000007}'
    }
    $layoutRes = [TerminalOrganizer.App.LayoutResolution] {
        param($monitor, $desktop)
        $script:Seq.Add('layout')
        if ($script:LayoutMode -eq 'unsupported') {
            [TerminalOrganizer.Core.Layouts.LayoutResult]::Unsupported(
                [TerminalOrganizer.Core.Layouts.LayoutReason]::Focus, 'focus layout', 'focus', $null)
        }
        elseif ($script:LayoutMode -eq 'invalid') {
            [TerminalOrganizer.Core.Layouts.LayoutResult]::Invalid(
                [TerminalOrganizer.Core.Layouts.LayoutReason]::MalformedJson, 'bad json near offset 3', 'grid')
        }
        else {
            [TerminalOrganizer.Core.Layouts.LayoutResult]::Supported('grid', $null, 0, $script:Zones, @())
        }
    }
    $windowDisc = [TerminalOrganizer.App.WindowDiscovery] {
        param($monitor, $desktop)
        $script:Seq.Add('windows')
        New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:CFacts, $script:CSnaps
    }
    $assigner = [TerminalOrganizer.Core.Overflow.AssignmentComputation] {
        param($zones, $facts, $manager)
        $script:Seq.Add('assign')
        foreach ($f in $facts) { $script:AssignedRows.Add(($f.Id + ':' + $f.Identified)) }
        [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zones, $facts, $manager)
    }
    $mergePlanner = [TerminalOrganizer.App.MergePlanning] {
        param($plan, $snaps)
        $script:Seq.Add('mergeplan')
        [TerminalOrganizer.Core.Overflow.MergePlanner]::Plan($plan, $snaps)
    }
    $probe = [TerminalOrganizer.App.HelperExistsProbe] {
        param($merge)
        $script:Seq.Add('probe')
        if ($script:ProbeMode -eq 'false') { $false }
        elseif ($script:ProbeMode -eq 'throw') { throw 'probe infrastructure failed' }
        else { $true }
    }
    $executor = [TerminalOrganizer.Core.Overflow.MergeExecution] {
        param($merge)
        $script:Seq.Add('merge:' + $merge.SourceWindowId)
        if ($script:MergeMode -eq 'confirm-timeout') {
            [TerminalOrganizer.Core.Overflow.MergeOutcome]::ConfirmTimeout($merge.SourceWindowId)
        }
        elseif ($script:MergeMode -eq 'confirmed-not-closed') {
            [TerminalOrganizer.Core.Overflow.MergeOutcome]::ConfirmedNotClosed($merge.SourceWindowId)
        }
        else {
            [TerminalOrganizer.Core.Overflow.MergeOutcome]::Merged($merge.SourceWindowId)
        }
    }
    $placer = [TerminalOrganizer.Core.Overflow.PlacementPass] {
        param($plan)
        $script:Seq.Add('place')
        @()
    }
    $notifySink = [TerminalOrganizer.App.NoticeSink] {
        param($text)
        $script:Notices.Add($text)
    }
    $labels = New-Object TerminalOrganizer.App.LabelRegistry
    $controller = New-Object TerminalOrganizer.App.OrganizeController -ArgumentList `
        $desktopSrc, $layoutRes, $windowDisc, $assigner, $mergePlanner, $probe, $executor, $placer, $notifySink, $labels, $null, `
        ([TerminalOrganizer.App.CommitGuardCreation]{ param($m,$d,$l)
            if ($null -ne $script:A4Guard) { return $script:A4Guard }
            $signature = [TerminalOrganizer.Core.Monitors.CommitSignature]::new(
                [TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@($m)),
                [TerminalOrganizer.Core.Monitors.LayoutSignature]::new($m.StableKey.CanonicalValue,$d,$l.Kind,$l.LayoutType,$l.Zones))
            $script:A4Current = $signature
            [TerminalOrganizer.Core.Monitors.CommitGuard]::new($signature, [TerminalOrganizer.Core.Monitors.CommitSignatureSource]{ $script:A4Current })
        }), $null
    @{ Controller = $controller; Labels = $labels }
}

Describe 'AC-006 Pipeline orchestration, failure-first (REQ-PIPE-001/003/005)' {
    It 'Unsupported layout (type "focus") emits the UnsupportedLayout notice verbatim and NOTHING downstream is called' {
        $h = New-CController
        $script:LayoutMode = 'unsupported'
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $result.Completed | Should Be $false
        $script:Notices.Count | Should Be 1
        $script:Notices[0] | Should BeExactly "FancyZones layout 'focus' is not supported on this monitor; nothing was changed."
        ($script:Seq -join ',') | Should BeExactly 'desktop,layout'
    }

    It 'Invalid layout (MalformedJson) emits the InvalidLayout notice carrying the reason detail and stops' {
        $h = New-CController
        $script:LayoutMode = 'invalid'
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $result.Completed | Should Be $false
        $script:Notices.Count | Should Be 1
        $script:Notices[0] | Should BeExactly 'The FancyZones layout data on this monitor is invalid (bad json near offset 3); nothing was changed.'
        ($script:Seq -join ',') | Should BeExactly 'desktop,layout'
    }

    It '3 zones + 7 windows (2 mergeable, Remote helper absent): sequence is EXACTLY desktop,layout,windows,assign,mergeplan,probe,merges,assign,place; HelperMissing skips only the Remote merge' {
        $h = New-CController
        $script:ProbeMode = 'false'
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $result.Completed | Should Be $true
        # Canonical token 'merges' is the merge-execution phase; here exactly one merge
        # executes (E, Local) while F (Remote, probe false) is skipped before execution.
        ($script:Seq -join ',') | Should BeExactly 'desktop,layout,windows,assign,mergeplan,probe,merge:E,assign,place'
        # Computation-before-mutation (REQ-PIPE-003): the placer's first call follows the
        # merge outcomes (index order of the recording above).
        $result.Outcomes.Length | Should Be 1
        $result.Outcomes[0].SourceWindowId | Should BeExactly 'E'
        $result.HelperMissingSkips | Should Be 1
        $script:Notices.Count | Should Be 1
        $script:Notices[0] | Should BeExactly "Attach helper not found for 'YODA2'; the merge was skipped."
        # Survivor reassignment: E merged away, F skipped (survives) -> both assign calls
        # saw 7 then 6 windows.
        $script:AssignedRows.Count | Should Be 13
    }

    It 'a probe that FAILS does not skip the merge: fail-open - both merges still execute' {
        $h = New-CController
        $script:ProbeMode = 'throw'
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $result.Completed | Should Be $true
        $result.Outcomes.Length | Should Be 2
        ($script:Seq -join ',') | Should BeExactly 'desktop,layout,windows,assign,mergeplan,probe,merge:E,merge:F,assign,place'
        @($script:Notices | Where-Object { $_ -like 'Attach helper*' }).Count | Should Be 0
    }

    It 'a merge abort emits MergeNotConfirmed with the session name; confirmed-not-closed emits MergeConfirmedNotClosed' {
        $h = New-CController
        $script:MergeMode = 'confirm-timeout'
        $null = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $script:Notices.Count | Should Be 2
        # B3 concise merge copy (curly quotes pinned in the notice table).
        $script:Notices.Contains('Merge for ' + $script:B3Lq + 'YODA3' + $script:B3Rq + ' was not confirmed. The original window remains open.') | Should Be $true
        $script:Notices.Contains('Merge for ' + $script:B3Lq + 'YODA2' + $script:B3Rq + ' was not confirmed. The original window remains open.') | Should Be $true

        $h2 = New-CController
        $script:MergeMode = 'confirmed-not-closed'
        $null = $h2.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $script:Notices.Count | Should Be 2
        $script:Notices.Contains("The tab for 'YODA3' was created but its old window could not be closed; close it by hand.") | Should Be $true
        $script:Notices.Contains("The tab for 'YODA2' was created but its old window could not be closed; close it by hand.") | Should Be $true
    }
}

Describe 'AC-007 Idempotent second run (REQ-PIPE-002)' {
    It 'A4 guard mismatch blocks both merge and placement before first mutation' {
        $h = New-CController
        $script:A4Guard = [TerminalOrganizer.Core.Monitors.CommitGuard]::new($null, [TerminalOrganizer.Core.Monitors.CommitSignatureSource]{ $null })
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $result.TopologyAborted | Should Be $true
        $result.Completed | Should Be $false
        ($script:Seq -join ',') | Should Not Match 'merge:|place'
        $script:Notices.Contains('Monitor layout changed during organize. No remaining moves were applied.') | Should Be $true
    }
    It 'A4 placement aborts remaining moves after the first guard failure' {
        $script:A4MoveCount = 0
        $script:A4GuardCount = 0
        $placer = [TerminalOrganizer.Core.Assignment.WindowPlacer]::new(
            [Func[TerminalOrganizer.Core.Assignment.PlannedMove,bool]]{ param($m) $script:A4MoveCount++; $true },
            [Action[IntPtr]]{ param($h) throw 'unexpected restore' })
        $moves = @(1..3 | ForEach-Object { [TerminalOrganizer.Core.Assignment.PlannedMove]::new(('w' + $_), [IntPtr]$_, $_, 0,0,400,300,$true,$false,$false,$false) })
        $plan = [TerminalOrganizer.Core.Assignment.AssignmentPlan]::new($moves,$false,$null,$null)
        $guard = [TerminalOrganizer.Core.Assignment.MutationGuard]{ $script:A4GuardCount++; $script:A4GuardCount -ne 2 }
        $result = $placer.Apply($plan,$guard)
        $script:A4MoveCount | Should Be 1
        @($result | Where-Object { $_.Error -eq 'topology-aborted' }).Count | Should Be 2
    }
    It 'A4 menu payload resolves physical identity after renumbering' {
        $before = New-TMonitor 2
        $after = [TerminalOrganizer.Core.Monitors.MonitorInfo]::new($before.InterfacePath, $before.MonitorId, $before.Instance, $before.Serial, 1, $before.MonitorLeft, $before.MonitorTop, $before.MonitorWidth, $before.MonitorHeight, $before.WorkArea)
        $entry = ([TerminalOrganizer.App.TrayMenuBuilder]::Build(@($before), @()))[0]
        $entry.MonitorKey.EqualsKey($after.StableKey) | Should Be $true
        [TerminalOrganizer.Core.Monitors.MonitorSelector]::ResolveUnique(@($after), $entry.MonitorKey).Number | Should Be 1
    }
    It 'A2 settled unequal zones need no placement without a manager on repeated runs' {
        $h = New-CController
        $script:CFacts = @(
            (New-CFact 'C' -Top 16 -Left 1448 -Width 456 -Height 1120),
            (New-CFact 'A' -Top 16 -Left 16 -Width 456 -Height 1120),
            (New-CFact 'B' -Top 16 -Left 488 -Width 944 -Height 1120)
        )
        $script:CSnaps = @()
        1..2 | ForEach-Object {
            $result = $h.Controller.Run((New-TMonitor 1), $null)
            @($result.FinalPlan.Moves | Where-Object { $_.MoveRequired }).Count | Should Be 0
        }
        $script:Seq.Contains('place') | Should Be $false
    }
    It 'a second run over the settled screen performs ZERO merge calls and ZERO place calls' {
        $h = New-CController
        $null = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)   # first run: E merged into B
        # Settle: survivors sit exactly on their zone rects, no stacking (3 windows, 3 zones).
        $script:CFacts = @(
            (New-CFact 'MGR' -Top 16  -Left 488  -Width 944 -Height 1120),
            (New-CFact 'A'   -Top 16  -Left 16   -Width 456 -Height 1120),
            (New-CFact 'B'   -Top 16  -Left 1448 -Width 456 -Height 1120)
        )
        $script:CSnaps = @()
        $script:Seq.Clear()
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        $result.Completed | Should Be $true
        $result.Outcomes.Length | Should Be 0
        $seqText = $script:Seq -join ','
        ($seqText -like '*merge:*') | Should Be $false
        ($seqText -like '*place*') | Should Be $false
        $seqText | Should BeExactly 'desktop,layout,windows,assign,mergeplan,assign'
    }
}

Describe 'AC-008 Run-scoped labels (REQ-PIPE-004)' {
    It 'LabelRegistry stores, reads and clears run-scoped labels' {
        $registry = New-Object TerminalOrganizer.App.LabelRegistry
        $registry.Count | Should Be 0
        $registry.SetLabel([IntPtr]777, 'YODA5')
        $registry.TryGetLabel([IntPtr]777) | Should BeExactly 'YODA5'
        $registry.TryGetLabel([IntPtr]888) | Should BeNullOrEmpty
        $registry.Count | Should Be 1
        $registry.Clear()
        $registry.Count | Should Be 0
        $registry.TryGetLabel([IntPtr]777) | Should BeNullOrEmpty
    }

    It 'a label set in the same run-lifetime feeds the matcher input; a fresh controller instance does NOT see it' {
        # Same-lifetime controller: the discovery adapter consults controller.Labels (the
        # registry handed in at construction) when composing the matcher input.
        $registry = New-Object TerminalOrganizer.App.LabelRegistry
        $script:MatcherInputs = New-Object 'System.Collections.Generic.List[string]'
        $script:AssignedRows = New-Object 'System.Collections.Generic.List[string]'
        $script:Notices = New-Object 'System.Collections.Generic.List[string]'
        $script:CHandles = @{}
        $script:CSeed = 5000

        $disc = [TerminalOrganizer.App.WindowDiscovery] {
            param($monitor, $desktop)
            # Fixed handles (301/302): a label must survive across runs of the same lifetime.
            $label = $script:R.TryGetLabel([IntPtr]302)
            $xIdentified = ($null -ne $label)
            $facts = @(
                [TerminalOrganizer.Core.Assignment.WindowFact]::new('A', [IntPtr]301, 'A', $true, 0, 0, 400, 300, $false, $false, $false),
                [TerminalOrganizer.Core.Assignment.WindowFact]::new('X', [IntPtr]302, 'X', $xIdentified, 0, 800, 400, 300, $false, $false, $false)
            )
            $snapA = New-Object TerminalOrganizer.Core.Windows.WindowSnapshot -ArgumentList ([IntPtr]301), $null, $null, @(), $true, @(), $true
            if ($label) {
                $script:MatcherInputs.Add($label)
                $tabsX = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.TabSnapshot]'
                $tabsX.Add((New-Object TerminalOrganizer.Core.Windows.TabSnapshot -ArgumentList 'WD_UNK1', 'WD_UNK1', (New-CSession $label 'Local' 'labeled')))
                $snapX = New-Object TerminalOrganizer.Core.Windows.WindowSnapshot -ArgumentList ([IntPtr]302), $null, $null, $tabsX.ToArray(), $true, @(), $true
            }
            else {
                $script:MatcherInputs.Add('<no labels>')
                $tabsX = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.TabSnapshot]'
                $tabsX.Add((New-Object TerminalOrganizer.Core.Windows.TabSnapshot -ArgumentList 'WD_UNK1', 'WD_UNK1', $null))
                $snapX = New-Object TerminalOrganizer.Core.Windows.WindowSnapshot -ArgumentList ([IntPtr]302), $null, $null, $tabsX.ToArray(), $false, @('WD_UNK1'), $false
            }
            New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $facts, @($snapA, $snapX)
        }
        $assigner = [TerminalOrganizer.Core.Overflow.AssignmentComputation] {
            param($zones, $facts, $manager)
            foreach ($f in $facts) { $script:AssignedRows.Add(($f.Id + ':' + $f.Identified)) }
            [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zones, $facts, $manager)
        }
        $noopPlanner = [TerminalOrganizer.App.MergePlanning] { param($plan, $snaps) [TerminalOrganizer.Core.Overflow.MergePlan]::new(@(), @()) }
        $trueProbe = [TerminalOrganizer.App.HelperExistsProbe] { param($m) $true }
        $mergedExec = [TerminalOrganizer.Core.Overflow.MergeExecution] { param($m) [TerminalOrganizer.Core.Overflow.MergeOutcome]::Merged($m.SourceWindowId) }
        $noopPlace = [TerminalOrganizer.Core.Overflow.PlacementPass] { param($plan) @() }
        $notifySink = [TerminalOrganizer.App.NoticeSink] { param($text) $script:Notices.Add($text) }
        $desktopSrc = [TerminalOrganizer.App.CurrentDesktopSource] { $null }
        $layoutRes = [TerminalOrganizer.App.LayoutResolution] {
            param($monitor, $desktop)
            [TerminalOrganizer.Core.Layouts.LayoutResult]::Supported('grid', $null, 0, (New-CZones), @())
        }

        $script:R = $registry
        $c1 = New-Object TerminalOrganizer.App.OrganizeController -ArgumentList `
            $desktopSrc, $layoutRes, $disc, $assigner, $noopPlanner, $trueProbe, $mergedExec, $noopPlace, $notifySink, $registry
        # The controller exposes the SAME registry instance (the tray menu labels through it).
        [object]::ReferenceEquals($c1.Labels, $registry) | Should Be $true

        $null = $c1.Run((New-TMonitor 1), $null)   # no label yet (2 assign calls: initial + survivor reassign)
        $script:MatcherInputs[0] | Should BeExactly '<no labels>'
        ($script:AssignedRows -join ',') | Should BeExactly 'A:True,X:False,A:True,X:False'

        $c1.Labels.SetLabel([IntPtr]302, 'YODA5')
        $null = $c1.Run((New-TMonitor 1), $null)   # same run-lifetime: label feeds the matcher
        $script:MatcherInputs[1] | Should BeExactly 'YODA5'
        ($script:AssignedRows -join ',') | Should BeExactly 'A:True,X:False,A:True,X:False,A:True,X:True,A:True,X:True'

        # Fresh controller (fresh process analogue): its own registry sees no label.
        $freshRegistry = New-Object TerminalOrganizer.App.LabelRegistry
        $script:R = $freshRegistry
        $c2 = New-Object TerminalOrganizer.App.OrganizeController -ArgumentList `
            $desktopSrc, $layoutRes, $disc, $assigner, $noopPlanner, $trueProbe, $mergedExec, $noopPlace, $notifySink, $freshRegistry
        $null = $c2.Run((New-TMonitor 1), $null)
        $script:MatcherInputs[2] | Should BeExactly '<no labels>'
        ($script:AssignedRows -join ',') | Should BeExactly 'A:True,X:False,A:True,X:False,A:True,X:True,A:True,X:True,A:True,X:False,A:True,X:False'
    }
}

# --- AC-002/003/010/011: lifecycle surface, log sink, build outputs ---

Describe 'AC-002 Hotkey registration surface (REQ-SHELL-002)' {
    It 'RegisterHotKey(mods, vk) succeeds through the register port; WM_HOTKEY dispatch organizes under the cursor; a failed registration returns false and emits HotkeyConflict with the configured string' {
        $script:L2Record = New-Object 'System.Collections.Generic.List[string]'
        $script:L2Notices = New-Object 'System.Collections.Generic.List[string]'
        $script:L2RegResult = $true
        $register = [TerminalOrganizer.App.RegisterHotKeyCall] {
            param($id, $mods, $vk)
            $script:L2Record.Add(('register:{0}:{1}:{2}' -f $id, $mods, $vk)); $script:L2RegResult
        }
        $unregister = [TerminalOrganizer.App.UnregisterHotKeyCall] { param($id) $script:L2Record.Add('unregister'); $true }
        $organize = [Action] { $script:L2Record.Add('organize-under-cursor') }
        $disposeIcon = [Action] { $script:L2Record.Add('dispose-icon') }
        $flushLog = [Action] { $script:L2Record.Add('flush-log') }
        $notify = [TerminalOrganizer.App.NoticeSink] { param($text) $script:L2Notices.Add($text) }
        $life = New-Object TerminalOrganizer.App.TrayLifecycle -ArgumentList `
            $register, $unregister, 'Ctrl+Alt+O', $notify, $organize, $disposeIcon, $flushLog

        [TerminalOrganizer.App.TrayLifecycle]::HotkeyId | Should Be 1
        $life.RegisterHotKey(3, 0x4F) | Should Be $true
        ($script:L2Record -join ',') | Should BeExactly 'register:1:3:79'

        $life.DispatchHotkey()
        ($script:L2Record -join ',') | Should BeExactly 'register:1:3:79,organize-under-cursor'

        $script:L2RegResult = $false
        $life.RegisterHotKey(3, 0x4F) | Should Be $false
        $script:L2Notices.Count | Should Be 1
        $script:L2Notices[0] | Should BeExactly "Hotkey 'Ctrl+Alt+O' is already taken; use the tray menu."
    }
}

Describe 'AC-003 Clean exit (REQ-SHELL-003)' {
    It 'the exit path unregisters the hotkey, disposes the icon and flushes the log - the recorder receives the three calls in order' {
        $script:L3Record = New-Object 'System.Collections.Generic.List[string]'
        $register = [TerminalOrganizer.App.RegisterHotKeyCall] { param($id, $mods, $vk) $true }
        $unregister = [TerminalOrganizer.App.UnregisterHotKeyCall] { param($id) $script:L3Record.Add('unregister:' + $id); $true }
        $organize = [Action] { }
        $disposeIcon = [Action] { $script:L3Record.Add('dispose-icon') }
        $flushLog = [Action] { $script:L3Record.Add('flush-log') }
        $notify = [TerminalOrganizer.App.NoticeSink] { param($text) }
        $life = New-Object TerminalOrganizer.App.TrayLifecycle -ArgumentList `
            $register, $unregister, 'Ctrl+Alt+O', $notify, $organize, $disposeIcon, $flushLog
        $life.Exit()
        ($script:L3Record -join ',') | Should BeExactly 'unregister:1,dispose-icon,flush-log'
    }
}

Describe 'AC-009 balloon == log composition' {
    It 'one notice text fans out identically to the log sink and the balloon (fake recorder equality)' {
        $script:LoggedText = New-Object 'System.Collections.Generic.List[string]'
        $script:BalloonedText = New-Object 'System.Collections.Generic.List[string]'
        $logAction = [Action[string]] { param($t) $script:LoggedText.Add($t) }
        $balloonAction = [Action[string]] { param($t) $script:BalloonedText.Add($t) }
        $sink = [TerminalOrganizer.App.NoticeDispatch]::Combine($logAction, $balloonAction)
        $text = [TerminalOrganizer.App.NoticeTable]::Text([TerminalOrganizer.App.NoticeKind]::HelperMissing, 'OC_YODA2')
        $sink.Invoke($text)
        $script:LoggedText.Count | Should Be 1
        $script:BalloonedText.Count | Should Be 1
        $script:LoggedText[0] | Should BeExactly $text
        $script:BalloonedText[0] | Should BeExactly $text
    }
}

Describe 'AC-010 Log sink degradation (REQ-NOTI-002)' {
    It 'appending to an unwritable path drops the line without throwing; a writable temp path receives the timestamped line' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('tray007log-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $dirAsPath = Join-Path $tempDir 'blocked-as-directory'
            New-Item -ItemType Directory -Path $dirAsPath | Out-Null
            $bad = New-Object TerminalOrganizer.App.LogSink -ArgumentList $dirAsPath
            $caught = $null
            try { $bad.Append('this line is dropped') } catch { $caught = $_ }
            $caught | Should BeNullOrEmpty

            $goodPath = Join-Path $tempDir 'app.log'
            $good = New-Object TerminalOrganizer.App.LogSink -ArgumentList $goodPath
            $good.Append('hello tray')
            $good.Flush()
            $lines = @(Get-Content -LiteralPath $goodPath)
            $lines.Count | Should Be 1
            $lines[0] | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} hello tray$'
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }
}

Describe 'AC-011 Build outputs (REQ-APP-001)' {
    It 'build.ps1 exits 0 with zero warnings producing BOTH outputs; the exe manifest declares PerMonitorV2; Program is STA' {
        $buildScript = Join-Path $repoRoot 'build.ps1'
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Byte-loaded assemblies above keep the outputs unlocked while they rebuild.
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $buildScript
        $code = $LASTEXITCODE
        $code | Should Be 0
        (($out | Out-String) -match 'warning CS') | Should Be $false
        Test-Path $coreDll | Should Be $true
        Test-Path $appExe | Should Be $true

        $manifestPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\app.manifest'
        [IO.File]::ReadAllText($manifestPath).Contains('PerMonitorV2') | Should Be $true

        $exeText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($appExe))
        $exeText.Contains('PerMonitorV2') | Should Be $true

        $programPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\Program.cs'
        [IO.File]::ReadAllText($programPath).Contains('[STAThread]') | Should Be $true
    }
}

Describe 'AC-012 organize-once tool (REQ-APP-002)' {
    $tool = Join-Path $repoRoot 'tools\organize-once.ps1'
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    It '-SelfTest under PS 5.1 exercises the AC-005 + AC-006 rows, one PASS/FAIL line each, exits 0 only on all-pass' {
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $tool -SelfTest
        $code = $LASTEXITCODE
        $code | Should Be 0
        (@($out | Where-Object { $_ -like 'FAIL: *' }).Count) | Should Be 0
        (@($out | Where-Object { $_ -like 'PASS: ac005/*' }).Count -ge 1) | Should Be $true
        (@($out | Where-Object { $_ -like 'PASS: ac006/*' }).Count -ge 1) | Should Be $true
    }

    It '-WhatIf swaps BOTH mutation ports (merge executor AND placer) for recording fakes and proves zero mutations' {
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $tool -WhatIf -Monitor 1
        $code = $LASTEXITCODE
        $code | Should Be 0
        $text = $out -join "`n"
        $text.Contains('BOTH mutation ports swapped') | Should Be $true
        $text.Contains('executed=0 (recording fake; no wt launch)') | Should Be $true
        $text.Contains('issued=0 (recording fake; no SetWindowPos)') | Should Be $true
    }

    It 'live mode labels itself a manual verification step (source-level assertion; live behaviour is the morning checklist)' {
        $source = [IO.File]::ReadAllText($tool)
        # The pinned label is assembled with [char]0x2014 so the tool file stays pure ASCII.
        $source.Contains("'manual verification step ' + [char]0x2014") | Should Be $true
        $source.Contains('Write-Output $ManualLabel') | Should Be $true
        $source.Contains('MORNING CHECKLIST') | Should Be $true
    }
}


Describe 'A1 merge default-off and label trust' {
    It 'A3 empty fail-closed discovery never reaches assignment or merge and emits no manager notice' {
        $h = New-CController
        $script:CFacts = @()
        $script:CSnaps = @()
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true)
        ($script:Seq -join ',') | Should BeExactly 'desktop,layout,windows'
        # B3: the zero-window run now emits exactly the NoWindows information notice
        # (label derived from the single monitor: Center + WxH); no manager warning.
        $script:Notices.Count | Should Be 1
        $script:Notices[0] | Should BeExactly ('No Windows Terminal windows on Center ' + $script:B3Em + ' 1920' + $script:B3Times + '1152 ' + $script:B3Em + ' nothing to organize.')
        $result.Completed | Should Be $true
    }
    It 'A3 unknown desktop is excluded before state UIA and session reads' {
        $mon = New-TMonitor 1
        $id = [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]1, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', 'fixture')
        $rows = @(
            [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]1, $mon, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true), $id),
            [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]2, $mon, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($false)),
            [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]3, $mon, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Failure('unknown'))
        )
        $script:A3Reads = New-Object 'System.Collections.Generic.List[long]'
        $state = [Func[IntPtr,TerminalOrganizer.Core.Assignment.WindowState]] { param($h) $script:A3Reads.Add($h.ToInt64()); [TerminalOrganizer.Core.Assignment.WindowState]::new(0,0,400,300,$false,$false,$false) }
        $tabs = [TerminalOrganizer.Core.Overflow.TabTitleRead] { param($h) $script:A3Reads.Add($h.ToInt64()); [TerminalOrganizer.Core.Windows.TabTitleResult]::Ok(@('OTHER')) }
        $sessions = [TerminalOrganizer.App.SessionRecordsRead] { param($pids) @() }
        $result = [TerminalOrganizer.App.DiscoveryPolicy]::Acquire($rows, $mon, $state, $tabs, $sessions, $null)
        $result.EnumeratedCount | Should Be 3
        $result.SkippedOtherDesktopCount | Should Be 1
        $result.SkippedUnknownDesktopCount | Should Be 1
        $result.Facts.Count | Should Be 1
        ($script:A3Reads -join ',') | Should BeExactly '1,1'
        $invalid = [Func[IntPtr,TerminalOrganizer.Core.Assignment.WindowState]] { param($h) [TerminalOrganizer.Core.Assignment.WindowState]::Invalid([TerminalOrganizer.Core.Assignment.WindowStateReadStatus]::StyleUnavailable, 'style failed') }
        $script:A3Reads.Clear()
        $result = [TerminalOrganizer.App.DiscoveryPolicy]::Acquire($rows, $mon, $invalid, $tabs, $sessions, $null)
        $result.Facts.Count | Should Be 0
        $result.SkippedUnknownStateCount | Should Be 1
        $result.Snapshots[0].Mergeable | Should Be $false
        $script:A3Reads.Count | Should Be 0
    }
    It 'a label cannot manufacture merge eligibility or a command line' {
        $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]707, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', 'unknown')
        $tab = [TerminalOrganizer.Core.Windows.TabSnapshot]::new('unknown', 'unknown', $null)
        $snapshot = [TerminalOrganizer.Core.Windows.WindowSnapshot]::new($identity, $null, $null, @($tab), $false, @('unknown'), $false, [TerminalOrganizer.Core.Windows.TabReadQuality]::Trusted)
        $labels = [TerminalOrganizer.App.LabelRegistry]::new()
        $labels.SetLabel([IntPtr]707, 'YODA3')
        $composition = [TerminalOrganizer.App.AppSettings].Assembly.GetType('TerminalOrganizer.App.Composition')
        $method = $composition.GetMethod('ApplyLabels', [Reflection.BindingFlags]'NonPublic,Static')
        $shots = $method.Invoke($null, [object[]]@([TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($snapshot), $labels))
        $shots[0].Identified | Should Be $true
        $shots[0].Mergeable | Should Be $false
        $shots[0].TabReadQuality.ToString() | Should BeExactly 'Trusted'
        $shots[0].Tabs[0].Session.CommandLine | Should BeNullOrEmpty
    }
    It 'legacy settings default off and explicit merge setting round-trips' {
        $path = Join-Path $TestDrive 'a1-settings.json'
        [IO.File]::WriteAllText($path, '{"managerWindowName":"MGR"}')
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $store.Load().MergeEnabled | Should Be $false
        $store.Save([TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log', 'MGR', $true))
        $store.Load().MergeEnabled | Should Be $true
    }
    It 'merge defaults off and placement still runs without planner probe or executor' {
        $h = New-CController
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR')
        @($result.Outcomes).Count | Should Be 0
        ($script:Seq -join ',') | Should BeExactly 'desktop,layout,windows,assign,assign,place'
        ([TerminalOrganizer.App.AppSettings]::new($null, $null, $null)).MergeEnabled | Should Be $false
    }
}

# --- A5: single instance + operation serialization (night-design-2026-09-25 unit A5) ---

Describe 'A5 single-instance gate and bootstrap' {
    It 'A5 mutex name is per SID and session: BuildName(S-1-5-21-7, 3) is the exact pinned string' {
        [TerminalOrganizer.App.InstanceGate]::BuildName('S-1-5-21-7', 3) |
            Should BeExactly 'Local\TerminalOrganizer.S-1-5-21-7.Session.3'
    }

    It 'A5 second instance exits before shell construction: gate not acquired -> no shell action, return 0' {
        # The design's "fake gate Acquired=false": an uninitialized InstanceGate object has
        # Acquired=false and a null-mutex no-op Dispose. Byte-load identity rules out an
        # Add-Type fake implementing the interface, so the reflective fake is the closest
        # deterministic equivalent.
        $fake = [Runtime.Serialization.FormatterServices]::GetUninitializedObject(
            [TerminalOrganizer.App.InstanceGate])
        $fake.Acquired | Should Be $false
        $script:A5Gate = $fake
        $script:A5ShellCount = 0
        $rc = [TerminalOrganizer.App.AppBootstrap]::Run(
            [Func[TerminalOrganizer.App.IInstanceGate]] { $script:A5Gate },
            [Action] { $script:A5ShellCount = $script:A5ShellCount + 1 })
        $rc | Should Be 0
        $script:A5ShellCount | Should Be 0

        # A null gate is treated the same way: fail closed, never run unguarded.
        $rc2 = [TerminalOrganizer.App.AppBootstrap]::Run(
            [Func[TerminalOrganizer.App.IInstanceGate]] { $null },
            [Action] { $script:A5ShellCount = $script:A5ShellCount + 1 })
        $rc2 | Should Be 0
        $script:A5ShellCount | Should Be 0
    }

    It 'A5 acquired instance constructs the shell once and disposes the gate (mutex freed for the next acquire)' {
        $gate = [TerminalOrganizer.App.InstanceGate]::TryAcquire()
        $gate.Acquired | Should Be $true
        $script:A5Gate = $gate
        $script:A5ShellCount = 0
        $rc = [TerminalOrganizer.App.AppBootstrap]::Run(
            [Func[TerminalOrganizer.App.IInstanceGate]] { $script:A5Gate },
            [Action] { $script:A5ShellCount = $script:A5ShellCount + 1 })
        $rc | Should Be 0
        $script:A5ShellCount | Should Be 1
        # Dispose evidence: Run's using released the named mutex, so a fresh acquire succeeds.
        $again = [TerminalOrganizer.App.InstanceGate]::TryAcquire()
        $again.Acquired | Should Be $true
        $again.Dispose()
    }
}

# Shared A5 serialization fixtures: one hidden marshalling form (created handle), a
# per-test state bag the worker thread writes through, and a bounded DoEvents pump.
Add-Type -AssemblyName System.Windows.Forms
$script:A5Form = New-Object System.Windows.Forms.Form
$script:A5Form.Visible = $false
$null = $script:A5Form.Handle   # Control.BeginInvoke requires a created handle.

# PS 5.1 scriptblock delegates CANNOT execute on foreign threads ("There is no Runspace
# available" — they fail silently), so the fake work is a PowerShell CLASS method:
# compiled IL that the coordinator's C# worker invokes directly. The class is defined
# through Invoke-Expression AFTER the byte-load above so its typed parameters resolve,
# and each test news up its own instance (per-test state isolation).
#
# Harness constraint (measured): a worker that BLOCKS (kernel WaitOne or Thread.Sleep)
# freezes this host's main-thread pump for the full block duration, so cross-thread
# blocking is unrepresentable here. The fake worker therefore runs to completion
# immediately; a request stays "in flight" for as long as its completion marshal sits
# unprocessed in the message queue — the coordinator only leaves the busy state when
# the UI thread pumps (Wait-A5Pump), which gives every test a deterministic busy
# window with no worker-side waiting.
if (-not ('A5FakeWorker' -as [type])) {
    Invoke-Expression @'
    class A5FakeWorker {
        [System.Collections.Hashtable]$State
        A5FakeWorker([System.Collections.Hashtable]$s) { $this.State = $s }
        [TerminalOrganizer.App.OperationCompletion] Run([TerminalOrganizer.App.OrganizeRequest] $request, [System.Threading.CancellationToken] $token) {
            $this.State['Log'].Enqueue('work:' + $request.Source)
            if ($request.ResolveMonitorUnderCursor) { $this.State['Log'].Enqueue('resolved:' + $this.State['Cursor']) }
            else { $this.State['Log'].Enqueue('resolved:' + $request.MonitorKey.CanonicalValue) }
            $this.State['Token'] = $token
            $this.State['Log'].Enqueue('mutation')
            if ($this.State['Aborted']) {
                # F1: complete with a TopologyAborted run result so the completion
                # path exercises the shell's rerun wiring.
                $aborted = [TerminalOrganizer.App.OrganizeRunResult]::new($null, 0, $null, $null, $false, $true)
                return [TerminalOrganizer.App.OperationCompletion]::new($aborted, $false, $null)
            }
            return [TerminalOrganizer.App.OperationCompletion]::new($null, $false, $null)
        }
    }
'@
}

function New-A5State {
    # Synchronized so worker-thread writes are safe; Log entries are appended on the
    # worker thread and snapshotted on the UI thread via ToArray().
    [hashtable]::Synchronized(@{
        Cursor = 'M1'
        Token  = $null
        Log    = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
    })
}

function New-A5Coordinator([hashtable]$State) {
    $worker = [A5FakeWorker]::new($State)
    $work = [System.Delegate]::CreateDelegate(
        [TerminalOrganizer.App.OperationWork], $worker, 'Run')
    $phaseChanged = [Action[TerminalOrganizer.App.OperationPhase]] {
        param($p) $script:A5Phases.Add($p.ToString()) }
    $completed = [Action[TerminalOrganizer.App.OperationCompletion]] {
        param($c) $script:A5Completed.Add(('cancelled=' + $c.Cancelled)) }
    $coord = [TerminalOrganizer.App.OperationCoordinator]::new($script:A5Form, $work, $phaseChanged, $completed)
    @{ Coord = $coord; State = $State }
}

function Wait-A5Worker([scriptblock]$Condition) {
    # Worker-progress wait WITHOUT DoEvents: the completion marshal stays queued, so the
    # coordinator remains busy and later Requests coalesce. Plain Thread::Sleep only —
    # the PS Start-Sleep cmdlet measurably stalls while a threadpool worker is in flight.
    for ($i = 0; $i -lt 300; $i++) {
        if (& $Condition) { return $true }
        [System.Threading.Thread]::Sleep(10)
    }
    return (& $Condition)
}

function Wait-A5Pump([scriptblock]$Condition) {
    # DoEvents drains the coordinator's BeginInvoke marshals; bounded so a lost marshal
    # fails the test rather than hanging the suite.
    for ($i = 0; $i -lt 300; $i++) {
        if (& $Condition) { return $true }
        [System.Windows.Forms.Application]::DoEvents() | Out-Null
        [System.Threading.Thread]::Sleep(10)
    }
    return (& $Condition)
}

function Get-A5Log([hashtable]$State) { @($State['Log'].ToArray()) }

Describe 'A5 operation serialization (OperationCoordinator)' {
    It 'A5 duplicate requests coalesce to one rerun: A,B,C executes as A then C, never B' {
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $h = New-A5Coordinator (New-A5State)
        $coord = $h.Coord
        $state = $h.State
        $coord.IsBusy | Should Be $false
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'A'))
        $coord.IsBusy | Should Be $true
        # A's worker finished, but its completion marshal is still queued (no pump ran):
        # the coordinator stays busy, so B and C coalesce into the pending slot.
        (Wait-A5Worker { (Get-A5Log $state) -contains 'mutation' }) | Should Be $true
        $coord.IsBusy | Should Be $true
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'B'))
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'C'))
        $coord.HasPendingRerun | Should Be $true
        (Wait-A5Pump { -not $coord.IsBusy -and $coord.Phase.ToString() -eq 'Idle' }) | Should Be $true
        ((Get-A5Log $state | Where-Object { $_ -like 'work:*' }) -join ',') | Should BeExactly 'work:A,work:C'
        ((Get-A5Log $state) -join ',') |
            Should BeExactly 'work:A,resolved:M1,mutation,work:C,resolved:M1,mutation'
        $coord.HasPendingRerun | Should Be $false
        $coord.Dispose()
    }

    It 'A5 pending under-cursor rerun resolves the monitor when the rerun begins, not when queued' {
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $h = New-A5Coordinator (New-A5State)
        $coord = $h.Coord
        $state = $h.State
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'A'))
        (Wait-A5Worker { (Get-A5Log $state) -contains 'resolved:M1' }) | Should Be $true
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'B'))
        $state['Cursor'] = 'M2'   # the cursor moves AFTER queueing, before the rerun begins
        (Wait-A5Pump { -not $coord.IsBusy -and $coord.Phase.ToString() -eq 'Idle' }) | Should Be $true
        ((Get-A5Log $state | Where-Object { $_ -like 'resolved:*' }) -join ',') |
            Should BeExactly 'resolved:M1,resolved:M2'
        $coord.Dispose()
    }

    It 'A5 Exit cancels the operation token and clears the pending rerun; the deferred exit runs exactly once' {
        # Harness deviation: the design's blocking worker ("waits on token, then asserts
        # mutation-recorder 0") is unrepresentable here — a blocking worker freezes this
        # host's main thread for the whole block. Verified instead against the same
        # contract surface: the token is cancelled, the pending rerun is cleared (B never
        # runs), and the exit action fires exactly once, only after the in-flight unit's
        # completion marshalled back.
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $h = New-A5Coordinator (New-A5State)
        $coord = $h.Coord
        $state = $h.State
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'A'))
        (Wait-A5Worker { $null -ne $state['Token'] }) | Should Be $true
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'B'))
        $coord.HasPendingRerun | Should Be $true
        $script:A5ExitCount = 0
        $coord.RequestExit([Action] { $script:A5ExitCount = $script:A5ExitCount + 1 })
        $state['Token'].IsCancellationRequested | Should Be $true
        $coord.HasPendingRerun | Should Be $false
        $script:A5ExitCount | Should Be 0
        (Wait-A5Pump { $script:A5ExitCount -eq 1 }) | Should Be $true
        $script:A5ExitCount | Should Be 1
        ((Get-A5Log $state | Where-Object { $_ -like 'work:*' }) -join ',') | Should BeExactly 'work:A'
        $script:A5Completed.Count | Should Be 1
        $coord.IsBusy | Should Be $false
        $coord.Dispose()
    }

    It 'A5 Exit during an in-flight operation defers the exit action until work completion marshals back' {
        # A5 models the in-flight mutation window as the busy phase: the coordinator must
        # let the indivisible work unit finish and only then run the deferred exit; the
        # mid-mutation token checkpoints are the worker's (B4 extends them). The busy
        # window here is the unprocessed completion marshal (see the fixtures comment).
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $h = New-A5Coordinator (New-A5State)
        $coord = $h.Coord
        $state = $h.State
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'A'))
        (Wait-A5Worker { (Get-A5Log $state) -contains 'mutation' }) | Should Be $true
        $script:A5ExitCount = 0
        $coord.RequestExit([Action] { $script:A5ExitCount = $script:A5ExitCount + 1 })
        $script:A5ExitCount | Should Be 0   # completion not marshalled yet: exit must be deferred
        (Wait-A5Pump { $script:A5ExitCount -eq 1 }) | Should Be $true
        $script:A5ExitCount | Should Be 1
        ((Get-A5Log $state) -contains 'mutation') | Should Be $true   # the unit finished first
        $coord.Dispose()
    }

    It 'A4 topology abort arms exactly one rerun through the coordinator (F1)' {
        # F1 (P0 audit round 1): TrayShell.OrganizeCompleted must consume
        # OrganizeRunResult.TopologyAborted — arm exactly ONE rerun of the
        # remembered request, and a rerun that aborts again must not re-arm (no
        # retry loop). The suite never constructs TrayShell (real NotifyIcon
        # surface), so the wiring is pinned through an uninitialized TrayShell
        # whose private coordinator field points at the real coordinator: each
        # marshalled completion invokes the real private OrganizeCompleted,
        # while the private activeRequest field stands in for ExecuteOrganize's
        # remembering (a one-liner reviewed in the diff).
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $state = New-A5State
        $state['Aborted'] = $true
        # TrayShell is internal: resolve through a public App type's assembly (the
        # suite's established pattern for internal types).
        $shellType = [TerminalOrganizer.App.OperationCoordinator].Assembly.GetType(
            'TerminalOrganizer.App.TrayShell', $true)
        $script:F1Shell = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($shellType)
        $script:F1Completed = $shellType.GetMethod(
            'OrganizeCompleted', [Reflection.BindingFlags]'NonPublic,Instance')
        $completed = [Action[TerminalOrganizer.App.OperationCompletion]] {
            param($c)
            $script:A5Completed.Add(('aborted=' + ($null -ne $c.Result -and $c.Result.TopologyAborted)))
            $script:F1Completed.Invoke($script:F1Shell, @($c)) | Out-Null
        }
        $phaseChanged = [Action[TerminalOrganizer.App.OperationPhase]] {
            param($p) $script:A5Phases.Add($p.ToString()) }
        $work = [System.Delegate]::CreateDelegate(
            [TerminalOrganizer.App.OperationWork], ([A5FakeWorker]::new($state)), 'Run')
        $coord = [TerminalOrganizer.App.OperationCoordinator]::new(
            $script:A5Form, $work, $phaseChanged, $completed)
        $shellType.GetField('coordinator', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($script:F1Shell, $coord)
        $shellType.GetField('activeRequest', [Reflection.BindingFlags]'NonPublic,Instance').SetValue(
            $script:F1Shell, [TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'menu'))
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'menu'))
        (Wait-A5Pump { -not $coord.IsBusy -and $coord.Phase.ToString() -eq 'Idle' }) | Should Be $true
        # exactly one rerun: the aborted chain ran menu + topology-rerun, and the
        # second aborted completion reached OrganizeCompleted without arming again.
        ((Get-A5Log $state | Where-Object { $_ -like 'work:*' }) -join ',') |
            Should BeExactly 'work:menu,work:topology-rerun'
        ($script:A5Completed -join ',') | Should BeExactly 'aborted=True,aborted=True'
        $coord.HasPendingRerun | Should Be $false
        $coord.Dispose()
    }
}

Describe 'A5 busy menu state' {
    It 'A5 busy disables organize entries but leaves set-manager/label/Exit enabled; idle re-enables organize' {
        $monitors = @((New-TMonitor 1), (New-TMonitor 2))
        $windows = @((New-TWindow 'w-A' $true 101), (New-TWindow 'unk-D' $false 104))
        $busy = [TerminalOrganizer.App.TrayMenuBuilder]::Build($monitors, $windows, $true)
        $busy.Length | Should Be 5
        ($busy | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'OrganizeMonitor,OrganizeMonitor,SetManager,LabelWindow,Exit'
        $busy[0].Enabled | Should Be $false
        $busy[1].Enabled | Should Be $false
        $busy[2].Enabled | Should Be $true
        $busy[3].Enabled | Should Be $true
        $busy[4].Enabled | Should Be $true
        $idle = [TerminalOrganizer.App.TrayMenuBuilder]::Build($monitors, $windows, $false)
        (@($idle | ForEach-Object { $_.Enabled }) -contains $false) | Should Be $false
        # The two-argument AC-001 surface stays enabled.
        [TerminalOrganizer.App.TrayMenuBuilder]::Build($monitors, $windows)[0].Enabled | Should Be $true
    }
}

# --- B1: product icon and first-run onboarding (night-design-2026-09-25 unit B1) ---

Add-Type -AssemblyName System.Drawing

# Structural ICO parse: ICONDIR + ICONDIRENTRY rows (width/height 0 mean 256).
function Parse-B1Ico {
    param([byte[]]$Bytes)
    $entries = @()
    $count = [BitConverter]::ToUInt16($Bytes, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $base = 6 + 16 * $i
        $entries += @{
            W      = [int]$Bytes[$base]
            H      = [int]$Bytes[$base + 1]
            Planes = [int][BitConverter]::ToUInt16($Bytes, $base + 4)
            Bits   = [int][BitConverter]::ToUInt16($Bytes, $base + 6)
            Size   = [UInt32][BitConverter]::ToUInt32($Bytes, $base + 8)
            Offset = [UInt32][BitConverter]::ToUInt32($Bytes, $base + 12)
        }
    }
    @{
        Reserved = [int][BitConverter]::ToUInt16($Bytes, 0)
        Type     = [int][BitConverter]::ToUInt16($Bytes, 2)
        Count    = $count
        Entries  = $entries
    }
}

function Invoke-B1Generator {
    param([string]$Directory)
    $gen = Join-Path $repoRoot 'tools\generate-icon.ps1'
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $gen -OutputDirectory $Directory | Out-Null
    $LASTEXITCODE
}

function ConvertTo-B1IconBytes {
    param([System.Drawing.Icon]$Icon)
    $ms = New-Object System.IO.MemoryStream
    $Icon.Save($ms)
    ,($ms.ToArray())
}

Describe 'B1 Product icon and first-run onboarding' {
    $script:B1Temp = Join-Path ([IO.Path]::GetTempPath()) ('b1-' + [guid]::NewGuid().ToString('N'))

    It 'B1 generator produces six-image light and dark ICO files' {
        New-Item -ItemType Directory -Path $script:B1Temp | Out-Null
        (Invoke-B1Generator $script:B1Temp) | Should Be 0
        foreach ($name in @('TerminalOrganizer.ico', 'TerminalOrganizer.Dark.ico')) {
            $ico = Parse-B1Ico ([IO.File]::ReadAllBytes((Join-Path $script:B1Temp $name)))
            $ico.Reserved | Should Be 0
            $ico.Type | Should Be 1
            $ico.Count | Should Be 6
            ($ico.Entries | ForEach-Object { $_.W }) -join ',' | Should BeExactly '16,20,24,32,48,0'
            ($ico.Entries | ForEach-Object { $_.H }) -join ',' | Should BeExactly '16,20,24,32,48,0'
            ($ico.Entries | ForEach-Object { $_.Planes }) -join ',' | Should BeExactly '1,1,1,1,1,1'
            ($ico.Entries | ForEach-Object { $_.Bits }) -join ',' | Should BeExactly '32,32,32,32,32,32'
            # Payloads appended in ascending-size order behind the fixed 102-byte header.
            [int]$ico.Entries[0].Offset | Should Be 102
            for ($i = 1; $i -lt $ico.Count; $i++) {
                [int]$ico.Entries[$i].Offset | Should BeGreaterThan ([int]$ico.Entries[$i - 1].Offset)
            }
            $last = $ico.Entries[$ico.Count - 1]
            ([int]$last.Offset + [int]$last.Size) | Should Be (Get-Item (Join-Path $script:B1Temp $name)).Length
        }
    }

    It 'B1 generated icon bytes are deterministic' {
        $dirA = Join-Path $script:B1Temp 'runA'
        $dirB = Join-Path $script:B1Temp 'runB'
        New-Item -ItemType Directory -Path $dirA | Out-Null
        New-Item -ItemType Directory -Path $dirB | Out-Null
        (Invoke-B1Generator $dirA) | Should Be 0
        (Invoke-B1Generator $dirB) | Should Be 0
        foreach ($name in @('TerminalOrganizer.ico', 'TerminalOrganizer.Dark.ico')) {
            $hashA = (Get-FileHash -Algorithm SHA256 (Join-Path $dirA $name)).Hash
            $hashB = (Get-FileHash -Algorithm SHA256 (Join-Path $dirB $name)).Hash
            $hashA | Should Be $hashB
        }
    }

    It 'B1 App build embeds both named icon resources' {
        $names = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetManifestResourceNames()
        $names -contains 'TerminalOrganizer.ico' | Should Be $true
        $names -contains 'TerminalOrganizer.Dark.ico' | Should Be $true
    }

    It 'B1 executable has a non-default application icon' {
        $extracted = [System.Drawing.Icon]::ExtractAssociatedIcon($appExe)
        $extracted | Should Not BeNullOrEmpty
        $extractedBytes = ConvertTo-B1IconBytes $extracted
        $defaultBytes = ConvertTo-B1IconBytes ([System.Drawing.SystemIcons]::Application)
        [Convert]::ToBase64String($extractedBytes) | Should Not Be [Convert]::ToBase64String($defaultBytes)
        $extracted.Dispose()
    }

    It 'B1 runtime loader returns a clone after stream disposal' {
        $light = [TerminalOrganizer.App.IconLoader]::LoadApplicationIcon($false)
        $dark = [TerminalOrganizer.App.IconLoader]::LoadApplicationIcon($true)
        $light | Should Not BeNullOrEmpty
        $dark | Should Not BeNullOrEmpty
        # The loader's manifest-resource stream is closed inside the call; the returned
        # clone must still resolve size and handle afterwards.
        $light.Width | Should BeGreaterThan 0
        $light.Height | Should BeGreaterThan 0
        $light.Handle.ToInt64() | Should BeGreaterThan 0
        $dark.Handle.ToInt64() | Should BeGreaterThan 0
        $light.Dispose()
        $dark.Dispose()
    }

    It 'B1 source no longer assigns SystemIcons.Application' {
        $appSources = Get-ChildItem -Path (Join-Path $repoRoot 'src\TerminalOrganizer.App') -Recurse -Filter '*.cs'
        $count = 0
        foreach ($file in $appSources) {
            $count += ([regex]::Matches([IO.File]::ReadAllText($file.FullName), 'SystemIcons\.Application')).Count
        }
        $count | Should Be 0
    }

    It 'B1 icon flags appear after target winexe' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'build.ps1'))
        $targetIndex = $text.IndexOf('/target:winexe')
        $win32IconIndex = $text.IndexOf('/win32icon:')
        $resourceIndex = $text.IndexOf('/resource:')
        $targetIndex | Should BeGreaterThan -1
        $win32IconIndex | Should BeGreaterThan -1
        $resourceIndex | Should BeGreaterThan -1
        $targetIndex | Should BeLessThan $win32IconIndex
        $win32IconIndex | Should BeLessThan $resourceIndex
    }

    It 'B1 Core reference count remains eight' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'build.ps1'))
        $winexeAt = $text.IndexOf('/target:winexe')
        $winexeAt | Should BeGreaterThan -1
        $coreText = $text.Substring(0, $winexeAt)
        ([regex]::Matches($coreText, '/r:')).Count | Should Be 8
    }

    It 'B1 first run defaults incomplete and saves complete once' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('b1fr-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        $settingsPath = Join-Path $tempDir 'settings.json'
        try {
            # Missing settings => first run incomplete. Fixtures use ::new() because
            # New-Object output arrives PSObject-wrapped and cannot bind through the
            # reflective Invoke below.
            $store = [TerminalOrganizer.App.SettingsStore]::new($settingsPath)
            $current = $store.Load()
            $current.FirstRunCompleted | Should Be $false
            $current.StartWithWindows | Should Be $false

            # Simulated acknowledgement through the injectable dialog seam.
            $script:B1Calls = 0
            $show = [TerminalOrganizer.App.FirstRunShow] {
                param($icon, $hotkey, $startWith)
                $script:B1Calls = $script:B1Calls + 1
                [TerminalOrganizer.App.FirstRunResult]::new($true, $true)
            }
            $flowType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType('TerminalOrganizer.App.FirstRunFlow', $true)
            $ensure = $flowType.GetMethod('EnsureCompleted', [Reflection.BindingFlags]'NonPublic,Static')
            $null = $ensure.Invoke($null, @($current, $null, $store, $show))
            $script:B1Calls | Should Be 1

            # Persisted: a reload sees the completed first run.
            $reloaded = $store.Load()
            $reloaded.FirstRunCompleted | Should Be $true
            $reloaded.StartWithWindows | Should Be $true
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    It 'B1 completed first run does not invoke dialog seam' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('b1fr2-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        $settingsPath = Join-Path $tempDir 'settings.json'
        try {
            # ::new() fixtures (New-Object output is PSObject-wrapped and cannot
            # bind through the reflective Invoke below).
            $store = [TerminalOrganizer.App.SettingsStore]::new($settingsPath)
            $completed = [TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log', $null, $false, $true, $false)
            $script:B1Calls = 0
            $show = [TerminalOrganizer.App.FirstRunShow] {
                param($icon, $hotkey, $startWith)
                $script:B1Calls = $script:B1Calls + 1
                [TerminalOrganizer.App.FirstRunResult]::new($true, $true)
            }
            $flowType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType('TerminalOrganizer.App.FirstRunFlow', $true)
            $ensure = $flowType.GetMethod('EnsureCompleted', [Reflection.BindingFlags]'NonPublic,Static')
            $result = $ensure.Invoke($null, @($completed, $null, $store, $show))
            $script:B1Calls | Should Be 0
            $result.FirstRunCompleted | Should Be $true
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -Recurse -Force $script:B1Temp -ErrorAction SilentlyContinue
}

# --- Startup registration (start-with-Windows wiring unit) ---
# The fake port redirects every file effect to a temp .lnk while recording the
# canonical Startup path Apply hands it; nothing ever touches the real Startup
# folder. Fake state is $script:-scoped because delegate scriptblocks see only
# script scope (same rule as the B1 counters above).

Describe 'Startup registration (start-with-Windows)' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('su-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $canonical = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'TerminalOrganizer.lnk'

    $script:SuLnk = Join-Path $tempDir 'TerminalOrganizer.lnk'
    $script:SuExists = 0
    $script:SuCreate = 0
    $script:SuRemove = 0
    $script:SuPath = $null

    function New-SuPort {
        # The exists/create/remove trio over the temp .lnk; each records the path
        # the caller handed it.
        [TerminalOrganizer.App.StartupShortcutPort]::new(
            [Func[string,bool]] {
                param($path)
                $script:SuExists = $script:SuExists + 1
                $script:SuPath = $path
                Test-Path -LiteralPath $script:SuLnk
            },
            [Action[string]] {
                param($path)
                $script:SuCreate = $script:SuCreate + 1
                $script:SuPath = $path
                Set-Content -LiteralPath $script:SuLnk -Value 'lnk'
            },
            [Action[string]] {
                param($path)
                $script:SuRemove = $script:SuRemove + 1
                $script:SuPath = $path
                Remove-Item -LiteralPath $script:SuLnk -ErrorAction SilentlyContinue
            })
    }

    function Reset-SuFake {
        Remove-Item -LiteralPath $script:SuLnk -ErrorAction SilentlyContinue
        $script:SuExists = 0
        $script:SuCreate = 0
        $script:SuRemove = 0
        $script:SuPath = $null
    }

    It 'apply true creates the canonical Startup shortcut through the seam' {
        Reset-SuFake
        [TerminalOrganizer.App.StartupRegistration]::Apply($true, (New-SuPort))
        $script:SuCreate | Should Be 1
        $script:SuRemove | Should Be 0
        $script:SuPath | Should BeExactly $canonical
        Test-Path -LiteralPath $script:SuLnk | Should Be $true
    }

    It 'apply false removes an existing shortcut through the seam' {
        Reset-SuFake
        [TerminalOrganizer.App.StartupRegistration]::Apply($true, (New-SuPort))
        [TerminalOrganizer.App.StartupRegistration]::Apply($false, (New-SuPort))
        $script:SuCreate | Should Be 1
        $script:SuRemove | Should Be 1
        Test-Path -LiteralPath $script:SuLnk | Should Be $false
    }

    It 'apply true twice creates only once (idempotent ensure)' {
        Reset-SuFake
        [TerminalOrganizer.App.StartupRegistration]::Apply($true, (New-SuPort))
        [TerminalOrganizer.App.StartupRegistration]::Apply($true, (New-SuPort))
        $script:SuCreate | Should Be 1
        Test-Path -LiteralPath $script:SuLnk | Should Be $true
    }

    It 'apply false on a missing shortcut never invokes the remover' {
        Reset-SuFake
        [TerminalOrganizer.App.StartupRegistration]::Apply($false, (New-SuPort))
        $script:SuExists | Should Be 1
        $script:SuRemove | Should Be 0
        $script:SuCreate | Should Be 0
        $script:SuPath | Should BeExactly $canonical
    }

    It 'loading completed settings with startWithWindows false never touches the registration seam' {
        Reset-SuFake
        # Operator protection: a completed first run short-circuits before any
        # Apply, so a hand-made shortcut at the canonical path survives every
        # plain settings load.
        $store = [TerminalOrganizer.App.SettingsStore]::new((Join-Path $tempDir 'settings-load.json'))
        $completed = [TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log', $null, $false, $true, $false)
        $show = [TerminalOrganizer.App.FirstRunShow] {
            param($icon, $hotkey, $startWith)
            throw 'the dialog seam must not run for a completed first run'
        }
        $flowType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType('TerminalOrganizer.App.FirstRunFlow', $true)
        $ensure = $flowType.GetMethod('EnsureCompletedWithStartup', [Reflection.BindingFlags]'NonPublic,Static')
        $null = $ensure.Invoke($null, @($completed, $null, $store, $show, (New-SuPort)))
        $script:SuExists | Should Be 0
        $script:SuCreate | Should Be 0
        $script:SuRemove | Should Be 0
    }

    It 'first-run checkbox true persists and registers the shortcut' {
        Reset-SuFake
        $store = [TerminalOrganizer.App.SettingsStore]::new((Join-Path $tempDir 'settings-fr-true.json'))
        $current = $store.Load()
        $current.FirstRunCompleted | Should Be $false
        $show = [TerminalOrganizer.App.FirstRunShow] {
            param($icon, $hotkey, $startWith)
            [TerminalOrganizer.App.FirstRunResult]::new($true, $true)
        }
        $flowType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType('TerminalOrganizer.App.FirstRunFlow', $true)
        $ensure = $flowType.GetMethod('EnsureCompletedWithStartup', [Reflection.BindingFlags]'NonPublic,Static')
        $null = $ensure.Invoke($null, @($current, $null, $store, $show, (New-SuPort)))
        $script:SuCreate | Should Be 1
        $script:SuRemove | Should Be 0
        $reloaded = $store.Load()
        $reloaded.FirstRunCompleted | Should Be $true
        $reloaded.StartWithWindows | Should Be $true
    }

    It 'first-run checkbox false removes an existing shortcut' {
        Reset-SuFake
        # A shortcut already exists (e.g. from an earlier registration); only the
        # flow's own calls are counted after the setup.
        [TerminalOrganizer.App.StartupRegistration]::Apply($true, (New-SuPort))
        $script:SuExists = 0
        $script:SuCreate = 0
        $script:SuRemove = 0
        $store = [TerminalOrganizer.App.SettingsStore]::new((Join-Path $tempDir 'settings-fr-false.json'))
        $current = $store.Load()
        $show = [TerminalOrganizer.App.FirstRunShow] {
            param($icon, $hotkey, $startWith)
            [TerminalOrganizer.App.FirstRunResult]::new($true, $false)
        }
        $flowType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType('TerminalOrganizer.App.FirstRunFlow', $true)
        $ensure = $flowType.GetMethod('EnsureCompletedWithStartup', [Reflection.BindingFlags]'NonPublic,Static')
        $null = $ensure.Invoke($null, @($current, $null, $store, $show, (New-SuPort)))
        $script:SuCreate | Should Be 0
        $script:SuRemove | Should Be 1
        Test-Path -LiteralPath $script:SuLnk | Should Be $false
        $store.Load().StartWithWindows | Should Be $false
    }

    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

# --- B2: physical-monitor menu and canonical manager UX (night-design-2026-09-25 unit B2) ---

# Pinned label characters are built from [char] codes so this file stays pure ASCII
# (PS 5.1 reads a BOM-less .ps1 as ANSI; a literal U+2014 would arrive mojibake'd).
$script:B2Em = [string][char]0x2014        # em dash
$script:B2En = [string][char]0x2013        # en dash (bucket names)
$script:B2Times = [string][char]0x00D7     # multiplication sign
$script:B2Ellipsis = [string][char]0x2026  # ellipsis

function New-B2Monitor {
    param([int]$Number, [bool]$Primary, [int]$Left, [int]$Top, [int]$Width = 1920, [int]$Height = 1080)
    [TerminalOrganizer.Core.Monitors.MonitorInfo]::new(
        $null, ('PCI\VEN_00&DEV_0' + $Number), ('MON-' + $Number), '0', ('SN-' + $Number), $Number, $Primary,
        $Left, $Top, $Width, $Height, (New-TWorkArea $Left $Top $Width $Height))
}

function New-B2Tab {
    param([string]$Title, [string]$SessionName)
    $session = $null
    if ($SessionName) {
        $session = [TerminalOrganizer.Core.Windows.SessionRecord]::new(
            $SessionName, [TerminalOrganizer.Core.Windows.SessionKind]::Local,
            ('wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach ' + $SessionName))
    }
    [TerminalOrganizer.Core.Windows.TabSnapshot]::new($Title, $Title, $session)
}

# One fact+snapshot pair joined by handle (DiscoveryPolicy shape: fact name = raw title).
function New-B2Pair {
    param([long]$Handle, [string]$RawTitle, [object[]]$Tabs, [bool]$Identified)
    $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new(
        [IntPtr]$Handle, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', $RawTitle)
    $unmatched = @()
    if (-not $Identified) { $unmatched = @($Tabs | ForEach-Object { $_.Title }) }
    $snapshot = [TerminalOrganizer.Core.Windows.WindowSnapshot]::new(
        $identity, $null, $null, [TerminalOrganizer.Core.Windows.TabSnapshot[]]$Tabs,
        $Identified, [string[]]$unmatched, $false, [TerminalOrganizer.Core.Windows.TabReadQuality]::Trusted)
    $fact = [TerminalOrganizer.Core.Assignment.WindowFact]::new(
        ('w' + $Handle), [IntPtr]$Handle, $RawTitle, $Identified, 0, 0, 400, 300, $false, $false, $false)
    @{ Handle = $Handle; Fact = $fact; Snapshot = $snapshot }
}

function Get-B2Root([object[]]$Entries, [string]$Kind) {
    @($Entries | Where-Object { $_.Kind.ToString() -eq $Kind })[0]
}

function Get-B2Kind([object]$Entry, [string]$Kind) {
    @($Entry.Children | Where-Object { $_.Kind.ToString() -eq $Kind })
}

# Every checked SetManager row anywhere under the given entry (direct or inside buckets).
function Get-B2CheckedCandidates([object]$Entry) {
    $found = @()
    foreach ($child in @($Entry.Children)) {
        if ($null -eq $child) { continue }
        if ($child.Kind.ToString() -eq 'SetManager' -and $child.Checked) { $found += $child }
        if (@($child.Children).Length -gt 0) { $found += Get-B2CheckedCandidates $child }
    }
    $found
}

function New-B2State {
    param([object[]]$Monitors, [object[]]$Windows, $Selector, $Facts = $null, $Resolution = $null, [bool]$Busy = $false)
    $snaps = @($Windows | ForEach-Object { $_.Snapshot })
    if ($null -eq $Facts) { $Facts = @($Windows | ForEach-Object { $_.Fact }) }
    if ($null -eq $Resolution) {
        $Resolution = [TerminalOrganizer.Core.Assignment.ManagerResolver]::Resolve(
            $Selector, [TerminalOrganizer.Core.Assignment.WindowFact[]]$Facts,
            [TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps)
    }
    [TerminalOrganizer.App.TrayMenuState]::new($Busy, 'Ctrl+Alt+O',
        [TerminalOrganizer.Core.Monitors.MonitorInfo[]]$Monitors,
        [TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps,
        $Selector, $Resolution, $null, $false)
}

Describe 'B2 Physical-monitor menu and canonical manager UX' {
    It 'B2 physical labels derive left right and primary from rectangles' {
        $left = New-B2Monitor 1 $false 0 0
        $right = New-B2Monitor 2 $true 1920 0
        $monitors = @($left, $right)
        [TerminalOrganizer.App.TrayMenuBuilder]::DerivePhysicalLabel($left, $monitors) |
            Should BeExactly ('Left ' + $script:B2Em + ' 1920' + $script:B2Times + '1080')
        [TerminalOrganizer.App.TrayMenuBuilder]::DerivePhysicalLabel($right, $monitors) |
            Should BeExactly ('Right (Primary) ' + $script:B2Em + ' 1920' + $script:B2Times + '1080')
    }

    It 'B2 vertical topology derives Above and Below' {
        $top = New-B2Monitor 1 $false 0 0
        $bottom = New-B2Monitor 2 $false 0 1080
        $monitors = @($top, $bottom)
        [TerminalOrganizer.App.TrayMenuBuilder]::DerivePhysicalLabel($top, $monitors) |
            Should BeExactly ('Above ' + $script:B2Em + ' 1920' + $script:B2Times + '1080')
        [TerminalOrganizer.App.TrayMenuBuilder]::DerivePhysicalLabel($bottom, $monitors) |
            Should BeExactly ('Below ' + $script:B2Em + ' 1920' + $script:B2Times + '1080')
    }

    It 'B2 physical labels do not contain Monitor 1 or Monitor 2' {
        $monitors = @((New-B2Monitor 1 $true 0 0), (New-B2Monitor 2 $false 1920 0), (New-B2Monitor 3 $false 3840 0))
        foreach ($monitor in $monitors) {
            [TerminalOrganizer.App.TrayMenuBuilder]::DerivePhysicalLabel($monitor, $monitors) |
                Should Not Match 'Monitor \d'
        }
        # The built menu rows carry the derived labels unchanged.
        $state = New-B2State $monitors @() ([TerminalOrganizer.Core.Assignment.ManagerSelector]::None())
        $root = Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'OrganizeMonitorRoot'
        foreach ($row in @($root.Children)) { $row.Label | Should Not Match 'Monitor \d' }
    }

    It 'B2 menu tree has pinned root order' {
        $windows = @(
            (New-B2Pair 9101 'mgr-raw' @((New-B2Tab 'OC_MGR' 'MGR')) $true),
            (New-B2Pair 9102 'unk-raw' @((New-B2Tab 'WD_UNK1' $null)) $false)
        )
        $monitors = @((New-B2Monitor 1 $true 0 0))
        $none = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-B2State $monitors $windows $none))
        ($entries | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'Status,Separator,OrganizeUnderCursor,Separator,OrganizeMonitorRoot,Separator,ManagerRoot,Separator,OverflowRoot,Separator,LabelsAndPrioritiesRoot,Separator,LastResult,OpenLog,Settings,Version,Exit'
        $entries[0].Label | Should BeExactly ('TerminalOrganizer ' + $script:B2Em + ' Ready')
        $entries[0].Enabled | Should Be $false
        $entries[2].Label | Should BeExactly 'Organize monitor under cursor    Ctrl+Alt+O'
        $entries[2].Enabled | Should Be $true
        $busyEntries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-B2State $monitors $windows $none -Busy $true))
        $busyEntries[0].Label | Should BeExactly ('Organizing' + $script:B2Ellipsis)
        $busyEntries[2].Enabled | Should Be $false
    }

    It 'Version row sits above Exit, disabled, and survives the busy banner' {
        $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\AssemblyVersion.cs'))
        $expected = [regex]::Match($source, 'AssemblyInformationalVersion\("([^"]+)"\)').Groups[1].Value
        $monitors = @((New-B2Monitor 1 $true 0 0))
        $none = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
        foreach ($busy in @($false, $true)) {
            $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-B2State $monitors @() $none -Busy $busy))
            $row = $entries[$entries.Length - 2]
            $row.Kind.ToString() | Should BeExactly 'Version'
            $row.Label | Should BeExactly ('TerminalOrganizer v' + $expected)
            $row.Enabled | Should Be $false
        }
    }

    It 'Version: App, Core and UiaProbe all carry the src\AssemblyVersion.cs version' {
        $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\AssemblyVersion.cs'))
        $expected = [regex]::Match($source, 'AssemblyInformationalVersion\("([^"]+)"\)').Groups[1].Value
        $expected | Should Match '^\d+\.\d+\.\d+$'
        [TerminalOrganizer.App.AppVersion]::Text | Should BeExactly $expected
        foreach ($name in @('TerminalOrganizer.App.exe', 'TerminalOrganizer.Core.dll', 'TerminalOrganizer.UiaProbe.exe')) {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $repoRoot ('bin\' + $name)))
            $info.FileVersion | Should BeExactly ($expected + '.0')
            $info.ProductVersion | Should BeExactly $expected
        }
    }

    It 'B2 current manager is checked and exposes Show Clear' {
        $windows = @(
            (New-B2Pair 9201 'mgr-raw' @((New-B2Tab 'OC_MGR' 'MGR')) $true),
            (New-B2Pair 9202 'other-raw' @((New-B2Tab 'OC_OTHER' 'OTHER')) $true)
        )
        $selector = [TerminalOrganizer.Core.Assignment.ManagerResolver]::CreateSelector($windows[0].Snapshot, $null)
        $selector.Kind.ToString() | Should BeExactly 'Session'
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build(
            (New-B2State @((New-B2Monitor 1 $true 0 0)) $windows $selector))
        $managerRoot = Get-B2Root $entries 'ManagerRoot'
        $current = Get-B2Kind $managerRoot 'ManagerCurrent'
        $current.Count | Should Be 1
        $current[0].Label | Should BeExactly 'Current: MGR'
        $current[0].Enabled | Should Be $false
        $show = Get-B2Kind $managerRoot 'ShowManager'
        $show.Count | Should Be 1
        $show[0].Enabled | Should Be $true
        $clear = Get-B2Kind $managerRoot 'ClearManager'
        $clear.Count | Should Be 1
        $clear[0].Enabled | Should Be $true
        $choose = Get-B2Kind $managerRoot 'ManagerCandidateGroup'
        $choose.Count | Should Be 1
        @($choose[0].Children).Length | Should Be 2
        $checked = Get-B2CheckedCandidates $managerRoot
        $checked.Count | Should Be 1
        $checked[0].Label | Should BeExactly 'OC_MGR'
    }

    It 'B2 ambiguous canonical session is explicit' {
        $windows = @(
            (New-B2Pair 9301 'raw-a' @((New-B2Tab 'OC_MGR_A' 'MGR')) $true),
            (New-B2Pair 9302 'raw-b' @((New-B2Tab 'OC_MGR_B' 'MGR')) $true)
        )
        # Stale raw title: neither candidate's freshly created selector equals the persisted
        # one, so the ambiguity selects nothing implicitly (never first-match).
        $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
            [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'MGR', 'stale-raw')
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build(
            (New-B2State @((New-B2Monitor 1 $true 0 0)) $windows $selector))
        $managerRoot = Get-B2Root $entries 'ManagerRoot'
        $current = (Get-B2Kind $managerRoot 'ManagerCurrent')[0]
        $current.Label | Should BeExactly ('Current: MGR ' + $script:B2Em + ' ambiguous (2 windows)')
        (Get-B2Kind $managerRoot 'ShowManager')[0].Enabled | Should Be $false
        (Get-B2Kind $managerRoot 'ClearManager')[0].Enabled | Should Be $true
        (Get-B2CheckedCandidates $managerRoot).Count | Should Be 0
    }

    It 'B2 Clear writes None and unchecks old candidate' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('b2-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $windows = @((New-B2Pair 9401 'mgr-raw' @((New-B2Tab 'OC_MGR' 'MGR')) $true))
            $monitors = @((New-B2Monitor 1 $true 0 0))
            $store = [TerminalOrganizer.App.SettingsStore]::new((Join-Path $tempDir 'settings.json'))
            $selector = [TerminalOrganizer.Core.Assignment.ManagerResolver]::CreateSelector($windows[0].Snapshot, $null)
            $store.Save([TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log',
                $selector.RawTitleFallback, $false, $true, $false, $selector))
            $loaded = $store.Load()
            $loaded.ManagerSelector.Kind.ToString() | Should BeExactly 'Session'
            (Get-B2CheckedCandidates (Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build(
                (New-B2State $monitors $windows $loaded.ManagerSelector))) 'ManagerRoot')).Count | Should Be 1

            # Clear manager persists the None selector (the shell's Clear action shape).
            $store.Save([TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log', $null, $false, $true, $false,
                [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()))
            $cleared = $store.Load()
            $cleared.ManagerSelector.IsEmpty | Should Be $true
            $cleared.ManagerWindowName | Should BeNullOrEmpty
            $managerRoot = Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build(
                (New-B2State $monitors $windows $cleared.ManagerSelector))) 'ManagerRoot'
            (Get-B2Kind $managerRoot 'ManagerCurrent')[0].Label | Should BeExactly 'Current: None'
            (Get-B2Kind $managerRoot 'ClearManager')[0].Enabled | Should Be $false
            (Get-B2CheckedCandidates $managerRoot).Count | Should Be 0
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    It 'B2 15 candidates group into five deterministic buckets' {
        $titles = @(
            'Alpha-1', 'Alpha-2', 'Alpha-3', 'Alpha-4', 'Alpha-5', 'Beta-1',   # A,B -> A-F (6)
            'Golf-1', 'Golf-2', 'Hotel-1',                                     # G,H -> G-L (3)
            'Mike-1', 'Mike-2', 'Romeo-1',                                     # M,R -> M-R (3)
            'Sierra-1', 'Tango-1',                                             # S,T -> S-Z (2)
            '7number'                                                          # digit -> # (1)
        )
        $windows = @()
        $handle = 9500
        foreach ($title in $titles) {
            $handle++
            $windows += (New-B2Pair $handle ('raw-' + $title) @((New-B2Tab $title $title)) $true)
        }
        $windows.Count | Should Be 15
        $state = New-B2State @((New-B2Monitor 1 $true 0 0)) $windows ([TerminalOrganizer.Core.Assignment.ManagerSelector]::None())
        $choose = (Get-B2Kind (Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'ManagerRoot') 'ManagerCandidateGroup')[0]
        # All 15 candidates live under buckets; none sit directly under Choose manager.
        (@($choose.Children) | Where-Object { $_.Kind.ToString() -eq 'SetManager' }).Count | Should Be 0
        $buckets = @($choose.Children)
        $buckets.Count | Should Be 5
        ($buckets | ForEach-Object { $_.Label }) -join ',' |
            Should BeExactly ('A' + $script:B2En + 'F,G' + $script:B2En + 'L,M' + $script:B2En + 'R,S' + $script:B2En + 'Z,#')
        (@($buckets[0].Children)).Count | Should Be 6
        (@($buckets[1].Children)).Count | Should Be 3
        (@($buckets[2].Children)).Count | Should Be 3
        (@($buckets[3].Children)).Count | Should Be 2
        (@($buckets[4].Children)).Count | Should Be 1
        $buckets[4].Children[0].Label | Should BeExactly '7number'
    }

    It 'B2 candidate label reports additional tab count' {
        $tabs = @((New-B2Tab 'Alpha' 'S1'), (New-B2Tab 'Beta' 'S2'), (New-B2Tab 'Gamma' 'S3'))
        $pair = New-B2Pair 9601 'alpha-raw' $tabs $true
        [TerminalOrganizer.App.TrayMenuBuilder]::DisplayWindowCandidate($pair.Snapshot) |
            Should BeExactly 'Alpha (+2 tabs)'
        # The menu row carries the same label.
        $state = New-B2State @((New-B2Monitor 1 $true 0 0)) @($pair) ([TerminalOrganizer.Core.Assignment.ManagerSelector]::None())
        $choose = (Get-B2Kind (Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'ManagerRoot') 'ManagerCandidateGroup')[0]
        $choose.Children[0].Label | Should BeExactly 'Alpha (+2 tabs)'
    }

    It 'B2 monitor click survives renumber by stable key' {
        $before = New-B2Monitor 2 $false 1920 0
        $after = [TerminalOrganizer.Core.Monitors.MonitorInfo]::new(
            $null, $before.InterfacePath, $before.MonitorId, $before.Instance, $before.Serial, 1, $false,
            $before.MonitorLeft, $before.MonitorTop, $before.MonitorWidth, $before.MonitorHeight, $before.WorkArea)
        $state = New-B2State @($before) @() ([TerminalOrganizer.Core.Assignment.ManagerSelector]::None())
        $root = Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'OrganizeMonitorRoot'
        $row = @($root.Children)[0]
        $row.Kind.ToString() | Should BeExactly 'OrganizeMonitor'
        $row.MonitorKey.EqualsKey($after.StableKey) | Should Be $true
        [TerminalOrganizer.Core.Monitors.MonitorSelector]::ResolveUnique(@($after), $row.MonitorKey).Number | Should Be 1
    }
}

# --- B3: structured last-operation status and notice levels (night-design-2026-09-25 unit B3) ---

# kernel32 SetLastError P/Invoke: lets the fake native seam plant a Win32 error the
# placer's Marshal.GetLastWin32Error() then observes (declared SetLastError=true so
# the marshaler caches the code).
if (-not ('B3Test.NativeHelpers' -as [type])) {
    Add-Type -TypeDefinition @'
namespace B3Test
{
    public static class NativeHelpers
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        public static extern void SetLastError(int errorCode);
    }
}
'@
}

# B3 count fixture (design item 1): 8 windows; final plan = A,B move / C stacked+move /
# D move (fails) / F,G no-move / H full-screen; E merges away, F's merge times out.
# -> placed=3 (A,B,C), unchanged=2 (F,G), stacked=1 (C, also placed), skipped=1 (H),
#    merged=1 (E), mergeFailed=1 (F), placementFailed=1 (D), Failed=2, Discovered=8.
function New-B3StatusController {
    param([string]$DiscoveryMode = 'scenario')
    $script:B3Notices = New-Object 'System.Collections.Generic.List[object]'
    $script:B3Discovery = $DiscoveryMode
    $script:B3Handles = @{}
    $seed = 7000
    $facts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in @('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H')) {
        $seed++
        $script:B3Handles[$id] = [IntPtr]$seed
        $facts.Add([TerminalOrganizer.Core.Assignment.WindowFact]::new(
            $id, [IntPtr]$seed, $id, $true, 0, 0, 400, 300, $false, $false, $false))
    }
    $script:B3Facts = $facts.ToArray()
    $script:B3Snaps = @()

    $move = {
        param([string]$Id, [int]$Zone, [bool]$Stacked)
        [TerminalOrganizer.Core.Assignment.PlannedMove]::new(
            $Id, $script:B3Handles[$Id], $Zone, 0, 0, 400, 300, $true, $false, $Stacked,
            [TerminalOrganizer.Core.Assignment.PlannedMoveSkipReason]::None)
    }
    $noMove = {
        param([string]$Id)
        [TerminalOrganizer.Core.Assignment.PlannedMove]::new(
            $Id, $script:B3Handles[$Id], 0, 0, 0, 400, 300, $false, $false, $false,
            [TerminalOrganizer.Core.Assignment.PlannedMoveSkipReason]::None)
    }
    $fullScreen = {
        param([string]$Id)
        [TerminalOrganizer.Core.Assignment.PlannedMove]::new(
            $Id, $script:B3Handles[$Id], 0, 0, 0, 400, 300, $false, $false, $false,
            [TerminalOrganizer.Core.Assignment.PlannedMoveSkipReason]::FullScreen)
    }
    # One hand-built plan serves both assign calls (the fake merge planner ignores it;
    # the manager notice never fires with a null manager name).
    $script:B3Plan = [TerminalOrganizer.Core.Assignment.AssignmentPlan]::new(@(
        (& $move 'A' 0 $false), (& $move 'B' 1 $false), (& $move 'C' 2 $true), (& $move 'D' 0 $false),
        (& $noMove 'F'), (& $noMove 'G'), (& $fullScreen 'H')), $false, $null, $null)

    $desktopSrc = [TerminalOrganizer.App.CurrentDesktopSource] { '{00000000-0000-4000-8000-000000000007}' }
    $layoutRes = [TerminalOrganizer.App.LayoutResolution] {
        param($monitor, $desktop)
        [TerminalOrganizer.Core.Layouts.LayoutResult]::Supported('grid', $null, 0, (New-CZones), @())
    }
    $windowDisc = [TerminalOrganizer.App.WindowDiscovery] {
        param($monitor, $desktop)
        if ($script:B3Discovery -eq 'throw') { throw 'discovery exploded' }
        New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:B3Facts, $script:B3Snaps
    }
    $assigner = [TerminalOrganizer.Core.Overflow.AssignmentComputation] {
        param($zones, $facts, $manager)
        $script:B3Plan
    }
    # Delegates resolve variables dynamically at Run() time, so the bodies only touch
    # $script:-scoped state (no function locals like a session-builder helper).
    $mergePlanner = [TerminalOrganizer.App.MergePlanning] {
        param($plan, $snaps)
        $sessionFor = {
            param([string]$Name)
            [TerminalOrganizer.Core.Windows.SessionRecord]::new(
                $Name, [TerminalOrganizer.Core.Windows.SessionKind]::Local, 'wsl.exe -d Ubuntu --exec /tmp/attach.sh')
        }
        [TerminalOrganizer.Core.Overflow.MergePlan]::new(@(
            [TerminalOrganizer.Core.Overflow.PlannedMerge]::new('E', $script:B3Handles['E'], 'A', $script:B3Handles['A'], (& $sessionFor 'E')),
            [TerminalOrganizer.Core.Overflow.PlannedMerge]::new('F', $script:B3Handles['F'], 'A', $script:B3Handles['A'], (& $sessionFor 'F'))), @())
    }
    $probe = [TerminalOrganizer.App.HelperExistsProbe] { param($m) $true }
    $executor = [TerminalOrganizer.Core.Overflow.MergeExecution] {
        param($merge)
        if ($merge.SourceWindowId -eq 'E') {
            [TerminalOrganizer.Core.Overflow.MergeOutcome]::Merged('E')
        }
        else {
            [TerminalOrganizer.Core.Overflow.MergeOutcome]::ConfirmTimeout('F')
        }
    }
    $placer = [TerminalOrganizer.Core.Overflow.PlacementPass] {
        param($plan)
        $results = New-Object 'System.Collections.Generic.List[object]'
        foreach ($m in @($plan.Moves)) {
            if ($null -eq $m) { continue }
            if (-not $m.MoveRequired) {
                $results.Add([TerminalOrganizer.Core.Assignment.WindowPlacementResult]::new($m.Handle, $m.WindowId, $true, $true, $null))
            }
            elseif ($m.WindowId -eq 'D') {
                $results.Add([TerminalOrganizer.Core.Assignment.WindowPlacementResult]::new($m.Handle, $m.WindowId, $false, $false, 'SetWindowPos failed: Win32 error 5'))
            }
            else {
                $results.Add([TerminalOrganizer.Core.Assignment.WindowPlacementResult]::new($m.Handle, $m.WindowId, $false, $true, $null))
            }
        }
        [TerminalOrganizer.Core.Assignment.WindowPlacementResult[]]$results.ToArray()
    }
    $notifySink = [TerminalOrganizer.App.NoticeSink] { param($text) }
    $msgSink = [TerminalOrganizer.App.NoticeMessageSink] { param($m) $script:B3Notices.Add($m) }
    $controller = New-Object TerminalOrganizer.App.OrganizeController -ArgumentList `
        $desktopSrc, $layoutRes, $windowDisc, $assigner, $mergePlanner, $probe, $executor, $placer,
        $notifySink, (New-Object TerminalOrganizer.App.LabelRegistry), $null, $null, $null, $msgSink
    @{ Controller = $controller }
}

Describe 'B3 Structured last-operation status and notice levels' {
    $script:B3Label = 'Left ' + $script:B3Em + ' 1920' + $script:B3Times + '1080'

    It 'B3 status counts each result category exactly once' {
        $h = New-B3StatusController
        $before = [DateTime]::UtcNow
        $result = $h.Controller.Run((New-TMonitor 1), $null, $true, $script:B3Label, 'b3-status.log')
        $result.Completed | Should Be $true
        $s = $result.Status
        $s | Should Not BeNullOrEmpty
        $s.Disposition.ToString() | Should BeExactly 'Completed'
        ($s.StartedUtc -ge $before) | Should Be $true
        ($s.CompletedUtc -ge $s.StartedUtc) | Should Be $true
        ($s.ElapsedMilliseconds -ge 0) | Should Be $true
        $s.MonitorLabel | Should BeExactly $script:B3Label
        $s.Discovered | Should Be 8
        $s.SkippedUnknownDesktop | Should Be 0
        $s.SkippedUnknownState | Should Be 0
        $s.SkippedFullScreen | Should Be 1
        $s.Placed | Should Be 3
        $s.Unchanged | Should Be 2
        $s.Stacked | Should Be 1
        $s.Merged | Should Be 1
        $s.MergeFailed | Should Be 1
        $s.PlacementFailed | Should Be 1
        $s.Failed | Should Be 2
        $s.TopologyChanged | Should Be $false
        $s.LogPath | Should BeExactly 'b3-status.log'
        $s.Detail | Should BeNullOrEmpty
    }

    It 'B3 menu summary uses pinned count order' {
        $h = New-B3StatusController
        $result = $h.Controller.Run((New-TMonitor 1), $null, $true, $script:B3Label, 'b3-status.log')
        $result.Status.MenuSummary | Should BeExactly 'Last result: 3 placed, 2 unchanged, 1 stacked, 1 skipped, 1 merged, 2 failed'
        [TerminalOrganizer.App.LastOperationStatus]::NeverRun('x.log').MenuSummary |
            Should BeExactly 'Last result: Not run yet'
    }

    It 'B3 zero windows returns NothingToDo and no manager warning' {
        $h = New-B3StatusController
        $script:B3Facts = @()
        $script:B3Snaps = @()
        $result = $h.Controller.Run((New-TMonitor 1), 'MGR', $true, $script:B3Label, 'b3-status.log')
        $result.Completed | Should Be $true
        $result.Status.Disposition.ToString() | Should BeExactly 'NothingToDo'
        $script:B3Notices.Count | Should Be 1
        $script:B3Notices[0].Kind.ToString() | Should BeExactly 'NoWindows'
        $script:B3Notices[0].Level.ToString() | Should BeExactly 'Information'
        $script:B3Notices[0].ShowBalloon | Should Be $false
        $script:B3Notices[0].Text | Should BeExactly ('No Windows Terminal windows on ' + $script:B3Label + ' ' + $script:B3Em + ' nothing to organize.')
    }

    It 'B3 placement errors include Win32 error code' {
        $placer = [TerminalOrganizer.Core.Assignment.WindowPlacer]::new(
            [Func[TerminalOrganizer.Core.Assignment.PlannedMove,bool]] {
                param($m)
                [B3Test.NativeHelpers]::SetLastError(5)
                $false
            },
            [Action[IntPtr]] { param($h) })
        $moves = @([TerminalOrganizer.Core.Assignment.PlannedMove]::new(
            'w1', [IntPtr]1, 0, 0, 0, 400, 300, $true, $false, $false,
            [TerminalOrganizer.Core.Assignment.PlannedMoveSkipReason]::None))
        $plan = [TerminalOrganizer.Core.Assignment.AssignmentPlan]::new($moves, $false, $null, $null)
        $result = $placer.Apply($plan)
        $result.Length | Should Be 1
        $result[0].Skipped | Should Be $false
        $result[0].Success | Should Be $false
        $result[0].Error | Should Match 'Win32 error 5'
    }

    It 'B3 each notice kind has pinned level and balloon policy' {
        $cases = @(
            @{ Kind = 'NoWindows';             Arg = $script:B3Label; Monitor = $null;       Level = 'Information'; Balloon = $false; Expected = 'No Windows Terminal windows on ' + $script:B3Label + ' ' + $script:B3Em + ' nothing to organize.' },
            @{ Kind = 'ManagerSkipped';        Arg = 'MGR';           Monitor = $script:B3Label; Level = 'Information'; Balloon = $false; Expected = 'Manager ' + $script:B3Lq + 'MGR' + $script:B3Rq + ' is not open on ' + $script:B3Label + '. Other windows were organized.' },
            @{ Kind = 'MergeNotConfirmed';     Arg = 'YODA3';      Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = 'Merge for ' + $script:B3Lq + 'YODA3' + $script:B3Rq + ' was not confirmed. The original window remains open.' },
            @{ Kind = 'MergeSafetyAborted';    Arg = 'YODA3';      Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = 'Merge for ' + $script:B3Lq + 'YODA3' + $script:B3Rq + ' could not be verified safely. The original window remains open.' },
            @{ Kind = 'MergeConfirmedNotClosed'; Arg = 'YODA4';    Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = "The tab for 'YODA4' was created but its old window could not be closed; close it by hand." },
            @{ Kind = 'HelperMissing';         Arg = 'OC_YODA2';   Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = "Attach helper not found for 'OC_YODA2'; the merge was skipped." },
            @{ Kind = 'PlacementFailed';       Arg = '2';          Monitor = $null;           Level = 'Error';       Balloon = $true;  Expected = '2 windows could not be moved. Open the log for details.' },
            @{ Kind = 'AcquisitionDegraded';   Arg = '3';          Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = '3 windows were skipped because their desktop or state could not be verified.' },
            @{ Kind = 'TopologyChanged';       Arg = $null;        Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = 'Monitor layout changed during organize. No remaining moves were applied.' },
            @{ Kind = 'HotkeyConflict';        Arg = 'Ctrl+Alt+O'; Monitor = $null;           Level = 'Error';       Balloon = $true;  Expected = "Hotkey 'Ctrl+Alt+O' is already taken; use the tray menu." },
            @{ Kind = 'UnsupportedLayout';     Arg = 'focus';      Monitor = $null;           Level = 'Warning';     Balloon = $true;  Expected = "FancyZones layout 'focus' is not supported on this monitor; nothing was changed." },
            @{ Kind = 'InvalidLayout';         Arg = 'bad json';   Monitor = $null;           Level = 'Error';       Balloon = $true;  Expected = 'The FancyZones layout data on this monitor is invalid (bad json); nothing was changed.' },
            @{ Kind = 'NoAppliedLayout';       Arg = $null;        Monitor = $null;           Level = 'Information'; Balloon = $false; Expected = 'No FancyZones layout is applied to this monitor; nothing was changed.' },
            @{ Kind = 'UnexpectedFailure';     Arg = $null;        Monitor = $null;           Level = 'Error';       Balloon = $true;  Expected = 'Organize failed. Open the log for details.' }
        )
        $cases.Count | Should Be 14
        foreach ($c in $cases) {
            $kind = [TerminalOrganizer.App.NoticeKind]::Parse([TerminalOrganizer.App.NoticeKind], $c.Kind)
            $m = [TerminalOrganizer.App.NoticeTable]::Get($kind, $c.Arg, $c.Monitor)
            $m.Kind.ToString() | Should BeExactly $c.Kind
            $m.Text | Should BeExactly $c.Expected
            $m.Level.ToString() | Should BeExactly $c.Level
            $m.ShowBalloon | Should Be $c.Balloon
            # Compatibility wrapper: Text mirrors Get(...).Text for every kind.
            [TerminalOrganizer.App.NoticeTable]::Text($kind, $c.Arg, $c.Monitor) | Should BeExactly $c.Expected
        }
    }

    It 'B3 information notice logs but does not balloon' {
        $script:B3Logged = New-Object 'System.Collections.Generic.List[string]'
        $script:B3Ballooned = New-Object 'System.Collections.Generic.List[string]'
        $route = [TerminalOrganizer.App.NoticeDispatch]::Route(
            [Action[string]] { param($t) $script:B3Logged.Add($t) },
            [Action[TerminalOrganizer.App.NoticeMessage]] { param($m) $script:B3Ballooned.Add($m.Text) })
        $route.Invoke([TerminalOrganizer.App.NoticeTable]::Get(
            [TerminalOrganizer.App.NoticeKind]::NoWindows, $script:B3Label))
        $script:B3Logged.Count | Should Be 1
        $script:B3Ballooned.Count | Should Be 0
        # Balloon-requested notices log and balloon the IDENTICAL text.
        $route.Invoke([TerminalOrganizer.App.NoticeTable]::Get(
            [TerminalOrganizer.App.NoticeKind]::MergeNotConfirmed, 'YODA3'))
        $script:B3Logged.Count | Should Be 2
        $script:B3Ballooned.Count | Should Be 1
        $script:B3Ballooned[0] | Should BeExactly $script:B3Logged[1]
    }

    It 'B3 unexpected exception becomes failed status plus error notice' {
        $h = New-B3StatusController 'throw'
        $result = $h.Controller.Run((New-TMonitor 1), $null, $true, $script:B3Label, 'b3-status.log')
        $result.Completed | Should Be $false
        $result.Status.Disposition.ToString() | Should BeExactly 'Failed'
        $result.Status.Detail | Should BeExactly 'discovery exploded'
        $script:B3Notices.Count | Should Be 1
        $script:B3Notices[0].Kind.ToString() | Should BeExactly 'UnexpectedFailure'
        $script:B3Notices[0].Level.ToString() | Should BeExactly 'Error'
        $script:B3Notices[0].ShowBalloon | Should Be $true
        $script:B3Notices[0].Text | Should BeExactly 'Organize failed. Open the log for details.'
    }
}

# --- B4: worker/UI marshalling, busy UX, exit-cancellation (night-design-2026-09-25 unit B4) ---
# --- plus the R2 carry-forward MINORs from p0-gate-verdict-2026-09-26.md ---

# Worker progress recorder: PS-class method invoked by the coordinator's C# worker
# (A5FakeWorker pattern). NOTE (measured, b4probe): a PS-class method body in this
# host reports the MAIN thread id even when the coordinator runs it from its worker
# task, so the worker's own thread id is not assertable here — the marshalling
# contract is pinned by the completion staying queued until the pump runs and then
# executing on the pumping (UI) thread.
try {
    if (-not ('B4ThreadWorker' -as [type])) {
        Invoke-Expression @'
    class B4ThreadWorker {
        [System.Collections.Hashtable]$State
        B4ThreadWorker([System.Collections.Hashtable]$s) { $this.State = $s }
        [TerminalOrganizer.App.OperationCompletion] Run([TerminalOrganizer.App.OrganizeRequest] $request, [System.Threading.CancellationToken] $token) {
            $this.State['Log'].Enqueue('work:' + $request.Source)
            return [TerminalOrganizer.App.OperationCompletion]::new($null, $false, $null)
        }
    }
'@
    }
}
catch { }

Describe 'B4 worker/UI marshalling and busy UX' {
    It 'B4 worker completion is marshalled to UI control' {
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $mainThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        $state = New-A5State
        $work = [System.Delegate]::CreateDelegate(
            [TerminalOrganizer.App.OperationWork], ([B4ThreadWorker]::new($state)), 'Run')
        $script:B4CompletedThread = 0
        $completed = [Action[TerminalOrganizer.App.OperationCompletion]] {
            param($c)
            $script:B4CompletedThread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $script:A5Completed.Add('published') }
        $coord = [TerminalOrganizer.App.OperationCoordinator]::new(
            $script:A5Form, $work, $null, $completed)
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'A'))
        (Wait-A5Worker { (Get-A5Log $state) -contains 'work:A' }) | Should Be $true
        # Marshalling proof part 1: the worker has finished, but the completion has
        # NOT run — it sits queued in the marshalling control until the UI pump runs.
        $script:A5Completed.Count | Should Be 0
        (Wait-A5Pump { $script:A5Completed.Count -eq 1 }) | Should Be $true
        # Part 2: when it runs, it runs on the UI (pumping) thread.
        $script:B4CompletedThread | Should Be $mainThreadId
        $coord.Dispose()
    }

    It 'B4 busy menu disables mutating entries and leaves Exit enabled' {
        $windows = @(
            (New-B2Pair 9701 'mgr-raw' @((New-B2Tab 'OC_MGR' 'MGR')) $true),
            (New-B2Pair 9702 'unk-raw' @((New-B2Tab 'WD_UNK1' $null)) $false)
        )
        $monitors = @((New-B2Monitor 1 $true 0 0))
        $none = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
        $busy = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-B2State $monitors $windows $none -Busy $true))
        $busy[0].Label | Should BeExactly ('Organizing' + $script:B2Ellipsis)
        (Get-B2Root $busy 'OrganizeUnderCursor').Enabled | Should Be $false
        (Get-B2Root $busy 'OrganizeMonitorRoot').Enabled | Should Be $false
        (Get-B2Root $busy 'ManagerRoot').Enabled | Should Be $false
        (Get-B2Root $busy 'OverflowRoot').Enabled | Should Be $false
        (Get-B2Root $busy 'LabelsAndPrioritiesRoot').Enabled | Should Be $false
        (Get-B2Root $busy 'OpenLog').Enabled | Should Be $true
        (Get-B2Root $busy 'Exit').Enabled | Should Be $true
        # Idle keeps the mutating entries usable.
        $idle = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-B2State $monitors $windows $none -Busy $false))
        (Get-B2Root $idle 'OrganizeUnderCursor').Enabled | Should Be $true
        (Get-B2Root $idle 'ManagerRoot').Enabled | Should Be $true
        (Get-B2Root $idle 'OverflowRoot').Enabled | Should Be $true
        (Get-B2Root $idle 'LabelsAndPrioritiesRoot').Enabled | Should Be $true
    }

    It 'B4 Exit during UIA wait cancels before mutation' {
        # A real interleaved UIA wait is unrepresentable here (a blocking worker freezes
        # this host), so the exit contract is pinned at its deterministic ends: the
        # worker unit's cancellation checkpoint (pre-cancelled token -> NO pipeline
        # call, Cancelled completion) and the shell's cancelled-completion mapping.
        $shellType = [TerminalOrganizer.App.OperationCoordinator].Assembly.GetType(
            'TerminalOrganizer.App.TrayShell', $true)
        $shell = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($shellType)
        $exec = $shellType.GetMethod('ExecuteOrganize', [Reflection.BindingFlags]'NonPublic,Instance')
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.Cancel()
        $request = [TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'menu')
        $completion = $exec.Invoke($shell, @($request, $cts.Token))
        $completion.Cancelled | Should Be $true
        $completion.Result | Should BeNullOrEmpty
        $completion.Error | Should BeNullOrEmpty
        # The remembered request was set before the checkpoint (F1 ordering intact).
        [object]::ReferenceEquals(
            $shellType.GetField('activeRequest', [Reflection.BindingFlags]'NonPublic,Instance').GetValue($shell),
            $request) | Should Be $true
        # The shell maps a token cancelled after the pipeline returned to a Cancelled
        # completion (source pin; the interleaving itself is the morning checklist).
        $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $source.Contains('new OperationCompletion(result, true, null)') | Should Be $true
    }

    It 'B4 build produces UiaProbe with no new Core references' {
        $probeExe = Join-Path $repoRoot 'bin\TerminalOrganizer.UiaProbe.exe'
        Test-Path $probeExe | Should Be $true
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'build.ps1'))
        $text.Contains('/target:exe') | Should Be $true
        # AC-016: the Core invocation keeps exactly eight references with the third
        # target present, and the helper compiles after the App target.
        $winexeAt = $text.IndexOf('/target:winexe')
        $winexeAt | Should BeGreaterThan -1
        ([regex]::Matches($text.Substring(0, $winexeAt), '/r:')).Count | Should Be 8
        $text.LastIndexOf('/target:exe') | Should BeGreaterThan $winexeAt
    }
}

Describe 'R2 carry-forward fixes (p0-gate-verdict-2026-09-26)' {
    It 'R2 Request during deferred exit does not start work' {
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $h = New-A5Coordinator (New-A5State)
        $coord = $h.Coord
        $state = $h.State
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'A'))
        (Wait-A5Worker { (Get-A5Log $state) -contains 'mutation' }) | Should Be $true
        $script:A5ExitCount = 0
        $coord.RequestExit([Action] { $script:A5ExitCount = $script:A5ExitCount + 1 })
        # Deferred exit: the completion marshal is queued, so the coordinator is busy
        # and exitRequested is set. A request arriving in this window must be dropped
        # outright — never parked as a pending rerun that races ExitApplication.
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($null, $true, 'X'))
        $coord.HasPendingRerun | Should Be $false
        (Wait-A5Pump { $script:A5ExitCount -eq 1 }) | Should Be $true
        $script:A5ExitCount | Should Be 1
        ((Get-A5Log $state | Where-Object { $_ -like 'work:*' }) -join ',') | Should BeExactly 'work:A'
        $coord.IsBusy | Should Be $false
        $coord.Dispose()
    }

    It 'R2 fresh-source re-arm branch runs in ExecuteOrganize' {
        # R2-2: the F1 test's reflection stand-in set activeRequest directly, so the
        # re-arm branch inside the REAL ExecuteOrganize had no coverage. This drives
        # the real method: a bogus monitor key stops it at the no-target checkpoint,
        # AFTER the branch under test, with no pipeline activity.
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('r2b-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $shellType = [TerminalOrganizer.App.OperationCoordinator].Assembly.GetType(
                'TerminalOrganizer.App.TrayShell', $true)
            $shell = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($shellType)
            $compositionType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType(
                'TerminalOrganizer.App.Composition', $true)
            $build = $compositionType.GetMethod('Build', [Reflection.BindingFlags]'NonPublic,Static')
            # ::new() fixtures (New-Object output is PSObject-wrapped and cannot bind
            # through the reflective Invoke below).
            $logSink = [TerminalOrganizer.App.LogSink]::new((Join-Path $tempDir 'r2.log'))
            $labels = [TerminalOrganizer.App.LabelRegistry]::new()
            $ports = $build.Invoke($null, [object[]]@($logSink, $labels))
            $shellType.GetField('ports', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($shell, $ports)
            $exec = $shellType.GetMethod('ExecuteOrganize', [Reflection.BindingFlags]'NonPublic,Instance')
            $armed = 'topologyRerunArmed'
            $none = [System.Threading.CancellationToken]::None
            $bogusKey = (New-TMonitor 99).StableKey   # matches no real monitor -> null target

            # A fresh user source clears the one-shot latch.
            $shellType.GetField($armed, [Reflection.BindingFlags]'NonPublic,Instance').SetValue($shell, $true)
            $menuRequest = [TerminalOrganizer.App.OrganizeRequest]::new($bogusKey, $false, 'menu')
            $null = $exec.Invoke($shell, @($menuRequest, $none))
            [bool]$shellType.GetField($armed, [Reflection.BindingFlags]'NonPublic,Instance').GetValue($shell) |
                Should Be $false

            # The topology-rerun source leaves the latch armed (one-shot, no loop).
            $shellType.GetField($armed, [Reflection.BindingFlags]'NonPublic,Instance').SetValue($shell, $true)
            $rerunRequest = [TerminalOrganizer.App.OrganizeRequest]::new($bogusKey, $false, 'topology-rerun')
            $null = $exec.Invoke($shell, @($rerunRequest, $none))
            [bool]$shellType.GetField($armed, [Reflection.BindingFlags]'NonPublic,Instance').GetValue($shell) |
                Should Be $true
            [object]::ReferenceEquals(
                $shellType.GetField('activeRequest', [Reflection.BindingFlags]'NonPublic,Instance').GetValue($shell),
                $rerunRequest) | Should Be $true
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    It 'R2 armed rerun preserves the original monitor key and cursor-resolve flag' {
        # R2-3: the F1 test used null-key/resolve=true for both requests, so parameter
        # preservation was weakly pinned. Here the remembered request carries a REAL
        # stable key and resolve=false; a rerun that lost either would resolve through
        # the cursor instead (the fake logs the cursor value 'M1' for under-cursor
        # requests — distinct from the key's canonical value by construction).
        $script:A5Phases = New-Object 'System.Collections.Generic.List[string]'
        $script:A5Completed = New-Object 'System.Collections.Generic.List[string]'
        $state = New-A5State
        $state['Aborted'] = $true
        $canonical = (New-TMonitor 1).StableKey.CanonicalValue
        $canonical | Should Not BeExactly 'M1'
        $shellType = [TerminalOrganizer.App.OperationCoordinator].Assembly.GetType(
            'TerminalOrganizer.App.TrayShell', $true)
        $script:R2Shell = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($shellType)
        $script:R2OrganizeCompleted = $shellType.GetMethod(
            'OrganizeCompleted', [Reflection.BindingFlags]'NonPublic,Instance')
        $completed = [Action[TerminalOrganizer.App.OperationCompletion]] {
            param($c)
            $script:A5Completed.Add(('aborted=' + ($null -ne $c.Result -and $c.Result.TopologyAborted)))
            $script:R2OrganizeCompleted.Invoke($script:R2Shell, @($c)) | Out-Null }
        $work = [System.Delegate]::CreateDelegate(
            [TerminalOrganizer.App.OperationWork], ([A5FakeWorker]::new($state)), 'Run')
        $coord = [TerminalOrganizer.App.OperationCoordinator]::new(
            $script:A5Form, $work, $null, $completed)
        $key = (New-TMonitor 1).StableKey
        $shellType.GetField('coordinator', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($script:R2Shell, $coord)
        $shellType.GetField('activeRequest', [Reflection.BindingFlags]'NonPublic,Instance').SetValue(
            $script:R2Shell, [TerminalOrganizer.App.OrganizeRequest]::new($key, $false, 'menu'))
        $coord.Request([TerminalOrganizer.App.OrganizeRequest]::new($key, $false, 'menu'))
        (Wait-A5Pump { -not $coord.IsBusy -and $coord.Phase.ToString() -eq 'Idle' }) | Should Be $true
        ((Get-A5Log $state | Where-Object { $_ -like 'work:*' }) -join ',') |
            Should BeExactly 'work:menu,work:topology-rerun'
        # BOTH runs resolved through the original stable key — never the cursor.
        ((Get-A5Log $state | Where-Object { $_ -like 'resolved:*' }) -join ',') |
            Should BeExactly ('resolved:' + $canonical + ',resolved:' + $canonical)
        $coord.Dispose()
    }
}

# --- C2: pure cross-monitor redistribution planner + -WhatIf output
# (night-design-2026-09-25 unit C2, test 10) ---

Describe 'C2 WhatIf redistribution output' {
    # Local fixtures (the standing design-example world; zones are absolute screen rects).
    function New-C2Key([string]$Serial) {
        [TerminalOrganizer.Core.Monitors.MonitorKey]::new($Serial, $null, $null, $null)
    }
    function New-C2Layout([string]$Serial, [string]$Label, [object[]]$Zones) {
        [TerminalOrganizer.Core.Overflow.MonitorLayoutSnapshot]::new(
            (New-C2Key $Serial), $Label, [TerminalOrganizer.Core.Geometry.Zone[]]$Zones)
    }
    function New-C2Priority([string]$Id, [object]$DeclaredRank) {
        [TerminalOrganizer.Core.Overflow.PriorityResolver]::Resolve(
            [TerminalOrganizer.Core.Overflow.PriorityInput]::new(
                $Id, $null, $DeclaredRank,
                [TerminalOrganizer.Core.Overflow.DerivedPriorityClass]::LocalSession,
                $false, $false, $false, 0, 'SN-L', 0, 0))
    }
    function New-C2Window([string]$Id, [string]$Monitor, [bool]$Stable, [bool]$Overflow,
        [int]$ZoneId, [int]$Left, [int]$Top, [int]$Width, [int]$Height, [object]$DeclaredRank = $null) {
        $script:C2Seed = $script:C2Seed + 1
        $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new(
            [IntPtr]$script:C2Seed, 4242, 1234567890, 'CASCADIA_HOSTING_WINDOW_CLASS', ('raw-' + $script:C2Seed))
        [TerminalOrganizer.Core.Overflow.CrossMonitorWindow]::new(
            $Id, [IntPtr]$script:C2Seed, $identity, (New-C2Key $Monitor),
            $true, $true, $false, $false, $Stable, $Overflow, $ZoneId,
            $Left, $Top, $Width, $Height, (New-C2Priority $Id $DeclaredRank))
    }

    It 'C2 WhatIf prints source destination and reason' {
        $script:C2Seed = 32000
        # The design's pinned example world: Left zones both stably occupied; Right z0
        # occupied and z2 (id 2, @2400,0 960x1040) free; source YODA3 carries declared rank 8.
        $leftLabel = 'Left ' + $script:B3Em + ' 1920' + $script:B3Times + '1080'
        $rightLabel = 'Right ' + $script:B3Em + ' 1920' + $script:B3Times + '1080'
        $left = New-C2Layout 'SN-L' $leftLabel @(
            (New-Object TerminalOrganizer.Core.Geometry.Zone -ArgumentList 0, 0, 0, 960, 1040),
            (New-Object TerminalOrganizer.Core.Geometry.Zone -ArgumentList 1, 960, 0, 960, 1040))
        $right = New-C2Layout 'SN-R' $rightLabel @(
            (New-Object TerminalOrganizer.Core.Geometry.Zone -ArgumentList 0, 1920, 0, 960, 1040),
            (New-Object TerminalOrganizer.Core.Geometry.Zone -ArgumentList 2, 2400, 0, 960, 1040))
        $windows = @(
            (New-C2Window 'ST-L0' 'SN-L' $true $false 0 0 0 960 1040),
            (New-C2Window 'ST-L1' 'SN-L' $true $false 1 960 0 960 1040),
            (New-C2Window 'ST-R0' 'SN-R' $true $false 0 1920 0 960 1040),
            (New-C2Window 'YODA3' 'SN-L' $false $true -1 100 500 400 300 8)
        )
        $plan = [TerminalOrganizer.Core.Overflow.CrossMonitorPlanner]::Plan(
            [TerminalOrganizer.Core.Overflow.CrossMonitorSnapshot]::new(
                '{00000000-0000-4000-8000-00000000000C}',
                [TerminalOrganizer.Core.Overflow.MonitorLayoutSnapshot[]]@($left, $right),
                [TerminalOrganizer.Core.Overflow.CrossMonitorWindow[]]$windows))
        $plan.Moves.Length | Should Be 1
        # The pinned two-line -WhatIf format (em dash and multiplication sign via [char]).
        $expected = 'redistribute: YODA3 | ' + $leftLabel + ' -> ' + $rightLabel + "`n" +
            '| zone 2 @ 2400,0 960x1040 | declared rank 8'
        $plan.Moves[0].ToWhatIfText() | Should BeExactly $expected

        # Controller integration: OrganizePlan carries the pure plan; C2 never applies it.
        $emptyAssignment = [TerminalOrganizer.Core.Assignment.AssignmentPlan]::new(@(), $false, $null, $null)
        $emptyMerge = [TerminalOrganizer.Core.Overflow.MergePlan]::new(@(), @())
        $organizePlan = [TerminalOrganizer.App.OrganizePlan]::new($emptyAssignment, $emptyMerge, $plan, $null)
        $organizePlan.HasOverflow | Should Be $true
        [object]::ReferenceEquals($organizePlan.RedistributionPlan, $plan) | Should Be $true
        $emptyRedistribution = [TerminalOrganizer.Core.Overflow.CrossMonitorPlanner]::Plan(
            [TerminalOrganizer.Core.Overflow.CrossMonitorSnapshot]::new($null, @(), @()))
        $quietPlan = [TerminalOrganizer.App.OrganizePlan]::new($emptyAssignment, $emptyMerge, $emptyRedistribution, $null)
        $quietPlan.HasOverflow | Should Be $false

        # Tool wiring: -WhatIf keeps BOTH mutation counts at zero and prints any planned
        # redistribution rows through the same formatter (recording fakes never mutate).
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $tool = Join-Path $repoRoot 'tools\organize-once.ps1'
        $toolSource = [IO.File]::ReadAllText($tool)
        $toolSource.Contains('ToWhatIfText()') | Should Be $true
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $tool -WhatIf -Monitor 1
        $code = $LASTEXITCODE
        $code | Should Be 0
        $text = $out -join "`n"
        $text.Contains('executed=0 (recording fake; no wt launch)') | Should Be $true
        $text.Contains('issued=0 (recording fake; no SetWindowPos)') | Should Be $true
        $text.Contains('applied=0') | Should Be $true
    }
}

# --- C3: overflow policy and pre-mutation choice (night-design-2026-09-25 unit C3) ---
# World: M1 is the organized target (single zone z0 = the stack zone, D-B); M2 is the
# other monitor with two FREE zones in reading order (z0 @1936,16 456x1120 and
# z1 @2408,16 944x1120). Pre-move facts on M1: ST-A exactly on z0 (stable) plus two
# floating overflow windows OV-9 (title rank 9) and OV-5 (title rank 5). C2's planner
# must move OV-9 first (rank descending = lowest priority first) into M2 z0, then
# OV-5 into M2 z1. The cross-move fake flips the phase to 'post' so the Redistribute
# reacquisition sees the moved windows settled exactly on their destination zones.

function New-C3Controller {
    param([string]$Mode = 'overflow')
    $script:C3Phase = 'pre'
    $script:C3Seq = New-Object 'System.Collections.Generic.List[string]'
    $script:C3Notices = New-Object 'System.Collections.Generic.List[string]'
    $script:C3DialogCount = 0
    $script:C3DialogChoice = [TerminalOrganizer.App.OverflowChoice]::Cancel
    $script:C3DialogRemember = $false
    $script:C3OnDialog = $null
    $script:C3M1 = New-TMonitor 1
    $script:C3M2 = New-TMonitor 2

    if ($Mode -eq 'overflow') {
        $script:C3Zones1 = @([TerminalOrganizer.Core.Geometry.Zone]::new(0, 16, 16, 456, 1120))
        $script:C3Facts = @(
            (New-CFact 'ST-A' -Top 16 -Left 16 -Width 456 -Height 1120),
            (New-CFact 'OV-9' -Top 500 -Left 100),
            (New-CFact 'OV-5' -Top 900 -Left 100)
        )
        $script:C3Snaps = @(
            (New-CSnap 'ST-A' @('OC_BASE') @((New-CSession 'BASE' 'Local' 'wsl.exe -d Ubuntu --exec base.sh')) $true $true),
            (New-CSnap 'OV-9' @('OC9_R9') @((New-CSession 'R9' 'Local' 'wsl.exe -d Ubuntu --exec r9.sh')) $true $true),
            (New-CSnap 'OV-5' @('OC5_R5') @((New-CSession 'R5' 'Local' 'wsl.exe -d Ubuntu --exec r5.sh')) $true $true)
        )
    }
    else {
        # no-overflow: two zones, one stable occupant plus one movable floating window.
        $script:C3Zones1 = @(
            [TerminalOrganizer.Core.Geometry.Zone]::new(0, 16, 16, 456, 1120),
            [TerminalOrganizer.Core.Geometry.Zone]::new(1, 488, 16, 944, 1120)
        )
        $script:C3Facts = @(
            (New-CFact 'ST-A' -Top 16 -Left 16 -Width 456 -Height 1120),
            (New-CFact 'NOF-B' -Top 100 -Left 600)
        )
        $script:C3Snaps = @(
            (New-CSnap 'ST-A' @('OC_BASE') @((New-CSession 'BASE' 'Local' 'wsl.exe -d Ubuntu --exec base.sh')) $true $true),
            (New-CSnap 'NOF-B' @('OC_B') @((New-CSession 'B' 'Local' 'wsl.exe -d Ubuntu --exec b.sh')) $true $true)
        )
    }
    $script:C3Zones2 = @(
        [TerminalOrganizer.Core.Geometry.Zone]::new(0, 1936, 16, 456, 1120),
        [TerminalOrganizer.Core.Geometry.Zone]::new(1, 2408, 16, 944, 1120)
    )
    # Post-move facts: the moved windows sit exactly on their M2 destination zones.
    $script:C3PostFacts = @(
        (New-CFact 'OV-9' -Top 16 -Left 1936 -Width 456 -Height 1120),
        (New-CFact 'OV-5' -Top 16 -Left 2408 -Width 944 -Height 1120)
    )
    $script:C3PostM1Facts = @((New-CFact 'ST-A' -Top 16 -Left 16 -Width 456 -Height 1120))
    # Organizing M2 itself (pre phase): one stable occupant on M2 z0, so the run is not
    # stopped at the zero-windows gate. Used only when M2 is the target.
    $script:C3M2Facts = @((New-CFact 'M2-A' -Top 16 -Left 1936 -Width 456 -Height 1120))
    $script:C3M2Snaps = @(
        (New-CSnap 'M2-A' @('OCM2_A') @((New-CSession 'M2A' 'Local' 'wsl.exe -d Ubuntu --exec m2a.sh')) $true $true)
    )

    $desktopSrc = [TerminalOrganizer.App.CurrentDesktopSource] {
        $script:C3Seq.Add('desktop'); '{00000000-0000-4000-8000-00000000000C}'
    }
    $layoutRes = [TerminalOrganizer.App.LayoutResolution] {
        param($monitor, $desktop)
        $script:C3Seq.Add('layout')
        $zones = if ($monitor.Number -eq 2) { $script:C3Zones2 } else { $script:C3Zones1 }
        [TerminalOrganizer.Core.Layouts.LayoutResult]::Supported('grid', $null, 0, $zones, @())
    }
    $disc = [TerminalOrganizer.App.WindowDiscovery] {
        param($monitor, $desktop)
        $script:C3Seq.Add('windows')
        if ($monitor.Number -eq 2) {
            if ($script:C3Phase -eq 'post') { return (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:C3PostFacts, $script:C3Snaps) }
            return (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:C3M2Facts, $script:C3M2Snaps)
        }
        if ($script:C3Phase -eq 'post') { return (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:C3PostM1Facts, $script:C3Snaps) }
        return (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:C3Facts, $script:C3Snaps)
    }
    $assigner = [TerminalOrganizer.Core.Overflow.AssignmentComputation] {
        param($zones, $facts, $manager)
        $script:C3Seq.Add('assign')
        [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zones, $facts, $manager)
    }
    $mergePlanner = [TerminalOrganizer.App.MergePlanning] {
        param($plan, $snaps)
        $script:C3Seq.Add('mergeplan')
        [TerminalOrganizer.Core.Overflow.MergePlanner]::Plan($plan, $snaps)
    }
    $probe = [TerminalOrganizer.App.HelperExistsProbe] { param($merge) $script:C3Seq.Add('probe'); $true }
    $executor = [TerminalOrganizer.Core.Overflow.MergeExecution] {
        param($merge)
        $script:C3Seq.Add('merge:' + $merge.SourceWindowId)
        [TerminalOrganizer.Core.Overflow.MergeOutcome]::Merged($merge.SourceWindowId)
    }
    $placer = [TerminalOrganizer.Core.Overflow.PlacementPass] {
        param($plan)
        $script:C3Seq.Add('place')
        @()
    }
    $crossMove = [TerminalOrganizer.App.CrossMonitorMoveExecution] {
        param($move, $guard, $snaps, $token)
        $script:C3Seq.Add('xmove:' + $move.WindowId)
        if ($script:C3Phase -eq 'pre') { $script:C3Phase = 'post' }
        [TerminalOrganizer.Core.Assignment.WindowPlacementResult]::new($move.Handle, $move.WindowId, $false, $true, $null)
    }
    $worldCapture = [TerminalOrganizer.App.OverflowWorldCapture] {
        param($target, $desktop)
        $script:C3Seq.Add('world')
        if ($target.Number -eq 2) {
            # Organizing M2: the OTHER monitor is M1 with its overflowing windows.
            $rowM1 = [TerminalOrganizer.App.CapturedMonitorRow]::new(
                $script:C3M1, [TerminalOrganizer.Core.Geometry.Zone[]]$script:C3Zones1, 'M1',
                (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList $script:C3Facts, $script:C3Snaps))
            return [TerminalOrganizer.App.CapturedOverflowWorld]::new(
                [TerminalOrganizer.App.CapturedMonitorRow[]]@($rowM1),
                [TerminalOrganizer.App.PriorityOverride[]]@())
        }
        $rowM2 =[TerminalOrganizer.App.CapturedMonitorRow]::new(
            $script:C3M2, [TerminalOrganizer.Core.Geometry.Zone[]]$script:C3Zones2, 'M2',
            (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList @(), @()))
        [TerminalOrganizer.App.CapturedOverflowWorld]::new(
            [TerminalOrganizer.App.CapturedMonitorRow[]]@($rowM2),
            [TerminalOrganizer.App.PriorityOverride[]]@())
    }
    $guardCreate = [TerminalOrganizer.App.CommitGuardCreation] {
        param($m, $d, $l)
        $expected = [TerminalOrganizer.Core.Monitors.CommitSignature]::new(
            [TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@($script:C3M1, $script:C3M2)),
            [TerminalOrganizer.Core.Monitors.LayoutSignature]::new($m.StableKey.CanonicalValue, $d, $l.Kind, $l.LayoutType, $l.Zones))
        $script:C3GuardExpected = $expected
        $script:C3GuardCurrent = $expected
        [TerminalOrganizer.Core.Monitors.CommitGuard]::new($expected, [TerminalOrganizer.Core.Monitors.CommitSignatureSource]{
            $script:C3Seq.Add('guard')
            $script:C3GuardCurrent
        })
    }
    $notifySink = [TerminalOrganizer.App.NoticeSink] { param($text) $script:C3Notices.Add($text) }
    $traceSink = [Action[string]] {
        param($text)
        if ($text -eq 'overflow-flow:prepare') { $script:C3Seq.Add('prepare') }
        elseif ($text -eq 'overflow-flow:choice') { $script:C3Seq.Add('choice') }
    }
    $labels = New-Object TerminalOrganizer.App.LabelRegistry
    $controller = New-Object TerminalOrganizer.App.OrganizeController -ArgumentList `
        $desktopSrc, $layoutRes, $disc, $assigner, $mergePlanner, $probe, $executor, $placer, $notifySink, $labels, $traceSink, `
        $guardCreate, $null, $null, $worldCapture, $crossMove
    $prompt = [TerminalOrganizer.App.OverflowChoicePrompt] {
        param($prepared, $mergeEnabled)
        $script:C3Seq.Add('dialog')
        $script:C3DialogCount = $script:C3DialogCount + 1
        if ($null -ne $script:C3OnDialog) { & $script:C3OnDialog }
        [TerminalOrganizer.App.OverflowChoiceResult]::new($script:C3DialogChoice, $script:C3DialogRemember)
    }
    @{ Controller = $controller; Prompt = $prompt; M1 = $script:C3M1; M2 = $script:C3M2 }
}

function Get-C3FlowTokens {
    # The pinned recorder tokens: the flow markers, the commit-guard validation, and
    # every mutation port (merge execution, cross-monitor move, local placement).
    @($script:C3Seq | Where-Object {
        $_ -in @('prepare', 'choice', 'guard') -or $_ -like 'merge:*' -or $_ -like 'xmove:*' -or $_ -eq 'place'
    })
}

Describe 'C3 Overflow policy and pre-mutation choice' {
    It 'C3 Ask occurs after planning and before mutation' {
        $h = New-C3Controller
        $script:C3DialogChoice = [TerminalOrganizer.App.OverflowChoice]::Parse([TerminalOrganizer.App.OverflowChoice], 'Stack')
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $result.Completed | Should Be $true
        $script:C3DialogCount | Should Be 1
        # Pinned order (design test 1): the pure plan completes, then the choice, then
        # the commit-guard validation, then the first mutation — asserted as the
        # first-occurrence subsequence (the guard seam also fires per mutation).
        $tokens = Get-C3FlowTokens
        $atPrepare = [array]::IndexOf($tokens, 'prepare')
        $atChoice = [array]::IndexOf($tokens, 'choice')
        $atGuard = [array]::IndexOf($tokens, 'guard')
        $atMutation = -1
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -eq 'place' -or $tokens[$i] -like 'merge:*' -or $tokens[$i] -like 'xmove:*') { $atMutation = $i; break }
        }
        $atPrepare | Should BeGreaterThan -1
        $atChoice | Should BeGreaterThan $atPrepare
        $atGuard | Should BeGreaterThan $atChoice
        $atMutation | Should BeGreaterThan $atGuard
    }

    It 'C3 Cancel performs zero mutation' {
        $h = New-C3Controller
        $script:C3DialogChoice = [TerminalOrganizer.App.OverflowChoice]::Parse([TerminalOrganizer.App.OverflowChoice], 'Cancel')
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $result.Completed | Should Be $false
        $result.Status.Detail | Should BeExactly 'overflow-choice-cancelled'
        $result.Status.Disposition.ToString() | Should BeExactly 'Aborted'
        # Merge, cross-monitor and placement recorders all zero after the cancel.
        (@($script:C3Seq | Where-Object { $_ -like 'merge:*' -or $_ -like 'xmove:*' -or $_ -eq 'place' })).Count | Should Be 0
        (@($script:C3Seq | Where-Object { $_ -eq 'guard' })).Count | Should Be 0
    }

    It 'C3 Ask with no overflow does not show dialog' {
        $h = New-C3Controller -Mode quiet
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $script:C3DialogCount | Should Be 0
        $result.Completed | Should Be $true
        (@($script:C3Seq | Where-Object { $_ -eq 'place' })).Count | Should Be 1
    }

    It 'C3 saved Stack hotkey does not show dialog' {
        $h = New-C3Controller
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Stack'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $script:C3DialogCount | Should Be 0
        (@($script:C3Seq | Where-Object { $_ -eq 'place' })).Count | Should Be 1
        (@($script:C3Seq | Where-Object { $_ -like 'xmove:*' })).Count | Should Be 0
        $result.Completed | Should Be $true
    }

    It 'C3 saved Redistribute hotkey does not show dialog' {
        $h = New-C3Controller
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Redistribute'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $script:C3DialogCount | Should Be 0
        # C2 order: rank 9 (lowest priority) moves first, then rank 5.
        ((@($script:C3Seq | Where-Object { $_ -like 'xmove:*' })) -join ',') | Should BeExactly 'xmove:OV-9,xmove:OV-5'
        (@($script:C3Seq | Where-Object { $_ -like 'merge:*' })).Count | Should Be 0
        $result.Completed | Should Be $true
    }

    It 'C3 saved Merge while disabled degrades to Stack' {
        $h = New-C3Controller
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Merge'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $script:C3DialogCount | Should Be 0
        (@($script:C3Seq | Where-Object { $_ -like 'merge:*' })).Count | Should Be 0
        (@($script:C3Seq | Where-Object { $_ -eq 'place' })).Count | Should Be 1
        $result.Completed | Should Be $true
        # Exactly ONE warning entry for the Merge-while-disabled degrade.
        @($script:C3Notices | Where-Object {
            $_ -eq 'Overflow policy is Merge, but merge is not enabled; windows were stacked instead.'
        }).Count | Should Be 1
    }

    It 'C3 dialog renders disabled Merge option' {
        $stable = [TerminalOrganizer.Core.Assignment.PlannedMove]::new(
            'ST-A', [IntPtr]11, 0, 16, 16, 456, 1120, $false, $false, $false, $false)
        $stacked = [TerminalOrganizer.Core.Assignment.PlannedMove]::new(
            'OV-9', [IntPtr]12, 0, 16, 16, 456, 1120, $true, $false, $true, $false)
        $local = [TerminalOrganizer.Core.Assignment.AssignmentPlan]::new(@($stable, $stacked), $false, $null, $null)
        $merge = [TerminalOrganizer.Core.Overflow.PlannedMerge]::new(
            'OV-9', [IntPtr]12, 'ST-A', [IntPtr]11, (New-CSession 'R9' 'Local' 'wsl.exe -d r9.sh'))
        $oneMove = [TerminalOrganizer.Core.Overflow.CrossMonitorMove]::new(
            'OV-9', [IntPtr]12, 'M1', 'M1', 'M2', 'M2', 0, 1936, 16, 456, 1120, 'declared rank 9')
        $plan = [TerminalOrganizer.App.OrganizePlan]::new(
            $local,
            [TerminalOrganizer.Core.Overflow.MergePlan]::new(@($merge), @()),
            [TerminalOrganizer.Core.Overflow.CrossMonitorPlan]::new(@($oneMove), @()),
            $null)
        $prepared = [TerminalOrganizer.App.PreparedOrganizeRun]::new($null, $plan, $null, $null)
        $model = [TerminalOrganizer.App.OverflowChoiceModel]::Build($prepared, $false)
        $model.SummaryText | Should BeExactly '1 stacked, 1 merge-eligible, 1 movable to other monitors'
        $model.Options.Length | Should Be 3
        ($model.Options | ForEach-Object { $_.Label }) -join '|' |
            Should BeExactly 'Stack only|Move to free zones on other monitors|Merge eligible tmux windows'
        $merge = @($model.Options | Where-Object { $_.Choice.ToString() -eq 'Merge' })[0]
        $merge.Visible | Should Be $true
        $merge.Enabled | Should Be $false
        $merge.Checked | Should Be $false
    }

    It 'C3 dialog centers on the organized monitor, not the primary screen' {
        # Live bug 2026-10-02: hotkey on the right monitor, dialog opened centered on the
        # primary (left) screen behind other windows; the run waited on it unseen.
        $location = [TerminalOrganizer.App.OverflowChoiceModel]::DialogLocation((New-TMonitor 2), 460, 240)
        $location.X | Should Be 2650
        $location.Y | Should Be 456
    }

    It 'C3 dialog location clamps an oversized dialog to the monitor origin' {
        $location = [TerminalOrganizer.App.OverflowChoiceModel]::DialogLocation((New-TMonitor 2), 4000, 2000)
        $location.X | Should Be 1920
        $location.Y | Should Be 0
    }

    It 'C3 dialog location without a monitor falls back to screen centering' {
        [TerminalOrganizer.App.OverflowChoiceModel]::DialogLocation($null, 460, 240) | Should BeNullOrEmpty
    }

    It 'C3 composer flags overflow only on the organized monitor' {
        # Live bug 2026-10-03: organizing the RIGHT monitor (no overflow) pulled the LEFT
        # monitor's overflow window in as a redistribution source. Sources are only the
        # organized monitor's own overflow; other monitors stay destinations/occupancy.
        $h = New-C3Controller
        $monitors = [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($script:C3M1, $script:C3M2)
        $zonesPer = New-Object 'TerminalOrganizer.Core.Geometry.Zone[][]' 2
        $zonesPer[0] = [TerminalOrganizer.Core.Geometry.Zone[]]$script:C3Zones1
        $zonesPer[1] = [TerminalOrganizer.Core.Geometry.Zone[]]$script:C3Zones2
        $labels = [string[]]@('M1', 'M2')
        $facts = [TerminalOrganizer.Core.Assignment.WindowFact[]]$script:C3Facts
        $snaps = [TerminalOrganizer.Core.Windows.WindowSnapshot[]]$script:C3Snaps
        $plan1 = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zonesPer[0], $facts, $null)
        $plan2 = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zonesPer[1],
            [TerminalOrganizer.Core.Assignment.WindowFact[]]@(), $null)
        $plans = [TerminalOrganizer.Core.Assignment.AssignmentPlan[]]@($plan1, $plan2)
        $rows = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.EnumeratedWindow]'
        for ($i = 0; $i -lt $facts.Length; $i++) {
            $rows.Add([TerminalOrganizer.Core.Windows.EnumeratedWindow]::new($facts[$i].Handle, $script:C3M1,
                [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true), $snaps[$i].Identity))
        }
        $overrides = [TerminalOrganizer.App.PriorityOverride[]]@()
        $desktopId = '{00000000-0000-4000-8000-00000000000C}'

        # Organized = M2 (no overflow of its own): nothing may be flagged as overflow.
        $forM2 = [TerminalOrganizer.App.CrossMonitorSnapshotComposer]::Compose($desktopId, $monitors,
            $zonesPer, $labels, $plans, $rows.ToArray(), $facts, $snaps, $overrides, $script:C3M2.StableKey)
        $forM2.Windows.Length | Should Be 3
        @($forM2.Windows | Where-Object { $_.Overflow }).Count | Should Be 0

        # Organized = M1: its own overflow (OV-9, OV-5) is flagged; the stable occupant is not.
        $forM1 = [TerminalOrganizer.App.CrossMonitorSnapshotComposer]::Compose($desktopId, $monitors,
            $zonesPer, $labels, $plans, $rows.ToArray(), $facts, $snaps, $overrides, $script:C3M1.StableKey)
        @($forM1.Windows | Where-Object { $_.WindowId -eq 'OV-9' })[0].Overflow | Should Be $true
        @($forM1.Windows | Where-Object { $_.WindowId -eq 'OV-5' })[0].Overflow | Should Be $true
        @($forM1.Windows | Where-Object { $_.WindowId -eq 'ST-A' })[0].Overflow | Should Be $false

        # Legacy 9-argument form: every monitor's stacked windows are sources.
        $legacy = [TerminalOrganizer.App.CrossMonitorSnapshotComposer]::Compose($desktopId, $monitors,
            $zonesPer, $labels, $plans, $rows.ToArray(), $facts, $snaps, $overrides)
        @($legacy.Windows | Where-Object { $_.WindowId -eq 'OV-9' })[0].Overflow | Should Be $true
        @($legacy.Windows | Where-Object { $_.WindowId -eq 'OV-5' })[0].Overflow | Should Be $true
        @($legacy.Windows | Where-Object { $_.WindowId -eq 'ST-A' })[0].Overflow | Should Be $false
    }

    It 'C3 organizing a monitor without overflow never pulls another monitor overflow' {
        $h = New-C3Controller
        $result = $h.Controller.RunWithChoice($h.M2, $null, 'M2', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $script:C3DialogCount | Should Be 0
        (@($script:C3Seq | Where-Object { $_ -like 'xmove:*' })).Count | Should Be 0
        $result.Completed | Should Be $true
    }

    It 'C3 remember choice persists Stack or Redistribute' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('c3-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $script:C3Store = New-Object TerminalOrganizer.App.SettingsStore -ArgumentList (Join-Path $tempDir 'settings.json')
            $script:C3Store.Save([TerminalOrganizer.App.SettingsStore]::Defaults())
            $persist = [Action[TerminalOrganizer.App.OverflowPolicy]] {
                param($policy)
                $s = $script:C3Store.Load()
                $script:C3Store.Save([TerminalOrganizer.App.AppSettings]::new(
                    $s.Hotkey, $s.LogPath, $s.ManagerWindowName, $s.MergeEnabled,
                    $s.FirstRunCompleted, $s.StartWithWindows, $s.ManagerSelector,
                    $s.PriorityOverrides, $s.SchemaVersion, $policy,
                    ($policy.ToString() -eq 'Redistribute')))
            }
            $h = New-C3Controller
            $script:C3DialogChoice = [TerminalOrganizer.App.OverflowChoice]::Parse([TerminalOrganizer.App.OverflowChoice], 'Redistribute')
            $script:C3DialogRemember = $true
            $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
                [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
                $false, $h.Prompt, $persist, [System.Threading.CancellationToken]::None)
            $result.Completed | Should Be $true
            $reloaded = $script:C3Store.Load()
            $reloaded.OverflowPolicy.ToString() | Should BeExactly 'Redistribute'
            $reloaded.CrossMonitorRedistribution | Should Be $true
            $reloaded.SchemaVersion | Should Be 3
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    It 'C3 unremembered choice leaves Ask saved' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('c3-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $script:C3Store = New-Object TerminalOrganizer.App.SettingsStore -ArgumentList (Join-Path $tempDir 'settings.json')
            $script:C3Store.Save([TerminalOrganizer.App.SettingsStore]::Defaults())
            $persist = [Action[TerminalOrganizer.App.OverflowPolicy]] {
                param($policy)
                $s = $script:C3Store.Load()
                $script:C3Store.Save([TerminalOrganizer.App.AppSettings]::new(
                    $s.Hotkey, $s.LogPath, $s.ManagerWindowName, $s.MergeEnabled,
                    $s.FirstRunCompleted, $s.StartWithWindows, $s.ManagerSelector,
                    $s.PriorityOverrides, $s.SchemaVersion, $policy,
                    ($policy.ToString() -eq 'Redistribute')))
            }
            $h = New-C3Controller
            $script:C3DialogChoice = [TerminalOrganizer.App.OverflowChoice]::Parse([TerminalOrganizer.App.OverflowChoice], 'Stack')
            $script:C3DialogRemember = $false
            $null = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
                [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
                $false, $h.Prompt, $persist, [System.Threading.CancellationToken]::None)
            $script:C3Store.Load().OverflowPolicy.ToString() | Should BeExactly 'Ask'
        }
        finally {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    It 'C3 topology change while dialog is open aborts commit' {
        $h = New-C3Controller
        $script:C3OnDialog = {
            # The dialog stays open while the monitor layout changes: the guard's
            # current signature no longer equals the signature captured at Prepare.
            $script:C3GuardCurrent = [TerminalOrganizer.Core.Monitors.CommitSignature]::new(
                [TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@($script:C3M1)),
                $script:C3GuardExpected.Layout)
        }
        $script:C3DialogChoice = [TerminalOrganizer.App.OverflowChoice]::Parse([TerminalOrganizer.App.OverflowChoice], 'Stack')
        $result = $h.Controller.RunWithChoice($h.M1, $null, 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
            $false, $h.Prompt, $null, [System.Threading.CancellationToken]::None)
        $result.TopologyAborted | Should Be $true
        $result.Completed | Should Be $false
        (@($script:C3Seq | Where-Object { $_ -like 'merge:*' -or $_ -like 'xmove:*' -or $_ -eq 'place' })).Count | Should Be 0
        $script:C3Notices.Contains('Monitor layout changed during organize. No remaining moves were applied.') | Should Be $true
    }

    It 'C3 policy menu has four rows with one checked' {
        $ellipsis = [string][char]0x2026
        $monitors = @((New-TMonitor 1))
        $none = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
        foreach ($case in @(
            @{ Policy = 'Ask';         Checked = 'Ask' },
            @{ Policy = 'Redistribute'; Checked = 'Redistribute' }
        )) {
            $policy = [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], $case.Policy)
            $state = [TerminalOrganizer.App.TrayMenuState]::new($false, 'Ctrl+Alt+O',
                [TerminalOrganizer.Core.Monitors.MonitorInfo[]]$monitors,
                [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@(),
                $none,
                [TerminalOrganizer.Core.Assignment.ManagerResolution]::new(
                    [TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None, $null, [IntPtr]::Zero, 0, $null),
                $null, $false, $policy)
            $root = Get-B2Root ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'OverflowRoot'
            $rows = @($root.Children)
            $rows.Length | Should Be 4
            ($rows | ForEach-Object { $_.Label }) -join '|' | Should BeExactly (
                'Ask before overflow actions|Stack only|Merge eligible tmux windows|' +
                'Move lowest-priority windows to free zones' + $ellipsis)
            ($rows | ForEach-Object { $_.Value }) -join '|' | Should BeExactly 'ask|stackOnly|merge|moveLowest'
            # Exactly one checked row: the saved policy's row.
            @($rows | Where-Object { $_.Checked }).Count | Should Be 1
            (@($rows | Where-Object { $_.Checked })[0].Value) | Should BeExactly (
                @{ Ask = 'ask'; Stack = 'stackOnly'; Merge = 'merge'; Redistribute = 'moveLowest' }[$case.Checked])
            # Merge ships disabled; the other three policies are selectable.
            $mergeRow = @($rows | Where-Object { $_.Value -eq 'merge' })[0]
            $mergeRow.Enabled | Should Be $false
            @($rows | Where-Object { $_.Value -ne 'merge' } | ForEach-Object { $_.Enabled } | Where-Object { -not $_ }).Count | Should Be 0
        }
    }

    It 'C3 compatibility Run uses Stack and never opens UI' {
        $h = New-C3Controller
        $result = $h.Controller.Run($h.M1, $null, $true)
        $script:C3DialogCount | Should Be 0
        $result.Completed | Should Be $true
        # The legacy overload plans merges (the pinned AC-006 behaviour) and never
        # enters the choice flow (no flow trace tokens).
        $script:C3Seq.Contains('mergeplan') | Should Be $true
        $script:C3Seq.Contains('prepare') | Should Be $false
        $script:C3Seq.Contains('choice') | Should Be $false
    }
}

# --- B5: supervised-merge command documentation check (public-tree variant: reads README)
# B5, test 10). Source assertion against the working tree: the handoff carries the
# corrected close drill (-SourceHwnd required) plus a separate attach-only example.
Describe 'B5 handoff supervised-merge commands' {
    It 'B5 handoff close command includes SourceHwnd' {
        $handoff = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
        $commandLines = @($handoff -split "`r?`n" | Where-Object { $_.Contains('merge-test.ps1') })
        # The close drill names BOTH handles on one command line.
        @($commandLines | Where-Object {
            $_.Contains('-TargetHwnd') -and $_.Contains('-SourceHwnd') -and -not $_.Contains('-AttachOnly')
        }).Count | Should Be 1
        # The attach-only example is a separate command line without a source.
        @($commandLines | Where-Object {
            $_.Contains('-AttachOnly') -and $_.Contains('-TargetHwnd') -and -not $_.Contains('-SourceHwnd')
        }).Count | Should Be 1
        # The manual-verification language is retained.
        $handoff.ToLowerInvariant().Contains('manual verification') | Should Be $true
    }
}

# --- SPEC-RULES-009 M1: settings v3, migration, save paths, diagnostics logging ---
# Expected values come from SPEC-RULES-009 acceptance.md and plan.md section J.3, never from the code under test.

Add-Type -AssemblyName System.Web.Extensions
$script:R9Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:R9AppAsm = [TerminalOrganizer.App.TrayMenuBuilder].Assembly
$script:R9RuleListU = '{"match":"PowerShell*","rank":200},{"match":"regex:^ssh (?<name>[^ ]+)","rank":400},{"match":"regex:^(?<rank>[0-9]{1,4})-(?<name>.+)$"},{"marker":"#"},{"match":"*--attach YODA*","on":"commandline","rank":250}'
$script:R9V2 = '{"hotkey":"Ctrl+Alt+O","managerWindowName":"OC_YODA1","mergeEnabled":false,"firstRunCompleted":true,"startWithWindows":false,"managerSelector":{"kind":"Session","value":"YODA1","rawTitleFallback":"OC_YODA1"},"priorityOverrides":[{"kind":"RawTitle","value":"notes","rawTitleFallback":"notes","rank":700}],"schemaVersion":2,"overflowPolicy":"Stack","crossMonitorRedistribution":false}'
$script:R9Unversioned = '{"hotkey":"Ctrl+Alt+O","firstRunCompleted":true}'

function New-R9TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('r9-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $dir
}

# A version-N file: the v2 content with the version replaced and an optional titleRules value (JSON text).
function Get-R9File([int]$Version, [string]$TitleRulesJson, [bool]$FirstRun = $true) {
    $json = $script:R9V2.Replace('"schemaVersion":2', ('"schemaVersion":' + $Version))
    if (-not $FirstRun) { $json = $json.Replace('"firstRunCompleted":true', '"firstRunCompleted":false') }
    if ($TitleRulesJson) { $json = $json.Substring(0, $json.Length - 1) + ',"titleRules":' + $TitleRulesJson + '}' }
    $json
}

function Write-R9File([string]$Dir, [string]$Json, [string]$Name = 'settings.json') {
    $path = Join-Path $Dir $Name
    [IO.File]::WriteAllText($path, $Json)
    $path
}

function Get-R9Block([string]$Path) {
    $root = $script:R9Ser.DeserializeObject([IO.File]::ReadAllText($Path))
    if ($root.ContainsKey('titleRules')) { $script:R9Ser.Serialize($root['titleRules']) } else { '<absent>' }
}

function Get-R9ShellMethod([string]$Name) {
    $shell = $script:R9AppAsm.GetType('TerminalOrganizer.App.TrayShell', $true)
    $shell.GetMethod($Name, [Reflection.BindingFlags]'NonPublic,Static')
}

Describe 'SPEC-RULES-009 AC-006 v2 to v3 migration' {
    $dir = New-R9TempDir
    It 'a v2 file loads preset launcher-prefix, no user rules, default rank 500, version 3, and keeps every other setting' {
        $path = Write-R9File $dir $script:R9V2
        $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        $s.TitleRules.PresetEnabled | Should Be $true
        @($s.TitleRules.RuleDefinitions).Count | Should Be 0
        $s.TitleRules.DefaultRank | Should Be 500
        $s.SchemaVersion | Should Be 3
        $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
        $s.ManagerSelector.Kind.ToString() | Should BeExactly 'Session'
        $s.ManagerSelector.Value | Should BeExactly 'YODA1'
        $s.ManagerSelector.RawTitleFallback | Should BeExactly 'OC_YODA1'
        @($s.PriorityOverrides).Count | Should Be 1
        $s.PriorityOverrides[0].Selector.Value | Should BeExactly 'notes'
        $s.PriorityOverrides[0].Rank | Should Be 700
        $s.OverflowPolicy.ToString() | Should BeExactly 'Stack'
    }
    It 'an unversioned file loads preset launcher-prefix, no user rules, default rank 500 and version 3' {
        $path = Write-R9File $dir $script:R9Unversioned 'unversioned.json'
        $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        @($s.TitleRules.RuleDefinitions).Count | Should Be 0
        $s.TitleRules.DefaultRank | Should Be 500
        $s.SchemaVersion | Should Be 3
        $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
        $s.FirstRunCompleted | Should Be $true
    }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

Describe 'SPEC-RULES-009 AC-007 every save path keeps the block' {
    $dir = New-R9TempDir
    $block = '{"preset":"launcher-prefix","defaultRank":450,"rules":[' + $script:R9RuleListU + ']}'
    It 'the manager-choice save helper on a v2 file writes version 3 and preset launcher-prefix, and HG2_YODA1 still resolves through the preset' {
        $path = Write-R9File $dir $script:R9V2
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
            [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'YODA1', 'OC_YODA1')
        $null = (Get-R9ShellMethod 'SaveManagerSelectorTo').Invoke($null, @($store, $selector))
        $s = $store.Load()
        $s.SchemaVersion | Should Be 3
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        @($s.TitleRules.RuleDefinitions).Count | Should Be 0
        $r = [TerminalOrganizer.Core.Rules.RuleEvaluator]::EvaluateTab($s.TitleRules.RuleSet, 'HG2_YODA1', $null)
        $r.Name | Should BeExactly 'YODA1'
        $r.Reference | Should BeExactly 'preset launcher-prefix'
        $s.ManagerSelector.Value | Should BeExactly 'YODA1'
    }
    It 'the overflow-policy save helper keeps preset, default rank and all five rules of a version-3 file' {
        $path = Write-R9File $dir (Get-R9File 3 $block) 'v3-overflow.json'
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $policy = [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Merge')
        $null = (Get-R9ShellMethod 'SaveOverflowPolicyTo').Invoke($null, @($store, $policy))
        $s = $store.Load()
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        $s.TitleRules.DefaultRank | Should Be 450
        @($s.TitleRules.RuleDefinitions).Count | Should Be 5
        $s.OverflowPolicy.ToString() | Should BeExactly 'Merge'
        (Get-R9Block $path) | Should BeExactly ($script:R9Ser.Serialize($script:R9Ser.DeserializeObject($block)))
    }
    It 'the first-run save keeps the block' {
        $path = Write-R9File $dir (Get-R9File 3 $block $false) 'v3-firstrun.json'
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $current = $store.Load()
        $current.FirstRunCompleted | Should Be $false
        $show = [TerminalOrganizer.App.FirstRunShow] {
            param($icon, $hotkey, $startWith)
            [TerminalOrganizer.App.FirstRunResult]::new($true, $false)
        }
        $flowType = $script:R9AppAsm.GetType('TerminalOrganizer.App.FirstRunFlow', $true)
        $ensure = $flowType.GetMethod('EnsureCompletedWithStartup', [Reflection.BindingFlags]'NonPublic,Static')
        $null = $ensure.Invoke($null, @($current, $null, $store, $show, $null))
        $s = $store.Load()
        $s.FirstRunCompleted | Should Be $true
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        $s.TitleRules.DefaultRank | Should Be 450
        @($s.TitleRules.RuleDefinitions).Count | Should Be 5
    }
    It 'a save built with the eleven-argument settings constructor (no block) writes the block the file already had' {
        $path = Write-R9File $dir (Get-R9File 3 $block) 'v3-old-ctor.json'
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $old = [TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log', $null, $false, $true, $false,
            $null, $null, 3, [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'), $false)
        $store.Save($old)
        $s = $store.Load()
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        $s.TitleRules.DefaultRank | Should Be 450
        @($s.TitleRules.RuleDefinitions).Count | Should Be 5
        $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
    }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

Describe 'SPEC-RULES-009 AC-008 fresh and invalid settings' {
    $dir = New-R9TempDir
    It 'no settings file loads preset none, no rules and default rank 500' {
        $s = (New-Object TerminalOrganizer.App.SettingsStore -ArgumentList (Join-Path $dir 'missing.json')).Load()
        $s.TitleRules.Preset | Should BeExactly 'none'
        $s.TitleRules.PresetEnabled | Should Be $false
        @($s.TitleRules.RuleDefinitions).Count | Should Be 0
        $s.TitleRules.DefaultRank | Should Be 500
        @($s.TitleRules.DiagnosticLines).Count | Should Be 0
    }
    It 'a version-3 file without titleRules, and one whose titleRules lacks preset, load the same way' {
        foreach ($case in @(@('v3-none.json', (Get-R9File 3 $null)), @('v3-nopreset.json', (Get-R9File 3 '{"defaultRank":500}')))) {
            $s = (New-Object TerminalOrganizer.App.SettingsStore -ArgumentList (Write-R9File $dir $case[1] $case[0])).Load()
            $s.TitleRules.Preset | Should BeExactly 'none'
            @($s.TitleRules.RuleDefinitions).Count | Should Be 0
            $s.TitleRules.DefaultRank | Should Be 500
            @($s.TitleRules.DiagnosticLines).Count | Should Be 0
            $s.SchemaVersion | Should Be 3
        }
    }
    It 'each invalid titleRules file loads the default for its part, reports one diagnostic, keeps every other setting, and the invalid value survives a save and reload' {
        $invalid = @(
            '"oops"',
            '[]',
            '{"preset":"none","rules":"oops"}',
            '{"preset":"fancy"}',
            '{"preset":"Launcher-Prefix"}',
            '{"preset":"none","defaultRank":1000}',
            '{"preset":"none","defaultRank":"450"}',
            '{"preset":"none","defaultRank":450.5}'
        )
        $i = 0
        foreach ($value in $invalid) {
            $i++
            $path = Write-R9File $dir (Get-R9File 3 $value) ('invalid-' + $i + '.json')
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $s = $store.Load()
            $s.TitleRules.Preset | Should BeExactly 'none'
            @($s.TitleRules.RuleDefinitions).Count | Should Be 0
            $s.TitleRules.DefaultRank | Should Be 500
            @($s.TitleRules.DiagnosticLines).Count | Should Be 1
            $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
            $s.ManagerSelector.Value | Should BeExactly 'YODA1'
            @($s.PriorityOverrides).Count | Should Be 1
            $s.OverflowPolicy.ToString() | Should BeExactly 'Stack'
            $before = Get-R9Block $path
            $store.Save($s)
            (Get-R9Block $path) | Should BeExactly $before
            $again = $store.Load()
            $again.TitleRules.Preset | Should BeExactly 'none'
            $again.TitleRules.DefaultRank | Should Be 500
            @($again.TitleRules.DiagnosticLines).Count | Should Be 1
            $again.TitleRules.DiagnosticLines[0] | Should BeExactly $s.TitleRules.DiagnosticLines[0]
        }
    }
    It 'a file reporting schemaVersion 4 loads its title rules and reports version 4' {
        $block = '{"preset":"launcher-prefix","defaultRank":450,"rules":[' + $script:R9RuleListU + ']}'
        $path = Write-R9File $dir (Get-R9File 4 $block) 'v4.json'
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $s = $store.Load()
        $s.SchemaVersion | Should Be 4
        $s.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        $s.TitleRules.DefaultRank | Should Be 450
        @($s.TitleRules.RuleDefinitions).Count | Should Be 5
        $store.Save($s)
        $store.Load().SchemaVersion | Should Be 4
    }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

Describe 'SPEC-RULES-009 AC-009 round trip and re-read' {
    $dir = New-R9TempDir
    $extended = '{"preset":"launcher-prefix","defaultRank":450,"rules":[' + $script:R9RuleListU + ',{"match":"a","rank":"high"},{"match":"b*","rank":20,"note":"x"}]}'
    It 'preset, default rank and all seven definitions survive load, save, load at the JSON-value level, malformed rule and unknown key included' {
        $path = Write-R9File $dir (Get-R9File 3 $extended)
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $s = $store.Load()
        @($s.TitleRules.RuleDefinitions).Count | Should Be 7
        $s.TitleRules.DefaultRank | Should Be 450
        $store.Save($s)
        (Get-R9Block $path) | Should BeExactly ($script:R9Ser.Serialize($script:R9Ser.DeserializeObject($extended)))
        $again = $store.Load()
        @($again.TitleRules.RuleDefinitions).Count | Should Be 7
        $again.TitleRules.Preset | Should BeExactly 'launcher-prefix'
        (Get-R9Block $path) | Should Match '"note":"x"'
        (Get-R9Block $path) | Should Match '"rank":"high"'
        # 1 preset + 5 valid + 1 valid extra; the malformed rank rule is skipped with one diagnostic.
        @($again.TitleRules.RuleSet.Rules).Count | Should Be 7
        @($again.TitleRules.RuleSet.Diagnostics).Count | Should Be 1
    }
    It 'a settings edit between two reads is used by the second read without a restart' {
        $path = Write-R9File $dir (Get-R9File 3 '{"preset":"none","rules":[{"match":"first*","rank":11}]}') 'edit.json'
        $store = [TerminalOrganizer.App.SettingsStore]::new($path)
        $a = [TerminalOrganizer.Core.Rules.RuleEvaluator]::EvaluateTab($store.Load().TitleRules.RuleSet, 'first one', $null)
        $a.Rank | Should Be 11
        [IO.File]::WriteAllText($path, (Get-R9File 3 '{"preset":"none","rules":[{"match":"first*","rank":22}]}'))
        $b = [TerminalOrganizer.Core.Rules.RuleEvaluator]::EvaluateTab($store.Load().TitleRules.RuleSet, 'first one', $null)
        $b.Rank | Should Be 22
    }
    It 'no .cs file under src mentions FileSystemWatcher' {
        $hits = @(Get-ChildItem -Path (Join-Path $repoRoot 'src') -Recurse -Filter '*.cs' |
            Select-String -Pattern 'FileSystemWatcher' -SimpleMatch)
        $hits.Count | Should Be 0
    }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

Describe 'SPEC-RULES-009 AC-012 one log line per diagnostic' {
    $dir = New-R9TempDir
    It 'five loads of a file with two bad rules write exactly two lines; a changed rule text adds exactly one' {
        $id = [guid]::NewGuid().ToString('N')
        $json = Get-R9File 3 ('{"preset":"none","rules":[{"match":"regex:([' + $id + '","rank":1},{"match":"x' + $id + '","on":"window"}]}')
        $path = Write-R9File $dir $json
        $script:R9Lines = New-Object 'System.Collections.Generic.List[string]'
        $sink = [Action[string]] { param($m) $script:R9Lines.Add($m) }
        $store = [TerminalOrganizer.App.SettingsStore]::new($path, $sink)
        1..5 | ForEach-Object { $null = $store.Load() }
        $script:R9Lines.Count | Should Be 2
        @($script:R9Lines | Where-Object { $_ -match '^title rule [12] skipped: .+' }).Count | Should Be 2
        $changed = $json.Replace('([' + $id, '([x' + $id)
        [IO.File]::WriteAllText($path, $changed)
        $null = $store.Load()
        $null = $store.Load()
        $script:R9Lines.Count | Should Be 3
    }
    It 'a settings-level diagnostic uses the title rules prefix and is also written once' {
        $id = [guid]::NewGuid().ToString('N')
        $path = Write-R9File $dir (Get-R9File 3 ('{"preset":"fancy' + $id + '"}')) 'level.json'
        $script:R9Lines = New-Object 'System.Collections.Generic.List[string]'
        $sink = [Action[string]] { param($m) $script:R9Lines.Add($m) }
        $store = [TerminalOrganizer.App.SettingsStore]::new($path, $sink)
        1..3 | ForEach-Object { $null = $store.Load() }
        $script:R9Lines.Count | Should Be 1
        $script:R9Lines[0] | Should Match '^title rules: .+'
    }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

# --- SPEC-RULES-009 M2: identity consumers, Identity selector, labels, priority wiring, organize-run manager ---
# Expected values come from SPEC-RULES-009 acceptance.md and plan.md section J, never from the code under test.

$script:R9Mon1 = New-TMonitor 1
$script:R9Mon2 = New-TMonitor 2
$script:R9YodaCmd = 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1'

function New-R9Rules([bool]$Preset = $true, [string]$ListJson = $script:R9RuleListU) {
    $defs = $script:R9Ser.DeserializeObject('[' + $ListJson + ']')
    [TerminalOrganizer.Core.Rules.RuleSetBuilder]::Build($defs, $Preset)
}

function New-R9Acquired([long]$Handle, [string[]]$Titles) {
    $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]$Handle, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', $Titles[0])
    [TerminalOrganizer.Core.Windows.AcquiredWindow]::new($identity,
        [TerminalOrganizer.Core.Windows.TabTitleResult]::Ok([string[]]$Titles),
        $script:R9Mon1, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true))
}

function Get-R9Snapshots($Acquired, $Sessions, $Rules) {
    [TerminalOrganizer.Core.Windows.WindowSnapshotBuilder]::Compose(
        [TerminalOrganizer.Core.Windows.AcquiredWindow[]]@($Acquired),
        [TerminalOrganizer.Core.Windows.SessionRecord[]]@($Sessions), $Rules)
}

function New-R9Fact([string]$Id, [long]$Handle, [string]$Name, [bool]$Identified = $true, [int]$Left = 0, [int]$Top = 0, [int]$Width = 400, [int]$Height = 300) {
    [TerminalOrganizer.Core.Assignment.WindowFact]::new($Id, [IntPtr]$Handle, $Name, $Identified, $Left, $Top, $Width, $Height, $false, $false, $false)
}

function New-R9Selector([string]$Kind, [string]$Value, [string]$Fallback) {
    [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
        [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Parse([TerminalOrganizer.Core.Assignment.ManagerSelectorKind], $Kind), $Value, $Fallback)
}

# Composes the one-organized-monitor (M1) plus one-free-destination (M2) world of plan.md J.3 through the
# 11-parameter composer overload, and returns the composed snapshot and the cross-monitor plan.
function Get-R9World($Facts, $Snaps, $Overrides, [int]$DefaultRank) {
    $z1 = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 0, 0, 960, 1040))
    $z2 = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 1920, 0, 960, 1040))
    $plan1 = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($z1, [TerminalOrganizer.Core.Assignment.WindowFact[]]@($Facts), $null)
    $plan2 = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($z2, [TerminalOrganizer.Core.Assignment.WindowFact[]]@(), $null)
    $zs = New-Object 'TerminalOrganizer.Core.Geometry.Zone[][]' 2
    $zs[0] = $z1
    $zs[1] = $z2
    $rows = New-Object 'System.Collections.Generic.List[TerminalOrganizer.Core.Windows.EnumeratedWindow]'
    foreach ($snap in $Snaps) {
        $rows.Add([TerminalOrganizer.Core.Windows.EnumeratedWindow]::new($snap.Handle, $script:R9Mon1,
            [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true), $snap.Identity))
    }
    $composed = [TerminalOrganizer.App.CrossMonitorSnapshotComposer]::Compose('desk',
        [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($script:R9Mon1, $script:R9Mon2), $zs,
        [string[]]@('M1', 'M2'), [TerminalOrganizer.Core.Assignment.AssignmentPlan[]]@($plan1, $plan2),
        $rows.ToArray(), [TerminalOrganizer.Core.Assignment.WindowFact[]]@($Facts),
        [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($Snaps),
        [TerminalOrganizer.App.PriorityOverride[]]@($Overrides), $script:R9Mon1.StableKey, $DefaultRank)
    $plan = [TerminalOrganizer.Core.Overflow.CrossMonitorPlanner]::Plan($composed)
    @{ Composed = $composed; Plan = $plan }
}

function Get-R9Priority($World, [string]$Id) {
    @($World.Composed.Windows | Where-Object { $_.WindowId -eq $Id })[0].Priority
}

Describe 'SPEC-RULES-009 AC-001 name-only consumers accept named windows' {
    $rules = New-R9Rules
    $rows = @(
        [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]11, $script:R9Mon1, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true),
            [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]11, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', 'powershell')),
        [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]12, $script:R9Mon1, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true),
            [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]12, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', 'OC_YODA1')),
        [TerminalOrganizer.Core.Windows.EnumeratedWindow]::new([IntPtr]13, $script:R9Mon1, [TerminalOrganizer.Core.Monitors.DesktopFlagResult]::Ok($true),
            [TerminalOrganizer.Core.Windows.WindowIdentity]::new([IntPtr]13, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', 'Untitled tab'))
    )
    $titles = @{ 11 = 'powershell'; 12 = 'OC_YODA1'; 13 = 'Untitled tab' }
    $state = [Func[IntPtr, TerminalOrganizer.Core.Assignment.WindowState]] { param($h) [TerminalOrganizer.Core.Assignment.WindowState]::new(0, 0, 400, 300, $false, $false, $false) }
    $tabs = [TerminalOrganizer.Core.Overflow.TabTitleRead] { param($h) [TerminalOrganizer.Core.Windows.TabTitleResult]::Ok([string[]]@($titles[[int]$h.ToInt64()])) }
    $sessions = [TerminalOrganizer.App.SessionRecordsRead] { param($pids) @([TerminalOrganizer.Core.Windows.SessionRecord]::new('YODA1', [TerminalOrganizer.Core.Windows.SessionKind]::Local, $script:R9YodaCmd)) }

    It 'a window fact built by rule-set discovery reports that it has an identity name, for W-PS and the unmatched title alike' {
        $found = [TerminalOrganizer.App.DiscoveryPolicy]::Acquire($rows, $script:R9Mon1, $state, $tabs, $sessions, $null, $rules)
        @($found.Facts).Count | Should Be 3
        foreach ($fact in $found.Facts) { $fact.Identified | Should Be $true }
    }
    It 'W-PS and Untitled tab appear among the manager candidates of the tray menu model' {
        $found = [TerminalOrganizer.App.DiscoveryPolicy]::Acquire($rows, $script:R9Mon1, $state, $tabs, $sessions, $null, $rules)
        $state9 = [TerminalOrganizer.App.TrayMenuState]::new($false, 'Ctrl+Alt+O', [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($script:R9Mon1),
            $found.Snapshots, [TerminalOrganizer.Core.Assignment.ManagerSelector]::None(), $null, $null, $false)
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($state9)
        $manager = @($entries | Where-Object { $_.Kind.ToString() -eq 'ManagerRoot' })[0]
        $group = @($manager.Children | Where-Object { $_.Kind.ToString() -eq 'ManagerCandidateGroup' })[0]
        $labels = @($group.Children | ForEach-Object { $_.Label })
        ($labels -contains 'powershell') | Should Be $true
        ($labels -contains 'Untitled tab') | Should Be $true
        ($labels -contains 'OC_YODA1') | Should Be $true
    }
    It 'a RawTitle selector powershell resolves to W-PS and the zone assigner pins it as manager' {
        $found = [TerminalOrganizer.App.DiscoveryPolicy]::Acquire($rows, $script:R9Mon1, $state, $tabs, $sessions, $null, $rules)
        $selector = New-R9Selector 'RawTitle' 'powershell' 'powershell'
        $resolution = [TerminalOrganizer.Core.Assignment.ManagerResolver]::Resolve($selector, $found.Facts, $found.Snapshots)
        $resolution.Status.ToString() | Should BeExactly 'Resolved'
        $plan = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign((New-CZones), $found.Facts, 'powershell')
        $plan.ManagerPinned | Should Be $true
    }
    It 'a fact passed in with no identity name still yields window unidentified' {
        $fact = New-R9Fact 'wx' 14 'powershell' $false
        $plan = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign((New-CZones), @($fact), 'powershell')
        $plan.ManagerPinned | Should Be $false
        $plan.ManagerSkippedReason | Should Match 'unidentified'
    }
}

Describe 'SPEC-RULES-009 AC-002 strict consumers unchanged' {
    It 'a stacked zone with W-PS as its base is planned stack-only and W-PS is never a merge source' {
        $rules = New-R9Rules
        $sess = New-CSession 'YODA2' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA2'
        foreach ($order in @('ps-first', 'ps-second')) {
            $acq = @((New-R9Acquired 21 @('powershell')), (New-R9Acquired 22 @('OC_YODA2')))
            $snaps = Get-R9Snapshots $acq @($sess) $rules
            $psTop = if ($order -eq 'ps-first') { 0 } else { 400 }
            $xTop = if ($order -eq 'ps-first') { 400 } else { 0 }
            $facts = @((New-R9Fact 'wps' 21 'powershell' $true 0 $psTop), (New-R9Fact 'wx' 22 'OC_YODA2' $true 0 $xTop))
            $zone = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 0, 0, 960, 1040))
            $plan = [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zone, [TerminalOrganizer.Core.Assignment.WindowFact[]]$facts, $null)
            $merge = [TerminalOrganizer.Core.Overflow.MergePlanner]::Plan($plan, [TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps)
            (@($merge.Merges | Where-Object { $_.SourceWindowId -eq 'wps' })).Count | Should Be 0
            if ($order -eq 'ps-first') {
                @($merge.StackOnlyZoneIds).Count | Should Be 1
                @($merge.Merges).Count | Should Be 0
            }
        }
    }
    It 'a catch-all fixed-name rule and an open session of that name neither identify nor make a window mergeable' {
        $rules = New-R9Rules $true '{"match":"*","name":"YODA3"}'
        $sess = New-CSession 'YODA3' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA3'
        $snaps = Get-R9Snapshots @((New-R9Acquired 23 @('scratch'))) @($sess) $rules
        $snaps[0].Identified | Should Be $false
        $snaps[0].Mergeable | Should Be $false
        $snaps[0].IdentityName | Should BeExactly 'YODA3'
    }
}

Describe 'SPEC-RULES-009 AC-003 Identity selector kind' {
    $rules = New-R9Rules
    It 'W-SSH is chosen as manager through an Identity selector with value server1 and raw-title fallback ssh server1' {
        $snap = (Get-R9Snapshots @((New-R9Acquired 31 @('ssh server1'))) @() $rules)[0]
        $selector = [TerminalOrganizer.Core.Assignment.ManagerResolver]::CreateSelector($snap, $null)
        $selector.Kind.ToString() | Should BeExactly 'Identity'
        $selector.Value | Should BeExactly 'server1'
        $selector.RawTitleFallback | Should BeExactly 'ssh server1'
    }
    It 'after the title changes to ssh server1 -v the saved selector still resolves to that window' {
        $selector = New-R9Selector 'Identity' 'server1' 'ssh server1'
        $snap = (Get-R9Snapshots @((New-R9Acquired 31 @('ssh server1 -v'))) @() $rules)[0]
        $fact = New-R9Fact 'w31' 31 'ssh server1 -v'
        $resolution = [TerminalOrganizer.Core.Assignment.ManagerResolver]::Resolve($selector,
            [TerminalOrganizer.Core.Assignment.WindowFact[]]@($fact), [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($snap))
        $resolution.Status.ToString() | Should BeExactly 'Resolved'
        $resolution.WindowId | Should BeExactly 'w31'
    }
    It 'a two-session window gets an Identity selector with value YODA1; a partially bound window keeps a Session selector' {
        $s1 = New-CSession 'YODA1' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA1'
        $s2 = New-CSession 'YODA2' 'Local' 'wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach YODA2'
        $two = (Get-R9Snapshots @((New-R9Acquired 32 @('OC_YODA1', 'OC_YODA2'))) @($s1, $s2) $rules)[0]
        $created = [TerminalOrganizer.Core.Assignment.ManagerResolver]::CreateSelector($two, $null)
        $created.Kind.ToString() | Should BeExactly 'Identity'
        $created.Value | Should BeExactly 'YODA1'
        $partial = (Get-R9Snapshots @((New-R9Acquired 33 @('OC_YODA1', 'scratch'))) @($s1) $rules)[0]
        $createdPartial = [TerminalOrganizer.Core.Assignment.ManagerResolver]::CreateSelector($partial, $null)
        $createdPartial.Kind.ToString() | Should BeExactly 'Session'
        $createdPartial.Value | Should BeExactly 'YODA1'
    }
    It 'an Identity override row ranks W-SSH 600 as manual, survives a save and reload with kind Identity, and a RawTitle row still matches by raw title' {
        $snap = (Get-R9Snapshots @((New-R9Acquired 34 @('ssh server1'))) @() $rules)[0]
        $fact = New-R9Fact 'w34' 34 'ssh server1' $true 100 500
        $row = [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'Identity' 'server1' 'ssh server1'), 600)
        $world = Get-R9World @($fact) @($snap) @($row) 500
        $priority = Get-R9Priority $world 'w34'
        $priority.Rank | Should Be 600
        $priority.Source.ToString() | Should BeExactly 'Manual'
        $priority.Provenance | Should BeExactly 'manual'
        $dir = New-R9TempDir
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new((Join-Path $dir 'settings.json'))
            $store.Save([TerminalOrganizer.App.AppSettings]::new('Ctrl+Alt+O', 'test.log', $null, $false, $true, $false,
                $null, [TerminalOrganizer.App.PriorityOverride[]]@($row), 3,
                [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'), $false))
            $reloaded = $store.Load()
            @($reloaded.PriorityOverrides).Count | Should Be 1
            $reloaded.PriorityOverrides[0].Selector.Kind.ToString() | Should BeExactly 'Identity'
            $reloaded.PriorityOverrides[0].Rank | Should Be 600
        }
        finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
        $rawRow = [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'RawTitle' 'ssh server1' 'ssh server1'), 650)
        $rawWorld = Get-R9World @($fact) @($snap) @($rawRow) 500
        (Get-R9Priority $rawWorld 'w34').Rank | Should Be 650
    }
    It 'Identity is the last selector kind and the canonical order of Session, UserLabel and RawTitle rows is unchanged' {
        $names = [Enum]::GetNames([TerminalOrganizer.Core.Assignment.ManagerSelectorKind])
        $names[$names.Count - 1] | Should BeExactly 'Identity'
        ($names[0..3] -join ',') | Should BeExactly 'None,Session,UserLabel,RawTitle'
        $rowsIn = @(
            [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'RawTitle' 'b' 'b'), 1),
            [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'Identity' 'a' 'a'), 2),
            [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'Session' 'c' 'c'), 3),
            [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'UserLabel' 'd' 'd'), 4)
        )
        $sorted = [TerminalOrganizer.App.SettingsStore]::NormalizeOverrides([TerminalOrganizer.App.PriorityOverride[]]$rowsIn)
        (($sorted | ForEach-Object { $_.Selector.Kind.ToString() }) -join ',') | Should BeExactly 'Session,UserLabel,RawTitle,Identity'
    }
}

Describe 'SPEC-RULES-009 AC-004 labeled windows' {
    $rules = New-R9Rules
    $composition = [TerminalOrganizer.App.AppSettings].Assembly.GetType('TerminalOrganizer.App.Composition')
    $apply = $composition.GetMethod('ApplyLabels', [Reflection.BindingFlags]'NonPublic,Static')
    $wl = New-CSession 'YODA1' 'Local' $script:R9YodaCmd

    It 'the overlay rebuilds a labeled window with identity = label, a synthetic session without a command line, and the rule outcome carried through' {
        $acq = @((New-R9Acquired 41 @('powershell')), (New-R9Acquired 42 @('Untitled tab')), (New-R9Acquired 43 @('1000-big')), (New-R9Acquired 44 @('OC_YODA1')))
        $snaps = Get-R9Snapshots $acq @($wl) $rules
        $labels = [TerminalOrganizer.App.LabelRegistry]::new()
        $labels.SetLabel([IntPtr]41, 'scratch')
        $labels.SetLabel([IntPtr]42, 'notes')
        $labels.SetLabel([IntPtr]43, 'bigjob')
        $labels.SetLabel([IntPtr]44, 'relabel')
        $shots = $apply.Invoke($null, [object[]]@([TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps, $labels))
        $ps = $shots[0]; $notes = $shots[1]; $big = $shots[2]; $yoda = $shots[3]
        $ps.IdentityName | Should BeExactly 'scratch'
        $ps.Identified | Should Be $true
        $ps.Mergeable | Should Be $false
        $ps.Tabs[0].Session.CommandLine | Should BeNullOrEmpty
        $ps.RuleRank | Should Be 200
        $ps.RuleReference | Should BeExactly 'rule 1: PowerShell*'
        $ps.HasRuleOutcome | Should Be $true
        $notes.IdentityName | Should BeExactly 'notes'
        $notes.RuleRank | Should BeNullOrEmpty
        $notes.RuleReference | Should BeNullOrEmpty
        $big.IdentityName | Should BeExactly 'bigjob'
        $big.RuleRank | Should BeNullOrEmpty
        $big.RuleReference | Should BeExactly 'rule 3: regex:^(?<rank>[0-9]{1,4})-(?<name>.+)$'
        # W-L has canonical session evidence and is not relabeled.
        $yoda.IdentityName | Should BeExactly 'YODA1'
        $yoda.Tabs[0].Session.CommandLine | Should BeExactly $script:R9YodaCmd
    }
    It 'labeled windows rank by rule rank first, then the 300 label step' {
        $acq = @((New-R9Acquired 41 @('powershell')), (New-R9Acquired 42 @('Untitled tab')), (New-R9Acquired 43 @('1000-big')))
        $snaps = Get-R9Snapshots $acq @() $rules
        $labels = [TerminalOrganizer.App.LabelRegistry]::new()
        $labels.SetLabel([IntPtr]41, 'scratch')
        $labels.SetLabel([IntPtr]42, 'notes')
        $labels.SetLabel([IntPtr]43, 'bigjob')
        $shots = $apply.Invoke($null, [object[]]@([TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps, $labels))
        $facts = @((New-R9Fact 'wps' 41 'powershell' $true 100 500), (New-R9Fact 'wnotes' 42 'Untitled tab' $true 100 600), (New-R9Fact 'wbig' 43 '1000-big' $true 100 700))
        $world = Get-R9World $facts @($shots) @() 450
        $ps = Get-R9Priority $world 'wps'
        $ps.Rank | Should Be 200
        $ps.Source.ToString() | Should BeExactly 'Declared'
        $ps.Provenance | Should BeExactly 'rule 1: PowerShell*'
        $notes = Get-R9Priority $world 'wnotes'
        $notes.Rank | Should Be 300
        $big = Get-R9Priority $world 'wbig'
        $big.Rank | Should Be 300
        $big.Provenance | Should Match 'matched rule 3:'
    }
}

Describe 'SPEC-RULES-009 AC-005 priority wiring end to end' {
    $rules = New-R9Rules
    $wl = New-CSession 'YODA1' 'Local' $script:R9YodaCmd
    function New-R9OverflowFixture {
        $acq = @((New-R9Acquired 51 @('OC_YODA1')), (New-R9Acquired 52 @('powershell')), (New-R9Acquired 53 @('ssh server1')), (New-R9Acquired 54 @('Untitled tab')))
        $snaps = Get-R9Snapshots $acq @($wl) $rules
        $facts = @(
            (New-R9Fact 'wl' 51 'OC_YODA1' $true 0 0 960 1040),
            (New-R9Fact 'wps' 52 'powershell' $true 100 500),
            (New-R9Fact 'wssh' 53 'ssh server1' $true 100 600),
            (New-R9Fact 'wut' 54 'Untitled tab' $true 100 700))
        @{ Snaps = $snaps; Facts = $facts }
    }

    It 'the composer with a default rank resolves W-PS 200 and W-SSH 400 as Declared, Untitled tab 450 as Derived, W-L as a stable occupant, and plans the single move for Untitled tab' {
        $fx = New-R9OverflowFixture
        $world = Get-R9World $fx.Facts $fx.Snaps @() 450
        $ps = Get-R9Priority $world 'wps'
        $ps.Rank | Should Be 200
        $ps.Source.ToString() | Should BeExactly 'Declared'
        $ssh = Get-R9Priority $world 'wssh'
        $ssh.Rank | Should Be 400
        $ssh.Source.ToString() | Should BeExactly 'Declared'
        $ut = Get-R9Priority $world 'wut'
        $ut.Rank | Should Be 450
        $ut.Source.ToString() | Should BeExactly 'Derived'
        $ut.Provenance | Should BeExactly 'default'
        $lw = Get-R9Priority $world 'wl'
        $lw.Immovable | Should Be $true
        $lw.ImmovableReason | Should BeExactly 'stable occupant'
        @($world.Plan.Moves).Count | Should Be 1
        $world.Plan.Moves[0].WindowId | Should BeExactly 'wut'
        $world.Plan.Moves[0].PriorityReason | Should BeExactly 'derived rank 450'
    }
    It 'the organize controller builds the same plan when its world capture carries the default rank' {
        $fx = New-R9OverflowFixture
        $script:R9Fx = $fx
        $zones1 = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 0, 0, 960, 1040))
        $zones2 = [TerminalOrganizer.Core.Geometry.Zone[]]@([TerminalOrganizer.Core.Geometry.Zone]::new(0, 1920, 0, 960, 1040))
        $script:R9Z1 = $zones1
        $script:R9Z2 = $zones2
        $desktop = [TerminalOrganizer.App.CurrentDesktopSource] { '{00000000-0000-4000-8000-000000000009}' }
        $layout = [TerminalOrganizer.App.LayoutResolution] {
            param($monitor, $d)
            $z = if ($monitor.Number -eq 2) { $script:R9Z2 } else { $script:R9Z1 }
            [TerminalOrganizer.Core.Layouts.LayoutResult]::Supported('grid', $null, 0, $z, @())
        }
        $disc = [TerminalOrganizer.App.WindowDiscovery] {
            param($monitor, $d)
            New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList ([TerminalOrganizer.Core.Assignment.WindowFact[]]$script:R9Fx.Facts), ([TerminalOrganizer.Core.Windows.WindowSnapshot[]]$script:R9Fx.Snaps)
        }
        $assign = [TerminalOrganizer.Core.Overflow.AssignmentComputation] {
            param($zones, $facts, $manager)
            [TerminalOrganizer.Core.Assignment.ZoneAssigner]::Assign($zones, $facts, $manager)
        }
        $merge = [TerminalOrganizer.App.MergePlanning] { param($plan, $snaps) [TerminalOrganizer.Core.Overflow.MergePlanner]::Plan($plan, $snaps) }
        $probe = [TerminalOrganizer.App.HelperExistsProbe] { param($m) $true }
        $exec = [TerminalOrganizer.Core.Overflow.MergeExecution] { param($m) [TerminalOrganizer.Core.Overflow.MergeOutcome]::Merged($m.SourceWindowId) }
        $place = [TerminalOrganizer.Core.Overflow.PlacementPass] { param($p) @() }
        $notice = [TerminalOrganizer.App.NoticeSink] { param($t) }
        $world = [TerminalOrganizer.App.OverflowWorldCapture] {
            param($target, $d)
            $row = [TerminalOrganizer.App.CapturedMonitorRow]::new($script:R9Mon2, $script:R9Z2, 'M2',
                (New-Object TerminalOrganizer.App.DiscoveredWindows -ArgumentList @(), @()))
            [TerminalOrganizer.App.CapturedOverflowWorld]::new([TerminalOrganizer.App.CapturedMonitorRow[]]@($row),
                [TerminalOrganizer.App.PriorityOverride[]]@(), 450)
        }
        $controller = New-Object TerminalOrganizer.App.OrganizeController -ArgumentList `
            $desktop, $layout, $disc, $assign, $merge, $probe, $exec, $place, $notice, ([TerminalOrganizer.App.LabelRegistry]::new()), $null, `
            $null, $null, $null, $world, $null
        $prepared = $controller.Prepare($script:R9Mon1, $null, $false, 'M1', $null, $null, [System.Threading.CancellationToken]::None)
        @($prepared.Plan.RedistributionPlan.Moves).Count | Should Be 1
        $prepared.Plan.RedistributionPlan.Moves[0].WindowId | Should BeExactly 'wut'
        $prepared.Plan.RedistributionPlan.Moves[0].PriorityReason | Should BeExactly 'derived rank 450'
    }
    It 'a world capture without a default rank keeps 500 and a snapshot built through today''s constructor keeps its title-parsed rank' {
        $lgFact = New-CFact 'LG' -Top 500 -Left 100
        $legacy = New-CSnap 'LG' @('OC9_R9') @((New-CSession 'R9' 'Local' 'wsl.exe -d Ubuntu --exec r9.sh')) $true $true
        $legacy.HasRuleOutcome | Should Be $false
        $world3 = [TerminalOrganizer.App.CapturedOverflowWorld]::new([TerminalOrganizer.App.CapturedMonitorRow[]]@(), [TerminalOrganizer.App.PriorityOverride[]]@())
        $world3.DefaultRank | Should Be 500
        $world = Get-R9World @($lgFact) @($legacy) @() 450
        $p = Get-R9Priority $world 'LG'
        $p.Rank | Should Be 9
        $p.Reason | Should BeExactly 'declared'
    }
}

Describe 'SPEC-RULES-009 AC-015 organize run pins the manager by identity' {
    $rules = New-R9Rules
    It 'the 7-parameter Run pins W-SSH after its title changed, with no window-not-found skip' {
        $h = New-CController
        $fact = New-CFact 'ssh server1 -v' -Top 100 -Left 100
        $snap = (Get-R9Snapshots @((New-R9Acquired ([long]$script:CHandles['ssh server1 -v'].ToInt64()) @('ssh server1 -v'))) @() $rules)[0]
        $script:CFacts = @($fact)
        $script:CSnaps = @($snap)
        $selector = New-R9Selector 'Identity' 'server1' 'ssh server1'
        $result = $h.Controller.Run((New-TMonitor 1), 'ssh server1', $false, 'M1', $null, [System.Threading.CancellationToken]::None, $selector)
        $result.Completed | Should Be $true
        $result.FinalPlan.ManagerPinned | Should Be $true
        $result.FinalPlan.ManagerWindowId | Should BeExactly 'ssh server1 -v'
        (@($script:Notices | Where-Object { $_ -like '*not open*' })).Count | Should Be 0
    }
    It 'with no window carrying identity server1 the run falls back to raw-title matching and reports today''s skip reason' {
        $h = New-CController
        $fact = New-CFact 'other window' -Top 100 -Left 100
        $snap = (Get-R9Snapshots @((New-R9Acquired ([long]$script:CHandles['other window'].ToInt64()) @('other window'))) @() $rules)[0]
        $script:CFacts = @($fact)
        $script:CSnaps = @($snap)
        $selector = New-R9Selector 'Identity' 'server1' 'ssh server1'
        $result = $h.Controller.Run((New-TMonitor 1), 'ssh server1', $false, 'M1', $null, [System.Threading.CancellationToken]::None, $selector)
        $result.FinalPlan.ManagerPinned | Should Be $false
        (@($script:Notices | Where-Object { $_ -like '*ssh server1*not open*' })).Count | Should Be 1
    }
    It 'the 10-parameter RunWithChoice resolves the selector like the 7-parameter Run' {
        $h = New-CController
        $fact = New-CFact 'ssh server1 -v' -Top 100 -Left 100
        $snap = (Get-R9Snapshots @((New-R9Acquired ([long]$script:CHandles['ssh server1 -v'].ToInt64()) @('ssh server1 -v'))) @() $rules)[0]
        $script:CFacts = @($fact)
        $script:CSnaps = @($snap)
        $selector = New-R9Selector 'Identity' 'server1' 'ssh server1'
        $result = $h.Controller.RunWithChoice((New-TMonitor 1), 'ssh server1', 'M1', $null,
            [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Stack'),
            $false, $null, $null, [System.Threading.CancellationToken]::None, $selector)
        $result.FinalPlan.ManagerPinned | Should Be $true
    }
    It 'the menu resolution and the run name the same manager window' {
        $selector = New-R9Selector 'Identity' 'server1' 'ssh server1'
        $snap = (Get-R9Snapshots @((New-R9Acquired 61 @('ssh server1 -v'))) @() $rules)[0]
        $fact = New-R9Fact 'w61' 61 'ssh server1 -v'
        $menu = [TerminalOrganizer.Core.Assignment.ManagerResolver]::Resolve($selector,
            [TerminalOrganizer.Core.Assignment.WindowFact[]]@($fact), [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($snap))
        $menu.WindowId | Should BeExactly 'w61'
    }
}

# --- SPEC-RULES-009 M3: menu provenance rows and the tools ---
# Expected values come from SPEC-RULES-009 acceptance.md and plan.md section J.4, never from the code under test.

$script:R9Dot = ' ' + [string][char]0x00B7 + ' '
$script:R9Ellipsis = [string][char]0x2026

function Get-R9LabelRoot($Snaps, $Overrides = @(), [int]$DefaultRank = 500) {
    $texts = [TerminalOrganizer.App.RuleProvenance]::RowTexts(
        [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($Snaps),
        [TerminalOrganizer.App.PriorityOverride[]]@($Overrides), $DefaultRank)
    $state = [TerminalOrganizer.App.TrayMenuState]::new($false, 'Ctrl+Alt+O',
        [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($script:R9Mon1),
        [TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($Snaps),
        [TerminalOrganizer.Core.Assignment.ManagerSelector]::None(), $null, $null, $false,
        [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], 'Ask'),
        [string[]]@($texts))
    $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($state)
    @($entries | Where-Object { $_.Kind.ToString() -eq 'LabelsAndPrioritiesRoot' })[0]
}

Describe 'SPEC-RULES-009 AC-010 menu rows' {
    $rules = New-R9Rules
    $wl = New-CSession 'YODA1' 'Local' $script:R9YodaCmd

    It 'Labels and priorities lists the three pinned rows, W-PS and W-SSH enabled and W-L disabled' {
        $acq = @((New-R9Acquired 71 @('powershell')), (New-R9Acquired 72 @('OC_YODA1')), (New-R9Acquired 73 @('ssh server1')))
        $snaps = Get-R9Snapshots $acq @($wl) $rules
        $root = Get-R9LabelRoot $snaps
        $root.Enabled | Should Be $true
        @($root.Children).Count | Should Be 3
        $root.Children[0].Label | Should BeExactly ('powershell' + $script:R9Dot + 'rank 200' + $script:R9Dot + 'rule 1: PowerShell*')
        $root.Children[1].Label | Should BeExactly ('OC_YODA1 (as YODA1)' + $script:R9Dot + 'rank 300' + $script:R9Dot + 'session Local (matched preset launcher-prefix)')
        $root.Children[2].Label | Should BeExactly ('ssh server1 (as server1)' + $script:R9Dot + 'rank 400' + $script:R9Dot + 'rule 2: regex:^ssh (?<name>[^ ]+)')
        $root.Children[0].Enabled | Should Be $true
        $root.Children[1].Enabled | Should Be $false
        $root.Children[2].Enabled | Should Be $true
    }
    It 'a provenance longer than 80 characters is cut to its first 79 characters plus an ellipsis' {
        $x80 = 'x' * 80
        $long = New-R9Rules $false ('{"match":"regex:^' + $x80 + '$","rank":100}')
        $snap = (Get-R9Snapshots @((New-R9Acquired 74 @($x80))) @() $long)[0]
        $snap.RuleReference.Length | Should Be 96
        $root = Get-R9LabelRoot @($snap)
        $expectedProvenance = 'rule 1: regex:^' + ('x' * 64) + $script:R9Ellipsis
        $expectedProvenance.Length | Should Be 80
        $root.Children[0].Label | Should BeExactly ($x80 + $script:R9Dot + 'rank 100' + $script:R9Dot + $expectedProvenance)
    }
    It 'a provenance of exactly 80 characters is not cut' {
        $x = 'x' * 64
        $rule = New-R9Rules $false ('{"match":"regex:^' + $x + '$","rank":100}')
        $snap = (Get-R9Snapshots @((New-R9Acquired 75 @($x))) @() $rule)[0]
        $snap.RuleReference.Length | Should Be 80
        $root = Get-R9LabelRoot @($snap)
        $root.Children[0].Label | Should BeExactly ($x + $script:R9Dot + 'rank 100' + $script:R9Dot + $snap.RuleReference)
    }
    It 'no menu entry kind edits rules' {
        @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]) | Where-Object { $_ -match 'Rule' }).Count | Should Be 0
    }
    It 'the existing constructors still list only unidentified windows as label rows' {
        $acq = @((New-R9Acquired 76 @('powershell')), (New-R9Acquired 77 @('OC_YODA1')))
        $snaps = Get-R9Snapshots $acq @($wl) $rules
        $state = [TerminalOrganizer.App.TrayMenuState]::new($false, 'Ctrl+Alt+O',
            [TerminalOrganizer.Core.Monitors.MonitorInfo[]]@($script:R9Mon1), [TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps,
            [TerminalOrganizer.Core.Assignment.ManagerSelector]::None(), $null, $null, $false)
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($state)
        $root = @($entries | Where-Object { $_.Kind.ToString() -eq 'LabelsAndPrioritiesRoot' })[0]
        @($root.Children).Count | Should Be 1
        $root.Children[0].Label | Should BeExactly 'powershell'
    }
}

Describe 'SPEC-RULES-009 AC-004 labeled rows' {
    $rules = New-R9Rules
    $composition = [TerminalOrganizer.App.AppSettings].Assembly.GetType('TerminalOrganizer.App.Composition')
    $apply = $composition.GetMethod('ApplyLabels', [Reflection.BindingFlags]'NonPublic,Static')
    $wl = New-CSession 'YODA1' 'Local' $script:R9YodaCmd

    It 'labeled windows render the label step, stay enabled, and W-L is not relabeled' {
        $acq = @((New-R9Acquired 81 @('powershell')), (New-R9Acquired 82 @('Untitled tab')), (New-R9Acquired 83 @('1000-big')), (New-R9Acquired 84 @('OC_YODA1')))
        $snaps = Get-R9Snapshots $acq @($wl) $rules
        $labels = [TerminalOrganizer.App.LabelRegistry]::new()
        $labels.SetLabel([IntPtr]81, 'scratch')
        $labels.SetLabel([IntPtr]82, 'notes')
        $labels.SetLabel([IntPtr]83, 'bigjob')
        $labels.SetLabel([IntPtr]84, 'relabel')
        $shots = $apply.Invoke($null, [object[]]@([TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps, $labels))
        $root = Get-R9LabelRoot $shots
        @($root.Children).Count | Should Be 4
        $root.Children[0].Label | Should BeExactly ('powershell (as scratch)' + $script:R9Dot + 'rank 200' + $script:R9Dot + 'rule 1: PowerShell*')
        $root.Children[1].Label | Should BeExactly ('Untitled tab (as notes)' + $script:R9Dot + 'rank 300' + $script:R9Dot + 'label')
        $root.Children[2].Label | Should BeExactly ('1000-big (as bigjob)' + $script:R9Dot + 'rank 300' + $script:R9Dot + 'label (matched rule 3: regex:^(?<rank>[0-9]{1,4})-(?<name>.+)$)')
        $root.Children[3].Label | Should BeExactly ('OC_YODA1 (as YODA1)' + $script:R9Dot + 'rank 300' + $script:R9Dot + 'session Local (matched preset launcher-prefix)')
        $root.Children[0].Enabled | Should Be $true
        $root.Children[1].Enabled | Should Be $true
        $root.Children[2].Enabled | Should Be $true
        $root.Children[3].Enabled | Should Be $false
    }
}

Describe 'SPEC-RULES-009 AC-005 menu and redistribution agree for movable windows' {
    $rules = New-R9Rules
    $wl = New-CSession 'YODA1' 'Local' $script:R9YodaCmd
    It 'the menu rows carry the ranks used for redistribution; W-L shows 300 while it is immovable' {
        $acq = @((New-R9Acquired 91 @('OC_YODA1')), (New-R9Acquired 92 @('powershell')), (New-R9Acquired 93 @('ssh server1')), (New-R9Acquired 94 @('Untitled tab')))
        $snaps = Get-R9Snapshots $acq @($wl) $rules
        $facts = @(
            (New-R9Fact 'wl' 91 'OC_YODA1' $true 0 0 960 1040),
            (New-R9Fact 'wps' 92 'powershell' $true 100 500),
            (New-R9Fact 'wssh' 93 'ssh server1' $true 100 600),
            (New-R9Fact 'wut' 94 'Untitled tab' $true 100 700))
        $world = Get-R9World $facts $snaps @() 450
        $texts = [TerminalOrganizer.App.RuleProvenance]::RowTexts([TerminalOrganizer.Core.Windows.WindowSnapshot[]]$snaps, [TerminalOrganizer.App.PriorityOverride[]]@(), 450)
        $texts.Count | Should Be 4
        $texts[0] | Should Match 'rank 300'
        (Get-R9Priority $world 'wl').Immovable | Should Be $true
        $ids = @('wl', 'wps', 'wssh', 'wut')
        for ($i = 1; $i -lt 4; $i++) {
            $p = Get-R9Priority $world $ids[$i]
            $texts[$i] | Should Match ('rank ' + $p.Rank + ' ')
        }
        $texts[3] | Should BeExactly ('Untitled tab' + $script:R9Dot + 'rank 450' + $script:R9Dot + 'default')
    }
    It 'a manual Identity override shows rank and the manual provenance in the menu row' {
        $snap = (Get-R9Snapshots @((New-R9Acquired 95 @('ssh server1'))) @() $rules)[0]
        $row = [TerminalOrganizer.App.PriorityOverride]::new((New-R9Selector 'Identity' 'server1' 'ssh server1'), 600)
        $texts = [TerminalOrganizer.App.RuleProvenance]::RowTexts([TerminalOrganizer.Core.Windows.WindowSnapshot[]]@($snap), [TerminalOrganizer.App.PriorityOverride[]]@($row), 500)
        $texts[0] | Should BeExactly ('ssh server1 (as server1)' + $script:R9Dot + 'rank 600' + $script:R9Dot + 'manual')
    }
}

Describe 'SPEC-RULES-009 AC-011 tools compose with rules at every site' {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($toolName in @('organize-dryrun.ps1', 'organize-once.ps1')) {
        $tool = Join-Path $repoRoot ('tools\' + $toolName)
        It ($toolName + ' -SelfTest runs the line check and the preview check and exits 0') {
            $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $tool -SelfTest
            $LASTEXITCODE | Should Be 0
            (@($out | Where-Object { $_ -like 'FAIL: *' }).Count) | Should Be 0
            (@($out | Where-Object { $_ -eq 'PASS: ac011/lines' }).Count) | Should Be 1
            (@($out | Where-Object { $_ -eq 'PASS: ac011/preview' }).Count) | Should Be 1
        }
        It ($toolName + ' stays pure ASCII and carries no second provenance formatter') {
            $text = [IO.File]::ReadAllText($tool)
            ($text -match '[^\x00-\x7F]') | Should Be $false
            $text.Contains('RuleProvenance') | Should Be $true
            $text.Contains('Compose($acquired, $sessions)') | Should Be $false
            $text.Contains('ManagerStore') | Should Be $false
        }
    }
    It 'organize-once calls the 7-parameter Run overload at both run sites' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'tools\organize-once.ps1'))
        ([regex]::Matches($text, '\$controller\.Run\(\$chosen, \$managerName, \$false, \$null, \$null, \[System\.Threading\.CancellationToken\]::None, \$selector\)')).Count | Should Be 2
    }
}

# --- SPEC-RULES-009 M4: README title-rules section (AC-013) ---
# The five example rules are the verbatim lines of plan.md section J.5.

Describe 'SPEC-RULES-009 AC-013 README' {
    $readme = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
    $startMarker = '### Title rules'
    $startIndex = $readme.IndexOf($startMarker)
    $endIndex = if ($startIndex -ge 0) { $readme.IndexOf("`n### ", $startIndex + 5) } else { -1 }
    $section = if ($startIndex -ge 0 -and $endIndex -gt $startIndex) { $readme.Substring($startIndex, $endIndex - $startIndex) } else { '' }

    It 'the old priority-channel heading is gone and a title-rules section stands in its place' {
        $readme.Contains('### Window titles as the priority channel') | Should Be $false
        $startIndex | Should BeGreaterThan -1
        $section.Length | Should BeGreaterThan 200
        # In its place: after the tray menu section and before the overflow section.
        $readme.IndexOf('### The tray menu') | Should BeLessThan $startIndex
        $readme.IndexOf("### When windows don't all fit") | Should BeGreaterThan $startIndex
    }
    It 'the section carries the five pinned example rules verbatim' {
        $section.Contains('{ "match": "PowerShell*", "rank": 200 }') | Should Be $true
        $section.Contains('{ "match": "regex:^[A-Z]:", "rank": 150 }') | Should Be $true
        $section.Contains('{ "match": "regex:^(?<rank>[0-9]{1,3})-(?<name>.+)$" }') | Should Be $true
        $section.Contains('{ "marker": "#" }') | Should Be $true
        $section.Contains('{ "match": "*--attach YODA*", "on": "commandline", "rank": 250 }') | Should Be $true
    }
    It 'the section names the preset, the precedence order and the caveats' {
        $section.Contains('launcher-prefix') | Should Be $true
        $section | Should Match '(?i)precedence'
        $section | Should Match '(?i)a renamed window is a new identity'
        $section | Should Match '(?i)plain PowerShell, cmd and ssh windows have no command line to match'
        $section | Should Match '(?i)settings file.*(missing|reset).*(preset is off|preset off|starts with the preset off)|(missing|reset).*settings file.*preset'
    }
    It 'Known limitations gains one bullet stating that identity follows the window title' {
        $limits = $readme.Substring($readme.IndexOf('## Known limitations'))
        $limits = $limits.Substring(0, $limits.IndexOf('## License'))
        @($limits -split "`n" | Where-Object { $_ -match '^- ' -and $_ -match '(?i)identity follows the window title' }).Count | Should Be 1
    }
}

# ---------------------------------------------------------------------------
# SPEC-MON-011 M4: AppliedLayoutResolver (REQ-RES-001, REQ-RES-002; AC-011..AC-013)
# and M5 tool wiring (REQ-TOOL-002; AC-014, the organize tools).
# SF-STALE is pinned by hand from acceptance.md Conventions; expected row
# identities, zone counts and line counts are never taken from the code under test.
# Every resolver test builds its own FancyZones-shaped temp directory and removes it.
# ---------------------------------------------------------------------------
$RS_ID = 'DEL4091'
$RS_INST_4352 = '5&22cafbe4&0&UID4352'
$RS_INST_4358 = '5&22cafbe4&0&UID4358'
$RS_INST_NONE = '5&22cafbe4&0&UID9999'
$RS_DESK1 = '{9089F388-5216-49EA-9CD4-07E910D817EB}'
$RS_DESK2 = '{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}'
$RS_DESK3 = '{F00CF935-4664-4091-8DB7-96651F0C4D1E}'
$RS_EHU = 'XPG0H42JBEHU'
$RS_D2U = 'XPG0H42JBD2U'
$RS_FOUR = '{A1000000-0000-4000-8000-000000000004}'
$RS_FIVE = '{A1000000-0000-4000-8000-000000000005}'
$RS_TS = '[2026-10-23 18:52:16.538900] [p-24844] [t-24848] [info] '

# SF-STALE, the 12 rows in the original order (instance, number, serial, desktop, kind); L = live (FourTerms), S = stale (FiveTerms).
$RS_ROWS = @(
    @($RS_INST_4352, 2, $RS_D2U, $RS_DESK1, 'S'),
    @($RS_INST_4358, 2, $RS_EHU, $RS_DESK1, 'L'),
    @($RS_INST_4352, 1, $RS_EHU, $RS_DESK1, 'L'),
    @($RS_INST_4358, 2, $RS_EHU, $RS_DESK2, 'L'),
    @($RS_INST_4352, 1, $RS_EHU, $RS_DESK2, 'L'),
    @($RS_INST_4358, 1, $RS_D2U, $RS_DESK1, 'S'),
    @($RS_INST_4358, 1, $RS_D2U, $RS_DESK2, 'S'),
    @($RS_INST_4358, 1, $RS_D2U, $RS_DESK3, 'S'),
    @($RS_INST_4352, 2, $RS_D2U, $RS_DESK2, 'S'),
    @($RS_INST_4352, 2, $RS_D2U, $RS_DESK3, 'S'),
    @($RS_INST_4352, 1, $RS_EHU, $RS_DESK3, 'L'),
    @($RS_INST_4358, 2, $RS_EHU, $RS_DESK3, 'L')
)
$RS_ORIGINAL = @(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
$RS_REVERSE = @(11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0)
$RS_SHUFFLE = @(7, 2, 11, 0, 9, 4, 1, 10, 5, 8, 3, 6)

# Custom layouts with exactly two layouts: FourTerms (2x2 grid, 4 zones) and FiveTerms (1x5 grid, 5 zones).
$RS_CUSTOM = '{"custom-layouts":[' +
    '{"uuid":"' + $RS_FOUR + '","name":"FourTerms","type":"grid","info":{"rows":2,"columns":2,"rows-percentage":[5000,5000],"columns-percentage":[5000,5000],"cell-child-map":[[0,1],[2,3]],"show-spacing":false,"spacing":0,"sensitivity-radius":20}},' +
    '{"uuid":"' + $RS_FIVE + '","name":"FiveTerms","type":"grid","info":{"rows":1,"columns":5,"rows-percentage":[10000],"columns-percentage":[2000,2000,2000,2000,2000],"cell-child-map":[[0,1,2,3,4]],"show-spacing":false,"spacing":0,"sensitivity-radius":20}}]}'

function New-RsRowJson([int]$Index, [bool]$Shared) {
    $r = $RS_ROWS[$Index]
    $uuid = $RS_FIVE
    $zones = 5
    if ($Shared -or $r[4] -eq 'L') { $uuid = $RS_FOUR; $zones = 4 }
    '{"device":{"monitor":"' + $RS_ID + '","monitor-instance":"' + $r[0] + '","monitor-number":' + $r[1] +
        ',"serial-number":"' + $r[2] + '","virtual-desktop":"' + $r[3] +
        '"},"applied-layout":{"uuid":"' + $uuid + '","type":"custom","show-spacing":false,"spacing":0,"zone-count":' + $zones + ',"sensitivity-radius":20}}'
}

# SF-STALE (or SF-STALE-SHARED when $Shared) with its rows in the given order of original positions.
function New-RsAppliedJson([int[]]$Order, [bool]$Shared) {
    $rows = foreach ($i in $Order) { New-RsRowJson $i $Shared }
    '{"applied-layouts":[' + (@($rows) -join ',') + ']}'
}

function New-RsLogLine([string]$Instance, [string]$Number, [string]$Serial, [string]$Desktop) {
    '{0}Initialize layout on {1}_{2}_{3}_{4}_{5}, work area rect = 1920x1032' -f $RS_TS, $RS_ID, $Instance, $Number, $Serial, $Desktop
}

# The log of the Conventions: (1, EHU) for UID4352 and (2, EHU) for UID4358, on D1 and D2.
function Get-RsStandardLog {
    @(
        (New-RsLogLine $RS_INST_4352 '1' $RS_EHU $RS_DESK1),
        (New-RsLogLine $RS_INST_4358 '2' $RS_EHU $RS_DESK1),
        (New-RsLogLine $RS_INST_4352 '1' $RS_EHU $RS_DESK2),
        (New-RsLogLine $RS_INST_4358 '2' $RS_EHU $RS_DESK2)
    ) -join "`r`n"
}

function Get-RsLogPath([string]$Dir) { Join-Path $Dir 'Logs\v0.102.2862\log_2026-10-23.log' }

function Set-RsLog([string]$Dir, [string]$Text) {
    $path = Get-RsLogPath $Dir
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, $Text + "`r`n", [Text.Encoding]::ASCII)
}

function Add-RsLogText([string]$Dir, [string]$Text) {
    [IO.File]::AppendAllText((Get-RsLogPath $Dir), $Text + "`r`n", [Text.Encoding]::ASCII)
}

function Set-RsApplied([string]$Dir, [string]$Json) {
    [IO.File]::WriteAllText((Join-Path $Dir 'applied-layouts.json'), $Json)
}

# A fresh FancyZones-shaped directory: applied-layouts.json, custom-layouts.json and the standard log.
function New-RsDir([bool]$Shared) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('mon011-rs-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    Set-RsApplied $dir (New-RsAppliedJson $RS_ORIGINAL $Shared)
    [IO.File]::WriteAllText((Join-Path $dir 'custom-layouts.json'), $RS_CUSTOM)
    Set-RsLog $dir (Get-RsStandardLog)
    $dir
}

function Remove-RsDir([string]$Dir) {
    try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# A 1920x1080 monitor with a 1920x1032 work area at DPI 96 for the given instance, enumeration number and EDID serial.
function New-RsMonitor([string]$Instance, [int]$Number, [string]$Serial) {
    New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        ('\\?\DISPLAY#' + $RS_ID + '#' + $Instance + '#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}'), $RS_ID, $Instance, $Serial, $Number, `
        0, 0, 1920, 1080, (New-TWorkArea 0 0 1920 1032)
}

# A resolver over the directory whose app-log lines are collected in $script:RsLines.
function New-RsResolver([string]$Dir) {
    $script:RsLines = New-Object 'System.Collections.Generic.List[string]'
    $sink = [Action[string]] { param($line) $script:RsLines.Add($line) }
    New-Object TerminalOrganizer.App.AppliedLayoutResolver -ArgumentList $Dir, $sink
}

function Get-RsSummary($Result) {
    $zones = 0
    if ($null -ne $Result.Zones) { $zones = $Result.Zones.Length }
    '{0}|{1}|{2}' -f $Result.Kind.ToString(), $Result.LayoutName, $zones
}

Describe 'SPEC-MON-011 AC-011 Same row identity under a matching hint; the fallback is order-dependent' {
    It 'ten calls with row-order rewrites and appended log lines all resolve FourTerms on the live row, with one decision line' {
        $dir = New-RsDir $false
        try {
            $mon = New-RsMonitor $RS_INST_4352 1 $RS_D2U
            $resolver = New-RsResolver $dir
            for ($i = 1; $i -le 10; $i++) {
                if ($i -eq 3) { Set-RsApplied $dir (New-RsAppliedJson $RS_REVERSE $false) }
                if ($i -eq 6) { Set-RsApplied $dir (New-RsAppliedJson $RS_SHUFFLE $false) }
                if ($i % 2 -eq 0) { Add-RsLogText $dir ($RS_TS + 'unrelated line ' + $i) }
                (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4'
            }
            $script:RsLines.Count | Should Be 1
            $script:RsLines[0].Contains('by LiveHint') | Should Be $true
            $script:RsLines[0].Contains('number 1 serial XPG0H42JBEHU') | Should Be $true
        }
        finally { Remove-RsDir $dir }
    }

    It 'with the Logs folder removed and the original order the call yields the 5-zone FiveTerms layout of the stale row (the defect, pinned in the App path)' {
        $dir = New-RsDir $false
        try {
            Remove-Item -LiteralPath (Join-Path $dir 'Logs') -Recurse -Force
            $resolver = New-RsResolver $dir
            (Get-RsSummary $resolver.Resolve((New-RsMonitor $RS_INST_4352 1 $RS_D2U), $RS_DESK1)) | Should BeExactly 'Supported|FiveTerms|5'
            $script:RsLines.Count | Should Be 1
            $script:RsLines[0].Contains('position 0 number 2 serial XPG0H42JBD2U') | Should Be $true
        }
        finally { Remove-RsDir $dir }
    }

    It 'with the Logs folder removed and the reverse order the same call yields the 4-zone FourTerms layout of the live row (the fallback depends on row order, as today)' {
        $dir = New-RsDir $false
        try {
            Remove-Item -LiteralPath (Join-Path $dir 'Logs') -Recurse -Force
            Set-RsApplied $dir (New-RsAppliedJson $RS_REVERSE $false)
            $resolver = New-RsResolver $dir
            (Get-RsSummary $resolver.Resolve((New-RsMonitor $RS_INST_4352 1 $RS_D2U), $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4'
            $script:RsLines[0].Contains('number 1 serial XPG0H42JBEHU') | Should Be $true
        }
        finally { Remove-RsDir $dir }
    }

    It 'an absent applied-layouts file is the unsupported no-applied-layout result with no decision line, as today' {
        $dir = New-RsDir $false
        try {
            Remove-Item -LiteralPath (Join-Path $dir 'applied-layouts.json') -Force
            $resolver = New-RsResolver $dir
            $r = $resolver.Resolve((New-RsMonitor $RS_INST_4352 1 $RS_D2U), $RS_DESK1)
            $r.Kind.ToString() | Should BeExactly 'Unsupported'
            $r.Reason.ToString() | Should BeExactly 'NoAppliedLayout'
            $script:RsLines.Count | Should Be 0
        }
        finally { Remove-RsDir $dir }
    }

    It 'a malformed applied-layouts file is the invalid malformed-json result with no decision line, as today' {
        $dir = New-RsDir $false
        try {
            Set-RsApplied $dir '{ not json'
            $resolver = New-RsResolver $dir
            $r = $resolver.Resolve((New-RsMonitor $RS_INST_4352 1 $RS_D2U), $RS_DESK1)
            $r.Kind.ToString() | Should BeExactly 'Invalid'
            $r.Reason.ToString() | Should BeExactly 'MalformedJson'
            $script:RsLines.Count | Should Be 0
        }
        finally { Remove-RsDir $dir }
    }

    It 'a lowercase ToString("B") desktop resolves the same row and keeps one decision line with the upper-case GUID' {
        $dir = New-RsDir $false
        try {
            $resolver = New-RsResolver $dir
            $mon = New-RsMonitor $RS_INST_4352 1 $RS_D2U
            (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4'
            (Get-RsSummary $resolver.Resolve($mon, ([Guid]$RS_DESK1).ToString('B'))) | Should BeExactly 'Supported|FourTerms|4'
            $script:RsLines.Count | Should Be 1
            $script:RsLines[0].Contains('desktop ' + $RS_DESK1 + ' by') | Should Be $true
        }
        finally { Remove-RsDir $dir }
    }
}

Describe 'SPEC-MON-011 AC-012 Fallback states and explicit line counts' {
    It 'five states over one resolver give the pinned reader codes, rules, rows and total line counts' {
        $dir = New-RsDir $false
        $lock = $null
        try {
            $mon = New-RsMonitor $RS_INST_4352 1 $RS_D2U
            $resolver = New-RsResolver $dir
            $logPath = Get-RsLogPath $dir

            # State 1: the directory as built.
            for ($i = 0; $i -lt 3; $i++) { (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4' }
            $script:RsLines.Count | Should Be 1
            $script:RsLines[0].Contains('by LiveHint') | Should Be $true

            # State 2: the whole Logs folder deleted.
            Remove-Item -LiteralPath (Join-Path $dir 'Logs') -Recurse -Force
            for ($i = 0; $i -lt 3; $i++) { (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FiveTerms|5' }
            $script:RsLines.Count | Should Be 2
            $script:RsLines[1].Contains('NoLogsFolder') | Should Be $true
            $script:RsLines[1].Contains('by DocumentOrder') | Should Be $true
            $script:RsLines[1].Contains('number 2 serial XPG0H42JBD2U') | Should Be $true

            # State 3: the log recreated as the only file, held open with share none.
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $logPath))
            $lock = [IO.File]::Open($logPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            for ($i = 0; $i -lt 3; $i++) { (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FiveTerms|5' }
            $script:RsLines.Count | Should Be 2

            # State 4: the lock released and the file overwritten with binary noise.
            $lock.Dispose()
            $lock = $null
            $noise = New-Object byte[] 4096
            for ($i = 0; $i -lt $noise.Length; $i++) { $noise[$i] = [byte](($i * 37 + 11) % 256) }
            [IO.File]::WriteAllBytes($logPath, $noise)
            for ($i = 0; $i -lt 3; $i++) { (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FiveTerms|5' }
            $script:RsLines.Count | Should Be 2

            # State 5: the file overwritten with the valid log of the Conventions.
            Set-RsLog $dir (Get-RsStandardLog)
            for ($i = 0; $i -lt 3; $i++) { (Get-RsSummary $resolver.Resolve($mon, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4' }
            $script:RsLines.Count | Should Be 3
            $script:RsLines[2].Contains('by LiveHint') | Should Be $true
        }
        finally {
            if ($null -ne $lock) { $lock.Dispose() }
            Remove-RsDir $dir
        }
    }
}

Describe 'SPEC-MON-011 AC-013 Decision-line deduplication, null row and fields' {
    It 'steps a to f over SF-STALE-SHARED give the pinned total line counts and line texts' {
        $dir = New-RsDir $true
        try {
            $mon4352 = New-RsMonitor $RS_INST_4352 1 $RS_D2U
            $mon4358 = New-RsMonitor $RS_INST_4358 2 $RS_EHU
            $monNone = New-RsMonitor $RS_INST_NONE 3 'XPG0H42JBZZZ'
            $resolver = New-RsResolver $dir

            # a: 20 calls, nothing changed.
            for ($i = 0; $i -lt 20; $i++) { (Get-RsSummary $resolver.Resolve($mon4352, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4' }
            $script:RsLines.Count | Should Be 1
            $script:RsLines[0] | Should BeExactly ('applied row: monitor 1 desktop ' + $RS_DESK1 + ' by LiveHint (hint 1, XPG0H42JBEHU, log_2026-10-23.log) position 2 number 1 serial XPG0H42JBEHU layout ' + $RS_FOUR)

            # b: reverse row order and five unrelated log lines; the position changed, the identity did not.
            Set-RsApplied $dir (New-RsAppliedJson $RS_REVERSE $true)
            for ($i = 0; $i -lt 5; $i++) { Add-RsLogText $dir ($RS_TS + 'unrelated line ' + $i) }
            for ($i = 0; $i -lt 5; $i++) { (Get-RsSummary $resolver.Resolve($mon4352, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4' }
            $script:RsLines.Count | Should Be 1

            # c: original order again, no Logs folder; live and stale rows share a uuid, yet the line count rises.
            Set-RsApplied $dir (New-RsAppliedJson $RS_ORIGINAL $true)
            Remove-Item -LiteralPath (Join-Path $dir 'Logs') -Recurse -Force
            for ($i = 0; $i -lt 3; $i++) { (Get-RsSummary $resolver.Resolve($mon4352, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4' }
            $script:RsLines.Count | Should Be 2
            $script:RsLines[1] | Should BeExactly ('applied row: monitor 1 desktop ' + $RS_DESK1 + ' by DocumentOrder (no hint: NoLogsFolder) position 0 number 2 serial XPG0H42JBD2U layout ' + $RS_FOUR)

            # d: the log recreated, a different monitor stable key.
            Set-RsLog $dir (Get-RsStandardLog)
            (Get-RsSummary $resolver.Resolve($mon4358, $RS_DESK1)) | Should BeExactly 'Supported|FourTerms|4'
            $script:RsLines.Count | Should Be 3
            $script:RsLines[2] | Should BeExactly ('applied row: monitor 2 desktop ' + $RS_DESK1 + ' by LiveHint (hint 2, XPG0H42JBEHU, log_2026-10-23.log) position 1 number 2 serial XPG0H42JBEHU layout ' + $RS_FOUR)

            # e: ID-NONE, no UID9999 line in the log: no instance-exact row, chosen row none.
            for ($i = 0; $i -lt 5; $i++) {
                $r = $resolver.Resolve($monNone, $RS_DESK1)
                $r.Kind.ToString() | Should BeExactly 'Unsupported'
                $r.Reason.ToString() | Should BeExactly 'NoAppliedLayout'
            }
            $script:RsLines.Count | Should Be 4
            $script:RsLines[3] | Should BeExactly ('applied row: monitor 3 desktop ' + $RS_DESK1 + ' by DocumentOrder (no hint: NoMatchingLine) row none')

            # f: a UID9999 line with (3, S9) appended: a hint, no row carries it; the rule changes the key.
            Add-RsLogText $dir (New-RsLogLine $RS_INST_NONE '3' 'S9' $RS_DESK1)
            for ($i = 0; $i -lt 5; $i++) { $resolver.Resolve($monNone, $RS_DESK1).Kind.ToString() | Should BeExactly 'Unsupported' }
            $script:RsLines.Count | Should Be 5
            $script:RsLines[4] | Should BeExactly ('applied row: monitor 3 desktop ' + $RS_DESK1 + ' by HintUnmatched (hint 3, S9, log_2026-10-23.log) row none')
        }
        finally { Remove-RsDir $dir }
    }
}

Describe 'SPEC-MON-011 composition and tool wiring' {
    $trayText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
    $resolverPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AppliedLayoutResolver.cs'

    It 'TrayContext builds the layout resolution from AppliedLayoutResolver and no longer selects rows itself' {
        $trayText.Contains('new AppliedLayoutResolver(') | Should Be $true
        $trayText.Contains('AppliedEntrySelector') | Should Be $false
        $trayText.Contains('FancyZonesJsonReader') | Should Be $false
    }

    It 'Composition.Build keeps exactly the two parameters (LogSink, LabelRegistry)' {
        $compositionType = [TerminalOrganizer.App.TrayMenuBuilder].Assembly.GetType('TerminalOrganizer.App.Composition', $true)
        $build = $compositionType.GetMethod('Build', [Reflection.BindingFlags]'NonPublic,Static')
        $names = @($build.GetParameters() | ForEach-Object { $_.ParameterType.Name })
        ($names -join ',') | Should BeExactly 'LogSink,LabelRegistry'
    }

    It 'the new resolver file exists, holds no FileSystemWatcher, Timer or Stopwatch and no AskUserQuestion' {
        Test-Path $resolverPath | Should Be $true
        $text = [IO.File]::ReadAllText($resolverPath)
        ($text -match 'FileSystemWatcher|Timer|Stopwatch|AskUserQuestion') | Should Be $false
    }

    It 'organize-once.ps1 -SelfTest exits 0, and the tool uses the resolver with no closure copy of its own' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $tool = Join-Path $repoRoot 'tools\organize-once.ps1'
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $tool -SelfTest
        $LASTEXITCODE | Should Be 0
        (@($out | Where-Object { $_ -like 'FAIL: *' }).Count) | Should Be 0
        $text = [IO.File]::ReadAllText($tool)
        $text.Contains('AppliedLayoutResolver') | Should Be $true
        $text.Contains('AppliedEntrySelector') | Should Be $false
        ($text -match 'ReadAllText\(\s*\$appliedPath') | Should Be $false
        ($text -match '\$appliedPath') | Should Be $false
        ($text -match '[^\x00-\x7F]') | Should Be $false
    }

    It 'organize-dryrun.ps1 declares -FancyZonesLogs, decides rows through Decide and prints the rule line; its -SelfTest asserts row decided by: LiveHint' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $tool = Join-Path $repoRoot 'tools\organize-dryrun.ps1'
        $text = [IO.File]::ReadAllText($tool)
        ($text -match '\[string\]\$FancyZonesLogs') | Should Be $true
        $text.Contains('AppliedEntrySelector]::Decide(') | Should Be $true
        $text.Contains('row decided by:') | Should Be $true
        $text.Contains('AppliedEntrySelector]::Select(') | Should Be $false
        ($text -match '[^\x00-\x7F]') | Should Be $false
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $tool -SelfTest
        $LASTEXITCODE | Should Be 0
        (@($out | Where-Object { $_ -like 'FAIL: *' }).Count) | Should Be 0
        (@($out | Where-Object { $_ -eq 'PASS: mon011/row-decided-by' }).Count) | Should Be 1
        (@($out | Where-Object { $_ -ceq 'row decided by: LiveHint' }).Count) | Should Be 1
    }
}

# --- SPEC-RULES-010 M3: menu-path rule-timeout logging and the first ReportRuleTimeouts test ---
# Expected values come from SPEC-RULES-010 acceptance.md and plan.md section J, never from the code under test.
# RuleDiagnosticLog is process-wide and has no reset: AC-008 owns the rule positions 41 to 43 and must run once per fresh process.

function New-R10Rules([int]$Fillers, [string[]]$Hostile) {
    $defs = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 1; $i -le $Fillers; $i++) {
        $defs.Add(@{ match = ('filler-' + $i + '*') })
    }
    foreach ($h in $Hostile) {
        $defs.Add(@{ match = $h })
    }
    [TerminalOrganizer.Core.Rules.RuleSetBuilder]::Build([object[]]$defs.ToArray(), $false)
}

function New-R10Snapshots($Rules, [int]$Count) {
    $title = ('a' * 30) + 'b'
    $acquired = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 1; $i -le $Count; $i++) {
        $acquired.Add((New-R9Acquired (900 + $i) ([string[]]@($title))))
    }
    , ([TerminalOrganizer.Core.Windows.WindowSnapshot[]]@(Get-R9Snapshots $acquired.ToArray() @() $Rules))
}

# Returns the text between the opening character that precedes $Start and its matching closing character.
function Get-R10Span([string]$Text, [int]$Start, [string]$Open, [string]$Close) {
    $depth = 1
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = [string]$Text[$i]
        if ($ch -ceq $Open) { $depth++ }
        elseif ($ch -ceq $Close) {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($Start, $i - $Start) }
        }
    }
    $null
}

# Returns the last top-level argument of an argument-list text.
function Get-R10LastArg([string]$Text) {
    $depth = 0
    $last = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = [string]$Text[$i]
        if ($ch -ceq '(' -or $ch -ceq '{' -or $ch -ceq '[') { $depth++ }
        elseif ($ch -ceq ')' -or $ch -ceq '}' -or $ch -ceq ']') { $depth-- }
        elseif ($ch -ceq ',' -and $depth -eq 0) { $last = $i + 1 }
    }
    $Text.Substring($last).Trim()
}

Describe 'SPEC-RULES-010 AC-008 ReportRuleTimeouts: first test, one line per rule position' {
    It 'skipped evaluations add no line; repeats and a second compose add none; a new position adds exactly one; null inputs are safe' {
        $composition = [TerminalOrganizer.App.AppSettings].Assembly.GetType('TerminalOrganizer.App.Composition')
        $report = $composition.GetMethod('ReportRuleTimeouts', [Reflection.BindingFlags]'NonPublic,Static')
        $report | Should Not BeNullOrEmpty
        $script:R10Lines = New-Object 'System.Collections.Generic.List[string]'
        $sink = [Action[string]] { param($m) $script:R10Lines.Add($m) }

        $l1 = New-R10Rules 40 @('regex:^(a+)+$', 'regex:^(a+)+c$')
        $snaps = New-R10Snapshots $l1 3
        $diags = @($snaps | ForEach-Object { $_.RuleDiagnostics })
        $diags.Count | Should Be 6
        @($diags | Where-Object { $_.Position -eq 41 }).Count | Should Be 3
        @($diags | Where-Object { $_.Position -eq 42 }).Count | Should Be 3
        @($diags | Where-Object { $_.Reason -ceq 'regex timeout (skipped after repeated timeouts)' }).Count | Should Be 2

        [void]$report.Invoke($null, [object[]]@($snaps, $sink))
        $script:R10Lines.Count | Should Be 2
        $script:R10Lines[0] | Should BeExactly 'title rule 41 timed out; treated as no match'
        $script:R10Lines[1] | Should BeExactly 'title rule 42 timed out; treated as no match'

        foreach ($repeat in 1..3) {
            [void]$report.Invoke($null, [object[]]@($snaps, $sink))
        }
        $script:R10Lines.Count | Should Be 2

        $again = New-R10Snapshots $l1 1
        @($again | ForEach-Object { $_.RuleDiagnostics }).Count | Should Be 2
        [void]$report.Invoke($null, [object[]]@($again, $sink))
        $script:R10Lines.Count | Should Be 2

        $l2 = New-R10Rules 42 @('regex:^(a+)+$')
        $third = New-R10Snapshots $l2 1
        @($third | ForEach-Object { $_.RuleDiagnostics }).Count | Should Be 1
        [void]$report.Invoke($null, [object[]]@($third, $sink))
        $script:R10Lines.Count | Should Be 3
        $script:R10Lines[2] | Should BeExactly 'title rule 43 timed out; treated as no match'
    }

    It 'a null sink, a null snapshot array and a null snapshot element write no line and throw nothing' {
        $composition = [TerminalOrganizer.App.AppSettings].Assembly.GetType('TerminalOrganizer.App.Composition')
        $report = $composition.GetMethod('ReportRuleTimeouts', [Reflection.BindingFlags]'NonPublic,Static')
        $script:R10Lines = New-Object 'System.Collections.Generic.List[string]'
        $sink = [Action[string]] { param($m) $script:R10Lines.Add($m) }
        $withNull = [Array]::CreateInstance([TerminalOrganizer.Core.Windows.WindowSnapshot], 1)
        $snaps = New-R10Snapshots (New-R10Rules 40 @('regex:^(a+)+$')) 1
        $caught = $null
        try {
            [void]$report.Invoke($null, [object[]]@($snaps, $null))
            [void]$report.Invoke($null, [object[]]@($null, $sink))
            [void]$report.Invoke($null, [object[]]@($withNull, $sink))
        }
        catch {
            $caught = $_
        }
        $caught | Should BeNullOrEmpty
        $script:R10Lines.Count | Should Be 0
    }
}

Describe 'SPEC-RULES-010 AC-009 the menu read logs rule timeouts and nothing else' {
    $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))

    It 'ReadWindowsForMenu has exactly two parameters: a LabelRegistry and an Action of string' {
        $composition = [TerminalOrganizer.App.AppSettings].Assembly.GetType('TerminalOrganizer.App.Composition')
        $method = $composition.GetMethod('ReadWindowsForMenu', [Reflection.BindingFlags]'NonPublic,Static')
        $method | Should Not BeNullOrEmpty
        $params = $method.GetParameters()
        $params.Count | Should Be 2
        $params[0].ParameterType.Name | Should BeExactly 'LabelRegistry'
        ($params[1].ParameterType -eq [Action[string]]) | Should Be $true
    }

    It 'the body reports through ReportRuleTimeouts with its second parameter, and the Discover trace argument stays the literal null' {
        $decl = [regex]::Match($text, 'DiscoveredWindows\s+ReadWindowsForMenu\s*\(\s*LabelRegistry\s+\w+\s*,\s*Action<string>\s+(\w+)\s*\)\s*\{')
        $decl.Success | Should Be $true
        $sinkName = $decl.Groups[1].Value
        $body = Get-R10Span $text ($decl.Index + $decl.Length) '{' '}'
        $body | Should Not BeNullOrEmpty
        ($body -match ('ReportRuleTimeouts\([^;]*\b' + $sinkName + '\b')) | Should Be $true
        $discover = $body.IndexOf('Discover(', [StringComparison]::Ordinal)
        ($discover -ge 0) | Should Be $true
        $discoverArgs = Get-R10Span $body ($discover + 'Discover('.Length) '(' ')'
        $discoverArgs | Should Not BeNullOrEmpty
        (Get-R10LastArg $discoverArgs) | Should BeExactly 'null'
    }

    It 'each of the three call sites passes a second argument that is not null and reaches log.Append' {
        $sites = [regex]::Matches($text, 'ReadWindowsForMenu\(ports\.Controller\.Labels,')
        $sites.Count | Should Be 3
        foreach ($site in $sites) {
            $span = (Get-R10Span $text ($site.Index + $site.Length) '(' ')').Trim()
            $span | Should Not BeNullOrEmpty
            ($span -match '^null\b') | Should Be $false
            $direct = $span -match 'log\.Append\b'
            if (-not $direct) {
                ($span -match '^[A-Za-z_][A-Za-z0-9_]*$') | Should Be $true
                $shellStart = $text.IndexOf('class TrayShell', [StringComparison]::Ordinal)
                $helper = [regex]::Match($text.Substring($shellStart), '\b' + $span + '\s*\([^)]*\)\s*\{')
                $helper.Success | Should Be $true
                $helperBody = Get-R10Span $text ($shellStart + $helper.Index + $helper.Length) '{' '}'
                ($helperBody -match 'log\.Append\b') | Should Be $true
            }
        }
    }

    It 'the organize run and the world capture still pass the app log as the discovery trace' {
        $kept = [regex]::Matches($text, 'ports\.RunToken,\s*delegate\(string message\)\s*\{\s*log\.Append\(message\);\s*\}\)')
        $kept.Count | Should BeGreaterThan 1
    }
}
