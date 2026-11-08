#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Process.ps1')
Export-ModuleMember -Function Write-WinpdEvidenceJson, Get-WinpdEvidenceHash, Invoke-WinpdProcess
