# SPEC-TRAY-015 M3 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-008 and spec.md REQ-WIN-001 /
# REQ-PERSIST-001 / AM-2 (the ELECTED supersession of the TRAY-007 section 1.1/6
# and TRAY-014 section 5 windowless commitments), hand-derived, never from the
# code under test. Source guards follow the AC-004 D-6-guard precedent (the
# MenuStayOpen/MenuIa suites); the WinForms layer itself is manual verification
# per NFR-5 — the M3 rows in docs/manual-test-checklist.md. This file is the
# only M3 test change: every existing suite stays unedited (AC-005).
# Non-ASCII expected values are built from [char] codes (the suite preamble).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# --- fixtures ---

function New-SetWorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, 96
}

# Menu states per constructor era. Default = the current (M2 radio) era, the
# 15-argument SPEC-TRAY-015 M2 constructor; the switches build the earlier eras
# exactly as the MenuIa suite does (constructor-era scoping).
function New-SetMenuState {
    param([bool]$Busy, [bool]$Enable, [string]$Policy, [int]$Limit, [bool]$Topmost,
        [switch]$PreAttention, [switch]$Tray013Era, [switch]$Tray014Era)
    $monitors = @(New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList `
        'PCI\VEN_00&DEV_0M', 'MON-1', '0', 'SN-1', 1, 0, 0, 1920, 1152, (New-SetWorkArea 0 0 1920 1152))
    $resolution = New-Object TerminalOrganizer.Core.Assignment.ManagerResolution -ArgumentList `
        ([TerminalOrganizer.Core.Assignment.ManagerResolutionStatus]::None), $null, ([IntPtr]::Zero), 0, $null
    $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::None()
    if ($PreAttention) {
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask)
    }
    if ($Tray013Era) {
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null, $Enable
    }
    if ($Tray014Era) {
        return New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
            $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null,
            $Enable, $Policy, $Limit, $Topmost
    }
    New-Object TerminalOrganizer.App.TrayMenuState -ArgumentList $Busy, 'Ctrl+Alt+O', $monitors, @(),
        $selector, $resolution, $null, $false, ([TerminalOrganizer.App.OverflowPolicy]::Ask), $null,
        $Enable, $Policy, $Limit, $Topmost, $true
}

# The Settings root row of one built state (the row renders in every era).
function Get-SetSettingsRow($State) {
    $entries = [TerminalOrganizer.App.TrayMenuBuilder]::Build($State)
    return @(@($entries | Where-Object { $_.Kind.ToString() -eq 'Settings' }))[0]
}

# The root kinds of one built state, for slot assertions.
function Get-SetRootKinds($State) {
    @([TerminalOrganizer.App.TrayMenuBuilder]::Build($State) | ForEach-Object { $_.Kind.ToString() })
}

# AC-003-precedent derivation probe (the MenuIa shape; null delivered as a real
# null through [NullString]::Value on the direct static call).
function Invoke-SetDerive([string]$Kind, $Value, $State) {
    $kindEnum = [TerminalOrganizer.App.TrayMenuEntryKind]::Parse([TerminalOrganizer.App.TrayMenuEntryKind], $Kind)
    if ($null -eq $Value) {
        return [TerminalOrganizer.App.TrayMenuBuilder]::DeriveSettingsEntry($kindEnum, [NullString]::Value, $State)
    }
    [TerminalOrganizer.App.TrayMenuBuilder]::DeriveSettingsEntry($kindEnum, $Value, $State)
}

# Source guards: the M3-touched sources, read once. The form file is the NEW M3
# file; pre-implementation it does not exist, so the guard rows assert presence
# first (the RED state fails on that assertion, never on a file-missing error).
$script:SetCtxPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'
$script:SetBuilderPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayMenuBuilder.cs'
$script:SetFormPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\SettingsForm.cs'
$script:SetCtx = [IO.File]::ReadAllText($script:SetCtxPath)
$script:SetCtxLines = [IO.File]::ReadAllLines($script:SetCtxPath)
$script:SetBuilder = [IO.File]::ReadAllText($script:SetBuilderPath)
$script:SetForm = if (Test-Path -LiteralPath $script:SetFormPath) { [IO.File]::ReadAllText($script:SetFormPath) } else { $null }
$script:SetFormLines = if ($null -ne $script:SetForm) { [IO.File]::ReadAllLines($script:SetFormPath) } else { @() }

function Get-SetMethodBody([string]$Name) {
    $marker = 'void ' + $Name + '('
    $start = $script:SetCtx.IndexOf($marker)
    if ($start -lt 0) { return $null }
    $end = $script:SetCtx.IndexOf("`n        }", $start)
    if ($end -lt 0) { return $null }
    return $script:SetCtx.Substring($start, $end - $start)
}

Describe 'AC-008 settings-row activation (REQ-WIN-001: the reserved row opens the form)' {
    It 'the Settings row renders ENABLED in the current era, its text and slot unchanged (label "Settings" + ellipsis, between OpenLog and Version)' {
        # Hand-derived from TrayMenuBuilder's pinned render: the row's text is
        # "Settings" + U+2026 and it sits between OpenLog and Version in every
        # era; M3 activates the row (plan.md A-3b / A-5: only the enabled flag
        # and the click wiring change).
        $row = Get-SetSettingsRow (New-SetMenuState $false $true 'mixed' 10 $false)
        ($null -ne $row) | Should Be $true
        $row.Enabled | Should Be $true
        $row.Label | Should BeExactly ('Settings' + [char]0x2026)
        $row.Checked | Should Be $false
        $kinds = Get-SetRootKinds (New-SetMenuState $false $true 'mixed' 10 $false)
        $slot = [array]::IndexOf($kinds, 'Settings')
        $kinds[$slot - 1] | Should BeExactly 'OpenLog'
        $kinds[$slot + 1] | Should BeExactly 'Version'
    }

    It 'the Settings row keeps its DISMISS classification (the REQ-STAY-004 partition is untouched by M3: 8 keep-open / 20 dismiss over all 28 members)' {
        # REQ-WIN-001: "the Settings kind's classification stays dismiss (the
        # menu closes; the form opens)". The full partition re-check is the
        # M1/M2 inheritance (plan.md A-2 iteration-2 N1: 8/18 exhaustive;
        # SPEC-TRAY-020 AM re-base: 8/20 over 28).
        [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind(
            [TerminalOrganizer.App.TrayMenuEntryKind]::Settings) | Should Be $false
        $members = [enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind])
        $members.Count | Should Be 28
        $keep = @($members | Where-Object { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind(
            [TerminalOrganizer.App.TrayMenuEntryKind]::Parse([TerminalOrganizer.App.TrayMenuEntryKind], $_)) })
        $dismiss = @($members | Where-Object { -not [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind(
            [TerminalOrganizer.App.TrayMenuEntryKind]::Parse([TerminalOrganizer.App.TrayMenuEntryKind], $_)) })
        $keep.Count | Should Be 8
        $dismiss.Count | Should Be 20
    }

    It 'the Settings row keeps its text and slot in every earlier constructor era (pre-attention, SPEC-TRAY-013 flat, SPEC-TRAY-014 cycle)' {
        foreach ($era in @('PreAttention', 'Tray013Era', 'Tray014Era')) {
            $state = switch ($era) {
                'PreAttention' { New-SetMenuState $false $true 'mixed' 10 $false -PreAttention }
                'Tray013Era' { New-SetMenuState $false $true 'mixed' 10 $false -Tray013Era }
                'Tray014Era' { New-SetMenuState $false $true 'mixed' 10 $false -Tray014Era }
            }
            $row = Get-SetSettingsRow $state
            ($null -ne $row) | Should Be $true
            $row.Label | Should BeExactly ('Settings' + [char]0x2026)
            $kinds = Get-SetRootKinds $state
            $slot = [array]::IndexOf($kinds, 'Settings')
            $kinds[$slot - 1] | Should BeExactly 'OpenLog'
            $kinds[$slot + 1] | Should BeExactly 'Version'
        }
    }
}

Describe 'AC-008 the settings form (ONE form over the EXISTING surface)' {
    It 'exactly one settings-form type exists in src\TerminalOrganizer.App, in its own SettingsForm.cs source' {
        $appSources = Get-ChildItem -Path (Join-Path $repoRoot 'src\TerminalOrganizer.App') -Recurse -Filter '*.cs'
        $formFiles = @($appSources | Where-Object {
            ([IO.File]::ReadAllText($_.FullName) -match 'class\s+\w*SettingsForm\b') })
        $formFiles.Count | Should Be 1
        $formFiles[0].Name | Should BeExactly 'SettingsForm.cs'
    }

    It 'the form covers exactly the EXISTING settings surface: attention enable / event policy / stop blinks / topmost, overflow policy, manager selection' {
        # Hand-derived from REQ-WIN-001's parenthetical enumeration — no setting
        # outside that set (spec.md section 5: no schema change, no expansion).
        ($null -ne $script:SetForm) | Should Be $true
        foreach ($kindToken in @(
            'TrayMenuEntryKind.AttentionEnabled', 'TrayMenuEntryKind.AttentionEventPolicy',
            'TrayMenuEntryKind.AttentionStopBlinks', 'TrayMenuEntryKind.AttentionTopmost',
            'TrayMenuEntryKind.OverflowPolicy', 'TrayMenuEntryKind.SetManager')) {
            ($script:SetForm.Contains($kindToken)) | Should Be $true
        }
    }

    It 'the form reads through the shared derivation and builds no second settings state (plan.md B7)' {
        ($null -ne $script:SetForm) | Should Be $true
        ($script:SetForm.Contains('TrayMenuBuilder.DeriveSettingsEntry')) | Should Be $true
        ($script:SetForm -match [regex]::Escape('new AppSettings(')) | Should Be $false
    }
}

Describe 'AC-008 save routing (REQ-PERSIST-001: writes through the six existing static helpers)' {
    It 'the form write surface is exactly the six existing static save helpers' {
        ($null -ne $script:SetForm) | Should Be $true
        foreach ($helper in @(
            'ToggleAttentionOverlayTo', 'SaveAttentionEventPolicyTo', 'SaveAttentionStopBlinksTo',
            'SaveAttentionTopmostTo', 'SaveManagerSelectorTo', 'SaveOverflowPolicyTo')) {
            ($script:SetForm.Contains($helper)) | Should Be $true
        }
    }

    It 'the form never writes the store directly and M3 adds no new settings-writing helper (store.Save sites stay 3 in TrayContext.cs, 0 in SettingsForm.cs)' {
        ([regex]::Matches($script:SetCtx, 'store\.Save\(new AppSettings')).Count | Should Be 3
        ($null -ne $script:SetForm) | Should Be $true
        ([regex]::Matches($script:SetForm, 'store\.Save')).Count | Should Be 0
    }

    It 'no new settings key: AppSettings still carries exactly the 17 shipped properties, schemaVersion 3' {
        # The MenuStayOpen DTO pin, re-asserted post-M3 (REQ-PERSIST-001 binds
        # M1 and M3 equally; the 16 save-constructor fields + HasTitleRules).
        ([TerminalOrganizer.App.AppSettings].GetProperties().Count) | Should Be 19
        $scratch = Join-Path $here ('scratch-set-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratch | Out-Null
        $path = Join-Path $scratch 'settings.json'
        [IO.File]::WriteAllText($path, '{}')
        try {
            (([TerminalOrganizer.App.SettingsStore]::new($path)).Load()).SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
    }

    It 'the form applies attention writes to the live controller (SetEnabled / SetEventPolicy / SetStopBlinkLimit / SetTopmost)' {
        # The menu handlers' contract (TrayContext's attention rows): every
        # attention save also flips the controller. The form mirrors it.
        ($null -ne $script:SetForm) | Should Be $true
        foreach ($setter in @('SetEnabled', 'SetEventPolicy', 'SetStopBlinkLimit', 'SetTopmost')) {
            ($script:SetForm.Contains($setter)) | Should Be $true
        }
    }
}

Describe 'AC-008 single-instance entry point (REQ-WIN-001; NFR-3 tag site)' {
    It 'the Settings row is wired to a settings-form entry point in the WinForms attach layer' {
        @($script:SetCtxLines | Where-Object { $_.Contains('case TrayMenuEntryKind.Settings:') }).Count | Should Be 1
        ($script:SetCtx -match [regex]::Escape('item.Click += delegate { ShowSettingsForm(); };')) | Should Be $true
    }

    It 'the entry point shows ONE single-instance form: an existing live instance is focused, not re-created' {
        # REQ-WIN-001: "single-instance, focusing the existing instance on
        # reopen". Hand-derived guard tokens: the IsDisposed liveness check and
        # the Activate call are the focus-existing pair; a fresh instance is
        # created only when none is alive.
        $body = Get-SetMethodBody 'ShowSettingsForm'
        ($null -ne $body) | Should Be $true
        ($body.Contains('IsDisposed')) | Should Be $true
        ($body.Contains('Activate')) | Should Be $true
        ($body -match [regex]::Escape('new SettingsForm(')) | Should Be $true
    }

    It 'the form path never arms the menu stay-open flag (the menu is closed while the form is up)' {
        # Derived from the M1 machinery: keepMenuOpenOnClose is a one-shot flag
        # consumed by the Closing chain of the OPEN menu. The Settings row
        # DISMISSES the menu (REQ-STAY-004), so arming the flag from the form
        # path would leak it into the next menu session and swallow that
        # session's first item click. The form path must stay keep-open-free.
        $body = Get-SetMethodBody 'ShowSettingsForm'
        ($null -ne $body) | Should Be $true
        ($body.Contains('KeepMenuOpenWithSettingsUpdate')) | Should Be $false
        ($null -ne $script:SetForm) | Should Be $true
        ($script:SetForm.Contains('KeepMenuOpen')) | Should Be $false
        $managerBody = Get-SetMethodBody 'SelectManagerFromSettingsForm'
        ($null -ne $managerBody) | Should Be $true
        ($managerBody.Contains('KeepMenuOpenWithSettingsUpdate')) | Should Be $false
    }

    It 'the M3 @MX:NOTE tag site exists (NFR-3: the settings-form entry point + single-instance wiring — the AM-2 elected-supersession site)' {
        (@($script:SetCtxLines | Where-Object {
            $_.Contains('@MX:NOTE') -and $_.Contains('M3') -and $_.Contains('AM-2') }).Count) | Should Be 1
        (@($script:SetCtxLines | Where-Object {
            $_.Contains('@MX:NOTE') -and $_.Contains('settings-form entry point') -and $_.Contains('single-instance') }).Count) | Should Be 1
    }

    It 'the form file carries its planned real-screen @MX:WARN marker (B5/NFR-5: never executed under Pester)' {
        ($null -ne $script:SetForm) | Should Be $true
        (@($script:SetFormLines | Where-Object { $_.Contains('@MX:WARN') }).Count) | Should Be 1
    }

    It 'closing the form never exits the app (the form owns no exit path)' {
        # AC-008 manual row "closing the form does not exit the app", source
        # side: the form holds no exit surface of any kind.
        ($null -ne $script:SetForm) | Should Be $true
        ($script:SetForm.Contains('ExitThread')) | Should Be $false
        ($script:SetForm.Contains('ExitApplication')) | Should Be $false
        ($script:SetForm.Contains('Environment.Exit')) | Should Be $false
    }
}

Describe 'AC-008 regression net (partition / era / derivation untouched by M3)' {
    It 'the 26-member keep-open set is still exactly the 8 settings-mutation kinds' {
        $expected = @('AttentionOverlay', 'AttentionEnabled', 'AttentionEventPolicy',
            'AttentionStopBlinks', 'AttentionTopmost', 'OverflowPolicy', 'SetManager', 'ClearManager')
        $members = [enum]::GetNames([TerminalOrganizer.App.TrayMenuEntryKind])
        $keep = @($members | Where-Object { [TerminalOrganizer.App.TrayMenuBuilder]::IsKeepOpenKind(
            [TerminalOrganizer.App.TrayMenuEntryKind]::Parse([TerminalOrganizer.App.TrayMenuEntryKind], $_)) })
        @($keep | Sort-Object) -join ',' | Should BeExactly (@($expected | Sort-Object) -join ',')
    }

    It 'the current-era root order is unchanged (Settings in its pinned slot; the M3 activation adds no row and moves none)' {
        $kinds = Get-SetRootKinds (New-SetMenuState $false $true 'mixed' 10 $false)
        $kinds -join ',' | Should BeExactly ('Status,Separator,OrganizeUnderCursor,Separator,OrganizeMonitorRoot,Separator,ManagerRoot,' +
            'Separator,OverflowRoot,Separator,AttentionRoot,Separator,LabelsAndPrioritiesRoot,Separator,LastResult,OpenLog,Settings,Version,Exit')
    }

    It 'the shared derivation still derives the M2 radio rows and the merge release gate exactly as before' {
        $state = New-SetMenuState $false $true 'all' 10 $false
        $allRow = Invoke-SetDerive 'AttentionEventPolicy' 'all' $state
        $allRow.Label | Should BeExactly 'All'
        $allRow.Checked | Should Be $true
        $mixedRow = Invoke-SetDerive 'AttentionEventPolicy' 'mixed' $state
        $mixedRow.Checked | Should Be $false
        $mergeRow = Invoke-SetDerive 'OverflowPolicy' 'merge' $state
        $mergeRow.Enabled | Should Be $false
        $askRow = Invoke-SetDerive 'OverflowPolicy' 'ask' $state
        $askRow.Enabled | Should Be $true
    }
}

# SPEC-TRAY-015 F1 (sync-phase audit-fix round, appended 2026-11-01): the single
# appended row of this round - append only, every existing row above stays unedited.
Describe 'AC-008 audit fix F1 (form-closed refresh: the tray menu reflects settings-form writes on next open)' {
    It 'the settings-form path wires ONE strip rebuild on form close (FormClosed then RebuildMenu in ShowSettingsForm - every form write path is covered)' {
        # Sync-audit MAJOR (Functionality): the form write paths (the manager
        # selection through SelectManagerFromSettingsForm and the five static
        # helper writes) persist through the store but never refreshed the live
        # strip, and no rebuild-on-menu-open exists - the menu showed stale
        # settings until the next organize run (AC-008 manual row / checklist
        # rows M3-6 and M3-10). The menu is dismissed while the form is up, so
        # ONE rebuild when the form closes makes the next open fresh for ALL
        # form write paths. Guard tokens: the FormClosed subscription (the
        # post-close event - never FormClosing, which the M1 guard rows pin the
        # Closing-subscription count of at exactly one) and the RebuildMenu call.
        $body = Get-SetMethodBody 'ShowSettingsForm'
        ($null -ne $body) | Should Be $true
        ($body.Contains('FormClosed')) | Should Be $true
        ($body -match [regex]::Escape('RebuildMenu();')) | Should Be $true
    }
}
