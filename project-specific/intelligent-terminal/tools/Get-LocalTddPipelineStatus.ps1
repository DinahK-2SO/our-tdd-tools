<#
.SYNOPSIS
    Read a durable local-TDD pipeline journal and classify abandoned running state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JournalPath,
    [switch]$RequirePassed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (Test-Path -LiteralPath $JournalPath -PathType Container) {
    $JournalPath = Join-Path $JournalPath 'pipeline-state.json'
}
if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) {
    throw "Pipeline journal not found: $JournalPath"
}

$journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
if ($journal.schemaVersion -ne 1) {
    throw "Unsupported pipeline journal schema '$($journal.schemaVersion)': $JournalPath"
}
$required = @(
    'runId', 'status', 'currentPhase', 'startedUtc', 'completedUtc', 'lastUpdatedUtc',
    'processId', 'processStartUtc', 'gitHead', 'sourceFingerprint', 'sourcePaths',
    'receiptPath', 'receiptSha256', 'e2eReportPath', 'e2eReportSha256',
    'e2eResultsPath', 'e2eResultsSha256', 'e2eTotals',
    'error', 'invocation', 'phases'
)
$missing = $required |
    Where-Object { $journal.PSObject.Properties.Name -notcontains $_ }
if ($missing) {
    throw "Pipeline journal is missing required fields ($($missing -join ', ')): $JournalPath"
}
$observedStatus = [string]$journal.status
$processMatches = $false
$validationErrors = [System.Collections.Generic.List[string]]::new()

function Get-NUnitCaseTotals {
    param([Parameter(Mandatory)][string]$Path)

    [xml]$results = Get-Content -LiteralPath $Path -Raw
    if (-not $results.'test-results') { throw 'not NUnit test-results XML' }
    $cases = @($results.SelectNodes("//*[local-name()='test-case']"))
    $passed = @($cases | Where-Object {
            $_.result -in @('Success', 'Passed') -or
            ($_.success -eq 'True' -and $_.result -notin @('Failure', 'Error', 'Ignored', 'Skipped', 'Inconclusive', 'Invalid', 'NotRunnable'))
        }).Count
    $failed = @($cases | Where-Object { $_.result -in @('Failure', 'Error', 'Failed') }).Count
    $skipped = @($cases | Where-Object { $_.result -in @('Ignored', 'Skipped', 'NotRun') }).Count
    [pscustomobject]@{
        total = $cases.Count
        passed = $passed
        failed = $failed
        skipped = $skipped
        invalid = $cases.Count - $passed - $failed - $skipped
    }
}

if ($journal.status -notin @('running', 'passed', 'failed')) {
    $validationErrors.Add("unsupported declared status '$($journal.status)'")
}
$runId = [guid]::Empty
if (-not [guid]::TryParse([string]$journal.runId, [ref]$runId)) {
    $validationErrors.Add('runId is not a GUID')
}
if ([string]$journal.gitHead -notmatch '^[a-f0-9]{40}$') {
    $validationErrors.Add('gitHead is not a full lowercase SHA')
}
if ([int]$journal.processId -le 0) {
    $validationErrors.Add('processId is not positive')
}
foreach ($field in @('processStartUtc', 'startedUtc', 'lastUpdatedUtc')) {
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$journal.$field, [ref]$parsed)) {
        $validationErrors.Add("$field is not a timestamp")
    }
}

$phases = @($journal.phases)
foreach ($phase in $phases) {
    $phaseMissing = @('name', 'status', 'startedUtc', 'completedUtc', 'exitCode', 'error') |
        Where-Object { $phase.PSObject.Properties.Name -notcontains $_ }
    if ($phaseMissing) {
        $validationErrors.Add("phase is missing fields: $($phaseMissing -join ', ')")
        continue
    }
    if (-not $phase.name) { $validationErrors.Add('phase name is empty') }
    if ($phase.status -notin @('running', 'passed', 'failed')) {
        $validationErrors.Add("phase '$($phase.name)' has invalid status '$($phase.status)'")
    }
    $phaseStarted = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$phase.startedUtc, [ref]$phaseStarted)) {
        $validationErrors.Add("phase '$($phase.name)' has invalid startedUtc")
    }
    if ($phase.status -eq 'running') {
        if ($phase.completedUtc -or $null -ne $phase.exitCode) {
            $validationErrors.Add("running phase '$($phase.name)' has completion data")
        }
    }
    else {
        $phaseCompleted = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$phase.completedUtc, [ref]$phaseCompleted)) {
            $validationErrors.Add("completed phase '$($phase.name)' has invalid completedUtc")
        }
        elseif ($phaseStarted -ne [DateTimeOffset]::MinValue -and $phaseCompleted -lt $phaseStarted) {
            $validationErrors.Add("phase '$($phase.name)' completed before it started")
        }
        if ($phase.status -eq 'passed' -and [int]$phase.exitCode -ne 0) {
            $validationErrors.Add("passed phase '$($phase.name)' has nonzero exitCode")
        }
        if ($phase.status -eq 'failed' -and -not $phase.error) {
            $validationErrors.Add("failed phase '$($phase.name)' has no error")
        }
    }
}

if ($journal.status -in @('passed', 'failed')) {
    $completed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$journal.completedUtc, [ref]$completed)) {
        $validationErrors.Add('completedUtc is required for a completed pipeline')
    }
}
elseif ($journal.completedUtc) {
    $validationErrors.Add('a running pipeline cannot have completedUtc')
}

if ($journal.status -eq 'passed') {
    if ($journal.currentPhase) { $validationErrors.Add('a passed pipeline cannot have currentPhase') }
    if ($journal.error) { $validationErrors.Add('a passed pipeline cannot have an error') }
    if (-not $journal.invocation -or $journal.invocation.PSObject.Properties.Name -notcontains 'e2ePaths') {
        $validationErrors.Add('a passed pipeline requires invocation.e2ePaths')
    }
    $e2eRequested = $journal.invocation -and
        $journal.invocation.PSObject.Properties.Name -contains 'e2ePaths' -and
        @($journal.invocation.e2ePaths).Count -gt 0
    $expectedPhases = @('preflight', 'build-deploy-freshness')
    if ($e2eRequested) { $expectedPhases += 'packaged-e2e' }
    $expectedPhases += 'final-source-verification'
    if (($phases.name -join '|') -ne ($expectedPhases -join '|')) {
        $validationErrors.Add("passed phase sequence must be: $($expectedPhases -join ', ')")
    }
    if (-not $phases -or @($phases | Where-Object status -ne 'passed').Count -gt 0) {
        $validationErrors.Add('every phase of a passed pipeline must be passed')
    }
    if ([string]$journal.sourceFingerprint -notmatch '^[A-F0-9]{64}$') {
        $validationErrors.Add('a passed pipeline requires a source fingerprint')
    }
    if (-not $journal.sourcePaths) { $validationErrors.Add('a passed pipeline requires source paths') }
    if ([string]$journal.receiptSha256 -notmatch '^[A-F0-9]{64}$') {
        $validationErrors.Add('a passed pipeline requires a receipt hash')
    }
    if (-not $journal.receiptPath -or -not (Test-Path -LiteralPath $journal.receiptPath -PathType Leaf)) {
        $validationErrors.Add('a passed pipeline requires its run-local receipt')
    }
    elseif ([string]$journal.receiptSha256 -match '^[A-F0-9]{64}$') {
        $actualReceiptHash = (Get-FileHash -LiteralPath $journal.receiptPath -Algorithm SHA256).Hash
        if ($actualReceiptHash -ne $journal.receiptSha256) {
            $validationErrors.Add('the run-local receipt hash does not match the journal')
        }
        else {
            try {
                $receipt = Get-Content -LiteralPath $journal.receiptPath -Raw | ConvertFrom-Json
                $sourceEntries = @($receipt.paths.packageSources.PSObject.Properties)
                if (-not $sourceEntries) { throw 'receipt has no package source map' }
                foreach ($entry in $sourceEntries) {
                    $recordedSourceHash = [string]$receipt.hashes.packageSources.($entry.Name)
                    $sourceHash = if (Test-Path -LiteralPath $entry.Value -PathType Leaf) {
                        (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
                    }
                    if (-not $recordedSourceHash -or $sourceHash -ne $recordedSourceHash) {
                        $validationErrors.Add("recipe source changed after validation: $($entry.Name)")
                    }
                    if ($receipt.installVerified) {
                        $appxPath = Join-Path $receipt.paths.appxLayout $entry.Name
                        $recordedAppxHash = [string]$receipt.hashes.appx.($entry.Name)
                        $appxHash = if (Test-Path -LiteralPath $appxPath -PathType Leaf) {
                            (Get-FileHash -LiteralPath $appxPath -Algorithm SHA256).Hash
                        }
                        if (-not $recordedAppxHash -or $appxHash -ne $recordedAppxHash) {
                            $validationErrors.Add("AppX destination changed after validation: $($entry.Name)")
                        }
                        if ($sourceHash -ne $appxHash) {
                            $validationErrors.Add("recipe source no longer matches AppX: $($entry.Name)")
                        }
                    }
                }
            }
            catch {
                $validationErrors.Add("the build receipt artifacts cannot be validated: $($_.Exception.Message)")
            }
        }
    }

    $e2eRecorded = $journal.e2eReportPath -or $journal.e2eResultsPath -or $journal.e2eTotals
    if ($e2eRequested) {
        $reportExists = $journal.e2eReportPath -and (Test-Path -LiteralPath $journal.e2eReportPath -PathType Leaf)
        $resultsExist = $journal.e2eResultsPath -and (Test-Path -LiteralPath $journal.e2eResultsPath -PathType Leaf)
        if (-not $reportExists) {
            $validationErrors.Add('the E2E summary referenced by a passed pipeline is missing')
        }
        if (-not $resultsExist) {
            $validationErrors.Add('the E2E results referenced by a passed pipeline are missing')
        }
        if (-not $journal.e2eTotals -or [int]$journal.e2eTotals.passed -le 0 -or
            [int]$journal.e2eTotals.failed -ne 0 -or [int]$journal.e2eTotals.invalid -ne 0) {
            $validationErrors.Add('a passed E2E pipeline requires positive passing totals and zero failed/invalid outcomes')
        }
        if (-not $reportExists -or [string]$journal.e2eReportSha256 -notmatch '^[A-F0-9]{64}$' -or
            (Get-FileHash -LiteralPath $journal.e2eReportPath -Algorithm SHA256).Hash -ne $journal.e2eReportSha256) {
            $validationErrors.Add('the E2E summary hash does not match the journal')
        }
        if (-not $resultsExist -or [string]$journal.e2eResultsSha256 -notmatch '^[A-F0-9]{64}$' -or
            (Get-FileHash -LiteralPath $journal.e2eResultsPath -Algorithm SHA256).Hash -ne $journal.e2eResultsSha256) {
            $validationErrors.Add('the E2E results hash does not match the journal')
        }
        if ($resultsExist) {
            try {
                $actualTotals = Get-NUnitCaseTotals -Path $journal.e2eResultsPath
                if (-not $journal.e2eTotals -or
                    $actualTotals.total -ne [int]$journal.e2eTotals.total -or
                    $actualTotals.passed -ne [int]$journal.e2eTotals.passed -or
                    $actualTotals.failed -ne [int]$journal.e2eTotals.failed -or
                    $actualTotals.skipped -ne [int]$journal.e2eTotals.skipped -or
                    $actualTotals.invalid -ne [int]$journal.e2eTotals.invalid) {
                    $validationErrors.Add('the E2E result totals do not match the journal')
                }
            }
            catch {
                $validationErrors.Add("the E2E results cannot be validated: $($_.Exception.Message)")
            }
        }
    }
    elseif ($e2eRecorded) {
        $validationErrors.Add('E2E evidence is present although the invocation requested no E2E')
    }
}
elseif ($journal.status -eq 'failed') {
    if (-not $journal.error) { $validationErrors.Add('a failed pipeline requires an error') }
    $failedPhases = @($phases | Where-Object status -eq 'failed')
    if (-not $phases -or $failedPhases.Count -eq 0) {
        $validationErrors.Add('a failed pipeline requires a failed phase')
    }
    elseif ($journal.currentPhase -ne $failedPhases[-1].name) {
        $validationErrors.Add('a failed pipeline currentPhase must identify its failed phase')
    }
    if (@($phases | Where-Object status -eq 'running').Count -gt 0) {
        $validationErrors.Add('a failed pipeline cannot retain a running phase')
    }
}
elseif ($journal.status -eq 'running') {
    $runningPhases = @($phases | Where-Object status -eq 'running')
    if ($journal.currentPhase) {
        if ($runningPhases.Count -ne 1 -or $runningPhases[0].name -ne $journal.currentPhase) {
            $validationErrors.Add('a running pipeline currentPhase must match exactly one running phase')
        }
    }
    elseif ($runningPhases.Count -ne 0) {
        $validationErrors.Add('a running phase requires currentPhase')
    }
}

if ($validationErrors.Count -gt 0) {
    $observedStatus = 'invalid'
}
elseif ($observedStatus -eq 'running') {
    $process = Get-Process -Id ([int]$journal.processId) -ErrorAction SilentlyContinue
    if ($process) {
        try {
            $recordedStart = [DateTimeOffset]::Parse([string]$journal.processStartUtc).UtcDateTime
            $actualStart = $process.StartTime.ToUniversalTime()
            $processMatches = [Math]::Abs(($actualStart - $recordedStart).TotalSeconds) -lt 1
        }
        catch {
            $processMatches = $false
        }
    }
    if (-not $processMatches) { $observedStatus = 'interrupted' }
}

$result = [pscustomobject]@{
    JournalPath = [IO.Path]::GetFullPath($JournalPath)
    RunId = $journal.runId
    DeclaredStatus = $journal.status
    ObservedStatus = $observedStatus
    CurrentPhase = $journal.currentPhase
    GitHead = $journal.gitHead
    ProcessId = $journal.processId
    ProcessMatches = $processMatches
    StartedUtc = $journal.startedUtc
    CompletedUtc = $journal.completedUtc
    LastUpdatedUtc = $journal.lastUpdatedUtc
    ReceiptPath = $journal.receiptPath
    ReceiptSha256 = $journal.receiptSha256
    E2EReportPath = $journal.e2eReportPath
    E2EResultsPath = $journal.e2eResultsPath
    Error = $journal.error
    ValidationErrors = @($validationErrors)
}
$result

if ($RequirePassed -and $observedStatus -ne 'passed') {
    throw "Pipeline is '$observedStatus', not passed: $JournalPath"
}
