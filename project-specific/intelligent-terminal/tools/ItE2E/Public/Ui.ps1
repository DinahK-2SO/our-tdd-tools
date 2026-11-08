. ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..\common\tools\windows\Windows.ps1')))
# Ui.ps1 — UI automation via `winapp ui` (Windows App CLI). Replaces WinAppDriver.
# Targets the WT window by stable HWND ($App.Hwnd), falling back to PID.

function Get-WinAppPath {
    if ($script:ItWinAppPath -and (Test-Path $script:ItWinAppPath)) { return $script:ItWinAppPath }
    $c = (Get-Command winapp -ErrorAction SilentlyContinue).Source
    if (-not $c) { throw "winapp (Windows App CLI) not found. Run bootstrap.ps1 or: winget install Microsoft.WinAppCli" }
    $script:ItWinAppPath = $c; $c
}

function Test-WinAppAvailable {
    <#
    .SYNOPSIS
        Non-throwing probe for the winapp (Windows App CLI) UI-automation tool.
    .DESCRIPTION
        Returns $true when winapp is on PATH (or already resolved), $false otherwise — unlike
        Get-WinAppPath, which throws. Use this in a Describe readiness gate so UI-dependent
        suites SKIP cleanly when winapp is missing instead of blowing up in BeforeAll with a
        raw "winapp not found" exception. Install winapp via local-tdd-kit/bootstrap.ps1.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:ItWinAppPath -and (Test-Path $script:ItWinAppPath)) { return $true }
    [bool](Get-Command winapp -ErrorAction SilentlyContinue)
}

function Get-UiTarget {
    param([Parameter(Mandatory)]$App)
    if ($App.Hwnd) { return @('-w', [string]$App.Hwnd) }
    if ($App.Pid) { return @('-a', [string]$App.Pid) }
    throw "App has no Hwnd or Pid for UI targeting. Launch via Start-Terminal first."
}

# ── Window-level key injection (WT accelerators + Settings) ───────────────────────────
# winapp drives UIA elements but has no key-send verb, and wtcli send-keys reaches a pane's
# CONPTY (the wta TUI), NOT WT's XAML keybinding layer — so WT accelerators (Ctrl+, to open
# Settings, Ctrl+Shift+. to toggle the agent pane, Alt+Shift+B delegate, …) can't be driven that
# way. This sends OS-level keystrokes to the focused WT WINDOW via keybd_event, which DOES hit
# WT's accelerator handler. Foreground-focus dependent (so a bit fragile under parallel runs /
# a locked session), hence the SetForegroundWindow + verify + retry below.
function Initialize-WtWin32Input {
    if ('ItE2E.ItWtWin32Input' -as [type]) { return }
    Add-Type -Namespace 'ItE2E' -Name 'ItWtWin32Input' -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref uint pvParam, uint fWinIni);

    const uint SPI_GETFOREGROUNDLOCKTIMEOUT = 0x2000;
    const uint SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001;
    const uint SPIF_SENDCHANGE = 0x2;
    const int  SW_RESTORE = 9;
    const byte VK_MENU = 0x12;   // ALT
    const uint KEYUP = 0x2;
    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_WHEEL = 0x0800;
    const uint MOUSEEVENTF_HWHEEL = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION data;
    }

    public static long[] GetWindowIdentity(IntPtr hWnd) {
        if (!IsWindow(hWnd)) return new long[] { 0, 0, 0, 0, 0 };
        uint pid;
        uint threadId = GetWindowThreadProcessId(hWnd, out pid);
        RECT rect;
        if (!GetClientRect(hWnd, out rect)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new long[] {
            threadId,
            pid,
            rect.Right - rect.Left,
            rect.Bottom - rect.Top,
            IsWindowVisible(hWnd) ? 1 : 0
        };
    }

    public static string GetWindowTitle(IntPtr hWnd) {
        var text = new System.Text.StringBuilder(1024);
        GetWindowText(hWnd, text, text.Capacity);
        return text.ToString();
    }

    public static int[] ClientPointToScreen(IntPtr hWnd, int x, int y) {
        POINT point = new POINT { X = x, Y = y };
        if (!ClientToScreen(hWnd, ref point)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new int[] { point.X, point.Y };
    }

    public static int[] GetCursorPosition() {
        POINT point;
        if (!GetCursorPos(out point)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new int[] { point.X, point.Y };
    }

    public static bool SendMouseClicks(uint downFlag, uint upFlag, int clickCount, int delayMs) {
        for (int click = 0; click < clickCount; click++) {
            var inputs = new INPUT[2];
            inputs[0].type = INPUT_MOUSE;
            inputs[0].data.mouse.dwFlags = downFlag;
            inputs[1].type = INPUT_MOUSE;
            inputs[1].data.mouse.dwFlags = upFlag;
            if (SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) != 2) return false;
            if (click + 1 < clickCount) System.Threading.Thread.Sleep(delayMs);
        }
        return true;
    }

    public static bool SendMouseButton(uint flag) {
        var inputs = new INPUT[1];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].data.mouse.dwFlags = flag;
        return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool IsKeyDown(int virtualKey) {
        return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
    }

    public static bool SendMouseWheel(int delta, int count, bool horizontal) {
        for (int wheel = 0; wheel < count; wheel++) {
            var inputs = new INPUT[1];
            inputs[0].type = INPUT_MOUSE;
            inputs[0].data.mouse.mouseData = unchecked((uint)delta);
            inputs[0].data.mouse.dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
            if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1) return false;
        }
        return true;
    }

    // Aggressively bring a window to the foreground, defeating the foreground-lock that otherwise
    // makes SetForegroundWindow a no-op when the caller doesn't own foreground. Combines every
    // documented workaround: zero the foreground-lock timeout, tap ALT (registers input from this
    // context so Windows permits the switch), AllowSetForegroundWindow, attach to the current
    // foreground thread's input queue, un-minimize, and push the window active/focused. Returns
    // true only if the window actually holds the foreground afterwards.
    public static bool ForceForeground(IntPtr hWnd) {
        if (GetForegroundWindow() == hWnd) return true;

        uint prev = 0; SystemParametersInfo(SPI_GETFOREGROUNDLOCKTIMEOUT, 0, ref prev, 0);
        uint zero = 0; SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, ref zero, SPIF_SENDCHANGE);

        // Tap ALT only when it is not already held. Never release user-owned modifier state.
        if (!IsKeyDown(VK_MENU)) {
            keybd_event(VK_MENU, 0, 0, System.UIntPtr.Zero);
            keybd_event(VK_MENU, 0, KEYUP, System.UIntPtr.Zero);
        }

        uint targetPid;
        GetWindowThreadProcessId(hWnd, out targetPid);
        AllowSetForegroundWindow(targetPid);

        uint tidThis = GetCurrentThreadId();
        IntPtr fg = GetForegroundWindow();
        uint fgPid; uint tidFg = (fg == IntPtr.Zero) ? 0 : GetWindowThreadProcessId(fg, out fgPid);
        bool attached = (tidFg != 0 && tidFg != tidThis) && AttachThreadInput(tidThis, tidFg, true);
        try {
            if (IsIconic(hWnd)) { ShowWindow(hWnd, SW_RESTORE); }
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            SetActiveWindow(hWnd);
            SetFocus(hWnd);
        }
        finally {
            if (attached) { AttachThreadInput(tidThis, tidFg, false); }
            uint restore = prev; SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, ref restore, SPIF_SENDCHANGE);
        }
        System.Threading.Thread.Sleep(120);
        return GetForegroundWindow() == hWnd;
    }
'@
}

function Set-WtWindowForeground {
    <#
    .SYNOPSIS
        Ensure the WT window IS in the foreground so a subsequent window-level key send lands on it.
        Applies the full foreground-forcing combo (see ForceForeground) and RETRIES until the window
        actually holds the foreground or the attempts run out.
    .OUTPUTS
        [bool] $true if the WT window is confirmed foreground; $false if it could not be forced
        (a competing foreground app is holding it — caller should treat as a precondition skip).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [int]$Attempts = 8, [int]$DelayMs = 200)
    process {
        if (-not $App.Hwnd) { throw "Set-WtWindowForeground needs `$App.Hwnd (launch via Start-Terminal)." }
        Initialize-WtWin32Input
        $hwnd = [IntPtr][int64]$App.Hwnd
        for ($i = 0; $i -lt $Attempts; $i++) {
            if ([ItE2E.ItWtWin32Input]::ForceForeground($hwnd)) { return $true }
            Start-Sleep -Milliseconds $DelayMs
        }
        [ItE2E.ItWtWin32Input]::ForceForeground($hwnd)
    }
}

function Get-WtWindowIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App)
    process { Get-WinpdWindowIdentity -Window $App }
}

function Get-WtTermControlBounds {
    <#
    .SYNOPSIS
        Return screen and client bounds for a visible TermControl in the test-owned window.
    .PARAMETER Kind
        Any, Agent (accessible name "Agent Pane"), or Terminal (any other TermControl).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [ValidateSet('Any', 'Agent', 'Terminal')][string]$Kind = 'Any',
        [ValidateRange(0, 64)][int]$Index = 0
    )
    process {
        $identity = Get-WtWindowIdentity -App $App
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $hwnd = [IntPtr][int64]$identity.Hwnd
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty,
            'TermControl')
        $controls = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        $origin = [ItE2E.ItWtWin32Input]::ClientPointToScreen($hwnd, 0, 0)
        $matches = @()
        for ($i = 0; $i -lt $controls.Count; $i++) {
            $control = $controls.Item($i)
            if ($control.Current.IsOffscreen) { continue }
            $isAgent = $control.Current.Name -eq 'Agent Pane'
            if (($Kind -eq 'Agent' -and -not $isAgent) -or
                ($Kind -eq 'Terminal' -and $isAgent)) {
                continue
            }
            $rect = $control.Current.BoundingRectangle
            if ($rect.Width -le 0 -or $rect.Height -le 0) { continue }
            $matches += [pscustomobject]@{
                ControlName = $control.Current.Name
                IsAgent = $isAgent
                ScreenLeft = [double]$rect.Left
                ScreenTop = [double]$rect.Top
                Width = [double]$rect.Width
                Height = [double]$rect.Height
                ScreenCenterX = [int][Math]::Round($rect.Left + ($rect.Width / 2))
                ScreenCenterY = [int][Math]::Round($rect.Top + ($rect.Height / 2))
                ClientLeft = [double]$rect.Left - $origin[0]
                ClientTop = [double]$rect.Top - $origin[1]
                ClientCenterX = [int][Math]::Round($rect.Left + ($rect.Width / 2) - $origin[0])
                ClientCenterY = [int][Math]::Round($rect.Top + ($rect.Height / 2) - $origin[1])
            }
        }
        @($matches | Select-Object -Index $Index)
    }
}

function Test-WtPhysicalInputReady {
    <#
    .SYNOPSIS
        Return true only when the exact test window can acquire foreground before physical input.
    .NOTES
        Use this as a pre-action SKIP/BLOCKED gate. Once it passes, later focus loss is a test
        failure and the input helper will throw rather than silently skipping.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App)
    process {
        Get-WtWindowIdentity -App $App | Out-Null
        if (-not (Set-WtWindowForeground -App $App)) { return $false }
        Get-WtWindowIdentity -App $App | Out-Null
        $true
    }
}

function Invoke-WtWindowMouse {
    <#
    .SYNOPSIS
        Send a left/right single or double click at a client coordinate in the test-owned window.
    .PARAMETER X/Y
        Zero-based coordinates relative to the target window's client area, not the screen.
    .PARAMETER Button
        Left or Right.
    .PARAMETER ClickCount
        One for a single click; two for a double click.
    .NOTES
        The HWND owner and coordinate bounds are checked before input. The target must acquire
        foreground focus; otherwise no mouse input is sent. The user's cursor is restored by
        default after the complete click sequence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [ValidateSet(1, 2)][int]$ClickCount = 1,
        [bool]$RestoreCursor = $true
    )
    process {
        $identity = Get-WtWindowIdentity -App $App
        if ($X -lt 0 -or $X -ge $identity.ClientWidth -or $Y -lt 0 -or $Y -ge $identity.ClientHeight) {
            throw "Client coordinate ($X,$Y) is outside HWND $($identity.Hwnd) bounds $($identity.ClientWidth)x$($identity.ClientHeight)."
        }

        if (-not (Set-WtWindowForeground -App $App)) {
            throw "Invoke-WtWindowMouse could not bring HWND $($identity.Hwnd) to the foreground; no input was sent."
        }

        # Revalidate after the focus transition so an HWND recycled during the wait cannot receive input.
        $identity = Get-WtWindowIdentity -App $App
        $hwnd = [IntPtr]$identity.Hwnd
        $screen = [ItE2E.ItWtWin32Input]::ClientPointToScreen($hwnd, $X, $Y)
        $original = if ($RestoreCursor) { [ItE2E.ItWtWin32Input]::GetCursorPosition() } else { $null }
        $flags = if ($Button -eq 'Left') { @(0x0002, 0x0004) } else { @(0x0008, 0x0010) }
        $delayMs = [Math]::Max(20, [Math]::Min(100, [int]([ItE2E.ItWtWin32Input]::GetDoubleClickTime() / 4)))
        try {
            if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($screen[0], $screen[1])) {
                throw "Invoke-WtWindowMouse could not move the cursor to screen coordinate ($($screen[0]),$($screen[1]))."
            }
            if (-not [ItE2E.ItWtWin32Input]::SendMouseClicks($flags[0], $flags[1], $ClickCount, $delayMs)) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "Invoke-WtWindowMouse SendInput failed with Win32 error $code."
            }
        }
        finally {
            if ($original) { [void][ItE2E.ItWtWin32Input]::SetCursorPos($original[0], $original[1]) }
        }

        [pscustomobject]@{
            Hwnd = $identity.Hwnd
            ProcessId = $identity.ProcessId
            ClientX = $X
            ClientY = $Y
            ScreenX = $screen[0]
            ScreenY = $screen[1]
            Button = $Button
            ClickCount = $ClickCount
        }
    }
}

function Invoke-WtWindowDrag {
    <#
    .SYNOPSIS
        Send a physical mouse drag between two client coordinates in the test-owned window.
    .NOTES
        The button is always released and the cursor is restored on failure. Intermediate cursor
        movement is intentional: a single jump is not equivalent to a user's selection drag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory)][int]$FromX,
        [Parameter(Mandatory)][int]$FromY,
        [Parameter(Mandatory)][int]$ToX,
        [Parameter(Mandatory)][int]$ToY,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [ValidateRange(1, 100)][int]$Steps = 8,
        [ValidateRange(0, 1000)][int]$StepDelayMs = 15,
        [bool]$RestoreCursor = $true
    )
    process {
        $identity = Get-WtWindowIdentity -App $App
        foreach ($point in @(@($FromX, $FromY), @($ToX, $ToY))) {
            if ($point[0] -lt 0 -or $point[0] -ge $identity.ClientWidth -or
                $point[1] -lt 0 -or $point[1] -ge $identity.ClientHeight) {
                throw "Drag client coordinate ($($point[0]),$($point[1])) is outside HWND $($identity.Hwnd) bounds $($identity.ClientWidth)x$($identity.ClientHeight)."
            }
        }
        if (-not (Set-WtWindowForeground -App $App)) {
            throw "Invoke-WtWindowDrag could not bring HWND $($identity.Hwnd) to the foreground; no input was sent."
        }

        $identity = Get-WtWindowIdentity -App $App
        $hwnd = [IntPtr]$identity.Hwnd
        $from = [ItE2E.ItWtWin32Input]::ClientPointToScreen($hwnd, $FromX, $FromY)
        $to = [ItE2E.ItWtWin32Input]::ClientPointToScreen($hwnd, $ToX, $ToY)
        $original = if ($RestoreCursor) { [ItE2E.ItWtWin32Input]::GetCursorPosition() } else { $null }
        $flags = if ($Button -eq 'Left') { @(0x0002, 0x0004) } else { @(0x0008, 0x0010) }
        $buttonDown = $false
        try {
            if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($from[0], $from[1])) {
                throw "Invoke-WtWindowDrag could not move the cursor to drag start ($($from[0]),$($from[1]))."
            }
            if (-not [ItE2E.ItWtWin32Input]::SendMouseButton($flags[0])) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "Invoke-WtWindowDrag button-down SendInput failed with Win32 error $code."
            }
            $buttonDown = $true
            for ($step = 1; $step -le $Steps; $step++) {
                $x = [int][Math]::Round($from[0] + (($to[0] - $from[0]) * $step / $Steps))
                $y = [int][Math]::Round($from[1] + (($to[1] - $from[1]) * $step / $Steps))
                if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($x, $y)) {
                    throw "Invoke-WtWindowDrag could not move the cursor to drag step ($x,$y)."
                }
                if ($StepDelayMs) { Start-Sleep -Milliseconds $StepDelayMs }
            }
        }
        finally {
            if ($buttonDown -and -not [ItE2E.ItWtWin32Input]::SendMouseButton($flags[1])) {
                Write-Warning "Invoke-WtWindowDrag could not release the $Button mouse button."
            }
            if ($original) {
                [void][ItE2E.ItWtWin32Input]::SetCursorPos($original[0], $original[1])
            }
        }

        [pscustomobject]@{
            Hwnd = $identity.Hwnd
            ProcessId = $identity.ProcessId
            FromX = $FromX
            FromY = $FromY
            ToX = $ToX
            ToY = $ToY
            FromScreenX = $from[0]
            FromScreenY = $from[1]
            ToScreenX = $to[0]
            ToScreenY = $to[1]
            Button = $Button
            Steps = $Steps
        }
    }
}

function Get-UiTextBounds {
    <#
    .SYNOPSIS
        Return the UI Automation bounding rectangles for an exact visible text occurrence.
    .DESCRIPTION
        Searches TextPattern providers inside the exact test-owned HWND. Occurrence is zero-based
        across visible providers. Use -RequireUnique for GUID markers and other test-owned text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Text,
        [ValidateRange(0, 1024)][int]$Occurrence = 0,
        [switch]$RequireUnique
    )
    process {
        $identity = Get-WtWindowIdentity -App $App
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $hwnd = [IntPtr][int64]$identity.Hwnd
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $elements = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Subtree,
            [System.Windows.Automation.Condition]::TrueCondition)
        $matches = [Collections.Generic.List[object]]::new()
        for ($elementIndex = 0; $elementIndex -lt $elements.Count; $elementIndex++) {
            $element = $elements.Item($elementIndex)
            if ($element.Current.IsOffscreen) { continue }
            $pattern = $null
            if (-not $element.TryGetCurrentPattern(
                    [System.Windows.Automation.TextPattern]::Pattern,
                    [ref]$pattern)) {
                continue
            }
            $document = ([System.Windows.Automation.TextPattern]$pattern).DocumentRange
            $documentText = $document.GetText(-1).TrimEnd("`r", "`n")
            $searchRange = $document.Clone()
            while ($true) {
                $found = $searchRange.FindText($Text, $false, $true)
                if (-not $found) { break }
                $matches.Add([pscustomobject]@{
                        Element = $element
                        Range = $found.Clone()
                        IsEntireDocument = $documentText -ceq $Text
                    })
                $searchRange.MoveEndpointByRange(
                    [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start,
                    $found,
                    [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End)
            }
        }
        if (-not $matches.Count) {
            throw "Exact UI text was not found in HWND $($identity.Hwnd): '$Text'."
        }
        if ($RequireUnique -and $matches.Count -ne 1) {
            throw "Expected exact UI text to be unique, but found $($matches.Count) occurrences: '$Text'."
        }
        if ($Occurrence -ge $matches.Count) {
            throw "Requested text occurrence $Occurrence, but only $($matches.Count) occurrence(s) were found."
        }

        $match = $matches[$Occurrence]
        $rawRectangles = @($match.Range.GetBoundingRectangles())
        $rectangles = @()
        if ($rawRectangles.Count -and $rawRectangles[0] -is [System.Windows.Rect]) {
            $rectangles = @($rawRectangles | ForEach-Object {
                    [pscustomobject]@{
                        ScreenLeft = [double]$_.Left
                        ScreenTop = [double]$_.Top
                        Width = [double]$_.Width
                        Height = [double]$_.Height
                    }
                })
        }
        elseif ($rawRectangles.Count) {
            [double[]]$values = $rawRectangles
            if ($values.Count % 4 -eq 0) {
                $rectangles = for ($i = 0; $i -lt $values.Count; $i += 4) {
                    [pscustomobject]@{
                        ScreenLeft = [double]$values[$i]
                        ScreenTop = [double]$values[$i + 1]
                        Width = [double]$values[$i + 2]
                        Height = [double]$values[$i + 3]
                    }
                }
            }
        }
        if (-not $rectangles.Count -and $match.IsEntireDocument) {
            $elementRect = $match.Element.Current.BoundingRectangle
            if ($elementRect.Width -gt 0 -and $elementRect.Height -gt 0) {
                $rectangles = @([pscustomobject]@{
                        ScreenLeft = [double]$elementRect.Left
                        ScreenTop = [double]$elementRect.Top
                        Width = [double]$elementRect.Width
                        Height = [double]$elementRect.Height
                    })
            }
        }
        if (-not $rectangles.Count) {
            throw "UI Automation returned no usable rectangles for exact text '$Text'."
        }
        $origin = [ItE2E.ItWtWin32Input]::ClientPointToScreen($hwnd, 0, 0)
        $left = ($rectangles | Measure-Object ScreenLeft -Minimum).Minimum
        $top = ($rectangles | Measure-Object ScreenTop -Minimum).Minimum
        $right = ($rectangles | ForEach-Object { $_.ScreenLeft + $_.Width } | Measure-Object -Maximum).Maximum
        $bottom = ($rectangles | ForEach-Object { $_.ScreenTop + $_.Height } | Measure-Object -Maximum).Maximum
        [pscustomobject]@{
            Text = $Text
            Occurrence = $Occurrence
            OccurrenceCount = $matches.Count
            ScreenLeft = [double]$left
            ScreenTop = [double]$top
            Width = [double]($right - $left)
            Height = [double]($bottom - $top)
            ScreenCenterX = [int][Math]::Round(($left + $right) / 2)
            ScreenCenterY = [int][Math]::Round(($top + $bottom) / 2)
            ClientLeft = [double]$left - $origin[0]
            ClientTop = [double]$top - $origin[1]
            ClientCenterX = [int][Math]::Round((($left + $right) / 2) - $origin[0])
            ClientCenterY = [int][Math]::Round((($top + $bottom) / 2) - $origin[1])
            Rectangles = @($rectangles)
        }
    }
}

function Invoke-WtWindowWheel {
    <#
    .SYNOPSIS
        Send physical vertical or horizontal wheel input to the exact test-owned window.
    .DESCRIPTION
        Accepts either client or screen coordinates, validates HWND ownership and bounds, acquires
        foreground, preserves the cursor and any modifiers already held by the user, then injects
        wheel input. A focus failure after readiness passed is a hard failure.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Client')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory, ParameterSetName = 'Client')][int]$X,
        [Parameter(Mandatory, ParameterSetName = 'Client')][int]$Y,
        [Parameter(Mandatory, ParameterSetName = 'Screen')][int]$ScreenX,
        [Parameter(Mandatory, ParameterSetName = 'Screen')][int]$ScreenY,
        [Parameter(Mandatory)][ValidateSet(-120, 120)][int]$Delta,
        [ValidateRange(1, 100)][int]$Count = 1,
        [switch]$Horizontal,
        [switch]$Ctrl,
        [switch]$Shift,
        [switch]$Alt,
        [bool]$RestoreCursor = $true
    )
    process {
        $identity = Get-WtWindowIdentity -App $App
        if (-not (Set-WtWindowForeground -App $App)) {
            throw "Invoke-WtWindowWheel could not bring HWND $($identity.Hwnd) to the foreground; no input was sent."
        }

        $identity = Get-WtWindowIdentity -App $App
        $hwnd = [IntPtr]$identity.Hwnd
        $origin = [ItE2E.ItWtWin32Input]::ClientPointToScreen($hwnd, 0, 0)
        if ($PSCmdlet.ParameterSetName -eq 'Client') {
            $clientX = $X
            $clientY = $Y
            $ScreenX = $origin[0] + $X
            $ScreenY = $origin[1] + $Y
        }
        else {
            $clientX = $ScreenX - $origin[0]
            $clientY = $ScreenY - $origin[1]
        }
        if ($clientX -lt 0 -or $clientX -ge $identity.ClientWidth -or
            $clientY -lt 0 -or $clientY -ge $identity.ClientHeight) {
            throw "Wheel coordinate ($ScreenX,$ScreenY) is outside HWND $($identity.Hwnd) client bounds."
        }

        $original = if ($RestoreCursor) { [ItE2E.ItWtWin32Input]::GetCursorPosition() } else { $null }
        $requested = @()
        if ($Ctrl) { $requested += 0x11 }
        if ($Shift) { $requested += 0x10 }
        if ($Alt) { $requested += 0x12 }
        $pressedHere = @()
        try {
            if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($ScreenX, $ScreenY)) {
                throw "Invoke-WtWindowWheel could not move the cursor to screen coordinate ($ScreenX,$ScreenY)."
            }
            foreach ($virtualKey in $requested) {
                if (-not [ItE2E.ItWtWin32Input]::IsKeyDown($virtualKey)) {
                    [ItE2E.ItWtWin32Input]::keybd_event([byte]$virtualKey, 0, 0, [UIntPtr]::Zero)
                    $pressedHere += $virtualKey
                }
            }
            if (-not [ItE2E.ItWtWin32Input]::SendMouseWheel($Delta, $Count, $Horizontal.IsPresent)) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "Invoke-WtWindowWheel SendInput failed with Win32 error $code."
            }
        }
        finally {
            foreach ($virtualKey in ($pressedHere | Sort-Object -Descending)) {
                [ItE2E.ItWtWin32Input]::keybd_event([byte]$virtualKey, 0, 0x2, [UIntPtr]::Zero)
            }
            if ($original) {
                [void][ItE2E.ItWtWin32Input]::SetCursorPos($original[0], $original[1])
            }
        }

        Start-Sleep -Milliseconds 250
        [pscustomobject]@{
            Hwnd = $identity.Hwnd
            ProcessId = $identity.ProcessId
            ScreenX = $ScreenX
            ScreenY = $ScreenY
            ClientX = $clientX
            ClientY = $clientY
            Delta = $Delta
            Count = $Count
            Horizontal = $Horizontal.IsPresent
            Ctrl = $Ctrl.IsPresent
            Shift = $Shift.IsPresent
            Alt = $Alt.IsPresent
        }
    }
}

function Send-WtWindowKey {
    <#
    .SYNOPSIS
        Send an OS-level keystroke (optionally with modifiers) to the WT window itself, so WT
        ACCELERATORS fire (Ctrl+,, Ctrl+Shift+., Alt+Shift+B, …). Unlike Send-WtKeys (conpty) this
        reaches WT's keybinding layer.
    .PARAMETER Vk         Main virtual-key code (e.g. 0xBC = OEM_COMMA, 0xBE = OEM_PERIOD, 'B'=0x42).
    .PARAMETER Ctrl/Shift/Alt  Modifier switches held around the main key.
    .PARAMETER RequireForeground  Throw if the WT window can't be brought to the foreground (so the
                          key would go to the wrong window). Default best-effort; callers that must
                          guarantee delivery pass -RequireForeground and catch/skip on failure.
    .NOTES
        Uses Set-WtWindowForeground to guarantee the window is foreground before injecting keys.
        `$script:ItLastForegroundOk` records whether foreground was confirmed for the last send.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory)][int]$Vk,
        [switch]$Ctrl, [switch]$Shift, [switch]$Alt, [switch]$Win,
        [int]$Repeat = 1,
        [switch]$RequireForeground
    )
    process {
        Initialize-WtWin32Input
        Get-WtWindowIdentity -App $App | Out-Null
        $KEYUP = 0x2
        $mods = @()
        if ($Ctrl) { $mods += 0x11 }; if ($Shift) { $mods += 0x10 }; if ($Alt) { $mods += 0x12 }; if ($Win) { $mods += 0x5B }
        for ($r = 0; $r -lt $Repeat; $r++) {
            # Guarantee foreground BEFORE injecting, so the keystroke can't land on the wrong window.
            $fg = Set-WtWindowForeground -App $App
            $script:ItLastForegroundOk = $fg
            if (-not $fg) {
                if ($RequireForeground) {
                    throw "Send-WtWindowKey: WT window could not be brought to the foreground (competing foreground app)."
                }
                # Foreground not acquired: do NOT inject — the keys (esp. Ctrl/Alt/Shift accelerators)
                # would land on whatever app currently owns the foreground. Skip this iteration; the
                # caller detects the no-effect via Test-WtWindowKeyFocusable and treats it as a
                # skippable foreground precondition rather than a spurious keystroke.
                continue
            }
            # Foreground acquisition can take time. Revalidate immediately before input so a
            # recycled HWND or exited test process cannot receive the chord.
            Get-WtWindowIdentity -App $App | Out-Null
            $pressedHere = @()
            $keyDown = $false
            try {
                foreach ($m in $mods) {
                    if (-not [ItE2E.ItWtWin32Input]::IsKeyDown($m)) {
                        [ItE2E.ItWtWin32Input]::keybd_event([byte]$m, 0, 0, [UIntPtr]::Zero)
                        $pressedHere += $m
                    }
                }
                [ItE2E.ItWtWin32Input]::keybd_event([byte]$Vk, 0, 0, [UIntPtr]::Zero)
                $keyDown = $true
                Start-Sleep -Milliseconds 40
            }
            finally {
                if ($keyDown) {
                    [ItE2E.ItWtWin32Input]::keybd_event([byte]$Vk, 0, $KEYUP, [UIntPtr]::Zero)
                }
                foreach ($m in ($pressedHere | Sort-Object -Descending)) {
                    [ItE2E.ItWtWin32Input]::keybd_event([byte]$m, 0, $KEYUP, [UIntPtr]::Zero)
                }
            }
            Start-Sleep -Milliseconds 120
        }
        $App
    }
}

function Send-WtWindowKeyChord {
    <#
    .SYNOPSIS
        Send named keys or chords such as Up, Enter, Ctrl+Shift+P, or Win+Left.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory)][string[]]$Chord,
        [switch]$RequireForeground
    )
    process {
        $namedKeys = @{
            Backspace = 0x08; Tab = 0x09; Enter = 0x0D; Escape = 0x1B; Space = 0x20
            PageUp = 0x21; PageDown = 0x22; End = 0x23; Home = 0x24
            Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28
            Insert = 0x2D; Delete = 0x2E
            Semicolon = 0xBA; Equals = 0xBB; Comma = 0xBC; Minus = 0xBD
            Period = 0xBE; Slash = 0xBF; Backtick = 0xC0
            LeftBracket = 0xDB; Backslash = 0xDC; RightBracket = 0xDD; Quote = 0xDE
        }
        foreach ($value in $Chord) {
            $parts = @($value -split '\+' | Where-Object { $_ })
            if (-not $parts.Count) { throw 'Key chord cannot be empty.' }
            $keyName = $parts[-1]
            $modifiers = @($parts | Select-Object -First ($parts.Count - 1))
            $ctrl = [bool]($modifiers | Where-Object { $_ -in @('Ctrl', 'Control') })
            $shift = [bool]($modifiers | Where-Object { $_ -eq 'Shift' })
            $alt = [bool]($modifiers | Where-Object { $_ -eq 'Alt' })
            $win = [bool]($modifiers | Where-Object { $_ -in @('Win', 'Windows') })
            $unknown = @($modifiers | Where-Object { $_ -notin @('Ctrl', 'Control', 'Shift', 'Alt', 'Win', 'Windows') })
            if ($unknown) { throw "Unknown key modifier(s) in '$value': $($unknown -join ', ')." }

            if ($keyName.Length -eq 1 -and $keyName -match '[A-Za-z0-9]') {
                $vk = [int][char]$keyName.ToUpperInvariant()
            }
            elseif ($namedKeys.ContainsKey($keyName)) {
                $vk = $namedKeys[$keyName]
            }
            elseif ($keyName -match '^F(?<number>\d{1,2})$' -and [int]$Matches.number -in 1..24) {
                $vk = 0x70 + [int]$Matches.number - 1
            }
            else {
                throw "Unknown key '$keyName' in chord '$value'."
            }

            Send-WtWindowKey -App $App -Vk $vk -Ctrl:$ctrl -Shift:$shift -Alt:$alt -Win:$win `
                -RequireForeground:$RequireForeground | Out-Null
        }
        $App
    }
}

function Test-WtWindowKeyFocusable {
    <#
    .SYNOPSIS
        $true if the WT window could be brought to the foreground for window-level key injection.
        Use to SKIP accelerator tests when a competing foreground app (e.g. the agent's own
        terminal driving the run) makes Send-WtWindowKey unreliable, instead of failing flakily.
    #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$App)
    process {
        if (-not $App.Hwnd) { return $false }
        Set-WtWindowForeground -App $App -Attempts 3 -DelayMs 150
    }
}

function Open-WtSettings {
    <#
    .SYNOPSIS
        Open the Windows Terminal SETTINGS editor (Ctrl+, via window-level key injection) and wait
        until its UI renders. Returns $App. The editor opens as a tab in the WT window; drive its
        controls with the normal Get-UiElement / Invoke-UiElement / Set-UiValue primitives.
    .NOTES
        The Settings UI is a real XAML surface (SettingsNav, per-page controls). This refutes the
        earlier assumption that the editor "can't be opened" by the harness — it can, via the OS
        accelerator. Idempotent: returns immediately if Settings is already showing.
    #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$App, [int]$TimeoutSec = 20)
    process {
        $shown = { Test-UiElementExists -App $App -Selector 'SettingsNav' -TimeoutSec 1 }
        if (& $shown) { return $App }
        for ($try = 0; $try -lt 3; $try++) {
            Send-WtWindowKey -App $App -Vk 0xBC -Ctrl | Out-Null   # Ctrl + OEM_COMMA
            if (Test-Until -TimeoutSec ([Math]::Max(4, [int]($TimeoutSec / 3))) -IntervalSec 0.5 -Condition $shown) { return $App }
        }
        throw "Open-WtSettings: the Settings editor did not render after Ctrl+, (is the WT window able to take foreground?)."
    }
}

function Invoke-SettingsNav {
    <# Navigate the open Settings editor to a nav page (e.g. 'AIAgentsNavItem', 'AppearanceNavItem'). #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$NavItem)
    process {
        Invoke-UiElement -App $App -Selector $NavItem -TimeoutSec 10 | Out-Null
        Start-Sleep -Milliseconds 500
        $App
    }
}


function Invoke-WinAppUi {
    <#
    .SYNOPSIS
        Run a `winapp ui` command against the WT window. Returns an Invoke-Native result
        (ExitCode/StdOut/StdErr). Telemetry is opted out.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)][string[]]$UiArgs, [int]$TimeoutSec = 30, [switch]$NoTarget)
    $winapp = Get-WinAppPath
    $args = @('ui') + $UiArgs
    if (-not $NoTarget) { $args += (Get-UiTarget -App $App) }
    Invoke-Native -FilePath $winapp -Arguments $args -TimeoutSec $TimeoutSec -Environment @{ WINAPP_CLI_TELEMETRY_OPTOUT = '1' }
}

function Get-WtWindowHwnds {
    <# Return normalized @{ hwnd; pid; title } for WT windows (via winapp list-windows). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$App)
    $r = Invoke-WinAppUi -App $App -NoTarget -UiArgs @('list-windows', '-a', 'WindowsTerminal', '--json') -TimeoutSec 15
    $j = $r.StdOut | ConvertFrom-JsonSafe
    if ($null -ne $j) {
        $rows = if ($j -is [System.Array]) { $j } elseif ($j.windows) { $j.windows } else { @($j) }
        return $rows | ForEach-Object {
            $wpid = if ($null -ne $_.processId) { $_.processId } else { $_.pid }
            [pscustomobject]@{ hwnd = [int]$_.hwnd; pid = [int]$wpid; title = [string]$_.title }
        }
    }
    # Fallback: parse the text form "HWND 985238: "title" ... (WindowsTerminal, PID 21228)".
    @($r.StdOut -split "`n" | ForEach-Object {
            if ($_ -match 'HWND\s+(\d+):\s+"?(.*?)"?\s+.*\(WindowsTerminal,\s*PID\s+(\d+)\)') {
                [pscustomobject]@{ hwnd = [int]$Matches[1]; title = $Matches[2]; pid = [int]$Matches[3] }
            }
        })
}

function Test-CommandPaletteOpen {
    <#
    .SYNOPSIS
        Locale-robust check that the command palette is open, centralizing the detection that was
        previously duplicated as a hard-coded English "Command palette" literal across suites.
        The palette's accessible name is the localized `CommandPaletteControlName` resource, and it
        exposes no stable AutomationId to winapp, so we SEARCH by each localized name value (winapp
        search needs a literal query) and confirm the hit against an all-locales regex of the same
        key. This works on any build language, not just en-US.
    #>
    [CmdletBinding()] param([Parameter(Mandatory, ValueFromPipeline)]$App)
    process {
        $rx = Get-WtReswTextRegex -Key 'CommandPaletteControlName'
        if (-not $rx) { $rx = '(?i)Command palette' }
        # Try each localized palette name as a search query; the running build's language matches on
        # its own value. Fall back to the en-US literal if the resources couldn't be read.
        $queries = @(Get-WtReswTextValues -Key 'CommandPaletteControlName')
        if (-not $queries.Count) { $queries = @('Command palette') }
        foreach ($q in $queries) {
            if ((Find-UiElement -App $App -Selector $q) -match $rx) { return $true }
        }
        $false
    }
}

function Get-UiTree {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [string]$Selector, [int]$Depth = 3, [switch]$Interactive)
    process {
        $a = @('inspect'); if ($Selector) { $a += $Selector }; $a += @('--depth', $Depth); if ($Interactive) { $a += '--interactive' }
        (Invoke-WinAppUi -App $App -UiArgs $a).StdOut
    }
}

function Find-UiElement {
    <# winapp ui search — returns the raw match listing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector, [int]$Max)
    process {
        $a = @('search', $Selector); if ($Max) { $a += @('--max', $Max) }
        (Invoke-WinAppUi -App $App -UiArgs $a).StdOut
    }
}

function Invoke-UiElement {
    <# winapp ui invoke (Invoke/Toggle/Selection/ExpandCollapse). Throws on failure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector, [int]$TimeoutSec = 20)
    process {
        # Make sure the element exists first (clearer failure + sync).
        Wait-UiElement -App $App -Selector $Selector -TimeoutSec $TimeoutSec | Out-Null
        $r = Invoke-WinAppUi -App $App -UiArgs @('invoke', $Selector)
        if ($r.ExitCode -ne 0) { throw "winapp ui invoke '$Selector' failed: $($r.StdErr.Trim())$($r.StdOut.Trim())" }
        $App
    }
}

function Invoke-UiClick {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector, [switch]$Double, [switch]$Right)
    process {
        $a = @('click', $Selector); if ($Double) { $a += '--double' }; if ($Right) { $a += '--right' }
        $r = Invoke-WinAppUi -App $App -UiArgs $a
        if ($r.ExitCode -ne 0) { throw "winapp ui click '$Selector' failed: $($r.StdErr.Trim())" }
        $App
    }
}

function Set-UiValue {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector, [Parameter(Mandatory)][string]$Value)
    process {
        $r = Invoke-WinAppUi -App $App -UiArgs @('set-value', $Selector, $Value)
        if ($r.ExitCode -ne 0) { throw "winapp ui set-value '$Selector' failed: $($r.StdErr.Trim())" }
        $App
    }
}

function Get-UiElement {
    <#
    .SYNOPSIS
        Return the `winapp ui inspect --json` property bag of the first matching element
        (type, name, automationId, isEnabled, isOffscreen, toggleState, bounds, …) or $null.
        Unlike Get-UiTree (a text summary that only shows [on]/[off]), this exposes UIA
        properties like isEnabled — needed to assert enabled/disabled (greyed) control state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector)
    process {
        $r = Invoke-WinAppUi -App $App -UiArgs @('inspect', $Selector, '--json', '--depth', '1')
        $j = $r.StdOut | ConvertFrom-JsonSafe
        if (-not $j -or -not $j.windows) { return $null }
        # Flatten to a single list of element objects (each window's `elements` may itself be an
        # array; @(... ForEach-Object) unrolls them into one flat list).
        $els = @($j.windows | ForEach-Object { $_.elements } | Where-Object { $_ })
        # Return ONLY an element that actually matches the requested selector (by AutomationId,
        # winapp slug, or name). Do NOT fall back to "first inspected element": winapp inspect can
        # return the window root / unrelated nodes when the selector doesn't resolve, and returning
        # those would make Test-UiElementEnabled / .toggleState assert against the wrong control
        # (false positives). No match => $null, so callers correctly see "absent/disabled".
        $els |
            Where-Object { $_.automationId -eq $Selector -or $_.selector -eq $Selector -or $_.name -eq $Selector } |
            Select-Object -First 1
    }
}

function Test-UiElementEnabled {
    <# $true when the element's UIA IsEnabled is true (i.e. NOT greyed/disabled). #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector)
    process { $el = Get-UiElement -App $App -Selector $Selector; [bool]($el -and $el.isEnabled) }
}

function Get-UiValue {
    <# Read an element value (smart fallback chain). Returns the text. #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector)
    process {
        $r = Invoke-WinAppUi -App $App -UiArgs @('get-value', $Selector, '--json')
        $j = $r.StdOut | ConvertFrom-JsonSafe
        if ($null -ne $j -and ($j.PSObject.Properties.Name -contains 'text')) { return $j.text }
        $r.StdOut.Trim()
    }
}

function Wait-UiElement {
    <#
    .SYNOPSIS
        Wait for an element to appear (or -Gone / -Value). Uses winapp ui wait-for, which
        returns exit code 1 on timeout. Throws on timeout unless -Quiet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$App,
        [Parameter(Mandatory)][string]$Selector,
        [int]$TimeoutSec = 15,
        [switch]$Gone,
        [string]$Value,
        [string]$Property,
        [switch]$Contains,
        [switch]$Quiet
    )
    process {
        $a = @('wait-for', $Selector, '--timeout', ($TimeoutSec * 1000))
        if ($Gone) { $a += '--gone' }
        if ($PSBoundParameters.ContainsKey('Value')) { $a += @('--value', $Value) }
        if ($Property) { $a += @('--property', $Property) }
        if ($Contains) { $a += '--contains' }
        $r = Invoke-WinAppUi -App $App -UiArgs $a -TimeoutSec ($TimeoutSec + 5)
        if ($r.ExitCode -ne 0) {
            if ($Quiet) { return $false }
            throw "winapp ui wait-for '$Selector' timed out/failed: $($r.StdErr.Trim())"
        }
        if ($Quiet) { return $true }
        $App
    }
}

function Test-UiElementExists {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Selector, [int]$TimeoutSec = 5)
    process { Wait-UiElement -App $App -Selector $Selector -TimeoutSec $TimeoutSec -Quiet }
}

function Save-UiScreenshot {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$App, [Parameter(Mandatory)][string]$Path, [switch]$CaptureScreen)
    process {
        $a = @('screenshot', '--output', $Path); if ($CaptureScreen) { $a += '--capture-screen' }
        $r = Invoke-WinAppUi -App $App -UiArgs $a
        if ($r.ExitCode -ne 0) { Write-ItLog -Level WARN -Message "screenshot failed: $($r.StdErr.Trim())" }
        $Path
    }
}
