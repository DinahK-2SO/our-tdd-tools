# Harness.ps1 — lifecycle: resolve, (safely) configure, launch, attach, teardown.
# Non-destructive by default: settings.json/state.json are backed up and restored.

function Backup-WtConfig {
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    foreach ($f in @($App.SettingsPath, $App.StatePath)) {
        $bak = "$f.e2ebak"
        $missing = "$bak.missing"
        # A leftover .e2ebak means a prior run crashed before restoring. Recover by
        # restoring it first (revert that run's changes) so we snapshot the real
        # pre-test state — not a state already mutated by the crashed run.
        if (Test-Path -LiteralPath $bak) {
            New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null
            Copy-Item -LiteralPath $bak -Destination $f -Force
            Remove-Item -LiteralPath $bak -Force
            Remove-Item -LiteralPath $missing -Force -ErrorAction SilentlyContinue
            Write-ItLog -Level WARN -Message "Recovered stale backup for $f (prior run did not clean up)"
        }
        elseif (Test-Path -LiteralPath $missing) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Write-ItLog -Level WARN -Message "Recovered stale missing-file backup for $f (prior run did not clean up)"
        }

        New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null
        if (Test-Path -LiteralPath $f) {
            Copy-Item -LiteralPath $f -Destination $bak -Force
            Remove-Item -LiteralPath $missing -Force -ErrorAction SilentlyContinue
            Write-ItLog -Level INFO -Message "Backed up $f"
        }
        else {
            Set-Content -LiteralPath $missing -Value 'originally-missing' -Encoding ascii
            Write-ItLog -Level INFO -Message "Recorded originally missing config file $f"
        }
    }
}

function Get-DescendantWtaIds {
    <# wta.exe PIDs that are descendants of the given WindowsTerminal pid (master spawned by
       SharedWta, helpers as conpty children). Only these belong to this test run. #>
    [CmdletBinding()] param([Parameter(Mandatory)][int]$RootPid)
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    if (-not $all) { return @() }
    $byParent = @{}
    foreach ($p in $all) { $byParent[[int]$p.ParentProcessId] += @($p) }
    # BFS from the WT root to collect all descendant PIDs.
    $descendants = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new(); $queue.Enqueue($RootPid)
    while ($queue.Count) {
        $cur = $queue.Dequeue()
        foreach ($child in $byParent[$cur]) {
            $cpid = [int]$child.ProcessId
            if ($descendants.Add($cpid)) { $queue.Enqueue($cpid) }
        }
    }
    $all | Where-Object { $_.Name -ieq 'wta.exe' -and $descendants.Contains([int]$_.ProcessId) } |
        Select-Object -ExpandProperty ProcessId
}

function Restore-WtConfig {
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    foreach ($f in @($App.SettingsPath, $App.StatePath)) {
        $bak = "$f.e2ebak"
        $missing = "$bak.missing"
        if (Test-Path -LiteralPath $bak) {
            New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null
            Copy-Item -LiteralPath $bak -Destination $f -Force
            Remove-Item -LiteralPath $bak -Force
            Remove-Item -LiteralPath $missing -Force -ErrorAction SilentlyContinue
            Write-ItLog -Level INFO -Message "Restored $f"
        }
        elseif (Test-Path -LiteralPath $missing) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $missing -Force
            Write-ItLog -Level INFO -Message "Restored originally missing state for $f"
        }
    }
}

function Enter-ItForegroundInputLease {
    <#
    .SYNOPSIS
        Acquire the machine-local lease that serializes foreground keyboard and pointer input.
    #>
    [CmdletBinding()]
    param([ValidateRange(0, 3600)][int]$TimeoutSec = 15)

    $mutex = [Threading.Mutex]::new($false, 'Local\IntelligentTerminal.LocalTdd.ForegroundInput')
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for the foreground-input lease after ${TimeoutSec}s. Another live ItE2E run owns physical input."
        }
        [pscustomobject]@{
            Mutex = $mutex
            Acquired = $true
        }
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Exit-ItForegroundInputLease {
    [CmdletBinding()]
    param($Lease)

    if (-not $Lease) { return }
    try {
        if ($Lease.Acquired) {
            $Lease.Mutex.ReleaseMutex()
            $Lease.Acquired = $false
        }
    }
    finally {
        $Lease.Mutex.Dispose()
    }
}

function Clear-WtConfig {
    <#
    .SYNOPSIS
        Strip agent/AI keys from settings.json so NO stale provider-specific value leaks into a
        test that only patches a subset of keys.
    .DESCRIPTION
        Tests apply settings by PATCHING individual keys (Set-WtSetting), layering on top of the
        existing settings.json. If the user's real file carries provider-specific keys — e.g.
        `acpModel`/`acpBaseUrl` pointing at a Foundry-local model that is only valid for
        `acpAgent: native` — a test that merely flips `acpAgent` to `copilot` would launch
        `copilot --acp --stdio --model <foundry>`, which the Copilot CLI rejects ("Invalid model
        …") and the agent handshake dies. Starting every test from an agent-clean config makes the
        launch deterministic and provider-pure.

        We REMOVE every agent/AI top-level key (acp*, delegate*, agentPane*, autoFix*,
        showToken*, aiIntegration*) while PRESERVING the rest of the file (profiles, theme, keybindings). A
        full schema-only wipe is deliberately NOT used: WindowsTerminal rejects a settings.json
        with no usable profile and pops a "Failed to load settings" dialog that would destabilize
        UI tests. When called via Start-Terminal (the normal path) the user's real settings are
        preserved in `.e2ebak` (Backup-WtConfig) and restored by Stop-Terminal, so this stays
        non-destructive across a run. If called standalone WITHOUT a prior backup, there is no
        `.e2ebak` to restore from — the caller owns preserving the original.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    $obj = Get-WtSettingsObject -App $App
    if (-not $obj) { Write-ItLog -Level INFO -Message "Clear-WtConfig: no parseable settings.json to clean"; return }
    $agentKeys = @($obj.PSObject.Properties.Name | Where-Object { $_ -match '^(acp|delegate|agentPane|autoFix|showToken|aiIntegration)' })
    foreach ($k in $agentKeys) { $obj.PSObject.Properties.Remove($k) }
    ($obj | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $App.SettingsPath -Encoding utf8
    $preserved = if (Test-Path "$($App.SettingsPath).e2ebak") { "; original preserved in .e2ebak" } else { "" }
    Write-ItLog -Level INFO -Message "Cleared agent/AI keys from settings.json (removed: $($agentKeys -join ', '))$preserved"
}

function Get-WtProcessesForApp {
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    if (-not $App.InstallLocation) { throw 'Cannot identify the selected package installation.' }
    $exe = [IO.Path]::GetFullPath((Join-Path $App.InstallLocation 'WindowsTerminal.exe'))
    foreach ($process in @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue)) {
        if (-not $process.Path) {
            if ($process.HasExited) { continue }
            throw "Cannot identify WindowsTerminal pid=$($process.Id)."
        }
        if ([string]::Equals($exe, $process.Path, [StringComparison]::OrdinalIgnoreCase)) { $process }
    }
}

function Get-RunningItProcesses {
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    Get-WtProcessesForApp -App $App
}

function Stop-ItCapturedProcess {
    param([Parameter(Mandatory)]$Process, [Parameter(Mandatory)][string]$ExpectedPath,
          [Parameter(Mandatory)][datetime]$Created, [int]$GraceSec = 6)
    if ($Process.HasExited) { return }
    if ($Process.Path -ine $ExpectedPath -or $Process.StartTime -ne $Created) {
        throw 'Refusing to close a process with a different executable or creation time.'
    }
    # Keep the original process handle through graceful and forced shutdown, not a recycled PID.
    try { $null = $Process.Handle }
    catch { if ($Process.HasExited) { return }; throw }
    if ($Process.HasExited) { return }
    [void]$Process.CloseMainWindow()
    if (-not $Process.WaitForExit($GraceSec * 1000)) {
        $Process.Kill()
        if (-not $Process.WaitForExit(4000)) { throw "Process $($Process.Id) did not exit." }
    }
}

function Stop-AppInstances {
    [CmdletBinding()] param([Parameter(Mandatory)]$App, [int]$GraceSec = 6)
    Stop-StaleItInstances -App $App -GraceSec $GraceSec
}

function Stop-StaleItInstances {
    [CmdletBinding()] param([Parameter(Mandatory)]$App, [int]$GraceSec = 6)
    $processes = @(Get-WtProcessesForApp -App $App)
    if (-not $processes.Count) { return }
    if ($App.Package -cne $script:ItKnownFamilies.Dev) {
        throw 'Existing Store or private package processes are not test-owned. Leave them running.'
    }
    $id = $PID
    $seen = [Collections.Generic.HashSet[int]]::new()
    while ($id -gt 0) {
        if (-not $seen.Add($id) -or $id -in $processes.Id) { throw 'Refusing to close the current process ancestry.' }
        $entry = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
        if (-not $entry) { throw "Cannot verify current process ancestry at pid=$id." }
        $id = [int]$entry.ParentProcessId
    }
    $exe = Join-Path $App.InstallLocation 'WindowsTerminal.exe'
    foreach ($process in $processes) {
        Stop-ItCapturedProcess -Process $process -ExpectedPath $exe -Created $process.StartTime -GraceSec $GraceSec
    }
}

function Get-ItTestPackage {
    <#
    .SYNOPSIS
        Resolve which package selector the feature/self-test suites should launch.
        Requires an explicit Store, Dev or package family name in ITE2E_PACKAGE.
        This is the single knob that lets the suites run against a dev-only machine
        (where only the sideload package is installed) without editing each Describe.
    #>
    [CmdletBinding()]
    param()
    if ([string]::IsNullOrWhiteSpace($env:ITE2E_PACKAGE) -or $env:ITE2E_PACKAGE -eq 'Auto') {
        throw 'Choose an explicit live test package with ITE2E_PACKAGE or -Package.'
    }
    return $env:ITE2E_PACKAGE
}

function Start-ItPackageProcess {
    param([Parameter(Mandatory)]$App)
    if ($App.AppUserModelId -cne "$($App.Package)!App") { throw 'Unexpected Terminal application identity.' }
    if (-not ('ItE2E.PackageActivation' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ItE2E {
    public static class PackageActivation {
        [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IManager {
            void ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string id,
                [MarshalAs(UnmanagedType.LPWStr)] string args, uint options, out int pid);
        }
        public static int Open(string id) {
            var manager = (IManager)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
            try { int pid; manager.ActivateApplication(id, "-w new", 2, out pid); return pid; }
            finally { Marshal.ReleaseComObject(manager); }
        }
    }
}
'@
    }
    $start = [DateTime]::UtcNow
    $id = [ItE2E.PackageActivation]::Open($App.AppUserModelId)
    $process = Get-Process -Id $id -ErrorAction Stop
    $null = $process.Handle
    if ($process.HasExited -or $process.Path -ine $App.WindowsTerminal -or $process.StartTime.ToUniversalTime() -lt $start) {
        throw 'Package activation did not create the expected Terminal process; refusing to attach.'
    }
    return $process
}

function Start-Terminal {
    <#
    .SYNOPSIS
        Resolve, (optionally) configure, launch, and attach to a deployed Intelligent
        Terminal. Returns the app context object used by every primitive.
    .PARAMETER Package   Store|Dev|<PackageFamilyName>
    .PARAMETER Settings  Hashtable of top-level settings.json keys to apply.
    .PARAMETER PassFre   Mark the agent FRE complete before launch (default $true).
    .PARAMETER Backup    Back up settings/state for restore on Stop-Terminal (default $true).
    .PARAMETER CleanSettings  Strip agent/AI keys from settings.json after backup so the user's
                         real config (e.g. a Foundry acpModel/acpBaseUrl set for acpAgent=native)
                         cannot leak into a test that only patches a subset of keys (default
                         $true; ignored when Backup is $false).
    .PARAMETER ShowFre   Leave the agent FRE overlay SHOWING (writes agentFreCompleted=false).
                         COM resolution is best-effort in this mode. A fresh monarch is always
                         started (see Stop-StaleItInstances below), which is what lets the FRE
                         re-read state.json — a running monarch caches ApplicationState.
    .PARAMETER CloseExistingInstances
        Allow closure only of the selected ordinary Dev package. Active private
        and Store targets are refused; unrelated packages are never closed.
    #>
    [CmdletBinding()]
    param(
        [string]$Package = (Get-ItTestPackage),
        [hashtable]$Settings,
        [bool]$PassFre = $true,
        [bool]$Backup = $true,
        [bool]$CleanSettings = $true,
        [bool]$SuppressCloseConfirmation = $true,
        [switch]$CloseExistingInstances,
        [switch]$ShowFre,
        [ValidateRange(0, 3600)][int]$InputLeaseTimeoutSec = 15,
        [int]$TimeoutSec = 60
    )
    $app = Resolve-ItApp -Package $Package
    Write-ItLog -Level INFO -Message "Resolved package $($app.Package) v$($app.Version); wtcli=$($app.WtcliPath)"

    $script:ItE2ELogFile = Get-ItArtifactPath -ChildPath ("logs\ite2e-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')) -CreateParent

    $proc = $null
    $created = $null
    $backupStarted = $false
    $inputLease = $null
    try {
    $inputLease = Enter-ItForegroundInputLease -TimeoutSec $InputLeaseTimeoutSec
    $app | Add-Member -NotePropertyName ForegroundInputLease -NotePropertyValue $inputLease -Force
    $runningIt = @(Get-WtProcessesForApp -App $app)
    if ($runningIt.Count) {
        if ($app.Package -cne $script:ItKnownFamilies.Dev -or -not $CloseExistingInstances) {
            throw "Selected package is already running; leave it untouched. -CloseExistingInstances applies only to explicitly owned ordinary Dev windows."
        }
        Stop-StaleItInstances -App $app
    }

    if ($Backup) { $backupStarted = $true; Backup-WtConfig -App $app }
    # Strip agent/AI keys from settings.json so the user's real config (e.g. a Foundry
    # acpModel/acpBaseUrl set for acpAgent=native) cannot leak into a test that only patches a
    # subset of keys. Requires a backup so Stop-Terminal can restore the real settings.
    if ($CleanSettings -and $Backup) { Clear-WtConfig -App $app }
    elseif ($CleanSettings) { Write-ItLog -Level WARN -Message "CleanSettings requested but Backup is off; skipping clean to avoid destroying user settings." }
    if ($SuppressCloseConfirmation -and $Backup) {
        if (-not $Settings) { $Settings = @{} }
        elseif (-not ($Settings -is [hashtable])) { $Settings = @{} + $Settings }
        if (-not $Settings.ContainsKey('warning.confirmOnClose')) {
            $Settings['warning.confirmOnClose'] = 'never'
        }
    }
    if ($ShowFre) { Reset-Fre -App $app | Out-Null }
    elseif ($PassFre) { Invoke-FrePass -App $app | Out-Null }
    if ($Settings) { Set-WtSettings -App $app -Settings $Settings | Out-Null }

    # Snapshot the agent-pane-sessions.jsonl BEFORE launching WT so Get-AgentPaneSession can tell
    # OUR agent pane(s) apart from every pane recorded by prior runs / other windows. The file is
    # shared + append-only under the single-instance monarch and accumulates across all runs, so
    # any pane_session_id already present here is NOT ours. Captured before activation, so the
    # pre-warm agent pane this launch creates is guaranteed to be a NEW id.
    $agentJsonl = Join-Path $app.LocalStateDir 'IntelligentTerminal\agent-pane-sessions.jsonl'
    # Case-insensitive set: pane_session_id GUIDs can vary in casing between producer/serializer, so
    # an ordinal (case-sensitive) HashSet would miss a match and treat a pre-existing pane as new.
    $preIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $agentJsonl) {
        Get-Content -LiteralPath $agentJsonl | Where-Object { $_.Trim() } |
            ForEach-Object { $_ | ConvertFrom-JsonSafe } |
            Where-Object { $_ -and $_.pane_session_id } |
            ForEach-Object { [void]$preIds.Add([string]$_.pane_session_id) }
    }
    $app | Add-Member -NotePropertyName PreExistingAgentPaneIds -NotePropertyValue $preIds -Force
    Write-ItLog -Level INFO -Message "Snapshotted $($preIds.Count) pre-existing agent-pane id(s) before launch."

    if (@(Get-WtProcessesForApp -App $app).Count) { throw 'Selected package became active before launch.' }
    $proc = Start-ItPackageProcess -App $app
    $app.Pid = $proc.Id
    $created = $proc.StartTime
    $app | Add-Member -NotePropertyName Created -NotePropertyValue $created -Force
    $app | Add-Member -NotePropertyName Launched -NotePropertyValue $true -Force
    Write-ItLog -Level INFO -Message "WindowsTerminal pid=$($app.Pid) launched=$($app.Launched)"

    # Wait until shell activation has created the first real window before probing COM.
    # An immediate COM activation while the process exists but has no HWND races startup
    # and can create a second logical window in the same WindowsTerminal process.
    $hwnd = Wait-Until -TimeoutSec 20 -IntervalSec 1 -Quiet -Because "WT window HWND" -Condition {
        $w = Get-WtWindowHwnds -App $app | Where-Object { [int]$_.pid -eq [int]$app.Pid } | Select-Object -First 1
        if ($w) { $w.hwnd } else { $null }
    }
    if ($hwnd) { $app.Hwnd = $hwnd; Write-ItLog -Level INFO -Message "WT window hwnd=$hwnd" }
    else { Write-ItLog -Level WARN -Message "Could not resolve WT HWND; UI primitives will fall back to -a pid." }

    # Bring COM online and resolve the brand CLSID. Best-effort while the FRE overlay is up
    # (the overlay replaces the window content, so the COM tab/pane surface may not be ready).
    if ($ShowFre) {
        try { Resolve-WtComClsid -App $app -TimeoutSec ([Math]::Min($TimeoutSec, 15)) | Out-Null }
        catch { Write-ItLog -Level WARN -Message "COM not resolved during FRE (expected): $_" }
    }
    else {
        Resolve-WtComClsid -App $app -TimeoutSec $TimeoutSec | Out-Null
    }

    # Capture the WT logical window id (informational; agent panes are XAML chrome and never
    # appear in list-panes, so window scoping of the agent pane itself relies on the
    # pre-existing-id snapshot above rather than on this).
    try {
        $active = Get-ActivePane -App $app
        if ($active -and $null -ne $active.window_id) {
            $app | Add-Member -NotePropertyName WindowId -NotePropertyValue ([string]$active.window_id) -Force
            Write-ItLog -Level INFO -Message "WT window_id=$($app.WindowId)"
        }
    }
    catch { Write-ItLog -Level WARN -Message "Could not resolve WT window_id: $_" }

    Initialize-LogOffsets -App $app | Out-Null
    $app
    }
    catch {
        $startupError = $_
        try {
            if ($proc -and $created) {
                Stop-ItCapturedProcess -Process $proc -ExpectedPath $app.WindowsTerminal -Created $created
            }
            if ($backupStarted) {
                if (@(Get-WtProcessesForApp -App $app).Count) { throw 'Target is active; keeping configuration backups for recovery.' }
                Restore-WtConfig -App $app
            }
        }
        finally { Exit-ItForegroundInputLease -Lease $inputLease }
        throw $startupError
    }
}

Set-Alias -Name Start-TerminalClean -Value Start-Terminal

function Stop-Terminal {
    <#
    .SYNOPSIS
        Close the terminal and (by default) restore the backed-up config.
    .DESCRIPTION
        Closes GRACEFULLY first (CloseMainWindow), giving WindowEmperor time to deregister
        its single-instance/COM-protocol server cleanly. Only force-kills as a fallback after
        -GraceSec. Graceful close is preferred so the COM monarch handoff between runs is
        clean; force-kill is a last resort for an unresponsive window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [bool]$RestoreSettings = $true,
        [int]$GraceSec = 8
    )
    process {
        try {
        if (-not $App.Launched -or -not $App.Created -or -not $App.Pid) {
            throw 'Cannot tear down a window without a captured launch identity.'
        }
        $proc = Get-Process -Id $App.Pid -ErrorAction SilentlyContinue
        if ($proc) {
            if ($proc.Path -ine $App.WindowsTerminal -or $proc.StartTime -ne $App.Created) {
                throw 'Refusing teardown: captured Terminal process identity changed.'
            }
            $wtaPath = Join-Path $App.InstallLocation 'wta.exe'
            $helpers = @(foreach ($id in @(Get-DescendantWtaIds -RootPid $proc.Id)) {
                $child = Get-Process -Id $id -ErrorAction SilentlyContinue
                if ($child -and $child.Path -ieq $wtaPath -and $child.StartTime -ge $App.Created) {
                    @{ Process = $child; Created = $child.StartTime }
                }
            })
            Stop-ItCapturedProcess -Process $proc -ExpectedPath $App.WindowsTerminal -Created $App.Created -GraceSec $GraceSec
            foreach ($helper in $helpers) {
                if (-not $helper.Process.HasExited) { Stop-ItCapturedProcess @helper -ExpectedPath $wtaPath -GraceSec $GraceSec }
            }
        }
        if ($RestoreSettings) {
            if (@(Get-WtProcessesForApp -App $App).Count) { throw 'Target is active; keeping configuration backups for recovery.' }
            Restore-WtConfig -App $App
        }
        }
        finally {
            if ($App.PSObject.Properties.Name -contains 'ForegroundInputLease') {
                Exit-ItForegroundInputLease -Lease $App.ForegroundInputLease
            }
        }
    }
}

function Start-TerminalFre {
    <#
    .SYNOPSIS
        Launch with the agent FRE overlay SHOWING so the FRE flow can be driven via UIA.
        Forces a COLD start (kills any running monarch) because a running monarch caches
        ApplicationState and would otherwise just open a normal tab instead of the overlay.
        Backs up config for restore on Stop-Terminal.
    #>
    [CmdletBinding()]
    param(
        [string]$Package = (Get-ItTestPackage),
        [switch]$CloseExistingInstances,
        [int]$TimeoutSec = 60
    )
    return (Start-Terminal -Package $Package -ShowFre -Backup $true `
            -CloseExistingInstances:$CloseExistingInstances -TimeoutSec $TimeoutSec)
}

function Reset-TerminalState {
    <#
    .SYNOPSIS
        Apply a clean baseline to a (running or not) app: optional minimal settings.json,
        FRE state. Use -Replace to overwrite settings.json with a minimal schema-only file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [hashtable]$Settings,
        [bool]$PassFre = $true,
        [switch]$Replace
    )
    process {
        if ($Replace) {
            $minimal = [pscustomobject]@{ '$schema' = 'https://aka.ms/terminal-profiles-schema' }
            Set-Content -LiteralPath $App.SettingsPath -Value ($minimal | ConvertTo-Json) -Encoding utf8
        }
        if ($PassFre) { Invoke-FrePass -App $App | Out-Null } else { Reset-Fre -App $App | Out-Null }
        if ($Settings) { Set-WtSettings -App $App -Settings $Settings | Out-Null }
        $App
    }
}
