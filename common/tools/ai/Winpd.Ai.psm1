#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Core.ps1')
. (Join-Path $PSScriptRoot '..\Process.ps1')
. (Join-Path $PSScriptRoot 'Budget.ps1')
. (Join-Path $PSScriptRoot 'Copilot.Events.ps1')
. (Join-Path $PSScriptRoot 'Judge.ps1')
Export-ModuleMember -Function Read-WinpdAuthorization, Reserve-WinpdRequest, Set-WinpdRequestOutcome,
    Read-WinpdCopilotEvents, Invoke-WinpdCopilotJudge
