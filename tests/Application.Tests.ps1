#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:sourceRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:sourceRoot 'common\Winpd.Setup.psm1') -Force
}

Describe 'Owned layered setup application' -Tag 'Unit' {
    BeforeEach {
        $script:repo = New-TestRepository $TestDrive 'intelligent-terminal'
        'Original project instructions.' | Set-Content -LiteralPath (Join-Path $script:repo 'AGENTS.md')
        $null = Invoke-TestGit $script:repo @('add', '--', 'AGENTS.md')
        $null = Invoke-TestGit $script:repo @('commit', '--quiet', '-m', 'Project instructions')
        $script:remote = Add-TestRemote $script:repo $TestDrive
        $script:toolkit = New-TestToolkit $TestDrive $script:sourceRoot
        $script:common = @{ WorkingDirectory = $script:repo; Keyword = 'setup'; Offline = $true }
    }

    It 'creates same-base worktrees and installs only into dev without altering caller work' {
        $readme = Join-Path $script:repo 'README.md'
        'uncommitted source work' | Add-Content -LiteralPath $readme
        'untracked source data' | Set-Content -LiteralPath (Join-Path $script:repo 'private.txt')
        $sourceHash = (Get-FileHash -LiteralPath $readme).Hash
        $sourceStatus = (Invoke-TestGit $script:repo @('status', '--porcelain')) -join "`n"
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common

        $result = Invoke-WinpdSetup -Plan $plan

        $result.Status | Should -Be 'ready'
        ((Invoke-TestGit $plan.Paths.Dev @('rev-parse', 'HEAD')) -join '') | Should -Be $plan.Base.Commit
        ((Invoke-TestGit $plan.Paths.Publish @('rev-parse', 'HEAD')) -join '') | Should -Be $plan.Base.Commit
        (Invoke-TestGit $plan.Paths.Publish @('status', '--porcelain')).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $plan.Paths.Publish '.winpd') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $plan.Paths.Dev '.winpd\common\tools\fixture.ps1') | Should -BeTrue
        $agents = Get-Content -LiteralPath (Join-Path $plan.Paths.Dev 'AGENTS.md') -Raw
        $agents | Should -Match 'Common fixture instructions'
        $agents | Should -Match 'Project fixture instructions'
        $agents | Should -Match 'User fixture instructions'
        $agents | Should -Match 'Original project instructions'
        $agents | Should -Match '<FEATURE_GOAL>'
        $agents.IndexOf('Common fixture') | Should -BeLessThan $agents.IndexOf('Project fixture')
        $agents.IndexOf('Project fixture') | Should -BeLessThan $agents.IndexOf('User fixture')
        (Get-FileHash -LiteralPath $readme).Hash | Should -Be $sourceHash
        ((Invoke-TestGit $script:repo @('status', '--porcelain')) -join "`n") | Should -Be $sourceStatus
        (Get-Content -LiteralPath $plan.Paths.State -Raw | ConvertFrom-Json).Status | Should -Be 'ready'
    }

    It 'reuses an unchanged setup without appending instructions or creating duplicate worktrees' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $null = Invoke-WinpdSetup -Plan $plan
        $agents = Join-Path $plan.Paths.Dev 'AGENTS.md'
        $hash = (Get-FileHash -LiteralPath $agents).Hash
        $worktrees = (Invoke-TestGit $script:repo @('worktree', 'list', '--porcelain')) -join "`n"

        $second = Invoke-WinpdSetup -Plan (New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common)

        $second.Reused | Should -BeTrue
        (Get-FileHash -LiteralPath $agents).Hash | Should -Be $hash
        ((Invoke-TestGit $script:repo @('worktree', 'list', '--porcelain')) -join "`n") | Should -Be $worktrees
    }

    It 'refuses a collision before creating the other worktree or a state journal' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        New-Item -ItemType Directory -Path $plan.Paths.Dev | Out-Null
        $sentinel = Join-Path $plan.Paths.Dev 'user.txt'
        'user-owned' | Set-Content -LiteralPath $sentinel

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*already exists*'

        Test-Path -LiteralPath $plan.Paths.Publish | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.State | Should -BeFalse
        (Get-Content -LiteralPath $sentinel -Raw).Trim() | Should -Be 'user-owned'
    }

    It 'does not overwrite a template the user has filled after setup' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $null = Invoke-WinpdSetup -Plan $plan
        $agents = Join-Path $plan.Paths.Dev 'AGENTS.md'
        'Human-written feature contract.' | Add-Content -LiteralPath $agents
        $hash = (Get-FileHash -LiteralPath $agents).Hash

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*Managed output changed*'

        (Get-FileHash -LiteralPath $agents).Hash | Should -Be $hash
    }

    It 'resumes a failed project phase without recreating already-owned resources' {
        $blocker = Join-Path $TestDrive 'block-project'
        'transient prerequisite' | Set-Content -LiteralPath $blocker
        $scriptPath = Join-Path $script:toolkit 'project-specific\intelligent-terminal\setup.ps1'
        @'
param([string]$Phase, [Collections.IDictionary]$Context, [Collections.IDictionary]$Parameters)
if ($Phase -eq 'Plan') {
    return @{ Instructions = @('templates/AGENTS.md'); ToolDirectories = @('tools') }
}
if ($Phase -eq 'Apply' -and (Test-Path -LiteralPath $Parameters.Marker)) {
    throw 'Synthetic project prerequisite failure.'
}
@{ Status = 'passed' }
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
        $null = Invoke-TestGit $script:toolkit @('add', '--all')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-m', 'Failing project fixture')
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common -Project @{ Marker = $blocker }

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*Synthetic project prerequisite failure*'
        $state = Get-Content -LiteralPath $plan.Paths.State -Raw | ConvertFrom-Json
        $state.Status | Should -Be 'failed'
        $state.Phase | Should -Be 'apply-project'
        $worktrees = (Invoke-TestGit $script:repo @('worktree', 'list', '--porcelain')) -join "`n"
        Remove-Item -LiteralPath $blocker

        (Invoke-WinpdSetup -Plan $plan).Status | Should -Be 'ready'
        ((Invoke-TestGit $script:repo @('worktree', 'list', '--porcelain')) -join "`n") | Should -Be $worktrees
    }

    It 'does not use a modified toolkit after a plan was pinned' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        'changed after plan' | Add-Content -LiteralPath (Join-Path $script:toolkit 'common\templates\AGENTS.md')

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*toolkit*clean*'
        Test-Path -LiteralPath $plan.Paths.Dev | Should -BeFalse
    }

    It 'preserves an existing task when the toolkit advances to a different clean revision' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $null = Invoke-WinpdSetup -Plan $plan
        $stateHash = (Get-FileHash -LiteralPath $plan.Paths.State).Hash
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '--allow-empty', '-m', 'Advance toolkit fixture')

        { New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common } |
            Should -Throw '*different toolkit revision/location*'

        (Get-FileHash -LiteralPath $plan.Paths.State).Hash | Should -Be $stateHash
        ((Invoke-TestGit $plan.Paths.Dev @('rev-parse', 'HEAD')) -join '') | Should -Be $plan.Base.Commit
    }

    It 'does not back up original instructions before their input path is accepted' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        Mock Get-Item -ModuleName Winpd.Setup {
            param($LiteralPath, [switch]$Force)
            $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
            if ($item.Name -eq 'AGENTS.md') {
                return [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint }
            }
            return $item
        }

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*Reparse points*'

        Test-Path -LiteralPath (Join-Path $plan.Paths.Dev '.winpd\original\AGENTS.md') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $plan.Paths.Dev 'AGENTS.md') -Raw).Trim() |
            Should -Be 'Original project instructions.'
    }

    It 'rechecks output ancestors when a junction is introduced after planning' {
        $parent = Join-Path $TestDrive "late-parent-$([guid]::NewGuid().ToString('N'))"
        $script:common.WorktreeRoot = $parent
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        New-Item -ItemType Junction -Path $parent -Target $script:repo | Out-Null

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*Reparse points*'

        Test-Path -LiteralPath $plan.Paths.Dev | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.State | Should -BeFalse
    }

    It 'does not rewrite an existing task journal when requested inputs differ' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $null = Invoke-WinpdSetup -Plan $plan
        $stateHash = (Get-FileHash -LiteralPath $plan.Paths.State).Hash
        $script:common.BranchPrefix = 'different-prefix'
        $otherPlan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common

        { Invoke-WinpdSetup -Plan $otherPlan } | Should -Throw '*different inputs*'

        (Get-FileHash -LiteralPath $plan.Paths.State).Hash | Should -Be $stateHash
        Test-Path -LiteralPath (Join-Path $plan.Paths.Dev 'AGENTS.md') | Should -BeTrue
    }

    It 'copies only tracked toolkit assets and excludes ignored local data' {
        '*.jsonl' | Set-Content -LiteralPath (Join-Path $script:toolkit '.gitignore')
        $null = Invoke-TestGit $script:toolkit @('add', '--all')
        $null = Invoke-TestGit $script:toolkit @('commit', '--quiet', '-m', 'Ignore fixture runtime data')
        'private fixture data' | Set-Content -LiteralPath (Join-Path $script:toolkit 'common\tools\session.jsonl')
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common

        $null = Invoke-WinpdSetup -Plan $plan

        Test-Path -LiteralPath (Join-Path $plan.Paths.Dev '.winpd\common\tools\fixture.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $plan.Paths.Dev '.winpd\common\tools\session.jsonl') | Should -BeFalse
    }

    It 'does not adopt an existing branch even when its worktree path is absent' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $null = Invoke-TestGit $script:repo @('branch', $plan.Branches.Dev, $plan.Base.Commit)

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*branch already exists*'

        Test-Path -LiteralPath $plan.Paths.Dev | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.Publish | Should -BeFalse
        Test-Path -LiteralPath $plan.Paths.State | Should -BeFalse
    }

    It 'blocks uncertain interrupted creation without deleting a registered worktree' {
        $plan = New-WinpdSetupPlan -ToolkitRoot $script:toolkit -Common $script:common
        $null = Invoke-WinpdSetup -Plan $plan
        $state = Get-Content -LiteralPath $plan.Paths.State -Raw | ConvertFrom-Json -AsHashtable
        $state.Status = 'failed'
        $state.Resources.Dev = 'creating'
        Write-TestJson $plan.Paths.State $state

        { Invoke-WinpdSetup -Plan $plan } | Should -Throw '*needs inspection*'

        Test-Path -LiteralPath (Join-Path $plan.Paths.Dev 'AGENTS.md') | Should -BeTrue
        ((Invoke-TestGit $plan.Paths.Dev @('rev-parse', 'HEAD')) -join '') | Should -Be $plan.Base.Commit
    }
}
