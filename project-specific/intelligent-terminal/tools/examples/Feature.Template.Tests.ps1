#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeDiscovery {
    $script:Ready = [bool](
        (Get-AppxPackage | Where-Object { $_.Name -like '*IntelligentTerminal*' }) -and
        (Get-Command winapp -ErrorAction SilentlyContinue)
    )
}

Describe '<ISSUE>: <USER-VISIBLE CONTRACT>' -Tag 'LocalFeature' -Skip:(-not $script:Ready) {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        $script:app = Start-Terminal -Package (Get-ItTestPackage) -PassFre $true -CloseExistingInstances -Settings @{
            # <ADD ONLY SETTINGS REQUIRED BY THIS TEST>
        }
    }

    AfterAll {
        if ($script:app) { Stop-Terminal -App $script:app }
    }

    It '<OBSERVABLE BEHAVIOR>' {
        $identity = Get-WtWindowIdentity -App $script:app
        $identity.ProcessId | Should -Be $script:app.Pid

        # Prefer a deterministic product-owned oracle:
        # protocol/event -> persisted state -> structured log -> rendered UI -> model output.
        # <ARRANGE>
        # <ACT>
        # <ASSERT>
        Set-ItResult -Skipped -Because 'Replace the placeholders before running this template.'
    }
}