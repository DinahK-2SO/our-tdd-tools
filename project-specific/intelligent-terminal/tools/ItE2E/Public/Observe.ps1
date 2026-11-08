# Observe.ps1 — read-only capture: logs, the wtcli event stream, and context bundles.

function Get-WtCaptureGeometry {
    <#
    .SYNOPSIS
        Measure rendered terminal text without assuming that row count equals viewport size.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Capture')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Capture')][object]$App,
        [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$SessionId,
        [Parameter(ParameterSetName = 'Capture')][int]$MaxLines = 500,
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string]$Text
    )

    if ($PSCmdlet.ParameterSetName -eq 'Capture') {
        $Text = Get-WtCapture -App $App -SessionId $SessionId -MaxLines $MaxLines
    }
    $lines = if ($Text.Length -eq 0) { @('') } else { @($Text -split "`r?`n") }
    Initialize-ItTerminalWidth
    $widths = @($lines | ForEach-Object { [ItE2E.ItTerminalWidth]::GetWidth($_, 8) })
    [pscustomobject]@{
        Rows = $lines.Count
        NonEmptyRows = @($lines | Where-Object { $_.Length -gt 0 }).Count
        Columns = [int](($widths | Measure-Object -Maximum).Maximum)
        LineWidths = $widths
        Text = $Text
    }
}

function Initialize-ItTerminalWidth {
    if ('ItE2E.ItTerminalWidth' -as [type]) { return }
    Add-Type -Namespace 'ItE2E' -Name 'ItTerminalWidth' -MemberDefinition @'
    public static int GetWidth(string text, int tabWidth) {
        int width = 0;
        var elements = System.Globalization.StringInfo.GetTextElementEnumerator(text ?? "");
        while (elements.MoveNext()) {
            string element = (string)elements.Current;
            if (element == "\t") {
                width += tabWidth - (width % tabWidth);
                continue;
            }
            bool printable = false;
            bool wide = false;
            bool emojiPresentation = false;
            int regionalIndicators = 0;
            foreach (var rune in element.EnumerateRunes()) {
                int value = rune.Value;
                emojiPresentation |= value == 0xFE0F;
                if (value >= 0x1F1E6 && value <= 0x1F1FF) regionalIndicators++;
                var category = System.Text.Rune.GetUnicodeCategory(rune);
                if (category == System.Globalization.UnicodeCategory.Control ||
                    category == System.Globalization.UnicodeCategory.Format ||
                    category == System.Globalization.UnicodeCategory.NonSpacingMark ||
                    category == System.Globalization.UnicodeCategory.EnclosingMark) {
                    continue;
                }
                printable = true;
                wide |= IsWide(value);
            }
            if (printable) width += (wide || emojiPresentation || regionalIndicators >= 2) ? 2 : 1;
        }
        return width;
    }

    // Unicode 16 EastAsianWidth.txt entries whose property is Wide or Fullwidth.
    private static bool IsWide(int value) {
        return
                    (value >= 0x1100 && value <= 0x115F) ||
                    (value >= 0x231A && value <= 0x231B) ||
                    (value >= 0x2329 && value <= 0x232A) ||
                    (value >= 0x23E9 && value <= 0x23EC) ||
                    (value >= 0x23F0 && value <= 0x23F0) ||
                    (value >= 0x23F3 && value <= 0x23F3) ||
                    (value >= 0x25FD && value <= 0x25FE) ||
                    (value >= 0x2614 && value <= 0x2615) ||
                    (value >= 0x2630 && value <= 0x2637) ||
                    (value >= 0x2648 && value <= 0x2653) ||
                    (value >= 0x267F && value <= 0x267F) ||
                    (value >= 0x268A && value <= 0x268F) ||
                    (value >= 0x2693 && value <= 0x2693) ||
                    (value >= 0x26A1 && value <= 0x26A1) ||
                    (value >= 0x26AA && value <= 0x26AB) ||
                    (value >= 0x26BD && value <= 0x26BE) ||
                    (value >= 0x26C4 && value <= 0x26C5) ||
                    (value >= 0x26CE && value <= 0x26CE) ||
                    (value >= 0x26D4 && value <= 0x26D4) ||
                    (value >= 0x26EA && value <= 0x26EA) ||
                    (value >= 0x26F2 && value <= 0x26F3) ||
                    (value >= 0x26F5 && value <= 0x26F5) ||
                    (value >= 0x26FA && value <= 0x26FA) ||
                    (value >= 0x26FD && value <= 0x26FD) ||
                    (value >= 0x2705 && value <= 0x2705) ||
                    (value >= 0x270A && value <= 0x270B) ||
                    (value >= 0x2728 && value <= 0x2728) ||
                    (value >= 0x274C && value <= 0x274C) ||
                    (value >= 0x274E && value <= 0x274E) ||
                    (value >= 0x2753 && value <= 0x2755) ||
                    (value >= 0x2757 && value <= 0x2757) ||
                    (value >= 0x2795 && value <= 0x2797) ||
                    (value >= 0x27B0 && value <= 0x27B0) ||
                    (value >= 0x27BF && value <= 0x27BF) ||
                    (value >= 0x2B1B && value <= 0x2B1C) ||
                    (value >= 0x2B50 && value <= 0x2B50) ||
                    (value >= 0x2B55 && value <= 0x2B55) ||
                    (value >= 0x2E80 && value <= 0x2E99) ||
                    (value >= 0x2E9B && value <= 0x2EF3) ||
                    (value >= 0x2F00 && value <= 0x2FD5) ||
                    (value >= 0x2FF0 && value <= 0x303E) ||
                    (value >= 0x3041 && value <= 0x3096) ||
                    (value >= 0x3099 && value <= 0x30FF) ||
                    (value >= 0x3105 && value <= 0x312F) ||
                    (value >= 0x3131 && value <= 0x318E) ||
                    (value >= 0x3190 && value <= 0x31E5) ||
                    (value >= 0x31EF && value <= 0x321E) ||
                    (value >= 0x3220 && value <= 0x3247) ||
                    (value >= 0x3250 && value <= 0xA48C) ||
                    (value >= 0xA490 && value <= 0xA4C6) ||
                    (value >= 0xA960 && value <= 0xA97C) ||
                    (value >= 0xAC00 && value <= 0xD7A3) ||
                    (value >= 0xF900 && value <= 0xFAFF) ||
                    (value >= 0xFE10 && value <= 0xFE19) ||
                    (value >= 0xFE30 && value <= 0xFE52) ||
                    (value >= 0xFE54 && value <= 0xFE66) ||
                    (value >= 0xFE68 && value <= 0xFE6B) ||
                    (value >= 0xFF01 && value <= 0xFF60) ||
                    (value >= 0xFFE0 && value <= 0xFFE6) ||
                    (value >= 0x16FE0 && value <= 0x16FE4) ||
                    (value >= 0x16FF0 && value <= 0x16FF1) ||
                    (value >= 0x17000 && value <= 0x187F7) ||
                    (value >= 0x18800 && value <= 0x18CD5) ||
                    (value >= 0x18CFF && value <= 0x18D08) ||
                    (value >= 0x1AFF0 && value <= 0x1AFF3) ||
                    (value >= 0x1AFF5 && value <= 0x1AFFB) ||
                    (value >= 0x1AFFD && value <= 0x1AFFE) ||
                    (value >= 0x1B000 && value <= 0x1B122) ||
                    (value >= 0x1B132 && value <= 0x1B132) ||
                    (value >= 0x1B150 && value <= 0x1B152) ||
                    (value >= 0x1B155 && value <= 0x1B155) ||
                    (value >= 0x1B164 && value <= 0x1B167) ||
                    (value >= 0x1B170 && value <= 0x1B2FB) ||
                    (value >= 0x1D300 && value <= 0x1D356) ||
                    (value >= 0x1D360 && value <= 0x1D376) ||
                    (value >= 0x1F004 && value <= 0x1F004) ||
                    (value >= 0x1F0CF && value <= 0x1F0CF) ||
                    (value >= 0x1F18E && value <= 0x1F18E) ||
                    (value >= 0x1F191 && value <= 0x1F19A) ||
                    (value >= 0x1F200 && value <= 0x1F202) ||
                    (value >= 0x1F210 && value <= 0x1F23B) ||
                    (value >= 0x1F240 && value <= 0x1F248) ||
                    (value >= 0x1F250 && value <= 0x1F251) ||
                    (value >= 0x1F260 && value <= 0x1F265) ||
                    (value >= 0x1F300 && value <= 0x1F320) ||
                    (value >= 0x1F32D && value <= 0x1F335) ||
                    (value >= 0x1F337 && value <= 0x1F37C) ||
                    (value >= 0x1F37E && value <= 0x1F393) ||
                    (value >= 0x1F3A0 && value <= 0x1F3CA) ||
                    (value >= 0x1F3CF && value <= 0x1F3D3) ||
                    (value >= 0x1F3E0 && value <= 0x1F3F0) ||
                    (value >= 0x1F3F4 && value <= 0x1F3F4) ||
                    (value >= 0x1F3F8 && value <= 0x1F43E) ||
                    (value >= 0x1F440 && value <= 0x1F440) ||
                    (value >= 0x1F442 && value <= 0x1F4FC) ||
                    (value >= 0x1F4FF && value <= 0x1F53D) ||
                    (value >= 0x1F54B && value <= 0x1F54E) ||
                    (value >= 0x1F550 && value <= 0x1F567) ||
                    (value >= 0x1F57A && value <= 0x1F57A) ||
                    (value >= 0x1F595 && value <= 0x1F596) ||
                    (value >= 0x1F5A4 && value <= 0x1F5A4) ||
                    (value >= 0x1F5FB && value <= 0x1F64F) ||
                    (value >= 0x1F680 && value <= 0x1F6C5) ||
                    (value >= 0x1F6CC && value <= 0x1F6CC) ||
                    (value >= 0x1F6D0 && value <= 0x1F6D2) ||
                    (value >= 0x1F6D5 && value <= 0x1F6D7) ||
                    (value >= 0x1F6DC && value <= 0x1F6DF) ||
                    (value >= 0x1F6EB && value <= 0x1F6EC) ||
                    (value >= 0x1F6F4 && value <= 0x1F6FC) ||
                    (value >= 0x1F7E0 && value <= 0x1F7EB) ||
                    (value >= 0x1F7F0 && value <= 0x1F7F0) ||
                    (value >= 0x1F90C && value <= 0x1F93A) ||
                    (value >= 0x1F93C && value <= 0x1F945) ||
                    (value >= 0x1F947 && value <= 0x1F9FF) ||
                    (value >= 0x1FA70 && value <= 0x1FA7C) ||
                    (value >= 0x1FA80 && value <= 0x1FA89) ||
                    (value >= 0x1FA8F && value <= 0x1FAC6) ||
                    (value >= 0x1FACE && value <= 0x1FADC) ||
                    (value >= 0x1FADF && value <= 0x1FAE9) ||
                    (value >= 0x1FAF0 && value <= 0x1FAF8) ||
                    (value >= 0x20000 && value <= 0x2FFFD) ||
                    (value >= 0x30000 && value <= 0x3FFFD);
    }
'@
}

# ── Logs ─────────────────────────────────────────────────────────────────────
function Get-ItLogDir {
    <# Newest versioned log dir (prefer the package version, else most-recent). #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$App)
    process {
        if (-not (Test-Path $App.LogRootDir)) { return $null }
        $byVer = Join-Path $App.LogRootDir $App.Version
        if (Test-Path $byVer) { return $byVer }
        Get-ChildItem $App.LogRootDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
}

function Initialize-LogOffsets {
    <# Record current byte length of each log file, so -SinceStart reads only new data. #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$App)
    process {
        $App.LogStartOffset = @{}
        $dir = Get-ItLogDir -App $App
        if (-not $dir) { return $App }
        foreach ($f in Get-ChildItem $dir -Filter *.log -ErrorAction SilentlyContinue) {
            $App.LogStartOffset[$f.Name] = $f.Length
        }
        $App
    }
}

function Get-ItLogText {
    <#
    .SYNOPSIS
        Read log text from the versioned dir. -Name filters file names (wildcard).
        -SinceStart returns only bytes appended after Initialize-LogOffsets (this test's slice).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [string]$Name = '*',
        [switch]$SinceStart
    )
    process {
        $dir = Get-ItLogDir -App $App
        if (-not $dir) { return '' }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($f in Get-ChildItem $dir -Filter *.log -ErrorAction SilentlyContinue | Where-Object Name -like $Name) {
            $start = if ($SinceStart -and $App.LogStartOffset.ContainsKey($f.Name)) { [int64]$App.LogStartOffset[$f.Name] } else { 0 }
            try {
                $fs = [System.IO.FileStream]::new($f.FullName, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($start -gt 0 -and $start -le $fs.Length) { $fs.Seek($start, 'Begin') | Out-Null }
                    $sr = [System.IO.StreamReader]::new($fs)
                    [void]$sb.AppendLine("# ==== $($f.Name) ====")
                    [void]$sb.Append($sr.ReadToEnd())
                }
                finally { $fs.Dispose() }
            }
            catch { Write-ItLog -Level WARN -Message "read log $($f.Name) failed: $_" }
        }
        $sb.ToString()
    }
}

# ── Event stream (wtcli listen) ──────────────────────────────────────────────
function Start-WtEventListener {
    <#
    .SYNOPSIS
        Start a background `wtcli listen --json` and buffer parsed events into a
        synchronized list. Start this BEFORE the action you want to observe.
    .OUTPUTS
        Listener object: @{ Process; Events; Reg; App }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [string]$EventFilter,
        [string]$SessionId,
        [switch]$SkipAuthenticate
    )
    process {
        if (-not $App.ComClsid) { Resolve-WtComClsid -App $App | Out-Null }
        $args = @('--json')
        if ($SkipAuthenticate) { $args += '--skip-authenticate' }
        $args += 'listen'
        if ($SessionId) { $args += @('-t', $SessionId) }
        if ($EventFilter) { $args += @('--event', $EventFilter) }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $App.WtcliPath
        foreach ($a in $args) { $psi.ArgumentList.Add([string]$a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.Environment['WT_COM_CLSID'] = $App.ComClsid

        $events = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        $p = [System.Diagnostics.Process]::new(); $p.StartInfo = $psi
        $handler = {
            if ($null -ne $EventArgs.Data) {
                try { $obj = $EventArgs.Data | ConvertFrom-Json -Depth 64; [void]$Event.MessageData.Add($obj) } catch { }
            }
        }
        # Explicit, unique SourceIdentifier so Stop-WtEventListener can unregister
        # deterministically (don't rely on the auto-generated job name).
        $sourceId = "ItE2E.WtEventListener.$([guid]::NewGuid())"
        $reg = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $handler -MessageData $events -SourceIdentifier $sourceId
        [void]$p.Start(); $p.BeginOutputReadLine(); $p.BeginErrorReadLine()
        Write-ItLog -Level INFO -Message "Event listener started (filter='$EventFilter' session='$SessionId')."
        [pscustomobject]@{ Process = $p; Events = $events; Reg = $reg; SourceId = $sourceId; App = $App }
    }
}

function Get-WtEvents {
    <# Snapshot of buffered events, optionally filtered by predicate. #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Listener, [scriptblock]$Predicate)
    process {
        $snap = @($Listener.Events.ToArray())
        if ($Predicate) { $snap = $snap | Where-Object $Predicate }
        $snap
    }
}

function Wait-WtEvent {
    <#
    .SYNOPSIS
        Wait until a buffered event matches the predicate. Requires a listener started
        before the triggering action. Returns the first matching event.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Listener,
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [int]$TimeoutSec = 30
    )
    process {
        Wait-Until -TimeoutSec $TimeoutSec -IntervalSec 0.4 -Because "a matching WT event" -Condition {
            @(Get-WtEvents -Listener $Listener -Predicate $Predicate) | Select-Object -First 1
        }
    }
}

function Stop-WtEventListener {
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$Listener)
    process {
        try { if (-not $Listener.Process.HasExited) { $Listener.Process.Kill($true) } } catch { }
        # Prefer the explicit SourceIdentifier we assigned; fall back to the job name.
        $sid = if ($Listener.PSObject.Properties.Name -contains 'SourceId' -and $Listener.SourceId) { $Listener.SourceId } else { $Listener.Reg.Name }
        try { if ($sid) { Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue } } catch { }
        try { $Listener.Process.Dispose() } catch { }
    }
}

# ── Context bundle (for Verify.AI / diagnostics) ─────────────────────────────
function Get-ContextBundle {
    <#
    .SYNOPSIS
        Aggregate the observable state into one object: active pane buffer, UI tree,
        recent log slice, and a screenshot path. Consumed by Assert-AI and failure dumps.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [string]$SessionId, [switch]$Screenshot)
    process {
        $active = try { Get-ActivePane -App $App } catch { $null }
        $sid = if ($SessionId) { $SessionId } elseif ($active) { $active.session_id } else { $null }
        $paneText = if ($sid) { try { Get-WtCapture -App $App -SessionId $sid -MaxLines 100 } catch { '' } } else { '' }
        $tree = try { Get-UiTree -App $App -Depth 4 } catch { '' }
        $logSlice = try { Get-ItLogText -App $App -SinceStart } catch { '' }
        $shot = $null
        if ($Screenshot) {
            $shot = Save-UiScreenshot -App $App -Path (Get-ItArtifactPath -ChildPath "context\shot-$([guid]::NewGuid().ToString('N')).png" -CreateParent)
        }
        [pscustomobject]@{
            Package    = $App.Package
            SessionId  = $sid
            PaneText   = $paneText
            UiTree     = $tree
            LogSlice   = $logSlice
            Screenshot = $shot
            Timestamp  = (Get-Date).ToString('o')
        }
    }
}

function ConvertTo-ContextText {
    <# Flatten a context bundle to a compact text block for an LLM judge. #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$Bundle)
    process {
        @"
== ACTIVE PANE BUFFER ==
$($Bundle.PaneText)

== UI TREE (depth 4) ==
$($Bundle.UiTree)

== RECENT LOG SLICE ==
$($Bundle.LogSlice)
"@
    }
}
