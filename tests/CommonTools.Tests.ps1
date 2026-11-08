#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:root 'common\tools\Winpd.Core.psm1') -Force
    Import-Module (Join-Path $script:root 'common\tools\ai\Winpd.Ai.psm1') -Force
    Import-Module (Join-Path $script:root 'common\tools\github\Winpd.Review.psm1') -Force
    Import-Module (Join-Path $script:root 'common\tools\windows\Winpd.Windows.psm1') -Force
}

Describe 'Common publication boundary' -Tag 'Unit' {
    It 'rejects the new dev-only toolbox path in a product candidate' {
        $repo = New-TestRepository $TestDrive 'product-candidate'
        $base = (Invoke-TestGit $repo @('rev-parse', 'HEAD')) -join ''
        $path = Join-Path $repo '.winpd\common\tools'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        'Write-Output 1' | Set-Content -LiteralPath (Join-Path $path 'fixture.ps1')
        $null = Invoke-TestGit $repo @('add', '--all')
        $null = Invoke-TestGit $repo @('commit', '--quiet', '-m', 'Accidental toolbox inclusion')

        { & (Join-Path $script:root 'common\tools\github\Test-WinpdPublication.ps1') `
            -RepoRoot $repo -BaseRef $base } | Should -Throw '*Public content audit failed*'
    }

    It 'accepts ordinary product changes without requiring Terminal-specific files' {
        $repo = New-TestRepository $TestDrive 'generic-candidate'
        $base = (Invoke-TestGit $repo @('rev-parse', 'HEAD')) -join ''
        'Actual product change.' | Add-Content -LiteralPath (Join-Path $repo 'README.md')
        $null = Invoke-TestGit $repo @('commit', '--quiet', '-am', 'Product change')

        (& (Join-Path $script:root 'common\tools\github\Test-WinpdPublication.ps1') `
            -RepoRoot $repo -BaseRef $base).Passed | Should -BeTrue
    }
}

Describe 'Project-independent AI request ownership' -Tag 'Unit' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $script:authorization = Join-Path $caseRoot 'authorization.json'
        $script:budget = Join-Path $caseRoot 'budget.json'
        @{
            schemaVersion = 1; approved = $true; scope = 'unrelated-project-check'
            totalLimit = 2; perHeadLimit = 1; timeoutSeconds = 10
        } | ConvertTo-Json | Set-Content -LiteralPath $script:authorization
    }

    It 'requires explicit authorization and retains charged requests after failure' {
        $attempt = Reserve-WinpdRequest -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('a' * 40) -RunId 'first'
        Set-WinpdRequestOutcome -BudgetPath $script:budget -AttemptId $attempt.id -Outcome failed
        { Reserve-WinpdRequest -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('a' * 40) -RunId 'retry' } |
            Should -Throw '*per-head*budget*'
        $ledger = Get-Content -LiteralPath $script:budget -Raw | ConvertFrom-Json
        $ledger.attempts.Count | Should -Be 1
        $ledger.attempts[0].status | Should -Be 'failed'
    }

    It 'does not invoke a judge or charge a request without the explicit invocation switch' {
        Mock -ModuleName Winpd.Ai Invoke-WinpdProcess { throw 'A real process must not be started.' }
        { Invoke-WinpdCopilotJudge -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('a' * 40) -RunId 'not-authorized' -Prompt 'Synthetic question' } |
            Should -Throw '*AllowInference*'
        Test-Path -LiteralPath $script:budget | Should -BeFalse
        Should -Invoke -ModuleName Winpd.Ai Invoke-WinpdProcess -Times 0
    }

    It 'keeps a false judge verdict false and records a bounded completed request' {
        Mock -ModuleName Winpd.Ai Get-WinpdCopilotExecutable { 'fixture-copilot.exe' }
        Mock -ModuleName Winpd.Ai Invoke-WinpdProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"pass":false,"confidence":0.9,"reason":"counterexample"}'
                StdErr = ''; TimedOut = $false }
        }
        $result = Invoke-WinpdCopilotJudge -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('a' * 40) -RunId 'judged' -Prompt 'Synthetic question' -AllowInference

        $result.pass | Should -BeFalse
        $result.reason | Should -Be 'counterexample'
        (Get-Content -LiteralPath $script:budget -Raw | ConvertFrom-Json).attempts[0].status | Should -Be 'passed'
        Should -Invoke -ModuleName Winpd.Ai Invoke-WinpdProcess -Times 1 `
            -ParameterFilter { $TimeoutSec -eq 10 }
    }

    It 'rejects truthy verdict strings rather than manufacturing a passing result' {
        Mock -ModuleName Winpd.Ai Get-WinpdCopilotExecutable { 'fixture-copilot.exe' }
        Mock -ModuleName Winpd.Ai Invoke-WinpdProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"pass":"false","confidence":1,"reason":"not boolean"}'
                StdErr = ''; TimedOut = $false }
        }
        { Invoke-WinpdCopilotJudge -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('a' * 40) -RunId 'invalid' -Prompt 'Synthetic question' -AllowInference } |
            Should -Throw '*Boolean verdict*'
        (Get-Content -LiteralPath $script:budget -Raw | ConvertFrom-Json).attempts[0].status | Should -Be 'failed'
    }

    It 'does not treat different Unicode scope strings as the same authorization' {
        $authorization = Get-Content -LiteralPath $script:authorization -Raw | ConvertFrom-Json -AsHashtable
        $authorization.scope = 'caf' + [char]0xE9
        $authorization | ConvertTo-Json | Set-Content -LiteralPath $script:authorization
        $null = Reserve-WinpdRequest -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('a' * 40) -RunId 'original-scope'
        $authorization.scope = 'cafe' + [char]0x0301
        $authorization | ConvertTo-Json | Set-Content -LiteralPath $script:authorization

        { Reserve-WinpdRequest -AuthorizationPath $script:authorization `
            -BudgetPath $script:budget -Head ('b' * 40) -RunId 'different-scope' } |
            Should -Throw '*scope differ*'
    }
}

Describe 'Optional generic Windows capture' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName Winpd.Windows Get-WinpdWindowIdentity {
            @{ Hwnd = 100; ProcessId = 200; ClientWidth = 640; ClientHeight = 480; IsVisible = $true }
        }
        Mock -ModuleName Winpd.Windows Get-WinpdWinAppExecutable { 'fixture-winapp.exe' }
    }

    It 'captures an exact supplied window without any Terminal package assumptions' {
        $path = Join-Path $TestDrive 'window.png'
        Mock -ModuleName Winpd.Windows Invoke-WinpdProcess {
            $index = [Array]::IndexOf($Arguments, '--output')
            'Synthetic captured bytes.' | Set-Content -LiteralPath $Arguments[$index + 1]
            @{ ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false }
        }
        $result = Save-WinpdWindowScreenshot -Window @{ Hwnd = 100; Pid = 200 } -Path $path

        $result.Succeeded | Should -BeTrue
        $result.Path | Should -Be $path
        Should -Invoke -ModuleName Winpd.Windows Invoke-WinpdProcess -Times 1 `
            -ParameterFilter { $Arguments -contains '-w' -and $Arguments -contains '100' }
    }

    It 'reports a failed or missing capture instead of a success-shaped path' {
        Mock -ModuleName Winpd.Windows Invoke-WinpdProcess {
            @{ ExitCode = 1; StdOut = ''; StdErr = 'Synthetic capture error'; TimedOut = $false }
        }
        $path = Join-Path $TestDrive 'missing.png'
        $result = Save-WinpdWindowScreenshot -Window @{ Hwnd = 100; Pid = 200 } -Path $path -WarningAction SilentlyContinue
        $result.Succeeded | Should -BeFalse
        $result.Error | Should -Match 'Synthetic capture error'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'does not capture after window ownership validation fails' {
        Mock -ModuleName Winpd.Windows Get-WinpdWindowIdentity { throw 'Window ownership changed.' }
        Mock -ModuleName Winpd.Windows Invoke-WinpdProcess { throw 'Capture must not run.' }
        { Save-WinpdWindowScreenshot -Window @{ Hwnd = 100; Pid = 200 } `
            -Path (Join-Path $TestDrive 'wrong-window.png') } | Should -Throw '*ownership changed*'
        Should -Invoke -ModuleName Winpd.Windows Invoke-WinpdProcess -Times 0
    }
}

Describe 'Read-only common PR observation' -Tag 'Unit' {
    It 'records a closed lifecycle without replying, resolving or continuing a watcher' {
        Mock -ModuleName Winpd.Review Get-WinpdReviewSnapshot {
            @{ data = @{ pullRequest = @{ state = 'MERGED'; headRefOid = 'a' * 40 } }; dataSha256 = 'b' * 64 }
        }
        $state = Join-Path $TestDrive 'watch.json'
        $result = Watch-WinpdPullRequest -PublicationPath 'fixture-publication.json' -StatePath $state -MaxObservations 5

        $result.Status | Should -Be 'closed'
        $result.Observations | Should -Be 1
        (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).Lifecycle | Should -Be 'MERGED'
        Should -Invoke -ModuleName Winpd.Review Get-WinpdReviewSnapshot -Times 1
    }

    It 'records UNKNOWN rather than retaining a stale green result after a read failure' {
        Mock -ModuleName Winpd.Review Get-WinpdReviewSnapshot { throw 'Synthetic network failure.' }
        $state = Join-Path $TestDrive 'failed-watch.json'
        { Watch-WinpdPullRequest -PublicationPath 'fixture-publication.json' -StatePath $state } |
            Should -Throw '*Synthetic network failure*'
        (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).Status | Should -Be 'unknown'
    }

    It 'does not claim a bounded observation is a still-running watcher' {
        Mock -ModuleName Winpd.Review Get-WinpdReviewSnapshot {
            @{ data = @{ pullRequest = @{ state = 'OPEN'; headRefOid = 'a' * 40 } }; dataSha256 = 'b' * 64 }
        }
        $state = Join-Path $TestDrive 'bounded-watch.json'
        $result = Watch-WinpdPullRequest -PublicationPath 'fixture-publication.json' -StatePath $state

        $result.Status | Should -Be 'observed'
        (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).RunnerActive | Should -BeFalse
    }
}
