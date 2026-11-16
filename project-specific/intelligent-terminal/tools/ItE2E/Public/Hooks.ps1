# Hooks.ps1 — inspect / snapshot the agent session-management hook install state ON DISK.
#
# The FRE "Session management" toggle, on Save, shells the IN-PACKAGE wta.exe to run
# `wta hooks install --cli <agent>` (FreOverlay.cpp:1608-1618, 1169-1184). We can't run the
# packaged `wta hooks status` externally (no package identity), but the install state is written
# to the agent CLI's own config, which we CAN read directly:
#   Copilot: ~/.copilot/config.json -> installedPlugins[] entry {name:"wt-agent-hooks", enabled}
# These helpers read that state and snapshot/restore the whole config so hook-install tests stay
# non-destructive (the developer's real hook state is restored on teardown).
# ConfigPath or ITE2E_COPILOT_CONFIG can select an isolated file instead.

$script:CopilotConfigPath = Join-Path $env:USERPROFILE '.copilot\config.json'

function Get-CopilotHooksInstalled {
    <# $true when the wt-agent-hooks plugin is installed AND enabled in ~/.copilot/config.json. #>
    [CmdletBinding()] param(
        [ValidateNotNullOrEmpty()][string]$ConfigPath = $(if ($env:ITE2E_COPILOT_CONFIG) { $env:ITE2E_COPILOT_CONFIG } else { $script:CopilotConfigPath })
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    try {
        $j = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $wt = @($j.installedPlugins) | Where-Object { $_.name -eq 'wt-agent-hooks' } | Select-Object -First 1
        [bool]($wt -and $wt.enabled)
    }
    catch { $false }
}

function Backup-CopilotConfig {
    <# Snapshot ~/.copilot/config.json for restore. Returns a state object. #>
    [CmdletBinding()] param(
        [ValidateNotNullOrEmpty()][string]$ConfigPath = $(if ($env:ITE2E_COPILOT_CONFIG) { $env:ITE2E_COPILOT_CONFIG } else { $script:CopilotConfigPath })
    )
    $existed = Test-Path -LiteralPath $ConfigPath
    $content = if ($existed) { Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 } else { $null }
    [pscustomobject]@{ Path = $ConfigPath; Existed = $existed; Content = $content }
}

function Restore-CopilotConfig {
    <# Restore the snapshot from Backup-CopilotConfig. #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$State)
    process {
        if ($State.Existed) { Set-Content -LiteralPath $State.Path -Value $State.Content -Encoding utf8 -NoNewline }
        elseif (Test-Path -LiteralPath $State.Path) { Remove-Item -LiteralPath $State.Path -Force }
        Write-ItLog -Level INFO -Message "Restored $($State.Path)"
    }
}

function Remove-CopilotHooksEntry {
    <#
    .SYNOPSIS
        Remove the wt-agent-hooks plugin entry from ~/.copilot/config.json to simulate a
        "not installed" baseline, so a test can then assert whether FRE Save (re)installs it.
        The local marketplace/plugin cache is left in place, so a subsequent install is fast
        (no npm/network). Non-destructive across a run when paired with Backup/Restore-CopilotConfig.
    #>
    [CmdletBinding()] param(
        [ValidateNotNullOrEmpty()][string]$ConfigPath = $(if ($env:ITE2E_COPILOT_CONFIG) { $env:ITE2E_COPILOT_CONFIG } else { $script:CopilotConfigPath })
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $j = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($j.PSObject.Properties.Name -contains 'installedPlugins') {
        $j.installedPlugins = @($j.installedPlugins | Where-Object { $_.name -ne 'wt-agent-hooks' })
    }
    ($j | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $ConfigPath -Encoding utf8
    Write-ItLog -Level INFO -Message "Removed wt-agent-hooks entry from copilot config (simulated not-installed baseline)"
}
