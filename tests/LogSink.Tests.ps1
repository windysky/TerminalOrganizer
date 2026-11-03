# SPEC-TRAY-017 M1 acceptance suite (Pester 3.4.0, Windows PowerShell 5.1).
# Run through test.ps1, which builds first and starts a fresh powershell.exe.
# Expected values come from acceptance.md AC-001..AC-003 and plan.md section J
# (the D-2 sanitize mapping), never from the code under test.
# This file stays pure ASCII (PS 5.1 reads a BOM-less .ps1 as ANSI): every control
# or non-ASCII character (CR, LF, TAB, NUL, SOH, VT, US, DEL, U+FFFD) is built
# from [char] codes, never typed literally.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$coreDll = Join-Path $repoRoot 'bin\TerminalOrganizer.Core.dll'
$appExe = Join-Path $repoRoot 'bin\TerminalOrganizer.App.exe'

# Byte-load keeps the files unlocked so build.ps1 can rebuild while this session runs.
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($coreDll))
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($appExe))

# D-2 fixture characters, built from [char] codes so this file stays pure ASCII.
$script:LkCR = [string][char]13          # CR  U+000D -> two-char literal escape
$script:LkLF = [string][char]10          # LF  U+000A -> two-char literal escape
$script:LkCRLF = $script:LkCR + $script:LkLF
$script:LkTAB = [string][char]9          # TAB U+0009 -> preserved verbatim per D-2
$script:LkFFFD = [string][char]0xFFFD    # U+FFFD replacement character

function New-LkSinkPath {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('tray017log-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    return (Join-Path $tempDir 'sink.log')
}

function Read-LkRaw([string]$FilePath) {
    # Explicit UTF-8: the sink's File.AppendAllText writes UTF-8 without BOM
    # (a U+FFFD in the sanitized line becomes EF BF BD on disk).
    return [IO.File]::ReadAllText($FilePath, [Text.Encoding]::UTF8)
}

Describe 'AC-001 forged-LF title yields exactly one sanitized log line (REQ-LOG-001)' {
    It 'a title-like payload abc + LF + forged timestamp produces ONE physical line, with the forged text inline after the visible backslash-n escape' {
        $logPath = New-LkSinkPath
        try {
            $sink = [TerminalOrganizer.App.LogSink]::new($logPath)
            $sink.Append('abc' + [char]10 + '2026-01-01 00:00:00 forged prefix')
            $raw = Read-LkRaw $logPath
            # Exactly one physical line: the only CR and the only LF in the file are the
            # single trailing Environment.NewLine terminator.
            ($raw.Split([char]10).Count - 1) | Should Be 1
            ($raw.Split([char]13).Count - 1) | Should Be 1
            $raw.EndsWith($script:LkCRLF) | Should Be $true
            # The written line body carries no raw CR/LF; the forged prefix survives only
            # INLINE, after the two-character visible backslash-n escape.
            $body = $raw.Substring(0, $raw.Length - 2)
            $body.Contains($script:LkCR) | Should Be $false
            $body.Contains($script:LkLF) | Should Be $false
            $body | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} abc\\n2026-01-01 00:00:00 forged prefix$'
        }
        finally {
            Remove-Item -Recurse -Force (Split-Path -Parent $logPath) -ErrorAction SilentlyContinue
        }
    }
}

Describe 'AC-002 CR/CRLF/mixed neutralized with content verbatim (REQ-LOG-001, REQ-LOG-002)' {
    It 'CR-only, CRLF, and mixed A/CR/B/LF/C/CRLF/D appends each yield one physical line; bodies carry zero raw CR/LF; non-control characters appear verbatim in order' {
        $logPath = New-LkSinkPath
        try {
            $sink = [TerminalOrganizer.App.LogSink]::new($logPath)
            $sink.Append('cr-only' + [char]13 + 'tail')
            $sink.Append('crlf' + [char]13 + [char]10 + 'tail')
            $sink.Append('A' + [char]13 + 'B' + [char]10 + 'C' + [char]13 + [char]10 + 'D')
            $raw = Read-LkRaw $logPath
            # Three Appends -> exactly three physical lines (three terminators, nothing trailing).
            ($raw.Split([char]10).Count - 1) | Should Be 3
            ($raw.Split([char]13).Count - 1) | Should Be 3
            $parts = $raw -split $script:LkCRLF
            $parts.Count | Should Be 4
            $parts[3] | Should Be ''
            # Zero raw CR and zero raw LF inside any written line body.
            ($parts[0..2] -join '').Contains($script:LkCR) | Should Be $false
            ($parts[0..2] -join '').Contains($script:LkLF) | Should Be $false
            # Every non-control character verbatim, in order, each line ending in its escapes.
            $parts[0] | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} cr-only\\rtail$'
            $parts[1] | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} crlf\\r\\ntail$'
            $parts[2] | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} A\\rB\\nC\\r\\nD$'
        }
        finally {
            Remove-Item -Recurse -Force (Split-Path -Parent $logPath) -ErrorAction SilentlyContinue
        }
    }
}

Describe 'AC-003 control-character policy per D-2 (REQ-LOG-002)' {
    It 'TAB survives verbatim; NUL/SOH/VT/US/DEL each render as U+FFFD; no byte in [0x00-0x08, 0x0A-0x1F, 0x7F] remains in the written line' {
        $logPath = New-LkSinkPath
        try {
            $sink = [TerminalOrganizer.App.LogSink]::new($logPath)
            $payload = 'pre' + [char]9
            $payload = $payload + '|nul' + [char]0
            $payload = $payload + '|soh' + [char]1
            $payload = $payload + '|vt' + [char]11
            $payload = $payload + '|us' + [char]31
            $payload = $payload + '|del' + [char]127
            $payload = $payload + '|post'
            $sink.Append($payload)
            $raw = Read-LkRaw $logPath
            ($raw.Split([char]10).Count - 1) | Should Be 1
            $raw.EndsWith($script:LkCRLF) | Should Be $true
            $body = $raw.Substring(0, $raw.Length - 2)
            # Prefix shape unchanged (plan.md section J): yyyy-MM-dd HH:mm:ss + space = 20 chars.
            $body | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} '
            $expectedTail = 'pre' + $script:LkTAB
            $expectedTail = $expectedTail + '|nul' + $script:LkFFFD
            $expectedTail = $expectedTail + '|soh' + $script:LkFFFD
            $expectedTail = $expectedTail + '|vt' + $script:LkFFFD
            $expectedTail = $expectedTail + '|us' + $script:LkFFFD
            $expectedTail = $expectedTail + '|del' + $script:LkFFFD
            $expectedTail = $expectedTail + '|post'
            $body.Substring(20) | Should BeExactly $expectedTail
            # TAB preserved; the five mapped controls gone; nothing in the D-2 forbidden set remains.
            $body.Contains($script:LkTAB) | Should Be $true
            $bad = @($body.ToCharArray() | Where-Object {
                ([int]$_ -le 8) -or (([int]$_ -ge 10) -and ([int]$_ -le 31)) -or ([int]$_ -eq 127) })
            $bad.Count | Should Be 0
        }
        finally {
            Remove-Item -Recurse -Force (Split-Path -Parent $logPath) -ErrorAction SilentlyContinue
        }
    }
}
