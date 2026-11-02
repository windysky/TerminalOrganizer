# SPEC-TRAY-016 M3 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-009/AC-010/AC-011 and plan.md section J,
# never from the code under test. This file is the only NEW test file of milestone
# M3; no pinned suite is touched. The WinForms panel itself never runs under Pester
# (A3): the panel rows are source assertions over src\TerminalOrganizer.App\
# AttentionMessagePanel.cs / AttentionOverlay.cs / AttentionController.cs in the
# MenuIa source-scan idiom; the pure geometry (AttentionMessageLayout /
# AttentionMessageText) is exercised for real from the Core dll.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

$script:OverlayCsPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'
$script:PanelCsPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionMessagePanel.cs'
$script:ControllerCsPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionController.cs'

function Read-Source([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ('source file not found: ' + $Path)
    }
    return [IO.File]::ReadAllText($Path)
}

function Get-RingFormBody {
    # The ring form class is the last class in AttentionOverlay.cs: from its
    # declaration to end-of-file. M3's seam edit lives in the factory above it,
    # so this body must stay free of panel code (the D3 net rows below pin it).
    $src = Read-Source $script:OverlayCsPath
    $i = $src.IndexOf('internal sealed class AttentionOverlayForm')
    if ($i -lt 0) { throw 'AttentionOverlayForm declaration not found' }
    return $src.Substring($i)
}

function Get-LiveRectDelegates {
    # The three (IntPtr target, int[] rect) delegates of the production Live
    # factory, in order: create, restart, tick. Both the opener and the closer are
    # anchored at the delegate indent (16 spaces) so nested braces never end a
    # capture early and the constructor's inline one-line no-op delegates
    # (mid-line "?? delegate(...) { };") never match.
    $src = Read-Source $script:OverlayCsPath
    $pattern = '\n {16}delegate\(IntPtr target, int\[\] rect\)\s*\{(.*?)\n {16}\},'
    $found = [regex]::Matches($src, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    $bodies = @()
    foreach ($m in $found) { $bodies += ,$m.Groups[1].Value }
    return ,$bodies
}

function Get-LiveHandleDelegates {
    # The two (IntPtr target) delegates of the production Live factory, in order:
    # stop, hide. Same 16-space opener/closer anchoring as Get-LiveRectDelegates
    # (the constructor's inline no-op delegates must not match).
    $src = Read-Source $script:OverlayCsPath
    $pattern = '\n {16}delegate\(IntPtr target\)\s*\{(.*?)\n {16}\},'
    $found = [regex]::Matches($src, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    $bodies = @()
    foreach ($m in $found) { $bodies += ,$m.Groups[1].Value }
    return ,$bodies
}

Describe 'AC-009 message layout and truncation' {
    It 'Prepare renders a 600-character message verbatim' {
        $m = 'x' * 600
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageText]::Prepare($m)
        $r.Length | Should Be 600
        $r | Should Be $m
    }

    It 'Prepare truncates a 700-character message to 597 characters plus one ellipsis' {
        $m = 'y' * 700
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageText]::Prepare($m)
        $r.Length | Should Be 598
        $r.StartsWith($m.Substring(0, 597)) | Should Be $true
        $r[597] | Should Be ([char]0x2026)
    }

    It 'Prepare passes null and empty through unchanged' {
        $nullResult = [TerminalOrganizer.Core.Attention.AttentionMessageText]::Prepare($null)
        $nullResult | Should BeNullOrEmpty
        $empty = [TerminalOrganizer.Core.Attention.AttentionMessageText]::Prepare('')
        $empty.Length | Should Be 0
    }

    It 'IsRenderable is false for absent, null, and whitespace-only messages and true for text' {
        $t = [TerminalOrganizer.Core.Attention.AttentionMessageText]
        $t::IsRenderable($null) | Should Be $false
        $t::IsRenderable('') | Should Be $false
        $t::IsRenderable('   ') | Should Be $false
        $t::IsRenderable("`t `r`n ") | Should Be $false
        $t::IsRenderable('hooks done') | Should Be $true
    }

    It 'PlacePanel places the card below the target, one ring thickness (6 px) under the bottom edge' {
        # AC-009 below placement: x=L, y=B+RingThicknessPx(6), width=R-L,
        # height=textHeight+2*MessagePaddingPx(10). 606+62=668 stays inside 1040.
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 200, 500, 600), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 100
        $r[1] | Should Be 606
        $r[2] | Should Be 400
        $r[3] | Should Be 62
    }

    It 'PlacePanel falls back inside-bottom when the work area ends below and the right column is too narrow (t11)' {
        # t11 (2026-11-01 UX round): the flip-above branch is REPLACED. Below would be
        # y=1030+6=1036 with bottom 1098 > 1040; the right column is 400/2=200 <
        # MessageMinColumnPx(280), so the card lands INSIDE-BOTTOM instead:
        # y = B-RingThicknessPx-height = 1030-6-62 = 962, full target width.
        # (Supersedes the M3 flip expectation 832 - same scenario inputs, new rule.)
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 900, 500, 1030), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 100
        $r[1] | Should Be 962
        $r[2] | Should Be 400
        $r[3] | Should Be 62
    }

    It 'PlacePanel no longer flips above: the old clamp scenario lands inside-bottom too (t11)' {
        # t11: the pre-fix flip would have landed at 20-6-62 = -48 (clamped to 0); with
        # the inside-right rule the narrow column (200 < 280) falls back inside-bottom:
        # y = 1030-6-62 = 962. (Supersedes the M3 clamp expectation 0 - same inputs.)
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 20, 500, 1030), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 100
        $r[1] | Should Be 962
        $r[2] | Should Be 400
        $r[3] | Should Be 62
    }

    It 'PlacePanel degrades null or short inputs to zeros' {
        $r1 = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel($null, @(0, 0, 1920, 1040), 380, 42)
        $r1 -join ',' | Should Be '0,0,0,0'
        $r2 = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 200, 500, 600), @(0, 0), 380, 42)
        $r2 -join ',' | Should Be '0,0,0,0'
    }

    It 'pins the section-J pixel constants (600, 14, 10, 3, 16)' {
        $c = [TerminalOrganizer.Core.Attention.AttentionConstants]
        $c::MessageMaxChars | Should Be 600
        $c::MessageFontPx | Should Be 14
        $c::MessagePaddingPx | Should Be 10
        $c::MessageAccentPx | Should Be 3
        $c::MessageCloseSizePx | Should Be 16
    }

    It 'pins the section-J color constants (panel 0x1E1E1E, text 0xEEEEEE)' {
        $c = [TerminalOrganizer.Core.Attention.AttentionConstants]
        $c::MessagePanelBackRgb | Should Be 0x1E1E1E
        $c::MessageTextRgb | Should Be 0xEEEEEE
    }
}

Describe 'AC-010 panel lifecycle, interaction model, ring purity' {
    # --- AM-6 interaction model: the panel source (AttentionMessagePanel.cs) ---

    It 'panel carries WS_EX_TOOLWINDOW (0x00000080)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('0x00000080') | Should Be $true
    }

    It 'panel drops the ring WS_EX_NOACTIVATE (0x08000000) and WS_EX_TRANSPARENT (0x00000020)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('0x08000000') | Should Be $false
        $src.Contains('0x00000020') | Should Be $false
    }

    It 'panel shows through SW_SHOWNOACTIVATE at creation (never steals focus)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('SwShownoactivate') | Should Be $true
        $src.Contains('ShowWindow') | Should Be $true
    }

    It 'panel has NO ShowWithoutActivation override (activation on click is the point)' {
        # The pin is the override DECLARATION (the ring form's no-activate-on-show
        # hook must not exist on the panel); the source may NAME the member in its
        # documentation without overriding it.
        $src = Read-Source $script:PanelCsPath
        $src -match 'protected\s+override\s+bool\s+ShowWithoutActivation' | Should Be $false
    }

    It 'panel text is a read-only selectable TextBox (ReadOnly, borderless, multiline)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('ReadOnly = true') | Should Be $true
        $src.Contains('BorderStyle.None') | Should Be $true
        $src.Contains('Multiline = true') | Should Be $true
    }

    It 'close affordance is sized by MessageCloseSizePx and dismisses the panel only (no ring reference)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('MessageCloseSizePx') | Should Be $true
        # Panel-only dismissal made structural: the panel source cannot reach the ring.
        $src.Contains('AttentionOverlayForm') | Should Be $false
    }

    It 'panel never queries foreground focus (ask-kind stop polls the TARGET handle)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('GetForeground') | Should Be $false
    }

    It 'panel positions only through SetWindowPos with SWP_NOACTIVATE (NFR-7)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('SetWindowPos') | Should Be $true
        $src.Contains('SwpNoactivate') | Should Be $true
    }

    # --- panel lifecycle twins: the collection seam (AttentionOverlay.cs Live factory) ---

    It 'Create twin: a panel is created only when the signal message is renderable' {
        $b = Get-LiveRectDelegates
        $b.Count | Should Be 3
        $b[0].Contains('IsRenderable(panelMessage)') | Should Be $true
        $b[0].Contains('ShowPanel(') | Should Be $true
    }

    It 'Restart twin: the panel is re-measured and re-placed on restart' {
        $b = Get-LiveRectDelegates
        $b[1].Contains('RestartPanel(') | Should Be $true
    }

    It 'Tick twin: the blink Tick never touches panel visibility (ring toggle only)' {
        $b = Get-LiveRectDelegates
        $tick = $b[2]
        $tick.Contains('form.Tick(rect);') | Should Be $true
        # The panel is not a target of the ring's toggle: no visibility mutation may
        # appear here. The single permitted contact is the desktop-gate RESTORE
        # (RestoreIfDesktopHidden), a steady-state no-op that is never a toggle.
        $tick -match 'panel\.(ShowPanel|HidePanel|RestartPanel|ClosePanel|Close|Dispose|Show|Hide|Visible)' | Should Be $false
        $tick.Contains('RestoreIfDesktopHidden') | Should Be $true
    }

    It 'Stop twin: the panel dies with the overlay (Close and Dispose)' {
        $h = Get-LiveHandleDelegates
        $h.Count | Should Be 2
        $h[0].Contains('panel.Close();') | Should Be $true
        $h[0].Contains('panel.Dispose();') | Should Be $true
    }

    It 'Hide twin: the off-desktop gate hides the panel too' {
        $h = Get-LiveHandleDelegates
        $h[1].Contains('HidePanel()') | Should Be $true
    }

    It 'controller publishes the consumed signal message to the seam (SetPanelMessage)' {
        $src = Read-Source $script:ControllerCsPath
        $src.Contains('overlays.SetPanelMessage(') | Should Be $true
    }

    # --- ring purity net (D3): the ring form body must be untouched by M3 ---

    It 'ring purity: the TransparencyKey assignment is intact' {
        $ring = Get-RingFormBody
        $ring.Contains('TransparencyKey = key') | Should Be $true
    }

    It 'ring purity: the four FillRectangle bars are intact' {
        $ring = Get-RingFormBody
        ([regex]::Matches($ring, 'FillRectangle')).Count | Should Be 4
    }

    It 'ring purity: the Tick visibility-toggle blink is intact' {
        $ring = Get-RingFormBody
        $ring.Contains('ringOn = !ringOn') | Should Be $true
    }

    It 'ring purity: the ring keeps its three pinned ex-styles (NOACTIVATE, TOOLWINDOW, TRANSPARENT)' {
        $ring = Get-RingFormBody
        $ring.Contains('0x08000000 | 0x00000080 | 0x00000020') | Should Be $true
    }

    It 'ring purity: the ring form contains no panel code' {
        $ring = Get-RingFormBody
        $ring.Contains('Panel') | Should Be $false
        $ring.Contains('panel') | Should Be $false
    }
}

Describe 't10 hidden arrival: no wrong-desktop create/restart flash (2026-11-01 UX round)' {
    # The 2026-11-01 live-session fix t10: a signal arriving while the target sits on
    # ANOTHER virtual desktop used to flash the ring once on the current desktop
    # (the production factory created/restarted the overlay shown, and the first
    # BlinkTick's desktop gate hid it only ~500 ms later). The create-hidden seam:
    # the Live factory consults the desktop source AT ARRIVAL and births the overlay
    # hidden; the tick's existing desktop gate reveals it on the first on-desktop
    # tick (the hide-but-keep-alive semantics reused at birth).

    It 'Live create twin branches on the arrival desktop (shown vs SeedHidden/ShowPanelHidden)' {
        $b = Get-LiveRectDelegates
        $b.Count | Should Be 3
        $b[0].Contains('ShowNoActivate()') | Should Be $true
        $b[0].Contains('SeedHidden(') | Should Be $true
        $b[0].Contains('ShowPanelHidden(') | Should Be $true
    }

    It 'Live restart twin keeps an off-desktop restart hidden (RestartHidden/RestartPanelHidden)' {
        $b = Get-LiveRectDelegates
        $b[1].Contains('RestartHidden(') | Should Be $true
        $b[1].Contains('RestartPanelHidden(') | Should Be $true
    }

    It 'the Live factory consults the virtual-desktop source at arrival (fail-open gate)' {
        $src = Read-Source $script:OverlayCsPath
        $src.Contains('IsWindowOnCurrentVirtualDesktop') | Should Be $true
        $src.Contains('TargetOnCurrentDesktop') | Should Be $true
    }

    It 'the ring form seeds the hidden birth (ringOn false so the first on-desktop tick shows)' {
        $ring = Get-RingFormBody
        $ring.Contains('SeedHidden') | Should Be $true
    }

    It 'the panel form carries the hidden-birth twins' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('ShowPanelHidden') | Should Be $true
        $src.Contains('RestartPanelHidden') | Should Be $true
    }

    It 'production wiring passes the desktop reader into the Live factory' {
        # Case-sensitive: the shared lowercase-d reader variable, distinct from the
        # VirtualDesktopReader type name the wiring already constructs.
        $src = Read-Source $script:ControllerCsPath
        $src -cmatch 'Live\([\s\S]*?desktopReader' | Should Be $true
    }
}

Describe 't11 inside-right placement: the message card never covers the title band (2026-11-01 UX round)' {
    # The 2026-11-01 live-session fix t11: when the below placement would cross the
    # work-area bottom (a maximized target), the old flip-above branch is REPLACED by
    # inside-right placement - the card docks to the target's right edge starting
    # MessageTopInsetPx below its top (below the title bar / tab strip), as wide as
    # the preferred text width capped at half the target; a right column narrower
    # than MessageMinColumnPx falls back INSIDE-BOTTOM (full width, one ring
    # thickness above the bottom edge).

    It 'fit-below boundary: y+height exactly at the work-area bottom still places below' {
        # 972+6=978; 978+62=1040 == workArea bottom -> fits (strictly-greater crosses).
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 500, 500, 972), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 100
        $r[1] | Should Be 978
        $r[2] | Should Be 400
        $r[3] | Should Be 62
    }

    It 'inside-right: the card docks to the right edge, width capped at half the target' {
        # Below would cross (1036+62=1098 > 1040); column 700/2=350 >= 280;
        # preferred 380+2*10=400 -> capped to 350; x=800-350=450, y=200+40=240.
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 200, 800, 1030), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 450
        $r[1] | Should Be 240
        $r[2] | Should Be 350
        $r[3] | Should Be 62
    }

    It 'inside-right: a preferred width narrower than the column keeps the preferred width' {
        # preferred 200+2*10=220 < 350 -> panelWidth 220; x=800-220=580.
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 200, 800, 1030), @(0, 0, 1920, 1040), 200, 42)
        $r[0] | Should Be 580
        $r[1] | Should Be 240
        $r[2] | Should Be 220
        $r[3] | Should Be 62
    }

    It 'column boundary: exactly MessageMinColumnPx (280) stays inside-right' {
        # width 560 -> column 280 == 280 (>= holds); preferred 400 -> capped to 280;
        # x=560-280=280, y=100+40=140.
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(0, 100, 560, 1030), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 280
        $r[1] | Should Be 140
        $r[2] | Should Be 280
        $r[3] | Should Be 62
    }

    It 'column boundary: 279 (width 558) falls back inside-bottom' {
        # column 279 < 280 -> y = 1030-6-62 = 962, full width 558.
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(0, 100, 558, 1030), @(0, 0, 1920, 1040), 380, 42)
        $r[0] | Should Be 0
        $r[1] | Should Be 962
        $r[2] | Should Be 558
        $r[3] | Should Be 62
    }

    It 'title-never-covered invariants: the card starts below the inset and stays inside the right edge' {
        $c = [TerminalOrganizer.Core.Attention.AttentionConstants]
        $r = [TerminalOrganizer.Core.Attention.AttentionMessageLayout]::PlacePanel(@(100, 200, 800, 1030), @(0, 0, 1920, 1040), 380, 42)
        # The title bar / tab strip band [top, top+inset) is never overlapped...
        ($r[1] - 200) -ge $c::MessageTopInsetPx | Should Be $true
        # ...and the card never extends past the target's right edge (nor before its left).
        $r[0] -ge 100 | Should Be $true
        ($r[0] + $r[2]) -le 800 | Should Be $true
    }

    It 'pins the t11 section constants (MessageTopInsetPx 40, MessageMinColumnPx 280)' {
        $c = [TerminalOrganizer.Core.Attention.AttentionConstants]
        $c::MessageTopInsetPx | Should Be 40
        $c::MessageMinColumnPx | Should Be 280
    }
}

Describe 't13 kind-styled centered text: ask red, info amber, default near-white (2026-11-01 UX round)' {
    # The 2026-11-01 live-session fix t13: the panel text is CENTER-aligned and its
    # color follows the signal kind, carried over the extended panel-message seam
    # (the controller publishes the kind beside the message; the panel resolves the
    # color through the pure AttentionMessageStyle mapper).

    It 'kind ask renders red (MessageAskTextRgb)' {
        $s = [TerminalOrganizer.Core.Attention.AttentionMessageStyle]
        $s::TextColorRgbForKind('ask') | Should Be 0xE5484D
    }

    It 'kind info renders the ring amber (RingColorRgb)' {
        $s = [TerminalOrganizer.Core.Attention.AttentionMessageStyle]
        $s::TextColorRgbForKind('info') | Should Be 0xFFBF00
    }

    It 'kinds stop, absent, and unknown degrade to the near-white default' {
        $s = [TerminalOrganizer.Core.Attention.AttentionMessageStyle]
        $s::TextColorRgbForKind('stop') | Should Be 0xEEEEEE
        $s::TextColorRgbForKind($null) | Should Be 0xEEEEEE
        $s::TextColorRgbForKind('future-kind') | Should Be 0xEEEEEE
    }

    It 'pins the t13 ask color constant (MessageAskTextRgb 0xE5484D)' {
        $c = [TerminalOrganizer.Core.Attention.AttentionConstants]
        $c::MessageAskTextRgb | Should Be 0xE5484D
    }

    It 'panel text is center-aligned' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('TextAlign = HorizontalAlignment.Center') | Should Be $true
    }

    It 'panel resolves the text color through the pure kind mapper' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('TextColorRgbForKind') | Should Be $true
    }

    It 'controller publishes the kind on the panel seam (SetPanelKind)' {
        $src = Read-Source $script:ControllerCsPath
        $src.Contains('overlays.SetPanelKind(') | Should Be $true
    }

    It 'the factory carries the kind seam to the panel twins' {
        $src = Read-Source $script:OverlayCsPath
        $src.Contains('SetPanelKind') | Should Be $true
    }
}
