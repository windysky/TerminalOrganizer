# Card ask-sound suite (Pester 3.4.0, Windows PowerShell 5.1): an attention signal of kind "ask" plays the
# Windows notification sound once, through an injected seam, at most once per normalized needle per
# AttentionConstants.AskSoundCooldownMs. The producer (wsl-toast) skips its own toast while the organizer
# heartbeat is fresh, so without this an ask signal is silent (ring and card only).
# Expected values come from the card, never from the code under test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# Kind stays untyped and is assigned only when supplied: assigning $null to the .NET string field would store ''.
function New-SSignal([string]$Event, [string]$Needle, $Kind = $null) {
    $signal = New-Object TerminalOrganizer.Core.Attention.AttentionSignal
    $signal.Version = 1
    $signal.Event = $Event
    $signal.Needle = $Needle
    if ($null -ne $Kind) { $signal.Kind = $Kind }
    return $signal
}

function New-SPoll($Accepted = @()) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]$Accepted), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]@())
}

# One window whose session tab is OC_alpha: needle alpha matches it, every other needle matches nothing.
function New-SController([string]$Policy = 'all', [bool]$Enabled = $true) {
    $script:SLog = New-Object 'System.Collections.Generic.List[string]'
    $script:SCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:SNow = 1000000
    $script:SNext = New-SPoll
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:SNext }
    $probe = [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param()
        ,@((New-Object TerminalOrganizer.Core.Attention.AttentionCandidate -ArgumentList ([IntPtr]7001), 'OC_alpha', ([string[]]@('OC_alpha')))) }
    $queue = [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) }
    $marshal = [System.Action[System.Action]]{ param($a) $a.Invoke() }
    $foreground = [Func[IntPtr]]{ param() [IntPtr]::Zero }
    $alive = [Func[IntPtr,bool]]{ param($h) $true }
    $minimized = [Func[IntPtr,bool]]{ param($h) $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) @(100, 200, 900, 700) }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:SCalls.Add('create ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:SCalls.Add('restart ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:SCalls.Add('tick ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:SCalls.Add('stop ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:SCalls.Add('hide ' + $h.ToInt64()) })
    $log = [System.Action[string]]{ param($line) $script:SLog.Add($line) }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $null, $Enabled, $Policy, 10, $false
}

function Install-SSound($Controller) {
    $script:SPlays = 0
    $play = [Action]{ $script:SPlays++ }
    $clock = [Func[long]]{ param() $script:SNow }
    $Controller.SetAskSound($play, $clock)
}

function Send-SSignal($Controller, $Signal) {
    $script:SNext = New-SPoll @($Signal)
    $Controller.PollTick()
}

function Get-SSoundLines {
    return ,@($script:SLog | Where-Object { $_ -like 'attention: ask sound*' })
}

Describe 'Ask-signal sound (card ask-sound)' {
    It 'an ask signal plays once and logs the played line; a matched window still rings' {
        $c = New-SController
        Install-SSound $c
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask')
        $script:SPlays | Should Be 1
        (Get-SSoundLines).Count | Should Be 1
        (Get-SSoundLines)[0] | Should BeExactly 'attention: ask sound played needle="alpha"'
        ($script:SCalls -join '|') | Should BeExactly 'create 7001'
        $c.Dispose()
    }

    It 'a zero-match ask signal also plays (the tray balloon is separate)' {
        $c = New-SController
        Install-SSound $c
        Send-SSignal $c (New-SSignal 'notification' 'zzzneedle' 'ask')
        $script:SPlays | Should Be 1
        (Get-SSoundLines)[0] | Should BeExactly 'attention: ask sound played needle="zzzneedle"'
        $c.Dispose()
    }

    It 'info, stop and no-kind signals never play and log no sound line' {
        $c = New-SController
        Install-SSound $c
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'info')
        Send-SSignal $c (New-SSignal 'stop' 'alpha' 'stop')
        Send-SSignal $c (New-SSignal 'stop' 'alpha')
        Send-SSignal $c (New-SSignal 'stop' 'alpha' 'Ask')
        $script:SPlays | Should Be 0
        (Get-SSoundLines).Count | Should Be 0
        $c.Dispose()
    }

    It 'the same needle inside the cooldown is suppressed and logged; at exactly 10000 ms it plays again' {
        $c = New-SController
        Install-SSound $c
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask')
        $script:SNow += 9999
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask')
        $script:SPlays | Should Be 1
        (Get-SSoundLines)[1] | Should BeExactly 'attention: ask sound suppressed (cooldown) needle="alpha"'
        $script:SNow += 1
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask')
        $script:SPlays | Should Be 2
        $c.Dispose()
    }

    It 'a different needle inside the cooldown plays; needles that normalize alike share one cooldown' {
        $c = New-SController
        Install-SSound $c
        Send-SSignal $c (New-SSignal 'notification' 'jang_proj' 'ask')
        $script:SNow += 1000
        Send-SSignal $c (New-SSignal 'notification' 'other' 'ask')
        $script:SPlays | Should Be 2
        Send-SSignal $c (New-SSignal 'notification' 'JANG proj' 'ask')
        $script:SPlays | Should Be 2
        $c.Dispose()
    }

    It 'a throwing play seam is contained, logged once, and does not arm the cooldown' {
        $c = New-SController
        $script:SAttempts = 0
        $bad = [Action]{ $script:SAttempts++; throw 'no audio device' }
        $c.SetAskSound($bad, ([Func[long]]{ param() $script:SNow }))
        $caught = $null
        try { Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask') } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        (Get-SSoundLines).Count | Should Be 1
        (Get-SSoundLines)[0] | Should BeExactly 'attention: ask sound failed: no audio device'
        # Not armed: the next signal for the same needle tries again at once.
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask')
        $script:SAttempts | Should Be 2
        @($script:SLog | Where-Object { $_ -like 'attention: ask sound suppressed*' }).Count | Should Be 0
        $c.Dispose()
    }

    It 'no seam installed: no throw and no sound line' {
        $c = New-SController
        $caught = $null
        try { Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask') } catch { $caught = $_ }
        $caught | Should BeNullOrEmpty
        (Get-SSoundLines).Count | Should Be 0
        $c.Dispose()
    }

    It 'a signal removed by the event policy or the disabled switch plays nothing' {
        $c = New-SController 'notifications'
        Install-SSound $c
        # An ask kind on a stop event under policy notifications is dropped before it becomes pending.
        Send-SSignal $c (New-SSignal 'stop' 'alpha' 'ask')
        $script:SPlays | Should Be 0
        $c.Dispose()
        $d = New-SController 'all' $false
        Install-SSound $d
        Send-SSignal $d (New-SSignal 'notification' 'alpha' 'ask')
        $script:SPlays | Should Be 0
        $d.Dispose()
    }

    It 'the existing log lines of an ask signal are byte-identical (the sound line is additive)' {
        $c = New-SController
        Install-SSound $c
        Send-SSignal $c (New-SSignal 'notification' 'alpha' 'ask')
        $others = @($script:SLog | Where-Object { $_ -notlike 'attention: ask sound*' })
        $others[0] | Should BeExactly 'attention: event=notification needle="alpha" matched=1'
        $others[1] | Should BeExactly 'attention: match hwnd=7001 session-tab="alpha"'
        $c.Dispose()
    }

    It 'the cooldown constant is named and set to 10000' {
        [TerminalOrganizer.Core.Attention.AttentionConstants]::AskSoundCooldownMs | Should Be 10000
    }

    It 'TrayContext wires SetAskSound to the winmm PlaySound with Notification.Default and SND_ASYNC' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\TerminalOrganizer.App\TrayContext.cs'))
        $text | Should Match 'SetAskSound\(\s*delegate\s*\{[^}]*PlayNotificationSound\(\)'
        $text | Should Match 'DllImport\("winmm\.dll"[^\]]*\]\s*(public|internal|private)?\s*static extern bool PlaySound\('
        $text | Should Match '"Notification\.Default"'
        $text | Should Match 'SND_ASYNC\s*=\s*0x0001'
        $text | Should Match 'SND_ALIAS\s*=\s*0x00010000'
        $text | Should Match 'SND_NODEFAULT\s*=\s*0x0002'
        $text | Should Match 'SND_ALIAS \| SND_ASYNC \| SND_NODEFAULT'
    }
}
