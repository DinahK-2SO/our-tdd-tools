[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$NativeBuildRoot,
    [Parameter(Mandatory)][string]$MsixPath,
    [Parameter(Mandatory)][string]$PackageFamily,
    [Parameter(Mandatory)][string]$OutPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DevTarget.ps1')
if ((Resolve-LocalTddDevFamily $PackageFamily) -cnotlike 'IntelligentTerminal.Worktree.*') { throw 'A private Dev package is required.' }
if (Test-Path -LiteralPath $OutPath) { throw 'Use a new receipt path.' }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$NativeBuildRoot = (Resolve-Path -LiteralPath $NativeBuildRoot).Path
foreach ($source in @($RepoRoot, $NativeBuildRoot)) {
    if ((git -C $source rev-parse HEAD) -ne $ExpectedHead -or $LASTEXITCODE) { throw 'Native or publish checkout differs from the expected PR head.' }
}
$fingerprint = & (Join-Path $PSScriptRoot 'Get-LocalTddSourceFingerprint.ps1') -RepoRoot $RepoRoot
if ($fingerprint.Dirty) { throw 'Published product inputs are dirty.' }
$manifestPath = 'src/cascadia/CascadiaPackage/Package-Dev.appxmanifest'
$windowPath = 'src/cascadia/WindowsTerminal/WindowEmperor.cpp'
$protocolPath = 'src/cascadia/WindowsTerminal/TerminalProtocolComServer.h'
$files = @(git -C $NativeBuildRoot diff --name-only HEAD)
$untracked = @(git -C $NativeBuildRoot ls-files --others --exclude-standard)
if ($LASTEXITCODE -or $untracked.Count -or (Compare-Object @($manifestPath,$windowPath,$protocolPath) $files)) {
    throw 'Only the three private package identity substitutions are allowed.'
}
$installed = @(Get-AppxPackage -ErrorAction Stop | Where-Object PackageFamilyName -CEQ $PackageFamily)
if ($installed.Count -ne 1) { throw 'Private Dev target is not uniquely registered.' }
$pkg = $installed[0]
$clsid = [guid](Get-ItPrivateProtocolClsid $pkg)
$token = $pkg.Name.Substring('IntelligentTerminal.Worktree.'.Length)
function Read-Source([string]$Root, [string]$File) {
    [IO.File]::ReadAllText((Join-Path $Root $File)).Replace("`r`n", "`n").TrimEnd()
}
$expectedWindow = (Read-Source $RepoRoot $windowPath).Replace('L"Windows Terminal Dev"', ('L"Windows Terminal Dev ' + $token + '"'))
$expectedProtocol = (Read-Source $RepoRoot $protocolPath).Replace('"D5B7C9E1-4F6A-4B8C-D9E0-F1A2B3C4D5E6"', ('"' + $clsid.ToString('D') + '"'))
if ((Read-Source $NativeBuildRoot $windowPath) -cne $expectedWindow -or
    (Read-Source $NativeBuildRoot $protocolPath) -cne $expectedProtocol) { throw 'Unexpected changes to private native source.' }
$original = Read-Source $RepoRoot $manifestPath
$template = Read-Source $RepoRoot 'build/templates/Package-DevWorktree.appxmanifest.template'
$resources = [regex]::Match($original, '(?s)<Resources>(.*?)</Resources>').Groups[1].Value.Trim()
if (-not $resources) { throw 'Could not read the original Dev package resources.' }
$template = $template.Replace('__WORKTREE_TOKEN__',$token).Replace('__PROTOCOL_CLSID__',$clsid.ToString('D')).Replace('__DEV_PACKAGE_VERSION__',[string]$pkg.Version).Replace('__DEV_PACKAGE_RESOURCES__',$resources)
$actualManifest = [xml](Read-Source $NativeBuildRoot $manifestPath)
$expectedManifest = [xml]$template
if ($actualManifest.OuterXml -cne $expectedManifest.OuterXml) { throw 'Private manifest differs from the product isolation template.' }

$packageBin = Join-Path $NativeBuildRoot 'src\cascadia\CascadiaPackage\bin\x64\Debug'
$recipe = Join-Path $packageBin 'CascadiaPackage.build.appxrecipe'
$comparison = & (Join-Path $PSScriptRoot 'Compare-AppxRecipeToDevLayout.ps1') -RecipePath $recipe -MsixPath $MsixPath -PackageFamilyName $PackageFamily
if (-not $comparison.RecipeAndManifestMatch) { throw 'Private registration does not match the built native MSIX and recipe.' }
$sources = & (Join-Path $PSScriptRoot 'Get-AppxRecipePackageSources.ps1') -Path $recipe
$hashes = @{}
foreach ($entry in $comparison.Entries) { $hashes[$entry.PackagePath] = $entry.SourceSha256 }
$receipt = [ordered]@{
    schemaVersion=2; gitHead=$ExpectedHead; nativeSourceHead=$ExpectedHead
    sourceFingerprint=$fingerprint.Fingerprint; sourcePaths=$fingerprint.SourcePaths
    configuration='Debug'; platform='x64'; rustTarget='x86_64-pc-windows-msvc'
    packageFamily=$PackageFamily; packageFullName=$pkg.PackageFullName; installVerified=$true
    msixSha256=$comparison.MsixSha256; recipeSha256=$comparison.RecipeSha256
    manifestSha256=$comparison.RegisteredManifestSha256; privateProtocolClsid=$clsid.ToString('B')
    hashes=@{wta=$hashes['wta.exe']; packageSources=$hashes; appx=$hashes}
    paths=@{repoRoot=$RepoRoot; appxLayout=$pkg.InstallLocation; installedWta=(Join-Path $pkg.InstallLocation 'wta.exe')
            stagedWta=(Join-Path $packageBin 'wta.exe'); recipe=$recipe; packageSources=$sources
            sourceWtcli=$sources['wtcli.exe']; recipeWtaSource=$sources['wta.exe']; cargoWta=$sources['wta.exe']}
}
$receipt | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $OutPath -Encoding utf8 -NoClobber
