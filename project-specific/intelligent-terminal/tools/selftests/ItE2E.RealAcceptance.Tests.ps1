#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:acceptanceModule = Join-Path $PSScriptRoot '..\LocalTdd.Acceptance.psm1'
    if (Test-Path -LiteralPath $script:acceptanceModule) {
        Import-Module $script:acceptanceModule -Force
    }
    function New-TestEvent([string]$Type, [hashtable]$Data) {
        @{ type = $Type; data = $Data; id = [guid]::NewGuid().ToString('N') }
    }
    function New-TestRequest {
        @(
            (New-TestEvent 'user.message' @{ content = 'unique task' }),
            (New-TestEvent 'assistant.turn_start' @{ turnId = '0' }),
            (New-TestEvent 'assistant.message' @{
                turnId = '0'; model = 'observed-model'; content = ''
                toolRequests = @(@{
                    toolCallId = 'tool-1'; name = 'powershell'; arguments = @{ command = 'allowed command' }
                })
            }),
            (New-TestEvent 'tool.execution_start' @{
                toolCallId = 'tool-1'; toolName = 'powershell'; arguments = @{ command = 'allowed command' }
            })
        )
    }
    function Get-TestRequestState([object[]]$Events, [string[]]$HandledActions = @()) {
        Get-LocalTddCopilotRequestState -Events $Events -ExpectedPrompt 'unique task' `
            -AllowedCommands 'allowed command' -HandledActions $HandledActions
    }
}

Describe 'Real acceptance orchestration without inference' -Tag 'Unit', 'RealAcceptance' {
    BeforeEach {
        $script:driverRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:driverRoot | Out-Null
        $script:driverArgs = @{
            RepoRoot = $script:driverRoot
            PublicationPath = Join-Path $script:driverRoot 'publication.json'
            ReceiptPath = Join-Path $script:driverRoot 'receipt.json'
            AuthorizationPath = Join-Path $script:driverRoot 'authorization.json'
            BudgetPath = Join-Path $script:driverRoot 'budget.json'
            ScenarioPath = Join-Path $script:driverRoot 'scenario.ps1'
            OutDir = Join-Path $script:driverRoot 'run'
        }
        '{}' | Set-Content $script:driverArgs.PublicationPath
        '{}' | Set-Content $script:driverArgs.ReceiptPath
        @{ schemaVersion = 1; approved = $true; scope = 'offline-fixture'; totalLimit = 1; perHeadLimit = 1; timeoutSeconds = 5 } |
            ConvertTo-Json | Set-Content $script:driverArgs.AuthorizationPath
        Mock -ModuleName LocalTdd.Acceptance Assert-LocalTddPublishedDeployment {
            @{ gitHead = 'a' * 40; hashes = @{ wta = 'b' * 64 } }
        }
        $script:scenario = @'
@{
    Prepare = {
        param($context)
        $context.state.eventsPath = Join-Path $context.outDir 'offline-events.jsonl'
        @{ provider = 'copilot'; sessionId = 'offline-fixture'; expectedPrompt = 'unique task'
            allowedCommands = @('allowed command'); eventsPath = $context.state.eventsPath }
    }
    Submit = {
        param($context)
        if (Test-Path -LiteralPath $context.state.eventsPath) { throw 'The runner must not create provider event logs.' }
        $context.state.events = @(
            @{ type = 'user.message'; data = @{ content = 'unique task' } },
            @{ type = 'assistant.turn_start'; data = @{ turnId = '0' } },
            @{ type = 'assistant.message'; data = @{ turnId = '0'; model = 'offline-model'; content = ''; toolRequests = @() } },
            @{ type = 'permission.requested'; data = @{ requestId = 'p1'; permissionRequest = @{ kind = 'shell'; fullCommandText = 'allowed command' } } }
        )
        $context.state.events | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } | Set-Content $context.state.eventsPath
    }
    HandleAction = {
        param($context, $action)
        $context.state.events += @{ type = 'permission.completed'; data = @{ requestId = 'p1'; result = @{ kind = 'approved' } } }
        $context.state.events += @{ type = 'assistant.turn_end'; data = @{ turnId = '0' } }
        $context.state.events | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } | Set-Content $context.state.eventsPath
        'performed'
    }
    Verify = { param($context) @{ status = 'passed'; expected = 'marker'; actual = 'marker' } }
    Cleanup = { param($context) $true }
}
'@
        $script:scenario | Set-Content $script:driverArgs.ScenarioPath -Encoding utf8
    }

    It 'does not load the scenario or reserve anything without real-inference opt-in' {
        { Invoke-LocalTddRealAcceptance @script:driverArgs } | Should -Throw '*opt-in*'
        Test-Path $script:driverArgs.OutDir | Should -BeFalse
        Test-Path $script:driverArgs.BudgetPath | Should -BeFalse
        Should -Invoke -ModuleName LocalTdd.Acceptance Assert-LocalTddPublishedDeployment -Times 0
    }

    It 'waits for a provider-created event log, then validates the request, action and cleanup' {
        $result = Invoke-LocalTddRealAcceptance @script:driverArgs -AllowRealInference
        $result.status | Should -Be 'passed'
        $result.promptsObserved | Should -Be 1
        $result.providerEventLogObserved | Should -BeTrue
        $result.cleanupPassed | Should -BeTrue
        @($result.handledActions).Count | Should -Be 1
        $result.model | Should -Be 'offline-model'
        (Get-Content $script:driverArgs.BudgetPath -Raw | ConvertFrom-Json).attempts[0].status | Should -Be 'passed'
        Should -Invoke -ModuleName LocalTdd.Acceptance Assert-LocalTddPublishedDeployment -Times 3
    }

    It 'keeps missing provider evidence failed and charged without creating a log' {
        $write = '$context.state.events | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } | Set-Content $context.state.eventsPath'
        $script:scenario.Replace($write, '$null') | Set-Content $script:driverArgs.ScenarioPath -Encoding utf8
        $authorization = Get-Content $script:driverArgs.AuthorizationPath -Raw | ConvertFrom-Json
        $authorization.timeoutSeconds = 1
        $authorization | ConvertTo-Json | Set-Content $script:driverArgs.AuthorizationPath
        { Invoke-LocalTddRealAcceptance @script:driverArgs -AllowRealInference } | Should -Throw '*deadline*'
        $result = Get-Content (Join-Path $script:driverArgs.OutDir 'real-acceptance.json') -Raw | ConvertFrom-Json
        $result.status | Should -Be 'failed'
        $result.promptsObserved | Should -Be 0
        $result.providerEventLogObserved | Should -BeFalse
        $result.cleanupPassed | Should -BeTrue
        Test-Path (Join-Path $script:driverArgs.OutDir 'offline-events.jsonl') | Should -BeFalse
        (Get-Content $script:driverArgs.BudgetPath -Raw | ConvertFrom-Json).attempts[0].status | Should -Be 'failed'
    }

    It 'rejects canonically equivalent but different observable text' {
        $script:scenario.Replace("expected = 'marker'; actual = 'marker'",
            "expected = ([string][char]0x00E9); actual = ('e' + [char]0x0301)") |
            Set-Content $script:driverArgs.ScenarioPath -Encoding utf8
        { Invoke-LocalTddRealAcceptance @script:driverArgs -AllowRealInference } | Should -Throw '*exact observable*'
    }

    It 'retains an observed result but fails the run when cleanup fails' {
        $script:scenario.Replace('Cleanup = { param($context) $true }', 'Cleanup = { param($context) throw "restore failed" }') |
            Set-Content $script:driverArgs.ScenarioPath -Encoding utf8
        { Invoke-LocalTddRealAcceptance @script:driverArgs -AllowRealInference } | Should -Throw '*restore failed*'
        $result = Get-Content (Join-Path $script:driverArgs.OutDir 'real-acceptance.json') -Raw | ConvertFrom-Json
        $result.status | Should -Be 'failed'
        $result.observable.actual | Should -Be 'marker'
        $result.cleanupPassed | Should -BeFalse
        (Get-Content $script:driverArgs.BudgetPath -Raw | ConvertFrom-Json).attempts[0].status | Should -Be 'failed'
    }

    It 'keeps a submission exception charged and still runs cleanup' {
        $script:scenario.Replace('$context.state.events = @(', 'throw "submission failed"; $context.state.events = @(') |
            Set-Content $script:driverArgs.ScenarioPath -Encoding utf8
        { Invoke-LocalTddRealAcceptance @script:driverArgs -AllowRealInference } | Should -Throw '*submission failed*'
        $result = Get-Content (Join-Path $script:driverArgs.OutDir 'real-acceptance.json') -Raw | ConvertFrom-Json
        $result.promptsObserved | Should -Be 0
        $result.submissionAttempted | Should -BeTrue
        $result.cleanupPassed | Should -BeTrue
        @( (Get-Content $script:driverArgs.BudgetPath -Raw | ConvertFrom-Json).attempts ).Count | Should -Be 1
    }
}

Describe 'Reference callback import scope' -Tag 'Unit', 'RealAcceptance' {
    It 'makes imported helpers available to nested configuration-verification closures' {
        $repo = Join-Path $TestDrive 'callback-repo'
        $moduleDir = Join-Path $repo 'test\e2e\ItE2E'
        $helpers = Join-Path $repo 'test\e2e\tests\helpers'
        New-Item -ItemType Directory -Path $moduleDir, $helpers | Out-Null
        "@{ RootModule = 'ItE2E.psm1'; ModuleVersion = '1.0' }" | Set-Content (Join-Path $moduleDir 'ItE2E.psd1')
        @'
function Get-FixtureScopeValue { 'scope-value' }
function Resolve-ItApp {
    param($Package)
    $probe = { Get-FixtureScopeValue }.GetNewClosure()
    if ((& $probe) -ne 'scope-value') { throw 'Nested helper lookup failed.' }
    throw 'fixture-scope-reached'
}
Export-ModuleMember -Function Get-FixtureScopeValue, Resolve-ItApp
'@ | Set-Content (Join-Path $moduleDir 'ItE2E.psm1')
        '' | Set-Content (Join-Path $helpers 'TestWindowKeyboardLayout.ps1')
        $runner = Join-Path $TestDrive 'scope-probe.ps1'
        @'
param($Scenario, $Repo)
$ErrorActionPreference = 'Stop'
$module = New-Module -ScriptBlock {
    function Invoke-Probe($Scenario, $Repo) {
        $definition = & $Scenario
        & $definition.Prepare @{ repoRoot = $Repo; state = @{} }
    }
}
try {
    & $module { param($Scenario, $Repo) Invoke-Probe $Scenario $Repo } $Scenario $Repo
    throw 'The offline setup probe unexpectedly continued.'
}
catch {
    if ($_.Exception.Message -ne 'fixture-scope-reached') { throw }
}
'@ | Set-Content $runner
        $example = (Resolve-Path (Join-Path $PSScriptRoot '..\examples\RealUser.Marker.ps1')).Path
        $probeOutput = & pwsh -NoProfile -File $runner -Scenario $example -Repo $repo 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "the nested setup must resolve its imported helper: $probeOutput"
    }
}

Describe 'Bounded real request ledger' -Tag 'Unit', 'RealAcceptance' {
    BeforeEach {
        $script:authorizationPath = Join-Path $TestDrive 'authorization.json'
        $script:budgetPath = Join-Path $TestDrive 'requests.json'
        $script:authorization = @{
            schemaVersion = 1; approved = $true; scope = 'offline-fixture'
            totalLimit = 2; perHeadLimit = 1; timeoutSeconds = 120
        }
        $script:authorization | ConvertTo-Json | Set-Content $script:authorizationPath -Encoding utf8
        if (Test-Path $script:budgetPath) { Remove-Item -LiteralPath $script:budgetPath }
    }

    It 'requires explicit authorization before reserving a request' {
        $script:authorization.approved = $false
        $script:authorization | ConvertTo-Json | Set-Content $script:authorizationPath -Encoding utf8
        { Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-a' } | Should -Throw '*approval*'
        Test-Path $script:budgetPath | Should -BeFalse
    }

    It 'persists a reservation before submission and refuses accidental same-head retries' {
        $attempt = Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-a'
        $attempt.status | Should -Be 'reserved'
        { Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-b' } | Should -Throw '*per-head*'
        @((Get-Content $script:budgetPath -Raw | ConvertFrom-Json).attempts).Count | Should -Be 1
    }

    It 'retains failed attempts when authorization explicitly increases the limit' {
        $attempt = Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-a'
        Set-LocalTddRequestOutcome -BudgetPath $script:budgetPath -AttemptId $attempt.id -Outcome failed
        $script:authorization.perHeadLimit = 2
        $script:authorization | ConvertTo-Json | Set-Content $script:authorizationPath -Encoding utf8
        $null = Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-b'
        $ledger = Get-Content $script:budgetPath -Raw | ConvertFrom-Json
        $ledger.attempts[0].status | Should -Be 'failed'
        @($ledger.attempts).Count | Should -Be 2
        { Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('b' * 40) -RunId 'run-c' } | Should -Throw '*total*'
    }

    It 'rejects corrupted or foreign ledgers rather than resetting their request count' {
        '{bad' | Set-Content $script:budgetPath
        { Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-a' } | Should -Throw
        @{ schemaVersion = 1; scope = 'another-task'; attempts = @() } |
            ConvertTo-Json | Set-Content $script:budgetPath
        { Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-a' } | Should -Throw '*scope*'
    }

    It 'does not overwrite a completed attempt with a later outcome' {
        $attempt = Reserve-LocalTddRequest -AuthorizationPath $script:authorizationPath -BudgetPath $script:budgetPath `
            -Head ('a' * 40) -RunId 'run-a'
        Set-LocalTddRequestOutcome -BudgetPath $script:budgetPath -AttemptId $attempt.id -Outcome failed
        { Set-LocalTddRequestOutcome -BudgetPath $script:budgetPath -AttemptId $attempt.id -Outcome passed } |
            Should -Throw '*terminal*'
    }
}

Describe 'Copilot request completion replay' -Tag 'Unit', 'RealAcceptance' {
    It 'does not mistake a tool turn end for the final response' {
        $events = @(New-TestRequest) + @(
            (New-TestEvent 'tool.execution_complete' @{ toolCallId = 'tool-1'; success = $true }),
            (New-TestEvent 'assistant.turn_end' @{ turnId = '0' })
        )
        (Get-TestRequestState $events).status | Should -Be 'working'
    }

    It 'waits for outstanding tools even when final-looking text has arrived' {
        $events = @(New-TestRequest) + @(
            (New-TestEvent 'assistant.message' @{ turnId = '0'; model = 'observed-model'; content = 'DONE'; toolRequests = @() }),
            (New-TestEvent 'assistant.turn_end' @{ turnId = '0' })
        )
        (Get-TestRequestState $events).status | Should -Be 'working'
        $events += New-TestEvent 'tool.execution_complete' @{ toolCallId = 'tool-1'; success = $true }
        (Get-TestRequestState $events).status | Should -Be 'working'
    }

    It 'handles distinct permission IDs and does not repeat an already performed action' {
        $events = @(New-TestRequest) + @(
            (New-TestEvent 'permission.requested' @{ requestId = 'p1'; permissionRequest = @{ kind = 'shell'; fullCommandText = 'allowed command' } }),
            (New-TestEvent 'permission.completed' @{ requestId = 'p1'; result = @{ kind = 'approved' } }),
            (New-TestEvent 'permission.requested' @{ requestId = 'p2'; permissionRequest = @{ kind = 'shell'; fullCommandText = 'allowed command' } })
        )
        $state = Get-TestRequestState $events
        @($state.actions).Count | Should -Be 1
        $state.actions[0].id | Should -Be 'permission:p2'
        $handled = Get-TestRequestState $events @('permission:p2')
        @($handled.actions).Count | Should -Be 0
        $handled.status | Should -Be 'working'
    }

    It 'requires physical command confirmation after an accepted MCP proposal' {
        $events = @(
            (New-TestEvent 'user.message' @{ content = 'unique task' }),
            (New-TestEvent 'assistant.turn_start' @{ turnId = '0' }),
            (New-TestEvent 'assistant.message' @{
                turnId = '0'; model = 'observed-model'; content = ''
                toolRequests = @(@{ toolCallId = 'proposal-1'; name = 'intellterm_test-run_command_in_current_shell'
                    arguments = @{ command = 'allowed command' }; mcpToolName = 'run_command_in_current_shell' })
            }),
            (New-TestEvent 'tool.execution_complete' @{ toolCallId = 'proposal-1'; success = $true
                result = @{ structuredContent = @{ status = 'accepted' } } }),
            (New-TestEvent 'assistant.message' @{ turnId = '0'; model = 'observed-model'; content = ''; toolRequests = @() }),
            (New-TestEvent 'assistant.turn_end' @{ turnId = '0' })
        )
        $state = Get-TestRequestState $events
        $state.actions[0].kind | Should -Be 'commandProposal'
        $state.status | Should -Be 'working'
        (Get-TestRequestState $events @('proposal:proposal-1')).status | Should -Be 'responseComplete'
    }

    It 'waits for the first permission completion before acting on a queued request' {
        $events = @(New-TestRequest) + @(
            (New-TestEvent 'permission.requested' @{ requestId = 'p1'; permissionRequest = @{ kind = 'shell'; fullCommandText = 'allowed command' } }),
            (New-TestEvent 'permission.requested' @{ requestId = 'p2'; permissionRequest = @{ kind = 'shell'; fullCommandText = 'allowed command' } })
        )
        (Get-TestRequestState $events).actions[0].id | Should -Be 'permission:p1'
        @( (Get-TestRequestState $events @('permission:p1')).actions ).Count | Should -Be 0
        $events += New-TestEvent 'permission.completed' @{ requestId = 'p1'; result = @{ kind = 'approved' } }
        (Get-TestRequestState $events @('permission:p1')).actions[0].id | Should -Be 'permission:p2'
    }

    It 'rejects out-of-scope commands even when another component already approved them' {
        $events = @(New-TestRequest) + @(
            (New-TestEvent 'permission.requested' @{ requestId = 'p1'; permissionRequest = @{ kind = 'shell'; fullCommandText = 'unapproved command' } }),
            (New-TestEvent 'permission.completed' @{ requestId = 'p1'; result = @{ kind = 'approved' } })
        )
        { Get-TestRequestState $events } | Should -Throw '*allowlist*'
    }

    It 'requires the exact submitted prompt and excludes an earlier request' {
        $old = @(
            (New-TestEvent 'user.message' @{ content = 'old task' }),
            (New-TestEvent 'assistant.turn_start' @{ turnId = '0' }),
            (New-TestEvent 'assistant.message' @{ turnId = '0'; model = 'old-model'; content = 'DONE'; toolRequests = @() }),
            (New-TestEvent 'assistant.turn_end' @{ turnId = '0' })
        )
        (Get-TestRequestState $old).status | Should -Be 'waitingForRequest'
        (Get-TestRequestState ($old + @(New-TestRequest))).status | Should -Be 'working'
    }

    It 'recognizes the product User Request envelope without matching terminal-context echoes' {
        $events = @(New-TestRequest)
        $events[0].data.content = "context`n`n## User Request`nunique task"
        (Get-TestRequestState $events).status | Should -Be 'working'
        $events[0].data.content = "unique task appeared in old terminal output`n`n## User Request`ndifferent task"
        (Get-TestRequestState $events).status | Should -Be 'waitingForRequest'
    }

    It 'rejects duplicate submissions instead of crediting a later request' {
        $events = @(New-TestRequest) + (New-TestEvent 'user.message' @{ content = 'unique task' })
        { Get-TestRequestState $events } | Should -Throw '*submission*'
    }

    It 'records the response model and leaves unavailable usage explicit' {
        $events = @(
            (New-TestEvent 'user.message' @{ content = 'unique task' }),
            (New-TestEvent 'assistant.turn_start' @{ turnId = '0' }),
            (New-TestEvent 'assistant.message' @{ turnId = '0'; model = 'observed-model'; content = ''; toolRequests = @() }),
            (New-TestEvent 'assistant.turn_end' @{ turnId = '0' })
        )
        $state = Get-TestRequestState $events
        $state.status | Should -Be 'responseComplete'
        $state.model | Should -Be 'observed-model'
        $state.usageAvailable | Should -BeFalse
    }

    It 'never credits a provider denial or failed tool' {
        $events = @(New-TestRequest) + (New-TestEvent 'tool.execution_complete' @{ toolCallId = 'tool-1'; success = $false })
        (Get-TestRequestState $events).status | Should -Be 'failed'
    }

    It 'ignores only an incomplete JSONL tail and rejects an invalid complete record' {
        $path = Join-Path $TestDrive 'events.jsonl'
        $first = (New-TestEvent 'user.message' @{ content = 'unique task' }) | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($path, "$first`n{partial")
        @(Read-LocalTddCopilotEvents -Path $path).Count | Should -Be 1
        [IO.File]::AppendAllText($path, "`n")
        { Read-LocalTddCopilotEvents -Path $path } | Should -Throw
    }
}
