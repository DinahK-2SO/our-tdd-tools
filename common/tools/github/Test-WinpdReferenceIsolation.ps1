<#
.SYNOPSIS
    Reject publish-target GitHub autolinks from dev-only commits and files.

.DESCRIPTION
    A publish pull request number, URL, review-thread identifier, or publish-branch
    URL committed on a dev branch can create a public timeline reference. This check
    scans every dev-only commit after -BaseRef plus the current changed/untracked
    text files. Supply the online identifiers only at runtime; never write them into
    a tracked dev workflow or commit message.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$PublishPullRequestNumber = $env:WINPD_PUBLISH_PR_NUMBER,
    [string]$PublishBranch = $env:WINPD_PUBLISH_BRANCH
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) {
    $RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "Repository root does not exist: $RepoRoot"
}

& git -C $RepoRoot rev-parse "$BaseRef^{commit}" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "BaseRef cannot be resolved to a commit: $BaseRef"
}
if ([string]::IsNullOrWhiteSpace($PublishPullRequestNumber) -and
    [string]::IsNullOrWhiteSpace($PublishBranch)) {
    throw 'Provide WINPD_PUBLISH_PR_NUMBER and/or WINPD_PUBLISH_BRANCH at runtime.'
}
if ($PublishPullRequestNumber -and $PublishPullRequestNumber -notmatch '^\d+$') {
    throw 'PublishPullRequestNumber must contain digits only.'
}

$patterns = [Collections.Generic.List[object]]::new()
if ($PublishPullRequestNumber) {
    $number = [regex]::Escape($PublishPullRequestNumber)
    $patterns.Add([pscustomobject]@{
            Kind = 'publish pull-request shorthand'
            Regex = [regex]::new("(?<!#)#$number(?!\d)")
        })
    $patterns.Add([pscustomobject]@{
            Kind = 'publish pull-request URL'
            Regex = [regex]::new("(?:https?://)?github\.com/[^\s/]+/[^\s/]+/pull/$number(?:[/?#][^\s]*)?")
        })
}

$discussionPrefix = 'discussion' + '_r'
$patterns.Add([pscustomobject]@{
        Kind = 'review-thread identifier'
        Regex = [regex]::new([regex]::Escape($discussionPrefix) + '\d+')
    })

if ($PublishBranch) {
    $branchForms = @(
        [regex]::Escape($PublishBranch),
        [regex]::Escape([Uri]::EscapeDataString($PublishBranch))
    ) | Sort-Object -Unique
    $patterns.Add([pscustomobject]@{
            Kind = 'publish-branch GitHub URL'
            Regex = [regex]::new(
                '(?:https?://)?github\.com/[^\s/]+/[^\s/]+/(?:tree|commits|compare)/[^\s]*(?:' +
                ($branchForms -join '|') +
                ')',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        })
}

$findings = [Collections.Generic.List[object]]::new()

function Test-ReferenceText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $lineNumber = 0
    foreach ($line in $Text -split '\r?\n') {
        $lineNumber++
        foreach ($pattern in $patterns) {
            $match = $pattern.Regex.Match($line)
            if ($match.Success) {
                $findings.Add([pscustomobject]@{
                        Source = $Source
                        Line = $lineNumber
                        Kind = $pattern.Kind
                        Match = $match.Value
                    })
            }
        }
    }
}

$commits = @(& git -C $RepoRoot rev-list --reverse "$BaseRef..HEAD")
if ($LASTEXITCODE -ne 0) {
    throw "Unable to enumerate commits after BaseRef: $BaseRef"
}
foreach ($commit in $commits) {
    $message = (& git -C $RepoRoot show -s --format='%B' $commit) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read commit message: $commit"
    }
    Test-ReferenceText -Text $message -Source "commit:${commit}:message"

    $path = '<unknown>'
    $patch = @(& git -C $RepoRoot show --format= --unified=0 --no-ext-diff $commit)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read commit patch: $commit"
    }
    foreach ($line in $patch) {
        if ($line.StartsWith('+++ b/')) {
            $path = $line.Substring(6)
            continue
        }
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) {
            Test-ReferenceText -Text $line.Substring(1) -Source "commit:${commit}:$path"
        }
    }
}

$textExtensions = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @(
        '.md', '.txt', '.ps1', '.psm1', '.psd1', '.json', '.yml', '.yaml',
        '.xml', '.cpp', '.c', '.h', '.hpp', '.rs', '.cs', '.ts', '.tsx',
        '.js', '.jsx', '.py', '.cmd', '.bat')) {
    [void]$textExtensions.Add($extension)
}

$trackedPaths = @(& git -C $RepoRoot diff --name-only --diff-filter=ACMRTUXB $BaseRef --)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate changed tracked files.'
}
$untrackedPaths = @(& git -C $RepoRoot ls-files --others --exclude-standard)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate untracked files.'
}
$changedPaths = @(
    @($trackedPaths + $untrackedPaths) |
        Where-Object { $_ } |
        Sort-Object -Unique
)
foreach ($relativePath in $changedPaths) {
    $fullPath = Join-Path $RepoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        continue
    }
    if (-not $textExtensions.Contains([IO.Path]::GetExtension($fullPath))) {
        continue
    }
    try {
        $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    }
    catch {
        Write-Verbose "Skipping unreadable text candidate '$relativePath': $($_.Exception.Message)"
        continue
    }
    Test-ReferenceText -Text $content -Source "worktree:$relativePath"
}

if ($findings.Count -gt 0) {
    $findings |
        Sort-Object Source, Line, Kind |
        Format-Table Source, Line, Kind, Match -AutoSize |
        Out-Host
    throw "Dev/publish reference isolation failed with $($findings.Count) finding(s)."
}

[pscustomobject]@{
    Passed = $true
    RepoRoot = $RepoRoot
    BaseRef = $BaseRef
    CommitCount = $commits.Count
    FileCount = $changedPaths.Count
}
