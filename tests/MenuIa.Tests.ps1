# SPEC-TRAY-015 M2 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-006 and spec.md REQ-IA-001 / AM-3,
# hand-derived (the AC-006 given state: busy false, one monitor, enable true, policy
# mixed, limit 10, topmost false; radio labels/checked matrices follow the
# overflow-policy exactly-one-checked pattern), never from the code under test.
# This file is the only M2 test change: every existing suite stays unedited
# (AC-005). The WinForms layer (sub-submenu rendering, live marker moves) is manual
# verification per NFR-5 — the M2 rows in docs/manual-test-checklist.md.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
$script:IaAppAsm = [TerminalOrganizer.App.SettingsStore].Assembly

# --- fixtures ---

# The AC-002 carry base (the MenuStayOpen shape): all four attention values set
# (enable false, policy notifications, limit 5, topmost true) plus unrelated fields.
$script:IaCarryBase = '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\ia\\log.txt","managerWindowName":"X","mergeEnabled":true,"overflowPolicy":"Stack","schemaVersion":3,"attentionOverlay":false,"attentionEventPolicy":"notifications","attentionStopBlinkLimit":5,"attentionOverlayTopmost":true}'

function New-IaSettingsScratch([string]$Content) {
    $dir = Join-Path $here ('scratch-ia-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    [IO.File]::WriteAllText($path, $Content)
    return $path
}

function Get-IaShellMethod([string]$Name) {
    $shell = $script:IaAppAsm.GetType('TerminalOrganizer.App.TrayShell', $true)
    $shell.GetMethod($Name, [Reflection.BindingFlags]'NonPublic,Static')
}

function Read-IaAttention($Path) {
    $s = ([TerminalOrganizer.App.SettingsStore]::new($Path)).Load()
    return @{ Enable = $s.AttentionOverlay; Policy = $s.AttentionEventPolicy
        Limit = $s.AttentionStopBlinkLimit; Topmost = $s.AttentionOverlayTopmost }
}

function New-IaWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, 96
}

# The AC-006 given state plus era switches. Default = the M2 radio era (the
# 15-argument SPEC-TRAY-015 M2 constructor: the options bundle plus the
# radio-submenu era flag).
function New-IaMenuState {
    param([bool]$Busy, [bool]$Enable, [string]$Policy, [int]$Limit, [bool]$Topmost,
        [switch]$Tray014Era, [switch]$Tray013Era, [switch]$PreAttention)
    $monitors = @(New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        'PCI\VEN_00&DEV_0M', 'MON-1', '0', 'SN-1', 1, 0, 0, 1920, 1152, (New-IaWorkArea 0 0 1920 1152))
    $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
        ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
    $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
    if ($PreAttention) {
        # The pre-attention era is the 9-argument constructor (no attention surface).
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask)
    }
    if ($Tray013Era) {
        # The SPEC-TRAY-013-era constructor renders the FLAT checkable root row.
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null, $Enable
    }
    if ($Tray014Era) {
        # The SPEC-TRAY-014-era constructor renders the pinned four-item cycle submenu.
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null,
            $Enable, $Policy, $Limit, $Topmost
    }
    New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
        $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null,
        $Enable, $Policy, $Limit, $Topmost, $true
}

# The one attention root of a built state (the M2 era renders exactly one).
function Get-IaAttentionRoot($State) {
    $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($State)
    return @(@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' }))[0]
}

# The AC-006 radio shape of a built M2-era state: the 4 attention children and the
# two radio groups (policy rows then blink rows, in pinned order).
function Get-IaRadioShape($State) {
    $root = Get-IaAttentionRoot $State
    $children = @($root.Children)
    $policyRows = @($children[1].Children)
    $blinkRows = @($children[2].Children)
    return @{ Root = $root; Children = $children; PolicyRows = $policyRows; BlinkRows = $blinkRows }
}

# Derivation probe. A bare $null bound to a [string] parameter arrives as ""
# (PowerShell string conversion). The derivation treats null AND empty alike as the
# legacy cycle-row request (a radio value is never empty), but this probe exercises
# the real-null path explicitly through [NullString]::Value, verified to deliver a
# genuine null on the direct static call (tray015-M2-nullprobe diagnostic).
function Invoke-IaDerive([string]$Kind, $Value, $State) {
    $kindEnum = [TerminalOrganizer.App.TrayMenuEntryKind]::Parse([TerminalOrganizer.App.TrayMenuEntryKind], $Kind)
    if ($null -eq $Value) {
        return [TerminalOrganizer.App.TrayMenuBuilder]::DeriveSettingsEntry($kindEnum, [NullString]::Value, $State)
    }
    [TerminalOrganizer.App.TrayMenuBuilder]::DeriveSettingsEntry($kindEnum, $Value, $State)
}

# AC-003 convergence in the M2 era: the derivation output equals the fresh-build row
# (label, checked, enabled, value). Null values compare through an explicit bool.
function Compare-IaEntries($Derived, $Built) {
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

# AC-004-precedent source guards: the M2-touched sources, read once.
$script:IaCtxPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'
$script:IaBuilderPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayMenuBuilder.cs'
$script:IaCtx = [IO.File]::ReadAllText($script:IaCtxPath)
$script:IaCtxLines = [IO.File]::ReadAllLines($script:IaCtxPath)
$script:IaBuilder = [IO.File]::ReadAllText($script:IaBuilderPath)
$script:IaBuilderLines = [IO.File]::ReadAllLines($script:IaBuilderPath)

function Get-IaMethodBody([string]$Name) {
    $marker = 'void ' + $Name + '('
    $start = $script:IaCtx.IndexOf($marker)
    if ($start -lt 0) { return $null }
    $end = $script:IaCtx.IndexOf("`n        }", $start)
    if ($end -lt 0) { return $null }
    return $script:IaCtx.Substring($start, $end - $start)
}

Describe 'AC-006 radio presentations (REQ-IA-001; elected at Decision Point 1)' {
    It 'the M2-era attention root renders once, labeled "Attention overlay", enabled' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        ($null -ne $shape.Root) | Should Be $true
        $shape.Root.Label | Should BeExactly 'Attention overlay'
        $shape.Root.Enabled | Should Be $true
    }

    It 'the M2-era root order is unchanged: the attention root keeps its pinned slot between Overflow and Labels' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-IaMenuState $false $true 'mixed' 10 $false))
        ($entries | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'Status,Separator,OrganizeUnderCursor,Separator,OrganizeMonitorRoot,Separator,ManagerRoot,Separator,OverflowRoot,Separator,AttentionRoot,Separator,LabelsAndPrioritiesRoot,Separator,LastResult,OpenLog,Settings,Version,Exit'
    }

    It 'the attention children become Enabled, the Event policy sub-submenu, the Stop blinks sub-submenu, Always on top' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        $shape.Children.Count | Should Be 4
        ($shape.Children | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'AttentionEnabled,AttentionRoot,AttentionRoot,AttentionTopmost'
    }

    It 'the four attention children keep their labels: Enabled / Event policy / Stop blinks / Always on top' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        ($shape.Children | ForEach-Object { $_.Label }) -join ',' |
            Should BeExactly 'Enabled,Event policy,Stop blinks,Always on top'
    }

    It 'the two sub-submenu roots navigate only: enabled, unchecked, no Value payload of their own' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        foreach ($subRoot in @($shape.Children[1], $shape.Children[2])) {
            $subRoot.Enabled | Should Be $true
            $subRoot.Checked | Should Be $false
            ($null -eq $subRoot.Value) | Should Be $true
        }
    }

    It 'the Event policy radio rows render Mixed / All / Notifications only with the policy tokens as Values' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        $shape.PolicyRows.Count | Should Be 3
        ($shape.PolicyRows | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'AttentionEventPolicy,AttentionEventPolicy,AttentionEventPolicy'
        ($shape.PolicyRows | ForEach-Object { $_.Label }) -join ',' |
            Should BeExactly 'Mixed,All,Notifications only'
        ($shape.PolicyRows | ForEach-Object { $_.Value }) -join ',' |
            Should BeExactly 'mixed,all,notifications'
        foreach ($row in $shape.PolicyRows) { $row.Enabled | Should Be $true }
    }

    It 'exactly-one-checked: policy mixed checks Mixed only (the AC-006 given state)' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        ($shape.PolicyRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'True,False,False'
        @($shape.PolicyRows | Where-Object { $_.Checked }).Count | Should Be 1
    }

    It 'exactly-one-checked: policy all checks All only' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'all' 10 $false)
        ($shape.PolicyRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'False,True,False'
        @($shape.PolicyRows | Where-Object { $_.Checked }).Count | Should Be 1
    }

    It 'exactly-one-checked: policy notifications checks Notifications only' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'notifications' 10 $false)
        ($shape.PolicyRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'False,False,True'
        @($shape.PolicyRows | Where-Object { $_.Checked }).Count | Should Be 1
    }

    # NOTE (fixture scope): a null-policy row is deliberately absent — PowerShell
    # cannot deliver a real null string through New-Object -ArgumentList ($null binds
    # as ""; [NullString]::Value arrives as its literal text — verified by the
    # tray015-M2-nullprobe diagnostic), and the shell never constructs a state with a
    # null policy (SettingsStore.Load normalizes first). The M2 constructor chains the
    # SPEC-TRAY-014 options constructor, so the null-tolerant normalization is
    # inherited by construction; the era-flag row below pins the chain.

    It 'the checked policy row always carries the state policy as its Value' {
        foreach ($policy in @('mixed', 'all', 'notifications')) {
            $shape = Get-IaRadioShape (New-IaMenuState $false $true $policy 10 $false)
            $checked = @($shape.PolicyRows | Where-Object { $_.Checked })[0]
            $checked.Value | Should BeExactly $policy
        }
    }

    It 'the Stop blinks radio rows render 5 / 10 / 20 with the values as Values' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        $shape.BlinkRows.Count | Should Be 3
        ($shape.BlinkRows | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'AttentionStopBlinks,AttentionStopBlinks,AttentionStopBlinks'
        ($shape.BlinkRows | ForEach-Object { $_.Label }) -join ',' | Should BeExactly '5,10,20'
        ($shape.BlinkRows | ForEach-Object { $_.Value }) -join ',' | Should BeExactly '5,10,20'
        foreach ($row in $shape.BlinkRows) { $row.Enabled | Should Be $true }
    }

    It 'exactly-one-checked: limit 10 checks the 10 row only (the AC-006 given state)' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $false)
        ($shape.BlinkRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'False,True,False'
        @($shape.BlinkRows | Where-Object { $_.Checked }).Count | Should Be 1
    }

    It 'exactly-one-checked: limit 5 checks the 5 row; limit 20 checks the 20 row' {
        $five = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 5 $false)
        ($five.BlinkRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'True,False,False'
        $twenty = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 20 $false)
        ($twenty.BlinkRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'False,False,True'
    }

    It 'the checked blink row always carries the state limit as its Value' {
        foreach ($limit in @(5, 10, 20)) {
            $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' $limit $false)
            $checked = @($shape.BlinkRows | Where-Object { $_.Checked })[0]
            $checked.Value | Should BeExactly "$limit"
        }
    }

    It 'a non-cycle file limit (7) checks no blink row: the shipped set renders only its own values' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 7 $false)
        ($shape.BlinkRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'False,False,False'
        ($shape.BlinkRows | ForEach-Object { $_.Label }) -join ',' | Should BeExactly '5,10,20'
    }

    It 'the Enabled check row keeps checked = the enable flag, for both flags' {
        foreach ($enable in @($true, $false)) {
            $shape = Get-IaRadioShape (New-IaMenuState $false $enable 'mixed' 10 $false)
            $shape.Children[0].Label | Should BeExactly 'Enabled'
            $shape.Children[0].Checked | Should Be $enable
            $shape.Children[0].Enabled | Should Be $true
        }
    }

    It 'the Always on top check row keeps checked = the topmost flag, for both flags' {
        foreach ($topmost in @($true, $false)) {
            $shape = Get-IaRadioShape (New-IaMenuState $false $true 'mixed' 10 $topmost)
            $shape.Children[3].Label | Should BeExactly 'Always on top'
            $shape.Children[3].Checked | Should Be $topmost
            $shape.Children[3].Enabled | Should Be $true
        }
    }

    It 'enable/topmost flips touch only their own check rows: the radio groups keep their markers' {
        $shape = Get-IaRadioShape (New-IaMenuState $false $false 'mixed' 10 $true)
        $shape.Children[0].Checked | Should Be $false
        $shape.Children[3].Checked | Should Be $true
        ($shape.PolicyRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'True,False,False'
        ($shape.BlinkRows | ForEach-Object { $_.Checked }) -join ',' | Should BeExactly 'False,True,False'
    }

    It 'busy true keeps every M2-era attention row enabled (children and radio grandchildren)' {
        $shape = Get-IaRadioShape (New-IaMenuState $true $true 'mixed' 10 $false)
        foreach ($row in $shape.Children) { $row.Enabled | Should Be $true }
        foreach ($row in ($shape.PolicyRows + $shape.BlinkRows)) { $row.Enabled | Should Be $true }
    }
}

Describe 'AC-006 era isolation (constructor-era scoping; the pinned suites stay unedited)' {
    It 'the SPEC-TRAY-014-era constructor still renders the pinned four-item cycle submenu' {
        $state = New-IaMenuState $false $true 'mixed' 10 $false -Tray014Era
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($state)
        $root = @(@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' }))[0]
        $children = @($root.Children)
        $children.Count | Should Be 4
        ($children | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'AttentionEnabled,AttentionEventPolicy,AttentionStopBlinks,AttentionTopmost'
        $children[1].Label | Should BeExactly 'Event policy: Mixed'
        $children[2].Label | Should BeExactly 'Stop blinks: 10'
    }

    It 'the TRAY-014-era cycle rows carry no children of their own (no radios leak into the old era)' {
        $state = New-IaMenuState $false $true 'all' 20 $false -Tray014Era
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($state)
        $children = @(@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' })[0].Children)
        $children[1].Label | Should BeExactly 'Event policy: All'
        $children[1].Checked | Should Be $false
        @($children[1].Children).Count | Should Be 0
        $children[2].Label | Should BeExactly 'Stop blinks: 20'
        @($children[2].Children).Count | Should Be 0
    }

    It 'the SPEC-TRAY-013-era constructor keeps the FLAT row; no attention root renders' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-IaMenuState $false $true 'mixed' 10 $false -Tray013Era))
        (@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionOverlay' }).Count) | Should Be 1
        (@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' }).Count) | Should Be 0
    }

    It 'a pre-attention constructor renders no attention entry at all' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-IaMenuState $false $true 'mixed' 10 $false -PreAttention))
        (@($entries | Where-Object { $_.Kind.ToString() -like 'Attention*' }).Count) | Should Be 0
    }

    It 'the era flag is true only on the M2 constructor; every earlier era stays false and the M2 state carries the options bundle' {
        $m2 = New-IaMenuState $false $true 'mixed' 10 $false
        $m2.HasAttentionRadioSubmenus | Should Be $true
        $m2.HasAttentionOptions | Should Be $true
        (New-IaMenuState $false $true 'mixed' 10 $false -Tray014Era).HasAttentionRadioSubmenus | Should Be $false
        (New-IaMenuState $false $true 'mixed' 10 $false -Tray014Era).HasAttentionOptions | Should Be $true
        (New-IaMenuState $false $true 'mixed' 10 $false -Tray013Era).HasAttentionRadioSubmenus | Should Be $false
        (New-IaMenuState $false $true 'mixed' 10 $false -PreAttention).HasAttentionRadioSubmenus | Should Be $false
    }

    It 'the pure policy cycle still advances per the pinned order (AM-3 amends the presentation, not the cycles)' {
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy('mixed') | Should BeExactly 'all'
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy('all') | Should BeExactly 'notifications'
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy('notifications') | Should BeExactly 'mixed'
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy($null) | Should BeExactly 'mixed'
    }

    It 'the pure blink cycle still advances per the pinned order; a non-cycle value enters at the start' {
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(5) | Should Be 10
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(10) | Should Be 20
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(20) | Should Be 5
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(7) | Should Be 5
    }
}

Describe 'AC-006 shared-derivation convergence (AC-003 in the new era: live == fresh-build by construction)' {
    It 'every Event policy radio row derives through DeriveSettingsEntry to the built row (given state mixed/10)' {
        $state = New-IaMenuState $false $true 'mixed' 10 $false
        $shape = Get-IaRadioShape $state
        foreach ($row in $shape.PolicyRows) {
            Compare-IaEntries (Invoke-IaDerive 'AttentionEventPolicy' $row.Value $state) $row
        }
    }

    It 'the policy derivation tracks the fresh build under all/20 and notifications/5 (the checked marker moves)' {
        foreach ($pair in @(@('all', 20), @('notifications', 5))) {
            $state = New-IaMenuState $false $true $pair[0] $pair[1] $false
            $shape = Get-IaRadioShape $state
            foreach ($row in $shape.PolicyRows) {
                Compare-IaEntries (Invoke-IaDerive 'AttentionEventPolicy' $row.Value $state) $row
            }
        }
    }

    It 'every Stop blinks radio row derives through DeriveSettingsEntry to the built row (given state mixed/10)' {
        $state = New-IaMenuState $false $true 'mixed' 10 $false
        $shape = Get-IaRadioShape $state
        foreach ($row in $shape.BlinkRows) {
            Compare-IaEntries (Invoke-IaDerive 'AttentionStopBlinks' $row.Value $state) $row
        }
    }

    It 'the blink derivation tracks the fresh build under all/20, notifications/5 and the non-cycle 7 (all unchecked converge)' {
        foreach ($limit in @(20, 5, 7)) {
            $state = New-IaMenuState $false $true 'all' $limit $false
            $shape = Get-IaRadioShape $state
            foreach ($row in $shape.BlinkRows) {
                Compare-IaEntries (Invoke-IaDerive 'AttentionStopBlinks' $row.Value $state) $row
            }
        }
    }

    It 'the value-null derivation still renders the cycle-row labels (the TRAY-014-era derivation is unchanged by M2)' {
        $state = New-IaMenuState $false $true 'all' 20 $false
        $policyCycle = Invoke-IaDerive 'AttentionEventPolicy' $null $state
        $policyCycle.Label | Should BeExactly 'Event policy: All'
        $policyCycle.Value | Should BeExactly 'all'
        $policyCycle.Checked | Should Be $false
        $blinkCycle = Invoke-IaDerive 'AttentionStopBlinks' $null $state
        $blinkCycle.Label | Should BeExactly 'Stop blinks: 20'
        $blinkCycle.Value | Should BeExactly '20'
        $blinkCycle.Checked | Should Be $false
    }

    It 'the radio derivation stays pure: null state returns null; an unknown radio value returns an unchecked row, never an exception' {
        { Invoke-IaDerive 'AttentionEventPolicy' 'all' $null } | Should Not Throw
        ($null -eq (Invoke-IaDerive 'AttentionEventPolicy' 'all' $null)) | Should Be $true
        $state = New-IaMenuState $false $true 'mixed' 10 $false
        { Invoke-IaDerive 'AttentionEventPolicy' 'bogus' $state } | Should Not Throw
        $bogus = Invoke-IaDerive 'AttentionEventPolicy' 'bogus' $state
        ($null -ne $bogus) | Should Be $true
        $bogus.Checked | Should Be $false
        $bogus.Value | Should BeExactly 'bogus'
    }
}

Describe 'AC-006 wiring and persistence guards (the M1 machinery ride-through)' {
    It 'the M2-era constructor carries its planned @MX:NOTE marker (NFR-3: the AM-3 radio-submenu presentation; root order unchanged)' {
        (@($script:IaBuilderLines | Where-Object {
            $_.Contains('@MX:NOTE') -and $_.Contains('M2-era constructor') }).Count) | Should Be 1
    }

    It 'the shell builds the M2 era: both menu-build state constructions pass the radio-era flag' {
        (@($script:IaCtxLines | Where-Object { $_.Contains('attentionRadioSubmenus: true') }).Count) | Should Be 2
    }

    It 'the policy click selects the row value directly: SaveAttentionEventPolicyTo, keep-open, no cycle advance, no rebuild' {
        $body = Get-IaMethodBody 'SelectAttentionEventPolicy'
        ($null -ne $body) | Should Be $true
        ($body.Contains('SaveAttentionEventPolicyTo')) | Should Be $true
        ($body.Contains('KeepMenuOpenWithSettingsUpdate')) | Should Be $true
        ($body.Contains('NextPolicy')) | Should Be $false
        ($body.Contains('RebuildMenu')) | Should Be $false
    }

    It 'the blinks click selects the row value directly: SaveAttentionStopBlinksTo, keep-open, no cycle advance, no rebuild' {
        $body = Get-IaMethodBody 'SelectAttentionStopBlinks'
        ($null -ne $body) | Should Be $true
        ($body.Contains('SaveAttentionStopBlinksTo')) | Should Be $true
        ($body.Contains('KeepMenuOpenWithSettingsUpdate')) | Should Be $true
        ($body.Contains('NextBlinkLimit')) | Should Be $false
        ($body.Contains('RebuildMenu')) | Should Be $false
    }

    It 'the pinned cycles have zero TrayContext call sites (they live on as pure functions only)' {
        (@($script:IaCtxLines | Where-Object { $_.Contains('NextPolicy') -or $_.Contains('NextBlinkLimit') }).Count) | Should Be 0
    }

    It 'M2 added no new settings-writing helper: exactly the three pre-existing store.Save sites remain' {
        ([regex]::Matches($script:IaCtx, 'store\.Save\(new AppSettings')).Count | Should Be 3
    }

    It 'no new settings key: AppSettings still carries exactly the 18 shipped properties, schema 3' {
        ([TerminalOrganizer.App.AppSettings].GetProperties().Count) | Should Be 18
        $path = New-IaSettingsScratch $script:IaCarryBase
        try {
            (([TerminalOrganizer.App.SettingsStore]::new($path)).Load()).SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the keep-open partition is unchanged by the radio shape: still 26 members, radio kinds keep-open, sub-roots dismiss' {
        $names = @([Enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind]))
        $names.Count | Should Be 26
        [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]::AttentionEventPolicy) | Should Be $true
        [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]::AttentionStopBlinks) | Should Be $true
        [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind([TerminalOrganizer.App.TrayMenuEntryKind]::AttentionRoot) | Should Be $false
    }

    It 'save boundary: every policy radio row Value persists through SaveAttentionEventPolicyTo with the other three values carried' {
        foreach ($policy in @('mixed', 'all', 'notifications')) {
            $path = New-IaSettingsScratch $script:IaCarryBase
            try {
                $store = [TerminalOrganizer.App.SettingsStore]::new($path)
                $null = (Get-IaShellMethod 'SaveAttentionEventPolicyTo').Invoke($null, @($store, $policy))
                $v = Read-IaAttention $path
                $v.Policy | Should BeExactly $policy
                $v.Enable | Should Be $false
                $v.Limit | Should Be 5
                $v.Topmost | Should Be $true
            }
            finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
        }
    }

    It 'save boundary: every blink radio row Value persists through SaveAttentionStopBlinksTo with the other three values carried' {
        foreach ($limit in @(5, 10, 20)) {
            $path = New-IaSettingsScratch $script:IaCarryBase
            try {
                $store = [TerminalOrganizer.App.SettingsStore]::new($path)
                $null = (Get-IaShellMethod 'SaveAttentionStopBlinksTo').Invoke($null, @($store, $limit))
                $v = Read-IaAttention $path
                $v.Limit | Should Be $limit
                $v.Enable | Should Be $false
                $v.Policy | Should BeExactly 'notifications'
                $v.Topmost | Should Be $true
            }
            finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
        }
    }
}
