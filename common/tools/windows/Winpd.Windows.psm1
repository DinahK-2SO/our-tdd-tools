#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Process.ps1')
. (Join-Path $PSScriptRoot 'Windows.ps1')
Export-ModuleMember -Function Get-WinpdWindowIdentity, Invoke-WinpdWindowUi, Save-WinpdWindowScreenshot
