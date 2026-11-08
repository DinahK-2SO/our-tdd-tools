<#
.SYNOPSIS
    Run the bounded local build/deploy/freshness/E2E workflow with a durable phase journal.

.DESCRIPTION
    This runner keeps all machine-side phases in one process. If an outer execution layer stops
    waiting, the runner can still finish and records its final state atomically. It does not wake
    an ended AI-agent turn; agents should invoke it synchronously without a tool timeout.

    Build/deploy deliberately does not pass -Launch. A requested E2E suite owns its exact app
    launch, which avoids stealing foreground focus during compilation and freshness checks.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [switch]$SkipWtaTests,
    [switch]$SkipDeploy,
    [switch]$ReplaceExistingDevRegistration,
    [switch]$CloseRunningPackageProcesses,
    [switch]$WtaOnly,
    [string]$NativeReceiptPath,
    [string[]]$SourcePaths,
    [string[]]$E2EPath,
    [string[]]$E2ETag,
    [ValidateSet('Dev')][string]$PackageSelector = 'Dev',
    [string]$OutDir,
    [string]$E2ERunner = (Join-Path $PSScriptRoot 'Invoke-LocalTddReport.ps1'),
    [Parameter(DontShow)][string]$BuildScript = (Join-Path $PSScriptRoot 'Invoke-BuildDeploy.ps1'),
    [Parameter(DontShow)][string]$WtaRefreshScript = (Join-Path $PSScriptRoot 'Invoke-WtaRefresh.ps1'),
    [Parameter(DontShow)][string]$ReceiptPath = (Join-Path $PSScriptRoot 'artifacts\build-receipt.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$kitRoot = $PSScriptRoot
$repoRoot = (& git -C $kitRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { throw 'Unable to resolve the repository root.' }
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[a-f0-9]{40}$') { throw 'Unable to resolve the exact Git HEAD.' }

if ($E2EPath -and $SkipDeploy) {
    throw 'Packaged E2E cannot run with -SkipDeploy.'
}
if ($E2EPath -and $Configuration -ne 'Debug') {
    throw 'The local packaged E2E pipeline requires a Debug deployment.'
}
if ($WtaOnly) {
    if ($Configuration -ne 'Debug' -or $SkipDeploy -or $ReplaceExistingDevRegistration -or
        $CloseRunningPackageProcesses -or $SourcePaths) {
        throw 'WtaOnly requires Debug deployment and the native receipt scope; it cannot replace registration or close processes.'
    }
    if (-not $NativeReceiptPath -or -not (Test-Path -LiteralPath $NativeReceiptPath -PathType Leaf)) {
        throw 'WtaOnly requires an existing native build receipt.'
    }
    $NativeReceiptPath = [IO.Path]::GetFullPath($NativeReceiptPath)
}
$selectedBuildScript = if ($WtaOnly) { $WtaRefreshScript } else { $BuildScript }
foreach ($requiredScript in @($selectedBuildScript) + @($E2ERunner | Where-Object { $E2EPath })) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Required pipeline script is missing: $requiredScript"
    }
}

$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
if (-not $OutDir) {
    $OutDir = Join-Path $kitRoot "artifacts\pipeline-$($head.Substring(0, 9))-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
$OutDir = [IO.Path]::GetFullPath($OutDir)
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (Test-Path -LiteralPath $OutDir -PathType Container) {
    $existingOutput = @(Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction Stop)
    if ($existingOutput.Count -gt 0) {
        throw "Pipeline output directory must be new or empty: $OutDir"
    }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$journalPath = Join-Path $OutDir 'pipeline-state.json'
$lockPath = Join-Path $kitRoot 'artifacts\pipeline.lock'
New-Item -ItemType Directory -Force -Path (Split-Path $lockPath -Parent) | Out-Null

try {
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch {
    throw "Another local TDD pipeline owns '$lockPath'. Wait for it to finish or verify that process before retrying. $($_.Exception.Message)"
}

try {
    $processStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $state = [ordered]@{
        schemaVersion = 1
        runId = [guid]::NewGuid().ToString('N')
        status = 'running'
        currentPhase = $null
        startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        completedUtc = $null
        lastUpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        processId = $PID
        processStartUtc = $processStartUtc
        repoRoot = $repoRoot
        gitHead = $head
        configuration = $Configuration
        packageSelector = $PackageSelector
        sourceFingerprint = $null
        sourcePaths = @()
        sharedReceiptPath = $ReceiptPath
        receiptPath = $null
        receiptSha256 = $null
        e2eReportPath = $null
        e2eReportSha256 = $null
        e2eResultsPath = $null
        e2eResultsSha256 = $null
        e2eArtifactRoot = $null
        e2eTotals = $null
        error = $null
        invocation = [ordered]@{
            skipWtaTests = $SkipWtaTests.IsPresent
            skipDeploy = $SkipDeploy.IsPresent
            replaceExistingDevRegistration = $ReplaceExistingDevRegistration.IsPresent
            closeRunningPackageProcesses = $CloseRunningPackageProcesses.IsPresent
            wtaOnly = $WtaOnly.IsPresent
            nativeReceiptPath = $NativeReceiptPath
            requestedSourcePaths = @($SourcePaths)
            e2ePaths = @($E2EPath)
            e2eTags = @($E2ETag)
            e2eRunner = if ($E2EPath) { [IO.Path]::GetFullPath($E2ERunner) } else { $null }
        }
        phases = @()
    }
}
catch {
    $lock.Dispose()
    throw
}

function Save-PipelineState {
    $state.lastUpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $json = $state | ConvertTo-Json -Depth 8
    $temp = "$journalPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $journalPath, $true)
}

function Invoke-PipelinePhase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $phase = [ordered]@{
        name = $Name
        status = 'running'
        startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        completedUtc = $null
        exitCode = $null
        error = $null
    }
    $state.phases += $phase
    $state.currentPhase = $Name
    Save-PipelineState

    try {
        $global:LASTEXITCODE = 0
        & $Action
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        if ($code -ne 0) { throw "Phase '$Name' failed with exit code $code." }
        $phase.exitCode = 0
        $phase.status = 'passed'
    }
    catch {
        $code = if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 1 }
        $phase.exitCode = $code
        $phase.status = 'failed'
        $phase.error = $_.Exception.Message
        throw
    }
    finally {
        $phase.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Save-PipelineState
    }
}

function Assert-ReceiptSourceSnapshot {
    param([Parameter(Mandatory)]$Receipt)

    if (-not $Receipt.sourceFingerprint -or -not $Receipt.sourcePaths) {
        throw 'Build receipt is missing source fingerprint metadata.'
    }
    $fingerprint = & (Join-Path $kitRoot 'Get-LocalTddSourceFingerprint.ps1') `
        -RepoRoot $repoRoot `
        -SourcePaths @($Receipt.sourcePaths)
    if ($fingerprint.Head -ne $head) {
        throw "Current HEAD '$($fingerprint.Head)' does not match pipeline HEAD '$head'."
    }
    if ($fingerprint.Fingerprint -ne $Receipt.sourceFingerprint) {
        throw "Source fingerprint changed after build: receipt=$($Receipt.sourceFingerprint) current=$($fingerprint.Fingerprint)"
    }
}

$priorPackageSelector = $env:ITE2E_PACKAGE
$priorArtifactRoot = $env:ITE2E_ARTIFACT_ROOT
try {
    Save-PipelineState

    Invoke-PipelinePhase -Name 'preflight' -Action {
        $current = (& git -C $repoRoot rev-parse HEAD).Trim()
        if ($current -ne $head) { throw "HEAD changed before the pipeline started: $head -> $current" }
        if ($E2EPath -and $PackageSelector -ne 'Dev') {
            throw 'Exact local package evidence requires PackageSelector=Dev.'
        }
    }

    $buildStartedUtc = [DateTimeOffset]::UtcNow
    Invoke-PipelinePhase -Name 'build-deploy-freshness' -Action {
        if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
            Move-Item -LiteralPath $ReceiptPath -Destination (Join-Path $OutDir 'prior-build-receipt.json') -Force
            if ($WtaOnly -and $NativeReceiptPath -ieq $ReceiptPath) {
                $NativeReceiptPath = Join-Path $OutDir 'prior-build-receipt.json'
            }
        }
        $buildArgs = @{ Configuration = $Configuration }
        if ($SkipWtaTests) { $buildArgs.SkipWtaTests = $true }
        if ($SkipDeploy) { $buildArgs.SkipDeploy = $true }
        if ($ReplaceExistingDevRegistration) { $buildArgs.ReplaceExistingDevRegistration = $true }
        if ($CloseRunningPackageProcesses) { $buildArgs.CloseRunningPackageProcesses = $true }
        if ($SourcePaths) { $buildArgs.SourcePaths = $SourcePaths }

        # Do not pass -Launch here. Packaged E2E owns the exact window launch.
        if ($WtaOnly) {
            $refreshArgs = @{
                RepoRoot = $repoRoot; NativeReceiptPath = $NativeReceiptPath
                OutDir = (Join-Path $OutDir 'wta-refresh'); Configuration = $Configuration
            }
            if ($SkipWtaTests) { $refreshArgs.SkipWtaTests = $true }
            $refresh = & $WtaRefreshScript @refreshArgs
            if ($refresh.status -ne 'passed' -or -not (Test-Path -LiteralPath $refresh.receiptPath -PathType Leaf)) {
                throw 'WTA refresh did not produce a successful receipt.'
            }
            Copy-Item -LiteralPath $refresh.receiptPath -Destination $ReceiptPath
        }
        else { & $BuildScript @buildArgs }
        if ($LASTEXITCODE -ne 0) { throw "Build/deploy script failed with exit code $LASTEXITCODE." }
        if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
            throw "Build/deploy did not produce its receipt: $ReceiptPath"
        }
        $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
        if ($receipt.gitHead -ne $head) {
            throw "Receipt HEAD '$($receipt.gitHead)' does not match pipeline HEAD '$head'."
        }
        $receiptCreated = if ($receipt.createdUtc -is [DateTime]) {
            [DateTimeOffset]$receipt.createdUtc
        } else {
            [DateTimeOffset]::Parse([string]$receipt.createdUtc)
        }
        # ConvertFrom-Json can materialize ISO timestamps as DateTime and lose subsecond
        # precision. Keep a small serialization/filesystem tolerance while HEAD remains exact.
        if ($receiptCreated -lt $buildStartedUtc.AddSeconds(-2)) {
            throw "Receipt predates this build phase: $($receipt.createdUtc)"
        }
        if ($receiptCreated -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
            throw "Receipt has an implausible future creation time: $($receipt.createdUtc)"
        }
        if (-not $SkipDeploy -and -not $receipt.installVerified) {
            throw 'Receipt does not verify the installed package.'
        }
        Assert-ReceiptSourceSnapshot -Receipt $receipt

        $immutableReceiptPath = Join-Path $OutDir 'build-receipt.json'
        Copy-Item -LiteralPath $ReceiptPath -Destination $immutableReceiptPath
        $state.receiptPath = $immutableReceiptPath
        $state.receiptSha256 = (Get-FileHash -LiteralPath $immutableReceiptPath -Algorithm SHA256).Hash
        $state.sourceFingerprint = [string]$receipt.sourceFingerprint
        $state.sourcePaths = @($receipt.sourcePaths)
        Save-PipelineState
    }

    if ($E2EPath) {
        $e2eOutDir = Join-Path $OutDir 'e2e'
        $state.e2eArtifactRoot = Join-Path $e2eOutDir 'artifacts'
        $state.e2eReportPath = Join-Path $e2eOutDir 'summary.md'
        $state.e2eResultsPath = Join-Path $e2eOutDir 'results.xml'
        Invoke-PipelinePhase -Name 'packaged-e2e' -Action {
            if (Test-Path -LiteralPath $e2eOutDir) {
                throw "E2E output directory unexpectedly exists before the run: $e2eOutDir"
            }
            $env:ITE2E_PACKAGE = $PackageSelector
            $env:ITE2E_ARTIFACT_ROOT = $state.e2eArtifactRoot
            $runnerArgs = @('-NoProfile', '-File', $E2ERunner, '-OutDir', $e2eOutDir, '-Path')
            $runnerArgs += $E2EPath
            if ($E2ETag) {
                $runnerArgs += '-Tag'
                $runnerArgs += $E2ETag
            }
            & pwsh @runnerArgs
            if ($LASTEXITCODE -ne 0) { throw "E2E runner failed with exit code $LASTEXITCODE." }
            if (-not (Test-Path -LiteralPath $state.e2eReportPath -PathType Leaf)) {
                throw "E2E runner did not produce its summary: $($state.e2eReportPath)"
            }
            if (-not (Test-Path -LiteralPath $state.e2eResultsPath -PathType Leaf)) {
                throw "E2E runner did not produce NUnit results: $($state.e2eResultsPath)"
            }
            [xml]$results = Get-Content -LiteralPath $state.e2eResultsPath -Raw
            $root = $results.'test-results'
            if (-not $root) { throw "E2E results are not NUnit XML: $($state.e2eResultsPath)" }
            $cases = @($results.SelectNodes("//*[local-name()='test-case']"))
            $passed = @($cases | Where-Object {
                    $_.result -in @('Success', 'Passed') -or
                    ($_.success -eq 'True' -and $_.result -notin @('Failure', 'Error', 'Ignored', 'Skipped', 'Inconclusive', 'Invalid', 'NotRunnable'))
                }).Count
            $failures = @($cases | Where-Object { $_.result -in @('Failure', 'Error', 'Failed') }).Count
            $skipped = @($cases | Where-Object { $_.result -in @('Ignored', 'Skipped', 'NotRun') }).Count
            $invalid = $cases.Count - $passed - $failures - $skipped
            if ($cases.Count -le 0 -or $passed -le 0) {
                throw 'E2E runner produced no passing tests.'
            }
            if ($failures -ne 0) { throw "E2E result XML reports $failures failure(s)." }
            if ($invalid -ne 0) { throw "E2E result XML reports $invalid invalid/inconclusive outcome(s)." }
            $state.e2eTotals = [ordered]@{
                total = $cases.Count
                passed = $passed
                failed = $failures
                skipped = $skipped
                invalid = $invalid
            }
            $state.e2eReportSha256 = (Get-FileHash -LiteralPath $state.e2eReportPath -Algorithm SHA256).Hash
            $state.e2eResultsSha256 = (Get-FileHash -LiteralPath $state.e2eResultsPath -Algorithm SHA256).Hash
            Save-PipelineState
        }
    }

    Invoke-PipelinePhase -Name 'final-source-verification' -Action {
        $receiptHash = (Get-FileHash -LiteralPath $state.receiptPath -Algorithm SHA256).Hash
        if ($receiptHash -ne $state.receiptSha256) {
            throw "Run-local build receipt changed after validation: expected=$($state.receiptSha256) actual=$receiptHash"
        }
        $validatedReceipt = Get-Content -LiteralPath $state.receiptPath -Raw | ConvertFrom-Json
        Assert-ReceiptSourceSnapshot -Receipt $validatedReceipt
    }
    $state.status = 'passed'
    $state.currentPhase = $null
    $state.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-PipelineState
    Write-Host "Local TDD pipeline passed for $head" -ForegroundColor Green
    Write-Host "Journal: $journalPath"
    [pscustomobject]$state
}
catch {
    $state.status = 'failed'
    $state.error = $_.Exception.Message
    $state.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-PipelineState
    throw
}
finally {
    $env:ITE2E_PACKAGE = $priorPackageSelector
    if ($null -eq $priorArtifactRoot) {
        Remove-Item Env:ITE2E_ARTIFACT_ROOT -ErrorAction SilentlyContinue
    }
    else {
        $env:ITE2E_ARTIFACT_ROOT = $priorArtifactRoot
    }
    $lock.Dispose()
}
