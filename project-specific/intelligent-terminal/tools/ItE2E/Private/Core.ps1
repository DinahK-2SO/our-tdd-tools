. ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..\common\tools\Process.ps1')))
# Core.ps1 — process execution, JSON, waiting, logging.
# These are the lowest-level bricks. Everything else builds on them.

$script:ItE2EVerbose = [bool]$env:ITE2E_VERBOSE

function Get-ItArtifactRoot {
    <#
    .SYNOPSIS
        Return the run-scoped artifact directory used by the current E2E invocation.
    #>
    [CmdletBinding()]
    param([switch]$Create)

    $root = if ($env:ITE2E_ARTIFACT_ROOT) {
        [IO.Path]::GetFullPath($env:ITE2E_ARTIFACT_ROOT)
    }
    else {
        $kitRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        [IO.Path]::GetFullPath((Join-Path $kitRoot "artifacts\manual-$PID"))
    }
    if ($Create) {
        New-Item -ItemType Directory -Force -Path $root | Out-Null
    }
    $root
}

function Get-ItArtifactPath {
    <#
    .SYNOPSIS
        Resolve a path below the run-scoped artifact root and optionally create its parent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [switch]$CreateParent
    )

    if ([IO.Path]::IsPathRooted($ChildPath)) {
        throw 'Artifact child paths must be relative.'
    }
    $root = Get-ItArtifactRoot -Create:$CreateParent
    $path = [IO.Path]::GetFullPath((Join-Path $root $ChildPath))
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Artifact path escapes the run root: $ChildPath"
    }
    if ($CreateParent) {
        New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    }
    $path
}

function Write-ItLog {
    <#
    .SYNOPSIS
        Structured framework log line (always to the host's verbose/debug stream,
        and to $script:ItE2ELogFile when a harness is active).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Level, $Message
    if ($script:ItE2ELogFile) {
        try { Add-Content -LiteralPath $script:ItE2ELogFile -Value $line -Encoding utf8 } catch { }
    }
    switch ($Level) {
        'ERROR' { Write-Verbose $line; if ($script:ItE2EVerbose) { Write-Host $line -ForegroundColor Red } }
        'WARN' { Write-Verbose $line; if ($script:ItE2EVerbose) { Write-Host $line -ForegroundColor Yellow } }
        default { Write-Verbose $line; if ($script:ItE2EVerbose) { Write-Host $line } }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 30,
        [hashtable]$Environment,
        [string]$WorkingDirectory
    )
    Write-ItLog -Level TRACE -Message "exec: $FilePath $($Arguments -join ' ')"
    Invoke-WinpdProcess @PSBoundParameters
}

function ConvertFrom-JsonSafe {
    <# Tolerant JSON parse: returns $null on empty/invalid instead of throwing. #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][string]$InputObject)
    process {
        if ([string]::IsNullOrWhiteSpace($InputObject)) { return $null }
        try { return $InputObject | ConvertFrom-Json -Depth 64 } catch { return $null }
    }
}

function Wait-Until {
    <#
    .SYNOPSIS
        Poll a predicate scriptblock until it returns a truthy value or the timeout
        elapses. Returns the last predicate result. Throws on timeout unless -Quiet.
    .NOTES
        This is the ONLY sanctioned wait mechanism — never Start-Sleep a fixed wait.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSec = 30,
        [double]$IntervalSec = 0.5,
        [string]$Because = 'condition',
        [switch]$Quiet
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    do {
        try { $last = & $Condition } catch { $last = $null; Write-ItLog -Level TRACE -Message "Wait-Until predicate threw: $_" }
        if ($last) { return $last }
        Start-Sleep -Seconds $IntervalSec
    } while ((Get-Date) -lt $deadline)
    if ($Quiet) { return $last }
    throw "Wait-Until timed out after ${TimeoutSec}s waiting for: $Because"
}

function Test-Until {
    <# Boolean-returning Wait-Until (never throws). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSec = 30,
        [double]$IntervalSec = 0.5
    )
    [bool](Wait-Until -Condition $Condition -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec -Quiet)
}
