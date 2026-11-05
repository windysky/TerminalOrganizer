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

    # Card t17 amended this row: it used to pin "does not match". The needle's own prefix is never matched as
    # identity (the TITLE is stripped, and needle hg above still never matches), but the whole session name in the
    # needle now contains the stripped session title, so the reverse rule matches it (spec.md as-built amendment).
    It 'the prefixed needle HG_MyProject matches only through the reverse rule (the title is stripped; the needle may carry the prefix)' {
        $fixture = @((New-SessionCandidate 9301 'HG_MyProject' @('HG_MyProject')))
        $handles = [TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('HG_MyProject', $fixture)
        ($handles -join ',') | Should BeExactly '9301'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed('HG_MyProject', $fixture))[0].MatchRule | Should BeExactly 'reverse'
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
        $script:SessionLog[0] | Should BeExactly 'attention: event=stop needle="zzz" matched=0 (no window; no tray notice)'
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

# --- Card t17: the reverse-containment rule (office tabs carry a shorter session name than the producer's needle) ---
# Needle jang_projectx (one token, normalized jangprojectx) against the tab OC_projectx (session title projectx):
# the forward rule fails (jangprojectx is not inside projectx); the reverse rule matches because the normalized
# session title occurs inside the needle's single token, for session titles of at least 4 normalized characters.
# The reverse rule applies to single-token needles only (a multi-token needle would degrade to any-token matching).

function New-ReverseFixture([string]$Tab) {
    return @((New-SessionCandidate 9501 $Tab @($Tab)))
}

function Get-ReverseDetail([string]$Needle, $Fixture) {
    return @([TerminalOrganizer.Core.Attention.AttentionMatcher]::MatchDetailed($Needle, $Fixture))[0]
}

Describe 'Reverse containment: the stripped session title inside a single-token needle' {
    It 'needle jang_projectx matches the tab OC_projectx and the detail names the reverse rule' {
        $fixture = New-ReverseFixture 'OC_projectx'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang_projectx', $fixture) -join ',') | Should BeExactly '9501'
        $d = Get-ReverseDetail 'jang_projectx' $fixture
        $d.Matched | Should Be $true
        $d.MatchedSessionTitle | Should BeExactly 'projectx'
        $d.MatchRule | Should BeExactly 'reverse'
    }

    It 'a forward match stays forward and an unmatched window reports no rule' {
        $fixture = New-ReverseFixture 'OC_projectx'
        $forward = Get-ReverseDetail 'projectx' $fixture
        $forward.Matched | Should Be $true
        $forward.MatchRule | Should BeExactly 'forward'
        $none = Get-ReverseDetail 'zzzz' $fixture
        $none.Matched | Should Be $false
        $none.MatchRule | Should Be $null
    }

    It 'a title matching both ways is attributed to the forward rule (evaluated first)' {
        $fixture = New-ReverseFixture 'OC_projectx'
        (Get-ReverseDetail 'projectx' $fixture).MatchRule | Should BeExactly 'forward'
        $both = New-ReverseFixture 'HG_MyProject'
        (Get-ReverseDetail 'HG_MyProject' $both).Matched | Should Be $true
    }

    It 'the length guard: a 3-character session title (OC_pro) does not match, a 4-character one (OC_proj) does' {
        $short = New-ReverseFixture 'OC_pro'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang_projectx', $short)).Length | Should Be 0
        (Get-ReverseDetail 'jang_projectx' $short).MatchRule | Should Be $null
        $edge = New-ReverseFixture 'OC_proj'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang_projectx', $edge) -join ',') | Should BeExactly '9501'
        (Get-ReverseDetail 'jang_projectx' $edge).MatchRule | Should BeExactly 'reverse'
    }

    It 'the guard counts normalized characters: OC_a-b_c (abc, 3) does not match, OC_a-b_cd (abcd, 4) does' {
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('xx_abcd', (New-ReverseFixture 'OC_a-b_c'))).Length | Should Be 0
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('xx_abcd', (New-ReverseFixture 'OC_a-b_cd')) -join ',') | Should BeExactly '9501'
    }

    It 'a non-session title never matches through the reverse rule' {
        foreach ($tab in @('C:\work\projectx', 'projectx', 'RU_projectx')) {
            $fixture = @((New-SessionCandidate 9502 'PowerShell' @($tab)))
            ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang_projectx', $fixture)).Length | Should Be 0
            (Get-ReverseDetail 'jang_projectx' $fixture).SuppressedTitle | Should Be $null
        }
    }

    # A multi-token needle never takes the reverse rule: joined, it would match any window whose session title equals
    # ONE of its tokens, turning the producer's all-tokens-in-one-title rule into any-token matching.
    It 'a multi-token needle never matches through the reverse rule: jang projectx and projectx jang do not match OC_projectx' {
        $fixture = New-ReverseFixture 'OC_projectx'
        foreach ($needle in @('jang projectx', 'projectx jang', 'jang_projectx jang_projectx')) {
            ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match($needle, $fixture)).Length | Should Be 0
            (Get-ReverseDetail $needle $fixture).MatchRule | Should Be $null
        }
    }

    It 'a multi-token needle keeps the forward all-tokens rule: hooks yoda does not ring OC_Hooks, jang projectx still rings a title holding both tokens' {
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('hooks yoda', (New-ReverseFixture 'OC_Hooks'))).Length | Should Be 0
        $both = New-ReverseFixture 'OC_jangprojectx'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang projectx', $both) -join ',') | Should BeExactly '9501'
        (Get-ReverseDetail 'jang projectx' $both).MatchRule | Should BeExactly 'forward'
    }

    It 'tokens that normalize to nothing do not count: jang_projectx -- is still a single-token needle and reverse-matches' {
        $fixture = New-ReverseFixture 'OC_projectx'
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang_projectx --', $fixture) -join ',') | Should BeExactly '9501'
        (Get-ReverseDetail 'jang_projectx --' $fixture).MatchRule | Should BeExactly 'reverse'
    }

    It 'the window title is also a reverse surface' {
        $fixture = @((New-SessionCandidate 9503 'OC_projectx' @()))
        ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match('jang_projectx', $fixture) -join ',') | Should BeExactly '9503'
    }

    It 'a needle of zero tokens still matches nothing' {
        $fixture = New-ReverseFixture 'OC_projectx'
        foreach ($needle in @('__', ' - ', '...')) {
            ([TerminalOrganizer.Core.Attention.AttentionMatcher]::Match($needle, $fixture)).Length | Should Be 0
        }
    }

    It 'the constant is named and set to 4' {
        [TerminalOrganizer.Core.Attention.AttentionConstants]::MinReverseSessionLength | Should Be 4
    }
}

function New-ReverseController($Fixture) {
    $controller = New-SessionTestController
    $script:ReverseFixtureRows = $Fixture
    $probeField = $controller.GetType().GetField('probeWindows', [Reflection.BindingFlags]'NonPublic,Instance')
    if ($null -eq $probeField) { throw 'probeWindows field not found' }
    $probeField.SetValue($controller, [Func[TerminalOrganizer.Core.Attention.AttentionCandidate[]]]{ param() $script:ReverseFixtureRows })
    return $controller
}

Describe 'Reverse containment: log lines through the controller' {
    It 'a reverse match logs the primary line unchanged and the detail line with a trailing rule=reverse' {
        $controller = New-ReverseController (New-ReverseFixture 'OC_projectx')
        $script:SessionNextPoll = New-SessionTestPollResult @((New-SessionTestSignal 'stop' 'jang_projectx'))
        $controller.PollTick()
        $script:SessionLog.Count | Should Be 2
        $script:SessionLog[0] | Should BeExactly 'attention: event=stop needle="jang_projectx" matched=1'
        $script:SessionLog[1] | Should BeExactly 'attention: match hwnd=9501 session-tab="projectx" rule=reverse'
        $controller.Dispose()
    }

    It 'a forward match logs the detail line byte-identical to before (no rule suffix)' {
        $controller = New-ReverseController (New-ReverseFixture 'OC_projectx')
        $script:SessionNextPoll = New-SessionTestPollResult @((New-SessionTestSignal 'stop' 'projectx'))
        $controller.PollTick()
        $script:SessionLog.Count | Should Be 2
        $script:SessionLog[1] | Should BeExactly 'attention: match hwnd=9501 session-tab="projectx"'
        $controller.Dispose()
    }
}
