[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ContractPath,
    [Parameter(Mandatory)][string]$OutPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalTdd.Evidence.psm1') -Force
Complete-LocalTddAcceptance @PSBoundParameters
