function Write-WinpdJson {
    param([string]$Path, $Value)
    $directory = Split-Path $Path -Parent
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ".winpd-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}

function Assert-WinpdWorktree {
    param([Collections.IDictionary]$Plan, [string]$Kind)
    $path = $Plan.Paths[$Kind]
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Owned $Kind worktree is missing." }
    $repository = Get-WinpdRepository $path
    if ($repository.Root -ne $path -or $repository.CommonDirectory -ne $Plan.Repository.CommonDirectory -or
        $repository.Branch -ne $Plan.Branches[$Kind] -or $repository.Head -ne $Plan.Base.Commit) {
        throw "Owned $Kind worktree identity changed; no resource was overwritten."
    }
}

function Assert-WinpdOutputs {
    param([Collections.IDictionary]$Plan, [Collections.IDictionary]$State, [switch]$Complete)
    foreach ($relative in $State.Files.Keys) {
        $record = $State.Files[$relative]
        $path = Resolve-WinpdChildPath $Plan.Paths.Dev $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if (-not $Complete -and $record.Status -eq 'writing') { continue }
            throw "Managed output changed or is missing: $relative"
        }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $record.Hash) {
            throw "Managed output changed: $relative"
        }
    }
}

function Set-WinpdManagedFile {
    param(
        [Collections.IDictionary]$Plan, [Collections.IDictionary]$State,
        [string]$Relative, [byte[]]$Bytes, [string]$OriginalHash
    )
    $path = Resolve-WinpdChildPath $Plan.Paths.Dev $Relative
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
    $known = $State.Files.Contains($Relative)
    if ($known -and $State.Files[$Relative].Hash -ne $hash) { throw "Managed output plan changed: $Relative" }
    if (Test-Path -LiteralPath $path) {
        $actual = (Get-FileHash -LiteralPath $path).Hash
        if ($known) {
            if ($actual -ne $hash) { throw "Managed output changed: $Relative" }
            $State.Files[$Relative].Status = 'written'
            Write-WinpdJson $Plan.Paths.State $State
            return
        }
        if (-not $OriginalHash -or $actual -ne $OriginalHash) { throw "Output already exists without ownership: $Relative" }
    }
    $State.Files[$Relative] = @{ Hash = $hash; Status = 'writing' }
    Write-WinpdJson $Plan.Paths.State $State
    $directory = Split-Path $path -Parent
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ".winpd-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        [IO.File]::Move($temporary, $path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
    $State.Files[$Relative].Status = 'written'
    Write-WinpdJson $Plan.Paths.State $State
}

function Get-WinpdInstructionText {
    param([Collections.IDictionary]$Plan)
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($layer in $Plan.Layers) {
        foreach ($fragment in $layer.Instructions) {
            if ((Get-FileHash -LiteralPath $fragment.Path).Hash -ne $fragment.Hash) {
                throw 'An instruction fragment changed after planning.'
            }
            $text = [IO.File]::ReadAllText($fragment.Path)
            $text = $text.Replace('{{User.ChatLanguage}}', $Plan.Parameters.User.ChatLanguage)
            $parts.Add($text.TrimEnd())
        }
    }
    return ($parts -join "`n`n") + "`n"
}

function Invoke-WinpdSetup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][Collections.IDictionary]$Plan)
    if ($Plan['SchemaVersion'] -ne 1 -or $Plan['Status'] -ne 'planned' -or -not $Plan['Fingerprint']) {
        throw 'Unsupported or incomplete setup plan.'
    }
    $copy = [ordered]@{}
    foreach ($key in $Plan.Keys) {
        if ($key -notin @('Fingerprint', 'PinSource')) { $copy[$key] = $Plan[$key] }
    }
    if ((Get-WinpdHash $copy) -ne $Plan.Fingerprint) { throw 'The setup plan was modified after resolution.' }
    $toolkit = Get-WinpdToolkit $Plan.Toolkit.Root $true
    if ($toolkit.Head -ne $Plan.Toolkit.Head) { throw 'The toolkit revision changed after planning.' }
    Assert-WinpdLayerInputs $Plan.Layers
    foreach ($layer in $Plan.Layers) { $null = Invoke-WinpdLayer $layer 'Preflight' $Plan }
    $repository = Get-WinpdRepository $Plan.Repository.Root
    if ($repository.CommonDirectory -ne $Plan.Repository.CommonDirectory -or
        $repository.Head -ne $Plan.Repository.Head -or $repository.Branch -ne $Plan.Repository.Branch) {
        throw 'The caller repository changed after planning.'
    }
    foreach ($path in $Plan.Paths.Values) {
        $null = Resolve-WinpdChildPath (Split-Path $path -Parent) (Split-Path $path -Leaf)
    }
    if (-not $PSCmdlet.ShouldProcess($Plan.Repository.Root, 'Prepare owned dev/publish worktrees and templates')) {
        return $Plan
    }
    $stateExists = Test-Path -LiteralPath $Plan.Paths.State
    if (-not $stateExists) {
        foreach ($kind in 'Dev', 'Publish') {
            if (Test-Path -LiteralPath $Plan.Paths[$kind]) { throw "$kind worktree path already exists." }
            $reference = Invoke-WinpdGit $repository.Root @(
                'show-ref', '--verify', '--quiet', "refs/heads/$($Plan.Branches[$kind])") @(0, 1)
            if ($reference.ExitCode -eq 0) { throw "$kind branch already exists." }
        }
    }
    $stateDirectory = Split-Path $Plan.Paths.State -Parent
    [void][IO.Directory]::CreateDirectory($stateDirectory)
    $lock = [IO.File]::Open("$($Plan.Paths.State).lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $state = $null
    $ownsState = $false
    try {
        if (Test-Path -LiteralPath $Plan.Paths.State) {
            $state = Read-WinpdJson $Plan.Paths.State
            if ($state['SchemaVersion'] -ne 1 -or $state['TaskId'] -ne $Plan.TaskId -or
                $state['Fingerprint'] -ne $Plan.Fingerprint) {
                throw 'Existing setup belongs to different inputs; no rebase, upgrade or overwrite was performed.'
            }
            if ($state['Resources'] -isnot [Collections.IDictionary] -or
                $state['Files'] -isnot [Collections.IDictionary] -or $state['CompletedLayers'] -isnot [array]) {
                throw 'The setup journal is incomplete; it will not be reset.'
            }
            $ownsState = $true
            foreach ($kind in 'Dev', 'Publish') {
                if ($state.Resources[$kind] -eq 'created') { Assert-WinpdWorktree $Plan $kind }
                elseif ($state.Resources[$kind] -eq 'creating') {
                    throw "Interrupted $kind creation needs inspection; ownership is not assumed."
                }
            }
            Assert-WinpdOutputs $Plan $state -Complete:($state.Status -eq 'ready')
            if ($state.Status -eq 'ready') {
                if ((Invoke-WinpdGit $Plan.Paths.Publish @('status', '--porcelain', '--untracked-files=all')).Lines.Count) {
                    throw 'The publish worktree has changed; setup will not overwrite it.'
                }
                return @{ Status = 'ready'; Reused = $true; DevRoot = $Plan.Paths.Dev
                    PublishRoot = $Plan.Paths.Publish; StatePath = $Plan.Paths.State
                    BaseCommit = $Plan.Base.Commit; ToolkitCommit = $Plan.Toolkit.Head; PinSource = $Plan.PinSource }
            }
        } else {
            $state = @{
                SchemaVersion = 1; TaskId = $Plan.TaskId; Fingerprint = $Plan.Fingerprint
                Status = 'applying'; Phase = 'preflight'; Resources = @{ Dev = 'pending'; Publish = 'pending' }
                Files = @{}; CompletedLayers = @(); OriginalAgents = $null; Error = $null
                Base = $Plan.Base; Toolkit = $Plan.Toolkit; Paths = $Plan.Paths; Branches = $Plan.Branches
            }
            $ownsState = $true
            Write-WinpdJson $Plan.Paths.State $state
        }
        $state.Status = 'applying'
        $state.Error = $null
        $available = Invoke-WinpdGit $repository.Root @('cat-file', '-e', "$($Plan.Base.Commit)^{commit}") @(0, 128)
        if ($available.ExitCode -ne 0) {
            if ($Plan.Parameters.Common.Offline) { throw 'The pinned base object is unavailable offline.' }
            $null = Invoke-WinpdGit $repository.Root @(
                'fetch', '--no-tags', '--no-write-fetch-head', $Plan.Base.Remote, $Plan.Base.Commit)
        }
        foreach ($kind in 'Dev', 'Publish') {
            if ($state.Resources[$kind] -eq 'created') { continue }
            if (Test-Path -LiteralPath $Plan.Paths[$kind]) { throw "$kind worktree path already exists." }
            $state.Phase = "create-$($kind.ToLowerInvariant())"
            $state.Resources[$kind] = 'creating'
            Write-WinpdJson $Plan.Paths.State $state
            $null = Invoke-WinpdGit $repository.Root @(
                'worktree', 'add', '-b', $Plan.Branches[$kind], $Plan.Paths[$kind], $Plan.Base.Commit)
            Assert-WinpdWorktree $Plan $kind
            $state.Resources[$kind] = 'created'
            Write-WinpdJson $Plan.Paths.State $state
        }
        $managedRoot = Join-Path $Plan.Paths.Dev '.winpd'
        if (-not $state.Files.Count -and (Test-Path -LiteralPath $managedRoot)) {
            throw 'The base already contains a .winpd directory; setup will not adopt it.'
        }
        foreach ($layer in $Plan.Layers) {
            if ($layer.Kind -in $state.CompletedLayers) { continue }
            $state.Phase = "apply-$($layer.Kind)"
            Write-WinpdJson $Plan.Paths.State $state
            foreach ($file in $layer.Files) {
                if ((Get-FileHash -LiteralPath $file.Source).Hash -ne $file.Hash) {
                    throw 'A tool asset changed after planning.'
                }
                Set-WinpdManagedFile $Plan $state $file.Relative ([IO.File]::ReadAllBytes($file.Source))
            }
            $null = Invoke-WinpdLayer $layer 'Apply' $Plan
            $state.CompletedLayers = @($state.CompletedLayers) + @($layer.Kind)
            Write-WinpdJson $Plan.Paths.State $state
        }
        $state.Phase = 'render'
        Write-WinpdJson $Plan.Paths.State $state
        $agentsPath = Resolve-WinpdChildPath $Plan.Paths.Dev 'AGENTS.md'
        $text = Get-WinpdInstructionText $Plan
        if (-not $state.Files.Contains('AGENTS.md')) {
            if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
                $bytes = [IO.File]::ReadAllBytes($agentsPath)
                $state.OriginalAgents = (Get-FileHash -LiteralPath $agentsPath).Hash
                Set-WinpdManagedFile $Plan $state '.winpd\original\AGENTS.md' $bytes
            }
        }
        if ($state.OriginalAgents) {
            $originalPath = Join-Path $Plan.Paths.Dev '.winpd\original\AGENTS.md'
            $text += "`n# Original project instructions`n`n" + [IO.File]::ReadAllText($originalPath)
        }
        Set-WinpdManagedFile $Plan $state 'AGENTS.md' ([Text.Encoding]::UTF8.GetBytes($text)) $state.OriginalAgents
        $manifest = [ordered]@{
            SchemaVersion = 1; TaskId = $Plan.TaskId; Keyword = $Plan.Parameters.Common.Keyword
            BaseCommit = $Plan.Base.Commit; ToolkitCommit = $Plan.Toolkit.Head; ProjectId = $Plan.Project.Id
            Branches = $Plan.Branches; InputFingerprint = $Plan.Fingerprint
            SemanticFieldsFilled = $false
        }
        Set-WinpdManagedFile $Plan $state '.winpd\setup.json' (
            [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 12)))
        $state.Phase = 'verify'
        Write-WinpdJson $Plan.Paths.State $state
        foreach ($layer in $Plan.Layers) { $null = Invoke-WinpdLayer $layer 'Verify' $Plan }
        foreach ($kind in 'Dev', 'Publish') { Assert-WinpdWorktree $Plan $kind }
        Assert-WinpdOutputs $Plan $state -Complete
        if ((Invoke-WinpdGit $Plan.Paths.Publish @('status', '--porcelain', '--untracked-files=all')).Lines.Count -or
            (Test-Path -LiteralPath (Join-Path $Plan.Paths.Publish '.winpd'))) {
            throw 'Publish verification failed: it must remain a pristine product base.'
        }
        $state.Status = 'ready'
        $state.Phase = 'complete'
        Write-WinpdJson $Plan.Paths.State $state
        return @{ Status = 'ready'; Reused = $false; DevRoot = $Plan.Paths.Dev
            PublishRoot = $Plan.Paths.Publish; StatePath = $Plan.Paths.State
            BaseCommit = $Plan.Base.Commit; ToolkitCommit = $Plan.Toolkit.Head; PinSource = $Plan.PinSource }
    }
    catch {
        if ($ownsState) {
            $state.Status = 'failed'
            $state.Error = $_.Exception.Message
            Write-WinpdJson $Plan.Paths.State $state
        }
        throw
    }
    finally { $lock.Dispose() }
}
