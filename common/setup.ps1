[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Preflight', 'Plan', 'Apply', 'Verify')][string]$Phase,
    [Parameter(Mandatory)][Collections.IDictionary]$Context,
    [Parameter(Mandatory)][Collections.IDictionary]$Parameters
)

if ($Phase -eq 'Plan') {
    return @{ Instructions = @('templates/AGENTS.md'); ToolDirectories = @('tools') }
}
@{ Status = 'passed' }
