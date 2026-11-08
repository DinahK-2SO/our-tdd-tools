function Invoke-TestGit {
    param([string]$Root, [string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Git fixture failed: $($Arguments -join ' '): $($output -join ' ')" }
    return $output
}

function Write-TestJson {
    param([string]$Path, $Value)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-TestRepository {
    param([string]$Parent, [string]$Name = 'sample-project', [string]$Branch = 'main')
    $root = Join-Path (Join-Path $Parent ([guid]::NewGuid().ToString('N'))) $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $null = Invoke-TestGit $root @('init', '--quiet', '-b', $Branch)
    $null = Invoke-TestGit $root @('config', 'user.name', 'Winpd Fixture')
    $null = Invoke-TestGit $root @('config', 'user.email', 'winpd-fixture@example.invalid')
    'fixture baseline' | Set-Content -LiteralPath (Join-Path $root 'README.md') -Encoding utf8
    $null = Invoke-TestGit $root @('add', '--', 'README.md')
    $null = Invoke-TestGit $root @('commit', '--quiet', '-m', 'Fixture baseline')
    return $root
}

function Add-TestRemote {
    param([string]$Root, [string]$Parent, [string]$Branch = 'main')
    $remote = Join-Path $Parent "$([guid]::NewGuid().ToString('N')).git"
    New-Item -ItemType Directory -Path $remote | Out-Null
    $null = Invoke-TestGit $remote @('init', '--bare', '--quiet', '-b', $Branch)
    $null = Invoke-TestGit $Root @('remote', 'add', 'origin', $remote)
    $null = Invoke-TestGit $Root @('push', '--quiet', '-u', 'origin', $Branch)
    $null = Invoke-TestGit $Root @('remote', 'set-head', 'origin', '--auto')
    return $remote
}

function Add-TestProjectProfile {
    param([string]$ToolkitRoot, [string]$Id, [string[]]$Names)
    $root = Join-Path $ToolkitRoot "project-specific\$Id"
    Write-TestJson (Join-Path $root 'project.json') @{
        schemaVersion = 1; id = $Id
        repositoryNames = @($Names); directoryNames = @($Names)
    }
    Write-TestJson (Join-Path $root 'defaults.json') @{ Marker = 'project-default' }
    Write-TestJson (Join-Path $root 'schema.json') @{
        type = 'object'; additionalProperties = $false
        properties = @{ Marker = @{ type = 'string' } }
    }
    Add-TestLayerAssets $root '# Project fixture instructions'
}

function Add-TestLayerAssets {
    param([string]$Root, [string]$Instructions)
    New-Item -ItemType Directory -Path (Join-Path $Root 'templates'), (Join-Path $Root 'tools') -Force | Out-Null
    "$Instructions`n`n<FEATURE_GOAL>" | Set-Content -LiteralPath (Join-Path $Root 'templates\AGENTS.md') -Encoding utf8
    'Write-Output "fixture tool"' | Set-Content -LiteralPath (Join-Path $Root 'tools\fixture.ps1') -Encoding utf8
    @'
param([string]$Phase, [Collections.IDictionary]$Context, [Collections.IDictionary]$Parameters)
if ($Phase -eq 'Plan') {
    return @{ Instructions = @('templates/AGENTS.md'); ToolDirectories = @('tools') }
}
@{ Status = 'passed' }
'@ | Set-Content -LiteralPath (Join-Path $Root 'setup.ps1') -Encoding utf8
}

function New-TestToolkit {
    param([string]$Parent, [string]$SourceRoot)
    $root = New-TestRepository $Parent 'toolkit'
    foreach ($relative in @(
        'common\defaults.json', 'common\schema.json',
        'user-specific\defaults.json', 'user-specific\schema.json'
    )) {
        $target = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination $target -ErrorAction Stop
    }
    Add-TestLayerAssets (Join-Path $root 'common') '# Common fixture instructions'
    Add-TestLayerAssets (Join-Path $root 'user-specific') '# User fixture instructions'
    Add-TestProjectProfile $root 'intelligent-terminal' @('intelligent-terminal')
    $null = Invoke-TestGit $root @('add', '--all')
    $null = Invoke-TestGit $root @('commit', '--quiet', '-m', 'Fixture toolkit configuration')
    return $root
}

function New-TestToolkitSnapshot {
    param([string]$Parent, [string]$SourceRoot)
    $root = New-TestRepository $Parent 'complete-toolkit'
    $paths = @(Invoke-TestGit $SourceRoot @('ls-files', '--cached', '--others', '--exclude-standard') | Sort-Object -Unique)
    foreach ($relative in $paths) {
        $source = Join-Path $SourceRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $destination = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    $null = Invoke-TestGit $root @('add', '--all')
    $null = Invoke-TestGit $root @('commit', '--quiet', '-m', 'Candidate toolkit snapshot')
    return $root
}
