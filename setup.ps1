#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [Collections.IDictionary]$Common = @{},
    [Collections.IDictionary]$Project = @{},
    [Collections.IDictionary]$User = @{},
    [switch]$Plan
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\Winpd.Setup.psm1') -Force
if (-not $User.Contains('ProfilePath') -and $env:WINPD_USER_PROFILE) {
    $copy = @{}
    foreach ($key in $User.Keys) { $copy[$key] = $User[$key] }
    $copy.ProfilePath = $env:WINPD_USER_PROFILE
    $User = $copy
}
$resolved = New-WinpdSetupPlan -ToolkitRoot $PSScriptRoot -Common $Common -Project $Project -User $User
if ($Plan -or $WhatIfPreference) { return $resolved }
if ($PSCmdlet.ShouldProcess($resolved.Repository.Root, 'Prepare layered TDD worktrees and an unfilled contract')) {
    Invoke-WinpdSetup -Plan $resolved -Confirm:$false
}
