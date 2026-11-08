#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force

    $script:readyPath = Join-Path $TestDrive 'input-probe-ready.json'
    $script:eventPath = Join-Path $TestDrive 'input-probe-events.jsonl'
    $fixture = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Win32InputProbe.ps1')).Path
    $pwsh = (Get-Process -Id $PID).Path
    $script:probe = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-Sta',
        '-File', "`"$fixture`"",
        '-ReadyPath', "`"$script:readyPath`"",
        '-EventPath', "`"$script:eventPath`""
    ) -PassThru

    $script:ready = Wait-Until -TimeoutSec 15 -IntervalSec 0.1 -Because 'the input probe window to open' -Condition {
        if (Test-Path -LiteralPath $script:readyPath) {
            Get-Content -LiteralPath $script:readyPath -Raw | ConvertFrom-Json
        }
    }
    $script:app = [pscustomobject]@{
        Pid = [int]$script:ready.pid
        Hwnd = [int64]$script:ready.hwnd
    }

    function Reset-ProbeEvents {
        Set-Content -LiteralPath $script:eventPath -Value '' -Encoding utf8
    }

    function Wait-ProbeEvents {
        param(
            [Parameter(Mandatory)][int]$Count,
            [string]$Type
        )

        Wait-Until -TimeoutSec 5 -IntervalSec 0.05 -Because "$Count '$Type' input probe event(s)" -Condition {
            $events = @(Get-Content -LiteralPath $script:eventPath -ErrorAction SilentlyContinue |
                    Where-Object { $_.Trim() } |
                    ForEach-Object { $_ | ConvertFrom-Json })
            $selected = if ($Type) { @($events | Where-Object type -eq $Type) } else { $events }
            if ($selected.Count -ge $Count) { $events }
        }
    }
}

AfterAll {
    if ($script:probe -and -not $script:probe.HasExited) {
        Stop-Process -Id $script:probe.Id -Force -ErrorAction SilentlyContinue
        $script:probe.WaitForExit(5000) | Out-Null
    }
}

Describe 'Local TDD Win32 input capabilities' -Tag 'Input' {
    It 'binds the HWND to the process started by the test' {
        $identity = Get-WtWindowIdentity -App $script:app

        $identity.Hwnd | Should -Be $script:ready.hwnd
        $identity.ProcessId | Should -Be $script:probe.Id
        $identity.IsVisible | Should -BeTrue
        $identity.ClientWidth | Should -BeGreaterThan 0
        $identity.ClientHeight | Should -BeGreaterThan 0

        $wrongOwner = [pscustomobject]@{ Pid = $script:probe.Id + 1; Hwnd = $script:ready.hwnd }
        { Get-WtWindowIdentity -App $wrongOwner } | Should -Throw '*belongs to process*'
    }

    It 'resolves exact UI text geometry inside the owned window' {
        $bounds = Get-UiTextBounds -App $script:app -Text $script:ready.textMarker -RequireUnique

        $bounds.OccurrenceCount | Should -Be 1
        $bounds.Width | Should -BeGreaterThan 0
        $bounds.Height | Should -BeGreaterThan 0
        $bounds.ClientCenterX | Should -BeGreaterThan 0
        $bounds.ClientCenterX | Should -BeLessThan $script:ready.clientWidth
        $bounds.ClientCenterY | Should -BeGreaterThan 0
        $bounds.ClientCenterY | Should -BeLessThan $script:ready.clientHeight
    }

    It 'sends left and right single clicks at client coordinates' {
        foreach ($button in @('Left', 'Right')) {
            Reset-ProbeEvents
            $sent = @(Invoke-WtWindowMouse -App $script:app -X 120 -Y 90 -Button $button -ClickCount 1)[-1]
            $events = @(Wait-ProbeEvents -Count 1 -Type 'mouse-up')

            @($events | Where-Object type -eq 'mouse-down').Count | Should -Be 1
            @($events | Where-Object type -eq 'mouse-up').Count | Should -Be 1
            @($events | Where-Object type -eq 'mouse-down')[0].button | Should -Be $button
            @($events | Where-Object type -eq 'mouse-down')[0].screenX |
                Should -BeIn @(($sent.ScreenX - 1), $sent.ScreenX, ($sent.ScreenX + 1))
            @($events | Where-Object type -eq 'mouse-down')[0].screenY |
                Should -BeIn @(($sent.ScreenY - 1), $sent.ScreenY, ($sent.ScreenY + 1))
        }
    }

    It 'sends left and right double clicks as two complete click pairs' {
        foreach ($button in @('Left', 'Right')) {
            Reset-ProbeEvents
            Invoke-WtWindowMouse -App $script:app -X 180 -Y 130 -Button $button -ClickCount 2 | Out-Null
            $events = @(Wait-ProbeEvents -Count 2 -Type 'mouse-up')

            @($events | Where-Object type -eq 'mouse-down').Count | Should -Be 2
            @($events | Where-Object type -eq 'mouse-up').Count | Should -Be 2
            @($events | Where-Object type -eq 'mouse-down' | Where-Object button -eq $button).Count | Should -Be 2
        }
    }

    It 'drags from one client coordinate to another' {
        Test-WtPhysicalInputReady -App $script:app | Should -BeTrue
        Reset-ProbeEvents
        $sent = @(Invoke-WtWindowDrag -App $script:app -FromX 80 -FromY 70 -ToX 260 -ToY 190 -Button Left)[-1]
        $events = @(Wait-ProbeEvents -Count 1 -Type 'mouse-up')

        $down = @($events | Where-Object type -eq 'mouse-down') | Select-Object -First 1
        $up = @($events | Where-Object type -eq 'mouse-up') | Select-Object -First 1
        $moves = @($events | Where-Object type -eq 'mouse-move')
        $down.button | Should -Be 'Left'
        $down.screenX | Should -BeIn @(($sent.FromScreenX - 1), $sent.FromScreenX, ($sent.FromScreenX + 1))
        $down.screenY | Should -BeIn @(($sent.FromScreenY - 1), $sent.FromScreenY, ($sent.FromScreenY + 1))
        $up.screenX | Should -BeIn @(($sent.ToScreenX - 1), $sent.ToScreenX, ($sent.ToScreenX + 1))
        $up.screenY | Should -BeIn @(($sent.ToScreenY - 1), $sent.ToScreenY, ($sent.ToScreenY + 1))
        $moves.Count | Should -BeGreaterThan 0
    }

    It 'sends physical wheel input and preserves modifier semantics' {
        Test-WtPhysicalInputReady -App $script:app | Should -BeTrue

        Reset-ProbeEvents
        Invoke-WtWindowWheel -App $script:app -X 220 -Y 160 -Delta 120 | Out-Null
        $plain = @(Wait-ProbeEvents -Count 1 -Type 'mouse-wheel' | Where-Object type -eq 'mouse-wheel')[0]
        $plain.delta | Should -Be 120
        $plain.control | Should -BeFalse

        Reset-ProbeEvents
        Invoke-WtWindowWheel -App $script:app -X 220 -Y 160 -Delta -120 -Ctrl | Out-Null
        $modified = @(Wait-ProbeEvents -Count 1 -Type 'mouse-wheel' | Where-Object type -eq 'mouse-wheel')[0]
        $modified.delta | Should -Be -120
        $modified.control | Should -BeTrue
    }

    It 'does not release a modifier that was already held before wheel injection' {
        Test-WtPhysicalInputReady -App $script:app | Should -BeTrue
        [ItE2E.ItWtWin32Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try {
            Wait-Until -TimeoutSec 2 -IntervalSec 0.05 -Because 'Ctrl to become physically held' -Condition {
                [ItE2E.ItWtWin32Input]::IsKeyDown(0x11)
            } | Out-Null

            Invoke-WtWindowWheel -App $script:app -X 220 -Y 160 -Delta 120 -Ctrl | Out-Null

            [ItE2E.ItWtWin32Input]::IsKeyDown(0x11) | Should -BeTrue
        }
        finally {
            [ItE2E.ItWtWin32Input]::keybd_event(0x11, 0, 0x2, [UIntPtr]::Zero)
        }
    }

    It 'does not release a modifier that was already held before key injection' {
        Test-WtPhysicalInputReady -App $script:app | Should -BeTrue
        [ItE2E.ItWtWin32Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try {
            Wait-Until -TimeoutSec 2 -IntervalSec 0.05 -Because 'Ctrl to become physically held' -Condition {
                [ItE2E.ItWtWin32Input]::IsKeyDown(0x11)
            } | Out-Null

            Send-WtWindowKey -App $script:app -Vk 0x50 -Ctrl -RequireForeground | Out-Null

            [ItE2E.ItWtWin32Input]::IsKeyDown(0x11) | Should -BeTrue
        }
        finally {
            [ItE2E.ItWtWin32Input]::keybd_event(0x11, 0, 0x2, [UIntPtr]::Zero)
        }
    }

    It 'sends named arrow, Enter, and modified key chords to the target window' {
        Reset-ProbeEvents
        Send-WtWindowKeyChord -App $script:app -Chord @('Up', 'Enter', 'Ctrl+Shift+P') | Out-Null
        $events = @(Wait-ProbeEvents -Count 3 -Type 'key-down')
        $downs = @($events | Where-Object type -eq 'key-down')

        $downs.key | Should -Contain 'Up'
        $downs.key | Should -Contain 'Enter'
        $modified = $downs | Where-Object key -eq 'P' | Select-Object -First 1
        $modified.control | Should -BeTrue
        $modified.shift | Should -BeTrue
    }
}