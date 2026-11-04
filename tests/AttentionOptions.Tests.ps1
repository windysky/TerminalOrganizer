# SPEC-TRAY-014 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md and plan.md section J, never from the code under
# test. This file is the ONLY test change of this SPEC: tests/Attention.Tests.ps1 stays
# unedited (its D-6 guard rows are the regression net for the topmost reintroduction).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
# The App assembly handle is taken from a resolved type so reflection targets the same
# instance another suite byte-loaded first.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
$script:OptionsAppAsm = [TerminalOrganizer.App.SettingsStore].Assembly

# --- fixtures ---

# The AC-001 common v3 base (the TRAY-013 base carrying attentionOverlay FALSE so the
# carry-through of AC-002 is observable). The persisted overflow-policy text is the enum
# name the store round-trips ("Stack"; "stackOnly" is a menu-row id).
$script:OptsV3Base = '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\attn\\log.txt","managerWindowName":"X","mergeEnabled":true,"overflowPolicy":"Stack","schemaVersion":3,"attentionOverlay":false}'

# The AC-002 base: all four attention values set (enable false, policy notifications,
# limit 5, topmost true).
$script:OptsCarryBase = '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\attn\\log.txt","managerWindowName":"X","mergeEnabled":true,"overflowPolicy":"Stack","schemaVersion":3,"attentionOverlay":false,"attentionEventPolicy":"notifications","attentionStopBlinkLimit":5,"attentionOverlayTopmost":true}'

function New-OptionsSettingsScratch([string]$Content) {
    $dir = Join-Path $here ('scratch-options-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    if ($null -ne $Content) {
        [IO.File]::WriteAllText($path, $Content)
    }
    return $path
}

function Get-OptionsShellMethod([string]$Name) {
    $shell = $script:OptionsAppAsm.GetType('TerminalOrganizer.App.TrayShell', $true)
    $shell.GetMethod($Name, [Reflection.BindingFlags]'NonPublic,Static')
}

function Read-OptionsAttention($Path) {
    $s = ([TerminalOrganizer.App.SettingsStore]::new($Path)).Load()
    return @{ Enable = $s.AttentionOverlay; Policy = $s.AttentionEventPolicy
        Limit = $s.AttentionStopBlinkLimit; Topmost = $s.AttentionOverlayTopmost }
}

Describe 'AC-001 Settings keys: defaults, resolution, clamp (REQ-SET-001)' {
    It 'a file with no new keys loads mixed / 10 / false with schema 3' {
        $path = New-OptionsSettingsScratch $script:OptsV3Base
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionEventPolicy | Should BeExactly 'mixed'
            $s.AttentionStopBlinkLimit | Should Be 10
            $s.AttentionOverlayTopmost | Should Be $false
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'explicit all / 20 / true loads all / 20 / true' {
        $json = $script:OptsV3Base.TrimEnd('}') + ',"attentionEventPolicy":"all","attentionStopBlinkLimit":20,"attentionOverlayTopmost":true}'
        $path = New-OptionsSettingsScratch $json
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionEventPolicy | Should BeExactly 'all'
            $s.AttentionStopBlinkLimit | Should Be 20
            $s.AttentionOverlayTopmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'policy notifications loads notifications; policy null and unknown load mixed (per-key degrade)' {
        $notified = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionEventPolicy":"notifications"}')
        $nulled = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionEventPolicy":null}')
        $bogus = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionEventPolicy":"bogus"}')
        try {
            (([TerminalOrganizer.App.SettingsStore]::new($notified)).Load()).AttentionEventPolicy |
                Should BeExactly 'notifications'
            (([TerminalOrganizer.App.SettingsStore]::new($nulled)).Load()).AttentionEventPolicy |
                Should BeExactly 'mixed'
            (([TerminalOrganizer.App.SettingsStore]::new($bogus)).Load()).AttentionEventPolicy |
                Should BeExactly 'mixed'
        }
        finally {
            Remove-Item -Recurse -Force (Split-Path $notified) -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force (Split-Path $nulled) -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force (Split-Path $bogus) -ErrorAction SilentlyContinue
        }
    }

    It 'the blink limit clamps into 1..50: 0 and -3 load 1; 51 and 999 load 50' {
        $zero = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionStopBlinkLimit":0}')
        $negative = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionStopBlinkLimit":-3}')
        $over = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionStopBlinkLimit":51}')
        $far = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionStopBlinkLimit":999}')
        try {
            (([TerminalOrganizer.App.SettingsStore]::new($zero)).Load()).AttentionStopBlinkLimit | Should Be 1
            (([TerminalOrganizer.App.SettingsStore]::new($negative)).Load()).AttentionStopBlinkLimit | Should Be 1
            (([TerminalOrganizer.App.SettingsStore]::new($over)).Load()).AttentionStopBlinkLimit | Should Be 50
            (([TerminalOrganizer.App.SettingsStore]::new($far)).Load()).AttentionStopBlinkLimit | Should Be 50
        }
        finally {
            foreach ($p in @($zero, $negative, $over, $far)) {
                Remove-Item -Recurse -Force (Split-Path $p) -ErrorAction SilentlyContinue
            }
        }
    }

    It 'a legacy 3-field file (no attention keys) loads mixed / 10 / false with schema 3' {
        $path = New-OptionsSettingsScratch '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\attn\\log.txt","managerWindowName":"X"}'
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionEventPolicy | Should BeExactly 'mixed'
            $s.AttentionStopBlinkLimit | Should Be 10
            $s.AttentionOverlayTopmost | Should Be $false
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'a NON-INTEGER blink limit follows the whole-file tolerant degradation to the defaults' {
        $path = New-OptionsSettingsScratch ($script:OptsV3Base.TrimEnd('}') + ',"attentionStopBlinkLimit":"ten"}')
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionEventPolicy | Should BeExactly 'mixed'
            $s.AttentionStopBlinkLimit | Should Be 10
            $s.AttentionOverlayTopmost | Should Be $false
            $s.Hotkey | Should BeExactly 'Ctrl+Alt+O'
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the pure resolver maps the closed set and degrades null, empty and unknown to mixed' {
        [TerminalOrganizer.App.AttentionPolicyResolver]::Parse('mixed') | Should BeExactly 'mixed'
        [TerminalOrganizer.App.AttentionPolicyResolver]::Parse('all') | Should BeExactly 'all'
        [TerminalOrganizer.App.AttentionPolicyResolver]::Parse('notifications') | Should BeExactly 'notifications'
        [TerminalOrganizer.App.AttentionPolicyResolver]::Parse('bogus') | Should BeExactly 'mixed'
        [TerminalOrganizer.App.AttentionPolicyResolver]::Parse($null) | Should BeExactly 'mixed'
        [TerminalOrganizer.App.AttentionPolicyResolver]::Parse('') | Should BeExactly 'mixed'
    }

    It 'the pure clamp holds the 1..50 bounds on the boundary values' {
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(0) | Should Be 1
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(-3) | Should Be 1
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(1) | Should Be 1
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(10) | Should Be 10
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(50) | Should Be 50
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(51) | Should Be 50
        [TerminalOrganizer.App.SettingsStore]::ClampBlinkLimit(999) | Should Be 50
    }
}

Describe 'AC-002 Every save path carries all four attention values (REQ-SET-002)' {
    It 'the attention toggle helper flips only attentionOverlay; the other three stay' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $off = (Get-OptionsShellMethod 'ToggleAttentionOverlayTo').Invoke($null, @($store))
            $off | Should Be $true
            $v = Read-OptionsAttention $path
            $v.Enable | Should Be $true
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the event-policy helper writes all; enable/limit/topmost stay' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-OptionsShellMethod 'SaveAttentionEventPolicyTo').Invoke($null, @($store, 'all'))
            $v = Read-OptionsAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'all'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the stop-blinks helper writes 20; the other three stay' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-OptionsShellMethod 'SaveAttentionStopBlinksTo').Invoke($null, @($store, 20))
            $v = Read-OptionsAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 20
            $v.Topmost | Should Be $true
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the topmost helper writes false; the other three stay' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-OptionsShellMethod 'SaveAttentionTopmostTo').Invoke($null, @($store, $false))
            $v = Read-OptionsAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $false
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'the EXISTING manager-selector helper (an unrelated save) keeps all four values and every unrelated field' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
                [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'YODA1', 'OC_YODA1')
            $null = (Get-OptionsShellMethod 'SaveManagerSelectorTo').Invoke($null, @($store, $selector))
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

    It 'the EXISTING overflow-policy helper (an unrelated save) keeps all four values' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-OptionsShellMethod 'SaveOverflowPolicyTo').Invoke($null,
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

    It 'a rebuilt AppSettings changing only an unrelated field keeps all four attention values' {
        $path = New-OptionsSettingsScratch $script:OptsCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $current = $store.Load()
            $store.Save([TerminalOrganizer.App.AppSettings]::new(
                $current.Hotkey, $current.LogPath, $current.ManagerWindowName, $current.MergeEnabled,
                $current.FirstRunCompleted, $current.StartWithWindows,
                ([TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
                    [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'YODA1', 'OC_YODA1')),
                $current.PriorityOverrides, $current.SchemaVersion, $current.OverflowPolicy,
                $current.CrossMonitorRedistribution, $current.TitleRules, $current.AttentionOverlay,
                $current.AttentionEventPolicy, $current.AttentionStopBlinkLimit, $current.AttentionOverlayTopmost))
            $s = $store.Load()
            $s.AttentionOverlay | Should Be $false
            $s.AttentionEventPolicy | Should BeExactly 'notifications'
            $s.AttentionStopBlinkLimit | Should Be 5
            $s.AttentionOverlayTopmost | Should Be $true
            $s.ManagerSelector.Value | Should BeExactly 'YODA1'
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }
}

# --- AC-003 fixtures ---

function New-OptionsWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, 96
}

function New-OptionsMenuState([bool]$Busy, [bool]$Enable, [string]$Policy, [int]$Limit, [bool]$Topmost, [switch]$Tray013Era, [switch]$PreAttention) {
    $monitors = @(New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        'PCI\VEN_00&DEV_0M', 'MON-1', '0', 'SN-1', 1, 0, 0, 1920, 1152, (New-OptionsWorkArea 0 0 1920 1152))
    $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
        ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
    $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
    if ($PreAttention) {
        # The pre-attention eras are the 8/9-argument constructors (the 10-argument
        # SPEC-RULES-009 form renders the TRAY-013 flat row by the era-scoping rule).
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask)
    }
    if ($Tray013Era) {
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null, $Enable
    }
    return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
        $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null,
        $Enable, $Policy, $Limit, $Topmost
}

Describe 'AC-003 Tray submenu model and cycles (REQ-UI-001)' {
    It 'the options-era state renders one AttentionRoot between Overflow and Labels with four pinned children' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-OptionsMenuState $false $true 'mixed' 10 $false))
        $roots = @($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' })
        $roots.Count | Should Be 1
        $kinds = @($entries | ForEach-Object { $_.Kind.ToString() })
        $attentionIndex = [Array]::IndexOf($kinds, 'AttentionRoot')
        $overflowIndex = [Array]::IndexOf($kinds, 'OverflowRoot')
        $labelsIndex = [Array]::IndexOf($kinds, 'LabelsAndPrioritiesRoot')
        ($attentionIndex -gt $overflowIndex) | Should Be $true
        ($attentionIndex -lt $labelsIndex) | Should Be $true
        $children = @($roots[0].Children)
        $children.Count | Should Be 4
        ($children | ForEach-Object { $_.Kind.ToString() }) -join ',' |
            Should BeExactly 'AttentionEnabled,AttentionEventPolicy,AttentionStopBlinks,AttentionTopmost'
        $children[0].Label | Should BeExactly 'Enabled'
        $children[0].Checked | Should Be $true
        $children[1].Label | Should BeExactly 'Event policy: Mixed'
        $children[1].Checked | Should Be $false
        $children[1].Value | Should BeExactly 'mixed'
        $children[2].Label | Should BeExactly 'Stop blinks: 10'
        $children[2].Value | Should BeExactly '10'
        $children[3].Label | Should BeExactly 'Always on top'
        $children[3].Checked | Should Be $false
        foreach ($child in $children) { $child.Enabled | Should Be $true }
    }

    It 'notifications / 20 / topmost true / enable false render their current values' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-OptionsMenuState $false $false 'notifications' 20 $true))
        $children = @(@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' })[0].Children)
        $children[0].Checked | Should Be $false
        $children[1].Label | Should BeExactly 'Event policy: Notifications only'
        $children[1].Value | Should BeExactly 'notifications'
        $children[2].Label | Should BeExactly 'Stop blinks: 20'
        $children[2].Value | Should BeExactly '20'
        $children[3].Checked | Should Be $true
    }

    It 'a non-cycle limit from the file (7) renders raw with Value 7' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-OptionsMenuState $false $true 'mixed' 7 $false))
        $children = @(@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' })[0].Children)
        $children[2].Label | Should BeExactly 'Stop blinks: 7'
        $children[2].Value | Should BeExactly '7'
    }

    It 'the SPEC-TRAY-013-era constructor keeps the FLAT row; no root, no children' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-OptionsMenuState $false $true 'mixed' 10 $false -Tray013Era))
        (@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionOverlay' }).Count) | Should Be 1
        (@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' }).Count) | Should Be 0
        (@($entries | Where-Object { $_.Kind.ToString() -like 'Attention*' -and $_.Kind.ToString() -ne 'AttentionOverlay' }).Count) | Should Be 0
    }

    It 'a pre-attention constructor renders no attention entry at all' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-OptionsMenuState $false $true 'mixed' 10 $false -PreAttention))
        (@($entries | Where-Object { $_.Kind.ToString() -like 'Attention*' }).Count) | Should Be 0
    }

    It 'busy true keeps all four children enabled while the organize root disables' {
        $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build((New-OptionsMenuState $true $true 'mixed' 10 $false))
        $children = @(@($entries | Where-Object { $_.Kind.ToString() -eq 'AttentionRoot' })[0].Children)
        foreach ($child in $children) { $child.Enabled | Should Be $true }
        $organize = @($entries | Where-Object { $_.Kind.ToString() -eq 'OrganizeUnderCursor' })[0]
        $organize.Enabled | Should Be $false
    }

    It 'the pure policy cycle advances and wraps: mixed->all->notifications->mixed' {
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy('mixed') | Should BeExactly 'all'
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy('all') | Should BeExactly 'notifications'
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy('notifications') | Should BeExactly 'mixed'
    }

    It 'the pure blink cycle advances and wraps: 5->10->20->5; a non-cycle value enters at the start' {
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(5) | Should Be 10
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(10) | Should Be 20
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(20) | Should Be 5
        [TerminalOrganizer.App.TrayMenuBuilder]::NextBlinkLimit(7) | Should Be 5
    }

    It 'the pure cycles never throw on a null policy' {
        [TerminalOrganizer.App.TrayMenuBuilder]::NextPolicy($null) | Should BeExactly 'mixed'
    }
}

# --- AC-004 to AC-006 fixtures: the options controller rig ---

function New-OptionsTestSignal([string]$Event, [string]$Needle) {
    $signal = New-Object TerminalOrganizer.Core.Attention.AttentionSignal
    $signal.Version = 1
    $signal.Event = $Event
    $signal.Needle = $Needle
    return $signal
}

function New-OptionsTestPollResult($Accepted = @()) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]$Accepted), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]@())
}

function New-OptionsCandidate([long]$Handle, [string]$Title, [string[]]$Tabs) {
    if ($null -eq $Tabs) { $Tabs = @() }
    return New-Object TerminalOrganizer.Core.Attention.AttentionCandidate -ArgumentList ([IntPtr]$Handle), $Title, $Tabs
}

function New-OptionsFixtureM {
    # SPEC-TRAY-019 (plan.md A-4 AM-1b): re-based identically to fixture M (session tabs
    # launcher-prefixed; the path-shaped window titles of 4102/4106 are the negatives).
    return @(
        (New-OptionsCandidate 4101 'HG_ClaudeWSL2Notification' @('HG_Hooks', 'HG_Pwsh')),
        (New-OptionsCandidate 4102 'claude ~ hooks' @('HG_ClaudeHooks')),
        (New-OptionsCandidate 4103 'PowerShell' @('HG_Wsl2')),
        (New-OptionsCandidate 4104 '' @()),
        (New-OptionsCandidate 4105 'HG_MyProject' @()),
        (New-OptionsCandidate 4106 'dev hooks' @('HG_DevHooks'))
    )
}

try {
    if (-not ('OptionsDesktopFake' -as [type])) {
        Invoke-Expression @'
    class OptionsDesktopFake : TerminalOrganizer.Core.Monitors.IDesktopSource {
        [System.Collections.Hashtable]$State
        OptionsDesktopFake([System.Collections.Hashtable]$s) { $this.State = $s }
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

function Reset-OptionsRig {
    $script:OptionsLog = New-Object 'System.Collections.Generic.List[string]'
    $script:OptionsFactoryCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:OptionsProbeCount = 0
    $script:OptionsForegroundHandle = [IntPtr]::Zero
    $script:OptionsRectFeed = @(100, 200, 900, 700)
    $script:OptionsAliveOverrides = @{}
    $script:OptionsMinimizedOverrides = @{}
    $script:OptionsNextPoll = New-OptionsTestPollResult
}

function New-OptionsTestController([bool]$Enabled = $true, [string]$Policy = 'all', [int]$Limit = 10, [bool]$Topmost = $false, [switch]$Bare, $DesktopState = $null) {
    Reset-OptionsRig
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:OptionsNextPoll }
    $probe = [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param() $script:OptionsProbeCount++; New-OptionsFixtureM }
    $queue = [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) }
    $marshal = [System.Action[System.Action]]{ param($a) $a.Invoke() }
    $foreground = [Func[IntPtr]]{ param() $script:OptionsForegroundHandle }
    $alive = [Func[IntPtr,bool]]{ param($h)
        $key = $h.ToInt64()
        if ($script:OptionsAliveOverrides.ContainsKey($key)) { return $script:OptionsAliveOverrides[$key] }
        return $true }
    $minimized = [Func[IntPtr,bool]]{ param($h)
        $key = $h.ToInt64()
        if ($script:OptionsMinimizedOverrides.ContainsKey($key)) { return $script:OptionsMinimizedOverrides[$key] }
        return $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) $script:OptionsRectFeed }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:OptionsFactoryCalls.Add('create ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:OptionsFactoryCalls.Add('restart ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:OptionsFactoryCalls.Add('tick ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:OptionsFactoryCalls.Add('stop ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:OptionsFactoryCalls.Add('hide ' + $h.ToInt64()) }), `
        ([System.Action[string,string]]$null), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:OptionsFactoryCalls.Add('steady ' + $h.ToInt64()) })
    $log = [System.Action[string]]{ param($line) $script:OptionsLog.Add($line) }
    if ($null -ne $DesktopState) {
        $desktop = [OptionsDesktopFake]::new($DesktopState)
    } else {
        $desktop = $null
    }
    if ($Bare) {
        return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
            $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $desktop, $Enabled
    }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $desktop, $Enabled, $Policy, $Limit, $Topmost
}

Describe 'AC-004 Event policy filtering (REQ-CTL-001)' {
    It 'mixed overlays both kinds: a stop signal matches and creates overlays' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        ($script:OptionsLog -contains 'attention: event=stop needle="hooks" matched=3') | Should Be $true
        ($script:OptionsFactoryCalls -join '|') | Should BeExactly 'create 4101|create 4102|create 4106'
        $controller.Dispose()
    }

    It 'mixed also overlays a notification signal' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        ($script:OptionsLog -contains 'attention: event=notification needle="pwsh" matched=1') | Should Be $true
        ($script:OptionsFactoryCalls -contains 'create 4101') | Should Be $true
        $controller.Dispose()
    }

    It 'all is the opt-back-in: a stop overlay ticks past the limit with no blinklimit stop' {
        $controller = New-OptionsTestController -Policy 'all' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        for ($i = 0; $i -lt 5; $i++) { $controller.BlinkTick() }
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 5
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'stop 4101' }).Count) | Should Be 0
        $controller.Dispose()
    }

    It 'notifications consumes a stop signal with the policy suppression line and starts NO run' {
        $controller = New-OptionsTestController -Policy 'notifications'
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        $script:OptionsProbeCount | Should Be 0
        $script:OptionsLog.Count | Should Be 1
        $script:OptionsLog[0] | Should BeExactly 'attention: suppressed (policy notifications) event=stop needle="hooks"'
        $script:OptionsFactoryCalls.Count | Should Be 0
        $controller.Dispose()
    }

    It 'notifications still overlays notification signals (unlimited)' {
        $controller = New-OptionsTestController -Policy 'notifications'
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'hooks'))
        $controller.PollTick()
        ($script:OptionsLog -contains 'attention: event=notification needle="hooks" matched=3') | Should Be $true
        ($script:OptionsFactoryCalls.Count -gt 0) | Should Be $true
        $controller.Dispose()
    }

    It 'a mixed stop+notification batch under notifications: one suppression line, the notification overlays, ONE run' {
        $controller = New-OptionsTestController -Policy 'notifications'
        $script:OptionsNextPoll = New-OptionsTestPollResult @(
            (New-OptionsTestSignal 'stop' 'pwsh'), (New-OptionsTestSignal 'notification' 'hooks'))
        $controller.PollTick()
        $script:OptionsProbeCount | Should Be 1
        # SPEC-TRAY-019 AM-3: suppression + primary + three match lines (hooks matches 4101/4102/4106).
        $script:OptionsLog.Count | Should Be 5
        $script:OptionsLog[0] | Should BeExactly 'attention: suppressed (policy notifications) event=stop needle="pwsh"'
        $script:OptionsLog[1] | Should BeExactly 'attention: event=notification needle="hooks" matched=3'
        $controller.Dispose()
    }

    It 'the bare 12-argument constructor behaves as all: a stop overlay outlives any limit' {
        $controller = New-OptionsTestController -Bare
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        for ($i = 0; $i -lt 15; $i++) { $controller.BlinkTick() }
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 15
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'stop *' }).Count) | Should Be 0
        $controller.Dispose()
    }

    It 'while disabled the policy adds nothing: only the disabled-suppression line appears' {
        $controller = New-OptionsTestController -Enabled $false -Policy 'notifications'
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'hooks'))
        $controller.PollTick()
        $script:OptionsLog.Count | Should Be 1
        $script:OptionsLog[0] | Should BeExactly 'attention: suppressed (disabled) event=stop needle="hooks"'
        $script:OptionsFactoryCalls.Count | Should Be 0
        $controller.Dispose()
    }
}

Describe 'AC-005 Blink-limit lifecycle (REQ-CTL-002)' {
    It 'limit N stops on the Nth visible tick, tick recorded first: N=3 boundary' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 2
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'steady 4101' }).Count) | Should Be 0
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 3
        $script:OptionsFactoryCalls[-1] | Should BeExactly 'steady 4101'
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $script:OptionsLog.Clear()
        $script:OptionsFactoryCalls.Clear()
        $controller.BlinkTick()
        # t18: the capped overlay stays alive as a steady dim ring - the next tick
        # re-asserts it (one steady call), never blinks it, and logs nothing.
        $script:OptionsLog.Count | Should Be 0
        $script:OptionsFactoryCalls.Count | Should Be 1
        $script:OptionsFactoryCalls[0] | Should BeExactly 'steady 4101'
        $controller.Dispose()
    }

    It 'limit 1 stops on the 1st visible tick' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 1
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        $script:OptionsFactoryCalls[-2] | Should BeExactly 'tick 4101'
        $script:OptionsFactoryCalls[-1] | Should BeExactly 'steady 4101'
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
    }

    It 'a notification overlay under mixed is never limited: N+10 visible ticks and no stop' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        for ($i = 0; $i -lt 13; $i++) { $controller.BlinkTick() }
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 13
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'steady *' }).Count) | Should Be 0
        $controller.Dispose()
    }

    It 'hidden off-desktop ticks do not count: the stop lands on the Nth on-desktop tick' {
        $desktop = @{ Success = $true; OnCurrent = $false; Calls = 0; Error = '' }
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 3 -DesktopState $desktop
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'hide 4101' }).Count) | Should Be 2
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'steady *' }).Count) | Should Be 0
        $desktop['OnCurrent'] = $true
        $controller.BlinkTick()
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 2
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'steady *' }).Count) | Should Be 0
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 3
        $script:OptionsFactoryCalls[-1] | Should BeExactly 'steady 4101'
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
    }

    It 'a restart resets the count and adopts the new signal kind (both directions)' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'restart 4101' }).Count) | Should Be 1
        for ($i = 0; $i -lt 13; $i++) { $controller.BlinkTick() }
        # 1 pre-restart tick + 13 further (N+10) ticks: the restart RESETS the count, so no stop
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'tick 4101' }).Count) | Should Be 14
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'steady *' }).Count) | Should Be 0

        $controller2 = New-OptionsTestController -Policy 'mixed' -Limit 3
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller2.PollTick()
        $controller2.BlinkTick()
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller2.PollTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'restart 4101' }).Count) | Should Be 1
        $controller2.BlinkTick()
        $controller2.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'steady *' }).Count) | Should Be 0
        $controller2.BlinkTick()
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
        $controller2.Dispose()
    }

    It 'the limit applies per overlay: two handles from one stop signal stop at their own Nth tick' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 2
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'claude'))
        $controller.PollTick()
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -like 'steady *' }).Count) | Should Be 0
        $controller.BlinkTick()
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'steady 4101' }).Count) | Should Be 1
        (@($script:OptionsFactoryCalls | Where-Object { $_ -eq 'steady 4102' }).Count) | Should Be 1
        $controller.Dispose()
    }

    It 'a D-10 move preempts the count: reason=moved before the Nth tick, for limited and unlimited alike' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 5
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'stop' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        $script:OptionsRectFeed = @(150, 250, 950, 750)
        $controller.BlinkTick()
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=moved'
        (@($script:OptionsLog | Where-Object { $_ -like '*blinklimit*' }).Count) | Should Be 0

        $controller2 = New-OptionsTestController -Policy 'mixed' -Limit 5
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller2.PollTick()
        $script:OptionsRectFeed = @(150, 250, 950, 750)
        $controller2.BlinkTick()
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=moved'
        $controller.Dispose()
        $controller2.Dispose()
    }

    It 'under mixed, a notification overlay still honors the TRAY-013 stop conditions (foreground)' {
        $controller = New-OptionsTestController -Policy 'mixed' -Limit 50
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        $controller.BlinkTick()
        $script:OptionsForegroundHandle = [IntPtr]4101
        $controller.BlinkTick()
        $script:OptionsLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=foreground'
        $controller.Dispose()
    }
}

Describe 'AC-006 Topmost z-mode and the reworked guard (REQ-OVL-001)' {
    It 'the pure selector: InsertAfterFor(false, T) is T; InsertAfterFor(true, T) is the sentinel -1' {
        $target = [IntPtr]424242
        [TerminalOrganizer.App.AttentionOverlayGeometry]::InsertAfterFor($false, $target) | Should Be $target
        [TerminalOrganizer.App.AttentionOverlayGeometry]::InsertAfterFor($true, $target) | Should Be ([IntPtr](-1))
    }

    It 'the reworked guard: one sentinel declaration, one IntPtr(-1) literal, one use, threaded through the single sizing line' {
        $overlayPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'
        $lines = [IO.File]::ReadAllLines($overlayPath)
        foreach ($token in @('HwndTopmost', 'HWND_TOPMOST', 'WsExTopmost', 'WS_EX_TOPMOST', '0x00000008')) {
            @($lines | Where-Object { $_.Contains($token) }).Count | Should Be 0
        }
        # one named sentinel, declared once and used exactly once (in the selector's true branch)
        (@($lines | Where-Object { $_.Contains('AboveAllInsertAfter') }).Count) | Should Be 2
        (@($lines | Where-Object { $_.Contains('new IntPtr(-1)') }).Count) | Should Be 1
        # the single sizing line threads the selector, the target, the extents and the no-activate flag
        $callLines = @($lines | Where-Object { $_.Contains('Native.SetWindowPos(') })
        $callLines.Count | Should Be 1
        ($callLines[0].Contains('InsertAfterFor(')) | Should Be $true
        ($callLines[0] -match '\btarget\b') | Should Be $true
        ($callLines[0] -match 'place\[') | Should Be $true
        @($lines | Where-Object { $_.Contains('SetWindowPos') -and $_ -notmatch '(?i)SWP_NOACTIVATE|SwpNoactivate' }).Count | Should Be 0
    }

    It 'SetTopmost stores the mode and never re-z-orders a live overlay (no positioning call)' {
        $controller = New-OptionsTestController -Policy 'mixed' -Topmost $false
        $script:OptionsNextPoll = New-OptionsTestPollResult @((New-OptionsTestSignal 'notification' 'pwsh'))
        $controller.PollTick()
        $controller.TopmostMode | Should Be $false
        $script:OptionsFactoryCalls.Clear()
        $controller.SetTopmost($true)
        $controller.TopmostMode | Should Be $true
        $script:OptionsFactoryCalls.Count | Should Be 0
        $controller.Dispose()
    }
}
