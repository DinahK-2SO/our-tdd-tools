[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PublicationPath,
    [Parameter(Mandatory)][string]$NativeReceiptPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$AuthorizationPath,
    [Parameter(Mandatory)][string]$BudgetPath,
    [string]$ScenarioPath = (Join-Path $PSScriptRoot 'examples\RealUser.Marker.ps1'),
    [Parameter(Mandatory)][switch]$AllowRealInference,
    [Parameter(DontShow)][string]$PipelineScript = (Join-Path $PSScriptRoot 'Invoke-LocalTddPipeline.ps1'),
    [Parameter(DontShow)][string]$RealScript = (Join-Path $PSScriptRoot 'Invoke-LocalTddRealAcceptance.ps1')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DevTarget.ps1')
. (Join-Path $PSScriptRoot '..\..\..\common\tools\Core.ps1')
. (Join-Path $PSScriptRoot '..\..\..\common\tools\ai\Budget.ps1')
if (-not $AllowRealInference) { throw 'Real verification requires explicit inference opt-in.' }
$null = Read-WinpdAuthorization $AuthorizationPath
$publication = Get-Content -LiteralPath $PublicationPath -Raw | ConvertFrom-Json -AsHashtable
$head = $publication.head
if ((git -C $RepoRoot rev-parse HEAD) -ne $head -or $LASTEXITCODE) { throw 'Source is not at the expected PR head.' }
Assert-LocalTddRemoteHead $RepoRoot $publication $head
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$key = Get-WinpdEvidenceHash @( $publication.repository.ToLowerInvariant(), [int]$publication.pullRequest )
$root = Join-Path $StateRoot $key
[void][IO.Directory]::CreateDirectory($root)
$latest = Join-Path $root 'latest.json'
$lock = [IO.File]::Open((Join-Path $root 'dispatch.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Assert-LocalTddRemoteHead $RepoRoot $publication $head
    $previous = $null
    if (Test-Path -LiteralPath $latest) {
        $previous = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
        if ($previous.head -notmatch '^[a-f0-9]{40}$' -or $previous.run -notmatch ('^'+$previous.head+'-[a-f0-9]{32}$')) {
            throw 'Invalid previous dispatch identity.'
        }
        $previousDir = Join-Path $root $previous.run
        $outcomePath = Join-Path $previousDir 'outcome.json'
        if ($previous.head -eq $head -and !(Test-Path -LiteralPath $outcomePath)) { throw 'This head was already dispatched; its run is unfinished.' }
        if ($previous.head -eq $head) {
            $cached = Get-Content -LiteralPath $outcomePath -Raw | ConvertFrom-Json
            if ($cached.head -ne $head -or $cached.runDirectory -ine $previousDir) { throw 'Cached outcome does not match the previous dispatch.' }
            if ($cached.status -eq 'passed') { return $cached }
        }
    }
    $runName = "$head-$([guid]::NewGuid().ToString('N'))"
    $run = Join-Path $root $runName
    [void](New-Item -ItemType Directory -Path $run -ErrorAction Stop)
    if ($previous -and $previous.head -ne $head -and !(Test-Path -LiteralPath $outcomePath)) {
        $marker = Join-Path $previousDir 'superseded-by.txt'
        $tmp = "$marker.$([guid]::NewGuid().ToString('N')).tmp"
        try { [IO.File]::WriteAllText($tmp,$head); [IO.File]::Move($tmp,$marker,$true) }
        finally { [IO.File]::Delete($tmp) }
    }
    $snapshot = Join-Path $run 'publication.json'
    Write-WinpdEvidenceJson $snapshot $publication
    Write-WinpdEvidenceJson $latest @{head=$head; run=$runName}
} finally { $lock.Dispose() }
$marker = Join-Path $run 'superseded-by.txt'
$outcome = @{ head=$head; status='running'; runDirectory=$run }
try {
    $build = @{ RepoRoot=$RepoRoot; ExpectedHead=$head; PublicationPath=$snapshot; WtaOnly=$true
        NativeReceiptPath=$NativeReceiptPath; OutDir=(Join-Path $run 'pipeline'); ReceiptPath=(Join-Path $run 'build-output.json') }
    $pipeline = & $PipelineScript @build
    if ($pipeline.status -ne 'passed' -or $pipeline.gitHead -ne $head) { throw 'Build did not verify the dispatched SHA.' }
    Assert-LocalTddRemoteHead $RepoRoot $publication $head
    $real = & $RealScript -AllowRealInference -RepoRoot $RepoRoot -ReceiptPath $pipeline.receiptPath -PublicationPath $snapshot `
        -AuthorizationPath $AuthorizationPath -BudgetPath $BudgetPath -ScenarioPath $ScenarioPath `
        -OutDir (Join-Path $run 'real') -SupersessionPath $marker
    if ($real.head -ne $head -or $real.status -notin 'superseded','passed') { throw 'Real acceptance did not verify the dispatched SHA.' }
    $outcome.status = $real.status
    if ($outcome.status -eq 'passed') { Assert-LocalTddRemoteHead $RepoRoot $publication $head }
} catch {
    $outcome.status = 'failed'
    $outcome.error = $_.Exception.Message
    throw
} finally {
    if ($outcome.status -eq 'passed' -and (Test-Path -LiteralPath $marker)) { $outcome.status = 'superseded' }
    Write-WinpdEvidenceJson (Join-Path $run 'outcome.json') $outcome
}
[pscustomobject]$outcome
