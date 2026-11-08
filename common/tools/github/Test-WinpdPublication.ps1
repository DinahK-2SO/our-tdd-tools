#Requires -Version 7.0
<#
.SYNOPSIS
    Audit candidate public history and prose for private toolkit references.
.DESCRIPTION
    This read-only preflight supplements dependency and privacy review. It does
    not publish anything, authorize a write, or certify arbitrary secrets absent.
    Prose files may be outside the clean candidate worktree or in ignored storage.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$HeadRef = 'HEAD',
    [string[]]$TextPath = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$findings = [Collections.Generic.List[object]]::new()
$textFiles = [Collections.Generic.List[object]]::new()
$privateText = '(?i)local-tdd-kit|LocalTdd|TDD-WORKFLOW|\.winpd[\\/]|(?:^|[^A-Za-z0-9_])dev-only[\\/]'
$privatePath = '(?i)(^|[\\/])(local-tdd-kit|\.local-tdd-kit-run|\.winpd|dev-only|Generated Files)([\\/]|$)'

function Invoke-PublicationGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git --no-pager -C $RepoRoot @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Public content audit Git read failed: $($Arguments[0]) (exit $LASTEXITCODE)." }
    return $output
}

function Test-PublicationText {
    param([AllowEmptyString()][string]$Text, [string]$Source)
    $lineNumber = 0
    foreach ($line in $Text -split '\r?\n') {
        $lineNumber++
        if ($line -match $privateText) {
            $findings.Add([pscustomobject]@{ Source = $Source; Line = $lineNumber; Kind = 'private reference' })
        }
    }
}

$baseCommit = (Invoke-PublicationGit -Arguments @('rev-parse', '--verify', '--end-of-options', "$BaseRef^{commit}")).Trim()
$headCommit = (Invoke-PublicationGit -Arguments @('rev-parse', '--verify', '--end-of-options', "$HeadRef^{commit}")).Trim()
& git -C $RepoRoot merge-base --is-ancestor $baseCommit $headCommit
if ($LASTEXITCODE -ne 0) { throw 'Public content audit requires BaseRef to be an ancestor of HeadRef.' }
if (@(Invoke-PublicationGit -Arguments @('status', '--porcelain', '--untracked-files=all')).Count) {
    throw 'Public content audit requires a clean worktree; commit candidates and keep drafts ignored or outside it.'
}
$commits = @(Invoke-PublicationGit -Arguments @('rev-list', '--reverse', "$baseCommit..$headCommit"))
if (-not $commits.Count -and -not $TextPath.Count) { throw 'No new commits or candidate text were selected for audit.' }

foreach ($commit in $commits) {
    $message = (Invoke-PublicationGit -Arguments @('show', '-s', '--format=%B', $commit)) -join "`n"
    Test-PublicationText -Text $message -Source "commit:${commit}:message"
    $paths = (Invoke-PublicationGit -Arguments @(
        'diff-tree', '--root', '-m', '--no-commit-id', '--name-only', '-r', '-z',
        '--no-renames', '--diff-filter=ACMRT', $commit, '--'
    )) -join "`n"
    foreach ($path in $paths.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($path -match $privatePath) {
            $findings.Add([pscustomobject]@{ Source = "commit:${commit}:$path"; Line = 0; Kind = 'private path' })
        }
    }
    $patch = @(Invoke-PublicationGit -Arguments @(
        'show', '-m', '--format=', '--unified=0', '--no-ext-diff', '--no-textconv', '--no-renames', $commit, '--'
    ))
    $inHunk = $false
    $lineNumber = 0
    foreach ($line in $patch) {
        $lineNumber++
        if ($line.StartsWith('diff --git ')) { $inHunk = $false }
        elseif ($line.StartsWith('@@ ')) { $inHunk = $true }
        elseif ($inHunk -and $line.StartsWith('+')) {
            Test-PublicationText -Text $line.Substring(1) -Source "commit:${commit}:patch-line-$lineNumber"
        }
    }
}

foreach ($candidate in $TextPath) {
    $path = (Resolve-Path -LiteralPath $candidate).Path
    $hash = (Get-FileHash -LiteralPath $path).Hash
    Test-PublicationText -Text ([IO.File]::ReadAllText($path)) -Source "text:$path"
    $textFiles.Add(@{ path = $path; sha256 = $hash })
}
if ((Invoke-PublicationGit -Arguments @('rev-parse', '--verify', '--end-of-options', "$BaseRef^{commit}")).Trim() -ne $baseCommit -or
    (Invoke-PublicationGit -Arguments @('rev-parse', '--verify', '--end-of-options', "$HeadRef^{commit}")).Trim() -ne $headCommit -or
    @(Invoke-PublicationGit -Arguments @('status', '--porcelain', '--untracked-files=all')).Count) {
    throw 'Public content audit inputs changed while scanning; rerun on a clean, stable candidate.'
}
foreach ($file in $textFiles) {
    if ((Get-FileHash -LiteralPath $file.path).Hash -ne $file.sha256) {
        throw 'Candidate public text changed while scanning; rerun before any public write.'
    }
}
if ($findings.Count) {
    $findings | Format-Table Source, Line, Kind -AutoSize | Out-Host
    throw "Public content audit failed with $($findings.Count) finding(s)."
}
[pscustomobject]@{
    Passed = $true; RepoRoot = $RepoRoot; BaseCommit = $baseCommit; HeadCommit = $headCommit
    CommitCount = $commits.Count; TextFiles = $textFiles.ToArray()
}
