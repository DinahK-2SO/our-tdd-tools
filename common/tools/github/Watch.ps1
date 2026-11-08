function Watch-WinpdPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PublicationPath,
        [Parameter(Mandatory)][string]$StatePath,
        [ValidateRange(1, 2147483647)][int]$MaxObservations = 1,
        [ValidateRange(1, 86400)][int]$IntervalSeconds = 1800
    )
    $previous = $null
    if (Test-Path -LiteralPath $StatePath) {
        $previous = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
    }
    for ($index = 1; $index -le $MaxObservations; $index++) {
        try {
            $snapshot = Get-WinpdReviewSnapshot -PublicationPath $PublicationPath
            $lifecycle = $snapshot.data.pullRequest.state
            if ($lifecycle -notin @('OPEN', 'MERGED', 'CLOSED')) { throw 'PR lifecycle is not a known observation.' }
            $changed = $null -eq $previous -or $previous['SnapshotHash'] -ne $snapshot.dataSha256
            $finished = $lifecycle -in @('MERGED', 'CLOSED') -or $index -eq $MaxObservations
            $state = [ordered]@{
                SchemaVersion = 1
                Status = $(if ($lifecycle -in @('MERGED', 'CLOSED')) { 'closed' } elseif ($finished) { 'observed' } else { 'observing' })
                Lifecycle = $lifecycle; Head = $snapshot.data.pullRequest.headRefOid
                ObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                Changed = $changed; SnapshotHash = $snapshot.dataSha256; Snapshot = $snapshot
                RunnerActive = -not $finished; RunnerPid = $PID
                RunnerStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
            }
            Write-WinpdEvidenceJson -Path $StatePath -Value $state
            if ($state.Status -eq 'closed' -or $index -eq $MaxObservations) {
                return [pscustomobject]@{ Status = $state.Status; Observations = $index; StatePath = $StatePath }
            }
            $previous = $state
            Start-Sleep -Seconds $IntervalSeconds
        }
        catch {
            Write-WinpdEvidenceJson -Path $StatePath -Value @{
                SchemaVersion = 1; Status = 'unknown'; RunnerActive = $false
                ObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                Error = $_.Exception.Message; LastKnownSnapshotHash = $(if ($previous) { $previous['SnapshotHash'] } else { $null })
            }
            throw
        }
    }
}
