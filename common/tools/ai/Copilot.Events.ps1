function Read-WinpdCopilotEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    # The writer may still be appending the last JSONL record. Invalid complete lines remain errors.
    $lastNewline = $text.LastIndexOf("`n")
    if ($lastNewline -lt 0) { return }
    foreach ($line in $text.Substring(0, $lastNewline).Split("`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $event = $line | ConvertFrom-Json -AsHashtable
            if (-not $event.type -or $event.data -isnot [Collections.IDictionary]) {
                throw 'Invalid complete Copilot event record.'
            }
            $event
        }
    }
}
