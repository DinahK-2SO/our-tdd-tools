#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$HeadRef = 'HEAD',
    [string[]]$TextPath = @()
)

$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\common\tools\github\Test-WinpdPublication.ps1'))
& $scriptPath @PSBoundParameters
