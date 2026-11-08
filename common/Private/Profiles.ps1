function Merge-WinpdValues {
    param([Collections.IDictionary]$Base, [Collections.IDictionary]$Additional)
    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Additional.Keys) { $result[$key] = $Additional[$key] }
    return $result
}

function Read-WinpdUserProfile {
    param([string]$Path)
    if (-not $Path) { return $null }
    $resolved = Get-WinpdFullPath $Path
    if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved = Join-Path $resolved 'profile.json' }
    $root = Split-Path $resolved -Parent
    $resolved = Resolve-WinpdChildPath $root ([IO.Path]::GetFileName($resolved))
    $data = Read-WinpdJson $resolved
    if ($data['schemaVersion'] -ne 1) { throw 'Unsupported local user profile version.' }
    $allowed = @('schemaVersion', 'commonDefaults', 'defaults', 'schema', 'instructions', 'tools', 'setupScript')
    foreach ($key in $data.Keys) {
        if ($key -notin $allowed) { throw "Unknown local user profile field: $key" }
    }
    foreach ($key in 'commonDefaults', 'defaults') {
        if (-not $data.Contains($key)) { $data[$key] = @{} }
        if ($data[$key] -isnot [Collections.IDictionary]) { throw "User profile $key must be an object." }
    }
    foreach ($key in 'instructions', 'tools') {
        if (-not $data.Contains($key)) { $data[$key] = @() }
        if ($data[$key] -isnot [array]) { throw "User profile $key must be an array." }
    }
    if (-not $data.Contains('schema')) {
        $data.schema = @{ type = 'object'; additionalProperties = $false; properties = @{} }
    }
    if ($data.schema -isnot [Collections.IDictionary] -or $data.schema['type'] -ne 'object' -or
        $data.schema['properties'] -isnot [Collections.IDictionary] -or
        $data.schema['additionalProperties'] -isnot [bool] -or $data.schema.additionalProperties) {
        throw 'User profile parameter schema is invalid.'
    }
    if ($data.defaults.Contains('ProfilePath')) { throw 'A local profile cannot redefine ProfilePath.' }
    $scriptPath = $null
    if ($data['setupScript']) {
        $scriptPath = Resolve-WinpdChildPath $root $data.setupScript
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw 'The selected user setup script is missing.' }
    }
    return @{
        Root = $root; Path = $resolved; Hash = (Get-FileHash -LiteralPath $resolved).Hash
        Data = $data; Script = $scriptPath
    }
}

function Merge-WinpdUserSchema {
    param([Collections.IDictionary]$Schema, [Collections.IDictionary]$Defaults, $Profile)
    if (-not $Profile) { return @{ Schema = $Schema; Defaults = $Defaults } }
    $properties = Merge-WinpdValues $Schema.properties @{}
    foreach ($key in $Profile.Data.schema.properties.Keys) {
        if ($properties.Contains($key)) { throw "A local profile cannot redefine the built-in User parameter: $key" }
        $rule = $Profile.Data.schema.properties[$key]
        if ($rule['sensitive'] -eq $true -or $rule['format'] -eq 'secret') {
            throw 'Credentials are not setup parameters; keep them in the provider credential store.'
        }
        $properties[$key] = $rule
    }
    return @{
        Schema = @{ type = 'object'; additionalProperties = $false; properties = $properties }
        Defaults = (Merge-WinpdValues $Defaults $Profile.Data.defaults)
    }
}

function Get-WinpdCommonDefaults {
    param([Collections.IDictionary]$Defaults, [Collections.IDictionary]$Contribution)
    $allowed = @('Keyword', 'BaseRemote', 'BaseBranch', 'BranchPrefix', 'WorktreeRoot')
    foreach ($key in $Contribution.Keys) {
        if ($key -notin $allowed) { throw "Unsupported cross-layer Common default: $key" }
    }
    return Merge-WinpdValues $Defaults $Contribution
}

function Assert-WinpdUserAsset {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    if ($name -match '^(?:\.env(?:\..*)?|credentials(?:\.json)?|auth\.json|id_rsa|id_ed25519|.*\.(?:pfx|p12|key))$') {
        throw "Private runtime data cannot be materialized: $name"
    }
    $text = [IO.File]::ReadAllText($Path)
    if ($text -match '-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}') {
        throw "Private credential material was found in a declared user asset: $name"
    }
}

function Assert-WinpdLayerInputs {
    param([object[]]$Layers)
    foreach ($layer in $Layers) {
        if ($layer.Script -and (Get-FileHash -LiteralPath $layer.Script).Hash -ne $layer.ScriptHash) {
            throw "A layer script changed after planning: $($layer.Id)"
        }
        foreach ($input in @($layer.Inputs) + @($layer.Instructions)) {
            if ((Get-FileHash -LiteralPath $input.Path).Hash -ne $input.Hash) {
                throw 'A customization input changed after planning.'
            }
        }
        foreach ($file in $layer.Files) {
            if ((Get-FileHash -LiteralPath $file.Source).Hash -ne $file.Hash) {
                throw 'A customization tool changed after planning.'
            }
        }
    }
}
