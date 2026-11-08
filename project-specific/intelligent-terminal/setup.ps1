[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Preflight', 'Plan', 'Apply', 'Verify')][string]$Phase,
    [Parameter(Mandatory)][Collections.IDictionary]$Context,
    [Parameter(Mandatory)][Collections.IDictionary]$Parameters
)

if ($Phase -eq 'Plan') {
    $directories = @()
    if ($Parameters.IncludeTools) { $directories = @('tools') }
    return @{ Instructions = @('templates/AGENTS.md'); ToolDirectories = $directories }
}
@{ Status = 'passed' }
