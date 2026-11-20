function Resolve-LocalTddDevFamily {
    param([Parameter(Mandatory)][string]$Selector)
    if ($Selector -in 'Dev', 'IntelligentTerminal_rd9vj3e6a2mbr') { return 'IntelligentTerminal_rd9vj3e6a2mbr' }
    if ($Selector -cmatch '^IntelligentTerminal\.Worktree\.[A-Za-z][A-Za-z0-9]{0,20}_rd9vj3e6a2mbr$') { return $Selector }
    throw "Expected Dev or an explicit private Dev package family, not '$Selector'."
}

function Assert-LocalTddRemoteHead {
    param([string]$RepoRoot, [System.Collections.IDictionary]$Publication, [string]$ExpectedHead)
    if ($Publication.head -ne $ExpectedHead -or $ExpectedHead -notmatch '^[a-fA-F0-9]{40}$' -or
        $Publication.remote -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or
        $Publication.repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -or
        $Publication.pullRequest -notmatch '^[1-9][0-9]*$' -or -not $Publication.branch) { throw 'Invalid publication identity.' }
    & git -C $RepoRoot check-ref-format --branch $Publication.branch | Out-Null
    if ($LASTEXITCODE) { throw 'Invalid publish branch.' }
    $remote = @(& git -C $RepoRoot ls-remote -- $Publication.remote "refs/heads/$($Publication.branch)")
    if ($LASTEXITCODE -or $remote.Count -ne 1 -or ($remote[0] -split '\s+')[0] -ne $ExpectedHead) {
        throw 'Remote publish HEAD differs from the source.'
    }
    $raw = & gh pr view $Publication.pullRequest --repo $Publication.repository --json headRefOid,state
    if ($LASTEXITCODE) { throw 'Cannot verify the PR HEAD.' }
    $pr = $raw | ConvertFrom-Json
    if ($pr.headRefOid -ne $ExpectedHead -or $pr.state -ne 'OPEN') { throw 'The PR no longer matches the open published iteration.' }
}

function Get-ItPrivateProtocolClsid {
    param([Parameter(Mandatory)]$Package)
    $family = Resolve-LocalTddDevFamily $Package.PackageFamilyName
    $manifest = Get-AppxPackageManifest -Package $Package.PackageFullName -ErrorAction Stop
    if ($family -cne "$($Package.Name)_rd9vj3e6a2mbr" -or $Package.Name -cnotlike 'IntelligentTerminal.Worktree.*' -or
        $manifest.Package.Identity.Name -cne $Package.Name -or $manifest.Package.Identity.Publisher -cne 'CN=Intelligent Terminal Dev' -or
        $Package.Publisher -cne $manifest.Package.Identity.Publisher) { throw 'Private Dev registration and manifest identity differ.' }
    $classes = @($manifest.SelectNodes("//*[local-name()='Application' and @Id='App' and @Executable='WindowsTerminal.exe']//*[local-name()='ExeServer' and @Executable='WindowsTerminal.exe']/*[local-name()='Class']"))
    if ($classes.Count -ne 1) { throw 'Expected one private Terminal COM server.' }
    $guid = [guid]$classes[0].Id
    if ($guid -in @([guid]::Empty, [guid]'D5B7C9E1-4F6A-4B8C-D9E0-F1A2B3C4D5E6',
        [guid]'A2E4F6B8-1C3D-4E5F-A6B7-C8D9E0F1A2B3', [guid]'B3F5A7C9-2D4E-4F6A-B7C8-D9E0F1A2B3C4',
        [guid]'C4A6B8D0-3E5F-4A7B-C8D9-E0F1A2B3C4D5')) { throw 'Expected a private, non-brand COM class.' }
    $clsid = $guid.ToString('B')
    $owners = @(Get-ChildItem -LiteralPath "Registry::HKEY_CLASSES_ROOT\PackagedCom\ClassIndex\$clsid" -ErrorAction Stop)
    if ($owners.Count -ne 1 -or $owners[0].PSChildName -cne $Package.PackageFullName) {
        throw 'Private Dev does not exclusively own its protocol CLSID.'
    }
    return $clsid
}
