#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-WinpdGit {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )
    $lines = @(& git --no-optional-locks --no-pager -C $Root @Arguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AllowedExitCodes) {
        throw "Git '$($Arguments[0])' failed in '$Root' (exit $exitCode)."
    }
    return @{ ExitCode = $exitCode; Lines = $lines; Text = ($lines -join "`n") }
}

function Read-WinpdJson {
    param([Parameter(Mandatory)][string]$Path)
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($value -isnot [Collections.IDictionary]) { throw "Expected a JSON object: $Path" }
    return $value
}

function ConvertTo-WinpdCanonical {
    param([AllowNull()]$Value)
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        [string[]]$keys = @($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $result[$key] = ConvertTo-WinpdCanonical $Value[$key] }
        return $result
    }
    if ($Value -is [array] -or $Value -is [Collections.IList]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-WinpdCanonical $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function Get-WinpdHash {
    param([Parameter(Mandatory)]$Value)
    $text = ConvertTo-Json -InputObject (ConvertTo-WinpdCanonical $Value) -Depth 64 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

function Get-WinpdFullPath {
    param([string]$Path, [string]$Base = $PWD.ProviderPath)
    if (-not $Path) { $Path = $Base }
    $full = [IO.Path]::GetFullPath($Path, $Base)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-WinpdParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][Collections.IDictionary]$Schema,
        [Parameter(Mandatory)][Collections.IDictionary]$Defaults,
        [Collections.IDictionary]$Overrides = @{}
    )
    if ($Schema['type'] -ne 'object' -or $Schema['properties'] -isnot [Collections.IDictionary] -or
        $Schema['additionalProperties'] -isnot [bool] -or $Schema['additionalProperties']) {
        throw "Invalid parameter schema for $Namespace."
    }
    foreach ($key in @($Defaults.Keys) + @($Overrides.Keys)) {
        if (-not $Schema.properties.Contains($key)) { throw "Unknown $Namespace parameter: $key" }
    }
    $result = [ordered]@{}
    foreach ($key in @($Schema.properties.Keys | Sort-Object)) {
        if (-not $Defaults.Contains($key)) { throw "Missing $Namespace default: $key" }
        $value = if ($Overrides.Contains($key)) { $Overrides[$key] } else { $Defaults[$key] }
        $rule = $Schema.properties[$key]
        $validType = switch ($rule['type']) {
            'string' { $value -is [string] }
            'boolean' { $value -is [bool] }
            'integer' { $value -is [int] -or $value -is [long] }
            'array' { $value -is [array] }
            'object' { $value -is [Collections.IDictionary] }
            default { throw "Unsupported schema type for ${Namespace}.${key}." }
        }
        if (-not $validType) { throw "${Namespace}.${key} must have type $($rule.type)." }
        if ($rule.Contains('enum') -and $value -notin $rule.enum) { throw "Invalid ${Namespace}.${key} value." }
        if ($rule.Contains('pattern') -and $value -cnotmatch $rule.pattern) { throw "Invalid ${Namespace}.${key} format." }
        if ($rule.Contains('minLength') -and $value.Length -lt $rule.minLength) { throw "${Namespace}.${key} is too short." }
        if ($rule.Contains('minimum') -and $value -lt $rule.minimum) { throw "${Namespace}.${key} is below its minimum." }
        if ($rule.Contains('maximum') -and $value -gt $rule.maximum) { throw "${Namespace}.${key} is above its maximum." }
        if ($rule.type -eq 'array' -and $rule.Contains('items')) {
            foreach ($item in $value) {
                if ($rule.items['type'] -ne 'string' -or $item -isnot [string]) {
                    throw "${Namespace}.${key} requires string items."
                }
            }
        }
        $result[$key] = $value
    }
    return $result
}

function Get-WinpdRepository {
    param([string]$Directory)
    $directoryPath = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $root = Get-WinpdFullPath (Invoke-WinpdGit $directoryPath @('rev-parse', '--show-toplevel')).Text
    $commonDir = Get-WinpdFullPath (Invoke-WinpdGit $root @(
        'rev-parse', '--path-format=absolute', '--git-common-dir')).Text
    $head = (Invoke-WinpdGit $root @('rev-parse', '--verify', 'HEAD^{commit}')).Text.Trim()
    $name = if ([IO.Path]::GetFileName($commonDir) -eq '.git') {
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($commonDir))
    } else { [IO.Path]::GetFileName($root) }
    return [ordered]@{
        Root = $root; CommonDirectory = $commonDir; Name = $name
        Head = $head; Branch = (Invoke-WinpdGit $root @('branch', '--show-current')).Text.Trim()
        Remotes = @((Invoke-WinpdGit $root @('remote')).Lines)
    }
}

function Get-WinpdRemoteName {
    param([Collections.IDictionary]$Repository, [string]$Requested)
    if ($Requested) {
        if ($Requested -notin $Repository.Remotes) { throw "Unknown base remote: $Requested" }
        return $Requested
    }
    if ('origin' -in $Repository.Remotes) { return 'origin' }
    if ($Repository.Remotes.Count -eq 1) { return $Repository.Remotes[0] }
    throw 'Select BaseRemote explicitly; the repository has no unambiguous default remote.'
}

function Get-WinpdRemoteRepositoryName {
    param([string]$Root, [string]$Remote)
    $url = (Invoke-WinpdGit $Root @('remote', 'get-url', $Remote)).Text.Trim()
    $path = $url
    $uri = $null
    if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('https', 'http', 'ssh', 'git')) {
        $path = $uri.AbsolutePath
    } elseif ($url -match '^[^@/]+@[^:]+:(.+)$') { $path = $Matches[1] }
    return (($path.TrimEnd('/', '\') -split '[/\\]')[-1] -replace '\.git$', '')
}

function Get-WinpdProject {
    param([string]$ToolkitRoot, [Collections.IDictionary]$Repository, [string]$Remote, [string]$Requested)
    $profiles = @()
    $profilesRoot = Join-Path $ToolkitRoot 'project-specific'
    if (Test-Path -LiteralPath $profilesRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $profilesRoot -Directory | Sort-Object Name) {
            $path = Join-Path $directory.FullName 'project.json'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $profile = Read-WinpdJson $path
            if ($profile['schemaVersion'] -ne 1 -or $profile['id'] -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
                $profile.id -cne $directory.Name) { throw "Invalid project descriptor: $path" }
            $profiles += @{ Id = $profile.id; Root = $directory.FullName; Descriptor = $profile }
        }
    }
    $method = 'explicit'
    if ($Requested -eq 'auto') {
        $marker = Join-Path $Repository.Root '.winpd-project.json'
        if (Test-Path -LiteralPath $marker) {
            $record = Read-WinpdJson $marker
            if ($record['projectId'] -cnotmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Invalid repository project marker.' }
            $Requested = $record.projectId
            $method = 'repository-marker'
        }
    }
    if ($Requested -eq 'common') { return @{ Id = 'common'; Root = $null; MatchedBy = $method } }
    if ($Requested -ne 'auto') {
        $matches = @($profiles | Where-Object Id -CEQ $Requested)
        if ($matches.Count -ne 1) { throw "Unknown project: $Requested" }
        return @{ Id = $matches[0].Id; Root = $matches[0].Root; MatchedBy = $method }
    }
    $remoteName = Get-WinpdRemoteRepositoryName $Repository.Root $Remote
    $matches = @($profiles | Where-Object { $remoteName -in @($_.Descriptor['repositoryNames']) })
    $method = 'repository-identity'
    if (-not $matches.Count) {
        $directoryName = [IO.Path]::GetFileName($Repository.Root)
        $matches = @($profiles | Where-Object { $directoryName -in @($_.Descriptor['directoryNames']) })
        $method = 'directory-hint'
    }
    if ($matches.Count -gt 1) { throw 'Ambiguous project matches; specify Common.ProjectId.' }
    if ($matches.Count -eq 1) {
        return @{ Id = $matches[0].Id; Root = $matches[0].Root; MatchedBy = $method }
    }
    return @{ Id = 'common'; Root = $null; MatchedBy = 'common-only' }
}

function Get-WinpdBase {
    param([Collections.IDictionary]$Repository, [string]$Remote, [string]$Branch, [bool]$Offline)
    if (-not $Branch) {
        if ($Offline) {
            $reference = (Invoke-WinpdGit $Repository.Root @(
                'symbolic-ref', '--quiet', "refs/remotes/$Remote/HEAD")).Text.Trim()
            $Branch = $reference.Substring("refs/remotes/$Remote/".Length)
        } else {
            $lines = (Invoke-WinpdGit $Repository.Root @('ls-remote', '--symref', $Remote, 'HEAD')).Lines
            $symbolic = @($lines | Where-Object { $_ -match '^ref: refs/heads/(.+)\s+HEAD$' })
            if ($symbolic.Count -ne 1 -or $symbolic[0] -notmatch '^ref: refs/heads/(.+)\s+HEAD$') {
                throw 'The remote default branch is unknown; specify Common.BaseBranch.'
            }
            $Branch = $Matches[1].Trim()
        }
    }
    $null = Invoke-WinpdGit $Repository.Root @('check-ref-format', "refs/heads/$Branch")
    if ($Offline) {
        $commit = (Invoke-WinpdGit $Repository.Root @(
            'rev-parse', '--verify', "refs/remotes/$Remote/$Branch^{commit}")).Text.Trim()
    } else {
        $lines = (Invoke-WinpdGit $Repository.Root @('ls-remote', '--heads', $Remote, "refs/heads/$Branch")).Lines
        if ($lines.Count -ne 1) { throw 'The selected remote base branch was not found.' }
        $commit = ($lines[0] -split '\s+')[0]
    }
    if ($commit -notmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') { throw 'The base commit identity is invalid.' }
    return [ordered]@{
        Remote = $Remote; Branch = $Branch; Commit = $commit
        Freshness = $(if ($Offline) { 'offline' } else { 'remote' })
    }
}

function Get-WinpdToolkit {
    param([string]$Root, [bool]$Offline)
    $repository = Get-WinpdRepository $Root
    if ($repository.Root -ne (Get-WinpdFullPath $Root)) { throw 'ToolkitRoot must be its repository root.' }
    if ((Invoke-WinpdGit $Root @('status', '--porcelain', '--untracked-files=all')).Lines.Count) {
        throw 'The toolkit must be clean; commit or preserve its changes before setup.'
    }
    if (-not $Offline) {
        if (-not $repository.Branch) { throw 'Online toolkit freshness needs a tracked branch; use explicit offline mode for pinned sources.' }
        $remote = (Invoke-WinpdGit $Root @('config', '--get', "branch.$($repository.Branch).remote")).Text.Trim()
        $merge = (Invoke-WinpdGit $Root @('config', '--get', "branch.$($repository.Branch).merge")).Text.Trim()
        $lines = (Invoke-WinpdGit $Root @('ls-remote', '--heads', $remote, $merge)).Lines
        if ($lines.Count -ne 1 -or ($lines[0] -split '\s+')[0] -ne $repository.Head) {
            throw 'The toolkit is not at its latest upstream revision. Update its checkout separately, then rerun setup.'
        }
    }
    return [ordered]@{
        Root = $repository.Root; Head = $repository.Head
        Freshness = $(if ($Offline) { 'offline' } else { 'remote' })
    }
}

function New-WinpdSetupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Collections.IDictionary]$Common = @{},
        [Collections.IDictionary]$Project = @{},
        [Collections.IDictionary]$User = @{}
    )
    $ToolkitRoot = Get-WinpdFullPath $ToolkitRoot
    $commonSchema = Read-WinpdJson (Join-Path $ToolkitRoot 'common\schema.json')
    $baseDefaults = Read-WinpdJson (Join-Path $ToolkitRoot 'common\defaults.json')
    $userSchema = Read-WinpdJson (Join-Path $ToolkitRoot 'user-specific\schema.json')
    $userDefaults = Read-WinpdJson (Join-Path $ToolkitRoot 'user-specific\defaults.json')
    $profilePath = if ($User.Contains('ProfilePath')) { $User.ProfilePath } else { $userDefaults.ProfilePath }
    if ($profilePath -isnot [string]) { throw 'User.ProfilePath must have type string.' }
    $userProfile = Read-WinpdUserProfile $profilePath
    $userDefinition = Merge-WinpdUserSchema $userSchema $userDefaults $userProfile
    $userParameters = Resolve-WinpdParameters 'User' $userDefinition.Schema $userDefinition.Defaults $User
    $defaults = $baseDefaults
    if ($userProfile) { $defaults = Get-WinpdCommonDefaults $defaults $userProfile.Data.commonDefaults }
    $commonParameters = Resolve-WinpdParameters 'Common' $commonSchema $defaults $Common
    $workingDirectory = Get-WinpdFullPath $commonParameters.WorkingDirectory
    $repository = Get-WinpdRepository $workingDirectory
    $remote = Get-WinpdRemoteName $repository $commonParameters.BaseRemote
    $profile = Get-WinpdProject $ToolkitRoot $repository $remote $commonParameters.ProjectId
    $projectSchema = @{ type = 'object'; additionalProperties = $false; properties = @{} }
    $projectDefaults = @{}
    if ($profile.Root) {
        $projectSchema = Read-WinpdJson (Join-Path $profile.Root 'schema.json')
        $projectDefaults = Read-WinpdJson (Join-Path $profile.Root 'defaults.json')
        $descriptor = Read-WinpdJson (Join-Path $profile.Root 'project.json')
        if ($descriptor.Contains('commonDefaults')) {
            if ($descriptor.commonDefaults -isnot [Collections.IDictionary]) { throw 'Project commonDefaults must be an object.' }
            $defaults = Get-WinpdCommonDefaults $baseDefaults $descriptor.commonDefaults
            if ($userProfile) { $defaults = Get-WinpdCommonDefaults $defaults $userProfile.Data.commonDefaults }
            $commonParameters = Resolve-WinpdParameters 'Common' $commonSchema $defaults $Common
            $remote = Get-WinpdRemoteName $repository $commonParameters.BaseRemote
        }
    }
    $projectParameters = Resolve-WinpdParameters 'Project' $projectSchema $projectDefaults $Project
    $parameters = [ordered]@{ Common = $commonParameters; Project = $projectParameters; User = $userParameters }
    $toolkit = Get-WinpdToolkit $ToolkitRoot $true
    $layers = @(Get-WinpdLayers $ToolkitRoot $profile $parameters $userProfile)
    $preflight = [ordered]@{
        SchemaVersion = 1; Toolkit = $toolkit; Repository = $repository
        Project = $profile; Parameters = $parameters
    }
    foreach ($layer in $layers) { $null = Invoke-WinpdLayer $layer 'Preflight' $preflight }
    $prefix = $commonParameters.BranchPrefix
    $keyword = $commonParameters.Keyword
    $taskId = (Get-WinpdHash @($repository.CommonDirectory.ToUpperInvariant(), $keyword.ToLowerInvariant())).Substring(0, 20).ToLowerInvariant()
    $statePath = Resolve-WinpdChildPath $repository.CommonDirectory "winpd\tasks\$taskId.json"
    $recorded = $null
    if (Test-Path -LiteralPath $statePath) {
        $recorded = Read-WinpdJson $statePath
        if ($recorded['SchemaVersion'] -ne 1 -or $recorded['TaskId'] -ne $taskId -or
            $recorded['Base'] -isnot [Collections.IDictionary] -or
            $recorded['Toolkit'] -isnot [Collections.IDictionary] -or
            $recorded.Base['Commit'] -notmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') {
            throw 'The existing task journal lacks valid pinned inputs; it will not be guessed or reset.'
        }
        if ($recorded.Toolkit.Head -ne $toolkit.Head -or $recorded.Toolkit.Root -ne $toolkit.Root) {
            throw 'This task is pinned to a different toolkit revision/location; no automatic upgrade was performed.'
        }
        $base = $recorded.Base
        $toolkit = $recorded.Toolkit
    } else {
        if (-not $commonParameters.Offline) { $toolkit = Get-WinpdToolkit $ToolkitRoot $false }
        $base = Get-WinpdBase $repository $remote $commonParameters.BaseBranch $commonParameters.Offline
    }
    $branches = [ordered]@{ Dev = "$prefix/$keyword-dev"; Publish = "$prefix/$keyword-publish" }
    foreach ($branch in $branches.Values) {
        $null = Invoke-WinpdGit $repository.Root @('check-ref-format', "refs/heads/$branch")
    }
    $defaultParent = Split-Path $repository.Root -Parent
    $worktreeRoot = if ($commonParameters.WorktreeRoot) {
        Get-WinpdFullPath $commonParameters.WorktreeRoot $repository.Root
    } else { $defaultParent }
    $paths = [ordered]@{
        Dev = Resolve-WinpdChildPath $worktreeRoot "$($repository.Name)-$keyword-dev"
        Publish = Resolve-WinpdChildPath $worktreeRoot "$($repository.Name)-$keyword-publish"
        State = $statePath
    }
    foreach ($path in @($paths.Dev, $paths.Publish)) {
        if ($path -eq $repository.Root -or $path -eq $ToolkitRoot -or
            $repository.Root.StartsWith("$path$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
            $ToolkitRoot.StartsWith("$path$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith("$($repository.Root)$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith("$ToolkitRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A generated worktree path overlaps an existing repository.'
        }
    }
    $plan = [ordered]@{
        SchemaVersion = 1; Status = 'planned'; TaskId = $taskId
        Toolkit = $toolkit; Repository = $repository; Base = $base; Project = $profile
        Parameters = $parameters
        Branches = $branches; Paths = $paths
    }
    $plan.Layers = @(Get-WinpdContributions $layers $plan)
    # Pin provenance is observational, not a change to an existing task's identity.
    $plan.Fingerprint = Get-WinpdHash $plan
    $plan.PinSource = $(if ($recorded) { 'existing-task' } else { 'new-resolution' })
    return $plan
}

. (Join-Path $PSScriptRoot 'Private\Layers.ps1')
. (Join-Path $PSScriptRoot 'Private\Profiles.ps1')
. (Join-Path $PSScriptRoot 'Private\Apply.ps1')

Export-ModuleMember -Function New-WinpdSetupPlan, Resolve-WinpdParameters, Invoke-WinpdSetup
