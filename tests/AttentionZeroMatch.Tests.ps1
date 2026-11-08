# Card t18 suite (Pester 3.4.0, Windows PowerShell 5.1): the organizer-side fallback cue when a consumed
# attention signal matches no window. The producer (wsl-toast) skips its toast and taskbar flash while the
# organizer heartbeat is fresh (SPEC-TRAY-016), so matched=0 would otherwise mean no cue at all; the controller
# now raises a tray notice through an injected seam, once per needle per ZeroMatchNoticeCooldownMs.
# Expected values come from the card, never from the code under test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# Message and Kind stay untyped: a [string] parameter would turn $null into an empty string.
function New-ZSignal([string]$Event, [string]$Needle, $Message = $null, $Kind = $null, [switch]$Remote) {
    $signal = New-Object TerminalOrganizer.Core.Attention.AttentionSignal
    $signal.Version = 1
    $signal.Event = $Event
    $signal.Needle = $Needle
    # Assigning $null to the string fields would store an empty string (and read as an unknown kind).
    if ($null -ne $Message) { $signal.Message = $Message }
    if ($null -ne $Kind) { $signal.Kind = $Kind }
    if ($Remote) { $signal.Remote = $true }
    return $signal
}

function New-ZPoll($Accepted = @()) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]$Accepted), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]@())
}

# One window whose session tab is OC_alpha: needle alpha matches it, every other needle matches nothing.
function New-ZController([string]$Policy = 'all', [bool]$Enabled = $true) {
    $script:ZLog = New-Object 'System.Collections.Generic.List[string]'
    $script:ZCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:ZNow = 1000000
    $script:ZNext = New-ZPoll
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:ZNext }
    $probe = [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param()
        ,@((New-Object TerminalOrganizer.Core.Attention.AttentionCandidate -ArgumentList ([IntPtr]7001), 'OC_alpha', ([string[]]@('OC_alpha')))) }
    $queue = [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) }
    $marshal = [System.Action[System.Action]]{ param($a) $a.Invoke() }
    $foreground = [Func[IntPtr]]{ param() [IntPtr]::Zero }
    $alive = [Func[IntPtr,bool]]{ param($h) $true }
    $minimized = [Func[IntPtr,bool]]{ param($h) $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) @(100, 200, 900, 700) }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:ZCalls.Add('create ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:ZCalls.Add('restart ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:ZCalls.Add('tick ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:ZCalls.Add('stop ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:ZCalls.Add('hide ' + $h.ToInt64()) })
    $log = [System.Action[string]]{ param($line) $script:ZLog.Add($line) }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $null, $Enabled, $Policy, 10, $false
}

function Install-ZNotice($Controller) {
    $script:ZNotices = New-Object 'System.Collections.Generic.List[string]'
    $notice = [Action[string,string]]{ param($title, $body) $script:ZNotices.Add($title + '|' + $body) }
    $clock = [Func[long]]{ param() $script:ZNow }
    $Controller.SetZeroMatchNotice($notice, $clock)
}

# The primary per-signal lines (the no-match dump lines in between are not counted).
function Get-ZPrimary {
    return ,@($script:ZLog | Where-Object { $_ -like 'attention: event=*' })
}

function Send-ZSignal($Controller, $Signal) {
    $script:ZNext = New-ZPoll @($Signal)
    $Controller.PollTick()
}

Describe 'Zero-match tray notice (card t18)' {
    It 'a zero-match signal calls the notice seam once with the needle and message, and logs notice shown' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle' 'Build finished')
        $script:ZNotices.Count | Should Be 1
        # 2026-11-07 wording round: title is session-generic (codex signals too), body
        # is plain language with an action hint (another PC / detached tab reattach).
        $script:ZNotices[0] | Should Match '^A session needs attention\|'
        $script:ZNotices[0] | Should Match 'window is not on this screen'
        $script:ZNotices[0] | Should Match 'tmux attach -t zzzneedle'
        $script:ZNotices[0] | Should Match 'zzzneedle'
        $script:ZNotices[0] | Should Match 'Build finished'
        (Get-ZPrimary)[0] | Should BeExactly 'attention: event=stop needle="zzzneedle" matched=0 (no window; tray notice shown)'
        $c.Dispose()
    }

    It 'a signal that matches a window raises no notice and keeps its log line' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'alpha')
        $script:ZNotices.Count | Should Be 0
        (Get-ZPrimary)[0] | Should BeExactly 'attention: event=stop needle="alpha" matched=1'
        $c.Dispose()
    }

    It 'the same needle again inside the cooldown raises no second notice and logs suppressed' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNow += 59999
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNotices.Count | Should Be 1
        (Get-ZPrimary)[1] | Should BeExactly 'attention: event=stop needle="zzzneedle" matched=0 (no window; tray notice suppressed, cooldown)'
        $c.Dispose()
    }

    It 'the same needle after the cooldown (exactly 60000 ms later) raises a notice again' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNow += 60000
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNotices.Count | Should Be 2
        $c.Dispose()
    }

    It 'a different needle inside the cooldown still raises its own notice' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNow += 1000
        Send-ZSignal $c (New-ZSignal 'stop' 'yyyneedle')
        $script:ZNotices.Count | Should Be 2
        $script:ZNotices[1] | Should Match 'yyyneedle'
        $c.Dispose()
    }

    It 'needles that normalize to the same text share one cooldown (jang_proj and JANG proj)' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'jang_proj')
        Send-ZSignal $c (New-ZSignal 'stop' 'JANG proj')
        $script:ZNotices.Count | Should Be 1
        $c.Dispose()
    }

    It 'no seam installed: no throw, the log says no tray notice, and the per-window no-match dump is unchanged' {
        $c = New-ZController
        $caught = $null
        try { Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle') } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        $script:ZLog[0] | Should BeExactly 'attention: event=stop needle="zzzneedle" matched=0 (no window; no tray notice)'
        $script:ZLog[1] | Should BeExactly 'attention: no-match hwnd=7001 session-tabs="alpha|alpha"'
        $c.Dispose()
    }

    It 'a seam that throws is contained: the signal still logs and the next tick works' {
        $c = New-ZController
        $bad = [Action[string,string]]{ param($t, $b) throw 'balloon failed' }
        $c.SetZeroMatchNotice($bad, ([Func[long]]{ param() $script:ZNow }))
        $caught = $null
        try { Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle') } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        @($script:ZLog | Where-Object { $_ -like 'attention: event=stop needle="zzzneedle" matched=0*' }).Count | Should Be 1
        @($script:ZLog | Where-Object { $_ -like '*tray notice failed*' }).Count | Should BeGreaterThan 0
        $c.Dispose()
    }

    It 'a policy-filtered signal (stop under notifications) and a disabled controller raise no notice' {
        $c = New-ZController 'notifications'
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNotices.Count | Should Be 0
        $c.Dispose()
        $d = New-ZController 'all' $false
        Install-ZNotice $d
        Send-ZSignal $d (New-ZSignal 'stop' 'zzzneedle')
        $script:ZNotices.Count | Should Be 0
        $d.Dispose()
    }

    It 'a notification-event signal under notifications still raises a notice when nothing matches' {
        $c = New-ZController 'notifications'
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'notification' 'zzzneedle')
        $script:ZNotices.Count | Should Be 1
        $c.Dispose()
    }

    It 'the message is trimmed, folded to one line and bounded to 200 characters with an ellipsis; a blank message is omitted' {
        $c = New-ZController
        Install-ZNotice $c
        $long = '  ' + ('x' * 300) + "`r`nsecond line  "
        Send-ZSignal $c (New-ZSignal 'stop' 'needle1' $long)
        $body = $script:ZNotices[0].Substring($script:ZNotices[0].IndexOf('|') + 1)
        $body.Contains("`n") | Should Be $false
        $body.Contains("`r") | Should Be $false
        $body | Should Match 'x{197}\.\.\.$'
        $body.Contains('x' * 198) | Should Be $false
        Send-ZSignal $c (New-ZSignal 'stop' 'needle2' '   ')
        $blankBody = $script:ZNotices[1].Substring($script:ZNotices[1].IndexOf('|') + 1)
        $blankBody | Should Match 'needle2'
        $blankBody | Should Not Match '\s$'
        $blankBody | Should Not Match '  '
        $c.Dispose()
    }

    It 'the cooldown constant is named and set to 60000' {
        [TerminalOrganizer.Core.Attention.AttentionConstants]::ZeroMatchNoticeCooldownMs | Should Be 60000
    }

    It 'TrayContext wires the seam to the tray balloon' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $m = [regex]::Match($text, 'SetZeroMatchNotice\(\s*delegate\(string \w+, string \w+\)\s*\{[^}]*\}')
        $m.Success | Should Be $true
        $m.Value | Should Match 'ShowAttentionBalloon'
        $text | Should Match 'ShowBalloonTip\(\d+, title, text, ToolTipIcon\.Info\)'
    }
}

function Install-ZSound($Controller) {
    $script:ZSounds = New-Object 'System.Collections.Generic.List[string]'
    $Controller.SetAskSound([Action]{ $script:ZSounds.Add('played') }, [Func[long]]{ param() $script:ZNow })
}

Describe 'Zero-match remote filter (v0.2.8 remote alerts)' {
    # A REMOTE signal (pushed from another machine by wsl-toast v1.6.1) that matches no
    # window is a background alert for a session this machine is not viewing; the
    # remote-alerts level decides whether it surfaces here. Local signals and matched
    # remote signals (a tab this machine IS viewing) are never filtered.
    It 'default level asks: a REMOTE stop with no window skips the notice and logs the skip' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle' -Remote)
        $script:ZNotices.Count | Should Be 0
        (Get-ZPrimary)[0] | Should BeExactly 'attention: event=stop needle="zzzneedle" matched=0 (no window; tray notice skipped, remote asks)'
        $c.Dispose()
    }

    It 'default level asks: a REMOTE ask (kind ask) still raises the notice' {
        $c = New-ZController
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'notification' 'zzzneedle' $null 'ask' -Remote)
        $script:ZNotices.Count | Should Be 1
        $c.Dispose()
    }

    It 'level off: even a REMOTE ask skips the notice (and the ask sound stays silent)' {
        $c = New-ZController
        $c.SetRemoteAlerts('off')
        Install-ZNotice $c
        Install-ZSound $c
        Send-ZSignal $c (New-ZSignal 'notification' 'zzzneedle' $null 'ask' -Remote)
        $script:ZNotices.Count | Should Be 0
        $script:ZSounds.Count | Should Be 0
        (Get-ZPrimary)[0] | Should BeExactly 'attention: event=notification needle="zzzneedle" matched=0 (no window; tray notice skipped, remote off)'
        $c.Dispose()
    }

    It 'level all: a REMOTE stop raises the notice (everything surfaces)' {
        $c = New-ZController
        $c.SetRemoteAlerts('all')
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'zzzneedle' -Remote)
        $script:ZNotices.Count | Should Be 1
        $c.Dispose()
    }

    It 'level off never silences a LOCAL signal (own-machine behavior unchanged)' {
        $c = New-ZController
        $c.SetRemoteAlerts('off')
        Install-ZNotice $c
        Install-ZSound $c
        Send-ZSignal $c (New-ZSignal 'notification' 'zzzneedle' $null 'ask')
        $script:ZNotices.Count | Should Be 1
        $script:ZSounds.Count | Should Be 1
        $c.Dispose()
    }

    It 'a matched REMOTE signal is never filtered (a tab this machine views always rings)' {
        $c = New-ZController
        $c.SetRemoteAlerts('off')
        Install-ZNotice $c
        Send-ZSignal $c (New-ZSignal 'stop' 'alpha' -Remote)
        $script:ZNotices.Count | Should Be 0
        (Get-ZPrimary)[0] | Should BeExactly 'attention: event=stop needle="alpha" matched=1'
        $c.Dispose()
    }

    It 'SetRemoteAlerts degrades an unknown token to asks' {
        $c = New-ZController
        $c.SetRemoteAlerts('bogus')
        $c.RemoteAlerts | Should BeExactly 'asks'
        $c.Dispose()
    }
}
