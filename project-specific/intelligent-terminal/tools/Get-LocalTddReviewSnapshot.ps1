[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublicationPath,
    [Parameter(Mandatory)][string]$OutPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalTdd.Acceptance.psm1')
Import-Module (Join-Path $PSScriptRoot 'LocalTdd.Evidence.psm1') -Force
if (Test-Path -LiteralPath $OutPath) { throw 'Use a new review snapshot path.' }
$snapshot = Get-LocalTddReviewSnapshot -PublicationPath $PublicationPath
Write-LocalTddEvidenceJson -Path $OutPath -Value $snapshot
[pscustomobject]@{ path = [IO.Path]::GetFullPath($OutPath); dataSha256 = $snapshot.dataSha256 }
