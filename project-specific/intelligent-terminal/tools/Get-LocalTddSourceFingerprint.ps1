[CmdletBinding()]
param(
    [string]$RepoRoot,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$CommittedHead,
    [string[]]$SourcePaths = @(
        'tools/wta', 'src', 'build', 'res', 'policies', 'packages.config',
        'NuGet.Config', 'vcpkg.json', '.vsconfig', 'OpenConsole.slnx',
        'Directory.Build.props', 'Directory.Build.targets', 'common.openconsole.props',
        'custom.props', 'Cargo.lock', '_build_msix_x64.cmd', '_build_msix_arm64.cmd'
    )
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
}
if (-not $RepoRoot -or -not (Test-Path -LiteralPath $RepoRoot)) {
    throw 'Repository root could not be resolved.'
}

$revision = if ($CommittedHead) { "$CommittedHead^{commit}" } else { 'HEAD' }
$head = (& git -C $RepoRoot rev-parse $revision).Trim()
if ($LASTEXITCODE -ne 0) { throw 'git rev-parse HEAD failed.' }

$pathArgs = @('--') + $SourcePaths
$diff = ''
$untracked = @()
if (-not $CommittedHead) {
    $diff = (& git -C $RepoRoot diff --binary HEAD @pathArgs 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'git diff failed while computing the source fingerprint.' }
    $untracked = @(& git -C $RepoRoot ls-files --others --exclude-standard @pathArgs)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed while computing the source fingerprint.' }
}

$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine("HEAD=$head")
[void]$builder.AppendLine($diff)
foreach ($relative in ($untracked | Sort-Object -Unique)) {
    $full = Join-Path $RepoRoot $relative
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        [void]$builder.AppendLine("UNTRACKED=$relative|$hash")
    }
}

$bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
$sha = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = [Convert]::ToHexString($sha.ComputeHash($bytes)) }
finally { $sha.Dispose() }

[pscustomobject]@{
    RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    Head = $head
    Fingerprint = $fingerprint
    Mode = if ($CommittedHead) { 'committed-tree' } else { 'worktree' }
    SourcePaths = $SourcePaths
    Dirty = [bool]($diff -or $untracked.Count)
    UntrackedPaths = @($untracked)
}