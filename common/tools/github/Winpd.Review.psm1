#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Core.ps1')
. (Join-Path $PSScriptRoot 'Review.ps1')
. (Join-Path $PSScriptRoot 'Watch.ps1')
Export-ModuleMember -Function Get-WinpdReviewSnapshot, Watch-WinpdPullRequest
