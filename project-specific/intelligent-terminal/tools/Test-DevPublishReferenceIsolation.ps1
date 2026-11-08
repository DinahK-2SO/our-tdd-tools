#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$PublishPullRequestNumber = $env:LOCAL_TDD_PUBLISH_PR_NUMBER,
    [string]$PublishBranch = $env:LOCAL_TDD_PUBLISH_BRANCH
)

$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\common\tools\github\Test-WinpdReferenceIsolation.ps1'))
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
$arguments.PublishPullRequestNumber = $PublishPullRequestNumber
$arguments.PublishBranch = $PublishBranch
& $scriptPath @arguments
