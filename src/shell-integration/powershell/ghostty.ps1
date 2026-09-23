if ($env:GHOSTTY_SHELL_INTEGRATION_NO_PWSH) { return }
if ($env:TERM_PROGRAM -ne 'ghostty') { return }
if ($global:__GhosttyState) { return }

$global:__GhosttyState = @{
    Esc          = [string][char]27
    Bel          = [string][char]7
    Features     = @(($env:GHOSTTY_SHELL_FEATURES -split ',') | Where-Object { $_ })
    Prompt       = $function:prompt
    ReadLine     = $null
    Executing    = $false
    Started      = $false
    LastError    = $null
    Wrapped      = $false
    LastCwd      = $null
    HostName     = [System.Net.Dns]::GetHostName()
    Width        = $Host.UI.RawUI.WindowSize.Width
    PromptAbove  = @()
    PromptTail   = 0
    Pending      = 0
    Settle       = 0
    Redraw       = [bool]($env:GHOSTTY_BIN_DIR -and (Test-Path -LiteralPath (Join-Path $env:GHOSTTY_BIN_DIR 'conpty.dll')))
}

function global:__Ghostty-HasFeature([string]$name) {
    foreach ($f in $global:__GhosttyState.Features) {
        if ($f -eq $name -or $f.StartsWith("${name}:")) { return $true }
    }
    return $false
}

function global:__Ghostty-CwdUrl {
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($loc.Provider.Name -ne 'FileSystem') { return $null }
    $path = $loc.ProviderPath
    if ($path.StartsWith('\\')) { return $null }
    $segments = $path.Replace('\', '/').Split('/')
    $encoded = for ($i = 0; $i -lt $segments.Length; $i++) {
        $s = $segments[$i]
        if ($i -eq 0 -and $s -match '^[A-Za-z]:$') { $s } else { [Uri]::EscapeDataString($s) }
    }
    $joined = $encoded -join '/'
    if (-not $joined.StartsWith('/')) { $joined = '/' + $joined }
    return "file://$($global:__GhosttyState.HostName)$joined"
}

function global:__Ghostty-WrapReadLine {
    $state = $global:__GhosttyState
    if ($state.Wrapped) { return }
    if (-not (Test-Path -Path Function:PSConsoleHostReadLine)) { return }
    $readLine = Get-Item -Path Function:PSConsoleHostReadLine
    $state.ReadLine = $readLine.ScriptBlock
    $state.Wrapped = $true

    function global:PSConsoleHostReadLine {
        $state = $global:__GhosttyState
        $line = & $state.ReadLine
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $e = $state.Esc
            $b = $state.Bel
            $out = ''
            if (__Ghostty-HasFeature 'cursor') { $out += "$e[0 q" }
            if (__Ghostty-HasFeature 'title') {
                $title = ($line -replace '[\x00-\x1f\x7f]', ' ').Trim()
                $out += "$e]2;$title$b"
            }
            $out += "$e]133;C;$b"
            [Console]::Write($out)
            $state.Executing = $true
        }
        $line
    }
}

function global:__Ghostty-VisibleWidth([string]$text) {
    $text = [regex]::Replace($text, '\x1b\[(\d*)C', { param($m) ' ' * [Math]::Max(1, [int]('0' + $m.Groups[1].Value)) })
    $text = [regex]::Replace($text, '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '')
    $text = [regex]::Replace($text, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
    $text = [regex]::Replace($text, '\x1b.', '')
    $text = [regex]::Replace($text, '[\x00-\x1f\x7f]', '')
    return [Globalization.StringInfo]::new($text).LengthInTextElements
}

function global:__Ghostty-RecordPrompt([string]$text) {
    $state = $global:__GhosttyState
    $lines = $text -split "`n"
    $state.PromptAbove = @(if ($lines.Count -gt 1) {
        foreach ($line in $lines[0..($lines.Count - 2)]) { __Ghostty-VisibleWidth $line }
    })
    $last = $lines[-1]
    $mark = $last.IndexOf("$($state.Esc)]133;B")
    if ($mark -ge 0) { $last = $last.Substring(0, $mark) }
    $state.PromptTail = __Ghostty-VisibleWidth $last
    $state.Width = $Host.UI.RawUI.WindowSize.Width
}

if ($global:__GhosttyState.Redraw -and (Get-Module PSReadLine)) {
    $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -SupportEvent -Action {
        $state = $global:__GhosttyState
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -le 0) { return }
        if ($width -eq $state.Width) {
            $state.Pending = 0
            if ($state.Settle -eq 0) { return }
            $state.Settle--
            if ($state.Settle -gt 0) { return }
        } elseif ($width -ne $state.Pending) { $state.Pending = $width; return }
        $buffer = $null
        $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$buffer, [ref]$cursor)
        $tail = $state.PromptTail + $cursor
        $separate = [Math]::Floor($tail / $width)
        foreach ($len in $state.PromptAbove) { $separate += [Math]::Max(1, [Math]::Ceiling($len / $width)) }
        $rows = $separate
        $x = $Host.UI.RawUI.CursorPosition.X
        if ($state.PromptAbove.Count -gt 0 -and $x -ne ($tail % $width)) {
            $joined = $tail
            foreach ($len in $state.PromptAbove) { $joined += $len }
            if ($x -eq ($joined % $width)) { $rows = [Math]::Floor($joined / $width) }
        }
        $top = [Math]::Max(0, $Host.UI.RawUI.CursorPosition.Y - $rows)
        if ($Host.UI.RawUI.WindowSize.Width -ne $width) { return }
        if ($state.Pending -ne 0) { $state.Settle = 3 }
        $state.Pending = 0
        $state.Width = $width
        [Console]::Write("$($state.Esc)[$($top + 1);1H$($state.Esc)[J")
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, $top)
    }
}

function global:prompt {
    $ok = $global:?
    $native = $global:LASTEXITCODE
    $state = $global:__GhosttyState
    $e = $state.Esc
    $b = $state.Bel

    __Ghostty-WrapReadLine

    $out = ''
    if ($state.Started -and ($state.Executing -or -not $state.Wrapped)) {
        $code = 0
        if (-not $ok) {
            $code = 1
            $newError = $global:Error.Count -gt 0 -and
                -not [object]::ReferenceEquals($global:Error[0], $state.LastError)
            if (-not $newError -and $native -is [int] -and $native -ne 0) { $code = $native }
        }
        if (-not $state.Wrapped) { $out += "$e]133;C;$b" }
        $out += "$e]133;D;$code$b"
    }
    $state.Executing = $false
    $state.Started = $true

    $cwd = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    if ($cwd -ne $state.LastCwd) {
        $state.LastCwd = $cwd
        $url = __Ghostty-CwdUrl
        if ($url) { $out += "$e]7;$url$b" }
    }

    if (__Ghostty-HasFeature 'title') { $out += "$e]2;$cwd$b" }

    if (__Ghostty-HasFeature 'cursor') {
        if (__Ghostty-HasFeature 'cursor:steady') { $out += "$e[6 q" } else { $out += "$e[5 q" }
    }

    [Console]::Write($out)

    $original = if ($state.Prompt) { & $state.Prompt } else { "PS $cwd$('>' * ($NestedPromptLevel + 1)) " }
    if ($null -ne $native) { $global:LASTEXITCODE = $native }
    $state.LastError = if ($global:Error.Count -gt 0) { $global:Error[0] } else { $null }
    $text = $original -join ''
    __Ghostty-RecordPrompt $text
    "$e]133;A;redraw=0$b$text$e]133;B$b"
}
