$commonTools = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\common\tools'))
. (Join-Path $commonTools 'Core.ps1')
. (Join-Path $commonTools 'github\Review.ps1')
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalTdd.Acceptance.psm1')

function Get-LocalTddObjectHash {
    param([Parameter(Mandatory)]$Value)
    Get-WinpdEvidenceHash @PSBoundParameters
}

function Resolve-LocalTddEvidence {
    param([Parameter(Mandatory)]$Reference, [Parameter(Mandatory)][string]$BasePath)
    if ($Reference -isnot [Collections.IDictionary] -or -not $Reference.path -or
        $Reference.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Evidence requires an exact path and SHA256.' }
    $path = if ([IO.Path]::IsPathRooted($Reference.path)) { [IO.Path]::GetFullPath($Reference.path) }
    else { [IO.Path]::GetFullPath((Join-Path $BasePath $Reference.path)) }
    if ((Get-FileHash -LiteralPath $path).Hash -ne $Reference.sha256) { throw "Evidence hash mismatch: $path" }
    return $path
}

function New-LocalTddEvidenceReference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    @{ path = $resolved; sha256 = (Get-FileHash -LiteralPath $resolved).Hash }
}

function Get-LocalTddReviewSnapshot {
    param([Parameter(Mandatory)][string]$PublicationPath)
    Get-WinpdReviewSnapshot @PSBoundParameters
}

function Test-LocalTddAcceptanceEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ContractPath)
    $base = Split-Path ([IO.Path]::GetFullPath($ContractPath)) -Parent
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json -AsHashtable
    if ($contract.schemaVersion -ne 1 -or $contract.head -notmatch '^[a-fA-F0-9]{40}$' -or
        -not $contract.requiredTests -or -not $contract.results) { throw 'Acceptance contract is incomplete.' }
    $receiptPath = Resolve-LocalTddEvidence $contract.receipt $base
    $publicationPath = Resolve-LocalTddEvidence $contract.publication $base
    $realPath = Resolve-LocalTddEvidence $contract.realAcceptance $base
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
    $publication = Get-Content -LiteralPath $publicationPath -Raw | ConvertFrom-Json -AsHashtable
    $real = Get-Content -LiteralPath $realPath -Raw | ConvertFrom-Json -AsHashtable
    if ($receipt.gitHead -ne $contract.head -or $publication.head -ne $contract.head -or
        $real.head -ne $contract.head -or $receipt.installVerified -isnot [bool] -or -not $receipt.installVerified -or
        $receipt.hashes.wta -notmatch '^[a-fA-F0-9]{64}$' -or
        $real.wtaSha256 -ne $receipt.hashes.wta -or $real.receiptSha256 -ne $contract.receipt.sha256) {
        throw 'Build, deployment, real acceptance and contract identities differ.'
    }
    $times = @(
        (ConvertTo-LocalTddTime $publication.pushedUtc),
        (ConvertTo-LocalTddTime $receipt.buildStartedUtc),
        (ConvertTo-LocalTddTime $receipt.createdUtc),
        (ConvertTo-LocalTddTime $real.startedUtc),
        (ConvertTo-LocalTddTime $real.submittedUtc),
        (ConvertTo-LocalTddTime $real.completedUtc)
    )
    for ($index = 1; $index -lt $times.Count; $index++) {
        if ($times[$index] -lt $times[$index - 1]) { throw 'Acceptance timestamps do not prove post-push ordering.' }
    }
    if ($times[-1] -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) { throw 'Acceptance evidence is dated in the future.' }
    if ($real.kind -ne 'real-user' -or $real.status -ne 'passed' -or $real.cleanupPassed -isnot [bool] -or
        -not $real.cleanupPassed -or $real.submissionAttempted -isnot [bool] -or -not $real.submissionAttempted -or
        $real.promptsObserved -ne 1 -or $real.provider -ne 'copilot' -or [string]::IsNullOrWhiteSpace($real.model) -or
        $real.observable.status -ne 'passed' -or $real.observable.expected -isnot [string] -or
        $real.observable.actual -isnot [string] -or $real.observable.actual -cne $real.observable.expected) {
        throw 'The real request, exact observable or cleanup is incomplete.'
    }
    $passedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reference in $contract.results) {
        $path = Resolve-LocalTddEvidence $reference $base
        $provenancePath = Resolve-LocalTddEvidence $reference.provenance $base
        $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json -AsHashtable
        if ($provenance.status -ne 'passed' -or $provenance.gitHead -ne $contract.head -or
            $provenance.receiptSha256 -ne $contract.receipt.sha256 -or
            $provenance.e2eResultsSha256 -ne $reference.sha256) {
            throw 'Test report provenance is not bound to this exact deployment.'
        }
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $cases = @($xml.SelectNodes("//*[local-name()='test-case']"))
        if (-not $cases.Count -or $xml.SelectNodes("//*[local-name()='test-suite']/*[local-name()='failure']").Count) {
            throw 'Test discovery, setup or teardown evidence failed.'
        }
        foreach ($case in $cases) {
            if ($case.GetAttribute('result') -notin @('Success', 'Passed') -or $case.GetAttribute('executed') -eq 'False') {
                throw "Current accepted reports must not contain failed/skipped tests: $($case.GetAttribute('name'))"
            }
            if (-not $case.GetAttribute('name')) { throw 'A test result has no exact name.' }
            [void]$passedNames.Add($case.GetAttribute('name'))
        }
    }
    foreach ($name in $contract.requiredTests) {
        if (-not $passedNames.Contains($name)) { throw "Required test did not pass: $name" }
    }
    $inspected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($contract.visual.required -isnot [bool]) { throw 'Visual coverage must be explicitly required or not applicable.' }
    if ($contract.visual.required) {
        if (-not $contract.visual.inventories -or -not $contract.visual.requiredFrames) { throw 'Visual inventory is missing.' }
        foreach ($reference in $contract.visual.inventories) {
            $path = Resolve-LocalTddEvidence $reference $base
            $inventory = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            if ($inventory.head -ne $contract.head -or -not $inventory.images) { throw 'Visual provenance does not match this head.' }
            foreach ($image in $inventory.images) {
                if ($image.actual_pixels_available -isnot [bool] -or -not $image.actual_pixels_available -or $image.inspection_status -ne 'PASS' -or
                    $image.visual_integrity_status -ne 'PASS') { throw 'A screenshot is uninspected or visually failed.' }
                $frame = Resolve-LocalTddEvidence $image (Split-Path $path -Parent)
                [void]$inspected.Add($frame)
            }
        }
        foreach ($frame in $contract.visual.requiredFrames) {
            $path = Resolve-LocalTddEvidence $frame $base
            if (-not $inspected.Contains($path)) { throw "Required screenshot is not inspected: $path" }
        }
    }
    $reviewPath = Resolve-LocalTddEvidence $contract.reviewSnapshot $base
    $review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json -AsHashtable
    if ($review.schemaVersion -ne 2 -or $review.data.pullRequest.headRefOid -ne $contract.head -or
        $review.dataSha256 -ne (Get-LocalTddObjectHash $review.data) -or
        $contract.reviewTriage.snapshotSha256 -ne $review.dataSha256 -or
        $contract.reviewTriage.complete -isnot [bool] -or -not $contract.reviewTriage.complete -or
        $contract.reviewTriage.noNewFindings -isnot [bool] -or -not $contract.reviewTriage.noNewFindings -or
        $contract.reviewTriage.annotationsTriaged -isnot [bool] -or -not $contract.reviewTriage.annotationsTriaged) {
        throw 'Current-head review triage is incomplete.'
    }
    $reviewed = @($review.data.pullRequest.reviews | Where-Object { $_.id -eq $contract.reviewTriage.reviewId })
    if ($reviewed.Count -ne 1 -or $reviewed[0].commit.oid -ne $contract.head) { throw 'The triaged review is not at this head.' }
    foreach ($check in $review.data.pullRequest.statusCheckRollup) {
        if ($check.Contains('conclusion')) {
            if (-not $check.Contains('annotations') -or -not $check.Contains('annotationsCount') -or
                $check.annotations -isnot [array] -or
                ($check.annotationsCount -isnot [int] -and $check.annotationsCount -isnot [long]) -or
                $check.annotationsCount -ne $check.annotations.Count) {
                throw 'Check annotation inventory is missing or incomplete.'
            }
            if ($check.status -ne 'COMPLETED' -or $check.conclusion -notin @('SUCCESS', 'SKIPPED', 'NEUTRAL')) {
                throw 'Online checks are not settled successfully.'
            }
        }
        elseif ($check.state -ne 'SUCCESS') { throw 'A commit status is not successful.' }
    }
    # Complete current-head triage is the gate; shared-account replies are not ownership proof.
    [pscustomobject]@{
        status = 'passed'; head = $contract.head; evidenceOnly = $true
        testsPassed = $passedNames.Count; originalsInspected = $inspected.Count
        publicationPath = $publicationPath; receiptPath = $receiptPath; reviewSnapshotSha256 = $review.dataSha256
        currentDeploymentVerified = $false; currentReviewVerified = $false
        humanApprovalRequired = $review.data.pullRequest.reviewDecision -ne 'APPROVED'
    }
}

function Complete-LocalTddAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ContractPath,
        [Parameter(Mandatory)][string]$OutPath
    )
    if (Test-Path -LiteralPath $OutPath) { throw 'Use a new final acceptance evidence path.' }
    $result = Test-LocalTddAcceptanceEvidence -ContractPath $ContractPath
    $null = Assert-LocalTddPublishedDeployment -RepoRoot $RepoRoot -PublicationPath $result.publicationPath -ReceiptPath $result.receiptPath
    $currentReview = Get-LocalTddReviewSnapshot -PublicationPath $result.publicationPath
    if ($currentReview.dataSha256 -ne $result.reviewSnapshotSha256) { throw 'Review/check evidence changed after triage.' }
    $result.evidenceOnly = $false
    $result.currentDeploymentVerified = $true
    $result.currentReviewVerified = $true
    $result | Add-Member -NotePropertyName verifiedUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o'))
    Write-LocalTddEvidenceJson -Path $OutPath -Value $result
    return $result
}

Export-ModuleMember -Function Get-LocalTddObjectHash, Get-LocalTddReviewSnapshot, New-LocalTddEvidenceReference,
    Test-LocalTddAcceptanceEvidence, Complete-LocalTddAcceptance
