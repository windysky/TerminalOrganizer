# SPEC-MON-003 dump tool (REQ-CMP-002).
# -SelfTest : exercises the pure components (path parse, EDID parse, matcher truth table,
#             desktop precedence) against the pinned values; prints one PASS/FAIL line per
#             check and exits 0 only when every check passes.
# No switch  : enumerates the real monitors and prints, per monitor: parsed identity, serial,
#             work area, DPI, the resolved desktop GUID source, and the FancyZones live-row
#             hint read from the log folder (a `live-hint:` line, printed always;
#             -FancyZonesLogs <path>, default: the real FancyZones Logs folder). With
#             -AppliedLayouts <path> it also prints the `document-order:` result, the
#             `hinted:` result and the `decided by:` rule (SPEC-MON-011); these lines
#             replace the older `fuzzy-match:` line.
#             Live output is informational (morning checklist), NOT an acceptance claim
#             about live correctness.
param(
    [switch]$SelfTest,
    [string]$AppliedLayouts,
    [string]$FancyZonesLogs
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$dllPath = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
if (-not $FancyZonesLogs) {
    $FancyZonesLogs = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\FancyZones\Logs'
}

if (-not (Test-Path $dllPath)) {
    Write-Output ('FAIL: build output missing: ' + $dllPath + ' (run build.ps1 first)')
    exit 1
}
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dllPath))

# Pinned values (acceptance.md Conventions; plan.md J.1/J.2) — never re-derived from code under test.
$MON14_PATH = '\\?\DISPLAY#DELA07B#5&1b98c55a&0&UID4354#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}'
$MON14_ID = 'DELA07B'
$MON14_INSTANCE = '5&1b98c55a&0&UID4354'
$MON14_NUMBER = 3
$MON14_SERIAL = 'YMYH14CO3VKS'
$DESKTOP_1 = '{A4E51EC3-B149-4070-A47D-1902CA048C5B}'
$DESKTOP_2 = '{E66ED430-0000-0000-0000-000000000000}'

$script:FailCount = 0
$script:CheckCount = 0

function Assert-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    $script:CheckCount++
    if ($Ok) {
        Write-Output ('PASS: ' + $Name)
    }
    else {
        $script:FailCount++
        Write-Output ('FAIL: ' + $Name + ' — expected ' + $Detail)
    }
}

function New-MonitorIdentity([string]$MonitorId, [string]$Instance, [int]$Number, [string]$Serial) {
    New-Object TerminalOrganizer.Core.Monitors.MonitorIdentity -ArgumentList $MonitorId, $Instance, $Number, $Serial
}

function New-DeviceKey([string]$Monitor, [string]$Instance, [int]$Number, [string]$Serial, [string]$Desktop) {
    New-Object TerminalOrganizer.Core.Layouts.DeviceKey -ArgumentList $Monitor, $Instance, $Number, $Serial, $Desktop
}

# Builds a plan.md J.2 synthetic EDID: descriptor at offset 54, FF 00 00 00, then the text bytes.
function New-SyntheticEdid([byte[]]$TextBytes) {
    $edid = New-Object byte[] 128
    $edid[54] = 0xFF
    $edid[55] = 0x00
    $edid[56] = 0x00
    $edid[57] = 0x00
    for ($i = 0; $i -lt $TextBytes.Length; $i++) { $edid[58 + $i] = $TextBytes[$i] }
    ,$edid
}

# SPEC-MON-011 REQ-TOOL-001: the per-monitor hint lines. Shared by the live mode and by -SelfTest, which
# asserts them on inputs pinned inside this tool.
function Format-RowText($Entry) {
    if ($null -eq $Entry) { return 'no-match' }
    'position ' + $Entry.Position + ' (' + $Entry.Device.MonitorNumber + ', ' + $Entry.Device.SerialNumber + ')'
}

function Get-HintLines($ReadResult, $AppliedDoc, $Identity, $DesktopText) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $hint = $ReadResult.Hint
    if ($null -ne $hint) { $lines.Add('  live-hint: ' + $hint.Number + ' ' + $hint.Serial + ' (' + $hint.SourceFileName + ')') }
    else { $lines.Add('  live-hint: none (' + $ReadResult.Code.ToString() + ')') }
    if ($null -ne $AppliedDoc) {
        $plain = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Select($AppliedDoc, $Identity, $DesktopText)
        $decision = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Decide($AppliedDoc, $Identity, $DesktopText, $hint)
        $lines.Add('  document-order: ' + (Format-RowText $plain))
        $lines.Add('  hinted: ' + (Format-RowText $decision.Entry))
        $lines.Add('  decided by: ' + $decision.Rule.ToString())
    }
    ,$lines.ToArray()
}

if ($SelfTest) {
    # --- Path parsing (AC-001) ---
    $parts = [TerminalOrganizer.Core.Monitors.InterfacePathParser]::Parse($MON14_PATH)
    Assert-Check 'path/monitor-id' ($parts.MonitorId -ceq $MON14_ID) ($MON14_ID + ' got [' + $parts.MonitorId + ']')
    Assert-Check 'path/instance' ($parts.Instance -ceq $MON14_INSTANCE) ($MON14_INSTANCE + ' got [' + $parts.Instance + ']')

    $badAllEmpty = $true
    foreach ($bad in @('garbage', '\\?\DISPLAY#ONLYONE', '', $null)) {
        $p = [TerminalOrganizer.Core.Monitors.InterfacePathParser]::Parse($bad)
        if ($p.MonitorId -ne '' -or $p.Instance -ne '') { $badAllEmpty = $false }
    }
    Assert-Check 'path/unparseable-empty' $badAllEmpty 'both components empty for every unparseable input'

    $lower = [TerminalOrganizer.Core.Monitors.InterfacePathParser]::Parse('\\?\DISPLAY#dela07b#5&1b98c55a&0&UID4354#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}')
    Assert-Check 'path/ordinal' ($lower.MonitorId -ceq 'dela07b' -and $lower.MonitorId -cne 'DELA07B') 'lower-case id stays lower-case'

    # --- EDID parsing (AC-002) ---
    $textA = [System.Text.Encoding]::ASCII.GetBytes('YMYH14CO3VKS')
    $bytesA = New-Object byte[] ($textA.Length + 2)
    [Array]::Copy($textA, 0, $bytesA, 0, $textA.Length)
    $bytesA[$textA.Length] = 0x0A
    $bytesA[$textA.Length + 1] = 0x20
    $serialA = [TerminalOrganizer.Core.Monitors.EdidParser]::ParseSerial((New-SyntheticEdid $bytesA))
    Assert-Check 'edid/case-A' ($serialA -ceq 'YMYH14CO3VKS') ('YMYH14CO3VKS got [' + $serialA + ']')

    $textB = [System.Text.Encoding]::ASCII.GetBytes(' SN-001')
    $bytesB = New-Object byte[] ($textB.Length + 1)
    [Array]::Copy($textB, 0, $bytesB, 0, $textB.Length)
    $bytesB[$textB.Length] = 0x0A
    $serialB = [TerminalOrganizer.Core.Monitors.EdidParser]::ParseSerial((New-SyntheticEdid $bytesB))
    Assert-Check 'edid/case-B' ($serialB -ceq 'SN-001') ('SN-001 got [' + $serialB + ']')

    $serialC = [TerminalOrganizer.Core.Monitors.EdidParser]::ParseSerial((New-Object byte[] 128))
    Assert-Check 'edid/case-C' ($serialC -ceq '') ('empty string got [' + $serialC + ']')

    $serialD = [TerminalOrganizer.Core.Monitors.EdidParser]::ParseSerial((New-Object byte[] 10))
    Assert-Check 'edid/case-D' ($serialD -ceq '') ('empty string got [' + $serialD + ']')

    # Real-hardware monitor-descriptor form (live probe 2026-09-25: 00 00 00 FF header, tag at
    # byte 3, NUL pad at byte 4, text from byte 5), same pinned serial value — proves the
    # registry EDID shape parses too.
    $edidReal = New-Object byte[] 128
    $edidReal[54] = 0x00
    $edidReal[55] = 0x00
    $edidReal[56] = 0x00
    $edidReal[57] = 0xFF
    $edidReal[58] = 0x00
    $textReal = [System.Text.Encoding]::ASCII.GetBytes('YMYH14CO3VKS')
    [Array]::Copy($textReal, 0, $edidReal, 59, $textReal.Length)
    $edidReal[71] = 0x0A
    $serialReal = [TerminalOrganizer.Core.Monitors.EdidParser]::ParseSerial($edidReal)
    Assert-Check 'edid/real-hardware-form' ($serialReal -ceq 'YMYH14CO3VKS') ('YMYH14CO3VKS got [' + $serialReal + ']')

    # --- Matcher truth table (AC-003) ---
    $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
    $rows = @(
        @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1), $true,  'exact-MON14' ),
        @( (New-DeviceKey $MON14_ID 'UID9999' $MON14_NUMBER $MON14_SERIAL $DESKTOP_1),      $true,  'number-fallback' ),
        @( (New-DeviceKey $MON14_ID 'UID9999' 7 $MON14_SERIAL $DESKTOP_1),                   $false, 'instance-and-number-changed' ),
        @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER '' $DESKTOP_1),            $true,  'entry-serial-empty' ),
        @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER 'OTHER-SERIAL' $DESKTOP_1), $false, 'serial-both-nonempty-differ' ),
        @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_2), $false, 'desktop-differs' )
    )
    foreach ($row in $rows) {
        $actual = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Match($row[0], $identity, $DESKTOP_1)
        Assert-Check ('matcher/' + $row[2]) ($actual -eq $row[1]) ($row[1].ToString() + ' got ' + $actual.ToString())
    }

    $identityEmptySerial = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER ''
    $entryFullSerial = New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1
    $actualQ = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Match($entryFullSerial, $identityEmptySerial, $DESKTOP_1)
    Assert-Check 'matcher/query-serial-empty' ($actualQ -eq $true) 'True got ' + $actualQ.ToString()

    $identityLegacy = New-MonitorIdentity '\\.\DISPLAY1' 'X' 3 ''
    $entryLegacy = New-DeviceKey '\\.\DISPLAY1' '' 3 '' $DESKTOP_1
    $actualL = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Match($entryLegacy, $identityLegacy, $DESKTOP_1)
    Assert-Check 'matcher/legacy-empty-instance' ($actualL -eq $true) 'True got ' + $actualL.ToString()

    $firstEntry = '{"device":{"monitor":"' + $MON14_ID + '","monitor-instance":"' + $MON14_INSTANCE + '","monitor-number":' + $MON14_NUMBER +
        ',"serial-number":"","virtual-desktop":"' + $DESKTOP_1 +
        '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0,"zone-count":2}}'
    $secondEntry = '{"device":{"monitor":"' + $MON14_ID + '","monitor-instance":"' + $MON14_INSTANCE + '","monitor-number":' + $MON14_NUMBER +
        ',"serial-number":"' + $MON14_SERIAL + '","virtual-desktop":"' + $DESKTOP_1 +
        '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0,"zone-count":2}}'
    $twoDoc = [TerminalOrganizer.Core.Layouts.FancyZonesJsonReader]::ParseAppliedLayouts(('{"applied-layouts":[' + $firstEntry + ',' + $secondEntry + ']}'))
    $firstSelected = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Select($twoDoc, $identity, $DESKTOP_1)
    Assert-Check 'matcher/first-wins' ($firstSelected -ne $null -and $firstSelected.Position -eq 0) 'position 0 (first in document order)'

    # --- Desktop precedence (AC-004) ---
    $gB = [guid]'{BBBBBBBB-0000-0000-0000-000000000001}'
    $gC = [guid]'{CCCCCCCC-0000-0000-0000-000000000002}'
    $gD = [guid]'{DDDDDDDD-0000-0000-0000-000000000003}'
    $precRows = @(
        @('{BBBBBBBB-0000-0000-0000-000000000001}', '{CCCCCCCC-0000-0000-0000-000000000002}', '{DDDDDDDD-0000-0000-0000-000000000003}', $gB, 'win10-wins'),
        @($null, '{CCCCCCCC-0000-0000-0000-000000000002}', '{DDDDDDDD-0000-0000-0000-000000000003}', $gC, 'win11-after-null'),
        @('not-a-guid', '{CCCCCCCC-0000-0000-0000-000000000002}', '{DDDDDDDD-0000-0000-0000-000000000003}', $gC, 'win11-after-bad-guid'),
        @($null, $null, '{DDDDDDDD-0000-0000-0000-000000000003}', $gD, 'window-fallback'),
        @($null, $null, $null, $null, 'all-null')
    )
    foreach ($row in $precRows) {
        $resolved = [TerminalOrganizer.Core.Monitors.DesktopIdResolver]::Resolve($row[0], $row[1], $row[2])
        if ($null -eq $row[3]) {
            Assert-Check ('precedence/' + $row[4]) ($null -eq $resolved) 'null got ' + $(if ($null -eq $resolved) { 'null' } else { $resolved.ToString() })
        }
        else {
            Assert-Check ('precedence/' + $row[4]) ($resolved -eq $row[3]) ($row[3].ToString() + ' got ' + $(if ($null -eq $resolved) { 'null' } else { $resolved.ToString() }))
        }
    }

    $resolvedLower = [TerminalOrganizer.Core.Monitors.DesktopIdResolver]::Resolve($DESKTOP_1.ToLowerInvariant(), $null, $null)
    Assert-Check 'precedence/guid-by-value' ($resolvedLower -eq [guid]$DESKTOP_1) 'value-equal GUID for lower-case text'

    # --- SPEC-MON-011 rows: log parser, hinted selection, line formats (inputs pinned here, never derived from the code under test) ---
    $slId = 'DEL4091'
    $slInst4352 = '5&22cafbe4&0&UID4352'
    $slInst4358 = '5&22cafbe4&0&UID4358'
    $slD1 = '{9089F388-5216-49EA-9CD4-07E910D817EB}'
    $slD2 = '{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}'
    $slD3 = '{F00CF935-4664-4091-8DB7-96651F0C4D1E}'
    $slEhu = 'XPG0H42JBEHU'
    $slD2u = 'XPG0H42JBD2U'
    $slLog = '[2026-10-23 18:52:16.538900] [p-24844] [t-24848] [info] Initialize layout on DEL4091_5&22cafbe4&0&UID4358_2_XPG0H42JBEHU_{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}, work area rect = 1920x1032' + "`r`n" +
        '[2026-10-23 18:52:16.552001] [p-24844] [t-24848] [info] Initialize layout on DEL4091_5&22cafbe4&0&UID4352_1_XPG0H42JBEHU_{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}, work area rect = 1920x1032' + "`r`n"
    $h4352 = [TerminalOrganizer.Core.Monitors.FancyZonesLogParser]::FindNewestHint($slLog, $slId, $slInst4352)
    Assert-Check 'mon011/parser-UID4352' ($null -ne $h4352 -and $h4352.Number -eq 1 -and $h4352.Serial -ceq $slEhu) '(1, XPG0H42JBEHU) from the log, not the EDID serial'
    $h4358 = [TerminalOrganizer.Core.Monitors.FancyZonesLogParser]::FindNewestHint($slLog, $slId, $slInst4358)
    Assert-Check 'mon011/parser-UID4358' ($null -ne $h4358 -and $h4358.Number -eq 2 -and $h4358.Serial -ceq $slEhu) '(2, XPG0H42JBEHU)'

    # SF-STALE: 12 rows (instance, number, serial, desktop) in the original order; positions 0, 5, 6, 7, 8, 9 are stale.
    $slRows = @(
        @($slInst4352, 2, $slD2u, $slD1), @($slInst4358, 2, $slEhu, $slD1), @($slInst4352, 1, $slEhu, $slD1),
        @($slInst4358, 2, $slEhu, $slD2), @($slInst4352, 1, $slEhu, $slD2), @($slInst4358, 1, $slD2u, $slD1),
        @($slInst4358, 1, $slD2u, $slD2), @($slInst4358, 1, $slD2u, $slD3), @($slInst4352, 2, $slD2u, $slD2),
        @($slInst4352, 2, $slD2u, $slD3), @($slInst4352, 1, $slEhu, $slD3), @($slInst4358, 2, $slEhu, $slD3)
    )
    $slJson = '{"applied-layouts":[' + ((@($slRows | ForEach-Object {
        '{"device":{"monitor":"' + $slId + '","monitor-instance":"' + $_[0] + '","monitor-number":' + $_[1] + ',"serial-number":"' + $_[2] +
            '","virtual-desktop":"' + $_[3] + '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0,"zone-count":2}}'
    })) -join ',') + ']}'
    $slDoc = [TerminalOrganizer.Core.Layouts.FancyZonesJsonReader]::ParseAppliedLayouts($slJson)
    # Expected-position table (acceptance.md): label, instance, desktop, hint number, 3-argument pick, hinted pick.
    $slCases = @(
        @('UID4352-D1', $slInst4352, $slD1, 1, 0, 2), @('UID4352-D2', $slInst4352, $slD2, 1, 4, 4), @('UID4352-D3', $slInst4352, $slD3, 1, 9, 10),
        @('UID4358-D1', $slInst4358, $slD1, 2, 1, 1), @('UID4358-D2', $slInst4358, $slD2, 2, 3, 3), @('UID4358-D3', $slInst4358, $slD3, 2, 7, 11)
    )
    foreach ($c in $slCases) {
        $slIdentity = $(if ($c[1] -eq $slInst4352) { New-MonitorIdentity $slId $c[1] 1 $slD2u } else { New-MonitorIdentity $slId $c[1] 2 $slEhu })
        $slHint = New-Object TerminalOrganizer.Core.Monitors.LiveRowHint -ArgumentList $c[3], $slEhu
        $slDecision = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Decide($slDoc, $slIdentity, $c[2], $slHint)
        $slPlain = [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Select($slDoc, $slIdentity, $c[2])
        Assert-Check ('mon011/hinted-' + $c[0]) ($null -ne $slDecision.Entry -and $slDecision.Entry.Position -eq $c[5] -and $slDecision.Rule.ToString() -ceq 'LiveHint' -and $null -ne $slPlain -and $slPlain.Position -eq $c[4]) ('LiveHint at position ' + $c[5] + ', document order ' + $c[4])
    }

    # Line formats for the SF-STALE decision of ID-4352 on D1 with the hint (1, XPG0H42JBEHU) from log_2026-10-23.log.
    $slReadResult = New-Object TerminalOrganizer.Core.Monitors.LogReadResult -ArgumentList ([TerminalOrganizer.Core.Monitors.LogReadCode]::Found),
        (New-Object TerminalOrganizer.Core.Monitors.LiveRowHint -ArgumentList 1, $slEhu, 'log_2026-10-23.log')
    $slLines = Get-HintLines $slReadResult $slDoc (New-MonitorIdentity $slId $slInst4352 1 $slD2u) $slD1
    $slExpected = @('  live-hint: 1 XPG0H42JBEHU (log_2026-10-23.log)', '  document-order: position 0 (2, XPG0H42JBD2U)', '  hinted: position 2 (1, XPG0H42JBEHU)', '  decided by: LiveHint')
    Assert-Check 'mon011/line-format' (($slLines -join '|') -ceq ($slExpected -join '|')) ($slExpected -join ' | ')
    foreach ($slLine in $slLines) { Write-Output $slLine }

    Write-Output ('SelfTest summary: ' + $script:CheckCount + ' checks, ' + $script:FailCount + ' failed')
    if ($script:FailCount -gt 0) { exit 1 }
    exit 0
}

# --- Live mode (morning checklist; informational only) ---
# Exit codes (B5): 0 success or valid no-monitors; 1 invalid args / missing required
# file; 2 acquisition exception/failure. Every catch writes ERROR to stderr.
function Fail-Mon([string]$Message, [int]$Code) {
    [Console]::Error.WriteLine('ERROR: ' + $Message)
    exit $Code
}

if (-not [string]::IsNullOrEmpty($AppliedLayouts) -and -not (Test-Path -LiteralPath $AppliedLayouts)) {
    Fail-Mon ('required applied-layouts file not found: ' + $AppliedLayouts) 1
}

try {
    $provider = New-Object TerminalOrganizer.Core.Monitors.Win32MonitorProvider
    $reader = New-Object TerminalOrganizer.Core.Monitors.VirtualDesktopReader

    $desktopText = $null
    $desktopSource = 'none (registry steps absent; step 3 needs a known window — tray app / SPEC-WIN-004)'
    $win10 = $reader.TryReadWin10SessionValue()
    if ($win10.Status.ToString() -eq 'Present') {
        $desktopText = $win10.Value
        $desktopSource = 'win10-session-registry'
    }
    else {
        $win11 = $reader.TryReadWin11Value()
        if ($win11.Status.ToString() -eq 'Present') {
            $desktopText = $win11.Value
            $desktopSource = 'win11-registry'
        }
        else {
            Write-Output ('note: win10-session read = ' + $win10.Status.ToString() + ', win11 read = ' + $win11.Status.ToString())
        }
    }

    $appliedDoc = $null
    if (-not [string]::IsNullOrEmpty($AppliedLayouts)) {
        $resolvedPath = (Resolve-Path -LiteralPath $AppliedLayouts).ProviderPath
        $appliedDoc = [TerminalOrganizer.Core.Layouts.FancyZonesJsonReader]::ParseAppliedLayouts([IO.File]::ReadAllText($resolvedPath))
        if (-not $appliedDoc.IsValid) {
            Write-Output ('WARN: applied-layouts document invalid: ' + $appliedDoc.Detail)
            $appliedDoc = $null
        }
    }

    $monitors = $provider.GetMonitors()
    Write-Output ('live dump: ' + $monitors.Length + ' monitor(s); desktop source: ' + $desktopSource +
        '; desktop: ' + $(if ($null -ne $desktopText) { $desktopText } else { '<null>' }))
    foreach ($m in $monitors) {
        Write-Output ('monitor #' + $m.Number + ': id=' + $m.MonitorId + ' instance=[' + $m.Instance + '] serial=[' + $m.Serial + ']')
        Write-Output ('  monitor-rect=' + $m.MonitorLeft + ',' + $m.MonitorTop + ' ' + $m.MonitorWidth + 'x' + $m.MonitorHeight +
            ' work-area=' + $m.WorkArea.Left + ',' + $m.WorkArea.Top + ' ' + $m.WorkArea.Width + 'x' + $m.WorkArea.Height + ' dpi=' + $m.WorkArea.Dpi)
        Write-Output ('  interface-path=' + $m.InterfacePath)
        # SPEC-MON-011 REQ-TOOL-001: the log hint, then (with -AppliedLayouts) document order, hinted pick and the rule.
        $readResult = [TerminalOrganizer.Core.Monitors.FancyZonesLogReader]::Read($FancyZonesLogs, $m.MonitorId, $m.Instance)
        foreach ($hintLine in (Get-HintLines $readResult $appliedDoc $m.ToIdentity() $desktopText)) {
            Write-Output $hintLine
        }
    }
    if ($monitors.Length -eq 0) {
        Write-Output 'live dump: no monitors reported (valid empty result; acquisition succeeded)'
    }
}
catch {
    Fail-Mon ('acquisition failed: ' + $_.Exception.Message) 2
}
Write-Output 'live dump is informational (morning checklist); it is NOT an acceptance claim'
exit 0
