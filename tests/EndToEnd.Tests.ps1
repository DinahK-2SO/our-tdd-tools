#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:sourceRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:sourceRoot 'common\Winpd.Setup.psm1') -Force
    function Invoke-SetupEntry {
        param([string]$Toolkit, [string]$Directory, [string]$Keyword, [string]$Mode = 'Apply', [switch]$Online)
        $runner = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).ps1"
        $output = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
        @'
param($Toolkit, $Directory, $Keyword, $Mode, $OutputPath, [switch]$Online)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
Set-Location -LiteralPath $Directory
$common = @{ Keyword = $Keyword; Offline = -not $Online }
$parameters = @{ Common = $common; User = @{ ProfilePath = '' } }
if ($Mode -eq 'Plan') { $parameters.Plan = $true }
if ($Mode -eq 'WhatIf') { $parameters.WhatIf = $true }
$result = & (Join-Path $Toolkit 'setup.ps1') @parameters
$result | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $OutputPath -Encoding utf8
'@ | Set-Content -LiteralPath $runner -Encoding utf8
        $arguments = @('-NoLogo', '-NoProfile', '-File', $runner, '-Toolkit', $Toolkit,
            '-Directory', $Directory, '-Keyword', $Keyword, '-Mode', $Mode, '-OutputPath', $output)
        if ($Online) { $arguments += '-Online' }
        $messages = @(& (Get-Process -Id $PID).Path @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $diagnostic = ($messages -join ' ') -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
            throw "Setup entrypoint failed: $diagnostic"
        }
        return Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -AsHashtable
    }
}

Describe 'Mechanical setup entrypoint' -Tag 'Unit' {
    It 'plans and applies from a spaced subdirectory, preserving staged and unstaged caller work' {
        $parent = Join-Path $TestDrive 'space and unicode-测试'
        New-Item -ItemType Directory -Path $parent | Out-Null
        $toolkit = New-TestToolkitSnapshot $parent $script:sourceRoot
        $repo = New-TestRepository $parent 'different-project'
        $null = Add-TestRemote $repo $parent
        $subdirectory = Join-Path $repo 'source folder'
        New-Item -ItemType Directory -Path $subdirectory | Out-Null
        'staged user change' | Add-Content -LiteralPath (Join-Path $repo 'README.md')
        $null = Invoke-TestGit $repo @('add', '--', 'README.md')
        'unstaged user change' | Add-Content -LiteralPath (Join-Path $repo 'README.md')
        'private caller file' | Set-Content -LiteralPath (Join-Path $repo 'caller.txt')
        $staged = (Invoke-TestGit $repo @('diff', '--cached', '--binary')) -join "`n"
        $status = (Invoke-TestGit $repo @('status', '--porcelain')) -join "`n"
        $hash = (Get-FileHash -LiteralPath (Join-Path $repo 'README.md')).Hash

        $plan = Invoke-SetupEntry $toolkit $subdirectory 'entry' 'Plan'
        $preview = Invoke-SetupEntry $toolkit $subdirectory 'entry' 'WhatIf'
        $preview.Fingerprint | Should -Be $plan.Fingerprint
        Test-Path -LiteralPath $plan.Paths.Dev | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.State | Should -BeFalse

        $result = Invoke-SetupEntry $toolkit $subdirectory 'entry'
        $result.Status | Should -Be 'ready'
        $result.PinSource | Should -Be 'new-resolution'
        $second = Invoke-SetupEntry $toolkit $subdirectory 'entry'
        $second.Reused | Should -BeTrue
        $second.PinSource | Should -Be 'existing-task'
        ((Invoke-TestGit $repo @('diff', '--cached', '--binary')) -join "`n") | Should -Be $staged
        ((Invoke-TestGit $repo @('status', '--porcelain')) -join "`n") | Should -Be $status
        (Get-FileHash -LiteralPath (Join-Path $repo 'README.md')).Hash | Should -Be $hash
        Test-Path -LiteralPath (Join-Path $result.DevRoot '.winpd\project-specific') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $result.DevRoot 'AGENTS.md') -Raw) | Should -Match '<FEATURE_GOAL>'
        $module = Join-Path $result.DevRoot '.winpd\common\tools\Winpd.Core.psm1'
        Import-Module $module -Force
        Get-Command Write-WinpdEvidenceJson -Module Winpd.Core | Should -Not -BeNullOrEmpty
    }

    It 'uses the latest advertised base once and retains that task pin when main later advances' {
        $toolkit = New-TestToolkitSnapshot $TestDrive $script:sourceRoot
        $null = Add-TestRemote $toolkit $TestDrive
        $producer = New-TestRepository $TestDrive 'upstream-product'
        $remote = Add-TestRemote $producer $TestDrive
        $caller = Join-Path $TestDrive 'intelligent-terminal'
        $null = Invoke-TestGit $TestDrive @('clone', '--quiet', $remote, $caller)
        $original = (Invoke-TestGit $caller @('rev-parse', 'HEAD')) -join ''
        'first new base' | Add-Content -LiteralPath (Join-Path $producer 'README.md')
        $null = Invoke-TestGit $producer @('commit', '--quiet', '-am', 'Advance before setup')
        $null = Invoke-TestGit $producer @('push', '--quiet')
        $base = (Invoke-TestGit $producer @('rev-parse', 'HEAD')) -join ''

        $result = Invoke-SetupEntry $toolkit $caller 'pinned' -Online
        ((Invoke-TestGit $result.DevRoot @('rev-parse', 'HEAD')) -join '') | Should -Be $base
        ((Invoke-TestGit $result.PublishRoot @('rev-parse', 'HEAD')) -join '') | Should -Be $base
        ((Invoke-TestGit $caller @('rev-parse', 'HEAD')) -join '') | Should -Be $original
        'second new base' | Add-Content -LiteralPath (Join-Path $producer 'README.md')
        $null = Invoke-TestGit $producer @('commit', '--quiet', '-am', 'Advance after setup')
        $null = Invoke-TestGit $producer @('push', '--quiet')

        (Invoke-SetupEntry $toolkit $caller 'pinned' -Online).Reused | Should -BeTrue
        ((Invoke-TestGit $result.PublishRoot @('rev-parse', 'HEAD')) -join '') | Should -Be $base
        (Get-Content -LiteralPath $result.StatePath -Raw | ConvertFrom-Json).Base.Commit | Should -Be $base
    }
}
