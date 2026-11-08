function Get-WinpdCopilotExecutable {
    $command = Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1
    return $command.Source
}

function Invoke-WinpdCopilotJudge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorizationPath,
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Head,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [switch]$AllowInference
    )
    if (-not $AllowInference) { throw 'A real judge request requires explicit -AllowInference.' }
    $authorization = Read-WinpdAuthorization $AuthorizationPath
    $executable = Get-WinpdCopilotExecutable
    $request = Reserve-WinpdRequest -AuthorizationPath $AuthorizationPath -BudgetPath $BudgetPath -Head $Head -RunId $RunId
    $instruction = "Return only a JSON object with Boolean pass, numeric confidence from 0 to 1, and string reason.`n`n$Prompt"
    $arguments = @('-p', $instruction)
    if ($Model) { $arguments += @('--model', $Model) }
    $literalArguments = @($arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $commandText = "& '" + $executable.Replace("'", "''") + "' @($literalArguments); exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
    $shell = (Get-Process -Id $PID).Path
    try {
        Set-WinpdRequestOutcome -BudgetPath $BudgetPath -AttemptId $request.id -Outcome submitted
        $result = Invoke-WinpdProcess -FilePath $shell `
            -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
            -TimeoutSec $authorization.timeoutSeconds
        if ($result.TimedOut -or $result.ExitCode -ne 0) { throw 'The bounded provider judge request failed or timed out.' }
        $text = $result.StdOut.Trim()
        if ($text.StartsWith('```')) { $text = $text -replace '^```(?:json)?\s*|\s*```$', '' }
        $verdict = $text | ConvertFrom-Json -AsHashtable
        if ($verdict -isnot [Collections.IDictionary] -or $verdict['pass'] -isnot [bool] -or
            $verdict['reason'] -isnot [string] -or
            ($verdict['confidence'] -isnot [double] -and $verdict['confidence'] -isnot [long] -and $verdict['confidence'] -isnot [int]) -or
            -not [double]::IsFinite([double]$verdict.confidence) -or
            $verdict.confidence -lt 0 -or $verdict.confidence -gt 1) {
            throw 'The provider did not return a valid Boolean verdict with bounded confidence.'
        }
        Set-WinpdRequestOutcome -BudgetPath $BudgetPath -AttemptId $request.id -Outcome passed
        return [pscustomobject]@{
            pass = $verdict.pass; confidence = $verdict.confidence; reason = $verdict.reason
            provider = 'copilot'; requestId = $request.id
        }
    }
    catch {
        Set-WinpdRequestOutcome -BudgetPath $BudgetPath -AttemptId $request.id -Outcome failed
        throw
    }
}
