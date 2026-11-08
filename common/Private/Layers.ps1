function Resolve-WinpdChildPath {
    param([string]$Root, [string]$RelativePath)
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[/\\])\.\.?([/\\]|$)|[:*?"<>|]') {
        throw "Invalid managed relative path: $RelativePath"
    }
    $relative = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar).Replace('\', [IO.Path]::DirectorySeparatorChar)
    $path = Get-WinpdFullPath $relative $Root
    $prefix = (Get-WinpdFullPath $Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A managed path escapes its declared root.'
    }
    $current = $path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not supported in managed paths: $current"
            }
        }
        $current = Split-Path $current -Parent
    }
    return $path
}

function Get-WinpdLayers {
    param([string]$ToolkitRoot, [Collections.IDictionary]$Project, [Collections.IDictionary]$Parameters, $UserProfile)
    $layers = @(
        @{ Id = 'common'; Kind = 'common'; Root = (Join-Path $ToolkitRoot 'common')
            Mount = 'common'; Parameters = $Parameters.Common }
    )
    if ($Project.Root) {
        $layers += @{ Id = $Project.Id; Kind = 'project'; Root = $Project.Root
            Mount = "project-specific\$($Project.Id)"; Parameters = $Parameters.Project }
    }
    $layers += @{ Id = 'user'; Kind = 'user'; Root = (Join-Path $ToolkitRoot 'user-specific')
        Mount = 'user-specific'; Parameters = $Parameters.User }
    foreach ($layer in $layers) {
        $layer.SourceKind = 'toolkit'
        $layer.Inputs = @()
        $layer.Script = Resolve-WinpdChildPath $layer.Root 'setup.ps1'
        if (-not (Test-Path -LiteralPath $layer.Script -PathType Leaf)) {
            throw "Layer setup script is missing: $($layer.Id)"
        }
        $relative = [IO.Path]::GetRelativePath($ToolkitRoot, $layer.Script).Replace('\', '/')
        $null = Invoke-WinpdGit $ToolkitRoot @('ls-files', '--error-unmatch', '--', $relative)
        $layer.ScriptHash = (Get-FileHash -LiteralPath $layer.Script).Hash
    }
    if ($UserProfile) {
        $layers += @{
            Id = 'user-local'; Kind = 'user-local'; Root = $UserProfile.Root
            Mount = 'user-specific\local'; SourceKind = 'local'; Parameters = $Parameters.User
            Script = $UserProfile.Script
            ScriptHash = $(if ($UserProfile.Script) { (Get-FileHash -LiteralPath $UserProfile.Script).Hash } else { $null })
            Inputs = @(@{ Path = $UserProfile.Path; Hash = $UserProfile.Hash })
            DeclaredInstructions = $UserProfile.Data.instructions; DeclaredTools = $UserProfile.Data.tools
        }
    }
    return $layers
}

function Invoke-WinpdLayer {
    param([Collections.IDictionary]$Layer, [string]$Phase, [Collections.IDictionary]$Context)
    if (-not $Layer.Script) {
        if ($Phase -eq 'Plan') { return @{ Instructions = @(); ToolDirectories = @() } }
        return @{ Status = 'passed' }
    }
    if ((Get-FileHash -LiteralPath $Layer.Script).Hash -ne $Layer.ScriptHash) {
        throw "Layer script changed after planning: $($Layer.Id)"
    }
    $contextCopy = $Context | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable
    $parameters = $Layer.Parameters | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable
    $before = Get-WinpdHash @($contextCopy, $parameters)
    $output = @(& $Layer.Script -Phase $Phase -Context $contextCopy -Parameters $parameters)
    if ((Get-WinpdHash @($contextCopy, $parameters)) -ne $before) {
        throw "Layer $($Layer.Id) mutated its read-only context or parameters."
    }
    if ($output.Count -ne 1 -or $output[0] -isnot [Collections.IDictionary]) {
        throw "Layer $($Layer.Id) must return one structured $Phase result."
    }
    if ($Phase -ne 'Plan' -and $output[0]['Status'] -ne 'passed') {
        throw "Layer $($Layer.Id) did not pass ${Phase}: $($output[0]['Reason'])"
    }
    return $output[0]
}

function Get-WinpdTrackedFiles {
    param([string]$ToolkitRoot, [string]$Directory)
    $relative = [IO.Path]::GetRelativePath($ToolkitRoot, $Directory).Replace('\', '/')
    if ($relative -eq '..' -or $relative.StartsWith('../')) { throw 'A toolkit asset directory is outside its source.' }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Tool directory is missing: $relative" }
    $raw = (Invoke-WinpdGit $ToolkitRoot @('ls-files', '-z', '--', "$relative/")).Text
    foreach ($path in $raw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
        $full = Resolve-WinpdChildPath $ToolkitRoot $path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Tracked asset is missing: $path" }
        $full
    }
}

function Get-WinpdContributions {
    param([object[]]$Layers, [Collections.IDictionary]$Context)
    foreach ($layer in $Layers) {
        $result = Invoke-WinpdLayer $layer 'Plan' $Context
        foreach ($name in 'Instructions', 'ToolDirectories') {
            if ($result[$name] -isnot [array]) { throw "Layer $($layer.Id) must declare an array for $name." }
        }
        $instructions = @($result.Instructions)
        if ($layer.SourceKind -eq 'local') {
            $instructions += @($layer.DeclaredInstructions)
            if ($result.ToolDirectories.Count) {
                throw 'Private profiles must declare individual tool files, not whole directories.'
            }
        }
        $layer.Instructions = @(
            foreach ($relative in $instructions) {
                if ($relative -isnot [string]) { throw 'Instruction paths must be strings.' }
                $path = Resolve-WinpdChildPath $layer.Root $relative
                if ($layer.SourceKind -eq 'toolkit') {
                    $tracked = [IO.Path]::GetRelativePath($Context.Toolkit.Root, $path).Replace('\', '/')
                    $null = Invoke-WinpdGit $Context.Toolkit.Root @('ls-files', '--error-unmatch', '--', $tracked)
                } else { Assert-WinpdUserAsset $path }
                @{ Path = $path; Hash = (Get-FileHash -LiteralPath $path).Hash }
            }
        )
        $layer.Files = @(
            foreach ($relative in $result.ToolDirectories) {
                if ($relative -isnot [string]) { throw 'Tool directory paths must be strings.' }
                $directory = Resolve-WinpdChildPath $layer.Root $relative
                foreach ($path in Get-WinpdTrackedFiles $Context.Toolkit.Root $directory) {
                    $withinLayer = [IO.Path]::GetRelativePath($layer.Root, $path)
                    @{ Source = $path; Relative = ".winpd\$($layer.Mount)\$withinLayer"
                        Hash = (Get-FileHash -LiteralPath $path).Hash }
                }
            }
            if ($layer.SourceKind -eq 'local') {
                foreach ($relative in $layer.DeclaredTools) {
                    if ($relative -isnot [string]) { throw 'Personal tool paths must be strings.' }
                    $path = Resolve-WinpdChildPath $layer.Root $relative
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Personal tool is missing: $relative" }
                    Assert-WinpdUserAsset $path
                    @{ Source = $path; Relative = ".winpd\$($layer.Mount)\$relative"
                        Hash = (Get-FileHash -LiteralPath $path).Hash }
                }
            }
        )
        $layer
    }
}
