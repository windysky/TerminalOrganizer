# SPEC-MON-003 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md and plan.md section J, never from the code under test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$fixtures = Join-Path $here 'fixtures'
$dllPath = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'

# Byte-load keeps the DLL file unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dllPath))

$realAppliedJson = [IO.File]::ReadAllText((Join-Path $fixtures 'applied-layouts.json'))
$realCustomJson = [IO.File]::ReadAllText((Join-Path $fixtures 'custom-layouts.json'))

# MON-14 identity (acceptance.md Conventions; plan.md section J.1).
$MON14_PATH = '\\?\DISPLAY#DELA07B#5&1b98c55a&0&UID4354#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}'
$MON14_ID = 'DELA07B'
$MON14_INSTANCE = '5&1b98c55a&0&UID4354'
$MON14_NUMBER = 3
$MON14_SERIAL = 'YMYH14CO3VKS'
$DESKTOP_1 = '{A4E51EC3-B149-4070-A47D-1902CA048C5B}'
$DESKTOP_2 = '{E66ED430-0000-0000-0000-000000000000}'

function Parse-Path([string]$Path) {
    [TerminalOrganizer.Core.Monitors.InterfacePathParser]::Parse($Path)
}

function Parse-Serial([byte[]]$Edid) {
    [TerminalOrganizer.Core.Monitors.EdidParser]::ParseSerial($Edid)
}

# Builds a section J.2 synthetic EDID: block-0 descriptor at offset 54, tag 0xFF,
# header FF 00 00 00, then the given 14 (or fewer, zero-padded) text bytes.
function New-SyntheticEdid([byte[]]$TextBytes) {
    $edid = New-Object byte[] 128
    $edid[54] = 0xFF
    $edid[55] = 0x00
    $edid[56] = 0x00
    $edid[57] = 0x00
    for ($i = 0; $i -lt $TextBytes.Length; $i++) { $edid[58 + $i] = $TextBytes[$i] }
    ,$edid
}

Describe 'AC-001 Interface path parsing' {
    It 'parses the documented shape into id DELA07B and instance 5&1b98c55a&0&UID4354' {
        $parts = Parse-Path $MON14_PATH
        $parts.MonitorId | Should BeExactly $MON14_ID
        $parts.Instance | Should BeExactly $MON14_INSTANCE
    }

    It 'returns empty id and instance for garbage, ONLYONE, the empty string and null, without throwing' {
        foreach ($bad in @('garbage', '\\?\DISPLAY#ONLYONE', '', $null)) {
            $parts = Parse-Path $bad
            ('id=[{0}] instance=[{1}]' -f $parts.MonitorId, $parts.Instance) | Should BeExactly 'id=[] instance=[]'
        }
    }

    It 'parsing is ordinal: a lower-case id stays lower-case and does not yield DELA07B' {
        $parts = Parse-Path '\\?\DISPLAY#dela07b#5&1b98c55a&0&UID4354#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}'
        $parts.MonitorId | Should BeExactly 'dela07b'
        $parts.MonitorId | Should Not BeExactly 'DELA07B'
    }
}

Describe 'AC-002 EDID serial parsing' {
    It 'case A: YMYH14CO3VKS + 0x0A + space pad parses to YMYH14CO3VKS' {
        $text = [System.Text.Encoding]::ASCII.GetBytes('YMYH14CO3VKS')
        $bytes = New-Object byte[] ($text.Length + 2)
        [Array]::Copy($text, 0, $bytes, 0, $text.Length)
        $bytes[$text.Length] = 0x0A
        $bytes[$text.Length + 1] = 0x20
        Parse-Serial (New-SyntheticEdid $bytes) | Should BeExactly 'YMYH14CO3VKS'
    }

    It 'case B: leading space + SN-001 + 0x0A parses to SN-001' {
        $text = [System.Text.Encoding]::ASCII.GetBytes(' SN-001')
        $bytes = New-Object byte[] ($text.Length + 1)
        [Array]::Copy($text, 0, $bytes, 0, $text.Length)
        $bytes[$text.Length] = 0x0A
        Parse-Serial (New-SyntheticEdid $bytes) | Should BeExactly 'SN-001'
    }

    It 'case C: an EDID with no 0xFF descriptor returns the empty string' {
        Parse-Serial (New-Object byte[] 128) | Should BeExactly ''
    }

    It 'case D: a 10-byte input returns the empty string, and so does a null input' {
        Parse-Serial (New-Object byte[] 10) | Should BeExactly ''
        Parse-Serial $null | Should BeExactly ''
    }
}

function New-MonitorIdentity([string]$MonitorId, [string]$Instance, [int]$Number, [string]$Serial) {
    New-Object TerminalOrganizer.Core.Monitors.MonitorIdentity -ArgumentList $MonitorId, $Instance, $Number, $Serial
}

function New-DeviceKey([string]$Monitor, [string]$Instance, [int]$Number, [string]$Serial, [string]$Desktop) {
    New-Object TerminalOrganizer.Core.Layouts.DeviceKey -ArgumentList $Monitor, $Instance, $Number, $Serial, $Desktop
}

function Read-Applied([string]$Json) { [TerminalOrganizer.Core.Layouts.FancyZonesJsonReader]::ParseAppliedLayouts($Json) }

function Test-Match($EntryDevice, $Identity, [string]$Desktop) {
    [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Match($EntryDevice, $Identity, $Desktop)
}

function Select-Entry($Document, $Identity, [string]$Desktop) {
    [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Select($Document, $Identity, $Desktop)
}

function Resolve-Desktop([string]$Win10, [string]$Win11, [string]$Window) {
    [TerminalOrganizer.Core.Monitors.DesktopIdResolver]::Resolve($Win10, $Win11, $Window)
}

# One applied-layouts entry whose device carries the given five fields (valid layout, accepted).
function New-AppliedEntryJson([string]$Monitor, [string]$Instance, [int]$Number, [string]$Serial, [string]$Desktop) {
    '{"device":{"monitor":"' + $Monitor + '","monitor-instance":"' + $Instance + '","monitor-number":' + $Number +
        ',"serial-number":"' + $Serial + '","virtual-desktop":"' + $Desktop +
        '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0,"zone-count":2}}'
}

function New-AppliedDoc([string[]]$EntryJsons) { '{"applied-layouts":[' + ($EntryJsons -join ',') + ']}' }

Describe 'AC-003 Fuzzy matcher truth table' {
    It 'matches the entry-side rows for the MON-14 query with DESKTOP-1' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $rows = @(
            @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1), $true ),
            @( (New-DeviceKey $MON14_ID 'UID9999' $MON14_NUMBER $MON14_SERIAL $DESKTOP_1), $true ),
            @( (New-DeviceKey $MON14_ID 'UID9999' 7 $MON14_SERIAL $DESKTOP_1), $false ),
            @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER '' $DESKTOP_1), $true ),
            @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER 'OTHER-SERIAL' $DESKTOP_1), $false ),
            @( (New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_2), $false )
        )
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $actual = Test-Match $rows[$i][0] $identity $DESKTOP_1
            ('row {0}: expected={1} actual={2}' -f $i, $rows[$i][1], $actual) |
                Should BeExactly ('row {0}: expected={1} actual={1}' -f $i, $rows[$i][1])
        }
    }

    It 'matches when the query serial is empty and the entry serial is non-empty (either side empty)' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER ''
        $entry = New-DeviceKey $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1
        Test-Match $entry $identity $DESKTOP_1 | Should Be $true
    }

    It 'matches the legacy empty-instance shape by monitor number' {
        $identity = New-MonitorIdentity '\\.\DISPLAY1' 'X' 3 ''
        $entry = New-DeviceKey '\\.\DISPLAY1' '' 3 '' $DESKTOP_1
        Test-Match $entry $identity $DESKTOP_1 | Should Be $true
    }

    It 'returns the FIRST matching entry in document order when two entries match' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $first = New-AppliedEntryJson $MON14_ID $MON14_INSTANCE $MON14_NUMBER '' $DESKTOP_1
        $second = New-AppliedEntryJson $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1
        $doc = Read-Applied (New-AppliedDoc @($first, $second))
        $doc.Entries.Length | Should Be 2
        $selected = Select-Entry $doc $identity $DESKTOP_1
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 0
    }
}

Describe 'AC-004 Desktop GUID precedence' {
    $gB = [guid]'{BBBBBBBB-0000-0000-0000-000000000001}'
    $gC = [guid]'{CCCCCCCC-0000-0000-0000-000000000002}'
    $gD = [guid]'{DDDDDDDD-0000-0000-0000-000000000003}'

    It 'resolves each precedence row: win10, then win11, then window, then null' {
        $rows = @(
            @('{BBBBBBBB-0000-0000-0000-000000000001}', '{CCCCCCCC-0000-0000-0000-000000000002}', '{DDDDDDDD-0000-0000-0000-000000000003}', $gB),
            @($null, '{CCCCCCCC-0000-0000-0000-000000000002}', '{DDDDDDDD-0000-0000-0000-000000000003}', $gC),
            @('not-a-guid', '{CCCCCCCC-0000-0000-0000-000000000002}', '{DDDDDDDD-0000-0000-0000-000000000003}', $gC),
            @($null, $null, '{DDDDDDDD-0000-0000-0000-000000000003}', $gD),
            @($null, $null, $null, $null)
        )
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $resolved = Resolve-Desktop $rows[$i][0] $rows[$i][1] $rows[$i][2]
            if ($null -eq $rows[$i][3]) {
                ('row {0}: null={1}' -f $i, ($null -eq $resolved)) | Should BeExactly ('row {0}: null=True' -f $i)
            }
            else {
                ('row {0}: equal={1}' -f $i, ($resolved -eq $rows[$i][3])) | Should BeExactly ('row {0}: equal=True' -f $i)
            }
        }
    }

    It 'compares GUIDs by value: a lower-case value equals the upper-case GUID' {
        $resolved = Resolve-Desktop $DESKTOP_1.ToLowerInvariant() $null $null
        ($resolved -eq [guid]$DESKTOP_1) | Should Be $true
    }
}

Describe 'AC-005 Single-entry fallback on unknown desktop' {
    It 'returns the single desktop-ignored match from a synthetic single-entry document' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $doc = Read-Applied (New-AppliedDoc @(New-AppliedEntryJson $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1))
        $selected = Select-Entry $doc $identity $null
        $selected | Should Not BeNullOrEmpty
        $selected.Device.VirtualDesktop | Should BeExactly $DESKTOP_1
    }

    It 'returns no-match on REAL-A where several DELA07B-family entries match ignoring desktop' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $selected = Select-Entry (Read-Applied $realAppliedJson) $identity $null
        $selected | Should BeNullOrEmpty
    }

    It 'returns no-match when no entry matches ignoring desktop' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $doc = Read-Applied (New-AppliedDoc @(New-AppliedEntryJson 'OTHER-ID' 'INST' 9 'SER' $DESKTOP_1))
        $selected = Select-Entry $doc $identity $null
        $selected | Should BeNullOrEmpty
    }
}

Describe 'AC-006 Selector hygiene' {
    # 2026-09-26 two-tier fix: entry 4 (document-first instance-exact row on DESKTOP-1) now wins.
    # Rows 4/11/14 all carry the exact MON-14 instance on DESKTOP-1; the old serial veto skipped
    # 4 and 11 (cross-wired old-episode serials) and landed on 14. Instance equality outranks serial.
    It 'REAL-A + MON-14 + DESKTOP-1 selects entry index 4 (0-based), the document-first instance-exact row' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $selected = Select-Entry (Read-Applied $realAppliedJson) $identity $DESKTOP_1
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 4
        $selected.Device.Monitor | Should BeExactly $MON14_ID
        $selected.Device.MonitorInstance | Should BeExactly $MON14_INSTANCE
        $selected.Device.MonitorNumber | Should Be 2
        $selected.Device.SerialNumber | Should BeExactly 'YMYH14BB0D6S'
        $selected.Device.VirtualDesktop | Should BeExactly $DESKTOP_1
    }

    It 'a document whose only matching entry is rejected yields no-match (rejected entries are not considered)' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        # A valid device but an applied layout missing zone-count: the parser rejects the entry.
        $rejectedOnlyJson = '{"applied-layouts":[{"device":{"monitor":"' + $MON14_ID + '","monitor-instance":"' + $MON14_INSTANCE +
            '","monitor-number":' + $MON14_NUMBER + ',"serial-number":"' + $MON14_SERIAL + '","virtual-desktop":"' + $DESKTOP_1 +
            '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0}}]}'
        $doc = Read-Applied $rejectedOnlyJson
        $doc.Entries.Length | Should Be 0
        $doc.Rejected.Length | Should Be 1
        $selected = Select-Entry $doc $identity $DESKTOP_1
        $selected | Should BeNullOrEmpty
    }

    It 'does not mutate the document: the Entries array length stays 50 after selection' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $doc = Read-Applied $realAppliedJson
        $before = $doc.Entries.Length
        $before | Should Be 50
        $null = Select-Entry $doc $identity $DESKTOP_1
        $doc.Entries.Length | Should Be 50
    }
}

# 2026-09-26 live-bug fix (two-tier selection). Live evidence from the user's machine: FancyZones
# cross-wires serials across monitor rows (one serial stamped on both monitors' rows) and replaces
# the live episode's row in place, so the just-applied row can carry a serial that mismatches the
# monitor's real EDID serial while older ghost rows keep the real one. The old serial veto rejected
# the fresh row (or every row on a desktop — NoAppliedLayout) and let a dead ghost win. Tier 1 now
# matches on monitor id + instance + desktop only; serial never vetoes or ranks.
Describe 'Two-tier selection: instance-exact before fuzzy' {
    $LIVE_ID = 'DEL30A9'
    $LIVE_INSTANCE = '5&22cafbe4&0&UID4352'
    $LIVE_DESKTOP = '{F00CF935-0000-4000-8000-000000000000}'
    $OTHER_DESKTOP = '{9089F388-0000-4000-8000-000000000000}'
    $REAL_SERIAL = 'XPG0H42JA001'    # the monitor's true EDID serial
    $CROSSED_SERIAL = 'XPG0H42JB002' # the serial FancyZones stamped on the live episode's rows

    It 'face 1: the document-first instance-exact row beats a later serial-exact ghost row' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $liveRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $LIVE_DESKTOP
        $ghostRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL $LIVE_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($liveRow, $ghostRow))
        $selected = Select-Entry $doc $identity $LIVE_DESKTOP
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 0
        $selected.Device.SerialNumber | Should BeExactly $CROSSED_SERIAL
    }

    It 'face 1 (reverse order): document order alone decides; serial exactness never ranks rows' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $ghostRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL $LIVE_DESKTOP
        $liveRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $LIVE_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($ghostRow, $liveRow))
        $selected = Select-Entry $doc $identity $LIVE_DESKTOP
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 0
        $selected.Device.SerialNumber | Should BeExactly $REAL_SERIAL
    }

    It 'face 2: a desktop whose only row is instance-exact with a mismatched serial still selects it' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $onlyRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $OTHER_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($onlyRow))
        $selected = Select-Entry $doc $identity $OTHER_DESKTOP
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 0
    }

    It 'tier 1 still requires the desktop GUID: an earlier instance-exact row on another desktop is skipped' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $otherDesktopRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $OTHER_DESKTOP
        $currentDesktopRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $LIVE_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($otherDesktopRow, $currentDesktopRow))
        $selected = Select-Entry $doc $identity $LIVE_DESKTOP
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 1
    }

    It 'tier 2 fallback: with no instance-exact row the legacy number-fallback fuzzy rule still selects' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $numberRow = New-AppliedEntryJson $LIVE_ID 'OTHER-INSTANCE' 1 $REAL_SERIAL $LIVE_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($numberRow))
        $selected = Select-Entry $doc $identity $LIVE_DESKTOP
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 0
    }

    It 'tier 1 beats an earlier document-order tier-2-only row' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $fuzzyRow = New-AppliedEntryJson $LIVE_ID 'OTHER-INSTANCE' 1 $REAL_SERIAL $LIVE_DESKTOP
        $exactRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $LIVE_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($fuzzyRow, $exactRow))
        $selected = Select-Entry $doc $identity $LIVE_DESKTOP
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 1
    }

    It 'unknown desktop: a single instance-exact row with a mismatched serial is the match' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $onlyRow = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $CROSSED_SERIAL $LIVE_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($onlyRow))
        $selected = Select-Entry $doc $identity $null
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 0
    }

    It 'unknown desktop: several instance-exact rows are still ambiguous and yield no match' {
        $identity = New-MonitorIdentity $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL
        $rowA = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL $LIVE_DESKTOP
        $rowB = New-AppliedEntryJson $LIVE_ID $LIVE_INSTANCE 1 $REAL_SERIAL $OTHER_DESKTOP
        $doc = Read-Applied (New-AppliedDoc @($rowA, $rowB))
        $selected = Select-Entry $doc $identity $null
        $selected | Should BeNullOrEmpty
    }
}

function New-WorkArea([int]$Left, [int]$Top, [int]$Width, [int]$Height, [int]$Dpi) {
    New-Object TerminalOrganizer.Core.Geometry.WorkArea -ArgumentList $Left, $Top, $Width, $Height, $Dpi
}

function New-MonitorInfo([string]$Path, [string]$Id, [string]$Instance, [string]$Serial, [int]$Number, $WorkArea) {
    New-Object TerminalOrganizer.Core.Monitors.MonitorInfo -ArgumentList $Path, $Id, $Instance, $Serial, $Number, 0, 0, 1920, 1200, $WorkArea
}

function Build-Context($Entry, $Monitor) {
    [TerminalOrganizer.Core.Monitors.OrganizerContext]::Build($Entry, $Monitor)
}

function Resolve-Key([string]$AppliedJson, [string]$CustomJson, $Key, $WorkArea) {
    [TerminalOrganizer.Core.Layouts.LayoutResolver]::ResolveByDeviceKey($AppliedJson, $CustomJson, $Key, $WorkArea)
}

function Get-Zones($Result) { ($Result.Zones | ForEach-Object { $_.ToString() }) -join ' ' }
function Get-Warnings($Result) { ($Result.Warnings | ForEach-Object { $_.ToString() }) -join ',' }

function Get-InnerException($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException -ne $null) { $e = $e.InnerException }
    $e
}

Describe 'AC-007 Composition into resolution' {
    # Entry 4 (two-tier fix) is a grid template, 3 zones, show-spacing, spacing 16; the zone
    # expectations are the SPEC-LAYOUT-002 grid n=3 pins (Templates.Tests.ps1 AC-004) on the
    # same work area, not values re-derived from this selector change.
    It 'the composed key resolves Supported, grid, 3 zones, effective spacing 16, no warnings, z0 615x1120@16,16, z1 624x1120@647,16 and z2 617x1120@1287,16' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $wa = New-WorkArea 0 0 1920 1152 96
        $monitor = New-MonitorInfo $MON14_PATH $MON14_ID $MON14_INSTANCE $MON14_SERIAL $MON14_NUMBER $wa
        $selected = Select-Entry (Read-Applied $realAppliedJson) $identity $DESKTOP_1
        $context = Build-Context $selected $monitor
        $r = Resolve-Key $realAppliedJson $realCustomJson $context.Key $wa
        $r.Kind.ToString() | Should BeExactly 'Supported'
        $r.LayoutType | Should BeExactly 'grid'
        $r.LayoutName | Should BeNullOrEmpty
        $r.EffectiveSpacing | Should Be 16
        Get-Warnings $r | Should BeExactly ''
        Get-Zones $r | Should BeExactly 'z0:615x1120@16,16 z1:624x1120@647,16 z2:617x1120@1287,16'
    }

    It 'equals the resolution with a hand-built exact DeviceKey carrying entry 4 five fields (direct construction, not the selector)' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $wa = New-WorkArea 0 0 1920 1152 96
        $monitor = New-MonitorInfo $MON14_PATH $MON14_ID $MON14_INSTANCE $MON14_SERIAL $MON14_NUMBER $wa
        $selected = Select-Entry (Read-Applied $realAppliedJson) $identity $DESKTOP_1
        $context = Build-Context $selected $monitor
        $handKey = New-DeviceKey $MON14_ID $MON14_INSTANCE 2 'YMYH14BB0D6S' $DESKTOP_1
        $r1 = Resolve-Key $realAppliedJson $realCustomJson $context.Key $wa
        $r2 = Resolve-Key $realAppliedJson $realCustomJson $handKey $wa
        ('{0}|{1}|{2}|{3}|{4}' -f $r1.Kind, $r1.LayoutType, $r1.LayoutName, $r1.EffectiveSpacing, (Get-Zones $r1)) |
            Should BeExactly ('{0}|{1}|{2}|{3}|{4}' -f $r2.Kind, $r2.LayoutType, $r2.LayoutName, $r2.EffectiveSpacing, (Get-Zones $r2))
    }

    It 'the context carries the entry device fields and the monitor work area, without copying the entry' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $wa = New-WorkArea 0 0 1920 1152 96
        $monitor = New-MonitorInfo $MON14_PATH $MON14_ID $MON14_INSTANCE $MON14_SERIAL $MON14_NUMBER $wa
        $selected = Select-Entry (Read-Applied $realAppliedJson) $identity $DESKTOP_1
        $context = Build-Context $selected $monitor
        $context.Key.Monitor | Should BeExactly $MON14_ID
        $context.Key.MonitorInstance | Should BeExactly $MON14_INSTANCE
        $context.Key.MonitorNumber | Should Be 2
        $context.Key.SerialNumber | Should BeExactly 'YMYH14BB0D6S'
        $context.Key.VirtualDesktop | Should BeExactly $DESKTOP_1
        ([object]::ReferenceEquals($context.Key, $selected.Device)) | Should Be $true
        $context.WorkArea.Width | Should Be 1920
        $context.WorkArea.Dpi | Should Be 96
    }

    It 'a null monitor argument throws ArgumentNullException' {
        $identity = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $selected = Select-Entry (Read-Applied $realAppliedJson) $identity $DESKTOP_1
        $caught = $null
        try { Build-Context $selected $null } catch { $caught = $_ }
        $caught | Should Not BeNullOrEmpty
        (Get-InnerException $caught).GetType().FullName | Should BeExactly 'System.ArgumentNullException'
    }
}

Describe 'AC-008 Wrapper surface and degradation' {
    It 'an EDID registry read of a non-existent key yields no bytes and an empty serial, without throwing' {
        $bytes = [TerminalOrganizer.Core.Monitors.Win32MonitorProvider]::ReadEdidFromRegistry('NO_SUCH_ID', 'NO_SUCH_INSTANCE')
        $bytes | Should BeNullOrEmpty
        Parse-Serial $bytes | Should BeExactly ''
    }

    It 'the VirtualDesktopReader registry miss returns Absent rather than throwing' {
        $reader = New-Object TerminalOrganizer.Core.Monitors.VirtualDesktopReader
        $result = $reader.TryReadWin10SessionValue()
        $result | Should Not BeNullOrEmpty
        $result.Status.ToString() | Should BeExactly 'Absent'
    }

    It 'the wrappers construct with no ambient configuration and sit behind IMonitorProvider/IDesktopSource' {
        $provider = New-Object TerminalOrganizer.Core.Monitors.Win32MonitorProvider
        ($provider -is [TerminalOrganizer.Core.Monitors.IMonitorProvider]) | Should Be $true
        $reader = New-Object TerminalOrganizer.Core.Monitors.VirtualDesktopReader
        ($reader -is [TerminalOrganizer.Core.Monitors.IDesktopSource]) | Should Be $true
    }

    It 'a fake is not required: a hand-built MonitorInfo feeds the selector through ToIdentity' {
        $wa = New-WorkArea 0 0 1920 1152 96
        $monitor = New-MonitorInfo $MON14_PATH $MON14_ID $MON14_INSTANCE $MON14_SERIAL $MON14_NUMBER $wa
        $selected = Select-Entry (Read-Applied $realAppliedJson) ($monitor.ToIdentity()) $DESKTOP_1
        $selected | Should Not BeNullOrEmpty
        $selected.Position | Should Be 4
    }
}

Describe 'AC-009 Dump tool self-test' {
    It 'tools/dump-monitors.ps1 -SelfTest exits 0 with one PASS/FAIL line per check and zero FAILs' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $dump = Join-Path $repoRoot 'tools\dump-monitors.ps1'
        $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $dump -SelfTest
        $code = $LASTEXITCODE
        $lines = @($output | Where-Object { $_ -cmatch '^(PASS|FAIL):' })
        $lines.Count | Should BeGreaterThan 0
        @($lines | Where-Object { $_ -cmatch '^FAIL:' }).Count | Should Be 0
        $code | Should Be 0
    }
}

function New-A4Monitor([int]$Number = 1, [int]$WorkTop = 0, [int]$Dpi = 96, [string]$Serial = 'SER', [int]$Left = 0) {
    $wa = [TerminalOrganizer.Core.Geometry.WorkArea]::new($Left, $WorkTop, 1920, 1040, $Dpi)
    [TerminalOrganizer.Core.Monitors.MonitorInfo]::new(('DISPLAY' + $Serial), ('PATH' + $Serial), 'MODEL', 'INSTANCE', $Serial, $Number, $true, $Left, 0, 1920, 1080, $wa)
}
Describe 'A4 monitor identity and exact signatures' {
    It 'stable keys ignore numbering and resolve menu payloads after renumbering' {
        $before = New-A4Monitor 2
        $after = New-A4Monitor 1
        $before.StableKey.EqualsKey($after.StableKey) | Should Be $true
        [TerminalOrganizer.Core.Monitors.MonitorSelector]::ResolveUnique(@($after), $before.StableKey).Number | Should Be 1
        [TerminalOrganizer.Core.Monitors.MonitorSelector]::ResolveUnique(@($after, $after), $before.StableKey) | Should BeNullOrEmpty
    }
    It 'topology changes on work area DPI identity or full rectangle, but ignores order and numbering' {
        $original = [TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@((New-A4Monitor)))
        foreach ($changed in @((New-A4Monitor -WorkTop 1), (New-A4Monitor -Dpi 120), (New-A4Monitor -Serial 'OTHER'), (New-A4Monitor -Left 1920))) {
            $original.EqualsSignature([TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@($changed))) | Should Be $false
        }
        $original.EqualsSignature([TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@((New-A4Monitor 2)))) | Should Be $true
        $left = New-A4Monitor
        $right = New-A4Monitor -Serial 'OTHER' -Left 1920
        ([TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@($left, $right))).EqualsSignature([TerminalOrganizer.Core.Monitors.MonitorTopologySignature]::Capture(@($right, $left))) | Should Be $true
    }
    It 'one-pixel layout edit invalidates commit' {
        $kind = [TerminalOrganizer.Core.Layouts.LayoutResultKind]::Supported
        $a = [TerminalOrganizer.Core.Monitors.LayoutSignature]::new('key', 'desktop', $kind, 'grid', @([TerminalOrganizer.Core.Geometry.Zone]::new(0,0,0,400,300)))
        $b = [TerminalOrganizer.Core.Monitors.LayoutSignature]::new('key', 'desktop', $kind, 'grid', @([TerminalOrganizer.Core.Geometry.Zone]::new(0,1,0,400,300)))
        $a.EqualsSignature($b) | Should Be $false
    }
    It 'HMONITOR device attribution picks right even when outer left is 1912 and unknown devices fail closed' {
        $left = New-A4Monitor
        $right = New-A4Monitor -Serial 'RIGHT' -Left 1920
        $resolved = [TerminalOrganizer.Core.Windows.Win32WindowEnumerator]::ResolveMonitorByDeviceName('DISPLAYRIGHT', @($left, $right))
        $resolved.MonitorLeft | Should Be 1920
        [TerminalOrganizer.Core.Windows.Win32WindowEnumerator]::ResolveMonitorByDeviceName('missing', @($left, $right)) | Should BeNullOrEmpty
    }
}

Describe 'AC-010 Dump tool live mode exists' {
    It 'with -AppliedLayouts it enumerates real monitors, prints the per-monitor report and exits 0 (informational, not a live-correctness claim)' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $dump = Join-Path $repoRoot 'tools\dump-monitors.ps1'
        $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $dump -AppliedLayouts (Join-Path $fixtures 'applied-layouts.json')
        $code = $LASTEXITCODE
        $code | Should Be 0
        (@($output).Length) | Should BeGreaterThan 0
    }
}

# ---------------------------------------------------------------------------
# SPEC-MON-011 M1: hinted live-row selection (REQ-HIN-001..004, AC-005..AC-008).
# SF-STALE and the expected-position table are pinned by hand from acceptance.md
# (Conventions); no expected value below is computed by the code under test.
# ---------------------------------------------------------------------------
$SF_ID = 'DEL4091'
$SF_INST_4352 = '5&22cafbe4&0&UID4352'
$SF_INST_4358 = '5&22cafbe4&0&UID4358'
$SF_DESK1 = '{9089F388-5216-49EA-9CD4-07E910D817EB}'
$SF_DESK2 = '{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}'
$SF_DESK3 = '{F00CF935-4664-4091-8DB7-96651F0C4D1E}'
$SF_EHU = 'XPG0H42JBEHU'
$SF_D2U = 'XPG0H42JBD2U'

# SF-STALE, the 12 rows in the original order (instance, number, serial, desktop); S = stale, L = live.
$SF_ROWS = @(
    @($SF_INST_4352, 2, $SF_D2U, $SF_DESK1),  # 0  S
    @($SF_INST_4358, 2, $SF_EHU, $SF_DESK1),  # 1  L
    @($SF_INST_4352, 1, $SF_EHU, $SF_DESK1),  # 2  L
    @($SF_INST_4358, 2, $SF_EHU, $SF_DESK2),  # 3  L
    @($SF_INST_4352, 1, $SF_EHU, $SF_DESK2),  # 4  L
    @($SF_INST_4358, 1, $SF_D2U, $SF_DESK1),  # 5  S
    @($SF_INST_4358, 1, $SF_D2U, $SF_DESK2),  # 6  S
    @($SF_INST_4358, 1, $SF_D2U, $SF_DESK3),  # 7  S
    @($SF_INST_4352, 2, $SF_D2U, $SF_DESK2),  # 8  S
    @($SF_INST_4352, 2, $SF_D2U, $SF_DESK3),  # 9  S
    @($SF_INST_4352, 1, $SF_EHU, $SF_DESK3),  # 10 L
    @($SF_INST_4358, 2, $SF_EHU, $SF_DESK3)   # 11 L
)

# Expected-position table. Pick3 = first instance-exact row (3-argument Select); Pick = the hinted pick;
# Shuf = the hinted pick's position in the fixed shuffled order below. The hint is (1, EHU) for UID4352 and (2, EHU) for UID4358.
$SF_REVERSE = @(11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0)
$SF_SHUFFLE = @(7, 2, 11, 0, 9, 4, 1, 10, 5, 8, 3, 6)
$SF_CASES = @(
    @{ Label = 'UID4352 D1'; Inst = $SF_INST_4352; Desk = $SF_DESK1; Num = 1; Pick3 = 0; Pick = 2; Shuf = 1 },
    @{ Label = 'UID4352 D2'; Inst = $SF_INST_4352; Desk = $SF_DESK2; Num = 1; Pick3 = 4; Pick = 4; Shuf = 5 },
    @{ Label = 'UID4352 D3'; Inst = $SF_INST_4352; Desk = $SF_DESK3; Num = 1; Pick3 = 9; Pick = 10; Shuf = 7 },
    @{ Label = 'UID4358 D1'; Inst = $SF_INST_4358; Desk = $SF_DESK1; Num = 2; Pick3 = 1; Pick = 1; Shuf = 6 },
    @{ Label = 'UID4358 D2'; Inst = $SF_INST_4358; Desk = $SF_DESK2; Num = 2; Pick3 = 3; Pick = 3; Shuf = 10 },
    @{ Label = 'UID4358 D3'; Inst = $SF_INST_4358; Desk = $SF_DESK3; Num = 2; Pick3 = 7; Pick = 11; Shuf = 2 }
)

# SF-STALE with its rows listed in the given order of original positions.
function New-SfStaleJson([int[]]$Order) {
    $jsons = foreach ($i in $Order) {
        $r = $SF_ROWS[$i]
        New-AppliedEntryJson $SF_ID $r[0] $r[1] $r[2] $r[3]
    }
    New-AppliedDoc @($jsons)
}

# ID-4352 / ID-4358 use the EDID serial and enumeration number of acceptance.md Conventions (the hinted path must not consult them).
function New-SfIdentity([string]$Instance) {
    if ($Instance -eq $SF_INST_4352) { New-MonitorIdentity $SF_ID $Instance 1 $SF_D2U }
    else { New-MonitorIdentity $SF_ID $Instance 2 $SF_EHU }
}

function New-Hint([int]$Number, [string]$Serial) {
    New-Object TerminalOrganizer.Core.Monitors.LiveRowHint -ArgumentList $Number, $Serial
}

# Untyped parameters on purpose: a $null desktop or hint must reach the selector as a real null.
function Decide-Hinted($Document, $Identity, $Desktop, $Hint) {
    [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Decide($Document, $Identity, $Desktop, $Hint)
}

function Select-Hinted($Document, $Identity, $Desktop, $Hint) {
    [TerminalOrganizer.Core.Monitors.AppliedEntrySelector]::Select($Document, $Identity, $Desktop, $Hint)
}

function Get-Pos($Entry) { if ($null -eq $Entry) { -1 } else { $Entry.Position } }

# Row identity: (instance, desktop by GUID value, number, serial); never the layout uuid or the position.
function Get-RowId($Entry) {
    if ($null -eq $Entry) { return 'none' }
    '{0}|{1}|{2}|{3}' -f $Entry.Device.MonitorInstance, $Entry.Device.VirtualDesktop.ToUpper(), $Entry.Device.MonitorNumber, $Entry.Device.SerialNumber
}

Describe 'SPEC-MON-011 LiveRowHint type' {
    It 'carries the number, the serial and the source file name' {
        $h = New-Object TerminalOrganizer.Core.Monitors.LiveRowHint -ArgumentList 1, $SF_EHU, 'log_2026-10-23.log'
        $h.Number | Should Be 1
        $h.Serial | Should BeExactly $SF_EHU
        $h.SourceFileName | Should BeExactly 'log_2026-10-23.log'
    }

    It 'the two-argument form leaves the source file name empty and keeps an empty serial empty' {
        $h = New-Hint 2 ''
        $h.Number | Should Be 2
        $h.Serial | Should BeExactly ''
        $h.SourceFileName | Should BeExactly ''
    }
}

Describe 'SPEC-MON-011 AC-005 Stale-before-live repaired' {
    $doc = Read-Applied (New-SfStaleJson (0..11))

    foreach ($c in $SF_CASES) {
        It ('hinted pick for {0} is position {1} under LiveHint' -f $c.Label, $c.Pick) {
            $d = Decide-Hinted $doc (New-SfIdentity $c.Inst) $c.Desk (New-Hint $c.Num $SF_EHU)
            (Get-Pos $d.Entry) | Should Be $c.Pick
            $d.Rule.ToString() | Should BeExactly 'LiveHint'
            (Get-Pos (Select-Hinted $doc (New-SfIdentity $c.Inst) $c.Desk (New-Hint $c.Num $SF_EHU))) | Should Be $c.Pick
        }

        It ('the same pick for {0} is returned when the desktop is the lowercase ToString("B") form' -f $c.Label) {
            $lower = ([Guid]$c.Desk).ToString('B')
            $lower | Should BeExactly $c.Desk.ToLower()
            $d = Decide-Hinted $doc (New-SfIdentity $c.Inst) $lower (New-Hint $c.Num $SF_EHU)
            (Get-Pos $d.Entry) | Should Be $c.Pick
            $d.Rule.ToString() | Should BeExactly 'LiveHint'
        }

        It ('the 3-argument Select for {0} returns position {1}' -f $c.Label, $c.Pick3) {
            (Get-Pos (Select-Entry $doc (New-SfIdentity $c.Inst) $c.Desk)) | Should Be $c.Pick3
        }
    }

    It 'positions 0, 7 and 9 are the stale rows the 3-argument Select picks, and the hint repairs all three' {
        $stale = @($SF_CASES | Where-Object { $_.Pick3 -ne $_.Pick } | ForEach-Object { $_.Pick3 } | Sort-Object)
        ($stale -join ',') | Should BeExactly '0,7,9'
    }
}

Describe 'SPEC-MON-011 AC-006 Order independence' {
    $orders = @(
        @{ Name = 'original'; Order = (0..11) },
        @{ Name = 'reverse'; Order = $SF_REVERSE },
        @{ Name = 'shuffled'; Order = $SF_SHUFFLE }
    )

    foreach ($o in $orders) {
        foreach ($c in $SF_CASES) {
            It ('{0} order, {1}: the chosen row is the live row ({2}, {3}) under LiveHint' -f $o.Name, $c.Label, $c.Num, $SF_EHU) {
                $doc = Read-Applied (New-SfStaleJson $o.Order)
                $d = Decide-Hinted $doc (New-SfIdentity $c.Inst) $c.Desk (New-Hint $c.Num $SF_EHU)
                (Get-RowId $d.Entry) | Should BeExactly ('{0}|{1}|{2}|{3}' -f $c.Inst, $c.Desk, $c.Num, $SF_EHU)
                $d.Rule.ToString() | Should BeExactly 'LiveHint'
            }
        }
    }

    It 'the chosen Position moves with the row order while the identity stays: reverse = 11 - original, shuffled = pinned index' {
        $docReverse = Read-Applied (New-SfStaleJson $SF_REVERSE)
        $docShuffled = Read-Applied (New-SfStaleJson $SF_SHUFFLE)
        foreach ($c in $SF_CASES) {
            $hint = New-Hint $c.Num $SF_EHU
            $id = New-SfIdentity $c.Inst
            (Get-Pos (Select-Hinted $docReverse $id $c.Desk $hint)) | Should Be (11 - $c.Pick)
            (Get-Pos (Select-Hinted $docShuffled $id $c.Desk $hint)) | Should Be $c.Shuf
            (11 - $c.Pick) | Should Not Be $c.Pick
        }
    }
}

Describe 'SPEC-MON-011 AC-007 Fallback equivalence and rule reporting' {
    $staleDoc = Read-Applied (New-SfStaleJson (0..11))
    $realDoc = Read-Applied $realAppliedJson
    $mon14 = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
    $idNone = New-MonitorIdentity $SF_ID '5&22cafbe4&0&UID9999' 3 'XPG0H42JBZZZ'
    $noMatch = New-Hint 9 'NONE'

    It 'a null hint returns the 3-argument result by Position under DocumentOrder for REAL-A and for all six SF-STALE combinations' {
        foreach ($desk in @($DESKTOP_1, $DESKTOP_2)) {
            $d = Decide-Hinted $realDoc $mon14 $desk $null
            (Get-Pos $d.Entry) | Should Be (Get-Pos (Select-Entry $realDoc $mon14 $desk))
            $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
        }
        (Get-Pos (Decide-Hinted $realDoc $mon14 $DESKTOP_1 $null).Entry) | Should Be 4
        foreach ($c in $SF_CASES) {
            $d = Decide-Hinted $staleDoc (New-SfIdentity $c.Inst) $c.Desk $null
            (Get-Pos $d.Entry) | Should Be $c.Pick3
            $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
        }
    }

    It 'an unmatched hint returns the 3-argument result by Position under HintUnmatched for REAL-A and for all six SF-STALE combinations' {
        foreach ($desk in @($DESKTOP_1, $DESKTOP_2)) {
            $d = Decide-Hinted $realDoc $mon14 $desk $noMatch
            (Get-Pos $d.Entry) | Should Be (Get-Pos (Select-Entry $realDoc $mon14 $desk))
            $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        }
        foreach ($c in $SF_CASES) {
            $d = Decide-Hinted $staleDoc (New-SfIdentity $c.Inst) $c.Desk $noMatch
            (Get-Pos $d.Entry) | Should Be $c.Pick3
            $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        }
    }

    It 'an unknown desktop ($null or empty) ignores even a matching hint: the 3-argument result under DocumentOrder' {
        $matching = New-Hint 1 $SF_EHU
        $id = New-SfIdentity $SF_INST_4352
        foreach ($desk in @($null, '')) {
            $d = Decide-Hinted $staleDoc $id $desk $matching
            (Get-Pos $d.Entry) | Should Be (Get-Pos (Select-Entry $staleDoc $id $desk))
            $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
            $d = Decide-Hinted $realDoc $mon14 $desk $matching
            (Get-Pos $d.Entry) | Should Be (Get-Pos (Select-Entry $realDoc $mon14 $desk))
            $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
        }
    }

    It 'REAL-A with MON-14 and a null desktop is a null entry under DocumentOrder (not a missing rule)' {
        $d = Decide-Hinted $realDoc $mon14 $null $null
        ($null -eq $d.Entry) | Should Be $true
        $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
        $d = Decide-Hinted $realDoc $mon14 $null $noMatch
        ($null -eq $d.Entry) | Should Be $true
        $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
    }

    It 'a hint for an identity with no instance-exact row (ID-NONE on SF-STALE, hint 3 / S9) is a null entry under HintUnmatched' {
        $d = Decide-Hinted $staleDoc $idNone $SF_DESK1 (New-Hint 3 'S9')
        ($null -eq $d.Entry) | Should Be $true
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        $d = Decide-Hinted $staleDoc $idNone $SF_DESK1 $null
        ($null -eq $d.Entry) | Should Be $true
        $d.Rule.ToString() | Should BeExactly 'DocumentOrder'
    }

    It 'single-entry, ambiguous and foreign documents match the 3-argument result under every desktop and hint form' {
        $id = New-MonitorIdentity $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL
        $one = Read-Applied (New-AppliedDoc @(New-AppliedEntryJson $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1))
        $two = Read-Applied (New-AppliedDoc @(
                (New-AppliedEntryJson $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_1),
                (New-AppliedEntryJson $MON14_ID $MON14_INSTANCE $MON14_NUMBER $MON14_SERIAL $DESKTOP_2)))
        $other = Read-Applied (New-AppliedDoc @(New-AppliedEntryJson 'OTHER-ID' 'INST' 9 'SER' $DESKTOP_1))
        $docs = @($one, $two, $other)
        foreach ($doc in $docs) {
            foreach ($desk in @($null, '', $DESKTOP_1)) {
                foreach ($hint in @($null, $noMatch)) {
                    $d = Decide-Hinted $doc $id $desk $hint
                    (Get-Pos $d.Entry) | Should Be (Get-Pos (Select-Entry $doc $id $desk))
                }
            }
        }
        (Get-Pos (Decide-Hinted $one $id $null $null).Entry) | Should Be 0
        ($null -eq (Decide-Hinted $two $id $null $null).Entry) | Should Be $true
    }

    It 'a rejected-only document yields a null entry (rejected entries are never considered)' {
        $rejectedOnlyJson = '{"applied-layouts":[{"device":{"monitor":"' + $SF_ID + '","monitor-instance":"' + $SF_INST_4352 +
            '","monitor-number":1,"serial-number":"' + $SF_EHU + '","virtual-desktop":"' + $SF_DESK1 +
            '"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000001}","type":"custom","show-spacing":true,"spacing":0}}]}'
        $doc = Read-Applied $rejectedOnlyJson
        $doc.Entries.Length | Should Be 0
        $doc.Rejected.Length | Should Be 1
        $d = Decide-Hinted $doc (New-SfIdentity $SF_INST_4352) $SF_DESK1 (New-Hint 1 $SF_EHU)
        ($null -eq $d.Entry) | Should Be $true
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
    }

    It 'no selection mutates the document: the entry count and the order stay the same' {
        $before = ($staleDoc.Entries | ForEach-Object { $_.Position }) -join ','
        $staleDoc.Entries.Length | Should Be 12
        foreach ($c in $SF_CASES) {
            $null = Decide-Hinted $staleDoc (New-SfIdentity $c.Inst) $c.Desk (New-Hint $c.Num $SF_EHU)
            $null = Decide-Hinted $staleDoc (New-SfIdentity $c.Inst) $c.Desk $noMatch
            $null = Decide-Hinted $staleDoc (New-SfIdentity $c.Inst) $null $null
        }
        $staleDoc.Entries.Length | Should Be 12
        (($staleDoc.Entries | ForEach-Object { $_.Position }) -join ',') | Should BeExactly $before
    }

    It 'the 4-parameter Select and Decide reject a null document or identity like the 3-argument Select' {
        $id = New-SfIdentity $SF_INST_4352
        $threw = 0
        try { $null = Decide-Hinted $null $id $SF_DESK1 $null } catch { if ((Get-InnerException $_) -is [System.ArgumentNullException]) { $threw++ } }
        try { $null = Decide-Hinted $staleDoc $null $SF_DESK1 $null } catch { if ((Get-InnerException $_) -is [System.ArgumentNullException]) { $threw++ } }
        try { $null = Select-Hinted $null $id $SF_DESK1 $null } catch { if ((Get-InnerException $_) -is [System.ArgumentNullException]) { $threw++ } }
        try { $null = Select-Hinted $staleDoc $null $SF_DESK1 $null } catch { if ((Get-InnerException $_) -is [System.ArgumentNullException]) { $threw++ } }
        $threw | Should Be 4
    }
}

Describe 'SPEC-MON-011 AC-008 Strict matching' {
    $staleDoc = Read-Applied (New-SfStaleJson (0..11))
    $id4352 = New-SfIdentity $SF_INST_4352

    It 'hint (1, D2U) for UID4352 on D1 matches only the number of row 2 and only the serial of row 0: HintUnmatched, pick 0' {
        $d = Decide-Hinted $staleDoc $id4352 $SF_DESK1 (New-Hint 1 $SF_D2U)
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        (Get-Pos $d.Entry) | Should Be 0
    }

    It 'hint (2, EHU) for UID4352 on D1 matches only the number of row 0 and only the serial of row 2: HintUnmatched, pick 0' {
        $d = Decide-Hinted $staleDoc $id4352 $SF_DESK1 (New-Hint 2 $SF_EHU)
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        (Get-Pos $d.Entry) | Should Be 0
    }

    It 'the serial compares ordinally: a lower-case serial does not match' {
        $d = Decide-Hinted $staleDoc $id4352 $SF_DESK1 (New-Hint 1 $SF_EHU.ToLower())
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        (Get-Pos $d.Entry) | Should Be 0
    }

    It 'a document with two rows of an identical full key returns the first of them in document order' {
        $stale = New-AppliedEntryJson $SF_ID $SF_INST_4352 2 $SF_D2U $SF_DESK1
        $live = New-AppliedEntryJson $SF_ID $SF_INST_4352 1 $SF_EHU $SF_DESK1
        $doc = Read-Applied (New-AppliedDoc @($stale, $live, $live))
        $d = Decide-Hinted $doc $id4352 $SF_DESK1 (New-Hint 1 $SF_EHU)
        $d.Rule.ToString() | Should BeExactly 'LiveHint'
        (Get-Pos $d.Entry) | Should Be 1
    }

    It 'a hint with an empty serial matches only a row with an empty serial' {
        $withSerial = New-AppliedEntryJson $SF_ID $SF_INST_4352 1 $SF_EHU $SF_DESK1
        $emptySerial = New-AppliedEntryJson $SF_ID $SF_INST_4352 1 '' $SF_DESK1
        $doc = Read-Applied (New-AppliedDoc @($withSerial, $emptySerial))
        $d = Decide-Hinted $doc $id4352 $SF_DESK1 (New-Hint 1 '')
        $d.Rule.ToString() | Should BeExactly 'LiveHint'
        (Get-Pos $d.Entry) | Should Be 1
        $d = Decide-Hinted $doc $id4352 $SF_DESK1 (New-Hint 1 $SF_EHU)
        $d.Rule.ToString() | Should BeExactly 'LiveHint'
        (Get-Pos $d.Entry) | Should Be 0
        $d = Decide-Hinted $staleDoc $id4352 $SF_DESK1 (New-Hint 1 '')
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        (Get-Pos $d.Entry) | Should Be 0
    }

    It 'a row on another desktop that carries the hint pair is never selected' {
        $onlyD2 = Read-Applied (New-AppliedDoc @(New-AppliedEntryJson $SF_ID $SF_INST_4352 1 $SF_EHU $SF_DESK2))
        $d = Decide-Hinted $onlyD2 $id4352 $SF_DESK1 (New-Hint 1 $SF_EHU)
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        ($null -eq $d.Entry) | Should Be $true
    }

    It 'a row of another instance that carries the hint pair is never selected, even when it comes first' {
        $foreign = New-AppliedEntryJson $SF_ID $SF_INST_4358 2 $SF_EHU $SF_DESK1
        $own = New-AppliedEntryJson $SF_ID $SF_INST_4352 2 $SF_D2U $SF_DESK1
        $doc = Read-Applied (New-AppliedDoc @($foreign, $own))
        $d = Decide-Hinted $doc $id4352 $SF_DESK1 (New-Hint 2 $SF_EHU)
        $d.Rule.ToString() | Should BeExactly 'HintUnmatched'
        (Get-Pos $d.Entry) | Should Be 1
    }
}

# ---------------------------------------------------------------------------
# SPEC-MON-011 M2: pure log parser (REQ-LOG-001, REQ-LOG-002; AC-001..AC-004).
# LOG-REAL is copied from acceptance.md Conventions; the other lines are built
# from the same shape. Expected values are pinned here, never taken from the parser.
# ---------------------------------------------------------------------------
$LOG_TS = '[2026-10-23 18:52:16.538900] [p-24844] [t-24848] [info] '
$LOG_REAL_4358 = '[2026-10-23 18:52:16.538900] [p-24844] [t-24848] [info] Initialize layout on DEL4091_5&22cafbe4&0&UID4358_2_XPG0H42JBEHU_{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}, work area rect = 1920x1032'
$LOG_REAL_4352 = '[2026-10-23 18:52:16.552001] [p-24844] [t-24848] [info] Initialize layout on DEL4091_5&22cafbe4&0&UID4352_1_XPG0H42JBEHU_{44CD2EF4-27B1-40A7-8549-DD8033C09F8F}, work area rect = 1920x1032'

# One FancyZones "Initialize layout on" line; Number is a string so a garbled number can be built.
function New-InitLine([string]$Id, [string]$Instance, [string]$Number, [string]$Serial, [string]$Desktop) {
    '{0}Initialize layout on {1}_{2}_{3}_{4}_{5}, work area rect = 1920x1032' -f $LOG_TS, $Id, $Instance, $Number, $Serial, $Desktop
}

# Untyped parameters on purpose: a $null text must reach the parser as a real null.
function Find-Hint($Text, $Id, $Instance) {
    [TerminalOrganizer.Core.Monitors.FancyZonesLogParser]::FindNewestHint($Text, $Id, $Instance)
}

function Get-HintText($Hint) {
    if ($null -eq $Hint) { 'none' } else { '{0}|{1}' -f $Hint.Number, $Hint.Serial }
}

Describe 'SPEC-MON-011 AC-001 Parser on the real lines' {
    It 'ID-4352 yields (1, XPG0H42JBEHU) although its EDID serial is XPG0H42JBD2U, and the parser attaches no file name' {
        $text = ($LOG_REAL_4358, $LOG_REAL_4352) -join "`r`n"
        $h = Find-Hint ($text + "`r`n") $SF_ID $SF_INST_4352
        $h.Number | Should Be 1
        $h.Serial | Should BeExactly 'XPG0H42JBEHU'
        $h.SourceFileName | Should BeExactly ''
    }

    It 'ID-4358 yields (2, XPG0H42JBEHU)' {
        $text = ($LOG_REAL_4358, $LOG_REAL_4352) -join "`r`n"
        $h = Find-Hint ($text + "`r`n") $SF_ID $SF_INST_4358
        $h.Number | Should Be 2
        $h.Serial | Should BeExactly 'XPG0H42JBEHU'
    }

    It 'the result is identical with CRLF, LF only, and a last line without a terminator' {
        $lines = @($LOG_REAL_4358, $LOG_REAL_4352)
        $variants = @(
            (($lines -join "`r`n") + "`r`n"),
            (($lines -join "`r`n")),
            (($lines -join "`n") + "`n"),
            (($lines -join "`n"))
        )
        foreach ($t in $variants) {
            (Get-HintText (Find-Hint $t $SF_ID $SF_INST_4352)) | Should BeExactly '1|XPG0H42JBEHU'
            (Get-HintText (Find-Hint $t $SF_ID $SF_INST_4358)) | Should BeExactly '2|XPG0H42JBEHU'
        }
    }
}

Describe 'SPEC-MON-011 AC-002 Newest line wins, on any desktop' {
    $older = New-InitLine $SF_ID $SF_INST_4352 '2' $SF_D2U $SF_DESK1
    $newer = New-InitLine $SF_ID $SF_INST_4352 '1' $SF_EHU $SF_DESK1

    It 'the newer of two D1 lines wins' {
        (Get-HintText (Find-Hint (($older, $newer) -join "`r`n") $SF_ID $SF_INST_4352)) | Should BeExactly '1|XPG0H42JBEHU'
    }

    It 'with the two lines swapped in text order the other pair wins' {
        (Get-HintText (Find-Hint (($newer, $older) -join "`r`n") $SF_ID $SF_INST_4352)) | Should BeExactly '2|XPG0H42JBD2U'
    }

    It 'a newer line on D2 beats an older line on D1 that carries the previous process pair' {
        $newerD2 = New-InitLine $SF_ID $SF_INST_4352 '1' $SF_EHU $SF_DESK2
        (Get-HintText (Find-Hint (($older, $newerD2) -join "`r`n") $SF_ID $SF_INST_4352)) | Should BeExactly '1|XPG0H42JBEHU'
    }

    It 'the desktop is not an input of the parser: FindNewestHint takes text, monitor id and instance only' {
        $m = [TerminalOrganizer.Core.Monitors.FancyZonesLogParser].GetMethod('FindNewestHint')
        $names = @($m.GetParameters() | ForEach-Object { $_.Name })
        $names.Count | Should Be 3
        ($names -join ',').ToLower().Contains('desktop') | Should Be $false
    }
}

Describe 'SPEC-MON-011 AC-003 Instance filtering and absence' {
    $d2Only = (New-InitLine $SF_ID $SF_INST_4352 '1' $SF_EHU $SF_DESK2) + "`r`n"

    It 'ID-4352 yields the D2 line hint and ID-4358 yields no hint' {
        (Get-HintText (Find-Hint $d2Only $SF_ID $SF_INST_4352)) | Should BeExactly '1|XPG0H42JBEHU'
        (Get-HintText (Find-Hint $d2Only $SF_ID $SF_INST_4358)) | Should BeExactly 'none'
    }

    It 'lines naming another monitor id or another instance are never returned' {
        $text = ((New-InitLine 'DELA07B' $SF_INST_4352 '7' 'OTHER' $SF_DESK1), (New-InitLine $SF_ID $SF_INST_4358 '8' 'OTHER' $SF_DESK1)) -join "`r`n"
        (Get-HintText (Find-Hint $text $SF_ID $SF_INST_4352)) | Should BeExactly 'none'
    }

    It 'an id that is only a prefix of the logged id does not match' {
        $text = New-InitLine 'DEL4091X' $SF_INST_4352 '7' 'OTHER' $SF_DESK1
        (Get-HintText (Find-Hint $text 'DEL4091' $SF_INST_4352)) | Should BeExactly 'none'
    }

    It 'a newer line whose GUID suffix is not a well-formed braced GUID is ignored and the next older line is used' {
        $valid = New-InitLine $SF_ID $SF_INST_4352 '1' $SF_EHU $SF_DESK1
        foreach ($badDesk in @('{ZZZZ}', '{9089F388-5216-49EA-9CD4-07E910D817EB', '9089F388-5216-49EA-9CD4-07E910D817EB', '{9089F388-5216-49EA-9CD4-07E910D817E}')) {
            $bad = New-InitLine $SF_ID $SF_INST_4352 '2' $SF_D2U $badDesk
            (Get-HintText (Find-Hint (($valid, $bad) -join "`r`n") $SF_ID $SF_INST_4352)) | Should BeExactly '1|XPG0H42JBEHU'
        }
    }
}

Describe 'SPEC-MON-011 AC-004 Garbled and unusual lines' {
    $good = New-InitLine $SF_ID $SF_INST_4352 '1' $SF_EHU $SF_DESK1
    $garbled = @(
        @{ Name = 'a line without the GUID suffix'; Text = ($LOG_TS + 'Initialize layout on DEL4091_5&22cafbe4&0&UID4352_1_XPG0H42JBEHU, work area rect = 1920x1032') },
        @{ Name = 'a non-digit number x1'; Text = (New-InitLine $SF_ID $SF_INST_4352 'x1' $SF_EHU $SF_DESK1) },
        @{ Name = 'an int-overflowing number 99999999999'; Text = (New-InitLine $SF_ID $SF_INST_4352 '99999999999' $SF_EHU $SF_DESK1) },
        @{ Name = 'a line without the work area rect tail'; Text = ($LOG_TS + 'Initialize layout on DEL4091_5&22cafbe4&0&UID4352_1_XPG0H42JBEHU_' + $SF_DESK1) },
        @{ Name = 'a truncated last line'; Text = ($LOG_TS + 'Initialize layout on DEL4091_5&22cafbe4&0&UID4352_1_XPG0H42JBEHU_' + $SF_DESK1 + ', work ar') },
        @{ Name = 'the empty string'; Text = '' },
        @{ Name = 'null'; Text = $null },
        @{ Name = 'binary noise'; Text = (-join ([char[]](0..255))) }
    )

    foreach ($g in $garbled) {
        It ('{0} yields no hint and no exception' -f $g.Name) {
            (Get-HintText (Find-Hint $g.Text $SF_ID $SF_INST_4352)) | Should BeExactly 'none'
        }
    }

    It 'a torn last line after a valid older line leaves the older line as the hint' {
        $torn = $LOG_TS + 'Initialize layout on DEL4091_5&22cafbe4&0&UID4352_2_XPG0H42JBD2U_' + $SF_DESK1 + ', work ar'
        (Get-HintText (Find-Hint (($good, $torn) -join "`r`n") $SF_ID $SF_INST_4352)) | Should BeExactly '1|XPG0H42JBEHU'
    }

    It 'Default_Monitor_<instance>_3_S_{D1} resolves to (3, S) for the identity (Default_Monitor, instance) through prefix anchoring' {
        $text = New-InitLine 'Default_Monitor' $SF_INST_4352 '3' 'S' $SF_DESK1
        (Get-HintText (Find-Hint $text 'Default_Monitor' $SF_INST_4352)) | Should BeExactly '3|S'
    }

    It 'an empty serial (2__{D1}) yields the hint (2, empty serial)' {
        $text = New-InitLine $SF_ID $SF_INST_4352 '2' '' $SF_DESK1
        $h = Find-Hint $text $SF_ID $SF_INST_4352
        $h.Number | Should Be 2
        $h.Serial | Should BeExactly ''
    }

    It 'a serial containing an underscore (AB_CD) is preserved whole' {
        $text = New-InitLine $SF_ID $SF_INST_4352 '2' 'AB_CD' $SF_DESK1
        (Get-HintText (Find-Hint $text $SF_ID $SF_INST_4352)) | Should BeExactly '2|AB_CD'
    }
}

# ---------------------------------------------------------------------------
# SPEC-MON-011 M3: log reader (REQ-RDR-001..003; AC-009, AC-010).
# Every test builds its own folder under $env:TEMP and removes it in a finally block.
# ---------------------------------------------------------------------------
$LOG_FILLER_LINE = '[2026-10-23 00:00:00.000000] [p-1] [t-1] [info] noise ' + ('x' * 120)

# At least $Bytes bytes of CRLF-terminated lines that never match the parser.
function New-LogFiller([int]$Bytes) {
    $n = [int][math]::Ceiling($Bytes / ($LOG_FILLER_LINE.Length + 2))
    ((@($LOG_FILLER_LINE) * $n) -join "`r`n") + "`r`n"
}

function New-TempRoot {
    $p = Join-Path $env:TEMP ('mon011-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $p 'Logs'))
    $p
}

function Remove-TempRoot([string]$Root) {
    try { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# Writes Logs\<Version>\log_<Date>.log (ASCII) and returns the path.
function Add-LogFile([string]$Root, [string]$Version, [string]$Date, [string]$Text) {
    $dir = Join-Path (Join-Path $Root 'Logs') $Version
    [void][IO.Directory]::CreateDirectory($dir)
    $path = Join-Path $dir ('log_' + $Date + '.log')
    [IO.File]::WriteAllText($path, $Text, [Text.Encoding]::ASCII)
    $path
}

function Read-LogHint([string]$LogsFolder) {
    [TerminalOrganizer.Core.Monitors.FancyZonesLogReader]::Read($LogsFolder, $SF_ID, $SF_INST_4352)
}

function Get-ResultText($Result) {
    '{0}|{1}' -f $Result.Code.ToString(), (Get-HintText $Result.Hint)
}

$RDR_HINT_A = New-InitLine $SF_ID $SF_INST_4352 '1' $SF_EHU $SF_DESK1
$RDR_HINT_B = New-InitLine $SF_ID $SF_INST_4352 '2' $SF_D2U $SF_DESK2

Describe 'SPEC-MON-011 AC-009 Reader discovery and bounds' {
    It 'version folders order numerically: v0.102.2862 beats v0.99.1 for the same date, and the hint carries the winning file name' {
        $root = New-TempRoot
        try {
            $null = Add-LogFile $root 'v0.99.1' '2026-10-23' ($RDR_HINT_B + "`r`n")
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($RDR_HINT_A + "`r`n")
            $r = Read-LogHint (Join-Path $root 'Logs')
            (Get-ResultText $r) | Should BeExactly 'Found|1|XPG0H42JBEHU'
            $r.Hint.SourceFileName | Should BeExactly 'log_2026-10-23.log'
        }
        finally { Remove-TempRoot $root }
    }

    It 'day files order newest first by the date in the file name, ahead of the version folder' {
        $root = New-TempRoot
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-22' ($RDR_HINT_B + "`r`n")
            $null = Add-LogFile $root 'v0.99.1' '2026-10-23' ($RDR_HINT_A + "`r`n")
            $r = Read-LogHint (Join-Path $root 'Logs')
            (Get-ResultText $r) | Should BeExactly 'Found|1|XPG0H42JBEHU'
            $r.Hint.SourceFileName | Should BeExactly 'log_2026-10-23.log'
        }
        finally { Remove-TempRoot $root }
    }

    It 'only the 3 newest files are consulted: a hint only in the 4th newest is not found (NoMatchingLine), in the 3rd newest it is' {
        $root = New-TempRoot
        try {
            $noise = (New-LogFiller 400)
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' $noise
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-22' $noise
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-21' $noise
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-20' ($RDR_HINT_A + "`r`n")
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoMatchingLine|none'
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-21' ($RDR_HINT_A + "`r`n")
            $r = Read-LogHint (Join-Path $root 'Logs')
            (Get-ResultText $r) | Should BeExactly 'Found|1|XPG0H42JBEHU'
            $r.Hint.SourceFileName | Should BeExactly 'log_2026-10-21.log'
        }
        finally { Remove-TempRoot $root }
    }

    It 'the midnight case: a hint only in the previous-day file is found and carries that file name' {
        $root = New-TempRoot
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($LOG_FILLER_LINE + "`r`n")
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-22' ($RDR_HINT_A + "`r`n")
            $r = Read-LogHint (Join-Path $root 'Logs')
            (Get-ResultText $r) | Should BeExactly 'Found|1|XPG0H42JBEHU'
            $r.Hint.SourceFileName | Should BeExactly 'log_2026-10-22.log'
        }
        finally { Remove-TempRoot $root }
    }

    It 'the newest file that holds a hint wins even when an older file holds a different one' {
        $root = New-TempRoot
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($RDR_HINT_A + "`r`n")
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-22' ($RDR_HINT_B + "`r`n")
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'Found|1|XPG0H42JBEHU'
        }
        finally { Remove-TempRoot $root }
    }

    It 'a hint line 300 KiB before the end of the file is not found' {
        $root = New-TempRoot
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($RDR_HINT_A + "`r`n" + (New-LogFiller 307200))
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoMatchingLine|none'
        }
        finally { Remove-TempRoot $root }
    }

    It 'a hint line 200 KiB before the end of a file longer than the window is found' {
        $root = New-TempRoot
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ((New-LogFiller 102400) + $RDR_HINT_A + "`r`n" + (New-LogFiller 204800))
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'Found|1|XPG0H42JBEHU'
        }
        finally { Remove-TempRoot $root }
    }

    It 'a line straddling the start of the 262144-byte window is not parsed; the same line in a file shorter than the window is' {
        $root = New-TempRoot
        try {
            $h = $RDR_HINT_A + "`r`n"
            # window start = byte 10 of the hint line: the line is partial and dropped
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($h + ('x' * (262144 - $h.Length + 10)))
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoMatchingLine|none'
            # file shorter than the window: read from byte 0, nothing dropped
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($h + ('x' * (262144 - $h.Length - 10)))
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'Found|1|XPG0H42JBEHU'
        }
        finally { Remove-TempRoot $root }
    }
}

Describe 'SPEC-MON-011 AC-010 Reader robustness and result codes' {
    It 'a missing Logs folder is NoLogsFolder' {
        $root = New-TempRoot
        try {
            (Get-ResultText (Read-LogHint (Join-Path $root 'NoSuchLogs'))) | Should BeExactly 'NoLogsFolder|none'
            (Get-ResultText (Read-LogHint '')) | Should BeExactly 'NoLogsFolder|none'
            (Get-ResultText ([TerminalOrganizer.Core.Monitors.FancyZonesLogReader]::Read($null, $SF_ID, $SF_INST_4352))) | Should BeExactly 'NoLogsFolder|none'
        }
        finally { Remove-TempRoot $root }
    }

    It 'an existing empty Logs folder, and a version folder without any log_*.log file, are NoLogFiles' {
        $root = New-TempRoot
        try {
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoLogFiles|none'
            [void][IO.Directory]::CreateDirectory((Join-Path (Join-Path $root 'Logs') 'v0.102.2862'))
            [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $root 'Logs') 'v0.102.2862') 'readme.txt'), 'x')
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoLogFiles|none'
        }
        finally { Remove-TempRoot $root }
    }

    It 'a zero-byte log file and a log file of binary garbage are NoMatchingLine' {
        $root = New-TempRoot
        try {
            $path = Add-LogFile $root 'v0.102.2862' '2026-10-23' ''
            (Get-Item -LiteralPath $path).Length | Should Be 0
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoMatchingLine|none'
            $bytes = New-Object byte[] 4096
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 37 + 11) % 256) }
            [IO.File]::WriteAllBytes($path, $bytes)
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoMatchingLine|none'
        }
        finally { Remove-TempRoot $root }
    }

    It 'a file locked with share none as the only file is Unreadable' {
        $root = New-TempRoot
        $lock = $null
        try {
            $path = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($RDR_HINT_A + "`r`n")
            $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'Unreadable|none'
        }
        finally {
            if ($lock -ne $null) { $lock.Dispose() }
            Remove-TempRoot $root
        }
    }

    It 'a locked newest file plus a readable older file without a matching line is NoMatchingLine' {
        $root = New-TempRoot
        $lock = $null
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-22' ($LOG_FILLER_LINE + "`r`n")
            $path = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($RDR_HINT_A + "`r`n")
            $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            (Get-ResultText (Read-LogHint (Join-Path $root 'Logs'))) | Should BeExactly 'NoMatchingLine|none'
        }
        finally {
            if ($lock -ne $null) { $lock.Dispose() }
            Remove-TempRoot $root
        }
    }

    It 'a locked newest file plus a readable older file that holds a matching line is Found with the older file name' {
        $root = New-TempRoot
        $lock = $null
        try {
            $null = Add-LogFile $root 'v0.102.2862' '2026-10-22' ($RDR_HINT_B + "`r`n")
            $path = Add-LogFile $root 'v0.102.2862' '2026-10-23' ($RDR_HINT_A + "`r`n")
            $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $r = Read-LogHint (Join-Path $root 'Logs')
            (Get-ResultText $r) | Should BeExactly 'Found|2|XPG0H42JBD2U'
            $r.Hint.SourceFileName | Should BeExactly 'log_2026-10-22.log'
        }
        finally {
            if ($lock -ne $null) { $lock.Dispose() }
            Remove-TempRoot $root
        }
    }

    It 'a file the test holds open for writing with shared read and write access (the way FancyZones holds it) is read normally' {
        $root = New-TempRoot
        $writer = $null
        try {
            $dir = Join-Path (Join-Path $root 'Logs') 'v0.102.2862'
            [void][IO.Directory]::CreateDirectory($dir)
            $path = Join-Path $dir 'log_2026-10-23.log'
            $writer = New-Object IO.FileStream -ArgumentList $path, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::ReadWrite)
            $bytes = [Text.Encoding]::ASCII.GetBytes($RDR_HINT_A + "`r`n")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            $r = Read-LogHint (Join-Path $root 'Logs')
            (Get-ResultText $r) | Should BeExactly 'Found|1|XPG0H42JBEHU'
            $r.Hint.SourceFileName | Should BeExactly 'log_2026-10-23.log'
        }
        finally {
            if ($writer -ne $null) { $writer.Dispose() }
            Remove-TempRoot $root
        }
    }
}

# ---------------------------------------------------------------------------
# SPEC-MON-011 AC-015 / NFR-2 standing purity guards (sync-audit F1), in the style of Rules.Tests.ps1
# 'AC-010 No user-visible change'. The resolver file's own watcher/timer ban is pinned in App.Tests.ps1.
# ---------------------------------------------------------------------------
Describe 'SPEC-MON-011 AC-015 Purity guards' {
    $monitorsDir = Join-Path $repoRoot 'src\TerminalOrganizer.Core\Monitors'

    It 'the log parser and the selector read no file, clock or environment value' {
        foreach ($name in @('FancyZonesLogParser.cs', 'AppliedEntrySelector.cs')) {
            $text = [IO.File]::ReadAllText((Join-Path $monitorsDir $name))
            foreach ($forbidden in @('System.IO', 'DateTime', 'Environment.')) {
                $text.Contains($forbidden) | Should Be $false
            }
        }
    }

    It 'the log reader reads no clock, file time or environment value (System.IO is allowed there)' {
        $text = [IO.File]::ReadAllText((Join-Path $monitorsDir 'FancyZonesLogReader.cs'))
        foreach ($forbidden in @('DateTime', 'Stopwatch', 'Environment.', 'LastWriteTime', 'CreationTime')) {
            $text.Contains($forbidden) | Should Be $false
        }
    }

    It 'the parser, the selector and the reader hold no watcher, timer, stopwatch or user prompt' {
        foreach ($name in @('FancyZonesLogParser.cs', 'AppliedEntrySelector.cs', 'FancyZonesLogReader.cs')) {
            $text = [IO.File]::ReadAllText((Join-Path $monitorsDir $name))
            foreach ($forbidden in @('FileSystemWatcher', 'Timer', 'Stopwatch', 'AskUserQuestion')) {
                $text.Contains($forbidden) | Should Be $false
            }
        }
    }
}

# ---------------------------------------------------------------------------
# SPEC-MON-011 M5: dump-monitors tool (REQ-TOOL-001; AC-014).
# -SelfTest asserts the specific values (inputs pinned inside the tool); a live run on a
# real machine asserts line structure and the exit code only, because the machine's own
# monitors can match the SF-STALE fixture rows.
# ---------------------------------------------------------------------------
function Invoke-DumpTool([string[]]$ToolArgs) {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $dump = Join-Path $repoRoot 'tools\dump-monitors.ps1'
    $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $dump @ToolArgs
    New-Object psobject -Property @{ Code = $LASTEXITCODE; Lines = @($out | ForEach-Object { [string]$_ }) }
}

Describe 'SPEC-MON-011 AC-014 dump-monitors tool' {
    It '-SelfTest exits 0 with no FAIL; the parser, the six hinted-selection rows and the line-format row pass' {
        $r = Invoke-DumpTool @('-SelfTest')
        $r.Code | Should Be 0
        @($r.Lines | Where-Object { $_ -like 'FAIL: *' }).Count | Should Be 0
        foreach ($name in @('mon011/parser-UID4352', 'mon011/parser-UID4358', 'mon011/line-format',
                'mon011/hinted-UID4352-D1', 'mon011/hinted-UID4352-D2', 'mon011/hinted-UID4352-D3',
                'mon011/hinted-UID4358-D1', 'mon011/hinted-UID4358-D2', 'mon011/hinted-UID4358-D3')) {
            @($r.Lines | Where-Object { $_ -ceq ('PASS: ' + $name) }).Count | Should Be 1
        }
    }

    It '-SelfTest prints the four pinned lines for the SF-STALE decision of ID-4352 on D1 with the hint (1, XPG0H42JBEHU) from log_2026-10-23.log' {
        $r = Invoke-DumpTool @('-SelfTest')
        foreach ($line in @('  live-hint: 1 XPG0H42JBEHU (log_2026-10-23.log)', '  document-order: position 0 (2, XPG0H42JBD2U)',
                '  hinted: position 2 (1, XPG0H42JBEHU)', '  decided by: LiveHint')) {
            @($r.Lines | Where-Object { $_ -ceq $line }).Count | Should Be 1
        }
    }

    It 'live mode with a nonexistent -FancyZonesLogs folder exits 0 and prints the four lines once per monitor block, structure only' {
        $applied = Join-Path $fixtures 'synthetic-applied-stale-live.json'
        $missing = Join-Path $env:TEMP ('mon011-nologs-' + [Guid]::NewGuid().ToString('N'))
        $r = Invoke-DumpTool @('-FancyZonesLogs', $missing, '-AppliedLayouts', $applied)
        $r.Code | Should Be 0
        $blocks = @($r.Lines | Where-Object { $_ -match '^monitor #' }).Count
        @($r.Lines | Where-Object { $_ -match '^  live-hint: none \(NoLogsFolder\)$' }).Count | Should Be $blocks
        @($r.Lines | Where-Object { $_ -match '^  document-order: (no-match|position \d+ \(\d+, .*\))$' }).Count | Should Be $blocks
        @($r.Lines | Where-Object { $_ -match '^  hinted: (no-match|position \d+ \(\d+, .*\))$' }).Count | Should Be $blocks
        @($r.Lines | Where-Object { $_ -match '^  decided by: DocumentOrder$' }).Count | Should Be $blocks
        $docOrder = @($r.Lines | Where-Object { $_ -like '  document-order: *' } | ForEach-Object { $_.Substring('  document-order: '.Length) })
        $hinted = @($r.Lines | Where-Object { $_ -like '  hinted: *' } | ForEach-Object { $_.Substring('  hinted: '.Length) })
        $docOrder.Count | Should Be $hinted.Count
        for ($i = 0; $i -lt $docOrder.Count; $i++) { $hinted[$i] | Should BeExactly $docOrder[$i] }
    }

    It 'live mode with an existing empty -FancyZonesLogs folder prints live-hint: none (NoLogFiles) in every block and exits 0' {
        $applied = Join-Path $fixtures 'synthetic-applied-stale-live.json'
        $empty = Join-Path $env:TEMP ('mon011-emptylogs-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($empty)
        try {
            $r = Invoke-DumpTool @('-FancyZonesLogs', $empty, '-AppliedLayouts', $applied)
            $r.Code | Should Be 0
            $blocks = @($r.Lines | Where-Object { $_ -match '^monitor #' }).Count
            @($r.Lines | Where-Object { $_ -match '^  live-hint: none \(NoLogFiles\)$' }).Count | Should Be $blocks
        }
        finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
