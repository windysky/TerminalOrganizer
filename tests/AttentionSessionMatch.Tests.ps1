# SPEC-TRAY-019 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# The session-title lens: a needle rings only the window whose launcher-prefixed
# session tab names it. Expected values come from spec.md section 3 and plan.md
# A-2/A-3, never from the code under test. Every NEW assertion of this SPEC lives
# here (era discipline); the sibling suites change only via the plan.md A-4 rows.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# --- shared fixtures ---

function New-SessionCandidate([long]$Handle, [string]$Title, [string[]]$Tabs) {
    if ($null -eq $Tabs) { $Tabs = @() }
    return New-Object TerminalOrganizer.Core.Attention.AttentionCandidate -ArgumentList ([IntPtr]$Handle), $Title, $Tabs
}

# The 2026-11-02 07:58 incident pair (spec.md 1.1): the true session window and the
# window whose SECOND tab is a plain shell sitting in a path that contains the name.
function New-IncidentFixture {
    return @(
        (New-SessionCandidate 9001 'HG_NDResHub' @('HG_NDResHub')),
        (New-SessionCandidate 9002 'HG_PubChemSR' @('HG_PubChemSR', '[dev@devPC: ~/PROJECTS/80_UND/NDResHub]'))
    )
}

Describe 'AC-001 Incident reproduction: the path tab never rings its window (REQ-STM-001, REQ-STM-004)' {
    It 'needle ndreshub matches exactly the HG_NDResHub window' {
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('ndreshub', (New-IncidentFixture))
        ($handles -join ',') | Should BeExactly '9001'
    }

    It 'the PubChemSR window is excluded although its path tab contains the needle text' {
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('ndreshub', (New-IncidentFixture))
        ($handles -contains 9002) | Should Be $false
    }

    It 'needle pubchemsr matches exactly the PubChemSR window (its own session tab)' {
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('pubchemsr', (New-IncidentFixture))
        ($handles -join ',') | Should BeExactly '9002'
    }
}

Describe 'AC-002 Common case and window-title lens preserved (REQ-STM-001)' {
    It 'needle Hooks matches the window whose session tab strips to Hooks' {
        $fixture = @((New-SessionCandidate 9101 'HG_Hooks' @('HG_Hooks')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('Hooks', $fixture)
        ($handles -join ',') | Should BeExactly '9101'
    }

    It 'case-insensitive containment is preserved: needle hooks matches session title Hooks' {
        $fixture = @((New-SessionCandidate 9101 'HG_Hooks' @('HG_Hooks')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hooks', $fixture)
        ($handles -join ',') | Should BeExactly '9101'
    }

    It 'the tab-read-failure backstop: a prefix-present window title with no tabs still matches' {
        $fixture = @((New-SessionCandidate 4105 'HG_MyProject' @()))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('myproject', $fixture)
        ($handles -join ',') | Should BeExactly '4105'
    }

    It 'the multi-token single-session rule holds: every token in ONE stripped title' {
        $fixture = @((New-SessionCandidate 9102 'HG_ClaudeHooks' @('HG_ClaudeHooks')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('claude hooks', $fixture)
        ($handles -join ',') | Should BeExactly '9102'
    }
}

Describe 'AC-003 Edge decisions pinned (REQ-STM-003, REQ-STM-004)' {
    It 'a window with only path tabs never matches the needle text its path contains' {
        $fixture = @((New-SessionCandidate 9201 '[dev@devPC: ~/PROJECTS/80_UND/NDResHub]' @('[dev@devPC: ~/PROJECTS/80_UND/NDResHub]')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('ndreshub', $fixture)
        $handles.Length | Should Be 0
    }

    It 'a path-shaped window title with no tabs never matches' {
        $fixture = @((New-SessionCandidate 9202 'dev hooks' @()))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hooks', $fixture)
        $handles.Length | Should Be 0
    }

    It 'tokens never straddle titles: session tabs HG_A and HG_B do not match needle "a b"' {
        $fixture = @((New-SessionCandidate 9203 'HG_A' @('HG_A', 'HG_B')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('a b', $fixture)
        $handles.Length | Should Be 0
    }

    It 'needle a matches the HG_A window and needle b matches it via its second session tab' {
        $fixture = @((New-SessionCandidate 9203 'HG_A' @('HG_A', 'HG_B')))
        (([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('a', $fixture)) -join ',') | Should BeExactly '9203'
        (([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('b', $fixture)) -join ',') | Should BeExactly '9203'
    }

    It 'a window with no prefix-present title never matches any non-empty needle' {
        $fixture = @((New-SessionCandidate 9204 'PowerShell' @('wsl2', '[dev@devPC: ~/PROJECTS/80_UND/NDResHub]')))
        foreach ($needle in @('powershell', 'wsl2', 'ndreshub', 'zzz')) {
            $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match($needle, $fixture)
            $handles.Length | Should Be 0
        }
    }
}

Describe 'AC-004 The prefix is launcher metadata, never identity (REQ-STM-001)' {
    It 'needle hg never matches the session tab HG_MyProject' {
        $fixture = @((New-SessionCandidate 9301 'HG_MyProject' @('HG_MyProject')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hg', $fixture)
        $handles.Length | Should Be 0
    }

    It 'the prefixed needle HG_MyProject does not match (matching sees only the stripped title)' {
        $fixture = @((New-SessionCandidate 9301 'HG_MyProject' @('HG_MyProject')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('HG_MyProject', $fixture)
        $handles.Length | Should Be 0
    }

    It 'the stripped needle myproject still matches (the documented producer shape)' {
        $fixture = @((New-SessionCandidate 9301 'HG_MyProject' @('HG_MyProject')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('myproject', $fixture)
        ($handles -join ',') | Should BeExactly '9301'
    }
}

Describe 'MatchDetail: per-window verdicts for diagnosability (plan A-2, REQ-STM-005 evidence model)' {
    It 'the matched window carries its stripped session title and no suppression' {
        $details = [TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('ndreshub', (New-IncidentFixture))
        $details.Length | Should Be 2
        $details[0].Handle | Should Be 9001
        $details[0].Matched | Should Be $true
        $details[0].MatchedSessionTitle | Should BeExactly 'NDResHub'
        $details[0].SuppressedTitle | Should Be $null
    }

    It 'the over-matched window carries the raw path title that would have rung it' {
        $details = [TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('ndreshub', (New-IncidentFixture))
        $details[1].Handle | Should Be 9002
        $details[1].Matched | Should Be $false
        $details[1].MatchedSessionTitle | Should Be $null
        $details[1].SuppressedTitle | Should BeExactly '[dev@devPC: ~/PROJECTS/80_UND/NDResHub]'
        ($details[1].SessionTitles -join '|') | Should BeExactly 'PubChemSR|PubChemSR'
    }

    It 'session titles list the window title first, then tabs in input order' {
        $fixture = @((New-SessionCandidate 9203 'HG_A' @('HG_A', 'HG_B')))
        $details = [TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('zzz', $fixture)
        $details[0].Matched | Should Be $false
        ($details[0].SessionTitles -join '|') | Should BeExactly 'A|A|B'
    }

    It 'the window-title-lens match attributes the window title, not a tab' {
        $fixture = @((New-SessionCandidate 4105 'HG_MyProject' @()))
        $details = [TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('myproject', $fixture)
        $details[0].Matched | Should Be $true
        $details[0].MatchedSessionTitle | Should BeExactly 'MyProject'
        ($details[0].SessionTitles -join '|') | Should BeExactly 'MyProject'
    }

    It 'a matched multi-session window attributes the FIRST eligible matching surface' {
        $fixture = @((New-SessionCandidate 9203 'HG_A' @('HG_A', 'HG_B')))
        $details = [TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('b', $fixture)
        $details[0].Matched | Should Be $true
        $details[0].MatchedSessionTitle | Should BeExactly 'B'
    }

    It 'a null needle or candidate list yields an empty detail array, never an exception' {
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed($null, (New-IncidentFixture))).Length | Should Be 0
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('ndreshub', $null)).Length | Should Be 0
    }

    It 'Match stays the handles-only projection of MatchDetailed' {
        $fixture = New-IncidentFixture
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('ndreshub', $fixture)
        $fromDetails = @([TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('ndreshub', $fixture) |
            Where-Object { $_.Matched } | ForEach-Object { $_.Handle })
        ($handles -join ',') | Should BeExactly ($fromDetails -join ',')
    }
}

# --- SPEC-TRAY-019 M2: the controller log rig (AC-005, plan.md A-3 pinned shapes) ---

function New-SessionTestSignal([string]$Event, [string]$Needle) {
    $signal = New-Object TerminalOrganizer.Core.Attention.AttentionSignal
    $signal.Version = 1
    $signal.Event = $Event
    $signal.Needle = $Needle
    return $signal
}

function New-SessionTestPollResult($Accepted = @()) {
    return New-Object TerminalOrganizer.Core.Attention.AttentionPollResult -ArgumentList `
        ([TerminalOrganizer.Core.Attention.AttentionSignal[]]$Accepted), `
        ([TerminalOrganizer.Core.Attention.AttentionRejectedFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionStaleFile[]]@()), `
        ([TerminalOrganizer.Core.Attention.AttentionIoErrorFile[]]@())
}

function Reset-SessionRig {
    $script:SessionLog = New-Object 'System.Collections.Generic.List[string]'
    $script:SessionFactoryCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:SessionNextPoll = New-SessionTestPollResult
}

function New-SessionTestController {
    Reset-SessionRig
    $poll = [Func[TerminalOrganizer.Core.Attention.AttentionPollResult]]{ param() $script:SessionNextPoll }
    $probe = [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param() New-IncidentFixture }
    $queue = [System.Action[System.Threading.WaitCallback]]{ param($cb) $null = $cb.Invoke($null) }
    $marshal = [System.Action[System.Action]]{ param($a) $a.Invoke() }
    $foreground = [Func[IntPtr]]{ param() [IntPtr]::Zero }
    $alive = [Func[IntPtr,bool]]{ param($h) $true }
    $minimized = [Func[IntPtr,bool]]{ param($h) $false }
    $rect = [Func[IntPtr,int[]]]{ param($h) @(100, 200, 900, 700) }
    $factory = New-Object TerminalOrganizer.App.AttentionOverlayFactory -ArgumentList `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:SessionFactoryCalls.Add('create ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:SessionFactoryCalls.Add('restart ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr,int[]]]{ param($h, $r) $script:SessionFactoryCalls.Add('tick ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:SessionFactoryCalls.Add('stop ' + $h.ToInt64()) }), `
        ([System.Action[IntPtr]]{ param($h) $script:SessionFactoryCalls.Add('hide ' + $h.ToInt64()) })
    $log = [System.Action[string]]{ param($line) $script:SessionLog.Add($line) }
    return New-Object TerminalOrganizer.App.AttentionController -ArgumentList `
        $poll, $probe, $queue, $marshal, $foreground, $alive, $minimized, $rect, $factory, $log, $null, $true
}

Describe 'AC-005 Diagnosability lines through the controller (REQ-STM-005, REQ-STM-006)' {
    It 'the incident signal: byte-identical primary line, one match line, one over-match-suppressed line' {
        $controller = New-SessionTestController
        $script:SessionNextPoll = New-SessionTestPollResult @((New-SessionTestSignal 'stop' 'ndreshub'))
        $controller.PollTick()
        $script:SessionLog.Count | Should Be 3
        $script:SessionLog[0] | Should BeExactly 'attention: event=stop needle="ndreshub" matched=1'
        $script:SessionLog[1] | Should BeExactly 'attention: match hwnd=9001 session-tab="NDResHub"'
        $script:SessionLog[2] | Should BeExactly 'attention: over-match suppressed hwnd=9002 non-session-title="[dev@devPC: ~/PROJECTS/80_UND/NDResHub]"'
        ($script:SessionFactoryCalls -join '|') | Should BeExactly 'create 9001'
        $controller.Dispose()
    }

    It 'a signal with no path-tab collision logs no suppressed line' {
        $controller = New-SessionTestController
        $script:SessionNextPoll = New-SessionTestPollResult @((New-SessionTestSignal 'stop' 'pubchemsr'))
        $controller.PollTick()
        $script:SessionLog.Count | Should Be 2
        $script:SessionLog[0] | Should BeExactly 'attention: event=stop needle="pubchemsr" matched=1'
        $script:SessionLog[1] | Should BeExactly 'attention: match hwnd=9002 session-tab="PubChemSR"'
        $suppressed = @($script:SessionLog | Where-Object { $_ -like 'attention: over-match suppressed*' })
        $suppressed.Count | Should Be 0
        $controller.Dispose()
    }

    It 'a zero-match signal logs one no-match line per session-bearing window naming its stripped titles' {
        $controller = New-SessionTestController
        $script:SessionNextPoll = New-SessionTestPollResult @((New-SessionTestSignal 'stop' 'zzz'))
        $controller.PollTick()
        $script:SessionLog.Count | Should Be 3
        $script:SessionLog[0] | Should BeExactly 'attention: event=stop needle="zzz" matched=0 (no window; taskbar flash remains)'
        $script:SessionLog[1] | Should BeExactly 'attention: no-match hwnd=9001 session-tabs="NDResHub|NDResHub"'
        $script:SessionLog[2] | Should BeExactly 'attention: no-match hwnd=9002 session-tabs="PubChemSR|PubChemSR"'
        $script:SessionFactoryCalls.Count | Should Be 0
        $controller.Dispose()
    }

    It 'an empty poll tick after a run writes no detail line (volume bounded to signals that ran)' {
        $controller = New-SessionTestController
        $script:SessionNextPoll = New-SessionTestPollResult @((New-SessionTestSignal 'stop' 'ndreshub'))
        $controller.PollTick()
        $script:SessionLog.Clear()
        $script:SessionNextPoll = New-SessionTestPollResult
        $controller.PollTick()
        $script:SessionLog.Count | Should Be 0
        $controller.Dispose()
    }
}
