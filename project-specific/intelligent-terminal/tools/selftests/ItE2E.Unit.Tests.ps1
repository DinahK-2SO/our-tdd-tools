#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Hermetic unit tests for the ItE2E framework core. No deployed terminal required.
#   Invoke-Pester local-tdd-kit/selftests -Tag Unit

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
}

Describe 'Invoke-Native' -Tag 'Unit' {
    It 'captures stdout and a zero exit code' {
        $r = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'echo', 'hello-ite2e')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'hello-ite2e'
    }

    It 'propagates a non-zero exit code' {
        (Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit', '7')).ExitCode | Should -Be 7
    }

    It 'does NOT truncate large output (regression for the async-read race)' {
        # Produce ~500 lines; the old Register-ObjectEvent impl truncated to a few bytes.
        $r = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'for /L %i in (1,1,500) do @echo line%i')
        $r.ExitCode | Should -Be 0
        ([regex]::Matches($r.StdOut, 'line\d+')).Count | Should -Be 500
    }

    It 'times out and flags TimedOut' {
        $r = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'ping', '-n', '10', '127.0.0.1') -TimeoutSec 1
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be -1
    }
}

Describe 'Wait-Until / Test-Until' -Tag 'Unit' {
    It 'returns the truthy value once the condition holds' {
        $script:n = 0
        $v = Wait-Until -TimeoutSec 5 -IntervalSec 0.1 -Condition { $script:n++; if ($script:n -ge 3) { 'ready' } else { $null } }
        $v | Should -Be 'ready'
    }

    Describe 'Artifact and geometry helpers' -Tag 'Unit' {
        It 'keeps artifact paths inside the run-scoped root' {
            $prior = $env:ITE2E_ARTIFACT_ROOT
            try {
                $env:ITE2E_ARTIFACT_ROOT = Join-Path $TestDrive 'run-artifacts'
                $path = Get-ItArtifactPath -ChildPath 'screenshots\before.png' -CreateParent

                $path | Should -Be (Join-Path $env:ITE2E_ARTIFACT_ROOT 'screenshots\before.png')
                Test-Path -LiteralPath (Split-Path $path -Parent) | Should -BeTrue
                { Get-ItArtifactPath -ChildPath '..\escape.txt' } | Should -Throw '*escapes the run root*'
            }
            finally {
                if ($null -eq $prior) { Remove-Item Env:ITE2E_ARTIFACT_ROOT -ErrorAction SilentlyContinue }
                else { $env:ITE2E_ARTIFACT_ROOT = $prior }
            }
        }

        It 'measures rendered width independently from row count' {
            $geometry = Get-WtCaptureGeometry -Text "short`n123456789`n"

            $geometry.Rows | Should -Be 3
            $geometry.NonEmptyRows | Should -Be 2
            $geometry.Columns | Should -Be 9
            $geometry.LineWidths | Should -Be @(5, 9, 0)
        }

        It 'measures terminal cells for CJK, combining text, emoji, and tabs' {
            $geometry = Get-WtCaptureGeometry -Text "界`ne$([char]0x0301)`n😀`na`tZ`n❤️`n🇺🇸`n1️⃣`n1⃣`n🏳`n🏳️`n🖥`n🖥️"

            $geometry.LineWidths | Should -Be @(2, 1, 2, 9, 2, 2, 2, 1, 1, 2, 1, 2)
            $geometry.Columns | Should -Be 9
        }
    }
    It 'throws on timeout' {
        { Wait-Until -TimeoutSec 1 -IntervalSec 0.2 -Condition { $false } -Because 'never' } | Should -Throw
    }
    It 'Test-Until returns a boolean and never throws' {
        Test-Until -TimeoutSec 1 -IntervalSec 0.2 -Condition { $false } | Should -BeFalse
        Test-Until -TimeoutSec 2 -IntervalSec 0.1 -Condition { $true } | Should -BeTrue
    }
}

Describe 'JSON helpers' -Tag 'Unit' {
    It 'ConvertFrom-JsonSafe returns $null on garbage' {
        ConvertFrom-JsonSafe -InputObject 'not json {' | Should -BeNullOrEmpty
        ConvertFrom-JsonSafe -InputObject '' | Should -BeNullOrEmpty
    }
    It 'ConvertFrom-JsonSafe parses valid JSON' {
        (ConvertFrom-JsonSafe -InputObject '{"a":1,"b":[2,3]}').b[1] | Should -Be 3
    }
    It 'ConvertFrom-JsonC strips // comments and trailing commas' {
        $jsonc = @"
{
    // a comment
    "acpAgent": "copilot",
    "autoFixEnabled": true,
}
"@
        $o = ConvertFrom-JsonC -Text $jsonc
        $o.acpAgent | Should -Be 'copilot'
        $o.autoFixEnabled | Should -BeTrue
    }

    It 'Set-WtSetting verifies nested object arrays structurally' {
        $settingsPath = Join-Path $TestDrive 'nested-settings.json'
        '{}' | Set-Content -LiteralPath $settingsPath -Encoding utf8
        $app = [pscustomobject]@{ SettingsPath = $settingsPath }
        $providers = @(@{
            id = 'provider-local'
            models = @(@{ id = 'test-model'; name = 'Test Model' })
        })

        Set-WtSetting -App $app -Key 'customModelProviders' -Value $providers | Out-Null

        $stored = Get-WtSetting -App $app -Key 'customModelProviders'
        @($stored) | Should -HaveCount 1
        $stored[0].id | Should -Be 'provider-local'
        $stored[0].models[0].name | Should -Be 'Test Model'
    }
}

Describe 'AI oracle safety' -Tag 'Unit' {
    It 'requires explicit opt-in before invoking an external provider' {
        $previous = $env:ITE2E_ENABLE_AI_ORACLE
        try {
            Remove-Item Env:ITE2E_ENABLE_AI_ORACLE -ErrorAction SilentlyContinue
            { Invoke-AgentJudge -Prompt 'do not send this' } | Should -Throw '*disabled by default*'
        }
        finally {
            if ($null -eq $previous) {
                Remove-Item Env:ITE2E_ENABLE_AI_ORACLE -ErrorAction SilentlyContinue
            }
            else {
                $env:ITE2E_ENABLE_AI_ORACLE = $previous
            }
        }
    }
}

Describe 'Agent settings cleanup' -Tag 'Unit' {
    It 'removes showTokenUsageAndCost while preserving profiles' {
        $settingsPath = Join-Path $TestDrive 'settings.json'
        @{
            defaultProfile = '{6239a42c-1111-49a3-80bd-e8fdd045185c}'
            profiles = @(@{
                name = 'p0'
                guid = '{6239a42c-1111-49a3-80bd-e8fdd045185c}'
            })
            acpAgent = 'copilot'
            showTokenUsageAndCost = $true
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8
        $app = [pscustomobject]@{ SettingsPath = $settingsPath }

        Clear-WtConfig -App $app

        $settings = Get-WtSettingsObject -App $app
        $settings.PSObject.Properties.Name | Should -Not -Contain 'showTokenUsageAndCost'
        $settings.PSObject.Properties.Name | Should -Not -Contain 'acpAgent'
        $settings.profiles[0].name | Should -Be 'p0'
    }
}

Describe 'Config backup transaction' -Tag 'Unit' {
    It 'restores existing config files byte-for-byte' {
        $root = Join-Path $TestDrive 'existing-config'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $app = [pscustomobject]@{
            SettingsPath = Join-Path $root 'settings.json'
            StatePath = Join-Path $root 'state.json'
        }
        '{"setting":"original"}' | Set-Content -LiteralPath $app.SettingsPath -Encoding utf8
        '{"state":"original"}' | Set-Content -LiteralPath $app.StatePath -Encoding utf8
        $settingsHash = (Get-FileHash -LiteralPath $app.SettingsPath -Algorithm SHA256).Hash
        $stateHash = (Get-FileHash -LiteralPath $app.StatePath -Algorithm SHA256).Hash

        Backup-WtConfig -App $app
        '{}' | Set-Content -LiteralPath $app.SettingsPath -Encoding utf8
        '{}' | Set-Content -LiteralPath $app.StatePath -Encoding utf8
        Restore-WtConfig -App $app

        (Get-FileHash -LiteralPath $app.SettingsPath -Algorithm SHA256).Hash | Should -Be $settingsHash
        (Get-FileHash -LiteralPath $app.StatePath -Algorithm SHA256).Hash | Should -Be $stateHash
    }

    It 'restores an originally missing config file to the missing state' {
        $root = Join-Path $TestDrive 'missing-config'
        $app = [pscustomobject]@{
            SettingsPath = Join-Path $root 'settings.json'
            StatePath = Join-Path $root 'state.json'
        }

        Backup-WtConfig -App $app
        "$($app.SettingsPath).e2ebak.missing" | Should -Exist
        "$($app.StatePath).e2ebak.missing" | Should -Exist
        '{}' | Set-Content -LiteralPath $app.SettingsPath -Encoding utf8 -ErrorAction Stop
        '{"agentFreCompleted":true}' | Set-Content -LiteralPath $app.StatePath -Encoding utf8 -ErrorAction Stop
        Restore-WtConfig -App $app

        $app.SettingsPath | Should -Not -Exist
        $app.StatePath | Should -Not -Exist
        "$($app.SettingsPath).e2ebak.missing" | Should -Not -Exist
        "$($app.StatePath).e2ebak.missing" | Should -Not -Exist
    }

    It 'recovers a missing-file transaction left by a crashed run' {
        $root = Join-Path $TestDrive 'crashed-missing-config'
        $app = [pscustomobject]@{
            SettingsPath = Join-Path $root 'settings.json'
            StatePath = Join-Path $root 'state.json'
        }

        Backup-WtConfig -App $app
        "$($app.SettingsPath).e2ebak.missing" | Should -Exist
        "$($app.StatePath).e2ebak.missing" | Should -Exist
        '{}' | Set-Content -LiteralPath $app.SettingsPath -Encoding utf8 -ErrorAction Stop
        '{"agentFreCompleted":true}' | Set-Content -LiteralPath $app.StatePath -Encoding utf8 -ErrorAction Stop
        Backup-WtConfig -App $app

        $app.SettingsPath | Should -Not -Exist
        $app.StatePath | Should -Not -Exist
        "$($app.SettingsPath).e2ebak.missing" | Should -Exist
        "$($app.StatePath).e2ebak.missing" | Should -Exist
        Restore-WtConfig -App $app
    }
}

Describe 'Foreground input lease' -Tag 'Unit' {
    It 'rejects a concurrent live input owner in another process' {
        $ready = Join-Path $TestDrive 'lease-ready.txt'
        $holder = @"
`$mutex = [Threading.Mutex]::new(`$false, 'Local\IntelligentTerminal.LocalTdd.ForegroundInput')
try {
    [void]`$mutex.WaitOne()
    Set-Content -LiteralPath '$($ready.Replace("'", "''"))' -Value ready
    Start-Sleep -Seconds 20
}
finally {
    try { `$mutex.ReleaseMutex() } catch {}
    `$mutex.Dispose()
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holder))
        $process = Start-Process pwsh -ArgumentList '-NoProfile', '-EncodedCommand', $encoded -PassThru
        try {
            Wait-Until -TimeoutSec 10 -IntervalSec 0.1 -Because 'input lease holder readiness' -Condition {
                Test-Path -LiteralPath $ready
            } | Out-Null
            { Enter-ItForegroundInputLease -TimeoutSec 1 } | Should -Throw '*foreground-input lease*'
        }
        finally {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            $process.WaitForExit(5000) | Out-Null
        }
    }
}

Describe 'UI Automation geometry contract' -Tag 'Unit' {
    It 'exports exact text geometry and physical drag primitives' {
        (Get-Command Get-UiTextBounds -Module ItE2E) | Should -Not -BeNullOrEmpty
        (Get-Command Invoke-WtWindowDrag -Module ItE2E) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Resolve-ItApp' -Tag 'Unit' {
    It 'resolves a descriptor with the expected shape when a package is installed' {
        $installed = Get-AppxPackage | Where-Object { $_.Name -like '*IntelligentTerminal*' }
        if (-not $installed) { Set-ItResult -Skipped -Because 'no IT package installed'; return }
        $app = Resolve-ItApp -Package Auto
        $app.Package | Should -Match 'IntelligentTerminal'
        $app.AppUserModelId | Should -Match '!'
        $app.SettingsPath | Should -Match 'LocalState\\settings\.json$'
        $app.WtcliPath | Should -Not -BeNullOrEmpty
    }
}

Describe 'Start-Terminal startup ordering' -Tag 'Unit' {
    It 'refuses to close pre-existing Intelligent Terminal processes without explicit opt-in' {
        InModuleScope ItE2E {
            $root = Join-Path $env:TEMP "ite2e-existing-process-$PID"
            $fakeApp = [pscustomobject]@{
                Package = 'IntelligentTerminal_rd9vj3e6a2mbr'
                Version = '0.0.0.0'
                WtcliPath = 'wtcli.exe'
                LocalStateDir = $root
                SettingsPath = Join-Path $root 'settings.json'
                StatePath = Join-Path $root 'state.json'
                AppUserModelId = 'IntelligentTerminal_rd9vj3e6a2mbr!App'
                LaunchAlias = $null
                ComClsid = $null
                Pid = $null
                Hwnd = $null
            }

            Mock Resolve-ItApp { $fakeApp }
            Mock Enter-ItForegroundInputLease { [pscustomobject]@{} }
            Mock Exit-ItForegroundInputLease
            Mock Get-RunningItProcesses { [pscustomobject]@{ Id = 4242; ProcessName = 'WindowsTerminal' } }
            Mock Stop-StaleItInstances
            Mock Start-Process

            { Start-Terminal -Package Dev -PassFre $false -Backup $false -CleanSettings $false } |
                Should -Throw '*already running*CloseExistingInstances*'
            Should -Invoke Stop-StaleItInstances -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Exit-ItForegroundInputLease -Times 1 -Exactly
        }
    }

    It 'waits for the first window before probing COM' {
        InModuleScope ItE2E {
            $script:startupOrder = @()
            $root = Join-Path $env:TEMP "ite2e-startup-order-$PID"
            $fakeApp = [pscustomobject]@{
                Package = 'IntelligentTerminal_rd9vj3e6a2mbr'
                Version = '0.0.0.0'
                WtcliPath = 'wtcli.exe'
                LocalStateDir = $root
                SettingsPath = Join-Path $root 'settings.json'
                StatePath = Join-Path $root 'state.json'
                AppUserModelId = 'IntelligentTerminal_rd9vj3e6a2mbr!App'
                LaunchAlias = $null
                ComClsid = $null
                Pid = $null
                Hwnd = $null
            }

            Mock Resolve-ItApp { $fakeApp }
            Mock Enter-ItForegroundInputLease { [pscustomobject]@{} }
            Mock Exit-ItForegroundInputLease
            Mock Get-RunningItProcesses { [pscustomobject]@{ Id = 31337; ProcessName = 'WindowsTerminal' } }
            Mock Stop-StaleItInstances
            Mock Get-WtProcessesForApp { [pscustomobject]@{ Id = 4242 } }
            Mock Start-Process
            Mock Get-WtWindowHwnds {
                $script:startupOrder += 'hwnd'
                [pscustomobject]@{ pid = 4242; hwnd = 9001; title = 'PowerShell' }
            }
            Mock Resolve-WtComClsid {
                $script:startupOrder += 'com'
                '{D5B7C9E1-4F6A-4B8C-D9E0-F1A2B3C4D5E6}'
            }
            Mock Get-ActivePane { [pscustomobject]@{ window_id = 1 } }
            Mock Initialize-LogOffsets
            Mock Write-ItLog

            $app = Start-Terminal -Package Dev -PassFre $false -Backup $false -CleanSettings $false `
                -CloseExistingInstances

            $app.Hwnd | Should -Be 9001
            $script:startupOrder | Should -Be @('hwnd', 'com')
            Should -Invoke Stop-StaleItInstances -Times 1 -Exactly
        }
    }

    It 'restores config and stops a newly launched process when startup fails' {
        InModuleScope ItE2E {
            $root = Join-Path $env:TEMP "ite2e-startup-rollback-$PID"
            $fakeApp = [pscustomobject]@{
                Package = 'IntelligentTerminal_rd9vj3e6a2mbr'
                Version = '0.0.0.0'
                WtcliPath = 'wtcli.exe'
                LocalStateDir = $root
                SettingsPath = Join-Path $root 'settings.json'
                StatePath = Join-Path $root 'state.json'
                AppUserModelId = 'IntelligentTerminal_rd9vj3e6a2mbr!App'
                LaunchAlias = $null
                ComClsid = $null
                Pid = $null
                Hwnd = $null
            }
            $fakeProcess = [pscustomobject]@{ Id = 4242 }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $true }
            $script:processLookup = 0

            Mock Resolve-ItApp { $fakeApp }
            Mock Enter-ItForegroundInputLease { [pscustomobject]@{} }
            Mock Exit-ItForegroundInputLease
            Mock Get-RunningItProcesses { @() }
            Mock Stop-StaleItInstances
            Mock Backup-WtConfig
            Mock Clear-WtConfig
            Mock Invoke-FrePass
            Mock Start-Process
            Mock Get-WtProcessesForApp {
                $script:processLookup++
                if ($script:processLookup -eq 1) { @() } else { $fakeProcess }
            }
            Mock Get-WtWindowHwnds { [pscustomobject]@{ pid = 4242; hwnd = 9001; title = 'PowerShell' } }
            Mock Resolve-WtComClsid { throw 'expected COM failure' }
            Mock Restore-WtConfig
            Mock Get-Process { $fakeProcess }
            Mock Stop-Process
            Mock Write-ItLog

            { Start-Terminal -Package Dev -SuppressCloseConfirmation $false } | Should -Throw '*expected COM failure*'
            Should -Invoke Restore-WtConfig -Times 1 -Exactly
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 -and $Force }
            Should -Invoke Exit-ItForegroundInputLease -Times 1 -Exactly
        }
    }
}
