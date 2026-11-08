[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecipePath,
    [Parameter(Mandatory)][string]$MsixPath,
    [string]$PackageFamilyName = 'IntelligentTerminal_rd9vj3e6a2mbr',
    [Parameter(DontShow)]$InstalledPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$recipe = [IO.Path]::GetFullPath($RecipePath)
$msix = [IO.Path]::GetFullPath($MsixPath)
foreach ($path in @($recipe, $msix)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package input does not exist: $path"
    }
}

$packages = @(
    if ($PSBoundParameters.ContainsKey('InstalledPackage')) {
        $InstalledPackage
    } else {
        Get-AppxPackage | Where-Object PackageFamilyName -eq $PackageFamilyName
    }
)
if ($packages.Count -ne 1 -or -not $packages[0] -or
    $packages[0].PackageFamilyName -ne $PackageFamilyName -or
    -not $packages[0].PackageFullName -or -not $packages[0].InstallLocation) {
    throw "Expected exactly one installed package in family '$PackageFamilyName'."
}
$package = $packages[0]
$layout = [IO.Path]::GetFullPath([string]$package.InstallLocation).TrimEnd('\')
$registeredManifest = Join-Path $layout 'AppxManifest.xml'
if (-not (Test-Path -LiteralPath $registeredManifest -PathType Leaf)) {
    throw "Registered layout has no AppxManifest.xml: $layout"
}

function Get-ManifestIdentity([xml]$Document) {
    $identity = $Document.SelectSingleNode("//*[local-name()='Identity']")
    if (-not $identity -or -not $identity.GetAttribute('Name') -or
        -not $identity.GetAttribute('Publisher') -or -not $identity.GetAttribute('Version')) {
        throw 'Package manifest has no complete Identity.'
    }
    [pscustomobject]@{
        Name = $identity.GetAttribute('Name')
        Publisher = $identity.GetAttribute('Publisher')
        Version = $identity.GetAttribute('Version')
    }
}
function Get-ArchiveEntryHash([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
}

[xml]$recipeXml = Get-Content -LiteralPath $recipe -Raw
$manifestNode = $recipeXml.SelectSingleNode("//*[local-name()='AppXManifest']")
if (-not $manifestNode -or -not $manifestNode.Include) {
    throw "Package recipe has no AppXManifest source: $recipe"
}
$sourceManifest = [IO.Path]::GetFullPath([Uri]::UnescapeDataString([string]$manifestNode.Include))
if (-not (Test-Path -LiteralPath $sourceManifest -PathType Leaf)) {
    throw "Recipe manifest source does not exist: $sourceManifest"
}
$sourceIdentity = Get-ManifestIdentity ([xml](Get-Content -LiteralPath $sourceManifest -Raw))
$installedIdentity = Get-ManifestIdentity ([xml](Get-Content -LiteralPath $registeredManifest -Raw))
$recipeSources = & (Join-Path $PSScriptRoot 'Get-AppxRecipePackageSources.ps1') -Path $recipe

Add-Type -AssemblyName System.IO.Compression
$archive = [IO.Compression.ZipFile]::OpenRead($msix)
try {
    $archiveEntries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
        if (-not $entry.Name) { continue }
        $name = $entry.FullName.Replace('/', '\')
        if (-not $archiveEntries.TryAdd($name, $entry)) {
            throw "MSIX contains duplicate package path: $name"
        }
    }
    if (-not $archiveEntries.ContainsKey('AppxManifest.xml')) {
        throw "MSIX has no AppxManifest.xml: $msix"
    }
    $msixManifestEntry = $archiveEntries['AppxManifest.xml']
    $stream = $msixManifestEntry.Open()
    try {
        $msixManifest = [xml]::new()
        $msixManifest.Load($stream)
    }
    finally { $stream.Dispose() }
    $msixIdentity = Get-ManifestIdentity $msixManifest
    if ($sourceIdentity.Name -ne $msixIdentity.Name -or
        $sourceIdentity.Publisher -ne $msixIdentity.Publisher -or
        $sourceIdentity.Version -ne $msixIdentity.Version -or
        $installedIdentity.Name -ne $msixIdentity.Name -or
        $installedIdentity.Publisher -ne $msixIdentity.Publisher -or
        $package.Name -ne $installedIdentity.Name) {
        throw 'Recipe, MSIX and registered package identities disagree.'
    }

    $layoutRoot = $layout + '\'
    $items = @(
        foreach ($packagePath in $recipeSources.Keys) {
            $relative = [string]$packagePath
            if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or
                $relative.Contains(':') -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or
                $relative -ieq 'AppxManifest.xml') {
                throw "Unsafe package path in recipe: $relative"
            }
            $source = [string]$recipeSources[$packagePath]
            $destination = [IO.Path]::GetFullPath((Join-Path $layout $relative))
            if (-not $destination.StartsWith($layoutRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $source -PathType Leaf) -or
                -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                throw "Missing or out-of-layout recipe payload: $relative"
            }

            $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            $installedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            $archivePath = $relative.Replace('/', '\')
            $inMsix = $archiveEntries.ContainsKey($archivePath)
            if ($inMsix) {
                if ((Get-ArchiveEntryHash $archiveEntries[$archivePath]) -ne $sourceHash) {
                    throw "MSIX payload differs from recipe source: $relative"
                }
            }
            elseif ($relative -notmatch '^ProfileIcons[\\/][^\\/]+\.scale-\d+\.png$') {
                throw "Recipe payload is absent from MSIX: $relative"
            }

            [pscustomobject]@{
                PackagePath = $relative
                Source = $source
                Destination = $destination
                SourceSha256 = $sourceHash
                InstalledSha256 = $installedHash
                IncludedInMsix = $inMsix
                NeedsUpdate = $sourceHash -ne $installedHash
            }
        }
    )
    $msixManifestHash = Get-ArchiveEntryHash $msixManifestEntry
}
finally { $archive.Dispose() }

$registeredManifestHash = (Get-FileHash -LiteralPath $registeredManifest -Algorithm SHA256).Hash
$manifestMatches = $registeredManifestHash -eq $msixManifestHash
$changes = @($items | Where-Object NeedsUpdate)

[pscustomobject]@{
    RecipeSha256 = (Get-FileHash -LiteralPath $recipe -Algorithm SHA256).Hash
    MsixSha256 = (Get-FileHash -LiteralPath $msix -Algorithm SHA256).Hash
    PackageFullName = [string]$package.PackageFullName
    InstalledLayout = $layout
    RegisteredManifestSha256 = $registeredManifestHash
    MsixManifestSha256 = $msixManifestHash
    RegisteredManifestMatchesMsix = $manifestMatches
    RegisteredVersion = $installedIdentity.Version
    MsixVersion = $msixIdentity.Version
    EntryCount = $items.Count
    MsixEntryCount = @($items | Where-Object IncludedInMsix).Count
    OmittedScaleAssets = @($items | Where-Object { -not $_.IncludedInMsix } | Select-Object -ExpandProperty PackagePath)
    NeedsUpdateCount = $changes.Count
    RecipeAndManifestMatch = $manifestMatches -and $changes.Count -eq 0
    Entries = $items
}
