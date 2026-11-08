function Read-WinpdAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $authorization = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($authorization.schemaVersion -ne 1 -or $authorization.approved -isnot [bool] -or
        -not $authorization.approved -or [string]::IsNullOrWhiteSpace($authorization.scope)) {
        throw 'Real inference requires explicit task-scoped approval.'
    }
    foreach ($name in 'totalLimit', 'perHeadLimit', 'timeoutSeconds') {
        $value = $authorization[$name]
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt [int]::MaxValue) {
            throw "Authorization requires a positive finite integer: $name"
        }
    }
    if ($authorization.perHeadLimit -gt $authorization.totalLimit) {
        throw 'The per-head request limit cannot exceed the total limit.'
    }
    return $authorization
}

function Read-WinpdLedger {
    param([string]$Path)
    $ledger = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($ledger.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($ledger.scope) -or
        $ledger.attempts -isnot [array]) { throw 'Invalid request ledger; no count was reset.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($attempt in $ledger.attempts) {
        if (-not $attempt.id -or -not $ids.Add($attempt.id) -or $attempt.head -notmatch '^[a-fA-F0-9]{40}$' -or
            -not $attempt.runId -or $attempt.status -notin @('reserved', 'submitted', 'passed', 'failed', 'unknown')) {
            throw 'Invalid request ledger entry; no count was reset.'
        }
    }
    return $ledger
}

function Reserve-WinpdRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorizationPath,
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Head,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId
    )
    $authorization = Read-WinpdAuthorization -Path $AuthorizationPath
    $BudgetPath = [IO.Path]::GetFullPath($BudgetPath)
    New-Item -ItemType Directory -Force -Path (Split-Path $BudgetPath -Parent) | Out-Null
    $lock = [IO.File]::Open("$BudgetPath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $ledger = if (Test-Path -LiteralPath $BudgetPath) { Read-WinpdLedger $BudgetPath }
        else { @{ schemaVersion = 1; scope = $authorization.scope; attempts = @() } }
        if (-not [string]::Equals($ledger.scope, $authorization.scope, [StringComparison]::Ordinal)) {
            throw 'Authorization and request ledger scope differ.'
        }
        if (@($ledger.attempts | Where-Object runId -eq $RunId).Count) { throw 'This run already reserved a request.' }
        if ($ledger.attempts.Count -ge $authorization.totalLimit) { throw 'The total real request budget is exhausted.' }
        if (@($ledger.attempts | Where-Object head -eq $Head).Count -ge $authorization.perHeadLimit) {
            throw 'The per-head real request budget is exhausted; another attempt needs explicit authorization.'
        }
        # Reservations are charged even if the process dies before recording submission.
        $attempt = @{
            id = [guid]::NewGuid().ToString('N'); runId = $RunId; head = $Head.ToLowerInvariant()
            status = 'reserved'; reservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            submittedUtc = $null; completedUtc = $null
            authorizationSha256 = (Get-FileHash -LiteralPath $AuthorizationPath).Hash
            totalLimit = $authorization.totalLimit; perHeadLimit = $authorization.perHeadLimit
            timeoutSeconds = $authorization.timeoutSeconds
        }
        $ledger.attempts = @($ledger.attempts) + @($attempt)
        Write-WinpdEvidenceJson -Path $BudgetPath -Value $ledger
        return $attempt
    }
    finally { $lock.Dispose() }
}

function Set-WinpdRequestOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][string]$AttemptId,
        [Parameter(Mandatory)][ValidateSet('submitted', 'passed', 'failed', 'unknown')][string]$Outcome
    )
    $BudgetPath = [IO.Path]::GetFullPath($BudgetPath)
    $lock = [IO.File]::Open("$BudgetPath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $ledger = Read-WinpdLedger $BudgetPath
        $matches = @($ledger.attempts | Where-Object id -CEQ $AttemptId)
        if ($matches.Count -ne 1) { throw 'The reserved request was not found.' }
        $attempt = $matches[0]
        if ($attempt.status -notin @('reserved', 'submitted')) { throw 'A terminal request outcome cannot be overwritten.' }
        if (($Outcome -eq 'submitted' -and $attempt.status -ne 'reserved') -or
            ($Outcome -eq 'passed' -and $attempt.status -ne 'submitted')) {
            throw 'Invalid request outcome transition.'
        }
        $attempt.status = $Outcome
        if ($Outcome -eq 'submitted') { $attempt.submittedUtc = [DateTimeOffset]::UtcNow.ToString('o') }
        else { $attempt.completedUtc = [DateTimeOffset]::UtcNow.ToString('o') }
        Write-WinpdEvidenceJson -Path $BudgetPath -Value $ledger
    }
    finally { $lock.Dispose() }
}
