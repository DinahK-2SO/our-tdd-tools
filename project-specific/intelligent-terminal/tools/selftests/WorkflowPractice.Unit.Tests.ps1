#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

Describe 'TDD practice and test admission contract' -Tag 'Unit' {
    BeforeAll {
        $kit = Split-Path -Parent $PSScriptRoot
        $script:boundaries = Get-Content -LiteralPath (Join-Path $kit 'TEST-BOUNDARIES.md') -Raw
        $script:workflow = Get-Content -LiteralPath (Join-Path $kit 'TDD-WORKFLOW.template.md') -Raw
        $script:readme = Get-Content -LiteralPath (Join-Path $kit 'README.md') -Raw
        $script:deployment = Get-Content -LiteralPath (Join-Path $kit 'BUILD-DEPLOY-E2E.md') -Raw
    }

    It 'excludes real authentication dependencies even for zero-token checks' {
        $script:boundaries | Should -Match 'Publish tests must not depend on real login'
        $script:boundaries | Should -Match 'even zero-token'
        $script:boundaries | Should -Match 'indirect calls'
        $script:boundaries | Should -Match 'unit tests must not require a real provider CLI installation'
    }

    It 'distinguishes publication eligibility from execution environment' {
        $script:boundaries | Should -Match 'publication eligibility'
        $script:boundaries | Should -Match 'execution environment'
        $script:boundaries | Should -Match 'Mock-provider packaged UI'
        $script:boundaries | Should -Match 'configured jobs'
    }

    It 'makes packaged workflow documents reference the same test boundary' {
        foreach ($document in @($script:workflow, $script:readme, $script:deployment)) {
            $document | Should -Match 'TEST-BOUNDARIES\.md'
        }
    }

    It 'records applicability instead of unconditionally demanding inference for every head' {
        $script:workflow | Should -Match 'REAL_ACCEPTANCE_REQUIRED'
        $script:workflow | Should -Not -Match ([regex]::Escape(
            'Every initial PR publication and subsequent published iteration must pass this gate'))
    }

    It 'keeps preparation and discussion pauses distinct from accepted product behavior' {
        $script:workflow | Should -Match 'PREPARATION'
        $script:workflow | Should -Match 'PAUSED_USER_DISCUSSION'
        $script:boundaries | Should -Match 'Preparation completion is not product completion|Preparation and paused discussion'
        $script:boundaries | Should -Match 'generic completion reminder'
    }

    It 'keeps explicit skip and review dispositions from becoming fabricated passes' {
        $script:boundaries | Should -Match 'passed_with_skips'
        $script:boundaries | Should -Match 'no executed tests'
        $script:boundaries | Should -Match 'not shared-account reply counts'
    }

    It 'keeps PR descriptions focused on product changes rather than internal progress' {
        $script:workflow | Should -Match 'Write PR descriptions in concise English'
        $script:workflow | Should -Match 'what changes and how it works'
        $script:workflow | Should -Match 'Internal progress, unfinished-work notes, cost or authorization decisions'
        $script:workflow | Should -Match 'actual commands and results'
    }

    It 'does not add a per-description approval gate to an existing PR delivery task' {
        $script:workflow | Should -Match 'Within an already requested PR-delivery task'
        $script:workflow | Should -Match 'Do not wait for per-description wording approval or confirmation'
        $script:workflow | Should -Match 'Preserve teammate edits'
        $script:readme | Should -Match 'without a separate wording-approval gate'
    }
}
