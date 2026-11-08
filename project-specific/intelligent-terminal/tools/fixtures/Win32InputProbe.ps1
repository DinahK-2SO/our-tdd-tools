[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$EventPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
[void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LocalTddProbeNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetCursorPos(out POINT point);
    public static int[] GetCursorPosition() {
        POINT point;
        if (!GetCursorPos(out point)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new int[] { point.X, point.Y };
    }
}
'@

function Write-ProbeEvent {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Data
    )

    $record = [ordered]@{
        type = $Type
        at = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($entry in $Data.GetEnumerator()) {
        $record[$entry.Key] = $entry.Value
    }
    Add-Content -LiteralPath $EventPath -Value ($record | ConvertTo-Json -Compress) -Encoding utf8
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = "Local TDD input probe $PID"
$form.Name = 'LocalTddInputProbe'
$form.ClientSize = [System.Drawing.Size]::new(480, 320)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = [System.Drawing.Point]::new(160, 160)
$form.KeyPreview = $true

$textMarker = 'LOCAL_TDD_TEXT_GEOMETRY_MARKER'
$textBox = [System.Windows.Forms.TextBox]::new()
$textBox.Name = 'LocalTddTextGeometry'
$textBox.Text = $textMarker
$textBox.ReadOnly = $true
$textBox.Location = [System.Drawing.Point]::new(40, 260)
$textBox.Size = [System.Drawing.Size]::new(300, 24)
$form.Controls.Add($textBox)

$form.add_MouseDown({
    param($sender, $eventArgs)
    $screen = $sender.PointToScreen([Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
    Write-ProbeEvent -Type 'mouse-down' -Data @{
        button = [string]$eventArgs.Button
        clicks = $eventArgs.Clicks
        x = $eventArgs.X
        y = $eventArgs.Y
        screenX = $screen.X
        screenY = $screen.Y
    }
})
$form.add_MouseUp({
    param($sender, $eventArgs)
    $screen = $sender.PointToScreen([Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
    Write-ProbeEvent -Type 'mouse-up' -Data @{
        button = [string]$eventArgs.Button
        clicks = $eventArgs.Clicks
        x = $eventArgs.X
        y = $eventArgs.Y
        screenX = $screen.X
        screenY = $screen.Y
    }
})
$form.add_MouseMove({
    param($sender, $eventArgs)
    $screen = $sender.PointToScreen([Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
    Write-ProbeEvent -Type 'mouse-move' -Data @{
        x = $eventArgs.X
        y = $eventArgs.Y
        screenX = $screen.X
        screenY = $screen.Y
    }
})
$form.add_MouseWheel({
    param($sender, $eventArgs)
    $modifiers = [System.Windows.Forms.Control]::ModifierKeys
    Write-ProbeEvent -Type 'mouse-wheel' -Data @{
        delta = $eventArgs.Delta
        x = $eventArgs.X
        y = $eventArgs.Y
        alt = [bool]($modifiers -band [System.Windows.Forms.Keys]::Alt)
        control = [bool]($modifiers -band [System.Windows.Forms.Keys]::Control)
        shift = [bool]($modifiers -band [System.Windows.Forms.Keys]::Shift)
    }
})
$form.add_KeyDown({
    param($sender, $eventArgs)
    Write-ProbeEvent -Type 'key-down' -Data @{
        key = [string]$eventArgs.KeyCode
        alt = $eventArgs.Alt
        control = $eventArgs.Control
        shift = $eventArgs.Shift
    }
})
$form.add_Shown({
    $client = [LocalTddProbeNative+RECT]::new()
    if (-not [LocalTddProbeNative]::GetClientRect($form.Handle, [ref]$client)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    @{
        pid = $PID
        hwnd = $form.Handle.ToInt64()
        title = $form.Text
        textMarker = $textMarker
        clientWidth = $client.Right - $client.Left
        clientHeight = $client.Bottom - $client.Top
    } | ConvertTo-Json | Set-Content -LiteralPath $ReadyPath -Encoding utf8
    $form.Activate()
})

[System.Windows.Forms.Application]::Run($form)