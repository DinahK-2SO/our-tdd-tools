# Local TDD Tools and Installation

This kit is local-only. It does not add a pipeline, scheduled task, GitHub Action,
Azure DevOps step, or release-checklist entry.

## Install

From `cmd.exe` on a fresh Windows machine:

```cmd
local-tdd-kit\install-tools.cmd
```

The command file uses `winget` to install PowerShell 7, Git and Rustup when
needed. Then `bootstrap.ps1` installs Pester and Windows App CLI when missing,
and verifies:

- Pester 5.5 or newer (`Install-Module`, current-user scope)
- Windows App CLI (`winget install Microsoft.WinAppCli`)
- PowerShell 7.2 or newer
- Git

Run a non-mutating check at any time:

```powershell
pwsh -File local-tdd-kit/bootstrap.ps1 -Check
```

Rust/Cargo and Visual Studio are required only to build product code. The command
file installs Rustup; allow Rustup to install the repository's requested toolchain.
Install the Visual Studio version and workloads required by the current
repository `.vsconfig`; the kit intentionally does not automate a system-wide
Visual Studio installation or elevation.

## Tool Ownership

| Tool | Purpose | Installation/Source |
|---|---|---|
| PowerShell 7 | Scripts, fixtures, orchestration | `install-tools.cmd` |
| Pester | Unit and live test runner | `bootstrap.ps1` |
| Windows App CLI (`winapp ui`) | Window enumeration, UIA inspect/search/invoke/value/wait, screenshots | `bootstrap.ps1` |
| `wtcli.exe` | Package-scoped tabs, panes, input, capture and event stream | Co-located in deployed package |
| `wta.exe` | Agent helper/master and test target | Built by Cargo, co-located in package |
| Win32 `user32.dll` | Verified foreground window, client-coordinate mouse and OS keyboard input | Windows built-in; no install |
| Cargo/Rust | Build/test WTA | `rustup` |
| MSBuild/DeployAppRecipe | Build and register CascadiaPackage | Visual Studio + Windows SDK |
| Git | Source identity and build receipt fingerprint | `install-tools.cmd` |

Optional policy tests use `tools/Enable-WtAgentPolicyTesting.ps1`. It displays a
UAC prompt and grants the current user write access only to the Intelligent
Terminal policy test key. Restore with `tools/Disable-WtAgentPolicyTesting.ps1`.
Do not run either script unless the issue actually exercises GPO behavior.

## Capabilities

All window-level input validates that `App.Hwnd` is still owned by `App.Pid`.
This prevents a recycled HWND or unrelated foreground application from receiving
test input.

```powershell
$app = Start-Terminal -Package Dev -CloseExistingInstances

# Exact launched-window identity and client bounds.
$identity = Get-WtWindowIdentity -App $app

# Client-area coordinates: left/right, single/double click.
Invoke-WtWindowMouse -App $app -X 120 -Y 90 -Button Left -ClickCount 1
Invoke-WtWindowMouse -App $app -X 120 -Y 90 -Button Right -ClickCount 2
Invoke-WtWindowDrag -App $app -FromX 120 -FromY 90 -ToX 320 -ToY 190

# Exact text geometry for a unique marker, including multiline rectangle detail.
$markerBounds = Get-UiTextBounds -App $app -Text $marker -RequireUnique

# Physical wheel input. Gate the environment once; later focus loss is a test failure.
if (-not (Test-WtPhysicalInputReady -App $app)) {
    Set-ItResult -Skipped -Because 'the interactive desktop cannot foreground the test window'
    return
}
$agent = Get-WtTermControlBounds -App $app -Kind Agent
Invoke-WtWindowWheel -App $app -ScreenX $agent.ScreenCenterX -ScreenY $agent.ScreenCenterY -Delta 120 -Ctrl

# Named OS keys and chords sent to the target window.
Send-WtWindowKeyChord -App $app -Chord @('Up', 'Enter', 'Ctrl+Shift+P')

# UI Automation selectors when a stable AutomationId exists.
Invoke-UiElement -App $app -Selector AgentToggleButton
Invoke-UiClick -App $app -Selector NewTabButton -Double
Set-UiValue -App $app -Selector '<AutomationId>' -Value '<text>'

# Agent TUI text and input through its own ConPTY session.
$session = Send-AgentPrompt -App $app -Text 'draft' -NoSubmit
Send-AgentKey -App $app -PaneSessionId $session.PaneSessionId -Key Enter
Send-AgentKey -App $app -Key Down -Count 2
Send-AgentWin32Key -App $app -Vk 0x56 -Sc 0x2F -Modifiers 0x02 # Alt+V

# Observe and preserve evidence locally.
$listener = Start-WtEventListener -App $app
Save-UiScreenshot -App $app -Path local-tdd-kit/artifacts/window.png
Get-WtCapture -App $app -SessionId (Get-ActivePane -App $app).session_id
$geometry = Get-WtCaptureGeometry -App $app -SessionId (Get-ActivePane -App $app).session_id
$evidencePath = Get-ItArtifactPath -ChildPath 'screenshots\window.png' -CreateParent
Stop-Terminal -App $app
```

## Input Safety

- Coordinate mouse and OS keyboard tests require an unlocked interactive desktop.
- `Start-Terminal` acquires a machine-local foreground-input lease. Do not run foreground-input
  suites in parallel or bypass that lease with feature-local input code.
- Existing Intelligent Terminal windows make `Start-Terminal` fail closed. Automated suites that
  own the machine-side test session must pass `-CloseExistingInstances`; the cleanup remains
  constrained to executable paths under exact Intelligent Terminal package install locations.
  Never terminate `WindowsTerminal.exe` or `wta.exe` by name, and never terminate the process tree
  hosting the current shell/conversation.
- Coordinates are relative to the window client area, not the screen.
- `Invoke-WtWindowMouse` bounds-checks, foregrounds, revalidates ownership, sends
  input, and restores the user's cursor by default.
- `Invoke-WtWindowWheel` accepts client or screen coordinates, supports vertical/horizontal wheel
  plus Ctrl/Shift/Alt, and releases only modifiers that it pressed itself.
- `Invoke-WtWindowDrag` emits intermediate movement, always releases its button and restores the
  cursor. Use `Get-UiTextBounds` for exact marker geometry instead of hard-coded row coordinates.
- Call `Test-WtPhysicalInputReady` before the action. A false result may be an environmental skip;
  focus loss after that gate is a failure.
- Use `Get-WtTermControlBounds` instead of feature-local UIA traversal.
- Use `Get-WtCaptureGeometry` for font/reflow/layout oracles; terminal TUI row count is not
  necessarily the viewport height.
- Use `Get-ItArtifactPath`; the report runner assigns a unique run-scoped artifact root.
- Prefer UIA selector invocation over coordinates when a stable AutomationId exists.
- `Start-Terminal` backs up settings/state; `Stop-Terminal` restores them byte-for-byte. Files that
  were absent before the run are removed again, including after recovery from a crashed transaction.
- Artifacts, provider configs, logs, captures and screenshots remain ignored.
- `Invoke-BuildDeploy.ps1 -Launch` may activate the Dev Terminal and move foreground focus away
  from VS Code. Prefer a non-launching build and let the E2E harness launch immediately before
  input. A focus flash is expected window activation, not evidence that VS Code was terminated.

## Optional AI Oracle

`Assert-AI` and `Invoke-AgentJudge` call an external authenticated agent CLI and
may send the supplied context to that provider. They are disabled by default.
Review and sanitize the context, then explicitly set
`ITE2E_ENABLE_AI_ORACLE=1` for a test that genuinely requires model judgment.
Such tests and their callers stay dev/local-only, never in publish or indirect CI
invocation. `TEST-BOUNDARIES.md` also excludes real-login/account dependencies when
they consume zero tokens. Opt-in is not permission to expose sensitive context,
change credentials or exceed the task's authorized request budget.
The deterministic `AgentInput` self-test does not use this oracle or any network.