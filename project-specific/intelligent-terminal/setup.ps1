[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Preflight', 'Plan', 'Apply', 'Verify')][string]$Phase,
    [Parameter(Mandatory)][Collections.IDictionary]$Context,
    [Parameter(Mandatory)][Collections.IDictionary]$Parameters
)

if ($Phase -eq 'Preflight') {
    if ($Parameters.ComClsid) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($Parameters.ComClsid, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw 'Project.ComClsid must be a non-empty GUID when supplied.'
        }
    }
    if ($Parameters.CopilotConfigPath -and -not [IO.Path]::IsPathFullyQualified($Parameters.CopilotConfigPath)) {
        throw 'Project.CopilotConfigPath must be an absolute path when supplied.'
    }
}

if ($Phase -eq 'Plan') {
    $directories = @()
    if ($Parameters.IncludeTools) { $directories = @('tools') }
    return @{ Instructions = @('templates/AGENTS.md'); ToolDirectories = $directories }
}
@{ Status = 'passed' }
