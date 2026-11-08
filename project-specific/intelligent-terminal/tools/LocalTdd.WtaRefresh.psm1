#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalTdd.Acceptance.psm1') -Force

function Invoke-LocalTddCargo {
    param([string]$RepoRoot, [string]$Configuration, [switch]$Test, [string]$SourceWtcli)
    $arguments = @($(if ($Test) { 'test' } else { 'build' }), '--target', 'x86_64-pc-windows-msvc',
        '--manifest-path', (Join-Path $RepoRoot 'tools\wta\Cargo.toml'),
        '--target-dir', (Join-Path $RepoRoot 'tools\wta\target'))
    if ($Test) { $arguments += @('--', '--test-threads=1') }
    $previousPath = $env:PATH
    Push-Location $RepoRoot
    try {
        if ($SourceWtcli) { $env:PATH = "$(Split-Path $SourceWtcli -Parent);$previousPath" }
        & cargo @arguments
        if ($LASTEXITCODE -ne 0) { throw 'Explicit-target Cargo failed.' }
    }
    finally { $env:PATH = $previousPath; Pop-Location }
}

function Get-LocalTddConfigFiles {
    param([string]$PackageFamily)
    foreach ($name in 'settings.json', 'state.json') {
        Join-Path $env:LOCALAPPDATA "Packages\$PackageFamily\LocalState\$name"
    }
}

function Assert-LocalTddUnusedLayout {
    param([string]$Layout)
    $prefix = [IO.Path]::GetFullPath($Layout).TrimEnd('\') + '\'
    $processes = @(Get-Process | Where-Object {
        $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($processes.Count) { throw 'The selected Dev layout is in use; no process will be closed.' }
}

function Assert-LocalTddNativeFiles {
    param([hashtable]$Reference, [switch]$IncludeWta)
    foreach ($name in $Reference.paths.packageSources.Keys) {
        if ($name -eq 'wta.exe' -and -not $IncludeWta) { continue }
        $source = $Reference.paths.packageSources[$name]
        $destination = Join-Path $Reference.paths.appxLayout $name
        $expected = $Reference.hashes.packageSources[$name]
        if (-not $expected -or $expected -ne $Reference.hashes.appx[$name] -or
            (Get-FileHash -LiteralPath $source).Hash -ne $expected -or
            (Get-FileHash -LiteralPath $destination).Hash -ne $expected) {
            throw "Native/package hash mismatch: $name"
        }
    }
}

function Invoke-LocalTddWtaRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$NativeReceiptPath,
        [Parameter(Mandatory)][string]$OutDir,
        [ValidateSet('Debug')][string]$Configuration = 'Debug',
        [switch]$SkipWtaTests
    )
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    $OutDir = [IO.Path]::GetFullPath($OutDir)
    $referenceHash = (Get-FileHash -LiteralPath $NativeReceiptPath).Hash
    $reference = Get-Content -LiteralPath $NativeReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    $fingerprintScript = Join-Path $PSScriptRoot 'Get-LocalTddSourceFingerprint.ps1'
    $canonical = & $fingerprintScript -RepoRoot $RepoRoot
    $scope = @($reference.sourcePaths | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') })
    if (@($canonical.SourcePaths | Where-Object { $_ -notin $scope }).Count) {
        throw 'Native receipt source scope is incomplete; use a full-scope native build receipt.'
    }
    if ($reference.schemaVersion -ne 1 -or $reference.installVerified -ne $true -or
        $reference.configuration -ne $Configuration -or $reference.platform -ne 'x64' -or
        $reference.rustTarget -ne 'x86_64-pc-windows-msvc' -or
        $reference.packageFamily -ne 'IntelligentTerminal_rd9vj3e6a2mbr') {
        throw 'WTA refresh requires a verified Debug x64 Dev receipt.'
    }
    $committed = & $fingerprintScript -RepoRoot $RepoRoot -CommittedHead $reference.gitHead -SourcePaths $scope
    if ($committed.Fingerprint -ne $reference.sourceFingerprint) {
        throw 'Native reference was not built from clean committed sources.'
    }
    $dirty = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw 'WTA refresh requires an exact clean source worktree.' }
    $nativeScope = @($scope | Where-Object { $_ -ne 'tools/wta' })
    & git -C $RepoRoot diff --quiet $reference.gitHead $canonical.Head -- @nativeScope
    if ($LASTEXITCODE -ne 0) { throw 'Native source inputs changed; a WTA-only refresh is insufficient.' }
    $packages = @(Get-AppxPackage | Where-Object PackageFamilyName -eq $reference.packageFamily)
    if ($packages.Count -ne 1 -or
        [IO.Path]::GetFullPath($packages[0].InstallLocation) -ine [IO.Path]::GetFullPath($reference.paths.appxLayout)) {
        throw 'The existing single Dev registration does not match the native receipt layout.'
    }
    Assert-LocalTddUnusedLayout $reference.paths.appxLayout
    $packageFullName = [string]$packages[0].PackageFullName
    $manifestPath = Join-Path $reference.paths.appxLayout 'AppxManifest.xml'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
    $recipeHash = (Get-FileHash -LiteralPath $reference.paths.recipe).Hash
    $sources = & (Join-Path $PSScriptRoot 'Get-AppxRecipePackageSources.ps1') -Path $reference.paths.recipe
    if ($sources.Count -ne $reference.paths.packageSources.Count) { throw 'Package recipe inventory changed.' }
    foreach ($name in $sources.Keys) {
        if ([IO.Path]::IsPathRooted($name) -or $name -match '(^|[\\/])\.\.([\\/]|$)' -or
            -not $reference.paths.packageSources.ContainsKey($name) -or
            $sources[$name] -ine [IO.Path]::GetFullPath($reference.paths.packageSources[$name])) {
            throw 'Package recipe source/destination mapping changed.'
        }
    }
    if (-not $sources.Contains('wta.exe')) { throw 'Package recipe has no WTA source.' }
    Assert-LocalTddNativeFiles $reference -IncludeWta
    $staged = Join-Path (Split-Path $reference.paths.appxLayout -Parent) 'wta.exe'
    $installed = Join-Path $reference.paths.appxLayout 'wta.exe'
    if ($staged -ine $reference.paths.stagedWta -or $installed -ine $reference.paths.installedWta -or
        (Get-FileHash -LiteralPath $staged).Hash -ne $reference.hashes.wta) {
        throw 'WTA staging layout/hash differs from the native receipt.'
    }
    if (Test-Path -LiteralPath $OutDir) { throw 'Use a new WTA refresh output directory.' }
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    $statePath = Join-Path $OutDir 'refresh-state.json'
    $lockPath = Join-Path (Split-Path $reference.paths.appxLayout -Parent) '.local-tdd-wta-refresh.lock'
    $state = @{
        schemaVersion = 1; status = 'running'; rollback = 'not-needed'; error = $null; rollbackError = $null
        head = $canonical.Head; startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        processId = $PID; processStartUtc = ([Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().ToString('o')
        completedUtc = $null; receiptPath = $null; nativeReceiptSha256 = $referenceHash
    }
    $destinations = @($sources['wta.exe'], $staged, $installed) | Sort-Object -Unique
    $backups = @()
    $configSnapshots = @()
    $mayHaveChangedWta = $false
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Write-LocalTddEvidenceJson -Path $statePath -Value $state
        foreach ($path in Get-LocalTddConfigFiles $reference.packageFamily) {
            $configSnapshots += @{ path = $path; hash = $(if (Test-Path -LiteralPath $path) { (Get-FileHash $path).Hash } else { $null }) }
        }
        foreach ($path in $destinations) {
            $backup = Join-Path $OutDir "previous-wta-$($backups.Count).exe"
            Copy-Item -LiteralPath $path -Destination $backup
            $backups += @{ path = $path; backup = $backup; hash = (Get-FileHash $path).Hash }
        }
        $mayHaveChangedWta = $true
        if (-not $SkipWtaTests) {
            Invoke-LocalTddCargo -RepoRoot $RepoRoot -Configuration $Configuration -Test -SourceWtcli $reference.paths.sourceWtcli |
                Out-File (Join-Path $OutDir 'wta-tests.log') -Encoding utf8
        }
        Invoke-LocalTddCargo -RepoRoot $RepoRoot -Configuration $Configuration |
            Out-File (Join-Path $OutDir 'wta-build.log') -Encoding utf8
        $builtWta = Join-Path $RepoRoot 'tools\wta\target\x86_64-pc-windows-msvc\debug\wta.exe'
        $after = & $fingerprintScript -RepoRoot $RepoRoot -SourcePaths $scope
        $sourceDirty = @(& git -C $RepoRoot status --porcelain)
        if ($LASTEXITCODE -ne 0 -or $sourceDirty.Count -or $after.Head -ne $canonical.Head -or $after.Dirty -or
            $after.Fingerprint -ne $canonical.Fingerprint) { throw 'Source changed during the WTA build.' }
        if ((Get-FileHash -LiteralPath $NativeReceiptPath).Hash -ne $referenceHash -or
            (Get-FileHash -LiteralPath $reference.paths.recipe).Hash -ne $recipeHash) {
            throw 'Native receipt or package recipe changed during the build.'
        }
        Assert-LocalTddUnusedLayout $reference.paths.appxLayout
        Assert-LocalTddNativeFiles $reference
        $hash = (Get-FileHash -LiteralPath $builtWta).Hash
        foreach ($path in $destinations) {
            if ($path -ine $builtWta) { Copy-Item -LiteralPath $builtWta -Destination $path -Force }
            if ((Get-FileHash -LiteralPath $path).Hash -ne $hash) { throw 'WTA propagation hash mismatch.' }
        }
        foreach ($item in $configSnapshots) {
            $actual = if (Test-Path -LiteralPath $item.path) { (Get-FileHash $item.path).Hash } else { $null }
            if ($actual -ne $item.hash) { throw 'Configuration changed during WTA refresh; it will not be overwritten.' }
        }
        $finalPackages = @(Get-AppxPackage | Where-Object PackageFamilyName -eq $reference.packageFamily)
        if ($finalPackages.Count -ne 1 -or $finalPackages[0].PackageFullName -cne $packageFullName -or
            $finalPackages[0].InstallLocation -ine $reference.paths.appxLayout -or
            (Get-FileHash -LiteralPath $manifestPath).Hash -ne $manifestHash) {
            throw 'Dev registration or manifest changed during the WTA refresh.'
        }
        $finalSource = & $fingerprintScript -RepoRoot $RepoRoot -SourcePaths $scope
        $finalDirty = @(& git -C $RepoRoot status --porcelain)
        if ($LASTEXITCODE -ne 0 -or $finalDirty.Count -or $finalSource.Fingerprint -ne $after.Fingerprint -or $finalSource.Dirty) {
            throw 'Source changed during WTA propagation.'
        }
        $receipt = $reference
        $receipt.nativeSourceHead = if ($reference.ContainsKey('nativeSourceHead')) { $reference.nativeSourceHead } else { $reference.gitHead }
        $receipt.gitHead = $after.Head
        $receipt.sourceFingerprint = $after.Fingerprint
        $receipt.buildStartedUtc = $state.startedUtc
        $receipt.createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $receipt.deploymentMethod = 'wta-only-refresh'
        $receipt.nativeReceiptSha256 = $referenceHash
        $receipt.recipeSha256 = $recipeHash
        $receipt.packageFullName = $packageFullName
        $receipt.manifestSha256 = $manifestHash
        $receipt.paths.repoRoot = $RepoRoot
        $receipt.paths.cargoWta = $builtWta
        $receipt.paths.recipeWtaSource = $sources['wta.exe']
        $receipt.hashes.wta = $hash
        $receipt.hashes.packageSources['wta.exe'] = $hash
        $receipt.hashes.appx['wta.exe'] = $hash
        $state.receiptPath = Join-Path $OutDir 'build-receipt.json'
        Write-LocalTddEvidenceJson -Path $state.receiptPath -Value $receipt
        $state.status = 'passed'
    }
    catch {
        $state.error = $_.Exception.Message
        $state.status = 'failed'
        if ($mayHaveChangedWta) {
            try {
                foreach ($item in $backups) {
                    if (-not (Test-Path -LiteralPath $item.path) -or (Get-FileHash -LiteralPath $item.path).Hash -ne $item.hash) {
                        Copy-Item -LiteralPath $item.backup -Destination $item.path -Force
                    }
                    if ((Get-FileHash -LiteralPath $item.path).Hash -ne $item.hash) { throw 'Restored WTA hash differs.' }
                }
                $state.rollback = 'passed'
            }
            catch { $state.rollback = 'failed'; $state.rollbackError = $_.Exception.Message }
        }
        throw
    }
    finally {
        $state.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        try { Write-LocalTddEvidenceJson -Path $statePath -Value $state }
        finally { $lock.Dispose() }
    }
    return [pscustomobject]$state
}

Export-ModuleMember -Function Invoke-LocalTddWtaRefresh
