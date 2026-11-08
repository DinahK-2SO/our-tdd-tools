#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeDiscovery {
    $script:AgentInputReady = [bool](
        (Get-AppxPackage | Where-Object { $_.Name -like '*IntelligentTerminal*' }) -and
        (Get-Command pwsh -ErrorAction SilentlyContinue) -and
        (Get-Command winapp -ErrorAction SilentlyContinue)
    )
}

Describe 'Local TDD agent input capability' -Tag 'AgentInput' -Skip:(-not $script:AgentInputReady) {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        $fixture = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-AcpEchoAgent.ps1')).Path
        $invocation = "& '$($fixture.Replace("'", "''"))'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
        $command = "pwsh -NoProfile -EncodedCommand $encoded"

        $script:app = Start-Terminal -Package (Get-ItTestPackage) -PassFre $true -CloseExistingInstances -Settings @{
            acpAgent = 'custom:local-tdd-echo'
            acpCustomCommand = $command
        }
        $shell = Get-ActivePane -App $script:app
        Open-AgentPane -App $script:app | Out-Null
        $script:agentPane = (Wait-NewAgentPaneSession -App $script:app -OwnerPaneSessionId $shell.session_id -TimeoutSec 30).PaneSessionId
        Wait-AgentReady -App $script:app -PaneSessionId $script:agentPane -TimeoutSec 60 |
            Should -BeTrue -Because 'the deterministic local ACP fixture must connect without external authentication'
    }

    AfterAll {
        if ($script:app) { Stop-Terminal -App $script:app }
    }

    It 'types a draft in agent chat and submits it with Enter' {
        $marker = "LOCAL_TDD_PROMPT_$([guid]::NewGuid().ToString('N'))"
        Send-AgentPrompt -App $script:app -PaneSessionId $script:agentPane -Text $marker -NoSubmit | Out-Null

        (Test-Until -TimeoutSec 10 -IntervalSec 0.2 -Condition {
                (Get-AgentPaneText -App $script:app -PaneSessionId $script:agentPane -MaxLines 40) -match [regex]::Escape($marker)
            }) | Should -BeTrue -Because 'the draft must be visible before submission'

        Send-AgentKey -App $script:app -PaneSessionId $script:agentPane -Key Enter | Out-Null
        Assert-AgentPaneText -App $script:app -PaneSessionId $script:agentPane `
            -Pattern ([regex]::Escape("LOCAL_TDD_ECHO:$marker")) -TimeoutSec 20
    }
}