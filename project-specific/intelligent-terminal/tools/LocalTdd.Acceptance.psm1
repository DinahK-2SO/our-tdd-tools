$commonTools = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\common\tools'))
. (Join-Path $commonTools 'Core.ps1')
. (Join-Path $commonTools 'ai\Budget.ps1')
. (Join-Path $commonTools 'ai\Copilot.Events.ps1')
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LocalTddEvidenceJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-WinpdEvidenceJson @PSBoundParameters
}

function Read-LocalTddAuthorization {
    param([Parameter(Mandatory)][string]$Path)
    Read-WinpdAuthorization @PSBoundParameters
}



function Reserve-LocalTddRequest {
    param(
        [Parameter(Mandatory)][string]$AuthorizationPath,
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Head,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId
    )
    Reserve-WinpdRequest @PSBoundParameters
}

function Set-LocalTddRequestOutcome {
    param(
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][string]$AttemptId,
        [Parameter(Mandatory)][ValidateSet('submitted', 'passed', 'failed', 'unknown')][string]$Outcome
    )
    Set-WinpdRequestOutcome @PSBoundParameters
}

function Read-LocalTddCopilotEvents {
    param([Parameter(Mandatory)][string]$Path)
    Read-WinpdCopilotEvents @PSBoundParameters
}

function Test-LocalTddSubmittedPrompt {
    param([string]$Content, [string]$ExpectedPrompt)
    if ([string]::Equals($Content, $ExpectedPrompt, [StringComparison]::Ordinal) -or
        [string]::Equals($Content, "## User Request`n$ExpectedPrompt", [StringComparison]::Ordinal)) { return $true }
    # WTA's prompt builder appends this final section after terminal context.
    return $Content.EndsWith("`n`n## User Request`n$ExpectedPrompt", [StringComparison]::Ordinal)
}

function Get-LocalTddCopilotRequestState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedPrompt,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$AllowedCommands,
        [string[]]$HandledActions = @()
    )
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($command in $AllowedCommands) {
        if ([string]::IsNullOrWhiteSpace($command)) { throw 'The command allowlist contains an empty command.' }
        [void]$allowed.Add($command.Trim())
    }
    $activeTurns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $tools = @{}
    $pendingTools = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $permissions = [ordered]@{}
    $permissionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $proposals = [ordered]@{}
    $found = $false
    $lastResponse = $null
    $usage = $null
    $failure = $null
    $responseAfterTool = $false
    foreach ($event in $Events) {
        $data = $event.data
        if ($event.type -eq 'user.message') {
            if ($found) { throw 'Unexpected additional submission in the scoped request stream.' }
            if (Test-LocalTddSubmittedPrompt $data.content $ExpectedPrompt) { $found = $true }
            continue
        }
        if (-not $found) { continue }
        switch ($event.type) {
            'assistant.turn_start' {
                if (-not $data.Contains('turnId') -or -not $activeTurns.Add([string]$data.turnId)) {
                    throw 'Invalid or repeated assistant turn start.'
                }
            }
            'assistant.message' {
                if (-not $data.Contains('toolRequests') -or -not $data.model -or -not $activeTurns.Contains([string]$data.turnId)) {
                    throw 'Assistant response lacks scoped turn/model/tool metadata.'
                }
                $lastResponse = $data
                $responseAfterTool = @($data.toolRequests).Count -eq 0
                foreach ($tool in @($data.toolRequests)) {
                    $command = [string]$tool.arguments.command
                    $proposal = $tool['mcpToolName'] -eq 'run_command_in_current_shell' -or
                        [string]$tool.name -match '-run_command_in_current_shell$'
                    if (-not $tool.toolCallId -or -not $allowed.Contains($command.Trim()) -or
                        (-not $proposal -and $tool.name -ne 'powershell')) {
                        throw 'A tool request is outside the exact command allowlist.'
                    }
                    $tools[$tool.toolCallId] = @{ command = $command; proposal = $proposal }
                    [void]$pendingTools.Add([string]$tool.toolCallId)
                }
            }
            'tool.execution_start' {
                if (-not $tools.ContainsKey($data.toolCallId) -or
                    -not [string]::Equals($data.arguments.command, $tools[$data.toolCallId].command, [StringComparison]::Ordinal)) {
                    throw 'A tool execution does not match its scoped assistant request.'
                }
            }
            'tool.execution_complete' {
                if (-not $pendingTools.Remove([string]$data.toolCallId)) { throw 'Unexpected tool completion.' }
                $responseAfterTool = $false
                if ($data.success -isnot [bool] -or -not $data.success) { $failure = 'Provider tool execution failed.' }
                elseif ($tools[$data.toolCallId].proposal) {
                    if ($data.result.structuredContent.status -ne 'accepted') { throw 'Unsupported terminal proposal result.' }
                    $proposals["proposal:$($data.toolCallId)"] = $tools[$data.toolCallId].command
                }
            }
            'permission.requested' {
                $permission = $data.permissionRequest
                $command = switch ($permission.kind) {
                    'shell' { [string]$permission.fullCommandText }
                    'mcp' {
                        if ([string]$permission.toolName -notmatch '(^|-)run_command_in_current_shell$') {
                            throw 'MCP permission is outside the command allowlist.'
                        }
                        [string]$permission.args.command
                    }
                    default { throw 'Permission kind is outside the command allowlist.' }
                }
                if (-not $data.requestId -or -not $allowed.Contains($command.Trim())) {
                    throw 'Permission command is outside the exact command allowlist.'
                }
                if (-not $permissionIds.Add([string]$data.requestId)) { throw 'Duplicate permission request ID.' }
                $permissions[$data.requestId] = $command
            }
            'permission.completed' {
                if (-not $permissions.Contains($data.requestId)) { throw 'Unexpected permission completion.' }
                $permissions.Remove($data.requestId)
                if ($data.result.kind -ne 'approved') { $failure = 'Provider permission was not approved.' }
            }
            'assistant.turn_end' {
                if (-not $activeTurns.Remove([string]$data.turnId)) { throw 'Unexpected assistant turn end.' }
            }
            'session.usage_checkpoint' {
                $usage = @{}
                foreach ($key in 'totalPremiumRequests', 'totalNanoAiu') {
                    if ($data.Contains($key)) { $usage[$key] = $data[$key] }
                }
            }
        }
    }
    $actions = @(
        foreach ($id in $permissions.Keys) {
            if ("permission:$id" -cnotin $HandledActions) {
                @{ id = "permission:$id"; kind = 'permission'; command = $permissions[$id] }
            }
            break
        }
        foreach ($id in $proposals.Keys) {
            if ($id -cnotin $HandledActions) { @{ id = $id; kind = 'commandProposal'; command = $proposals[$id] } }
        }
    )
    $status = if ($failure) { 'failed' }
    elseif (-not $found) { 'waitingForRequest' }
    elseif ($lastResponse -and $responseAfterTool -and $activeTurns.Count -eq 0 -and
        $pendingTools.Count -eq 0 -and $permissions.Count -eq 0 -and $actions.Count -eq 0) { 'responseComplete' }
    else { 'working' }
    [pscustomobject]@{
        status = $status; actions = $actions; failure = $failure
        model = if ($lastResponse) { $lastResponse.model } else { $null }
        response = if ($lastResponse) { $lastResponse.content } else { $null }
        usageAvailable = $null -ne $usage -and $usage.Count -gt 0
        usage = $usage
    }
}

function ConvertTo-LocalTddTime {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-LocalTddPublishedDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PublicationPath,
        [Parameter(Mandatory)][string]$ReceiptPath
    )
    $publication = Get-Content -LiteralPath $PublicationPath -Raw | ConvertFrom-Json -AsHashtable
    if ($publication.head -notmatch '^[a-fA-F0-9]{40}$' -or
        $publication.remote -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or
        $publication.repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -or
        $publication.pullRequest -notmatch '^[1-9][0-9]*$' -or -not $publication.branch) {
        throw 'Publication identity is incomplete.'
    }
    $headOutput = & git -C $RepoRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the source HEAD.' }
    $head = [string]$headOutput
    $dirty = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -or $head -ne $publication.head) {
        throw 'Publication requires the exact clean source HEAD.'
    }
    & git -C $RepoRoot check-ref-format --branch $publication.branch | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Invalid publish branch.' }
    $remote = @(& git -C $RepoRoot ls-remote -- $publication.remote "refs/heads/$($publication.branch)")
    if ($LASTEXITCODE -ne 0 -or $remote.Count -ne 1 -or ($remote[0] -split '\s+')[0] -ne $head) {
        throw 'Remote publish HEAD differs from the source.'
    }
    $prText = & gh pr view $publication.pullRequest --repo $publication.repository --json headRefOid,state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify the PR HEAD.' }
    $pr = $prText | ConvertFrom-Json -AsHashtable
    if ($pr.headRefOid -ne $head -or $pr.state -ne 'OPEN') { throw 'The PR no longer matches the open published iteration.' }
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    if ($receipt.gitHead -ne $head -or $receipt.installVerified -ne $true -or
        $receipt.packageFamily -ne 'IntelligentTerminal_rd9vj3e6a2mbr') {
        throw 'The receipt does not prove this published Dev build.'
    }
    $pushed = ConvertTo-LocalTddTime $publication.pushedUtc
    $built = ConvertTo-LocalTddTime $receipt.buildStartedUtc
    $deployed = ConvertTo-LocalTddTime $receipt.createdUtc
    if ($built -lt $pushed -or $deployed -lt $built -or $deployed -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
        throw 'Build/deployment timestamps do not establish a fresh post-push deployment.'
    }
    & (Join-Path $PSScriptRoot 'Verify-DeploymentFreshness.ps1') -RepoRoot $RepoRoot -ReceiptPath $ReceiptPath |
        Out-Null
    return $receipt
}

function Invoke-LocalTddRealAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PublicationPath,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$ScenarioPath,
        [Parameter(Mandatory)][string]$AuthorizationPath,
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$AllowRealInference
    )
    if (-not $AllowRealInference) { throw 'Real acceptance requires explicit -AllowRealInference opt-in.' }
    $null = Read-LocalTddAuthorization $AuthorizationPath
    $definition = $null
    $OutDir = [IO.Path]::GetFullPath($OutDir)
    if (Test-Path -LiteralPath $OutDir) { throw 'Use a new real-acceptance evidence directory.' }
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    $context = @{ repoRoot = $RepoRoot; outDir = $OutDir; state = @{} }
    $result = @{
        schemaVersion = 1; kind = 'real-user'; status = 'running'
        runId = [guid]::NewGuid().ToString('N'); head = $null
        processId = $PID; processStartUtc = ([Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().ToString('o')
        startedUtc = [DateTimeOffset]::UtcNow.ToString('o'); submittedUtc = $null; completedUtc = $null
        submissionAttempted = $false; promptsObserved = 0; providerEventLogObserved = $false; cleanupPassed = $false
        error = $null; cleanupError = $null; identityError = $null
        receiptSha256 = (Get-FileHash -LiteralPath $ReceiptPath).Hash
        scenarioSha256 = (Get-FileHash -LiteralPath $ScenarioPath).Hash
    }
    $attempt = $null
    $identityEstablished = $false
    $errorRecord = $null
    try {
        $receipt = Assert-LocalTddPublishedDeployment -RepoRoot $RepoRoot -PublicationPath $PublicationPath -ReceiptPath $ReceiptPath
        $identityEstablished = $true
        $context.receipt = $receipt
        $result.head = $receipt.gitHead
        $result.wtaSha256 = $receipt.hashes.wta
        $definition = & $ScenarioPath
        if ($definition -isnot [Collections.IDictionary]) { throw 'Scenario must return a callback dictionary.' }
        foreach ($name in 'Prepare', 'Submit', 'HandleAction', 'Verify', 'Cleanup') {
            if ($definition[$name] -isnot [scriptblock]) { throw "Scenario callback is missing: $name" }
        }
        $plan = & $definition.Prepare $context
        if ($plan -isnot [Collections.IDictionary] -or $plan.provider -ne 'copilot' -or
            -not $plan.expectedPrompt -or -not $plan.allowedCommands -or -not $plan.sessionId -or
            -not $plan.eventsPath -or -not [IO.Path]::IsPathFullyQualified($plan.eventsPath)) {
            throw 'Prepare must identify a real Copilot session, its events, exact prompt and allowed commands.'
        }
        $context.plan = $plan
        $priorEvents = @()
        if (Test-Path -LiteralPath $plan.eventsPath) {
            if (-not (Test-Path -LiteralPath $plan.eventsPath -PathType Leaf)) {
                throw 'The provider event path must name a file.'
            }
            $result.providerEventLogObserved = $true
            $priorEvents = @(Read-LocalTddCopilotEvents $plan.eventsPath)
        }
        if (@($priorEvents | Where-Object {
            $_.type -eq 'user.message' -and (Test-LocalTddSubmittedPrompt $_.data.content $plan.expectedPrompt)
        }).Count) {
            throw 'The exact prompt already exists in this session; use a fresh unique request.'
        }
        $null = Assert-LocalTddPublishedDeployment -RepoRoot $RepoRoot -PublicationPath $PublicationPath -ReceiptPath $ReceiptPath
        $attempt = Reserve-LocalTddRequest -AuthorizationPath $AuthorizationPath -BudgetPath $BudgetPath `
            -Head $result.head -RunId $result.runId
        $result.attemptId = $attempt.id
        $result.submissionAttempted = $true
        $result.submittedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Set-LocalTddRequestOutcome -BudgetPath $BudgetPath -AttemptId $attempt.id -Outcome submitted
        Write-LocalTddEvidenceJson -Path (Join-Path $OutDir 'real-acceptance.json') -Value $result
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($attempt.timeoutSeconds)
        & $definition.Submit $context | Out-Null
        $handled = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        do {
            if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'The real request exceeded its authorized deadline.' }
            # Some providers create their event log only after the first submission.
            $events = @()
            if (Test-Path -LiteralPath $plan.eventsPath) {
                if (-not (Test-Path -LiteralPath $plan.eventsPath -PathType Leaf)) {
                    throw 'The provider event path must name a file.'
                }
                $result.providerEventLogObserved = $true
                $events = @(Read-LocalTddCopilotEvents $plan.eventsPath)
            }
            elseif ($result.providerEventLogObserved) {
                throw 'The provider event log disappeared after observation.'
            }
            $state = Get-LocalTddCopilotRequestState -Events $events -ExpectedPrompt $plan.expectedPrompt `
                -AllowedCommands $plan.allowedCommands -HandledActions @($handled)
            if ($state.status -ne 'waitingForRequest') { $result.promptsObserved = 1 }
            if ($state.status -eq 'failed') { throw $state.failure }
            foreach ($action in $state.actions) {
                if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'The real request exceeded its authorized deadline.' }
                $performed = & $definition.HandleAction $context $action
                if ($performed -notin @('pending', 'performed')) { throw 'HandleAction must return pending or performed.' }
                if ($performed -eq 'performed') { [void]$handled.Add($action.id) }
            }
            if ($state.status -eq 'responseComplete') {
                $observable = & $definition.Verify $context
                if ($observable -isnot [Collections.IDictionary] -or $observable.status -notin @('pending', 'passed', 'failed')) {
                    throw 'Verify must return an explicit observable status.'
                }
                if ($observable.status -eq 'failed') { throw 'The feature observable failed after model completion.' }
                if ($observable.status -eq 'passed') {
                    if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'The real request exceeded its authorized deadline.' }
                    if ($observable.expected -isnot [string] -or $observable.actual -isnot [string] -or
                        -not [string]::Equals($observable.expected, $observable.actual, [StringComparison]::Ordinal)) {
                        throw 'The exact observable values do not match.'
                    }
                    $result.observable = $observable
                    $result.provider = 'copilot'
                    $result.model = $state.model
                    $result.response = $state.response
                    $result.usageAvailable = $state.usageAvailable
                    $result.usage = $state.usage
                    $result.handledActions = @($handled)
                    $result.responseCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    $result.status = 'passed'
                    break
                }
            }
            Start-Sleep -Milliseconds 200
        } while ($true)
    }
    catch {
        $errorRecord = $_
        $result.error = $_.Exception.Message
        $result.status = if ($result.submissionAttempted) { 'failed' } else { 'blocked' }
    }
    finally {
        try {
            $cleaned = if ($null -eq $definition) { $true } else { & $definition.Cleanup $context }
            if ($cleaned -isnot [bool] -or -not $cleaned) { throw 'Cleanup must explicitly confirm successful restoration.' }
            $result.cleanupPassed = $true
        }
        catch {
            $result.cleanupError = $_.Exception.Message
            $result.status = 'failed'
            $errorRecord = $_
        }
        if ($identityEstablished) {
            try {
                if ((Get-FileHash -LiteralPath $ReceiptPath).Hash -ne $result.receiptSha256 -or
                    (Get-FileHash -LiteralPath $ScenarioPath).Hash -ne $result.scenarioSha256) {
                    throw 'Receipt or scenario changed during real acceptance.'
                }
                $null = Assert-LocalTddPublishedDeployment -RepoRoot $RepoRoot -PublicationPath $PublicationPath -ReceiptPath $ReceiptPath
            }
            catch {
                $result.identityError = $_.Exception.Message
                $result.status = 'failed'
                $errorRecord = $_
            }
        }
        $result.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        if ($attempt) {
            Set-LocalTddRequestOutcome -BudgetPath $BudgetPath -AttemptId $attempt.id `
                -Outcome $(if ($result.status -eq 'passed') { 'passed' } else { 'failed' })
        }
        Write-LocalTddEvidenceJson -Path (Join-Path $OutDir 'real-acceptance.json') -Value $result
    }
    if ($errorRecord) { throw $errorRecord }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Write-LocalTddEvidenceJson, Read-LocalTddAuthorization,
    Reserve-LocalTddRequest, Set-LocalTddRequestOutcome, Read-LocalTddCopilotEvents, Get-LocalTddCopilotRequestState,
    ConvertTo-LocalTddTime, Assert-LocalTddPublishedDeployment, Invoke-LocalTddRealAcceptance
