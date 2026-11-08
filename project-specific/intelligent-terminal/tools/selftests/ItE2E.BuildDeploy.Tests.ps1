#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:fingerprintScript = (Resolve-Path (Join-Path $PSScriptRoot '..\Get-LocalTddSourceFingerprint.ps1')).Path
    $script:pipelineScript = (Resolve-Path (Join-Path $PSScriptRoot '..\Invoke-LocalTddPipeline.ps1')).Path
    $script:pipelineStatusScript = (Resolve-Path (Join-Path $PSScriptRoot '..\Get-LocalTddPipelineStatus.ps1')).Path
    $script:reportScript = (Resolve-Path (Join-Path $PSScriptRoot '..\Invoke-LocalTddReport.ps1')).Path
    $script:provenanceScript = (Resolve-Path (Join-Path $PSScriptRoot '..\New-LocalTddValidationProvenance.ps1')).Path
    $script:recipeSourcesScript = Join-Path $PSScriptRoot '..\Get-AppxRecipePackageSources.ps1'
    $script:referenceIsolationScript = (Resolve-Path (Join-Path $PSScriptRoot '..\Test-DevPublishReferenceIsolation.ps1')).Path
    $script:publicationAuditScript = Join-Path $PSScriptRoot '..\Test-LocalTddPublication.ps1'
}

Describe 'Build recipe source parsing' -Tag 'Unit' {
    It 'decodes URL-encoded Windows package source paths' {
        $recipe = Join-Path $TestDrive 'encoded.build.appxrecipe'
        @'
<Project>
  <ItemGroup>
    <AppxPackagedFile Include="C:\Program Files %28x86%29\Windows Kits\ucrtbase.dll">
      <PackagePath>ucrtbased.dll</PackagePath>
    </AppxPackagedFile>
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath $recipe -Encoding utf8

        $sources = & $script:recipeSourcesScript -Path $recipe
        $sources['ucrtbased.dll'] |
            Should -Be 'C:\Program Files (x86)\Windows Kits\ucrtbase.dll'
    }
}

Describe 'Read-only Dev package comparison' -Tag 'Unit' {
    BeforeAll {
        $script:comparisonScript = Join-Path $PSScriptRoot '..\Compare-AppxRecipeToDevLayout.ps1'

        function New-ComparisonFixture {
            param([switch]$OmitDll, [switch]$WrongDll, [switch]$TraversalPath,
                  [switch]$MatchingPackage)

            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $sources = Join-Path $root 'source'
            $layout = Join-Path $root 'registered\AppX'
            New-Item -ItemType Directory -Path $sources, $layout,
                (Join-Path $sources 'ProfileIcons'), (Join-Path $layout 'ProfileIcons') -Force | Out-Null

            $sourceDll = Join-Path $sources 'TerminalApp.dll'
            $installedDll = Join-Path $layout 'TerminalApp.dll'
            $sourceIcon = Join-Path $sources 'ProfileIcons\icon.scale-100.png'
            $installedIcon = Join-Path $layout 'ProfileIcons\icon.scale-100.png'
            'new-dll' | Set-Content -LiteralPath $sourceDll -NoNewline
            $(if ($MatchingPackage) { 'new-dll' } else { 'old-dll' }) |
                Set-Content -LiteralPath $installedDll -NoNewline
            'unchanged-icon' | Set-Content -LiteralPath $sourceIcon -NoNewline
            Copy-Item -LiteralPath $sourceIcon -Destination $installedIcon

            $msixManifest = '<Package><Identity Name="IntelligentTerminal" Publisher="CN=Test" Version="0.8.0.2"/></Package>'
            $registeredManifest = if ($MatchingPackage) {
                $msixManifest
            } else {
                '<Package><Identity Name="IntelligentTerminal" Publisher="CN=Test" Version="0.8.0.3"/></Package>'
            }
            $sourceManifest = Join-Path $sources 'AppxManifest.xml'
            $installedManifest = Join-Path $layout 'AppxManifest.xml'
            $msixManifest | Set-Content -LiteralPath $sourceManifest -NoNewline
            $registeredManifest | Set-Content -LiteralPath $installedManifest -NoNewline

            $dllPackagePath = if ($TraversalPath) { '..\TerminalApp.dll' } else { 'TerminalApp.dll' }
            $recipe = Join-Path $root 'CascadiaPackage.build.appxrecipe'
            @"
<Project>
  <ItemGroup>
    <AppXManifest Include="$sourceManifest"><PackagePath>AppxManifest.xml</PackagePath></AppXManifest>
    <AppxPackagedFile Include="$sourceDll"><PackagePath>$dllPackagePath</PackagePath></AppxPackagedFile>
    <AppxPackagedFile Include="$sourceIcon"><PackagePath>ProfileIcons\icon.scale-100.png</PackagePath></AppxPackagedFile>
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $recipe

            $msix = Join-Path $root 'CascadiaPackage.msix'
            Add-Type -AssemblyName System.IO.Compression
            $zip = [IO.Compression.ZipFile]::Open($msix, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($item in @(
                    @{ Path = 'AppxManifest.xml'; Content = $msixManifest },
                    @{ Path = 'TerminalApp.dll'; Content = $(if ($WrongDll) { 'wrong-dll' } else { 'new-dll' }) }
                )) {
                    if ($item.Path -eq 'TerminalApp.dll' -and $OmitDll) { continue }
                    $entry = $zip.CreateEntry($item.Path)
                    $stream = $entry.Open()
                    try {
                        $bytes = [Text.Encoding]::UTF8.GetBytes($item.Content)
                        $stream.Write($bytes, 0, $bytes.Length)
                    }
                    finally { $stream.Dispose() }
                }
            }
            finally { $zip.Dispose() }

            [pscustomobject]@{
                Recipe = $recipe
                Msix = $msix
                InstalledDll = $installedDll
                Package = [pscustomobject]@{
                    Name = 'IntelligentTerminal'
                    PackageFamilyName = 'IntelligentTerminal_rd9vj3e6a2mbr'
                    PackageFullName = 'IntelligentTerminal_0.8.0.3_x64__rd9vj3e6a2mbr'
                    InstallLocation = $layout
                }
            }
        }
    }

    It 'compares cross-worktree payloads without writing and exposes manifest version drift' {
        $fixture = New-ComparisonFixture
        $priorHash = (Get-FileHash -LiteralPath $fixture.InstalledDll -Algorithm SHA256).Hash
        $result = & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix `
            -InstalledPackage $fixture.Package

        $result.EntryCount | Should -Be 2
        $result.MsixEntryCount | Should -Be 1
        $result.NeedsUpdateCount | Should -Be 1
        $result.OmittedScaleAssets | Should -Be @('ProfileIcons\icon.scale-100.png')
        $result.RegisteredManifestMatchesMsix | Should -BeFalse
        $result.RecipeAndManifestMatch | Should -BeFalse
        $result.RegisteredVersion | Should -Be '0.8.0.3'
        $result.MsixVersion | Should -Be '0.8.0.2'
        (Get-FileHash -LiteralPath $fixture.InstalledDll -Algorithm SHA256).Hash | Should -Be $priorHash
    }

    It 'reports a match only when every recipe payload and the manifest match' {
        $fixture = New-ComparisonFixture -MatchingPackage
        $result = & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix `
            -InstalledPackage $fixture.Package

        $result.RecipeAndManifestMatch | Should -BeTrue
        $result.NeedsUpdateCount | Should -Be 0
        $result.RegisteredManifestMatchesMsix | Should -BeTrue
    }

    It 'resolves a single installed Dev package without scalarizing the result' {
        $fixture = New-ComparisonFixture
        Mock Get-AppxPackage { $fixture.Package }

        $result = & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix

        $result.PackageFullName | Should -Be $fixture.Package.PackageFullName
        $result.EntryCount | Should -Be 2
    }

    It 'rejects a non-icon recipe payload omitted from the MSIX' {
        $fixture = New-ComparisonFixture -OmitDll
        { & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix `
                -InstalledPackage $fixture.Package } | Should -Throw '*absent from MSIX: TerminalApp.dll*'
    }

    It 'rejects an MSIX payload with the wrong content' {
        $fixture = New-ComparisonFixture -WrongDll
        { & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix `
                -InstalledPackage $fixture.Package } | Should -Throw '*differs from recipe source: TerminalApp.dll*'
    }

    It 'rejects traversal paths instead of comparing files outside the registered layout' {
        $fixture = New-ComparisonFixture -TraversalPath
        { & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix `
                -InstalledPackage $fixture.Package } | Should -Throw '*Unsafe package path*'
    }

    It 'rejects a package from another family' {
        $fixture = New-ComparisonFixture
        $fixture.Package.PackageFamilyName = 'Microsoft.IntelligentTerminal_8wekyb3d8bbwe'
        { & $script:comparisonScript -RecipePath $fixture.Recipe -MsixPath $fixture.Msix `
                -InstalledPackage $fixture.Package } | Should -Throw '*Expected exactly one installed package*'
    }
}

Describe 'Dev and publish reference isolation' -Tag 'Unit' {
    BeforeEach {
        $script:referenceRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:referenceRepo -Force | Out-Null
        & git -C $script:referenceRepo init --quiet
        & git -C $script:referenceRepo config user.name 'Local TDD Test'
        & git -C $script:referenceRepo config user.email 'local-tdd@example.invalid'
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') -Value 'baseline' -Encoding utf8
        & git -C $script:referenceRepo add notes.md
        & git -C $script:referenceRepo commit --quiet -m baseline
        $script:referenceBase = (& git -C $script:referenceRepo rev-parse HEAD).Trim()
        $script:publishNumber = [string](Get-Random -Minimum 700000 -Maximum 900000)
        $script:publishBranch = 'user/example/publish'
    }

    It 'passes safe dev commits and plain local branch labels' {
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') `
            -Value "local branch: $($script:publishBranch)" -Encoding utf8
        & git -C $script:referenceRepo add notes.md
        & git -C $script:referenceRepo commit --quiet -m 'document local workflow'

        $result = & $script:referenceIsolationScript `
            -RepoRoot $script:referenceRepo `
            -BaseRef $script:referenceBase `
            -PublishPullRequestNumber $script:publishNumber `
            -PublishBranch $script:publishBranch

        $result.Passed | Should -BeTrue
        $result.CommitCount | Should -Be 1
    }

    It 'allows blank patch lines and empty text files' {
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') `
            -Value "safe workflow`n`nlocal evidence" -Encoding utf8
        & git -C $script:referenceRepo add notes.md
        & git -C $script:referenceRepo commit --quiet -m 'add spaced workflow text'
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'empty.txt') `
            -Value '' -NoNewline -Encoding utf8

        $result = & $script:referenceIsolationScript `
            -RepoRoot $script:referenceRepo -BaseRef $script:referenceBase `
            -PublishPullRequestNumber $script:publishNumber -PublishBranch $script:publishBranch

        $result.Passed | Should -BeTrue
    }

    It 'rejects a publish pull-request shorthand in a dev commit message' {
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') -Value 'changed' -Encoding utf8
        & git -C $script:referenceRepo add notes.md
        & git -C $script:referenceRepo commit --quiet `
            -m ("accidental public reference #" + $script:publishNumber)

        {
            & $script:referenceIsolationScript `
                -RepoRoot $script:referenceRepo `
                -BaseRef $script:referenceBase `
                -PublishPullRequestNumber $script:publishNumber `
                -PublishBranch $script:publishBranch
        } | Should -Throw '*reference isolation failed*'
    }

    It 'rejects a fully qualified repository shorthand' {
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') `
            -Value ("example/project#" + $script:publishNumber) -Encoding utf8

        {
            & $script:referenceIsolationScript `
                -RepoRoot $script:referenceRepo `
                -BaseRef $script:referenceBase `
                -PublishPullRequestNumber $script:publishNumber `
                -PublishBranch $script:publishBranch
        } | Should -Throw '*reference isolation failed*'
    }

    It 'rejects publish URLs and review-thread identifiers in changed files' {
        $discussion = ('discussion' + '_r' + $script:publishNumber)
        @(
            "https://github.com/example/project/pull/$($script:publishNumber)"
            "https://github.com/example/project/tree/$($script:publishBranch)"
            $discussion
        ) | Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') -Encoding utf8

        {
            & $script:referenceIsolationScript `
                -RepoRoot $script:referenceRepo `
                -BaseRef $script:referenceBase `
                -PublishPullRequestNumber $script:publishNumber `
                -PublishBranch $script:publishBranch
        } | Should -Throw '*reference isolation failed*'
    }

    It 'allows unrelated issue shorthand' {
        $unrelated = ([int]$script:publishNumber) - 1
        Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') `
            -Value ("unrelated issue #" + $unrelated) -Encoding utf8

        {
            & $script:referenceIsolationScript `
                -RepoRoot $script:referenceRepo `
                -BaseRef $script:referenceBase `
                -PublishPullRequestNumber $script:publishNumber `
                -PublishBranch $script:publishBranch
        } | Should -Not -Throw
    }

    Context 'Public content preflight' {
        BeforeAll {
            function Save-PublicationCommit([string]$Text, [string]$Message = 'Update public documentation') {
                Set-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') -Value $Text -Encoding utf8
                & git -C $script:referenceRepo add notes.md
                if ($LASTEXITCODE -ne 0) { throw 'Fixture staging failed.' }
                & git -C $script:referenceRepo commit --quiet -m $Message
                if ($LASTEXITCODE -ne 0) { throw 'Fixture commit failed.' }
            }
        }

        It 'accepts public test terminology and binds the exact prose bytes' {
            Save-PublicationCommit "A TDD regression test.`n`nScreenshots are optional for this test."
            $draft = Join-Path $TestDrive 'public-draft.txt'
            Set-Content -LiteralPath $draft -Value '' -NoNewline -Encoding utf8

            $result = & $script:publicationAuditScript -RepoRoot $script:referenceRepo `
                -BaseRef $script:referenceBase -TextPath $draft

            $result.Passed | Should -BeTrue
            $result.CommitCount | Should -Be 1
            $result.HeadCommit | Should -Be ((& git -C $script:referenceRepo rev-parse HEAD).Trim())
            $result.TextFiles.Count | Should -Be 1
            $result.TextFiles[0].sha256 | Should -Be (Get-FileHash -LiteralPath $draft).Hash
            (& git -C $script:referenceRepo status --porcelain) | Should -BeNullOrEmpty
        }

        It 'rejects a private file added and removed within the candidate history' {
            $privateDirectory = Join-Path $script:referenceRepo 'dev-only'
            New-Item -ItemType Directory -Path $privateDirectory | Out-Null
            Set-Content -LiteralPath (Join-Path $privateDirectory 'helper.ps1') -Value 'Write-Output 1'
            & git -C $script:referenceRepo add dev-only
            & git -C $script:referenceRepo commit --quiet -m 'Add helper'
            & git -C $script:referenceRepo rm --quiet -- 'dev-only\helper.ps1'
            & git -C $script:referenceRepo commit --quiet -m 'Remove helper'

            Test-Path -LiteralPath (Join-Path $privateDirectory 'helper.ps1') | Should -BeFalse
            {
                & $script:publicationAuditScript -RepoRoot $script:referenceRepo -BaseRef $script:referenceBase
            } | Should -Throw '*Public content audit failed*'
        }

        It 'rejects private imports and comments in otherwise public paths: <Text>' -ForEach @(
            @{ Text = 'Import-Module "..\local-tdd-kit\ItE2E\ItE2E.psd1"' }
            @{ Text = '// Follow dev-only\workflow\TDD-WORKFLOW.md before editing.' }
        ) {
            Save-PublicationCommit $Text

            {
                & $script:publicationAuditScript -RepoRoot $script:referenceRepo -BaseRef $script:referenceBase
            } | Should -Throw '*Public content audit failed*'
        }

        It 'rejects private implementation details in a commit message' {
            Save-PublicationCommit 'Public behavior only.' 'Validated by LocalTdd.Evidence'

            {
                & $script:publicationAuditScript -RepoRoot $script:referenceRepo -BaseRef $script:referenceBase
            } | Should -Throw '*Public content audit failed*'
        }

        It 'audits proposed public text even without a new commit' {
            $draft = Join-Path $TestDrive 'private-draft.txt'
            Set-Content -LiteralPath $draft -Value 'Acceptance passed through local-tdd-kit.'

            {
                & $script:publicationAuditScript -RepoRoot $script:referenceRepo `
                    -BaseRef $script:referenceBase -TextPath $draft
            } | Should -Throw '*Public content audit failed*'
        }

        It 'refuses to certify commits while uncommitted content is present' {
            Save-PublicationCommit 'Public behavior only.'
            Add-Content -LiteralPath (Join-Path $script:referenceRepo 'notes.md') -Value 'Uncommitted change.'

            {
                & $script:publicationAuditScript -RepoRoot $script:referenceRepo -BaseRef $script:referenceBase
            } | Should -Throw '*clean worktree*'
        }
    }
}

Describe 'Local TDD source fingerprint' -Tag 'Unit' {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:repo 'src') -Force | Out-Null
        & git -C $script:repo init --quiet
        & git -C $script:repo config user.name 'Local TDD Test'
        & git -C $script:repo config user.email 'local-tdd@example.invalid'
        Set-Content -LiteralPath (Join-Path $script:repo 'src\product.txt') -Value 'baseline' -Encoding utf8
        & git -C $script:repo add src/product.txt
        & git -C $script:repo commit --quiet -m baseline
    }

    Describe 'Cross-HEAD product provenance' -Tag 'Unit' {
        BeforeEach {
            $script:provenanceRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $script:provenanceRepo 'src'), (Join-Path $script:provenanceRepo 'doc') -Force | Out-Null
            & git -C $script:provenanceRepo init --quiet
            & git -C $script:provenanceRepo config user.name 'Local TDD Test'
            & git -C $script:provenanceRepo config user.email 'local-tdd@example.invalid'
            Set-Content -LiteralPath (Join-Path $script:provenanceRepo 'src\product.txt') -Value 'product' -Encoding utf8
            & git -C $script:provenanceRepo add src/product.txt
            & git -C $script:provenanceRepo commit --quiet -m product
            $script:productHead = (& git -C $script:provenanceRepo rev-parse HEAD).Trim()
            $script:provenanceReceipt = Join-Path $script:provenanceRepo 'receipt.json'
            @{
                gitHead = $script:productHead
                sourcePaths = @('src')
            } | ConvertTo-Json | Set-Content -LiteralPath $script:provenanceReceipt -Encoding utf8
        }

        It 'allows reuse when later commits do not change product source paths' {
            Set-Content -LiteralPath (Join-Path $script:provenanceRepo 'doc\notes.txt') -Value 'validation only' -Encoding utf8
            & git -C $script:provenanceRepo add doc/notes.txt
            & git -C $script:provenanceRepo commit --quiet -m validation

            $result = & $script:provenanceScript -RepoRoot $script:provenanceRepo -ReceiptPath $script:provenanceReceipt -RequireReusable

            $result.reusable | Should -BeTrue
            $result.productHead | Should -Be $script:productHead
            $result.changedProductPaths | Should -BeNullOrEmpty
        }

        It 'rejects reuse when a later commit changes product source paths' {
            Set-Content -LiteralPath (Join-Path $script:provenanceRepo 'src\product.txt') -Value 'changed' -Encoding utf8
            & git -C $script:provenanceRepo add src/product.txt
            & git -C $script:provenanceRepo commit --quiet -m product-change

            { & $script:provenanceScript -RepoRoot $script:provenanceRepo -ReceiptPath $script:provenanceReceipt -RequireReusable } |
                Should -Throw '*product source paths changed*'
        }

        It 'does not allow callers to narrow the receipt source scope' {
            Set-Content -LiteralPath (Join-Path $script:provenanceRepo 'src\product.txt') -Value 'changed' -Encoding utf8
            & git -C $script:provenanceRepo add src/product.txt
            & git -C $script:provenanceRepo commit --quiet -m product-change

            { & $script:provenanceScript -RepoRoot $script:provenanceRepo -ReceiptPath $script:provenanceReceipt -SourcePaths doc -RequireReusable } |
                Should -Throw '*product source paths changed*'
        }

        It 'treats caller paths as literals instead of exclusion pathspecs' {
            Set-Content -LiteralPath (Join-Path $script:provenanceRepo 'src\product.txt') -Value 'changed' -Encoding utf8
            & git -C $script:provenanceRepo add src/product.txt
            & git -C $script:provenanceRepo commit --quiet -m product-change

            { & $script:provenanceScript -RepoRoot $script:provenanceRepo -ReceiptPath $script:provenanceReceipt -SourcePaths ':(exclude)src' -RequireReusable } |
                Should -Throw '*product source paths changed*'
        }
    }

    It 'is stable for an unchanged source snapshot' {
        $first = & $script:fingerprintScript -RepoRoot $script:repo -SourcePaths src
        $second = & $script:fingerprintScript -RepoRoot $script:repo -SourcePaths src

        $first.Head | Should -Match '^[a-f0-9]{40}$'
        $first.Fingerprint | Should -Match '^[A-F0-9]{64}$'
        $first.Fingerprint | Should -Be $second.Fingerprint
        $first.Dirty | Should -BeFalse
    }

    It 'changes for tracked edits and untracked product inputs' {
        $baseline = & $script:fingerprintScript -RepoRoot $script:repo -SourcePaths src
        Set-Content -LiteralPath (Join-Path $script:repo 'src\product.txt') -Value 'edited' -Encoding utf8
        $edited = & $script:fingerprintScript -RepoRoot $script:repo -SourcePaths src
        Set-Content -LiteralPath (Join-Path $script:repo 'src\new.txt') -Value 'new input' -Encoding utf8
        $untracked = & $script:fingerprintScript -RepoRoot $script:repo -SourcePaths src

        $edited.Fingerprint | Should -Not -Be $baseline.Fingerprint
        $untracked.Fingerprint | Should -Not -Be $edited.Fingerprint
        $edited.Dirty | Should -BeTrue
        $untracked.UntrackedPaths | Should -Contain 'src/new.txt'
    }
}

Describe 'Build-only deployment freshness' -Tag 'Unit' {
    It 'verifies staged artifacts without requiring an installed package' {
        $repo = Join-Path $TestDrive 'build-only-repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo config user.name 'Local TDD Test'
        & git -C $repo config user.email 'local-tdd@example.invalid'
        Set-Content -LiteralPath (Join-Path $repo 'src\product.txt') -Value 'baseline' -Encoding utf8
        & git -C $repo add src/product.txt
        & git -C $repo commit --quiet -m baseline

        $cargo = Join-Path $TestDrive 'cargo\wta.exe'
        $appx = Join-Path $TestDrive 'AppX'
        New-Item -ItemType Directory -Path (Split-Path $cargo -Parent), $appx -Force | Out-Null
        Set-Content -LiteralPath $cargo -Value 'same-binary' -Encoding utf8
        Copy-Item -LiteralPath $cargo -Destination (Join-Path $appx 'wta.exe')
        $fingerprint = & $script:fingerprintScript -RepoRoot $repo -SourcePaths src
        $receipt = Join-Path $TestDrive 'build-only-receipt.json'
        @{
            schemaVersion = 1
            gitHead = $fingerprint.Head
            sourceFingerprint = $fingerprint.Fingerprint
            sourcePaths = @('src')
            packageFamily = 'not-installed-for-build-only'
            installVerified = $false
            paths = @{
                cargoWta = $cargo
                stagedWta = Join-Path $appx 'wta.exe'
                appxLayout = $appx
                installedWta = $null
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt -Encoding utf8

        $verify = (Resolve-Path (Join-Path $PSScriptRoot '..\Verify-DeploymentFreshness.ps1')).Path
        { & $verify -RepoRoot $repo -ReceiptPath $receipt } | Should -Not -Throw
    }

    It 'rejects a stale non-WTA recipe source in an installed AppX layout' {
        $repo = Join-Path $TestDrive 'installed-recipe-repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo config user.name 'Local TDD Test'
        & git -C $repo config user.email 'local-tdd@example.invalid'
        Set-Content -LiteralPath (Join-Path $repo 'src\product.txt') -Value 'baseline' -Encoding utf8
        & git -C $repo add src/product.txt
        & git -C $repo commit --quiet -m baseline

        $appx = Join-Path $TestDrive 'installed-AppX'
        $sources = Join-Path $TestDrive 'recipe-sources'
        New-Item -ItemType Directory -Path $appx, $sources -Force | Out-Null
        $cargo = Join-Path $sources 'wta.exe'
        Set-Content -LiteralPath $cargo -Value 'wta-current' -Encoding utf8
        Copy-Item -LiteralPath $cargo -Destination (Join-Path $appx 'wta.exe')
        foreach ($name in @('WindowsTerminal.exe', 'Microsoft.Terminal.Protocol.winmd', 'resources.pri')) {
            Set-Content -LiteralPath (Join-Path $appx $name) -Value "$name-current" -Encoding utf8
        }
        $sourceWtcli = Join-Path $sources 'wtcli.exe'
        Set-Content -LiteralPath $sourceWtcli -Value 'wtcli-current' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $appx 'wtcli.exe') -Value 'wtcli-stale' -Encoding utf8

        $fingerprint = & $script:fingerprintScript -RepoRoot $repo -SourcePaths src
        $receipt = Join-Path $TestDrive 'installed-recipe-receipt.json'
        @{
            schemaVersion = 1
            gitHead = $fingerprint.Head
            sourceFingerprint = $fingerprint.Fingerprint
            sourcePaths = @('src')
            packageFamily = 'local-tdd-recipe-test'
            installVerified = $true
            paths = @{
                cargoWta = $cargo
                stagedWta = Join-Path $appx 'wta.exe'
                appxLayout = $appx
                installedWta = Join-Path $appx 'wta.exe'
                packageSources = @{ 'wtcli.exe' = $sourceWtcli }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt -Encoding utf8

        $package = [pscustomobject]@{
            PackageFamilyName = 'local-tdd-recipe-test'
            InstallLocation = $appx
        }
        $verify = (Resolve-Path (Join-Path $PSScriptRoot '..\Verify-DeploymentFreshness.ps1')).Path

        { & $verify -RepoRoot $repo -ReceiptPath $receipt -InstalledPackage $package } |
            Should -Throw '*recipe source matches AppX: wtcli.exe*'
    }

    It 'rejects a stale AppX payload even when deployment is skipped' {
        $repo = Join-Path $TestDrive 'build-only-stale-repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo config user.name 'Local TDD Test'
        & git -C $repo config user.email 'local-tdd@example.invalid'
        Set-Content -LiteralPath (Join-Path $repo 'src\product.txt') -Value 'baseline' -Encoding utf8
        & git -C $repo add src/product.txt
        & git -C $repo commit --quiet -m baseline

        $source = Join-Path $TestDrive 'build-only-source\TerminalApp.dll'
        $appx = Join-Path $TestDrive 'build-only-stale-AppX'
        New-Item -ItemType Directory -Path (Split-Path $source -Parent), $appx -Force | Out-Null
        Set-Content -LiteralPath $source -Value 'new-terminal-app' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $appx 'TerminalApp.dll') -Value 'old-terminal-app' -Encoding utf8
        $cargo = Join-Path $TestDrive 'build-only-cargo\wta.exe'
        New-Item -ItemType Directory -Path (Split-Path $cargo -Parent) -Force | Out-Null
        Set-Content -LiteralPath $cargo -Value 'same-wta' -Encoding utf8
        Copy-Item -LiteralPath $cargo -Destination (Join-Path $appx 'wta.exe')

        $fingerprint = & $script:fingerprintScript -RepoRoot $repo -SourcePaths src
        $receipt = Join-Path $TestDrive 'build-only-stale-receipt.json'
        @{
            schemaVersion = 2
            gitHead = $fingerprint.Head
            sourceFingerprint = $fingerprint.Fingerprint
            sourcePaths = @('src')
            packageFamily = 'not-installed-for-build-only'
            installVerified = $false
            hashes = @{
                packageSources = @{ 'TerminalApp.dll' = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash }
                appx = @{ 'TerminalApp.dll' = (Get-FileHash -LiteralPath (Join-Path $appx 'TerminalApp.dll') -Algorithm SHA256).Hash }
            }
            paths = @{
                cargoWta = $cargo
                stagedWta = Join-Path $appx 'wta.exe'
                appxLayout = $appx
                installedWta = $null
                packageSources = @{ 'TerminalApp.dll' = $source }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receipt -Encoding utf8

        $verify = (Resolve-Path (Join-Path $PSScriptRoot '..\Verify-DeploymentFreshness.ps1')).Path
        { & $verify -RepoRoot $repo -ReceiptPath $receipt } |
            Should -Throw '*recipe source matches AppX: TerminalApp.dll*'
    }

    It 'invalidates a receipt when the standalone framework changes' {
        $repo = Join-Path $TestDrive 'framework-fingerprint-repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src'), (Join-Path $repo 'local-tdd-kit') -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo config user.name 'Local TDD Test'
        & git -C $repo config user.email 'local-tdd@example.invalid'
        Set-Content -LiteralPath (Join-Path $repo 'src\product.txt') -Value 'product' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $repo 'local-tdd-kit\framework.ps1') -Value 'framework-v1' -Encoding utf8
        & git -C $repo add .
        & git -C $repo commit --quiet -m baseline

        $cargo = Join-Path $TestDrive 'framework-cargo\wta.exe'
        $appx = Join-Path $TestDrive 'framework-AppX'
        New-Item -ItemType Directory -Path (Split-Path $cargo -Parent), $appx -Force | Out-Null
        Set-Content -LiteralPath $cargo -Value 'same-wta' -Encoding utf8
        Copy-Item -LiteralPath $cargo -Destination (Join-Path $appx 'wta.exe')
        $productFingerprint = & $script:fingerprintScript -RepoRoot $repo -SourcePaths src
        $frameworkFingerprint = & $script:fingerprintScript -RepoRoot $repo -SourcePaths local-tdd-kit
        $receipt = Join-Path $TestDrive 'framework-receipt.json'
        @{
            schemaVersion = 2
            gitHead = $productFingerprint.Head
            sourceFingerprint = $productFingerprint.Fingerprint
            sourcePaths = @('src')
            frameworkFingerprint = $frameworkFingerprint.Fingerprint
            frameworkSourcePaths = @('local-tdd-kit')
            packageFamily = 'not-installed-for-build-only'
            installVerified = $false
            paths = @{
                cargoWta = $cargo
                stagedWta = Join-Path $appx 'wta.exe'
                appxLayout = $appx
                installedWta = $null
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receipt -Encoding utf8

        $verify = (Resolve-Path (Join-Path $PSScriptRoot '..\Verify-DeploymentFreshness.ps1')).Path
        { & $verify -RepoRoot $repo -ReceiptPath $receipt } | Should -Not -Throw
        Set-Content -LiteralPath (Join-Path $repo 'local-tdd-kit\framework.ps1') -Value 'framework-v2' -Encoding utf8
        { & $verify -RepoRoot $repo -ReceiptPath $receipt } | Should -Throw '*framework fingerprint*'
    }
}

Describe 'Local report run validation' -Tag 'Unit' {
    It 'returns nonzero when every selected test is skipped' {
        $skipped = Join-Path $TestDrive 'skipped.Tests.ps1'
        "Describe 'skipped' -Tag Unit { It 'skip' { Set-ItResult -Skipped -Because 'external prerequisite' } }" |
            Set-Content -LiteralPath $skipped -Encoding utf8
        & pwsh -NoProfile -File $script:reportScript -Path $skipped -Tag Unit -OutDir (Join-Path $TestDrive 'skip-report') *> $null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'returns nonzero when a mixed run contains a skipped test' {
        $mixed = Join-Path $TestDrive 'mixed.Tests.ps1'
        @(
            "Describe 'mixed' -Tag Unit {"
            "    It 'pass' { `$true | Should -BeTrue }"
            "    It 'skip' { Set-ItResult -Skipped -Because 'external prerequisite' }"
            "}"
        ) | Set-Content -LiteralPath $mixed -Encoding utf8
        & pwsh -NoProfile -File $script:reportScript -Path $mixed -Tag Unit -OutDir (Join-Path $TestDrive 'mixed-report') *> $null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'reports a BeforeAll failure as a setup failure' {
        $broken = Join-Path $TestDrive 'broken-setup.Tests.ps1'
        @"
Describe 'broken setup' -Tag Unit {
    BeforeAll { throw 'expected setup failure' }
    It 'never reaches behavior' { `$true | Should -BeTrue }
}
"@ | Set-Content -LiteralPath $broken -Encoding utf8
        $out = Join-Path $TestDrive 'broken-report'
        & pwsh -NoProfile -File $script:reportScript -Path $broken -Tag Unit -OutDir $out *> $null

        $LASTEXITCODE | Should -Not -Be 0
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) |
            Should -Match 'Setup / cleanup failures|setup/cleanup failure'
        $summary = Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        $summary.status | Should -Be 'failed'
        $summary.setupCleanupFailures | Should -BeGreaterThan 0
        $summary.exitCode | Should -Be 1
    }

    It 'does not turn an all-skipped run green when skips are explicitly allowed' {
        $fixture = Join-Path $TestDrive 'allowed-skips.Tests.ps1'
        "Describe 'allowed skips' -Tag Unit { It 'skip' { Set-ItResult -Skipped -Because 'external prerequisite' } }" |
            Set-Content -LiteralPath $fixture -Encoding utf8
        $out = Join-Path $TestDrive 'allowed-skips-report'
        & pwsh -NoProfile -File $script:reportScript -Path $fixture -Tag Unit -AllowSkipped -OutDir $out *> $null

        $LASTEXITCODE | Should -Not -Be 0
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) |
            Should -Match 'No tests were executed'
        $summary = Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        $summary.status | Should -Be 'failed'
        $summary.selected | Should -Be 1
        $summary.executed | Should -Be 0
        $summary.skipped | Should -Be 1
        $summary.exitCode | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $out 'report.html') -Raw) |
            Should -Match 'class="banner bad".*NO TESTS EXECUTED'
    }

    It 'separates discovered selected executed and filtered-out counts' {
        $fixture = Join-Path $TestDrive 'filtered-counts.Tests.ps1'
        @(
            "Describe 'filtered counts' {"
            "    It 'selected' -Tag Selected { `$true | Should -BeTrue }"
            "    It 'filtered out' -Tag Other { throw 'must not execute' }"
            "}"
        ) | Set-Content -LiteralPath $fixture -Encoding utf8
        $out = Join-Path $TestDrive 'filtered-counts-report'
        & pwsh -NoProfile -File $script:reportScript -Path $fixture -Tag Selected -OutDir $out *> $null

        $LASTEXITCODE | Should -Be 0
        $summary = Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        $summary.status | Should -Be 'passed'
        $summary.discovered | Should -Be 2
        $summary.selected | Should -Be 1
        $summary.executed | Should -Be 1
        $summary.filteredOut | Should -Be 1
        $summary.passed | Should -Be 1
        $summary.skipped | Should -Be 0
        $summary.exitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) |
            Should -Match 'Discovered: 2\s+Selected: 1\s+Executed: 1\s+Filtered out: 1'
        (Get-Content -LiteralPath (Join-Path $out 'report.html') -Raw) |
            Should -Match '<div class="n">1</div><div class="l">Filtered out</div>'
    }

    It 'labels an allowed mixed-skip run without claiming every test passed' {
        $fixture = Join-Path $TestDrive 'allowed-mixed.Tests.ps1'
        @(
            "Describe 'allowed mixed' -Tag Unit {"
            "    It 'pass' { `$true | Should -BeTrue }"
            "    It 'skip' { Set-ItResult -Skipped -Because 'external prerequisite' }"
            "}"
        ) | Set-Content -LiteralPath $fixture -Encoding utf8
        $out = Join-Path $TestDrive 'allowed-mixed-report'
        & pwsh -NoProfile -File $script:reportScript -Path $fixture -Tag Unit -AllowSkipped -OutDir $out *> $null

        $LASTEXITCODE | Should -Be 0
        $summary = Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        $summary.status | Should -Be 'passed_with_skips'
        $summary.selected | Should -Be 2
        $summary.executed | Should -Be 1
        $summary.skipped | Should -Be 1
        $summary.exitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) |
            Should -Not -Match 'All tests passed'
        (Get-Content -LiteralPath (Join-Path $out 'report.html') -Raw) |
            Should -Match 'class="banner partial".*EXECUTED TESTS PASSED; 1 SKIPPED'
    }

    It 'does not report an inconclusive test as a pass' {
        $fixture = Join-Path $TestDrive 'inconclusive.Tests.ps1'
        "Describe 'inconclusive' -Tag Unit { It 'unknown' { Set-ItResult -Inconclusive -Because 'missing evidence' } }" |
            Set-Content -LiteralPath $fixture -Encoding utf8
        $out = Join-Path $TestDrive 'inconclusive-report'
        & pwsh -NoProfile -File $script:reportScript -Path $fixture -Tag Unit -AllowSkipped -OutDir $out *> $null

        $LASTEXITCODE | Should -Not -Be 0
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) |
            Should -Match 'Inconclusive tests'
        $summary = Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        $summary.status | Should -Be 'failed'
        $summary.executed | Should -Be 1
        $summary.inconclusive | Should -Be 1
        $summary.exitCode | Should -Be 1
    }
}

Describe 'Durable local TDD pipeline state' -Tag 'Unit' {
    BeforeEach {
        $script:repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
        $script:head = (& git -C $script:repoRoot rev-parse HEAD).Trim()
        $script:caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:runDir = Join-Path $script:caseDir 'run'
        $script:receipt = Join-Path $script:caseDir 'shared-build-receipt.json'
        $script:buildLog = Join-Path $script:caseDir 'build-invocation.json'
        $script:fakePackageSource = Join-Path $script:caseDir 'recipe-source\fixture.bin'
        $script:fakeAppx = Join-Path $script:caseDir 'AppX'
        New-Item -ItemType Directory -Force -Path $script:caseDir, $script:runDir | Out-Null

        $receiptLiteral = $script:receipt.Replace("'", "''")
        $headLiteral = $script:head.Replace("'", "''")
        $logLiteral = $script:buildLog.Replace("'", "''")
        $repoLiteral = $script:repoRoot.Replace("'", "''")
        $fingerprintLiteral = $script:fingerprintScript.Replace("'", "''")
        $packageSourceLiteral = $script:fakePackageSource.Replace("'", "''")
        $appxLiteral = $script:fakeAppx.Replace("'", "''")
        $script:fakeBuild = Join-Path $script:caseDir 'Fake-Build.ps1'
        @"
[CmdletBinding()]
param(
    [string]`$Configuration,
    [switch]`$SkipWtaTests,
    [switch]`$SkipDeploy,
    [switch]`$ReplaceExistingDevRegistration,
    [switch]`$Launch,
    [string[]]`$SourcePaths
)
@{ Launch = `$Launch.IsPresent; Configuration = `$Configuration } |
    ConvertTo-Json | Set-Content -LiteralPath '$logLiteral' -Encoding utf8
`$effectiveSourcePaths = if (`$SourcePaths) { `$SourcePaths } else { @('src') }
`$fingerprint = & '$fingerprintLiteral' -RepoRoot '$repoLiteral' -SourcePaths `$effectiveSourcePaths
New-Item -ItemType Directory -Force -Path (Split-Path '$packageSourceLiteral' -Parent), '$appxLiteral' | Out-Null
'fixture artifact' | Set-Content -LiteralPath '$packageSourceLiteral' -Encoding utf8
Copy-Item -LiteralPath '$packageSourceLiteral' -Destination (Join-Path '$appxLiteral' 'fixture.bin')
`$artifactHash = (Get-FileHash -LiteralPath '$packageSourceLiteral' -Algorithm SHA256).Hash
@{
    schemaVersion = 1
    createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
    gitHead = '$headLiteral'
    sourceFingerprint = `$fingerprint.Fingerprint
    sourcePaths = `$effectiveSourcePaths
    installVerified = -not `$SkipDeploy
    hashes = @{
        packageSources = @{ 'fixture.bin' = `$artifactHash }
        appx = @{ 'fixture.bin' = `$artifactHash }
    }
    paths = @{
        packageSources = @{ 'fixture.bin' = '$packageSourceLiteral' }
        appxLayout = '$appxLiteral'
    }
} | ConvertTo-Json | Set-Content -LiteralPath '$receiptLiteral' -Encoding utf8
"@ | Set-Content -LiteralPath $script:fakeBuild -Encoding utf8
    }

    It 'runs build and E2E phases without asking build to launch the UI' {
        @{ gitHead = 'stale'; createdUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $script:receipt -Encoding utf8
        $fakeReport = Join-Path $script:caseDir 'Fake-Report.ps1'
        $sharedReceiptLiteral = $script:receipt.Replace("'", "''")
        @"
[CmdletBinding()]
    param([string[]]`$Path, [string[]]`$Tag, [string]`$OutDir)
    New-Item -ItemType Directory -Force -Path `$OutDir | Out-Null
    'fake E2E passed' | Set-Content -LiteralPath (Join-Path `$OutDir 'summary.md') -Encoding utf8
    '<?xml version="1.0"?><test-results total="1" errors="0" failures="0" skipped="0" ignored="0" not-run="0"><test-case name="synthetic" result="Success" success="True" executed="True" /></test-results>' |
        Set-Content -LiteralPath (Join-Path `$OutDir 'results.xml') -Encoding utf8
    'overwritten during E2E' | Set-Content -LiteralPath '$sharedReceiptLiteral' -Encoding utf8
"@ | Set-Content -LiteralPath $fakeReport -Encoding utf8

        $result = & $script:pipelineScript `
            -BuildScript $script:fakeBuild `
            -ReceiptPath $script:receipt `
            -E2ERunner $fakeReport `
            -E2EPath 'synthetic.Tests.ps1' `
            -OutDir $script:runDir

        $result.status | Should -Be 'passed'
        (Get-Content -LiteralPath $script:buildLog -Raw | ConvertFrom-Json).Launch | Should -BeFalse
        $journal = Get-Content -LiteralPath (Join-Path $script:runDir 'pipeline-state.json') -Raw | ConvertFrom-Json
        $journal.status | Should -Be 'passed'
        $journal.phases.name | Should -Be @(
            'preflight',
            'build-deploy-freshness',
            'packaged-e2e',
            'final-source-verification'
        )
        $journal.phases.status | Should -Not -Contain 'running'
        $journal.e2eArtifactRoot | Should -Be (Join-Path $script:runDir 'e2e\artifacts')
        (Test-Path -LiteralPath $journal.e2eReportPath) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:runDir 'prior-build-receipt.json')) | Should -BeTrue
        $journal.receiptPath | Should -Be (Join-Path $script:runDir 'build-receipt.json')
        $immutableReceipt = Get-Content -LiteralPath $journal.receiptPath -Raw | ConvertFrom-Json
        $immutableReceipt.gitHead | Should -Be $script:head
        (Get-Content -LiteralPath $script:receipt -Raw) | Should -Match 'overwritten during E2E'
        (Get-Content -LiteralPath $journal.receiptPath -Raw | ConvertFrom-Json).gitHead |
            Should -Be $script:head
        $status = & $script:pipelineStatusScript -JournalPath (Join-Path $script:runDir 'pipeline-state.json') -RequirePassed
        $status.ObservedStatus | Should -Be 'passed'
        @(Get-ChildItem -LiteralPath $script:runDir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'dispatches WTA-only refresh without invoking full deployment' {
        '{}' | Set-Content -LiteralPath $script:receipt
        $fakeRefresh = Join-Path $script:caseDir 'Fake-Refresh.ps1'
        @"
param(`$RepoRoot, `$NativeReceiptPath, `$OutDir, `$Configuration, [switch]`$SkipWtaTests)
if (-not (Test-Path -LiteralPath `$NativeReceiptPath)) { throw 'Native reference was lost.' }
New-Item -ItemType Directory -Path `$OutDir | Out-Null
`$fingerprint = & '$($script:fingerprintScript)' -RepoRoot `$RepoRoot -SourcePaths src
`$path = Join-Path `$OutDir 'build-receipt.json'
@{ schemaVersion = 1; gitHead = `$fingerprint.Head; sourceFingerprint = `$fingerprint.Fingerprint
   sourcePaths = @('src'); installVerified = `$true; createdUtc = [DateTimeOffset]::UtcNow.ToString('o') } |
   ConvertTo-Json | Set-Content `$path
@{ status = 'passed'; receiptPath = `$path }
"@ | Set-Content -LiteralPath $fakeRefresh
        $result = & $script:pipelineScript -WtaOnly -NativeReceiptPath $script:receipt `
            -WtaRefreshScript $fakeRefresh -BuildScript 'must-not-run.ps1' `
            -ReceiptPath $script:receipt -OutDir $script:runDir
        $result.status | Should -Be 'passed'
        $result.invocation.wtaOnly | Should -BeTrue
        Test-Path $script:buildLog | Should -BeFalse
        Test-Path (Join-Path $script:runDir 'prior-build-receipt.json') | Should -BeTrue
    }

    It 'rejects registration replacement in WTA-only mode' {
        { & $script:pipelineScript -WtaOnly -ReplaceExistingDevRegistration -OutDir $script:runDir } |
            Should -Throw '*cannot replace registration*'
        Test-Path $script:buildLog | Should -BeFalse
    }

    It 'persists a failed phase instead of leaving a stale success' {
        $failingBuild = Join-Path $script:caseDir 'Failing-Build.ps1'
        @'
[CmdletBinding()]
param(
    [string]$Configuration,
    [switch]$SkipWtaTests,
    [switch]$SkipDeploy,
    [switch]$ReplaceExistingDevRegistration,
    [string[]]$SourcePaths
)
throw 'synthetic build failure'
'@ | Set-Content -LiteralPath $failingBuild -Encoding utf8

        { & $script:pipelineScript -BuildScript $failingBuild -ReceiptPath $script:receipt -OutDir $script:runDir } |
            Should -Throw '*synthetic build failure*'

        $journal = Get-Content -LiteralPath (Join-Path $script:runDir 'pipeline-state.json') -Raw | ConvertFrom-Json
        $journal.status | Should -Be 'failed'
        $journal.currentPhase | Should -Be 'build-deploy-freshness'
        $journal.phases[-1].status | Should -Be 'failed'
        $journal.error | Should -Match 'synthetic build failure'
    }

    It 'fails final verification when product source changes during E2E' {
        $sourceDirectory = Join-Path $script:repoRoot 'src'
        $createdSourceDirectory = $false
        $sourceProbe = Join-Path $sourceDirectory "pipeline-source-$([guid]::NewGuid().ToString('N')).txt"
        $sourceProbeLiteral = $sourceProbe.Replace("'", "''")
        $fakeReport = Join-Path $script:caseDir 'Mutating-Report.ps1'
        @"
[CmdletBinding()]
param([string[]]`$Path, [string[]]`$Tag, [string]`$OutDir)
New-Item -ItemType Directory -Force -Path `$OutDir | Out-Null
'changed during E2E' | Set-Content -LiteralPath '$sourceProbeLiteral' -Encoding utf8
'fake E2E passed' | Set-Content -LiteralPath (Join-Path `$OutDir 'summary.md') -Encoding utf8
'<?xml version="1.0"?><test-results total="1" errors="0" failures="0" skipped="0" ignored="0" not-run="0"><test-case name="synthetic" result="Success" success="True" executed="True" /></test-results>' |
    Set-Content -LiteralPath (Join-Path `$OutDir 'results.xml') -Encoding utf8
"@ | Set-Content -LiteralPath $fakeReport -Encoding utf8

        try {
            if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $sourceDirectory -ErrorAction Stop | Out-Null
                $createdSourceDirectory = $true
            }
            'before E2E' | Set-Content -LiteralPath $sourceProbe -Encoding utf8 -ErrorAction Stop
            {
                & $script:pipelineScript `
                    -BuildScript $script:fakeBuild `
                    -ReceiptPath $script:receipt `
                    -E2ERunner $fakeReport `
                    -E2EPath 'synthetic.Tests.ps1' `
                    -OutDir $script:runDir
            } | Should -Throw '*Source fingerprint changed after build*'

            $journal = Get-Content -LiteralPath (Join-Path $script:runDir 'pipeline-state.json') -Raw | ConvertFrom-Json
            $journal.status | Should -Be 'failed'
            $journal.currentPhase | Should -Be 'final-source-verification'
            $journal.phases[-1].status | Should -Be 'failed'
        }
        finally {
            if (Test-Path -LiteralPath $sourceProbe) {
                Remove-Item -LiteralPath $sourceProbe -Force -ErrorAction Stop
            }
            if ($createdSourceDirectory) {
                [IO.Directory]::Delete($sourceDirectory)
            }
        }
    }

    It 'records a child E2E failure and restores the package selector' {
        $fakeReport = Join-Path $script:caseDir 'Failing-Report.ps1'
        @'
[CmdletBinding()]
param([string[]]$Path, [string[]]$Tag, [string]$OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
'fake E2E failed' | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding utf8
exit 7
'@ | Set-Content -LiteralPath $fakeReport -Encoding utf8
        $priorSelector = $env:ITE2E_PACKAGE
        $env:ITE2E_PACKAGE = 'sentinel-before-pipeline'
        try {
            {
                & $script:pipelineScript `
                    -BuildScript $script:fakeBuild `
                    -ReceiptPath $script:receipt `
                    -E2ERunner $fakeReport `
                    -E2EPath 'synthetic.Tests.ps1' `
                    -OutDir $script:runDir
            } | Should -Throw "*E2E runner failed with exit code 7*"

            $env:ITE2E_PACKAGE | Should -Be 'sentinel-before-pipeline'
            $journal = Get-Content -LiteralPath (Join-Path $script:runDir 'pipeline-state.json') -Raw | ConvertFrom-Json
            $journal.status | Should -Be 'failed'
            $journal.currentPhase | Should -Be 'packaged-e2e'
            $journal.phases[-1].exitCode | Should -Be 7
        }
        finally {
            $env:ITE2E_PACKAGE = $priorSelector
        }
    }

    It 'rejects a reused output directory before accepting stale evidence' {
        'stale summary' | Set-Content -LiteralPath (Join-Path $script:runDir 'summary.md') -Encoding utf8

        {
            & $script:pipelineScript `
                -BuildScript $script:fakeBuild `
                -ReceiptPath $script:receipt `
                -OutDir $script:runDir
        } | Should -Throw '*output directory must be new or empty*'

        (Test-Path -LiteralPath (Join-Path $script:runDir 'pipeline-state.json')) | Should -BeFalse
    }

    It 'rejects an E2E runner that reports zero tests' {
        $zeroReport = Join-Path $script:caseDir 'Zero-Report.ps1'
        @'
[CmdletBinding()]
param([string[]]$Path, [string[]]$Tag, [string]$OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
'no tests' | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding utf8
'<?xml version="1.0"?><test-results total="0" errors="0" failures="0" skipped="0" ignored="0" not-run="0" />' |
    Set-Content -LiteralPath (Join-Path $OutDir 'results.xml') -Encoding utf8
'@ | Set-Content -LiteralPath $zeroReport -Encoding utf8

        {
            & $script:pipelineScript `
                -BuildScript $script:fakeBuild `
                -ReceiptPath $script:receipt `
                -E2ERunner $zeroReport `
                -E2EPath 'synthetic.Tests.ps1' `
                -OutDir $script:runDir
        } | Should -Throw '*produced no passing tests*'

        $journal = Get-Content -LiteralPath (Join-Path $script:runDir 'pipeline-state.json') -Raw | ConvertFrom-Json
        $journal.status | Should -Be 'failed'
        $journal.currentPhase | Should -Be 'packaged-e2e'
    }

    It 'rejects an E2E run whose only test is inconclusive' {
        $inconclusiveReport = Join-Path $script:caseDir 'Inconclusive-Report.ps1'
        @'
[CmdletBinding()]
param([string[]]$Path, [string[]]$Tag, [string]$OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
'inconclusive' | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding utf8
'<?xml version="1.0"?><test-results total="1" errors="0" failures="0" skipped="0" ignored="0" not-run="0" inconclusive="1"><test-case name="synthetic" result="Inconclusive" success="False" executed="True" /></test-results>' |
    Set-Content -LiteralPath (Join-Path $OutDir 'results.xml') -Encoding utf8
'@ | Set-Content -LiteralPath $inconclusiveReport -Encoding utf8

        {
            & $script:pipelineScript `
                -BuildScript $script:fakeBuild `
                -ReceiptPath $script:receipt `
                -E2ERunner $inconclusiveReport `
                -E2EPath 'synthetic.Tests.ps1' `
                -OutDir $script:runDir
        } | Should -Throw '*produced no passing tests*'
    }

    It 'rejects mixed passing and inconclusive E2E outcomes' {
        $mixedReport = Join-Path $script:caseDir 'Mixed-Report.ps1'
        @'
[CmdletBinding()]
param([string[]]$Path, [string[]]$Tag, [string]$OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
'mixed' | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding utf8
'<?xml version="1.0"?><test-results total="2"><test-case name="pass" result="Success" success="True" executed="True" /><test-case name="unknown" result="Inconclusive" success="False" executed="True" /></test-results>' |
    Set-Content -LiteralPath (Join-Path $OutDir 'results.xml') -Encoding utf8
'@ | Set-Content -LiteralPath $mixedReport -Encoding utf8

        {
            & $script:pipelineScript `
                -BuildScript $script:fakeBuild `
                -ReceiptPath $script:receipt `
                -E2ERunner $mixedReport `
                -E2EPath 'synthetic.Tests.ps1' `
                -OutDir $script:runDir
        } | Should -Throw '*invalid/inconclusive outcome*'
    }

    It 'makes the report runner fail when filters select zero tests' {
        $reportDir = Join-Path $script:caseDir 'zero-discovery-report'
        & pwsh -NoProfile -File $script:reportScript `
            -Path (Join-Path $PSScriptRoot 'ItE2E.BuildDeploy.Tests.ps1') `
            -Tag 'DefinitelyNoSuchLocalTddTag' `
            -OutDir $reportDir *> $null

        $LASTEXITCODE | Should -Be 1
        Get-Content -LiteralPath (Join-Path $reportDir 'summary.md') -Raw |
            Should -Match 'No tests were selected'
        $summary = Get-Content -LiteralPath (Join-Path $reportDir 'summary.json') -Raw | ConvertFrom-Json
        $summary.discovered | Should -BeGreaterThan 0
        $summary.filteredOut | Should -Be $summary.discovered
        $summary.selected | Should -Be 0
        $summary.executed | Should -Be 0
        $summary.status | Should -Be 'failed'
    }

    It 'injects a run-scoped artifact root into report tests' {
        $reportDir = Join-Path $script:caseDir 'artifact-report'
        $testFile = Join-Path $script:caseDir 'Artifact.Tests.ps1'
        $modulePath = (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1').Replace("'", "''")
        @"
BeforeAll { Import-Module '$modulePath' -Force }
Describe 'artifact context' {
    It 'writes below the report artifact root' {
        `$path = Get-ItArtifactPath -ChildPath 'identity\sample.json' -CreateParent
        '{}' | Set-Content -LiteralPath `$path -Encoding utf8
    }
}
"@ | Set-Content -LiteralPath $testFile -Encoding utf8

        & pwsh -NoProfile -File $script:reportScript -Path $testFile -OutDir $reportDir

        $LASTEXITCODE | Should -Be 0
        $artifact = Get-ChildItem -LiteralPath (Join-Path $reportDir 'artifacts') -Filter sample.json -Recurse |
            Select-Object -First 1
        $artifact | Should -Not -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $reportDir 'summary.md') -Raw |
            Should -Match ([regex]::Escape($artifact.Directory.Parent.FullName))
    }

    It 'classifies an abandoned running journal as interrupted' {
        $journalPath = Join-Path $script:runDir 'pipeline-state.json'
        @{
            schemaVersion = 1
            runId = [guid]::NewGuid().ToString('N')
            status = 'running'
            currentPhase = 'build-deploy-freshness'
            processId = [int]::MaxValue
            processStartUtc = [DateTimeOffset]::UtcNow.ToString('o')
            gitHead = $script:head
            sourceFingerprint = $null
            sourcePaths = @()
            startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            completedUtc = $null
            lastUpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            receiptPath = $script:receipt
            receiptSha256 = $null
            e2eReportPath = $null
            e2eReportSha256 = $null
            e2eResultsPath = $null
            e2eResultsSha256 = $null
            e2eTotals = $null
            error = $null
            invocation = @{ e2ePaths = @() }
            phases = @(@{
                    name = 'build-deploy-freshness'
                    status = 'running'
                    startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    completedUtc = $null
                    exitCode = $null
                    error = $null
                })
        } | ConvertTo-Json | Set-Content -LiteralPath $journalPath -Encoding utf8

        $status = & $script:pipelineStatusScript -JournalPath $journalPath
        $status.DeclaredStatus | Should -Be 'running'
        $status.ObservedStatus | Should -Be 'interrupted'
        $status.ProcessMatches | Should -BeFalse
    }

    It 'invalidates a passed journal when its run-local receipt changes' {
        $result = & $script:pipelineScript `
            -BuildScript $script:fakeBuild `
            -ReceiptPath $script:receipt `
            -OutDir $script:runDir
        $result.status | Should -Be 'passed'
        'tampered receipt' | Set-Content -LiteralPath $result.receiptPath -Encoding utf8

        $status = & $script:pipelineStatusScript -JournalPath (Join-Path $script:runDir 'pipeline-state.json')
        $status.ObservedStatus | Should -Be 'invalid'
        $status.ValidationErrors | Should -Contain 'the run-local receipt hash does not match the journal'
    }

    It 'invalidates a passed journal when a packaged artifact changes' {
        $result = & $script:pipelineScript `
            -BuildScript $script:fakeBuild `
            -ReceiptPath $script:receipt `
            -OutDir $script:runDir
        $result.status | Should -Be 'passed'
        'tampered AppX artifact' | Set-Content -LiteralPath (Join-Path $script:fakeAppx 'fixture.bin') -Encoding utf8

        $status = & $script:pipelineStatusScript -JournalPath (Join-Path $script:runDir 'pipeline-state.json')
        $status.ObservedStatus | Should -Be 'invalid'
        $status.ValidationErrors | Should -Contain 'AppX destination changed after validation: fixture.bin'
        $status.ValidationErrors | Should -Contain 'recipe source no longer matches AppX: fixture.bin'
    }

    It 'invalidates a passed journal when its E2E results change' {
        $fakeReport = Join-Path $script:caseDir 'Passing-Report.ps1'
        @'
[CmdletBinding()]
param([string[]]$Path, [string[]]$Tag, [string]$OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
'passed' | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding utf8
'<?xml version="1.0"?><test-results total="1"><test-case name="synthetic" result="Success" success="True" executed="True" /></test-results>' |
    Set-Content -LiteralPath (Join-Path $OutDir 'results.xml') -Encoding utf8
'@ | Set-Content -LiteralPath $fakeReport -Encoding utf8
        $result = & $script:pipelineScript `
            -BuildScript $script:fakeBuild `
            -ReceiptPath $script:receipt `
            -E2ERunner $fakeReport `
            -E2EPath 'synthetic.Tests.ps1' `
            -OutDir $script:runDir
        $result.status | Should -Be 'passed'
        '<?xml version="1.0"?><test-results total="1"><test-case name="synthetic" result="Failure" success="False" executed="True" /></test-results>' |
            Set-Content -LiteralPath $result.e2eResultsPath -Encoding utf8

        $status = & $script:pipelineStatusScript -JournalPath (Join-Path $script:runDir 'pipeline-state.json')
        $status.ObservedStatus | Should -Be 'invalid'
        $status.ValidationErrors | Should -Contain 'the E2E results hash does not match the journal'
        $status.ValidationErrors | Should -Contain 'the E2E result totals do not match the journal'
    }

    It 'classifies a semantically inconsistent passed journal as invalid' {
        $journalPath = Join-Path $script:runDir 'pipeline-state.json'
        @{
            schemaVersion = 1
            runId = [guid]::NewGuid().ToString('N')
            status = 'passed'
            currentPhase = 'packaged-e2e'
            processId = $PID
            processStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
            gitHead = $script:head
            sourceFingerprint = $null
            sourcePaths = @()
            startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            completedUtc = $null
            lastUpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            receiptPath = $null
            receiptSha256 = $null
            e2eReportPath = $null
            e2eReportSha256 = $null
            e2eResultsPath = $null
            e2eResultsSha256 = $null
            e2eTotals = $null
            error = $null
            invocation = @{ e2ePaths = @('expected.Tests.ps1') }
            phases = @(@{
                    name = 'packaged-e2e'
                    status = 'running'
                    startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    completedUtc = $null
                    exitCode = $null
                    error = $null
                })
        } | ConvertTo-Json | Set-Content -LiteralPath $journalPath -Encoding utf8

        $status = & $script:pipelineStatusScript -JournalPath $journalPath
        $status.ObservedStatus | Should -Be 'invalid'
        $status.ValidationErrors.Count | Should -BeGreaterThan 0
        $status.ValidationErrors | Should -Contain 'passed phase sequence must be: preflight, build-deploy-freshness, packaged-e2e, final-source-verification'
        { & $script:pipelineStatusScript -JournalPath $journalPath -RequirePassed } |
            Should -Throw "*Pipeline is 'invalid', not passed*"
    }
}