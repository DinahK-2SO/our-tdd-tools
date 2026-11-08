#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\LocalTdd.Acceptance.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\LocalTdd.Evidence.psm1') -Force
    function Save-FixtureEvidence([string]$Name, $Value) {
        $path = Join-Path $script:evidenceRoot $Name
        Write-LocalTddEvidenceJson -Path $path -Value $Value
        @{ path = $path; sha256 = (Get-FileHash $path).Hash }
    }
    function Save-FixtureContract {
        Write-LocalTddEvidenceJson -Path $script:contractPath -Value $script:contract
    }
}

Describe 'Current-head acceptance evidence contract' -Tag 'Unit', 'AcceptanceEvidence' {
    BeforeEach {
        $script:evidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:evidenceRoot | Out-Null
        $script:head = 'a' * 40
        $time = [DateTimeOffset]::UtcNow.AddMinutes(-10)
        $script:publication = @{ head = $script:head; pushedUtc = $time.ToString('o') }
        $script:receipt = @{ gitHead = $script:head; installVerified = $true; hashes = @{ wta = 'b' * 64 }
            buildStartedUtc = $time.AddSeconds(1).ToString('o'); createdUtc = $time.AddSeconds(2).ToString('o') }
        $receiptRef = Save-FixtureEvidence 'receipt.json' $script:receipt
        $script:real = @{
            kind = 'real-user'; head = $script:head; status = 'passed'; cleanupPassed = $true
            startedUtc = $time.AddSeconds(3).ToString('o'); submittedUtc = $time.AddSeconds(4).ToString('o')
            completedUtc = $time.AddSeconds(5).ToString('o'); submissionAttempted = $true; promptsObserved = 1
            provider = 'copilot'; model = 'offline-model'; wtaSha256 = 'b' * 64; receiptSha256 = $receiptRef.sha256
            observable = @{ status = 'passed'; expected = 'marker'; actual = 'marker' }
        }
        $script:resultPath = Join-Path $script:evidenceRoot 'results.xml'
        '<test-results><test-case name="Feature.exact case" result="Success" executed="True" /></test-results>' |
            Set-Content $script:resultPath
        $resultHash = (Get-FileHash $script:resultPath).Hash
        $script:provenance = @{
            status = 'passed'; gitHead = $script:head
            receiptSha256 = $receiptRef.sha256; e2eResultsSha256 = $resultHash
        }
        $frame = Join-Path $script:evidenceRoot 'offline-frame.png'
        'Synthetic bytes, not a real screenshot or inspection.' | Set-Content $frame
        $frameRef = @{ path = $frame; sha256 = (Get-FileHash $frame).Hash }
        $script:inventory = @{
            head = $script:head
            images = @(@{
                path = $frame; sha256 = $frameRef.sha256; actual_pixels_available = $true
                inspection_status = 'PASS'; visual_integrity_status = 'PASS'
            })
        }
        $script:review = @{
            schemaVersion = 2
            data = [ordered]@{
                pullRequest = @{
                    headRefOid = $script:head; reviewDecision = 'REVIEW_REQUIRED'
                    reviews = @(@{ id = 'offline-review'; commit = @{ oid = $script:head } })
                    statusCheckRollup = @(@{
                        status = 'COMPLETED'; conclusion = 'SUCCESS'; annotations = @(); annotationsCount = 0
                    })
                }
                viewer = 'fixture-user'
                threads = @(@{ isResolved = $false; comments = @{ nodes = @(@{ author = @{ login = 'fixture-user' } }) } })
            }
        }
        $script:review.dataSha256 = Get-LocalTddObjectHash $script:review.data
        $script:contract = @{
            schemaVersion = 1; head = $script:head
            publication = (Save-FixtureEvidence 'publication.json' $script:publication)
            receipt = $receiptRef
            realAcceptance = (Save-FixtureEvidence 'real.json' $script:real)
            requiredTests = @('Feature.exact case')
            results = @(@{ path = $script:resultPath; sha256 = $resultHash
                provenance = (Save-FixtureEvidence 'pipeline.json' $script:provenance) })
            visual = @{ required = $true; requiredFrames = @($frameRef)
                inventories = @((Save-FixtureEvidence 'visual.json' $script:inventory)) }
            reviewSnapshot = (Save-FixtureEvidence 'review.json' $script:review)
            reviewTriage = @{
                complete = $true; noNewFindings = $true; annotationsTriaged = $true
                reviewId = 'offline-review'; snapshotSha256 = $script:review.dataSha256
            }
        }
        $script:contractPath = Join-Path $script:evidenceRoot 'contract.json'
        Save-FixtureContract
    }

    It 'validates evidence without pretending an offline check verified current remote state' {
        $result = Test-LocalTddAcceptanceEvidence -ContractPath $script:contractPath
        $result.status | Should -Be 'passed'
        $result.evidenceOnly | Should -BeTrue
        $result.currentDeploymentVerified | Should -BeFalse
        $result.testsPassed | Should -Be 1
        $result.originalsInspected | Should -Be 1
        $result.humanApprovalRequired | Should -BeTrue
    }

    It 'rejects stale head bindings even when every referenced file hash is updated' {
        $script:real.head = 'c' * 40
        $script:contract.realAcceptance = Save-FixtureEvidence 'real.json' $script:real
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*identities differ*'
    }

    It 'rejects a build that preceded the push' {
        $script:publication.pushedUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        $script:contract.publication = Save-FixtureEvidence 'publication.json' $script:publication
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*post-push ordering*'
    }

    It 'requires observed inference, exact values and successful cleanup' {
        foreach ($field in 'promptsObserved', 'cleanupPassed') {
            $old = $script:real[$field]
            $script:real[$field] = 0
            $script:contract.realAcceptance = Save-FixtureEvidence 'real.json' $script:real
            Save-FixtureContract
            { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*incomplete*'
            $script:real[$field] = $old
        }
    }

    It 'requires all exact case names rather than a passing total' {
        $script:contract.requiredTests += 'Feature.missing case'
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*Required test*'
    }

    It 'rejects truthy strings instead of treating them as inspected pixels' {
        $script:inventory.images[0].actual_pixels_available = 'true'
        $script:contract.visual.inventories = @((Save-FixtureEvidence 'visual.json' $script:inventory))
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*uninspected*'
    }

    It 'does not relabel an old report with a newer deployment' {
        $script:provenance.gitHead = 'c' * 40
        $script:contract.results[0].provenance = Save-FixtureEvidence 'pipeline.json' $script:provenance
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*provenance*'
    }

    It 'rejects unviewed or altered screenshot evidence' {
        $script:inventory.images[0].actual_pixels_available = $false
        $script:contract.visual.inventories = @((Save-FixtureEvidence 'visual.json' $script:inventory))
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*uninspected*'
        $script:inventory.images[0].actual_pixels_available = $true
        $script:contract.visual.inventories = @((Save-FixtureEvidence 'visual.json' $script:inventory))
        Save-FixtureContract
        'changed frame' | Add-Content $script:inventory.images[0].path
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*hash mismatch*'
    }

    It 'requires a review at this head and an explicit annotation disposition' {
        $script:contract.reviewTriage.annotationsTriaged = $false
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*triage*'
        $script:contract.reviewTriage.annotationsTriaged = $true
        $script:contract.reviewTriage.reviewId = 'not-reviewed'
        Save-FixtureContract
        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*review is not at this head*'
    }

    It 'does not require shared-account replies after complete current-head triage' {
        $script:review.data.threads[0].comments.nodes = @(
            @{ author = @{ login = 'independent-reviewer' }; body = 'Retained review discussion.' }
        )
        $script:review.dataSha256 = Get-LocalTddObjectHash $script:review.data
        $script:contract.reviewSnapshot = Save-FixtureEvidence 'review.json' $script:review
        $script:contract.reviewTriage.snapshotSha256 = $script:review.dataSha256
        Save-FixtureContract

        $result = Test-LocalTddAcceptanceEvidence -ContractPath $script:contractPath
        $result.status | Should -Be 'passed'
        $result.humanApprovalRequired | Should -BeTrue
        $script:review.data.threads[0].isResolved | Should -BeFalse
    }

    It 'still rejects untriaged findings regardless of reply authorship' {
        $script:contract.reviewTriage.noNewFindings = $false
        Save-FixtureContract

        { Test-LocalTddAcceptanceEvidence $script:contractPath } |
            Should -Throw '*Current-head review triage is incomplete*'
    }

    It 'rejects declared annotation triage without the captured annotation inventory' {
        $script:review.data.pullRequest.statusCheckRollup[0].Remove('annotations')
        $script:review.dataSha256 = Get-LocalTddObjectHash $script:review.data
        $script:contract.reviewSnapshot = Save-FixtureEvidence 'review.json' $script:review
        $script:contract.reviewTriage.snapshotSha256 = $script:review.dataSha256
        Save-FixtureContract

        { Test-LocalTddAcceptanceEvidence $script:contractPath } | Should -Throw '*annotation inventory*'
    }

    It 'rechecks current deployment and review before writing final acceptance' {
        Mock -ModuleName LocalTdd.Evidence Assert-LocalTddPublishedDeployment { @{} }
        Mock -ModuleName LocalTdd.Evidence Get-LocalTddReviewSnapshot { $script:review }
        $out = Join-Path $script:evidenceRoot 'accepted.json'
        $result = Complete-LocalTddAcceptance -RepoRoot $script:evidenceRoot -ContractPath $script:contractPath -OutPath $out
        $result.currentDeploymentVerified | Should -BeTrue
        $result.currentReviewVerified | Should -BeTrue
        Test-Path $out | Should -BeTrue
        Should -Invoke -ModuleName LocalTdd.Evidence Assert-LocalTddPublishedDeployment -Times 1
        Mock -ModuleName LocalTdd.Evidence Get-LocalTddReviewSnapshot { @{ dataSha256 = '0' * 64 } }
        { Complete-LocalTddAcceptance -RepoRoot $script:evidenceRoot -ContractPath $script:contractPath `
            -OutPath (Join-Path $script:evidenceRoot 'not-accepted.json') } | Should -Throw '*changed after triage*'
    }
}

Describe 'Complete review snapshots' -Tag 'Unit', 'AcceptanceEvidence' {
    BeforeEach {
        $script:evidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:evidenceRoot | Out-Null
        $publicationRef = Save-FixtureEvidence 'publication.json' @{
            repository = 'example/project'; pullRequest = 1
        }
        $script:publicationPath = $publicationRef.path
        $script:remoteSnapshot = @{
            data = @{
                viewer = @{ login = 'fixture-user' }
                repository = @{
                    pullRequest = @{
                        headRefOid = 'a' * 40; state = 'OPEN'; reviewDecision = 'REVIEW_REQUIRED'
                        reviews = @{
                            pageInfo = @{ hasNextPage = $false }
                            nodes = @(@{
                                id = 'offline-review'; commit = @{ oid = 'a' * 40 }
                                body = "No open issues`n<details>Retained finding details</details>"
                            })
                        }
                        statusCheckRollup = @{
                            contexts = @{
                                pageInfo = @{ hasNextPage = $false }
                                nodes = @(@{
                                    __typename = 'CheckRun'; databaseId = 123; name = 'Spelling'
                                    status = 'COMPLETED'; conclusion = 'SUCCESS'
                                    checkSuite = @{ repository = @{ nameWithOwner = 'example/project' } }
                                    annotations = @{ totalCount = 2 }
                                })
                            }
                        }
                        reviewThreads = @{
                            pageInfo = @{ hasNextPage = $false }
                            nodes = @(@{
                                id = 'offline-thread'; isResolved = $false
                                comments = @{
                                    pageInfo = @{ hasNextPage = $false }
                                    nodes = @(@{ body = 'Retained discussion.' })
                                }
                            })
                        }
                    }
                }
            }
        }
        $script:annotationResponse = @'
[
  [{"path":"README.md","start_line":1,"end_line":1,"annotation_level":"warning","message":"First warning"}],
  [{"path":"README.md","start_line":2,"end_line":2,"annotation_level":"warning","message":"Second warning"}]
]
'@
        $script:annotationExitCode = 0
        $script:closingState = 'OPEN'
        Mock -ModuleName LocalTdd.Evidence gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'api' -and $args[1] -eq 'graphql') {
                return $script:remoteSnapshot | ConvertTo-Json -Depth 32
            }
            if ($args[0] -eq 'api' -and
                $args -contains 'repos/example/project/check-runs/123/annotations?per_page=100') {
                if ($args -notcontains '--paginate' -or $args -notcontains '--slurp') {
                    throw 'Annotation pagination was not requested.'
                }
                $global:LASTEXITCODE = $script:annotationExitCode
                return $script:annotationResponse
            }
            if ($args[0] -eq 'pr' -and $args[1] -eq 'view') {
                $pr = $script:remoteSnapshot.data.repository.pullRequest
                return @{
                    headRefOid = $pr.headRefOid; state = $script:closingState
                    reviewDecision = $pr.reviewDecision; reviews = $pr.reviews.nodes
                    statusCheckRollup = $pr.statusCheckRollup.contexts.nodes
                } | ConvertTo-Json -Depth 32
            }
            throw "Unexpected GitHub fixture command: $args"
        }
    }

    It 'binds all annotation pages and the complete review body even when checks stay green' {
        $first = Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath
        $first.data.pullRequest.statusCheckRollup[0].annotations.Count | Should -Be 2
        $first.data.pullRequest.reviews[0].body | Should -Match '<details>Retained finding details</details>'
        $first.data.threads[0].isResolved | Should -BeFalse

        $script:annotationResponse = $script:annotationResponse.Replace('Second warning', 'Changed warning')
        $second = Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath
        $second.dataSha256 | Should -Not -Be $first.dataSha256
    }

    It 'rejects incomplete <Collection> pagination' -ForEach @(
        @{ Collection = 'reviews' }
        @{ Collection = 'checks' }
    ) {
        $pr = $script:remoteSnapshot.data.repository.pullRequest
        if ($Collection -eq 'reviews') { $pr.reviews.pageInfo.hasNextPage = $true }
        else { $pr.statusCheckRollup.contexts.pageInfo.hasNextPage = $true }

        { Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath } | Should -Throw '*pagination*'
    }

    It 'rejects annotation retrieval errors instead of substituting an empty inventory' {
        $script:annotationExitCode = 1
        { Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath } | Should -Throw '*annotation retrieval failed*'
    }

    It 'rejects a malformed annotation response even with a zero command exit' {
        $script:annotationResponse = '{"message":"Unavailable"}'
        { Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath } | Should -Throw '*annotation response*'
    }

    It 'rejects a truncated annotation inventory even when its JSON is valid' {
        $script:annotationResponse = '[[]]'
        { Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath } | Should -Throw '*annotation inventory*'
    }

    It 'reads annotations from the check owner rather than assuming the pull request repository' {
        $script:remoteSnapshot.data.repository.pullRequest.statusCheckRollup.contexts.nodes[0].checkSuite.repository.nameWithOwner = 'example/checks'
        Mock -ModuleName LocalTdd.Evidence gh {
            $global:LASTEXITCODE = 0
            $script:annotationResponse.Replace('First warning', 'Fork warning')
        } -ParameterFilter { $args -contains 'repos/example/checks/check-runs/123/annotations?per_page=100' }

        $snapshot = Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath
        $snapshot.data.pullRequest.statusCheckRollup[0].annotations[0].message | Should -Be 'Fork warning'
    }

    It 'preserves nullable API fields instead of inventing annotation text' {
        $script:annotationResponse = '[[{"path":"README.md","annotation_level":null,"message":null}]]'
        $script:remoteSnapshot.data.repository.pullRequest.statusCheckRollup.contexts.nodes[0].annotations.totalCount = 1
        $snapshot = Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath
        $snapshot.data.pullRequest.statusCheckRollup[0].annotations.Count | Should -Be 1
        $snapshot.data.pullRequest.statusCheckRollup[0].annotations[0].message | Should -BeNullOrEmpty
    }

    It 'retains an explicitly empty annotation inventory' {
        $script:annotationResponse = '[[]]'
        $script:remoteSnapshot.data.repository.pullRequest.statusCheckRollup.contexts.nodes[0].annotations.totalCount = 0
        $snapshot = Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath
        $snapshot.data.pullRequest.statusCheckRollup[0].Contains('annotations') | Should -BeTrue
        $snapshot.data.pullRequest.statusCheckRollup[0].annotations.Count | Should -Be 0
    }

    It 'rejects a lifecycle transition during collection instead of returning an open snapshot' {
        $script:closingState = 'MERGED'
        { Get-LocalTddReviewSnapshot -PublicationPath $script:publicationPath } | Should -Throw '*changed while*'
    }
}
