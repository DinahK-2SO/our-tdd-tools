function Get-WinpdReviewSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicationPath)
    $publication = Get-Content -LiteralPath $PublicationPath -Raw | ConvertFrom-Json -AsHashtable
    if ($publication.repository -notmatch '^([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)$' -or
        $publication.pullRequest -notmatch '^[1-9][0-9]*$') { throw 'Review target is invalid.' }
    $parts = $publication.repository.Split('/')
    $query = @'
query($owner: String!, $repo: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      headRefOid state reviewDecision
      reviews(first: 100) {
        pageInfo { hasNextPage }
        nodes { id author { login } body state submittedAt commit { oid } }
      }
      statusCheckRollup {
        contexts(first: 100) {
          pageInfo { hasNextPage }
          nodes {
            __typename
            ... on CheckRun {
              id databaseId name status conclusion detailsUrl startedAt completedAt
              checkSuite { repository { nameWithOwner } }
              annotations { totalCount }
            }
            ... on StatusContext { id context state targetUrl createdAt description }
          }
        }
      }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id isResolved
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes { id author { login } body }
          }
        }
      }
    }
  }
}
'@
    $raw = & gh api graphql -f "query=$query" -f "owner=$($parts[0])" -f "repo=$($parts[1])" -F "number=$($publication.pullRequest)"
    if ($LASTEXITCODE -ne 0) { throw 'Review/check/thread retrieval failed.' }
    $response = $raw | ConvertFrom-Json -AsHashtable
    if ($response['errors']) { throw 'Review query returned GraphQL errors.' }
    $pr = $response.data.repository.pullRequest
    if ($pr -isnot [Collections.IDictionary] -or $pr.headRefOid -notmatch '^[a-fA-F0-9]{40}$' -or
        $pr.state -notin @('OPEN', 'CLOSED', 'MERGED') -or -not $pr.Contains('statusCheckRollup')) {
        throw 'Review query did not return a complete pull request identity.'
    }
    $collections = @($pr.reviews, $pr.reviewThreads)
    $checks = @()
    if ($null -ne $pr.statusCheckRollup) {
        $collections += $pr.statusCheckRollup.contexts
        $checks = @($pr.statusCheckRollup.contexts.nodes)
    }
    foreach ($thread in $pr.reviewThreads.nodes) { $collections += $thread.comments }
    foreach ($collection in $collections) {
        if ($collection -isnot [Collections.IDictionary] -or
            $collection.pageInfo.hasNextPage -isnot [bool] -or $collection.pageInfo.hasNextPage -or
            $collection.nodes -isnot [array]) {
            throw 'Review/check/thread snapshot is incomplete or needs explicit pagination.'
        }
    }
    foreach ($check in $checks) {
        if ($check.__typename -eq 'StatusContext') { continue }
        if ($check.__typename -ne 'CheckRun' -or $check.databaseId -notmatch '^[1-9][0-9]*$' -or
            $check.checkSuite.repository.nameWithOwner -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -or
            ($check.annotations.totalCount -isnot [int] -and $check.annotations.totalCount -isnot [long]) -or
            $check.annotations.totalCount -lt 0) {
            throw 'Check annotation identity or count is missing.'
        }
        $annotationCount = $check.annotations.totalCount
        $endpoint = "repos/$($check.checkSuite.repository.nameWithOwner)/check-runs/$($check.databaseId)/annotations?per_page=100"
        $rawAnnotations = & gh api --paginate --slurp $endpoint
        if ($LASTEXITCODE -ne 0) { throw "Check annotation retrieval failed: $($check.name)." }
        $pages = $rawAnnotations | ConvertFrom-Json -AsHashtable -NoEnumerate
        if ($pages -isnot [array] -or -not $pages.Count) { throw 'Check annotation response is not a complete page array.' }
        $annotations = [Collections.Generic.List[object]]::new()
        foreach ($page in $pages) {
            if ($page -isnot [array]) { throw 'Check annotation response contains an invalid page.' }
            foreach ($annotation in $page) {
                if ($annotation -isnot [Collections.IDictionary] -or $annotation.path -isnot [string] -or
                    -not $annotation.Contains('message') -or -not $annotation.Contains('annotation_level') -or
                    ($null -ne $annotation.message -and $annotation.message -isnot [string]) -or
                    ($null -ne $annotation.annotation_level -and $annotation.annotation_level -notin @('notice', 'warning', 'failure'))) {
                    throw 'Check annotation response contains an invalid annotation.'
                }
                $annotations.Add($annotation)
            }
        }
        if ($annotations.Count -ne $annotationCount) { throw 'Check annotation inventory changed or is incomplete; collect again.' }
        $check.annotations = $annotations.ToArray()
        $check.annotationsCount = $annotationCount
    }
    $threadRows = @($pr.reviewThreads.nodes)
    $pr.reviews = @($pr.reviews.nodes)
    $pr.statusCheckRollup = $checks
    [void]$pr.Remove('reviewThreads')
    $closingRaw = & gh pr view $publication.pullRequest --repo $publication.repository --json headRefOid,state
    if ($LASTEXITCODE -ne 0) { throw 'Closing review identity retrieval failed.' }
    $closing = $closingRaw | ConvertFrom-Json -AsHashtable
    if ($closing.headRefOid -ne $pr.headRefOid -or $closing.state -ne $pr.state) {
        throw 'Pull request head or lifecycle changed while collecting review evidence; collect again.'
    }
    $data = [ordered]@{ pullRequest = $pr; viewer = $response.data.viewer.login; threads = $threadRows }
    return @{ schemaVersion = 2; observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        data = $data; dataSha256 = (Get-WinpdEvidenceHash $data) }
}
