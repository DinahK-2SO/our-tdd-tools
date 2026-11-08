[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [switch]$SkipWtaTests,
    [switch]$SkipDeploy,
    [switch]$ReplaceExistingDevRegistration,
    [switch]$CloseRunningPackageProcesses,
    [switch]$Launch,
    [string[]]$SourcePaths
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$kitRoot = $PSScriptRoot
$repoRoot = (& git -C $kitRoot rev-parse --show-toplevel).Trim()
$rustTarget = 'x86_64-pc-windows-msvc'
$rustProfile = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
$manifest = Join-Path $repoRoot 'tools\wta\Cargo.toml'
$wtcliProjectDir = Join-Path $repoRoot 'src\tools\wtcli'
$wtcli = Join-Path $repoRoot "bin\x64\$Configuration\wtcli\wtcli.exe"
$cargoWta = Join-Path $repoRoot "tools\wta\target\$rustTarget\$rustProfile\wta.exe"
$packageDir = Join-Path $repoRoot 'src\cascadia\CascadiaPackage'
$recipe = Join-Path $packageDir "bin\x64\$Configuration\CascadiaPackage.build.appxrecipe"
$appx = Join-Path $packageDir "bin\x64\$Configuration\AppX"
$stagedWta = Join-Path $packageDir "bin\x64\$Configuration\wta.exe"
$packageFamily = 'IntelligentTerminal_rd9vj3e6a2mbr'
$receiptPath = Join-Path $kitRoot 'artifacts\build-receipt.json'
if (-not $SourcePaths) {
    $SourcePaths = @(
        'tools/wta', 'src', 'build', 'res', 'policies', 'packages.config',
        'NuGet.Config', 'vcpkg.json', '.vsconfig', 'OpenConsole.slnx',
        'Directory.Build.props', 'Directory.Build.targets', 'common.openconsole.props',
        'custom.props', 'Cargo.lock', '_build_msix_x64.cmd', '_build_msix_arm64.cmd'
    )
}
$expectedLayout = [IO.Path]::GetFullPath($appx)

function Invoke-Step([string]$Name, [scriptblock]$Action) {
    Write-Host "`n==> $Name" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE." }
}
function Get-DevPackage {
    Get-AppxPackage | Where-Object PackageFamilyName -eq $packageFamily | Select-Object -First 1
}
function Get-ExactPackageProcesses($Package) {
    if (-not $Package -or -not $Package.InstallLocation) { return @() }
    $root = [IO.Path]::GetFullPath([string]$Package.InstallLocation).TrimEnd('\') + '\'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
        })
}
function Stop-ExactPackageProcesses($Package) {
    $processes = @(Get-ExactPackageProcesses $Package)
    if (-not $processes.Count) { return }
    foreach ($process in $processes) { try { [void]$process.CloseMainWindow() } catch {} }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $remaining = @($processes | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
        if (-not $remaining) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    foreach ($process in $remaining) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}

$fingerprint = & (Join-Path $kitRoot 'Get-LocalTddSourceFingerprint.ps1') -RepoRoot $repoRoot -SourcePaths $SourcePaths
$commonToolsRoot = [IO.Path]::GetFullPath((Join-Path $kitRoot '..\..\..\common\tools'))
$frameworkSourcePaths = @(
    [IO.Path]::GetRelativePath($repoRoot, $kitRoot).Replace('\', '/')
    [IO.Path]::GetRelativePath($repoRoot, $commonToolsRoot).Replace('\', '/')
)
$frameworkFingerprint = & (Join-Path $kitRoot 'Get-LocalTddSourceFingerprint.ps1') `
    -RepoRoot $repoRoot -SourcePaths $frameworkSourcePaths
$buildStarted = [DateTime]::UtcNow

Invoke-Step 'Build source-matched wtcli' {
    Push-Location $wtcliProjectDir
    try {
        $mode = if ($Configuration -eq 'Release') { 'rel' } else { '' }
        if ($mode) { cmd.exe /d /c "call ..\..\..\tools\razzle.cmd && bx $mode" }
        else { cmd.exe /d /c 'call ..\..\..\tools\razzle.cmd && bx' }
    }
    finally { Pop-Location }
}
if (-not (Test-Path -LiteralPath $wtcli -PathType Leaf)) { throw "Expected source-matched wtcli missing: $wtcli" }
$wtcliHelp = & $wtcli --help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $wtcliHelp -notmatch 'agent-hook') {
    throw "Source-matched wtcli does not advertise agent-hook: $wtcli"
}

if (-not $SkipWtaTests) {
    Invoke-Step 'Test WTA with source-matched wtcli' {
        $previousPath = $env:PATH
        try {
            $env:PATH = "$(Split-Path $wtcli -Parent);$previousPath"
            cargo test --target $rustTarget --manifest-path $manifest
        }
        finally { $env:PATH = $previousPath }
    }
}
Invoke-Step 'Build explicit-target WTA product' {
    $args = @('build', '--target', $rustTarget, '--manifest-path', $manifest)
    if ($Configuration -eq 'Release') { $args += '--release' }
    & cargo @args
}
if (-not (Test-Path -LiteralPath $cargoWta -PathType Leaf)) { throw "Expected WTA product missing: $cargoWta" }

$installedBeforeBuild = Get-DevPackage
if ($installedBeforeBuild -and
    [IO.Path]::GetFullPath([string]$installedBeforeBuild.InstallLocation).Equals(
        [IO.Path]::GetFullPath($appx),
        [StringComparison]::OrdinalIgnoreCase)) {
    $running = @(Get-ExactPackageProcesses $installedBeforeBuild)
    if ($running.Count -and -not $CloseRunningPackageProcesses) {
        throw "The current Dev package has running process(es) [$($running.Id -join ', ')]. Re-run with -CloseRunningPackageProcesses to close only exact package-owned processes."
    }
    if ($running.Count) { Stop-ExactPackageProcesses $installedBeforeBuild }
}
Invoke-Step 'Build CascadiaPackage and dependencies' {
    Push-Location $packageDir
    try {
        $mode = if ($Configuration -eq 'Release') { 'rel' } else { '' }
        if ($mode) { cmd.exe /d /c "call ..\..\..\tools\razzle.cmd && bx $mode" }
        else { cmd.exe /d /c 'call ..\..\..\tools\razzle.cmd && bx' }
    }
    finally { Pop-Location }
}

foreach ($required in @($recipe, $stagedWta)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required package artifact missing: $required" }
}
$recipeSources = & (Join-Path $kitRoot 'Get-AppxRecipePackageSources.ps1') -Path $recipe
foreach ($packagePath in $recipeSources.Keys) {
    $source = $recipeSources[$packagePath]
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Package recipe source for '$packagePath' does not exist: $source"
    }
}
$recipeWta = $recipeSources['wta.exe']
if (-not $recipeWta.Equals([IO.Path]::GetFullPath($cargoWta), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Package recipe selected stale/unexpected WTA source '$recipeWta'; expected '$cargoWta'."
}
$cargoHash = (Get-FileHash -LiteralPath $cargoWta -Algorithm SHA256).Hash
$stagedHash = (Get-FileHash -LiteralPath $stagedWta -Algorithm SHA256).Hash
if ($cargoHash -ne $stagedHash) {
    throw "Package output contains stale wta.exe. Cargo=$cargoHash PackageOutput=$stagedHash. Rebuild CascadiaPackage."
}

if (-not $SkipDeploy) {
    if ($Configuration -ne 'Debug') {
        throw 'The safe loose-package deployment helper accepts Debug recipes only. Use -SkipDeploy for Release.'
    }
    $existing = Get-DevPackage
    if ($existing -and -not [IO.Path]::GetFullPath([string]$existing.InstallLocation).Equals($expectedLayout, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $ReplaceExistingDevRegistration) {
            throw "Dev package is registered from another worktree: $($existing.InstallLocation). Re-run with -ReplaceExistingDevRegistration to replace it while preserving app data."
        }
        Stop-ExactPackageProcesses $existing
        Remove-AppxPackage -Package $existing.PackageFullName -PreserveApplicationData
    }
    $deploy = Join-Path $repoRoot 'build\scripts\Invoke-IntelligentTerminalDebugDeployment.ps1'
    & $deploy -AppxRecipePath $recipe -NoRestart
}

$verifyInstalled = $Configuration -eq 'Debug' -and -not $SkipDeploy
$installed = Get-DevPackage
$installedWta = $null
if ($verifyInstalled) {
    if (-not $installed) { throw "Dev package $packageFamily is not installed." }
    $actualLayout = [IO.Path]::GetFullPath([string]$installed.InstallLocation)
    if (-not $actualLayout.Equals($expectedLayout, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installed Dev package points to '$actualLayout', not this worktree's AppX '$expectedLayout'."
    }
    $installedWta = Join-Path $actualLayout 'wta.exe'
    $installedHash = (Get-FileHash -LiteralPath $installedWta -Algorithm SHA256).Hash
    if ($installedHash -ne $cargoHash) { throw "Installed wta.exe is stale. Cargo=$cargoHash Installed=$installedHash" }
}

$packageSourceHashes = [ordered]@{}
$appxHashes = [ordered]@{}
foreach ($packagePath in $recipeSources.Keys) {
    $packageSourceHashes[$packagePath] = (Get-FileHash -LiteralPath $recipeSources[$packagePath] -Algorithm SHA256).Hash
    $packagedPath = Join-Path $appx $packagePath
    if (-not (Test-Path -LiteralPath $packagedPath -PathType Leaf)) {
        throw "AppX layout is missing recipe destination '$packagePath': $packagedPath"
    }
    $appxHashes[$packagePath] = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash
    if ($packageSourceHashes[$packagePath] -ne $appxHashes[$packagePath]) {
        throw "AppX contains stale '$packagePath'. Source=$($packageSourceHashes[$packagePath]) AppX=$($appxHashes[$packagePath])"
    }
}

New-Item -ItemType Directory -Force -Path (Split-Path $receiptPath -Parent) | Out-Null
[ordered]@{
    schemaVersion = 2
    createdUtc = [DateTime]::UtcNow.ToString('o')
    buildStartedUtc = $buildStarted.ToString('o')
    gitHead = $fingerprint.Head
    sourceFingerprint = $fingerprint.Fingerprint
    sourcePaths = $SourcePaths
    frameworkFingerprint = $frameworkFingerprint.Fingerprint
    frameworkSourcePaths = $frameworkSourcePaths
    configuration = $Configuration
    platform = 'x64'
    rustTarget = $rustTarget
    packageFamily = $packageFamily
    installVerified = $verifyInstalled
    hashes = @{
        wta = $cargoHash
        packageSources = $packageSourceHashes
        appx = $appxHashes
    }
    paths = @{
        repoRoot = $repoRoot
        sourceWtcli = $wtcli
        cargoWta = $cargoWta
        appxLayout = $appx
        stagedWta = $stagedWta
        recipeWtaSource = $recipeWta
        packageSources = $recipeSources
        installLocation = if ($verifyInstalled) { [string]$installed.InstallLocation } else { $null }
        installedWta = $installedWta
        recipe = $recipe
    }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8

if ($Launch) {
    if (-not $verifyInstalled) { throw '-Launch requires a verified Debug deployment.' }
    Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$packageFamily!App"
    $runtimeRoot = $expectedLayout.TrimEnd('\') + '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $terminal = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
        } | Select-Object -First 1
        if ($terminal) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $terminal) { throw "Dev Terminal did not start from '$expectedLayout' within 30 seconds." }
}
& (Join-Path $kitRoot 'Verify-DeploymentFreshness.ps1') -RepoRoot $repoRoot -ReceiptPath $receiptPath -RequireRunningTerminal:$Launch