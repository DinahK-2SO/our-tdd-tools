<#
.SYNOPSIS
    Record whether a previously built product package can be reused at a later validation HEAD.

.DESCRIPTION
    Compares the build receipt's product HEAD with the validation HEAD only across the receipt's
    product source paths. Reuse is allowed only when the product HEAD is an ancestor, no scoped
    files changed, and the validation worktree has no scoped tracked or untracked changes.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [string]$ValidationHead = 'HEAD',
    [string[]]$SourcePaths,
    [string]$OutPath,
    [switch]$RequireReusable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) {
    $RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    throw "Build receipt not found: $ReceiptPath"
}

$receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
$productHead = [string]$receipt.gitHead
if ($productHead -notmatch '^[a-f0-9]{40}$') {
    throw 'Build receipt does not contain a full lowercase gitHead.'
}
$validationOid = (& git -C $RepoRoot rev-parse "$ValidationHead^{commit}").Trim()
if ($LASTEXITCODE -ne 0 -or $validationOid -notmatch '^[a-f0-9]{40}$') {
    throw "Unable to resolve validation HEAD '$ValidationHead'."
}
$currentHead = (& git -C $RepoRoot rev-parse HEAD).Trim()
if ($currentHead -ne $validationOid) {
    throw "Validation HEAD '$validationOid' is not checked out in the worktree ('$currentHead')."
}

if (-not @($receipt.sourcePaths).Count) {
    throw 'No product source paths were recorded in the receipt.'
}
$effectivePaths = @(@($receipt.sourcePaths) + @($SourcePaths) | Sort-Object -Unique)

& git -C $RepoRoot merge-base --is-ancestor $productHead $validationOid
$isAncestor = $LASTEXITCODE -eq 0
$literalPathspecs = @($effectivePaths | ForEach-Object {
    $path = ([string]$_).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'Product source paths cannot be empty.'
    }
    ":(top,literal)$path"
})
$pathArgs = @('--') + $literalPathspecs
$changedPaths = @(& git -C $RepoRoot diff --name-only $productHead $validationOid @pathArgs)
if ($LASTEXITCODE -ne 0) { throw 'git diff failed while comparing product and validation HEADs.' }
$dirtyPaths = @(& git -C $RepoRoot diff --name-only HEAD @pathArgs)
if ($LASTEXITCODE -ne 0) { throw 'git diff failed while checking validation worktree changes.' }
$untrackedPaths = @(& git -C $RepoRoot ls-files --others --exclude-standard @pathArgs)
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed while checking validation worktree changes.' }

$reusable = $isAncestor -and $changedPaths.Count -eq 0 -and $dirtyPaths.Count -eq 0 -and $untrackedPaths.Count -eq 0
$reason = if (-not $isAncestor) {
    'product HEAD is not an ancestor of validation HEAD'
}
elseif ($changedPaths.Count -gt 0) {
    'product source paths changed between product and validation HEADs'
}
elseif ($dirtyPaths.Count -gt 0 -or $untrackedPaths.Count -gt 0) {
    'validation worktree has uncommitted product source changes'
}
else {
    'product source paths are unchanged; package reuse is provenance-safe'
}

$result = [ordered]@{
    schemaVersion = 1
    createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
    repoRoot = $RepoRoot
    productHead = $productHead
    validationHead = $validationOid
    productHeadIsAncestor = $isAncestor
    sourcePaths = $effectivePaths
    changedProductPaths = $changedPaths
    dirtyProductPaths = $dirtyPaths
    untrackedProductPaths = $untrackedPaths
    receiptPath = $ReceiptPath
    receiptSha256 = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash
    reusable = $reusable
    reason = $reason
}

if ($OutPath) {
    $OutPath = [IO.Path]::GetFullPath($OutPath)
    New-Item -ItemType Directory -Force -Path (Split-Path $OutPath -Parent) | Out-Null
    $json = $result | ConvertTo-Json -Depth 8
    $temp = "$OutPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $OutPath, $true)
}

$output = [pscustomobject]$result
$output
if ($RequireReusable -and -not $reusable) {
    throw "Product package cannot be reused: $reason"
}
