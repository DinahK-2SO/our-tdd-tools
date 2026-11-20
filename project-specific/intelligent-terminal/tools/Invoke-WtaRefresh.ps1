[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$NativeReceiptPath,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$PackageSelector = 'Dev',
    [string]$PublicationPath,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$ExpectedHead,
    [ValidateSet('Debug')][string]$Configuration = 'Debug',
    [switch]$SkipWtaTests
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalTdd.WtaRefresh.psm1') -Force
Invoke-LocalTddWtaRefresh @PSBoundParameters
