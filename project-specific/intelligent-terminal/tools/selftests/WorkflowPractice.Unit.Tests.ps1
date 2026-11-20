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

    It 'distinguishes mandatory published-head smoke from optional feature-specific scenarios' {
        $workflow = $script:workflow -replace '\s+', ' '
        $workflow | Should -Match 'docs-only and test-only'
        $workflow | Should -Match 'REAL_ACCEPTANCE_REQUIRED.{0,160}additional'
        $workflow | Should -Match 'superseded-by\.txt'
    }

    It 'keeps preparation and discussion pauses distinct from accepted product behavior' {
        $script:workflow | Should -Match 'PREPARATION'
        $script:workflow | Should -Match 'PAUSED_USER_DISCUSSION'
        $script:boundaries | Should -Match 'Preparation completion is not product completion|Preparation and paused discussion'
        $script:boundaries | Should -Match 'generic completion reminder'
    }

    It 'allows local tests before publication and a draft PR before validation finishes' {
        $workflow = $script:workflow -replace '\s+', ' '
        $workflow | Should -Match 'before a PR exists.*local revision'
        $workflow | Should -Match 'open a draft PR.*local validation.*still pending'
        $workflow | Should -Not -Match 'once the publish branch is clean and has deterministic RED/GREEN'
    }

    It 'keeps explicit skip and review dispositions from becoming fabricated passes' {
        $script:boundaries | Should -Match 'passed_with_skips'
        $script:boundaries | Should -Match 'no executed tests'
        $script:boundaries | Should -Match 'not shared-account reply counts'
    }

    It 'keeps PR descriptions focused on product changes rather than internal progress' {
        $script:workflow | Should -Match 'selected user profile'
        $script:workflow | Should -Match 'what changes and how it works'
        $script:workflow | Should -Match 'Internal progress, unfinished-work notes, cost or authorization decisions'
        $script:workflow | Should -Match 'actual commands and results'
        $script:workflow | Should -Not -Match 'title is at most \d+ words'
    }

    It 'uses selected review preferences without granting public-write authority' {
        $script:workflow | Should -Match 'Within an already requested PR-delivery task'
        $script:workflow | Should -Match 'explicit approval requirements'
        $script:workflow | Should -Match 'Preserve teammate edits'
        $script:workflow | Should -Not -Match 'The only permitted review comment is'
        $script:readme | Should -Match 'selected user profile'
    }
}
