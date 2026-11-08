#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:sourceRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:sourceRoot 'common\Winpd.Setup.psm1') -Force
}

Describe 'Layered setup planning' -Tag 'Unit' {
    BeforeEach {
        $script:repo = New-TestRepository $TestDrive 'intelligent-terminal'
        $script:remote = Add-TestRemote $script:repo $TestDrive
        $script:toolkit = New-TestToolkit $TestDrive $script:sourceRoot
        $script:common = @{ WorkingDirectory = $script:repo; Keyword = 'scroll'; Offline = $true }
    }

    It 'resolves a caller subdirectory without confusing it with the toolkit root' {
        $subdirectory = Join-Path $script:repo 'nested source'
        New-Item -ItemType Directory -Path $subdirectory | Out-Null
        $script:common.WorkingDirectory = $subdirectory
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common

        $plan.Repository.Root | Should -Be $script:repo
        $plan.Toolkit.Root | Should -Be $script:toolkit
        $plan.Project.Id | Should -Be 'intelligent-terminal'
        $plan.Base.Commit | Should -Be ((Invoke-TestGit $script:repo @('rev-parse', 'HEAD')) -join '')
        $plan.Branches.Dev | Should -Be 'winpd/scroll-dev'
        $plan.Branches.Publish | Should -Be 'winpd/scroll-publish'
        $plan.Paths.Dev | Should -Be (Join-Path (Split-Path $script:repo -Parent) 'intelligent-terminal-scroll-dev')
    }

    It 'keeps project and user parameter namespaces independent' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common `
            -Project @{ Marker = 'project-only' } -User @{ ChatLanguage = 'zh-CN' }

        $plan.Parameters.Project.Marker | Should -Be 'project-only'
        $plan.Parameters.User.ChatLanguage | Should -Be 'zh-CN'
        $plan.Parameters.Common.Contains('Marker') | Should -BeFalse
        $plan.Parameters.User.Contains('Marker') | Should -BeFalse
    }

    It 'rejects unknown keys and truthy strings before producing a plan' {
        $script:common.Keywrod = 'typo'
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Unknown Common parameter*'
        $script:common.Remove('Keywrod')
        $script:common.Offline = 'true'
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Common.Offline*boolean*'
        $script:common.Offline = $true
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common -Project @{ Unknown = 1 } } |
            Should -Throw '*Unknown Project parameter*'
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common -User @{ Unknown = 1 } } |
            Should -Throw '*Unknown User parameter*'
    }

    It 'does not mutate caller files, refs, or create worktrees while planning' {
        $existing = Join-Path $script:repo 'README.md'
        'user work' | Add-Content -LiteralPath $existing
        'untracked user data' | Set-Content -LiteralPath (Join-Path $script:repo 'user.txt')
        $hash = (Get-FileHash -LiteralPath $existing).Hash
        $status = (Invoke-TestGit $script:repo @('status', '--porcelain')) -join "`n"
        $refs = (Invoke-TestGit $script:repo @('show-ref')) -join "`n"

        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common

        (Get-FileHash -LiteralPath $existing).Hash | Should -Be $hash
        ((Invoke-TestGit $script:repo @('status', '--porcelain')) -join "`n") | Should -Be $status
        ((Invoke-TestGit $script:repo @('show-ref')) -join "`n") | Should -Be $refs
        Test-Path -LiteralPath $plan.Paths.Dev | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.Publish | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.State | Should -BeFalse
    }

    It 'produces stable plans from the same inputs and reports offline freshness honestly' {
        $script:common.Remove('Keyword')
        $first = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $second = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common

        $first.Parameters.Common.Keyword | Should -Be 'task'
        $first.Fingerprint | Should -Be $second.Fingerprint
        $first.TaskId | Should -Be $second.TaskId
        $first.Base.Freshness | Should -Be 'offline'
        $first.Toolkit.Freshness | Should -Be 'offline'
    }

    It 'uses the selected remote default branch rather than assuming main' {
        $repo = New-TestRepository $TestDrive 'plain-project' 'trunk'
        $null = Add-TestRemote $repo $TestDrive 'trunk'
        $null = Add-TestRemote $script:toolkit $TestDrive
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit `
            -Common @{ WorkingDirectory = $repo; Keyword = 'work' }

        $plan.Base.Branch | Should -Be 'trunk'
        $plan.Base.Freshness | Should -Be 'remote'
        $plan.Project.Id | Should -Be 'common'
        $plan.Toolkit.Freshness | Should -Be 'remote'
    }

    It 'allows explicit common-only selection and rejects an unknown project ID' {
        $script:common.ProjectId = 'common'
        (New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common).Project.Id |
            Should -Be 'common'
        $script:common.ProjectId = 'not-registered'
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Unknown project*'
    }

    It 'uses a repository project marker ahead of a directory-name hint' {
        Add-TestProjectProfile $script:toolkit 'other-project' @('another-name')
        $null = Invoke-TestGit $script:toolkit @('add', '--all')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-m', 'Additional profile')
        Write-TestJson (Join-Path $script:repo '.winpd-project.json') @{ projectId = 'other-project' }

        (New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common).Project.Id |
            Should -Be 'other-project'
    }

    It 'refuses ambiguous automatic profile matches' {
        Add-TestProjectProfile $script:toolkit 'duplicate' @('intelligent-terminal')
        $null = Invoke-TestGit $script:toolkit @('add', '--all')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-m', 'Ambiguous fixture')

        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Ambiguous project*'
    }

    It 'rejects traversal keywords and a dirty toolkit instead of copying uncertain inputs' {
        $script:common.Keyword = '..\outside'
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Common.Keyword*'
        $script:common.Keyword = 'scroll'
        'dirty toolkit' | Add-Content -LiteralPath (Join-Path $script:toolkit 'README.md')

        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*toolkit*clean*'
    }

    It 'rejects worktree destinations inside the caller or toolkit repositories' {
        foreach ($root in @($script:repo, $script:toolkit)) {
            $script:common.WorktreeRoot = Join-Path $root 'nested-output'
            { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
                Should -Throw '*worktree path*existing repository*'
        }
    }

    It 'pins the remote base rather than the callers stale local branch' {
        $client = Join-Path $TestDrive "client-$([guid]::NewGuid().ToString('N'))"
        $null = Invoke-TestGit $TestDrive @('clone', '--quiet', $script:remote, $client)
        $oldHead = (Invoke-TestGit $client @('rev-parse', 'HEAD')) -join ''
        'upstream change' | Add-Content -LiteralPath (Join-Path $script:repo 'README.md')
        $null = Invoke-TestGit $script:repo @('commit', '--quiet', '-am', 'Advance fixture base')
        $null = Invoke-TestGit $script:repo @('push', '--quiet')
        $newHead = (Invoke-TestGit $script:repo @('rev-parse', 'HEAD')) -join ''
        $null = Add-TestRemote $script:toolkit $TestDrive

        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common @{ WorkingDirectory = $client }

        $plan.Base.Commit | Should -Be $newHead
        $plan.Repository.Head | Should -Be $oldHead
        ((Invoke-TestGit $client @('rev-parse', 'HEAD')) -join '') | Should -Be $oldHead
        ((Invoke-TestGit $client @('rev-parse', 'origin/main')) -join '') | Should -Be $oldHead
    }

    It 'refuses a stale running toolkit instead of silently claiming the latest version' {
        $toolRemote = Add-TestRemote $script:toolkit $TestDrive
        $client = Join-Path $TestDrive "old-toolkit-$([guid]::NewGuid().ToString('N'))"
        $null = Invoke-TestGit $TestDrive @('clone', '--quiet', $toolRemote, $client)
        'new toolkit revision' | Add-Content -LiteralPath (Join-Path $script:toolkit 'README.md')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-am', 'Advance fixture toolkit')
        $null = Invoke-TestGit $script:toolkit @('push', '--quiet')
        $script:common.Offline = $false

        { New-WinpdSetupPlan -ToolkitRoot $client -Common $script:common } |
            Should -Throw '*latest upstream revision*'
    }

    It 'hashes equivalent configuration objects independently of dictionary insertion order' {
        InModuleScope Winpd.Setup {
            $first = [ordered]@{ Z = @([ordered]@{ B = 2; A = 1 }); A = 'value' }
            $second = [ordered]@{ A = 'value'; Z = @([ordered]@{ A = 1; B = 2 }) }
            Get-WinpdHash $first | Should -Be (Get-WinpdHash $second)
        }
    }

    It 'rejects a layer that tries to mutate parameters or escape its source directory' {
        $scriptPath = Join-Path $script:toolkit 'common\setup.ps1'
        @'
param($Phase, $Context, $Parameters)
$Parameters.Keyword = 'changed'
@{ Status = 'passed' }
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
        $null = Invoke-TestGit $script:toolkit @('add', '--all')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-m', 'Mutating layer fixture')
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*read-only context or parameters*'
        @'
param($Phase, $Context, $Parameters)
if ($Phase -eq 'Plan') { return @{ Instructions = @(); ToolDirectories = @('..\outside') } }
@{ Status = 'passed' }
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
        $null = Invoke-TestGit $script:toolkit @('add', '--all')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-m', 'Escaping layer fixture')
        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Invalid managed relative path*'
    }

    It 'does not let a junction redirect worktree output into the caller repository' {
        $redirect = Join-Path $TestDrive "redirect-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Junction -Path $redirect -Target $script:repo | Out-Null
        $script:common.WorktreeRoot = $redirect

        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*Reparse points*'
        Test-Path -LiteralPath (Join-Path $script:repo 'intelligent-terminal-scroll-dev') | Should -BeFalse
    }
}
