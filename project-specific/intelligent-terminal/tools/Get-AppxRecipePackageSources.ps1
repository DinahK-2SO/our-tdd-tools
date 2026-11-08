[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

[xml]$xml = Get-Content -LiteralPath $Path -Raw
$sources = [ordered]@{}
foreach ($item in $xml.SelectNodes("//*[local-name()='AppxPackagedFile']")) {
    $packagePath = [string]$item.SelectSingleNode("*[local-name()='PackagePath']").InnerText
    if (-not $packagePath -or -not $item.Include) {
        throw "Package recipe contains an incomplete AppxPackagedFile entry: $Path"
    }
    if ($sources.Contains($packagePath)) {
        throw "Package recipe contains duplicate package path '$packagePath': $Path"
    }

    $decodedSource = [Uri]::UnescapeDataString([string]$item.Include)
    $sources[$packagePath] = [IO.Path]::GetFullPath($decodedSource)
}
if ($sources.Count -eq 0) {
    throw "Package recipe contains no packaged files: $Path"
}

$sources
