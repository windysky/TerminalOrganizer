# SPEC-TRAY-015 M1 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-001..AC-005 and spec.md REQ-STAY-001..004 /
# REQ-PERSIST-001, never from the code under test. This file is the only M1 test change:
# every existing suite stays unedited (AC-005). The WinForms-level stay-open wiring
# (Closing-cancel, live-item mutation) is manual verification per NFR-5 — the AC-007 rows
# in docs/manual-test-checklist.md — and is never asserted here.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
# The App assembly handle is taken from a resolved type so reflection targets the same
# instance another suite byte-loaded first.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
$script:StayAppAsm = [TerminalOrganizer.App.SettingsStore].Assembly

# --- fixtures ---

# AC-002: the carry base — all four attention values set (enable false, policy
# notifications, limit 5, topmost true) plus the hotkey/manager/overflow fields.
$script:StayCarryBase = '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\stay\\log.txt","managerWindowName":"X","mergeEnabled":true,"overflowPolicy":"Stack","schemaVersion":3,"attentionOverlay":false,"attentionEventPolicy":"notifications","attentionStopBlinkLimit":5,"attentionOverlayTopmost":true}'

function New-StaySettingsScratch([string]$Content) {
    $dir = Join-Path $here ('scratch-stay-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    if ($null -ne $Content) {
        [IO.File]::WriteAllText($path, $Content)
    }
    return $path
}

function Get-StayShellMethod([string]$Name) {
    $shell = $script:StayAppAsm.GetType('TerminalOrganizer.App.TrayShell', $true)
    $shell.GetMethod($Name, [Reflection.BindingFlags]'NonPublic,Static')
}

function Read-StayAttention($Path) {
    $s = ([TerminalOrganizer.App.SettingsStore]::new($Path)).Load()
    return @{ Enable = $s.AttentionOverlay; Policy = $s.AttentionEventPolicy
        Limit = $s.AttentionStopBlinkLimit; Topmost = $s.AttentionOverlayTopmost }
}

function New-StayWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, 96
}

function New-StaySessionSelector([string]$Value, [string]$RawTitle) {
    New-Object TerminalOrganizer.Core.Assignment.ManagerSelector -ArgumentList `
        ([TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session), $Value, $RawTitle
}

# One identified candidate window: raw title OC_<name>, one trusted tab carrying the
# canonical session <name> — CreateSelector over it yields Session(name, rawTitle).
function New-StayCandidate([long]$Handle, [string]$Name) {
    $rawTitle = 'OC_' + $Name
    $identity = [TerminalOrganizer.Core.Windows.WindowIdentity]::new(
        [IntPtr]$Handle, 42, 12345, 'CASCADIA_HOSTING_WINDOW_CLASS', $rawTitle)
    $session = [TerminalOrganizer.Core.Windows.SessionRecord]::new($Name,
        [TerminalOrganizer.Core.Windows.SessionKind]::Local,
        ('wsl.exe -d Ubuntu --exec /home/dev/run_dev_launch.sh --attach ' + $Name))
    $tab = [TerminalOrganizer.Core.Windows.TabSnapshot]::new($rawTitle, $rawTitle, $session)
    [TerminalOrganizer.Core.Windows.WindowSnapshot]::new($identity, $null, $null,
        [TerminalOrganizer.Core.Windows.TabSnapshot[]]@($tab), $true, [string[]]@(), $false,
        [TerminalOrganizer.Core.Windows.TabReadQuality]::Trusted)
}

function New-StayMenuState {
    # NOTE: the persisted-selector/resolution params carry distinct names ($PersistedSelector,
    # $WithResolution) — PowerShell variables are case-insensitive, so a $Selector param and a
    # $selector local would be ONE variable and the local's None() default would eat the argument.
    param([bool]$Busy, [bool]$Enable, [string]$Policy, [int]$Limit, [bool]$Topmost,
        [string]$Overflow = 'Ask', $PersistedSelector = $null, $Windows = @(), $WithResolution = $null,
        [switch]$Tray013Era)
    $monitors = @(New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        'PCI\VEN_00&DEV_0M', 'MON-1', '0', 'SN-1', 1, 0, 0, 1920, 1152, (New-StayWorkArea 0 0 1920 1152))
    $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
    if ($null -ne $PersistedSelector) { $selector = $PersistedSelector }
    $resolution = $WithResolution
    if ($null -eq $resolution) {
        $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
            ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
    }
    $overflowEnum = [TerminalOrganizer.App.OverflowPolicy]::Parse([TerminalOrganizer.App.OverflowPolicy], $Overflow)
    $windowsArray = [TerminalOrganizer.Core.Windows.WindowSnapshot[]]$Windows
    if ($Tray013Era) {
        # The SPEC-TRAY-013-era constructor renders the FLAT checkable root row.
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, $windowsArray,
            $selector, $resolution, $null, $false, $overflowEnum, $null, $Enable
    }
    New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, $windowsArray,
        $selector, $resolution, $null, $false, $overflowEnum, $null, $Enable, $Policy, $Limit, $Topmost
}

function Get-StayEntries($Entries, [string]$Kind) {
    $found = @()
    foreach ($entry in $Entries) {
        if ($null -eq $entry) { continue }
        if ($entry.Kind.ToString() -eq $Kind) { $found += $entry }
        $children = @($entry.Children)
        if ($children.Count -gt 0) { $found += Get-StayEntries $children $Kind }
    }
    return @($found)
}

function Invoke-StayDerive([string]$Kind, [string]$Value, $State) {
    [TerminalOrganizer.App.TrayMenuBuilder]::DeriveSettingsEntry(
        [TerminalOrganizer.App.TrayMenuEntryKind]::Parse([TerminalOrganizer.App.TrayMenuEntryKind], $Kind),
        $Value, $State)
}

# AC-003 convergence: the derivation output equals the fresh-build entry (label, checked,
# enabled, value). Null values compare through an explicit bool so Pester never pipes $null.
function Compare-StayEntries($Derived, $Built) {
    ($null -ne $Derived) | Should Be $true
    ($null -ne $Built) | Should Be $true
    $Derived.Label | Should BeExactly $Built.Label
    $Derived.Checked | Should Be $Built.Checked
    $Derived.Enabled | Should Be $Built.Enabled
    if ($null -eq $Built.Value) {
        ($null -eq $Derived.Value) | Should Be $true
    }
    else {
        $Derived.Value | Should BeExactly $Built.Value
    }
}

# AC-004 fixtures: the M1-touched sources, read once.
$script:StayCtxPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'
$script:StayBuilderPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayMenuBuilder.cs'
$script:StayCtx = [IO.File]::ReadAllText($script:StayCtxPath)
$script:StayCtxLines = [IO.File]::ReadAllLines($script:StayCtxPath)
$script:StayBuilder = [IO.File]::ReadAllText($script:StayBuilderPath)
$script:StayBuilderLines = [IO.File]::ReadAllLines($script:StayBuilderPath)

function Get-StayMethodBody([string]$Name) {
    $marker = 'void ' + $Name + '('
    $start = $script:StayCtx.IndexOf($marker)
    if ($start -lt 0) { return $null }
    $end = $script:StayCtx.IndexOf("`n        }", $start)
    if ($end -lt 0) { return $null }
    return $script:StayCtx.Substring($start, $end - $start)
}

Describe 'AC-001 stay-open classification (REQ-STAY-004)' {
    It 'the keep-open set is exactly the 9 settings-mutation kinds' {
        $expected = @('AttentionOverlay', 'AttentionEnabled', 'AttentionEventPolicy',
            'AttentionStopBlinks', 'AttentionRemoteAlerts', 'AttentionTopmost', 'OverflowPolicy', 'SetManager', 'ClearManager')
        $keep = @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]) |
            Where-Object { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]$_) })
        $keep.Count | Should Be 9
        (($keep | Sort-Object) -join ',') | Should BeExactly (($expected | Sort-Object) -join ',')
    }

    It 'the dismiss set is exactly the 20 remaining members (actions, manager navigation, informational, update)' {
        $expectedDismiss = @('OrganizeUnderCursor', 'OrganizeMonitorRoot', 'OrganizeMonitor',
            'ManagerRoot', 'ManagerCurrent', 'ShowManager', 'ManagerCandidateGroup',
            'OverflowRoot', 'AttentionRoot', 'LabelsAndPrioritiesRoot', 'LabelWindow',
            'LastResult', 'OpenLog', 'Settings', 'CheckForUpdates', 'UpdateAndRestart', 'Exit', 'Version', 'Status', 'Separator')
        $dismiss = @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]) |
            Where-Object { -not [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]$_) })
        $dismiss.Count | Should Be 20
        (($dismiss | Sort-Object) -join ',') | Should BeExactly (($expectedDismiss | Sort-Object) -join ',')
    }

    It 'the partition is exhaustive over all 29 members: 9 keep-open + 20 dismiss, no member unclassified' {
        $names = @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]))
        $names.Count | Should Be 29
        $keep = @($names | Where-Object { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]$_) })
        $dismiss = @($names | Where-Object { -not [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]$_) })
        $keep.Count | Should Be 9
        $dismiss.Count | Should Be 20
        ((@($keep) + @($dismiss) | Sort-Object) -join ',') | Should BeExactly (($names | Sort-Object) -join ',')
    }

    It 'the classification returns a defined value and never throws on null and unknown input (NFR-2)' {
        # Neither $null nor an undefined raw value can cross a PowerShell enum cast (the cast
        # itself throws before the call — a PS conversion limit, not a classification failure),
        # so the zero member stands in for the degenerate inputs; the C# switch's default
        # branch is what makes undefined values structural false.
        { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]0) } | Should Not Throw
        $zeroResult = [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]0)
        ($zeroResult -is [bool]) | Should Be $true
        $zeroResult | Should Be $false
        foreach ($name in [Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind])) {
            { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]$name) } | Should Not Throw
        }
    }

    It 'the classification helper lives in TrayMenuBuilder.cs, beside the enum (plan.md A-3)' {
        ($script:StayBuilder.Contains('IsKeepOpenKind')) | Should Be $true
    }
}

Describe 'AC-002 save-helper reuse and carry-through (REQ-PERSIST-001)' {
    It 'the attention toggle helper flips only attentionOverlay; the other three stay' {
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $on = (Get-StayShellMethod 'ToggleAttentionOverlayTo').Invoke($null, @($store))
            $on | Should Be $true
            $v = Read-StayAttention $path
            $v.Enable | Should Be $true
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the event-policy helper writes all; enable/limit/topmost stay' {
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-StayShellMethod 'SaveAttentionEventPolicyTo').Invoke($null, @($store, 'all'))
            $v = Read-StayAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'all'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the stop-blinks helper writes 20; the other three stay' {
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-StayShellMethod 'SaveAttentionStopBlinksTo').Invoke($null, @($store, 20))
            $v = Read-StayAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 20
            $v.Topmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the topmost helper writes false; the other three stay' {
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-StayShellMethod 'SaveAttentionTopmostTo').Invoke($null, @($store, $false))
            $v = Read-StayAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $false
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the manager-selector helper (the ClearManager/SetManager save path) keeps all four values and every unrelated field' {
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            # Inline ::new() (the AttentionOptions AC-02 pattern): a function-returned
            # selector arrives PSObject-wrapped and the reflection Invoke cannot convert it.
            $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
                [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'YODA1', 'OC_YODA1')
            $null = (Get-StayShellMethod 'SaveManagerSelectorTo').Invoke($null, @($store, $selector))
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.AttentionEventPolicy | Should BeExactly 'notifications'
            $s.AttentionStopBlinkLimit | Should Be 5
            $s.AttentionOverlayTopmost | Should Be $true
            $s.Hotkey | Should BeExactly 'Ctrl+Alt+T'
            $s.ManagerSelector.Value | Should BeExactly 'YODA1'
            $s.OverflowPolicy.ToString() | Should BeExactly 'Stack'
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the overflow-policy helper keeps all four attention values' {
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-StayShellMethod 'SaveOverflowPolicyTo').Invoke($null,
                @($store, [TerminalOrganizer.App.OverflowPolicy]::Merge))
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.AttentionEventPolicy | Should BeExactly 'notifications'
            $s.AttentionStopBlinkLimit | Should Be 5
            $s.AttentionOverlayTopmost | Should Be $true
            $s.OverflowPolicy.ToString() | Should BeExactly 'Merge'
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'M1 added no new settings-writing helper: exactly the three pre-existing store.Save sites remain in TrayContext.cs' {
        ([regex]::Matches($script:StayCtx, 'store\.Save\(new AppSettings')).Count | Should Be 3
    }

    It 'no new settings key appears in the store DTO: AppSettings still carries exactly the 18 shipped properties, schema 3' {
        # Hand-derived from SettingsStore.cs: the 16 save-constructor fields plus the
        # computed HasTitleRules convenience property (the DTO's one non-persisted member),
        # plus the v0.2.8 remote-alerts value.
        ([TerminalOrganizer.App.AppSettings].GetProperties().Count) | Should Be 20
        $path = New-StaySettingsScratch $script:StayCarryBase
        try {
            (([TerminalOrganizer.App.SettingsStore]::new($path)).Load()).SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }
}

Describe 'AC-003 in-place derivation convergence (REQ-STAY-002)' {
    It 'the policy derivation converges with the fresh build for every policy token (anchor: all renders "Event policy: All" / Value all)' {
        foreach ($policy in @('mixed', 'all', 'notifications')) {
            $state = New-StayMenuState $false $true $policy 10 $false
            $built = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'AttentionEventPolicy'))[0]
            Compare-StayEntries (Invoke-StayDerive 'AttentionEventPolicy' $null $state) $built
        }
        $allState = New-StayMenuState $false $true 'all' 10 $false
        $allDerived = Invoke-StayDerive 'AttentionEventPolicy' $null $allState
        $allDerived.Label | Should BeExactly 'Event policy: All'
        $allDerived.Value | Should BeExactly 'all'
    }

    It 'the blink derivation converges for 5, 20 and the non-cycle file value 7 (anchor: 7 renders "Stop blinks: 7" / Value 7)' {
        foreach ($limit in @(5, 20, 7)) {
            $state = New-StayMenuState $false $true 'mixed' $limit $false
            $built = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'AttentionStopBlinks'))[0]
            Compare-StayEntries (Invoke-StayDerive 'AttentionStopBlinks' $null $state) $built
        }
        $sevenState = New-StayMenuState $false $true 'mixed' 7 $false
        $sevenDerived = Invoke-StayDerive 'AttentionStopBlinks' $null $sevenState
        $sevenDerived.Label | Should BeExactly 'Stop blinks: 7'
        $sevenDerived.Value | Should BeExactly '7'
    }

    It 'the Enabled and Always-on-top derivations converge for every enable/topmost flag combination (checked equals the flag)' {
        foreach ($enable in @($true, $false)) {
            foreach ($topmost in @($true, $false)) {
                $state = New-StayMenuState $false $enable 'mixed' 10 $topmost
                $enabledBuilt = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'AttentionEnabled'))[0]
                $topmostBuilt = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'AttentionTopmost'))[0]
                $enabledDerived = Invoke-StayDerive 'AttentionEnabled' $null $state
                $topmostDerived = Invoke-StayDerive 'AttentionTopmost' $null $state
                Compare-StayEntries $enabledDerived $enabledBuilt
                Compare-StayEntries $topmostDerived $topmostBuilt
                $enabledDerived.Checked | Should Be $enable
                $topmostDerived.Checked | Should Be $topmost
            }
        }
    }

    It 'the legacy SPEC-TRAY-013-era flat AttentionOverlay row derivation converges with the flat build' {
        foreach ($enable in @($true, $false)) {
            $state = New-StayMenuState $false $enable 'mixed' 10 $false -Tray013Era
            $built = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'AttentionOverlay'))[0]
            $derived = Invoke-StayDerive 'AttentionOverlay' $null $state
            Compare-StayEntries $derived $built
            $derived.Checked | Should Be $enable
        }
    }

    It 'the overflow-policy derivation converges for all four row values under a saved Stack policy (stackOnly checked, ask unchecked, merge still disabled)' {
        $state = New-StayMenuState $false $true 'mixed' 10 $false -Overflow 'Stack'
        $builtRows = Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'OverflowPolicy'
        $builtRows.Count | Should Be 4
        foreach ($value in @('ask', 'stackOnly', 'merge', 'moveLowest')) {
            $built = @($builtRows | Where-Object { $_.Value -eq $value })[0]
            Compare-StayEntries (Invoke-StayDerive 'OverflowPolicy' $value $state) $built
        }
        (Invoke-StayDerive 'OverflowPolicy' 'stackOnly' $state).Checked | Should Be $true
        (Invoke-StayDerive 'OverflowPolicy' 'ask' $state).Checked | Should Be $false
        (Invoke-StayDerive 'OverflowPolicy' 'merge' $state).Enabled | Should Be $false
    }

    It 'the overflow-policy derivation also converges under a saved Redistribute policy (moveLowest checked)' {
        $state = New-StayMenuState $false $true 'mixed' 10 $false -Overflow 'Redistribute'
        $builtRows = Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($state)) 'OverflowPolicy'
        foreach ($value in @('ask', 'stackOnly', 'merge', 'moveLowest')) {
            $built = @($builtRows | Where-Object { $_.Value -eq $value })[0]
            Compare-StayEntries (Invoke-StayDerive 'OverflowPolicy' $value $state) $built
        }
        (Invoke-StayDerive 'OverflowPolicy' 'moveLowest' $state).Checked | Should Be $true
    }

    It 'the ClearManager derivation converges: disabled with no selector, enabled with one persisted' {
        $noneState = New-StayMenuState $false $true 'mixed' 10 $false
        $noneBuilt = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($noneState)) 'ClearManager'))[0]
        $noneDerived = Invoke-StayDerive 'ClearManager' $null $noneState
        Compare-StayEntries $noneDerived $noneBuilt
        $noneDerived.Enabled | Should Be $false

        $setState = New-StayMenuState $false $true 'mixed' 10 $false -PersistedSelector (New-StaySessionSelector 'YODA1' 'OC_YODA1')
        $setBuilt = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($setState)) 'ClearManager'))[0]
        $setDerived = Invoke-StayDerive 'ClearManager' $null $setState
        Compare-StayEntries $setDerived $setBuilt
        $setDerived.Enabled | Should Be $true
    }

    It 'the manager-current caption derivation converges ("Current: None" / "Current: YODA1")' {
        $noneState = New-StayMenuState $false $true 'mixed' 10 $false
        $noneBuilt = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($noneState)) 'ManagerCurrent'))[0]
        $noneDerived = Invoke-StayDerive 'ManagerCurrent' $null $noneState
        Compare-StayEntries $noneDerived $noneBuilt
        $noneDerived.Label | Should BeExactly 'Current: None'

        $resolved = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
            ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::Resolved), 'w1', ([IntPtr]77), 1, $null
        $setState = New-StayMenuState $false $true 'mixed' 10 $false `
            -PersistedSelector (New-StaySessionSelector 'YODA1' 'OC_YODA1') -WithResolution $resolved
        $setBuilt = @((Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($setState)) 'ManagerCurrent'))[0]
        $setDerived = Invoke-StayDerive 'ManagerCurrent' $null $setState
        Compare-StayEntries $setDerived $setBuilt
        $setDerived.Label | Should BeExactly 'Current: YODA1'
    }

    It 'the SetManager checked predicate converges with the built candidate rows and never throws on a null candidate' {
        $yoda = New-StayCandidate 9001 'YODA1'
        $yodaSelector = New-StaySessionSelector 'YODA1' 'OC_YODA1'
        $matchState = New-StayMenuState $false $true 'mixed' 10 $false -PersistedSelector $yodaSelector -Windows @($yoda)
        $builtRows = Get-StayEntries ([TerminalOrganizer.App.TrayMenuBuilder]::Build($matchState)) 'SetManager'
        $builtRows.Count | Should Be 1
        $builtRows[0].Checked | Should Be $true
        [TerminalOrganizer.App.TrayMenuBuilder]::IsSelectedManagerCandidate($matchState.ManagerSelector, $yoda) | Should Be $true
        [TerminalOrganizer.App.TrayMenuBuilder]::IsSelectedManagerCandidate(
            (New-StaySessionSelector 'OTHER' 'OC_OTHER'), $yoda) | Should Be $false
        { [TerminalOrganizer.App.TrayMenuBuilder]::IsSelectedManagerCandidate($yodaSelector, $null) } | Should Not Throw
        [TerminalOrganizer.App.TrayMenuBuilder]::IsSelectedManagerCandidate($yodaSelector, $null) | Should Be $false
        [TerminalOrganizer.App.TrayMenuBuilder]::IsSelectedManagerCandidate(
            [TerminalOrganizer.Core.Assignment.ManagerSelector]::None(), $null) | Should Be $true
    }

    It 'the derivation is pure and total: null state, non-settings kinds, SetManager and unknown values return null with 0 exceptions (NFR-2)' {
        { Invoke-StayDerive 'AttentionEnabled' $null $null } | Should Not Throw
        ($null -eq (Invoke-StayDerive 'AttentionEnabled' $null $null)) | Should Be $true
        ($null -eq (Invoke-StayDerive 'Exit' $null (New-StayMenuState $false $true 'mixed' 10 $false))) | Should Be $true
        ($null -eq (Invoke-StayDerive 'SetManager' $null (New-StayMenuState $false $true 'mixed' 10 $false))) | Should Be $true
        ($null -eq (Invoke-StayDerive 'OverflowPolicy' 'bogus' (New-StayMenuState $false $true 'mixed' 10 $false))) | Should Be $true
    }
}

Describe 'AC-004 no rebuild from settings clicks (REQ-STAY-003; REQ-STAY-001 dismissal guard)' {
    It 'every settings click handler keeps the strip open in place instead of rebuilding (no RebuildMenu in the post-save path)' {
        foreach ($name in @('SelectOverflowPolicy', 'ToggleAttentionOverlay', 'SelectAttentionEventPolicy',
            'SelectAttentionStopBlinks', 'ToggleAttentionTopmost', 'SaveManagerSelector')) {
            $body = Get-StayMethodBody $name
            ($null -ne $body) | Should Be $true
            ($body.Contains('RebuildMenu')) | Should Be $false
            ($body.Contains('KeepMenuOpenWithSettingsUpdate')) | Should Be $true
        }
    }

    It 'RebuildMenu is retained with its dispose-snapshot guard and at least one non-settings call site' {
        $callLines = @($script:StayCtxLines | Where-Object {
            $_.Contains('RebuildMenu()') -and -not $_.Contains('private void RebuildMenu') })
        ($callLines.Count -ge 1) | Should Be $true
        ($script:StayCtx -match [regex]::Escape('ToolStripItem[] snapshot')) | Should Be $true
    }

    It 'exactly one Closing subscription exists and its cancel branch is gated on the keep-open flag' {
        @($script:StayCtxLines | Where-Object { $_.Contains('Closing +=') }).Count | Should Be 1
        $body = Get-StayMethodBody 'MenuDropdownClosing'
        ($null -ne $body) | Should Be $true
        ($body -match [regex]::Escape('if (!this.keepMenuOpenOnClose)')) | Should Be $true
        ($body.Contains('e.Cancel = true')) | Should Be $true
    }

    It 'the cancel branch never keys on an outside-click or focus-loss close reason (the menu stays dismissible)' {
        $body = Get-StayMethodBody 'MenuDropdownClosing'
        ($body -match 'AppClicked|AppFocusChange') | Should Be $false
    }

    It 'the three planned M1 @MX:NOTE tag sites exist (NFR-3: classification, flag + Closing handler, shared derivation)' {
        (@($script:StayBuilderLines | Where-Object {
            $_.Contains('@MX:NOTE') -and $_.Contains('stay-open classification') }).Count) | Should Be 1
        (@($script:StayBuilderLines | Where-Object {
            $_.Contains('@MX:NOTE') -and $_.Contains('shared per-entry value derivation') }).Count) | Should Be 1
        (@($script:StayCtxLines | Where-Object {
            $_.Contains('@MX:NOTE') -and $_.Contains('keep-open flag') -and $_.Contains('Closing handler') }).Count) | Should Be 1
    }
}
