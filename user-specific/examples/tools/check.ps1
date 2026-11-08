[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

if (-not (Test-Path -LiteralPath $Path)) { throw "Required local path is missing: $Path" }
[pscustomobject]@{ Status = 'passed'; Path = [IO.Path]::GetFullPath($Path) }
