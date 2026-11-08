#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:kit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:refreshModule = Join-Path $script:kit 'LocalTdd.WtaRefresh.psm1'
    if (Test-Path $script:refreshModule) { Import-Module $script:refreshModule -Force }
}

Describe 'Receipt-constrained WTA refresh' -Tag 'Unit', 'WtaRefresh' {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:repo = Join-Path $script:fixture 'source'
        $script:layout = Join-Path $script:fixture 'package\AppX'
        $script:native = Join-Path $script:fixture 'native'
        New-Item -ItemType Directory -Force -Path "$script:repo\tools\wta", "$script:repo\src", $script:layout, $script:native | Out-Null
        '[package]' | Set-Content "$script:repo\tools\wta\Cargo.toml"
        'native source' | Set-Content "$script:repo\src\native.txt"
        'tools/wta/target/' | Set-Content "$script:repo\.gitignore"
        & git -C $script:repo init --quiet
        & git -C $script:repo config user.name 'Local TDD Test'
        & git -C $script:repo config user.email 'local-tdd@example.invalid'
        & git -C $script:repo add .
        & git -C $script:repo commit --quiet -m baseline
        $fingerprint = & "$script:kit\Get-LocalTddSourceFingerprint.ps1" -RepoRoot $script:repo
        'old WTA' | Set-Content "$script:native\wta.exe"
        'native binary' | Set-Content "$script:native\native.dll"
        Copy-Item "$script:native\wta.exe" "$script:layout\wta.exe"
        Copy-Item "$script:native\wta.exe" (Join-Path (Split-Path $script:layout -Parent) 'wta.exe')
        Copy-Item "$script:native\native.dll" "$script:layout\native.dll"
        '<Package />' | Set-Content "$script:layout\AppxManifest.xml"
        foreach ($name in 'WindowsTerminal.exe', 'wtcli.exe', 'Microsoft.Terminal.Protocol.winmd', 'resources.pri') {
            'offline package fixture' | Set-Content (Join-Path $script:layout $name)
        }
        $script:recipe = Join-Path $script:fixture 'native.build.appxrecipe'
        @"
<Project><ItemGroup>
<AppxPackagedFile Include="$script:native\wta.exe"><PackagePath>wta.exe</PackagePath></AppxPackagedFile>
<AppxPackagedFile Include="$script:native\native.dll"><PackagePath>native.dll</PackagePath></AppxPackagedFile>
</ItemGroup></Project>
"@ | Set-Content $script:recipe -Encoding utf8
        $script:receipt = @{
            schemaVersion = 1; gitHead = $fingerprint.Head; sourcePaths = $fingerprint.SourcePaths
            sourceFingerprint = $fingerprint.Fingerprint; configuration = 'Debug'; platform = 'x64'
            rustTarget = 'x86_64-pc-windows-msvc'; installVerified = $true
            packageFamily = 'IntelligentTerminal_rd9vj3e6a2mbr'
            hashes = @{
                wta = (Get-FileHash "$script:native\wta.exe").Hash
                packageSources = @{
                    'wta.exe' = (Get-FileHash "$script:native\wta.exe").Hash
                    'native.dll' = (Get-FileHash "$script:native\native.dll").Hash
                }
                appx = @{
                    'wta.exe' = (Get-FileHash "$script:layout\wta.exe").Hash
                    'native.dll' = (Get-FileHash "$script:layout\native.dll").Hash
                }
            }
            paths = @{
                repoRoot = $script:repo; cargoWta = "$script:native\wta.exe"
                sourceWtcli = "$script:native\wtcli.exe"; appxLayout = $script:layout
                stagedWta = (Join-Path (Split-Path $script:layout -Parent) 'wta.exe')
                installedWta = "$script:layout\wta.exe"; recipe = $script:recipe
                recipeWtaSource = "$script:native\wta.exe"
                packageSources = @{ 'wta.exe' = "$script:native\wta.exe"; 'native.dll' = "$script:native\native.dll" }
            }
        }
        $script:reference = Join-Path $script:fixture 'native-receipt.json'
        $script:receipt | ConvertTo-Json -Depth 8 | Set-Content $script:reference -Encoding utf8
        $script:refreshArgs = @{
            RepoRoot = $script:repo; NativeReceiptPath = $script:reference
            OutDir = Join-Path $script:fixture 'refresh'; SkipWtaTests = $true
        }
        Mock -ModuleName LocalTdd.WtaRefresh Get-AppxPackage {
            @{ PackageFamilyName = 'IntelligentTerminal_rd9vj3e6a2mbr'; InstallLocation = $script:layout; PackageFullName = 'offline-dev' }
        }
        Mock -ModuleName LocalTdd.WtaRefresh Get-Process { @() }
        Mock -ModuleName LocalTdd.WtaRefresh Get-LocalTddConfigFiles { @() }
        Mock -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo {
            param($RepoRoot, $Configuration, $Test)
            if (-not $Test) {
                $path = Join-Path $RepoRoot 'tools\wta\target\x86_64-pc-windows-msvc\debug\wta.exe'
                New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
                'new source-built WTA' | Set-Content $path
            }
        }
    }

    It 'builds exact sources and updates only WTA while preserving native binaries' {
        $result = Invoke-LocalTddWtaRefresh @script:refreshArgs
        $result.status | Should -Be 'passed'
        $new = Get-Content $result.receiptPath -Raw | ConvertFrom-Json
        $new.gitHead | Should -Be $script:receipt.gitHead
        $new.deploymentMethod | Should -Be 'wta-only-refresh'
        $new.nativeSourceHead | Should -Be $script:receipt.gitHead
        (Get-FileHash "$script:layout\wta.exe").Hash | Should -Be $new.hashes.wta
        (Get-FileHash "$script:native\wta.exe").Hash | Should -Be $new.hashes.wta
        (Get-FileHash "$script:layout\native.dll").Hash | Should -Be $script:receipt.hashes.appx.'native.dll'
        (Get-Content $script:reference -Raw | ConvertFrom-Json).hashes.wta | Should -Be $script:receipt.hashes.wta
        $package = [pscustomobject]@{ PackageFullName = 'offline-dev'; InstallLocation = $script:layout }
        { & "$script:kit\Verify-DeploymentFreshness.ps1" -RepoRoot $script:repo -ReceiptPath $result.receiptPath -InstalledPackage $package } |
            Should -Not -Throw
    }

    It 'refuses dirty sources before invoking Cargo' {
        'dirty' | Add-Content "$script:repo\src\native.txt"
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*clean*'
        Should -Invoke -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo -Times 0
    }

    It 'refuses committed native changes and a narrowed source receipt' {
        'changed' | Add-Content "$script:repo\src\native.txt"
        & git -C $script:repo add .
        & git -C $script:repo commit --quiet -m native-change
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*Native source*'
        $script:receipt.sourcePaths = @('tools/wta')
        $script:receipt | ConvertTo-Json -Depth 8 | Set-Content $script:reference -Encoding utf8
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*scope*'
        Should -Invoke -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo -Times 0
    }

    It 'refuses an active selected package without closing any process' {
        Mock -ModuleName LocalTdd.WtaRefresh Get-Process { @{ Id = 123; Path = "$script:layout\WindowsTerminal.exe" } }
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*in use*'
        Should -Invoke -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo -Times 0
    }

    It 'refuses a changed native binary or package recipe' {
        'tampered' | Set-Content "$script:layout\native.dll"
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*hash*'
        Copy-Item "$script:native\native.dll" "$script:layout\native.dll" -Force
        (Get-Content $script:recipe -Raw).Replace('native.dll', 'other.dll') | Set-Content $script:recipe
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*recipe*'
        Should -Invoke -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo -Times 0
    }

    It 'rejects a native receipt whose fingerprint includes uncommitted changes' {
        $script:receipt.sourceFingerprint = '0' * 64
        $script:receipt | ConvertTo-Json -Depth 8 | Set-Content $script:reference -Encoding utf8
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*clean committed*'
        Should -Invoke -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo -Times 0
    }

    It 'does not rewrite user configuration if another writer changes it' {
        $script:settings = Join-Path $script:fixture 'settings.json'
        'original' | Set-Content $script:settings
        Mock -ModuleName LocalTdd.WtaRefresh Get-LocalTddConfigFiles { $script:settings }
        Mock -ModuleName LocalTdd.WtaRefresh Invoke-LocalTddCargo {
            param($RepoRoot)
            $path = Join-Path $RepoRoot 'tools\wta\target\x86_64-pc-windows-msvc\debug\wta.exe'
            New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
            'new WTA' | Set-Content $path
            'user change' | Set-Content $script:settings
        }
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*Configuration changed*'
        (Get-Content $script:settings -Raw).Trim() | Should -Be 'user change'
        (Get-FileHash "$script:layout\wta.exe").Hash | Should -Be $script:receipt.hashes.wta
    }

    It 'rolls back every WTA destination after a partial copy failure' {
        $script:copyFailed = $false
        Mock -ModuleName LocalTdd.WtaRefresh Copy-Item {
            param($LiteralPath, $Destination, $Force)
            if ($Destination -eq "$script:layout\wta.exe" -and -not $script:copyFailed) {
                $script:copyFailed = $true
                throw 'injected copy failure'
            }
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        }
        { Invoke-LocalTddWtaRefresh @script:refreshArgs } | Should -Throw '*copy failure*'
        foreach ($path in @("$script:native\wta.exe", "$script:layout\wta.exe", $script:receipt.paths.stagedWta)) {
            (Get-FileHash $path).Hash | Should -Be $script:receipt.hashes.wta
        }
        Test-Path (Join-Path $script:refreshArgs.OutDir 'build-receipt.json') | Should -BeFalse
        (Get-Content (Join-Path $script:refreshArgs.OutDir 'refresh-state.json') -Raw | ConvertFrom-Json).rollback | Should -Be 'passed'
    }
}
