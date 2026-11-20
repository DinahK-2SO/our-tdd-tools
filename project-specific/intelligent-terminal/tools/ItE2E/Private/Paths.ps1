# Paths.ps1 — resolve the deployed app, its binaries, data files, and COM CLSID.
# This is the brick that pins WHICH package we test and HOW to reach it.
. (Join-Path $PSScriptRoot '..\..\DevTarget.ps1')

# Fixed per-brand COM CLSIDs (src/cascadia/WindowsTerminal/TerminalProtocolComServer.h:19-27).
# wtcli's CLSIDFromString requires the canonical braced form WT sets in WT_COM_CLSID.
$script:ItBrandClsids = [ordered]@{
    Release = '{A2E4F6B8-1C3D-4E5F-A6B7-C8D9E0F1A2B3}'
    Preview = '{B3F5A7C9-2D4E-4F6A-B7C8-D9E0F1A2B3C4}'
    Canary  = '{C4A6B8D0-3E5F-4A7B-C8D9-E0F1A2B3C4D5}'
    Dev     = '{D5B7C9E1-4F6A-4B8C-D9E0-F1A2B3C4D5E6}'
}

$script:ItKnownFamilies = [ordered]@{
    Store = 'Microsoft.IntelligentTerminal_8wekyb3d8bbwe'
    Dev   = 'IntelligentTerminal_rd9vj3e6a2mbr'
}

# Which brand CLSID a known package family registers (TerminalProtocolComServer.h brands).
# The Store package ships the Release brand; the dev sideload ships the Dev brand. This lets
# Resolve-WtComClsid probe the CORRECT brand for the package under test instead of blindly
# taking the first responder — critical when BOTH Store and Dev are installed, since otherwise
# probing Release first cold-launches the (window-less) Store server and misroutes wtcli.
$script:ItFamilyBrand = @{
    'Microsoft.IntelligentTerminal_8wekyb3d8bbwe' = 'Release'
    'IntelligentTerminal_rd9vj3e6a2mbr'           = 'Dev'
}

function Get-ItRepoRoot {
    <# Walk up from the module until we find the git root (best-effort). #>
    $d = $PSScriptRoot
    for ($i = 0; $i -lt 8 -and $d; $i++) {
        if (Test-Path (Join-Path $d '.git')) { return $d }
        $d = Split-Path $d -Parent
    }
    return $null
}

function Resolve-ItApp {
    <#
    .SYNOPSIS
        Build the immutable app descriptor used by every primitive: package identity,
        binaries (wtcli/wta/WindowsTerminal), data files (settings/state), log root.
    .PARAMETER Package
        'Store', 'Dev', or an explicitly selected Intelligent Terminal package family.
    #>
    [CmdletBinding()]
    param([string]$Package = (Get-ItTestPackage))

    if ([string]::IsNullOrWhiteSpace($Package) -or $Package -eq 'Auto') { throw 'Choose an explicit live test package.' }
    $candidates = switch ($Package) {
        'Store' { @($script:ItKnownFamilies.Store) }
        'Dev' { @($script:ItKnownFamilies.Dev) }
        default { @($Package) }
    }

    $pkg = $null; $pfn = $null
    foreach ($c in $candidates) {
        $p = Get-AppxPackage | Where-Object PackageFamilyName -eq $c | Select-Object -First 1
        if ($p) {
            # Prefer a candidate whose InstallLocation is readable (co-located binaries).
            if (-not $pkg) { $pkg = $p; $pfn = $c }
            if ($p.InstallLocation -and (Test-Path $p.InstallLocation)) { $pkg = $p; $pfn = $c; break }
        }
    }
    if (-not $pkg) { throw "No Intelligent Terminal package found for selector '$Package'. Install one first." }

    if ($pkg.Name -notlike '*IntelligentTerminal*' -or -not $pkg.InstallLocation) {
        throw 'Selected package is not an installed Intelligent Terminal target.'
    }
    $install = $pkg.InstallLocation
    $private = $pkg.Name -like 'IntelligentTerminal.Worktree.*'
    if ($private) {
        $privateClsid = Get-ItPrivateProtocolClsid -Package $pkg
        if ($env:ITE2E_WT_COM_CLSID -and [guid]$env:ITE2E_WT_COM_CLSID -ne [guid]$privateClsid) {
            throw 'The COM override conflicts with the registered private package.'
        }
    }
    $aumid = "$pfn!App"

    # Binaries: prefer co-located (have package identity, readable for Store).
    $wtcli = Join-Path $install 'wtcli.exe'
    $wt = Join-Path $install 'WindowsTerminal.exe'
    $wta = Join-Path $install 'wta.exe'
    foreach ($file in $wtcli, $wt, $wta) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing selected package executable: $file" }
    }

    $localState = Join-Path $env:LOCALAPPDATA "Packages\$pfn\LocalState"
    $logRoot = Join-Path $env:LOCALAPPDATA "Packages\$pfn\LocalCache\Local\IntelligentTerminal\logs"

    $aliasName = if ($private) { 'wtai-' + $pkg.Name.Substring('IntelligentTerminal.Worktree.'.Length) + '.exe' } else { 'wtai.exe' }
    $launchAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$pfn\$aliasName"

    [pscustomobject]@{
        Package          = $pfn
        PackageFullName  = $pkg.PackageFullName
        Version          = [string]$pkg.Version
        AppUserModelId   = $aumid
        LaunchAlias      = $launchAlias
        InstallLocation  = $install
        WtcliPath        = $wtcli
        WtaPath          = $wta
        WindowsTerminal  = $wt
        SettingsPath     = Join-Path $localState 'settings.json'
        StatePath        = Join-Path $localState 'state.json'
        LocalStateDir    = $localState
        LogRootDir       = $logRoot
        PrivateProtocolClsid = if ($private) { $privateClsid } else { $null }
        ComClsid         = $null
        Hwnd             = $null   # filled by harness after launch
        Pid              = $null
        LogStartOffset   = @{}     # per-file byte offset captured at test start
    }
}

function Get-RunnableWtaPath {
    <#
    .SYNOPSIS
        The packaged wta.exe in WindowsApps cannot be launched by an external process
        ("Access is denied"), unlike wtcli. For wta subcommands that do NOT require WT
        package identity (sessions, eval), run a copy of the exact packaged binary from a
        writable temp dir (version-matched), falling back to the repo dev build.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    if ($App.PSObject.Properties.Name -contains 'WtaRunnable' -and $App.WtaRunnable -and (Test-Path $App.WtaRunnable)) { return $App.WtaRunnable }

    $runnable = $null
    if ($App.WtaPath -and (Test-Path $App.WtaPath) -and $App.WtaPath -like '*WindowsApps*') {
        $dir = Join-Path $env:TEMP "ite2e-wta\$($App.Version)"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $dest = Join-Path $dir 'wta.exe'
        if (-not (Test-Path $dest)) {
            try { Copy-Item -LiteralPath $App.WtaPath -Destination $dest -Force; Write-ItLog -Level INFO -Message "Staged runnable wta -> $dest" }
            catch { Write-ItLog -Level WARN -Message "Could not stage packaged wta: $_" }
        }
        $bundleSource = Join-Path $App.InstallLocation 'wt-agent-hooks'
        $bundleDest = Join-Path $dir 'wt-agent-hooks'
        if ((Test-Path $bundleSource) -and -not (Test-Path $bundleDest)) {
            try {
                Copy-Item -LiteralPath $bundleSource -Destination $bundleDest -Recurse -Force
                Write-ItLog -Level INFO -Message "Staged hook bundle -> $bundleDest"
            }
            catch { Write-ItLog -Level WARN -Message "Could not stage packaged hook bundle: $_" }
        }
        if (Test-Path $dest) { $runnable = $dest }
    }
    if (-not $runnable -and $App.WtaPath -and (Test-Path $App.WtaPath)) { $runnable = $App.WtaPath }
    if (-not $runnable) { throw "No runnable wta.exe available for $($App.Package)." }
    $App | Add-Member -NotePropertyName WtaRunnable -NotePropertyValue $runnable -Force
    $runnable
}

function Resolve-WtComClsid {
    <#
    .SYNOPSIS
        Resolve the running package's known brand or explicitly selected COM CLSID.
        Caches the result on the app object; unknown families require an override.
    .NOTES
        WT registers the server with CoRegisterClassObject(CLSCTX_LOCAL_SERVER), so the
        terminal MUST already be running. Returns the CLSID string, or throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [int]$TimeoutSec = 30,
        [string]$ComClsid = $env:ITE2E_WT_COM_CLSID
    )
    $override = $null
    if ($ComClsid) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($ComClsid, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw 'The COM override must be a non-empty GUID.'
        }
        $override = $parsed.ToString('B')
    }
    if ($App.PSObject.Properties.Name -contains 'PrivateProtocolClsid' -and $App.PrivateProtocolClsid) {
        $private = [guid]$App.PrivateProtocolClsid
        if ($override -and $parsed -ne $private) { throw 'The COM override conflicts with the registered private package.' }
        $parsed = $private
        $override = $private.ToString('B')
    }
    if ($App.ComClsid) {
        if ($override) {
            $cached = [guid]::Empty
            if (-not [guid]::TryParse($App.ComClsid, [ref]$cached) -or $cached -ne $parsed) {
                throw 'The COM override conflicts with the cached application identity.'
            }
            $App.ComClsid = $override
        }
        return $App.ComClsid
    }
    $wtcli = $App.WtcliPath
    if (-not $wtcli) { throw "wtcli not resolved for $($App.Package)." }

    # Probe the brand that THIS package registers (Store=Release, Dev=Dev). When both packages
    # are installed they share the COM activation namespace, so blindly taking the first
    # responding brand can cold-launch the OTHER package's window-less server and latch onto the
    # wrong CLSID (→ later GetActivePane 0x80004005). For a KNOWN package family we therefore
    # probe ONLY its brand (the Wait-Until retry absorbs startup). Unknown families need an
    # explicit endpoint rather than probing a server belonging to another package.
    $expectedBrand = $script:ItFamilyBrand[$App.Package]
    if (-not $override -and -not $expectedBrand) {
        throw "Package '$($App.Package)' requires an explicit COM override; no other brand will be probed."
    }
    $probeOrder = if ($override) { @('override') } else { @($expectedBrand) }

    $found = Wait-Until -TimeoutSec $TimeoutSec -IntervalSec 1 -Because "a brand CLSID that wtcli can connect to" -Quiet -Condition {
        foreach ($brand in $probeOrder) {
            $clsid = if ($override) { $override } else { $script:ItBrandClsids[$brand] }
            $r = Invoke-Native -FilePath $wtcli -Arguments @('--json', 'list-windows') -TimeoutSec 8 -Environment @{ WT_COM_CLSID = $clsid }
            if ($r.ExitCode -eq 0) {
                $j = $r.StdOut | ConvertFrom-JsonSafe
                if ($null -ne $j -and $null -ne $j.windows) {
                    Write-ItLog -Level INFO -Message "Resolved COM CLSID brand=$brand clsid=$clsid (expected=$expectedBrand)"
                    return $clsid
                }
            }
        }
        return $null
    }
    if (-not $found) { throw "Could not resolve a live WT_COM_CLSID for $($App.Package). Is the terminal running?" }
    $App.ComClsid = $found
    return $found
}
