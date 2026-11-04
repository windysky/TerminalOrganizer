# SPEC-TRAY-016 M2 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-004..AC-008 and plan.md section J,
# never from the code under test. This file is the only NEW test file of milestone
# M2; the only other test changes are the three AM-4 numeral rows re-based 17->18
# (MenuIa.Tests.ps1:453-454, MenuSettings.Tests.ps1:196, MenuStayOpen.Tests.ps1:302
# per the Decision Point 1 election). Every other suite stays unedited.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
# The App assembly handle is taken from a resolved type so reflection targets the same
# instance another suite byte-loaded first.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))
$script:KindAppAsm = [TerminalOrganizer.App.SettingsStore].Assembly

# --- settings fixtures ---

# AC-008: the carry base - all FIVE attention values set distinctively (enable false,
# policy notifications, limit 5, topmost true, info seconds 42) plus the non-attention
# fields a manager/overflow save must keep.
$script:KindCarryBase = '{"hotkey":"Ctrl+Alt+T","logPath":"C:\\kind\\log.txt","managerWindowName":"X","mergeEnabled":true,"overflowPolicy":"Stack","schemaVersion":3,"attentionOverlay":false,"attentionEventPolicy":"notifications","attentionStopBlinkLimit":5,"attentionOverlayTopmost":true,"attentionInfoVisibleSeconds":42}'

function New-KindSettingsScratch([string]$Content) {
    $dir = Join-Path $here ('scratch-kind-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    if ($null -ne $Content) {
        [IO.File]::WriteAllText($path, $Content)
    }
    return $path
}

function Get-KindShellMethod([string]$Name) {
    $shell = $script:KindAppAsm.GetType('TerminalOrganizer.App.TrayShell', $true)
    $shell.GetMethod($Name, [Reflection.BindingFlags]'NonPublic,Static')
}

function Read-KindAttention($Path) {
    $s = ([TerminalOrganizer.App.SettingsStore]::new($Path)).Load()
    return @{ Enable = $s.AttentionOverlay; Policy = $s.AttentionEventPolicy
        Limit = $s.AttentionStopBlinkLimit; Topmost = $s.AttentionOverlayTopmost
        Info = $s.AttentionInfoVisibleSeconds }
}

# --- controller fixtures (the AttentionOptions rig shape) ---

function New-KindSignal([string]$Event, [string]$Needle, [string]$Kind = $null) {
    $signal = New-Object TerminalOrganizer.Core.Attention.AttentionSignal
    $signal.Version = 1
    $signal.Event = $Event
    $signal.Needle = $Needle
    # A [string]-typed default of $null arrives as '' (PowerShell coercion), so the
    # absent-kind case is the IsNullOrEmpty guard, never a $null reference compare.
    if (-not [string]::IsNullOrEmpty($Kind)) { $signal.Kind = $Kind }
    return $signal
}

function New-KindPollResult($Accepted = @()) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]$Accepted), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]@())
}

function New-KindCandidate([long]$Handle, [string]$Title, [string[]]$Tabs) {
    if ($null -eq $Tabs) { $Tabs = @() }
    return New-Object TerminalOrganizer.Core.Attention.AttentionCandidate -ArgumentList ([IntPtr]$Handle), $Title, $Tabs
}

function New-KindFixture {
    # One candidate so needle "hooks" matches exactly one handle (4101): counts stay simple.
    # SPEC-TRAY-019 (plan.md A-4 AM-1c): the tab is re-based to the launcher-prefixed
    # session-tab shape; the stripped title Hooks keeps the one-handle invariant.
    return @(
        (New-KindCandidate 4101 'HG_ClaudeWSL2Notification' @('HG_Hooks'))
    )
}

try {
    if (-not ('KindDesktopFake' -as [type])) {
        Invoke-Expression @'
    class KindDesktopFake : TerminalOrganizer.Core.Monitors.IDesktopSource {
        [System.Collections.Hashtable]$State
        KindDesktopFake([System.Collections.Hashtable]$s) { $this.State = $s }
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

function Reset-KindRig {
    $script:KindLog = New-Object 'System.Collections.Generic.List[string]'
    $script:KindFactoryCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:KindProbeCount = 0
    $script:KindForegroundHandle = [IntPtr]::Zero
    $script:KindRectFeed = @(100, 200, 900, 700)
    $script:KindNextPoll = New-KindPollResult
    $script:KindDesktopState = $null
}

function New-KindController([bool]$Enabled = $true, [string]$Policy = 'all', [int]$Limit = 10, [bool]$Topmost = $false, $DesktopState = $null) {
    Reset-KindRig
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:KindNextPoll }
    $probe = [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param() $script:KindProbeCount++; New-KindFixture }
    $queue = [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) }
    $marshal = [System.Action[System.Action]]{ param($a) $a.Invoke() }
    $foreground = [Func[IntPtr]]{ param() $script:KindForegroundHandle }
    $alive = [Func[IntPtr,bool]]{ param($h) $true }
    $minimized = [Func[IntPtr,bool]]{ param($h) $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) $script:KindRectFeed }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:KindFactoryCalls.Add('create ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:KindFactoryCalls.Add('restart ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:KindFactoryCalls.Add('tick ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:KindFactoryCalls.Add('stop ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:KindFactoryCalls.Add('hide ' + $h.ToInt64()) }), `
        ([System.Action[string,string]]$null), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:KindFactoryCalls.Add('steady ' + $h.ToInt64()) })
    $log = [System.Action[string]]{ param($line) $script:KindLog.Add($line) }
    if ($null -ne $DesktopState) {
        $script:KindDesktopState = $DesktopState
        $desktop = [KindDesktopFake]::new($DesktopState)
    } else {
        $desktop = $null
    }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $desktop, $Enabled, $Policy, $Limit, $Topmost
}

function Get-KindTicks([long]$Handle = 4101) {
    return @($script:KindFactoryCalls | Where-Object { $_ -eq ('tick ' + $Handle) }).Count
}

function Get-KindStops([long]$Handle = 4101) {
    return @($script:KindFactoryCalls | Where-Object { $_ -eq ('stop ' + $Handle) }).Count
}

function Get-KindSteadies([long]$Handle = 4101) {
    return @($script:KindFactoryCalls | Where-Object { $_ -eq ('steady ' + $Handle) }).Count
}

function Get-KindUnknownKindLines {
    $found = @($script:KindLog | Where-Object { $_ -like 'attention: unknown kind*' })
    return ,$found
}

# --- source fixtures (read once per run) ---
$script:KindCtx = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
$script:KindStore = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\SettingsStore.cs'))

Describe 'AC-004 additive parser fields, zero contract change (REQ-FLD-001)' {
    It 'fixture (a): the P1-shaped payload with kind and message records every shared field plus Kind and Message' {
        $msg600 = 'A' * 600
        $json = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z","kind":"info","message":"' + $msg600 + '"}'
        $r = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $r.Accepted | Should Be $true
        $r.Signal.Kind | Should BeExactly 'info'
        $r.Signal.Message | Should BeExactly $msg600
        $r.Signal.Version | Should Be 1
        $r.Signal.Event | Should BeExactly 'stop'
        ($null -eq $r.Signal.NotificationType) | Should Be $true
        $r.Signal.SessionId | Should BeExactly 's-1'
        $r.Signal.Cwd | Should BeExactly '/home/j/hooks'
        $r.Signal.Needle | Should BeExactly 'hooks'
        $r.Signal.Timestamp | Should BeExactly '2026-10-31T09:00:00Z'
    }

    It 'fixture (b): a payload carrying neither additive key records Kind and Message null' {
        $json = '{"version":1,"event":"stop","notification_type":null,"session_id":"s-1","cwd":"/home/j/hooks","needle":"hooks","timestamp":"2026-10-31T09:00:00Z"}'
        $r = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $r.Accepted | Should Be $true
        ($null -eq $r.Signal.Kind) | Should Be $true
        ($null -eq $r.Signal.Message) | Should Be $true
        $r.Signal.Version | Should Be 1
        $r.Signal.Event | Should BeExactly 'stop'
        ($null -eq $r.Signal.NotificationType) | Should Be $true
        $r.Signal.SessionId | Should BeExactly 's-1'
        $r.Signal.Cwd | Should BeExactly '/home/j/hooks'
        $r.Signal.Needle | Should BeExactly 'hooks'
        $r.Signal.Timestamp | Should BeExactly '2026-10-31T09:00:00Z'
    }

    It 'fixture (c): kind null and message non-string record Kind and Message null (the ReadOptionalString rule)' {
        $json = '{"version":1,"event":"notification","needle":"pwsh","kind":null,"message":123}'
        $r = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $r.Accepted | Should Be $true
        ($null -eq $r.Signal.Kind) | Should Be $true
        ($null -eq $r.Signal.Message) | Should Be $true
        $r.Signal.Event | Should BeExactly 'notification'
        $r.Signal.Needle | Should BeExactly 'pwsh'
    }

    It 'fixture (d): further unknown keys stay ignored and acceptance is unchanged (the P10 shape)' {
        $json = '{"version":1,"event":"notification","needle":"pwsh","extra":123}'
        $r = [TerminalOrganizer.Core.Attention.AttentionSignalParser]::Parse($json)
        $r.Accepted | Should Be $true
        ($null -eq $r.Signal.Kind) | Should Be $true
        ($null -eq $r.Signal.Message) | Should Be $true
    }
}

Describe 'AC-005 absent/unknown kind degradation truth table (REQ-KIND-002)' {
    It 'absent kind, stop under notifications: suppressed outright - never pending, the pinned suppression line, no run' {
        $controller = New-KindController -Policy 'notifications'
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks'))
        $controller.PollTick()
        $script:KindProbeCount | Should Be 0
        $script:KindLog.Count | Should Be 1
        $script:KindLog[0] | Should BeExactly 'attention: suppressed (policy notifications) event=stop needle="hooks"'
        $script:KindFactoryCalls.Count | Should Be 0
        $controller.Dispose()
    }

    It 'absent kind, stop under mixed: blink-limited at the stop blink limit (the shipped fixed count)' {
        $controller = New-KindController -Policy 'mixed' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks'))
        $controller.PollTick()
        $controller.BlinkTick()
        $controller.BlinkTick()
        Get-KindTicks | Should Be 2
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindTicks | Should Be 3
        $script:KindFactoryCalls[-1] | Should BeExactly 'steady 4101'
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
    }

    It 'absent kind, stop under all: NO time cap - the long-run shape keeps blinking (the pinned NO-time-cap row)' {
        $controller = New-KindController -Policy 'all' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks'))
        $controller.PollTick()
        for ($i = 0; $i -lt 30; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 30
        Get-KindSteadies | Should Be 0
        $controller.Dispose()
    }

    It 'absent kind, notification under each policy: until-focus, no count, no cap (shipped)' {
        foreach ($policy in @('all', 'notifications', 'mixed')) {
            $controller = New-KindController -Policy $policy -Limit 3
            $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks'))
            $controller.PollTick()
            for ($i = 0; $i -lt 25; $i++) { $controller.BlinkTick() }
            Get-KindTicks | Should Be 25
            Get-KindSteadies | Should Be 0
            $controller.Dispose()
        }
    }

    It 'unknown kind "warn", stop under mixed: absent-equivalent blink-limited AND exactly one unknown-kind line' {
        $controller = New-KindController -Policy 'mixed' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'warn'))
        $controller.PollTick()
        $lines = Get-KindUnknownKindLines
        $lines.Count | Should Be 1
        $lines[0] | Should BeExactly 'attention: unknown kind "warn" (treated as absent) event=stop needle="hooks"'
        for ($i = 0; $i -lt 2; $i++) { $controller.BlinkTick() }
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        (Get-KindUnknownKindLines).Count | Should Be 1
        $controller.Dispose()
    }

    It 'unknown kind "warn", stop under all: absent-equivalent unlimited AND exactly one unknown-kind line' {
        $controller = New-KindController -Policy 'all' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'warn'))
        $controller.PollTick()
        for ($i = 0; $i -lt 25; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 25
        Get-KindSteadies | Should Be 0
        (Get-KindUnknownKindLines).Count | Should Be 1
        $controller.Dispose()
    }
}

Describe 'AC-006 ask and stop kinds (REQ-KIND-001)' {
    It 'ask kind with stop or notification events, under every policy that shows it: no time cap, no blink limit, no stop' {
        # 30 ticks escape BOTH caps (info 20 s at the default and any fixed count) with the
        # target untouched on the current desktop; only closed/foreground/minimized/moved may stop it.
        foreach ($combo in @(@('stop', 'all'), @('stop', 'mixed'), @('notification', 'all'),
                @('notification', 'mixed'), @('notification', 'notifications'))) {
            $controller = New-KindController -Policy $combo[1] -Limit 3
            $script:KindNextPoll = New-KindPollResult @((New-KindSignal $combo[0] 'hooks' 'ask'))
            $controller.PollTick()
            for ($i = 0; $i -lt 30; $i++) { $controller.BlinkTick() }
            Get-KindTicks | Should Be 30
            Get-KindSteadies | Should Be 0
            $controller.Dispose()
        }
    }

    It 'stop kind under all (the one intended delta vs absent-kind): fixed count at the stop blink limit' {
        $controller = New-KindController -Policy 'all' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        for ($i = 0; $i -lt 2; $i++) { $controller.BlinkTick() }
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        Get-KindTicks | Should Be 3
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
    }

    It 'stop kind under mixed: the fixed count travels with the explicit kind (not the mixed-only approximation)' {
        $controller = New-KindController -Policy 'mixed' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        $controller.BlinkTick()
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
    }

    It 'stop and info kinds under notifications with a stop event: suppressed outright both - the kind never rescues a filtered event' {
        foreach ($kind in @('stop', 'info')) {
            $controller = New-KindController -Policy 'notifications'
            $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' $kind))
            $controller.PollTick()
            $script:KindProbeCount | Should Be 0
            $script:KindLog.Count | Should Be 1
            $script:KindLog[0] | Should BeExactly 'attention: suppressed (policy notifications) event=stop needle="hooks"'
            $script:KindFactoryCalls.Count | Should Be 0
            $controller.Dispose()
        }
    }
}

Describe 'AC-007 info visible-seconds cap, VD-gated (REQ-KIND-003)' {
    It 'default 10 s: the info overlay stops exactly on the 20th visible tick (ceil(10 x 1000 / 500))' {
        $controller = New-KindController -Policy 'all'
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        for ($i = 0; $i -lt 19; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 19
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindTicks | Should Be 20
        $script:KindFactoryCalls[-1] | Should BeExactly 'steady 4101'
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=infocap'
        $controller.Dispose()
    }

    It 'off-desktop ticks neither advance the count nor stop the overlay; counting resumes on return' {
        $state = @{ Calls = 0; Success = $true; OnCurrent = $true; Error = '' }
        $controller = New-KindController -Policy 'all' -DesktopState $state
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        for ($i = 0; $i -lt 5; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 5
        $script:KindDesktopState['OnCurrent'] = $false
        for ($i = 0; $i -lt 8; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 5
        Get-KindSteadies | Should Be 0
        (@($script:KindFactoryCalls | Where-Object { $_ -eq 'hide 4101' })).Count | Should Be 8
        $script:KindDesktopState['OnCurrent'] = $true
        for ($i = 0; $i -lt 14; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 19
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindTicks | Should Be 20
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=infocap'
        $controller.Dispose()
    }

    It 'a failed desktop check keeps the ring visible and counting (the fix-B semantics)' {
        $state = @{ Calls = 0; Success = $false; OnCurrent = $false; Error = 'indeterminate' }
        $controller = New-KindController -Policy 'all' -DesktopState $state
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        for ($i = 0; $i -lt 19; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 19
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindTicks | Should Be 20
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=infocap'
        $controller.Dispose()
    }

    It 'restart resets the count and adopts the new kind: stop -> info' {
        $controller = New-KindController -Policy 'mixed' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        $controller.BlinkTick()
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 0
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        ($script:KindLog -contains 'attention: overlay restarted hwnd=4101') | Should Be $true
        $controller.BlinkTick()
        # Without the reset this tick is the 3rd visible tick of the stop window -> blinklimit.
        Get-KindSteadies | Should Be 0
        for ($i = 0; $i -lt 18; $i++) { $controller.BlinkTick() }
        # 19 visible ticks of the NEW info window - one short of the 20-tick cap.
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=infocap'
        # Full accounting: 2 ticks of the stop window + 20 of the adopted info window.
        Get-KindTicks | Should Be 22
        $controller.Dispose()
    }

    It 'restart resets the count and adopts the new kind: info -> stop' {
        $controller = New-KindController -Policy 'mixed' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        for ($i = 0; $i -lt 19; $i++) { $controller.BlinkTick() }
        Get-KindSteadies | Should Be 0
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        ($script:KindLog -contains 'attention: overlay restarted hwnd=4101') | Should Be $true
        $controller.BlinkTick()
        # Without the reset this tick is the 20th visible tick of the info window -> infocap.
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=blinklimit'
        $controller.Dispose()
    }

    It 'seconds 1 caps at 2 visible ticks (the unit rows assert SECONDS, not the 10-tick limit numeral)' {
        $controller = New-KindController -Policy 'all'
        $controller.SetInfoVisibleSeconds(1)
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=infocap'
        $controller.Dispose()
    }

    It 'seconds 3 caps at 6 visible ticks' {
        $controller = New-KindController -Policy 'all'
        $controller.SetInfoVisibleSeconds(3)
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        for ($i = 0; $i -lt 5; $i++) { $controller.BlinkTick() }
        Get-KindSteadies | Should Be 0
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay steady hwnd=4101 reason=infocap'
        $controller.Dispose()
    }
}

Describe 't18 steady dim ring: a capped overlay stays lit until the user attends (2026-11-04)' {
    # t18 (2026-11-04 UX round): when the stop blink limit or the info cap runs out,
    # the overlay is NOT removed - it switches to a steady (non-blinking) dimmer ring
    # and keeps its card, and the shipped user-attention stops (foreground,
    # minimized, moved, closed) still end it. The ask kind never caps, so never dims.

    It 'the cap turns the ring steady instead of stopping it; later ticks re-assert steady, never blink' {
        $controller = New-KindController -Policy 'all' -Limit 3
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        for ($i = 0; $i -lt 3; $i++) { $controller.BlinkTick() }
        Get-KindSteadies | Should Be 1
        for ($i = 0; $i -lt 5; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 3
        Get-KindSteadies | Should Be 6
        Get-KindStops | Should Be 0
        (@($script:KindLog | Where-Object { $_ -like 'attention: overlay steady*' })).Count | Should Be 1
        $controller.Dispose()
    }

    It 'focusing the window ends a steady ring (reason=foreground)' {
        $controller = New-KindController -Policy 'all'
        $controller.SetInfoVisibleSeconds(1)
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'info'))
        $controller.PollTick()
        for ($i = 0; $i -lt 4; $i++) { $controller.BlinkTick() }
        Get-KindSteadies | Should Be 3
        $script:KindForegroundHandle = [IntPtr]4101
        $controller.BlinkTick()
        Get-KindStops | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=foreground'
        $controller.Dispose()
    }

    It 'moving the window ends a steady ring (reason=moved)' {
        $controller = New-KindController -Policy 'all' -Limit 1
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindRectFeed = @(150, 250, 950, 750)
        $controller.BlinkTick()
        Get-KindStops | Should Be 1
        $script:KindLog[-1] | Should BeExactly 'attention: overlay stopped hwnd=4101 reason=moved'
        $controller.Dispose()
    }

    It 'a new signal on a steady ring restarts the blinking with a fresh count' {
        $controller = New-KindController -Policy 'all' -Limit 2
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        for ($i = 0; $i -lt 3; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 2
        Get-KindSteadies | Should Be 2
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        ($script:KindLog -contains 'attention: overlay restarted hwnd=4101') | Should Be $true
        $controller.BlinkTick()
        Get-KindTicks | Should Be 3
        Get-KindSteadies | Should Be 2
        $controller.BlinkTick()
        Get-KindTicks | Should Be 4
        Get-KindSteadies | Should Be 3
        $controller.Dispose()
    }

    It 'off-desktop hides a steady ring; returning re-asserts it steady (not blinking)' {
        $state = @{ Calls = 0; Success = $true; OnCurrent = $true; Error = '' }
        $controller = New-KindController -Policy 'all' -Limit 1 -DesktopState $state
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'stop' 'hooks' 'stop'))
        $controller.PollTick()
        $controller.BlinkTick()
        Get-KindSteadies | Should Be 1
        $script:KindDesktopState['OnCurrent'] = $false
        $controller.BlinkTick()
        $script:KindFactoryCalls[-1] | Should BeExactly 'hide 4101'
        $script:KindDesktopState['OnCurrent'] = $true
        $controller.BlinkTick()
        $script:KindFactoryCalls[-1] | Should BeExactly 'steady 4101'
        Get-KindTicks | Should Be 1
        Get-KindStops | Should Be 0
        $controller.Dispose()
    }

    It 'the ask kind never caps, so it never turns steady' {
        $controller = New-KindController -Policy 'all' -Limit 1
        $script:KindNextPoll = New-KindPollResult @((New-KindSignal 'notification' 'hooks' 'ask'))
        $controller.PollTick()
        for ($i = 0; $i -lt 40; $i++) { $controller.BlinkTick() }
        Get-KindTicks | Should Be 40
        Get-KindSteadies | Should Be 0
        $controller.Dispose()
    }

    It 'pins the dim ring color: the amber RingColorRgb at half brightness (0x7F5F00)' {
        $c = [TerminalOrganizer.Core.Attention.AttentionConstants]
        $c::RingColorRgb | Should Be 0xFFBF00
        $c::RingDimColorRgb | Should Be 0x7F5F00
    }
}

Describe 'AC-008 settings key: default, clamp, five-value carry (REQ-PREF-001)' {
    It 'a file without the new key loads the default 10 and keeps schemaVersion 3' {
        $path = New-KindSettingsScratch '{"schemaVersion":3}'
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionInfoVisibleSeconds | Should Be 10
            $s.SchemaVersion | Should Be 3
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'a file with no attention keys at all loads every shipped attention default' {
        $path = New-KindSettingsScratch '{}'
        try {
            $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
            $s.AttentionOverlay | Should Be $true
            $s.AttentionEventPolicy | Should BeExactly 'mixed'
            $s.AttentionStopBlinkLimit | Should Be 10
            $s.AttentionOverlayTopmost | Should Be $false
            $s.AttentionInfoVisibleSeconds | Should Be 10
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'persisted 0 and -5 clamp to 1; 999 clamps to 120 (the ClampInfoSeconds bounds)' {
        foreach ($pair in @(@(0, 1), @(-5, 1), @(999, 120))) {
            $path = New-KindSettingsScratch ('{"schemaVersion":3,"attentionInfoVisibleSeconds":' + $pair[0] + '}')
            try {
                $s = ([TerminalOrganizer.App.SettingsStore]::new($path)).Load()
                $s.AttentionInfoVisibleSeconds | Should Be $pair[1]
            }
            finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
        }
    }

    It 'AppSettings carries exactly the 18 shipped properties (the AM-4 re-based count)' {
        ([TerminalOrganizer.App.AppSettings].GetProperties().Count) | Should Be 19
    }

    It '(a) per-site guard: each of the three TrayContext save constructions carries AttentionInfoVisibleSeconds' {
        $constructions = [regex]::Matches($script:KindCtx, 'store\.Save\(new AppSettings\(')
        $constructions.Count | Should Be 3
        foreach ($m in $constructions) {
            $end = $script:KindCtx.IndexOf('));', $m.Index)
            ($end -gt $m.Index) | Should Be $true
            $span = $script:KindCtx.Substring($m.Index, $end - $m.Index)
            ($span.Contains('AttentionInfoVisibleSeconds')) | Should Be $true
        }
    }

    It '(b) the loader carries the camelCase DTO ternary for attentionInfoVisibleSeconds (the D-9 pattern)' {
        ([regex]::IsMatch($script:KindStore, 'dto\.attentionInfoVisibleSeconds\.HasValue\s*\?\s*ClampInfoSeconds\(dto\.attentionInfoVisibleSeconds\.Value\)\s*:\s*DefaultInfoVisibleSeconds')) | Should Be $true
    }

    It '(c) the total new AppSettings( count across src is exactly 6 - a seventh construction is a FAIL' {
        $total = 0
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Recurse -Filter '*.cs' | ForEach-Object {
            $total += ([regex]::Matches([IO.File]::ReadAllText($_.FullName), 'new AppSettings\(')).Count
        }
        $total | Should Be 6
    }

    It '(d) the store.Save(new AppSettings count in TrayContext.cs is still exactly 3' {
        ([regex]::Matches($script:KindCtx, 'store\.Save\(new AppSettings')).Count | Should Be 3
    }

    It 'save carry-through: SaveManagerSelectorTo carries all five attention values (behavioral)' {
        $path = New-KindSettingsScratch $script:KindCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $selector = [TerminalOrganizer.Core.Assignment.ManagerSelector]::new(
                [TerminalOrganizer.Core.Assignment.ManagerSelectorKind]::Session, 'YODA1', 'OC_YODA1')
            $null = (Get-KindShellMethod 'SaveManagerSelectorTo').Invoke($null, @($store, $selector))
            $v = Read-KindAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $true
            $v.Info | Should Be 42
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }

    It 'save carry-through: SaveOverflowPolicyTo carries all five attention values (behavioral)' {
        $path = New-KindSettingsScratch $script:KindCarryBase
        try {
            $store = [TerminalOrganizer.App.SettingsStore]::new($path)
            $null = (Get-KindShellMethod 'SaveOverflowPolicyTo').Invoke($null,
                @($store, [TerminalOrganizer.App.OverflowPolicy]::Merge))
            $v = Read-KindAttention $path
            $v.Enable | Should Be $false
            $v.Policy | Should BeExactly 'notifications'
            $v.Limit | Should Be 5
            $v.Topmost | Should Be $true
            $v.Info | Should Be 42
        }
        finally { Remove-Item -Recurse -Force (Split-Path $path) -ErrorAction SilentlyContinue }
    }
}
