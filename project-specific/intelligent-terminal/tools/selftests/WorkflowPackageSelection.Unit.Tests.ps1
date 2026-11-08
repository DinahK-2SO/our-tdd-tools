#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

Describe 'TDD workflow package selection' -Tag 'Unit' {
    BeforeAll {
        $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\TDD-WORKFLOW.template.md') -Raw
    }

    It 'defaults PR validation to its exact-head Dev deployment without asking Dev or Store' {
        $workflow | Should -Match 'For an unshipped PR, default to `Dev` built and deployed from the exact publish HEAD'
        $workflow | Should -Match 'Do not ask merely to choose Dev or Store'
    }

    It 'pins Dev while reserving Store for an explicitly requested baseline' {
        $workflow | Should -Match '\$env:ITE2E_PACKAGE = ''Dev'''
        $workflow | Should -Match 'An already installed Dev package or `Auto` cannot establish PR freshness'
        $workflow | Should -Match 'Use Store only when the user explicitly requests a production baseline'
        $workflow | Should -Match 'Outside a PR,\s+ask if the target package is ambiguous'
    }

    It 'closes only an authorized Dev window while protecting Store, stock Terminal, and chat' {
        $workflow | Should -Match 'IntelligentTerminal_rd9vj3e6a2mbr'
        $workflow | Should -Match 'Microsoft.IntelligentTerminal_8wekyb3d8bbwe'
        $workflow | Should -Match 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'
        $workflow | Should -Match 'standing permission'
        $workflow | Should -Match 'ExecutablePath'
        $workflow | Should -Match 'CreationDate'
        $workflow | Should -Match 'current chat ancestry'
        $workflow | Should -Match 'Stop-Process -Id'
    }
}
