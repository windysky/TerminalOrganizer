# SPEC-TRAY-018 M1 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from spec.md AC-002 and plan.md A-3, never from the code
# under test. This file is the only NEW test file of milestone M1; no pinned
# suite is touched (era discipline, spec C2). The Pester suite cannot assert
# true Win32 visibility (spec 2.2) - the LIVE AC (AC-005) is the binding visual
# acceptance. Every row here is a source pin over src\TerminalOrganizer.App\
# AttentionMessagePanel.cs / AttentionOverlay.cs in the MenuIa source-scan
# idiom; no assembly load is needed.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here

$script:PanelCsPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionMessagePanel.cs'
$script:OverlayCsPath = Join-Path $repoRoot 'src\TerminalOrganizer.App\AttentionOverlay.cs'

function Read-Source([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ('source file not found: ' + $Path)
    }
    return [IO.File]::ReadAllText($Path)
}

function Get-FlagOnlyHelperBody([string]$Name) {
    # The private flag-only reposition helpers (private void ShowWindowNoActivate() /
    # HideWindowNoActivate()): capture from the method declaration to its closing
    # brace at the same 8-space member indent.
    $src = Read-Source $script:PanelCsPath
    $pattern = '\n {8}private void ' + $Name + '\(\)\s*\{(.*?)\n {8}\}'
    $m = [regex]::Match($src, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { throw ('flag-only helper not found: ' + $Name) }
    return $m.Groups[1].Value
}

Describe 'AC-002 panel z-order fix: neighbor-derived insertAfter (SPEC-TRAY-018 D-2)' {
    # Root cause (spec 1.4, probe-proven three times): SetWindowPos(hWnd, hWndInsertAfter)
    # places the positioned window DIRECTLY BELOW hWndInsertAfter, so the panel's
    # insertAfter=target call stacked the card behind the target terminal. The fix
    # derives insertAfter from the window directly ABOVE the target (GW_HWNDPREV).

    It 'sizing call threads the above-target selector and keeps SwpNoactivate' {
        $src = Read-Source $script:PanelCsPath
        ($src -match 'Native\.SetWindowPos\(Handle, AboveTargetInsertAfter\(topmostMode, target\),\s*\r?\n\s*place\[0\], place\[1\], place\[2\], place\[3\], \(uint\)SwpNoactivate\)') | Should Be $true
    }

    It 'the selector reads the window directly above the target (GetWindow GW_HWNDPREV)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('GetWindow(target, GwHwndPrev)') | Should Be $true
        $src.Contains('GwHwndPrev = 3') | Should Be $true
        $src.Contains('[DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetWindow(IntPtr window, uint command);') | Should Be $true
    }

    It 'topmost mode keeps the above-everything sentinel path (InsertAfterFor(true, target))' {
        # REQ-ZUL-003: the topmost branch threads InsertAfterFor(true, target) rather
        # than naming the sentinel, preserving the AttentionOptions count pins.
        $src = Read-Source $script:PanelCsPath
        $src.Contains('AttentionOverlayGeometry.InsertAfterFor(true, target)') | Should Be $true
    }

    It 'the old insertAfter=target sizing call is gone' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('AttentionOverlayGeometry.InsertAfterFor(topmostMode, target)') | Should Be $false
    }

    It 'both flag-only helpers are z-neutral (SwpNozorder)' {
        # D-3: ShowWindowNoActivate / HideWindowNoActivate gain SWP_NOZORDER so no
        # restart-show, desktop-gate hide/restore, or close path changes z-order.
        $show = Get-FlagOnlyHelperBody 'ShowWindowNoActivate'
        $hide = Get-FlagOnlyHelperBody 'HideWindowNoActivate'
        $show.Contains('SwpNozorder') | Should Be $true
        $hide.Contains('SwpNozorder') | Should Be $true
    }
}

Describe 'AC-002 nets: NFR-7 and ring non-regression mirror' {
    It 'every panel Native.SetWindowPos call carries SWP_NOACTIVATE (NFR-7 net)' {
        # Call granularity, not line granularity: the panel's calls span two lines
        # (args on the second), so each full call is extracted and checked.
        $src = Read-Source $script:PanelCsPath
        $calls = [regex]::Matches($src, 'Native\.SetWindowPos\([^;]*?\);', [Text.RegularExpressions.RegexOptions]::Singleline)
        $calls.Count | Should Be 3
        $bad = @($calls | Where-Object { -not ($_.Value -match '(?i)SWP_NOACTIVATE|SwpNoactivate') })
        $bad.Count | Should Be 0
    }

    It 'ring mirror: the overlay file keeps exactly two AboveAllInsertAfter lines' {
        # AttentionOverlay.cs is byte-stable (D-4 / AC-004); these rows mirror the
        # AttentionOptions count pins so a stray overlay edit fails HERE too.
        $lines = [IO.File]::ReadAllLines($script:OverlayCsPath)
        (@($lines | Where-Object { $_.Contains('AboveAllInsertAfter') })).Count | Should Be 2
    }

    It 'ring mirror: the overlay file keeps exactly one Native.SetWindowPos call line' {
        $lines = [IO.File]::ReadAllLines($script:OverlayCsPath)
        (@($lines | Where-Object { $_.Contains('Native.SetWindowPos(') })).Count | Should Be 1
    }
}

Describe 'M2b child-handle contingency: the text surface gets a native handle (SPEC-TRAY-018)' {
    # Probes .moai/state/verify/tray018-M1-m2bprobe{,2,3,4}.log: the hidden-birth
    # restore shows the card with NO TextBox child HWND (probe2: GW_CHILD=0 after
    # the flag-only show); Form.CreateControl() no-ops while the form is
    # WinForms-invisible (probe3), so the plan's example mechanism cannot fix it;
    # forcing text.Handle creates a WS_VISIBLE child that renders after the
    # flag-only show (probe4). The pin is the WORKING mechanism.
    It 'panel forces the TextBox child handle after placement (not CreateControl)' {
        $src = Read-Source $script:PanelCsPath
        $src.Contains('GC.KeepAlive(text.Handle)') | Should Be $true
        # Code shape, not comment prose (plan B-pester34): an actual CreateControl()
        # call statement must not exist - it no-ops while the form is hidden.
        @([IO.File]::ReadAllLines($script:PanelCsPath) | Where-Object { $_ -match '^\s*CreateControl\(\);' }).Count | Should Be 0
    }
}
