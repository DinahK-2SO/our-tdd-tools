function Initialize-WinpdWindowApi {
    if (-not $IsWindows) { throw 'This optional capability requires Windows.' }
    if ('Winpd.NativeWindow' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Winpd {
    public static class NativeWindow {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClientRect(IntPtr window, out RECT rect);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
        public static long[] Identity(IntPtr window) {
            if (!IsWindow(window)) throw new InvalidOperationException("The selected window no longer exists.");
            uint process;
            uint thread = GetWindowThreadProcessId(window, out process);
            RECT rect;
            if (thread == 0 || !GetClientRect(window, out rect))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return new long[] { thread, process, rect.Right - rect.Left, rect.Bottom - rect.Top, IsWindowVisible(window) ? 1 : 0 };
        }
        public static string Title(IntPtr window) {
            var text = new StringBuilder(2048);
            GetWindowText(window, text, text.Capacity);
            return text.ToString();
        }
    }
}
'@
}

function Get-WinpdWindowIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Window,
        [string]$ExpectedExecutablePath,
        [DateTimeOffset]$ExpectedStartTime
    )
    process {
        if (-not $Window.Hwnd -or -not $Window.Pid) { throw 'Window targeting requires an exact Hwnd and Pid.' }
        Initialize-WinpdWindowApi
        $handle = [IntPtr][int64]$Window.Hwnd
        $values = [Winpd.NativeWindow]::Identity($handle)
        if ($values[1] -ne [int]$Window.Pid) {
            throw "HWND $($Window.Hwnd) belongs to process $($values[1]), not expected process $($Window.Pid)."
        }
        if ($ExpectedExecutablePath -or $PSBoundParameters.ContainsKey('ExpectedStartTime')) {
            $process = Get-Process -Id ([int]$Window.Pid) -ErrorAction Stop
            if ($ExpectedExecutablePath -and -not [string]::Equals(
                [IO.Path]::GetFullPath($process.Path), [IO.Path]::GetFullPath($ExpectedExecutablePath),
                [StringComparison]::OrdinalIgnoreCase)) { throw 'The selected process executable changed.' }
            if ($PSBoundParameters.ContainsKey('ExpectedStartTime') -and
                $process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTime.UtcTicks) {
                throw 'The selected process creation time changed.'
            }
        }
        [pscustomobject]@{
            Hwnd = [int64]$Window.Hwnd; ProcessId = [int]$values[1]; ThreadId = [int]$values[0]
            ClientWidth = [int]$values[2]; ClientHeight = [int]$values[3]
            IsVisible = [bool]$values[4]; Title = [Winpd.NativeWindow]::Title($handle)
        }
    }
}

function Get-WinpdWinAppExecutable {
    return (Get-Command winapp -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

function Invoke-WinpdWindowUi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 2147483)][int]$TimeoutSec = 30
    )
    $identity = Get-WinpdWindowIdentity -Window $Window
    Invoke-WinpdProcess -FilePath (Get-WinpdWinAppExecutable) `
        -Arguments (@('ui') + $Arguments + @('-w', [string]$identity.Hwnd)) `
        -TimeoutSec $TimeoutSec -Environment @{ WINAPP_CLI_TELEMETRY_OPTOUT = '1' }
}

function Save-WinpdWindowScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Path,
        [switch]$CaptureScreen
    )
    $Path = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $Path) { throw 'Use a new screenshot path; stale captures are not reused.' }
    $null = Get-WinpdWindowIdentity -Window $Window
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $arguments = @('screenshot', '--output', $Path)
    if ($CaptureScreen) { $arguments += '--capture-screen' }
    $result = Invoke-WinpdWindowUi -Window $Window -Arguments $arguments
    $succeeded = $result.ExitCode -eq 0 -and -not $result.TimedOut -and
        (Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -gt 0
    $errorText = if ($succeeded) { $null }
    elseif ($result.StdErr) { $result.StdErr.Trim() }
    else { 'The capture did not produce a nonempty image file.' }
    if (-not $succeeded) { Write-Warning $errorText }
    [pscustomobject]@{
        Succeeded = $succeeded; Path = $Path; ExitCode = $result.ExitCode; Error = $errorText
        InspectionPerformed = $false
    }
}
