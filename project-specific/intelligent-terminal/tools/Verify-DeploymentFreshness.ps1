[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ReceiptPath,
    [switch]$RequireRunningTerminal,
    [switch]$PassThru,
    [Parameter(DontShow)]$InstalledPackage
)

$ErrorActionPreference = 'Stop'
$kitRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (& git -C $kitRoot rev-parse --show-toplevel).Trim() }
if (-not $ReceiptPath) { $ReceiptPath = Join-Path $kitRoot 'artifacts\build-receipt.json' }
if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    throw "Build receipt not found: $ReceiptPath. Run Invoke-BuildDeploy.ps1 first."
}

$receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
$fingerprint = & (Join-Path $kitRoot 'Get-LocalTddSourceFingerprint.ps1') `
    -RepoRoot $RepoRoot -SourcePaths @($receipt.sourcePaths)

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
    $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
}
function Get-Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

Add-Check 'source fingerprint' ($fingerprint.Fingerprint -eq $receipt.sourceFingerprint) `
    "current=$($fingerprint.Fingerprint) receipt=$($receipt.sourceFingerprint)"
Add-Check 'source HEAD' ($fingerprint.Head -eq $receipt.gitHead) `
    "current=$($fingerprint.Head) receipt=$($receipt.gitHead)"
if ($receipt.PSObject.Properties.Name -contains 'frameworkFingerprint') {
    $frameworkSourcePaths = @($receipt.frameworkSourcePaths)
    $currentFramework = & (Join-Path $kitRoot 'Get-LocalTddSourceFingerprint.ps1') `
        -RepoRoot $RepoRoot -SourcePaths $frameworkSourcePaths
    Add-Check 'framework fingerprint' ($currentFramework.Fingerprint -eq $receipt.frameworkFingerprint) `
        "current=$($currentFramework.Fingerprint) receipt=$($receipt.frameworkFingerprint)"
}

$cargoHash = Get-Hash $receipt.paths.cargoWta
$stagedWtaHash = Get-Hash $receipt.paths.stagedWta
Add-Check 'Cargo WTA exists' ([bool]$cargoHash) $receipt.paths.cargoWta
Add-Check 'staged WTA matches Cargo' ($cargoHash -and $cargoHash -eq $stagedWtaHash) `
    "cargo=$cargoHash staged=$stagedWtaHash"
if ($receipt.paths.PSObject.Properties.Name -contains 'recipeWtaSource') {
    $recipeWtaSource = [IO.Path]::GetFullPath([string]$receipt.paths.recipeWtaSource)
    $cargoWtaPath = [IO.Path]::GetFullPath([string]$receipt.paths.cargoWta)
    if ($receipt.PSObject.Properties.Name -contains 'deploymentMethod' -and $receipt.deploymentMethod -eq 'wta-only-refresh') {
        $recipeSources = & (Join-Path $kitRoot 'Get-AppxRecipePackageSources.ps1') -Path $receipt.paths.recipe
        Add-Check 'WTA refresh native receipt recorded' ($receipt.nativeReceiptSha256 -match '^[a-fA-F0-9]{64}$') `
            ([string]$receipt.nativeReceiptSha256)
        Add-Check 'WTA refresh recipe unchanged' ((Get-Hash $receipt.paths.recipe) -eq $receipt.recipeSha256) $receipt.paths.recipe
        Add-Check 'recipe maps recorded WTA transfer source' ($recipeSources['wta.exe'] -ieq $recipeWtaSource -and
            $receipt.paths.packageSources.'wta.exe' -ieq $recipeWtaSource) $recipeWtaSource
        Add-Check 'recipe WTA matches fresh Cargo build' ($cargoHash -and (Get-Hash $recipeWtaSource) -eq $cargoHash) `
            "recipe=$recipeWtaSource cargo=$cargoWtaPath"
    }
    else {
        Add-Check 'recipe maps explicit-target WTA' ($recipeWtaSource.Equals($cargoWtaPath, [StringComparison]::OrdinalIgnoreCase)) `
            "recipe=$recipeWtaSource cargo=$cargoWtaPath"
    }
}
if ($receipt.paths.PSObject.Properties.Name -contains 'packageSources') {
    foreach ($entry in $receipt.paths.packageSources.PSObject.Properties) {
        $source = [string]$entry.Value
        $sourceHash = Get-Hash $source
        Add-Check "recipe source exists: $($entry.Name)" ([bool]$sourceHash) $source
        if ($receipt.hashes.PSObject.Properties.Name -contains 'packageSources') {
            $recordedSourceHash = [string]$receipt.hashes.packageSources.($entry.Name)
            Add-Check "recipe source unchanged: $($entry.Name)" `
                ($recordedSourceHash -and $sourceHash -eq $recordedSourceHash) `
                "current=$sourceHash receipt=$recordedSourceHash"
        }
        $packaged = Join-Path $receipt.paths.appxLayout $entry.Name
        $packagedHash = Get-Hash $packaged
        Add-Check "recipe source matches AppX: $($entry.Name)" `
            ($sourceHash -and $sourceHash -eq $packagedHash) `
            "source=$sourceHash packaged=$packagedHash"
        if ($receipt.PSObject.Properties.Name -contains 'hashes' -and
            $receipt.hashes.PSObject.Properties.Name -contains 'appx') {
            $recordedAppxHash = [string]$receipt.hashes.appx.($entry.Name)
            Add-Check "AppX destination unchanged: $($entry.Name)" `
                ($recordedAppxHash -and $packagedHash -eq $recordedAppxHash) `
                "current=$packagedHash receipt=$recordedAppxHash"
        }
    }
}

$expectedInstall = [IO.Path]::GetFullPath([string]$receipt.paths.appxLayout)
$actualInstall = ''
if ($receipt.installVerified) {
    $package = if ($PSBoundParameters.ContainsKey('InstalledPackage')) {
        $InstalledPackage
    } else {
        Get-AppxPackage | Where-Object PackageFamilyName -eq $receipt.packageFamily | Select-Object -First 1
    }
    $actualInstall = if ($package) { [IO.Path]::GetFullPath([string]$package.InstallLocation) } else { '' }
    $installedWtaHash = Get-Hash $receipt.paths.installedWta
    Add-Check 'Dev package installed' ([bool]$package) $receipt.packageFamily
    Add-Check 'installed layout is this worktree AppX' ($actualInstall -and $actualInstall.Equals($expectedInstall, [StringComparison]::OrdinalIgnoreCase)) `
        "actual=$actualInstall expected=$expectedInstall"
    Add-Check 'installed WTA matches Cargo' ($cargoHash -and $cargoHash -eq $installedWtaHash) `
        "cargo=$cargoHash installed=$installedWtaHash"
    if ($receipt.PSObject.Properties.Name -contains 'deploymentMethod' -and $receipt.deploymentMethod -eq 'wta-only-refresh') {
        Add-Check 'WTA refresh registration unchanged' ($package.PackageFullName -ceq $receipt.packageFullName) $receipt.packageFullName
        $manifestPath = Join-Path $actualInstall 'AppxManifest.xml'
        Add-Check 'WTA refresh manifest unchanged' ((Get-Hash $manifestPath) -eq $receipt.manifestSha256) $manifestPath
    }
}

if ($receipt.installVerified) {
    foreach ($name in @('WindowsTerminal.exe', 'wtcli.exe', 'Microsoft.Terminal.Protocol.winmd', 'resources.pri')) {
        $staged = Join-Path $receipt.paths.appxLayout $name
        $installed = Join-Path $actualInstall $name
        $stagedHash = Get-Hash $staged
        $installedHash = Get-Hash $installed
        Add-Check "$name propagated" ($stagedHash -and $stagedHash -eq $installedHash) `
            "staged=$stagedHash installed=$installedHash"
    }
}

$runtimeRoot = if ($actualInstall) { $actualInstall.TrimEnd('\') + '\' } else { '' }
$runtime = @(Get-Process -Name WindowsTerminal,wta -ErrorAction SilentlyContinue | Where-Object {
        try { $runtimeRoot -and $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
if ($RequireRunningTerminal) {
    if (-not $receipt.installVerified) { throw '-RequireRunningTerminal requires a receipt with installVerified=true.' }
    Add-Check 'runtime uses installed layout' ([bool]($runtime | Where-Object ProcessName -eq 'WindowsTerminal')) `
        (($runtime | ForEach-Object { "$($_.ProcessName):$($_.Id):$($_.Path)" }) -join '; ')
}

$failed = @($checks | Where-Object { -not $_.Passed })
$checks | Format-Table -AutoSize
if ($failed) {
    throw "Deployment freshness verification failed: $(($failed.Name) -join ', ')."
}
Write-Host "Deployment freshness verified for $($fingerprint.Head)." -ForegroundColor Green
if ($PassThru) { $checks }