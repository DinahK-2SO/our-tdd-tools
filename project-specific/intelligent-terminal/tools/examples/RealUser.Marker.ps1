# Local-only reference scenario. Add the feature's physical action and exact oracle in Prepare/Verify.
# Loading this file only defines callbacks; the opt-in runner owns submission and request accounting.
@{
    Prepare = {
        param($context)
        Import-Module (Join-Path $context.repoRoot 'test\e2e\ItE2E\ItE2E.psd1') -Force -Global
        . (Join-Path $context.repoRoot 'test\e2e\tests\helpers\TestWindowKeyboardLayout.ps1')
        $state = $context.state
        $state['target'] = Resolve-ItApp -Package Dev
        if (@(Get-WtProcessesForApp -App $state.target).Count) {
            throw 'The selected Dev package has user-owned windows; the scenario will not close them.'
        }
        $state['configuration'] = @()
        foreach ($path in @($state.target.SettingsPath, $state.target.StatePath)) {
            if (Test-Path -LiteralPath "$path.e2ebak") { throw 'A previous test backup needs recovery.' }
            $state.configuration += @{ path = $path; hash = $(if (Test-Path -LiteralPath $path) { (Get-FileHash $path).Hash } else { $null }) }
        }
        $state['clipboard'] = Get-ClipboardSnapshot
        $state['workspace'] = Join-Path $env:TEMP "ItE2E-real-marker-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $state.workspace | Out-Null
        $state['launchStarted'] = Get-Date
        $state['app'] = Start-Terminal -Package Dev -PassFre $true -Settings @{
            acpAgent = 'copilot'; acpModel = ''; 'warning.confirmOnClose' = 'never'
        }
        $shell = New-WtTab -App $state.app -Command 'pwsh.exe -NoLogo -NoExit' -Cwd $state.workspace
        Set-WtPaneFocus -App $state.app -SessionId $shell.session_id | Out-Null
        Open-AgentPane -App $state.app | Out-Null
        $session = Wait-NewAgentPaneSession -App $state.app -OwnerPaneSessionId $shell.session_id -TimeoutSec 30
        $state['pane'] = $session.PaneSessionId
        if (-not (Wait-AgentReady -App $state.app -PaneSessionId $state.pane -TimeoutSec 60)) {
            throw 'The real provider did not become ready.'
        }
        $session = Get-AgentPaneSession -App $state.app -PaneSessionId $state.pane
        $label = Get-UiElement -App $state.app -Selector AgentLabelText
        if (-not $label -or $label.name -notmatch 'Copilot') { throw 'The selected provider is not Copilot.' }
        $state['initialProviderHeader'] = $label.name
        $state['layout'] = Enable-TestWindowEnglishKeyboardLayout -App $state.app
        Invoke-WtCli -App $state.app -Arguments @('focus-pane', '-t', $state.pane) | Out-Null
        if (-not (Set-WtWindowForeground -App $state.app)) { throw 'The owned window cannot acquire foreground.' }
        $state['marker'] = 'TDD_' + [guid]::NewGuid().ToString('N')
        $state['file'] = Join-Path $state.workspace 'result.txt'
        $state['command'] = "[System.IO.File]::WriteAllText('result.txt', '$($state.marker)', [System.Text.UTF8Encoding]::new(`$false))"
        $state['prompt'] = "In the current workspace run exactly this PowerShell command, and no other commands: $($state.command)"
        Set-Clipboard -Value $state.prompt
        Send-WtWindowKey -App $state.app -Vk 0x56 -Ctrl -RequireForeground | Out-Null
        if (-not (Test-Until -TimeoutSec 10 -IntervalSec 0.2 -Condition {
            (Get-AgentPaneText -App $state.app -PaneSessionId $state.pane).Contains($state.marker)
        })) { throw 'The complete draft did not reach the owned Agent Pane.' }
        $sentinel = [guid]::NewGuid().ToString('N')
        Set-Clipboard -Value $sentinel
        Send-WtWindowKey -App $state.app -Vk 0x41 -Ctrl -RequireForeground | Out-Null
        Send-WtWindowKey -App $state.app -Vk 0x43 -Ctrl -RequireForeground | Out-Null
        $copied = Wait-Until -TimeoutSec 5 -IntervalSec 0.2 -Condition {
            $value = Get-Clipboard -Raw
            if ($value -cne $sentinel) { $value }
        }
        if (-not [string]::Equals($copied, $state.prompt, [StringComparison]::Ordinal)) {
            throw 'The exact prepared draft does not match the intended submission.'
        }
        Send-WtWindowKey -App $state.app -Vk 0x27 -RequireForeground | Out-Null
        Save-UiScreenshot -App $state.app -Path (Join-Path $context.outDir 'before-submit.png') | Out-Null
        $copied | Set-Content (Join-Path $context.outDir 'submitted.txt') -NoNewline -Encoding utf8
        @{ provider = 'copilot'; sessionId = $session.AcpSessionId
            eventsPath = (Join-Path $HOME ".copilot\session-state\$($session.AcpSessionId)\events.jsonl")
            expectedPrompt = $state.prompt; allowedCommands = @($state.command) }
    }
    Submit = {
        param($context)
        Import-Module (Join-Path $context.repoRoot 'test\e2e\ItE2E\ItE2E.psd1') -Global
        Send-WtWindowKey -App $context.state.app -Vk 0x0D -RequireForeground | Out-Null
    }
    HandleAction = {
        param($context, $action)
        Import-Module (Join-Path $context.repoRoot 'test\e2e\ItE2E\ItE2E.psd1') -Global
        $state = $context.state
        if (-not [string]::Equals($action.command, $state.command, [StringComparison]::Ordinal)) {
            throw 'The pending command is outside the marker task.'
        }
        $text = Get-AgentPaneText -App $state.app -PaneSessionId $state.pane -MaxLines 200
        if ($action.kind -eq 'permission' -and $text -match '\[Y(?:/N)?\]') {
            Send-WtWindowKey -App $state.app -Vk 0x59 -RequireForeground | Out-Null
        }
        elseif ($action.kind -eq 'commandProposal' -and $text -match (Get-RecommendationCardRegex)) {
            Save-UiScreenshot -App $state.app -Path (Join-Path $context.outDir 'command-confirmation.png') | Out-Null
            Send-WtWindowKey -App $state.app -Vk 0x0D -RequireForeground | Out-Null
        }
        else { return 'pending' }
        'performed'
    }
    Verify = {
        param($context)
        Import-Module (Join-Path $context.repoRoot 'test\e2e\ItE2E\ItE2E.psd1') -Global
        $state = $context.state
        if (-not (Test-Path -LiteralPath $state.file)) { return @{ status = 'pending' } }
        $actual = [IO.File]::ReadAllText($state.file)
        $actual | Set-Content (Join-Path $context.outDir 'observed-file.txt') -NoNewline -Encoding utf8
        Save-UiScreenshot -App $state.app -Path (Join-Path $context.outDir 'real-result.png') | Out-Null
        @{ status = $(if ([string]::Equals($actual, $state.marker, [StringComparison]::Ordinal)) { 'passed' } else { 'failed' })
            expected = $state.marker; actual = $actual }
    }
    Cleanup = {
        param($context)
        $state = $context.state
        if ($state['target']) { Import-Module (Join-Path $context.repoRoot 'test\e2e\ItE2E\ItE2E.psd1') -Global }
        try {
            try {
                if ($state['layout']) {
                    . (Join-Path $context.repoRoot 'test\e2e\tests\helpers\TestWindowKeyboardLayout.ps1')
                    Restore-TestWindowKeyboardLayout -App $state.app -Context $state.layout
                }
            }
            finally {
                if ($state['app']) { Stop-Terminal -App $state.app }
                elseif ($state['launchStarted']) {
                    foreach ($process in @(Get-WtProcessesForApp -App $state.target)) {
                        if ($process.Path -ine $state.target.WindowsTerminal -or $process.StartTime -lt $state.launchStarted) {
                            throw 'Cannot prove ownership of a failed-startup process.'
                        }
                        $recovery = $state.target.PSObject.Copy()
                        $recovery.Pid = $process.Id
                        $recovery | Add-Member -NotePropertyName Launched -NotePropertyValue $true -Force
                        Stop-Terminal -App $recovery -RestoreSettings $false
                    }
                    Restore-WtConfig -App $state.target
                }
            }
        }
        finally {
            if ($state.ContainsKey('clipboard')) { Restore-ClipboardSnapshot -Snapshot $state.clipboard }
            if ($state['workspace'] -and (Test-Path -LiteralPath $state.workspace)) {
                $resolved = [IO.Path]::GetFullPath($state.workspace)
                if ((Split-Path $resolved -Parent) -ine [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
                    (Split-Path $resolved -Leaf) -notmatch '^ItE2E-real-marker-[a-f0-9]{32}$') {
                    throw 'Disposable workspace cleanup target is invalid.'
                }
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
        foreach ($item in $state['configuration']) {
            $actual = if (Test-Path -LiteralPath $item.path) { (Get-FileHash $item.path).Hash } else { $null }
            if ($actual -ne $item.hash) { throw 'Product configuration was not restored.' }
        }
        $true
    }
}
