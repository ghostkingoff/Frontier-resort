param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [int]$WindowTimeoutMs = 20000,
    [int]$CaptureDelayMs = 2500
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if (-not ("CodexWindowCapture" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class CodexWindowCapture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);

    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);

    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(
        IntPtr destination,
        int x,
        int y,
        int width,
        int height,
        IntPtr source,
        int sourceX,
        int sourceY,
        uint operation);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr obj);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hdc);
}
"@
}

function Get-ProcessWindow {
    param([int]$TargetProcessId)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WindowTimeoutMs)
    do {
        $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
        $process.Refresh()
        $handle = $process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero -and
                [CodexWindowCapture]::IsWindowVisible($handle)) {
            return [pscustomobject]@{
                Process = $process
                Handle = $handle
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Godot window was not ready within $WindowTimeoutMs ms."
}

$window = Get-ProcessWindow -TargetProcessId $ProcessId
$hwnd = $window.Handle

[void][CodexWindowCapture]::ShowWindowAsync($hwnd, 9)
[void][CodexWindowCapture]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds $CaptureDelayMs

$clientRect = New-Object CodexWindowCapture+RECT
if (-not [CodexWindowCapture]::GetClientRect($hwnd, [ref]$clientRect)) {
    throw "GetClientRect failed."
}
$width = $clientRect.Right - $clientRect.Left
$height = $clientRect.Bottom - $clientRect.Top
if ($width -le 0 -or $height -le 0) {
    throw "Invalid client size: ${width}x${height}."
}

$clientOrigin = New-Object CodexWindowCapture+POINT
$clientOrigin.X = 0
$clientOrigin.Y = 0
if (-not [CodexWindowCapture]::ClientToScreen($hwnd, [ref]$clientOrigin)) {
    throw "ClientToScreen failed."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$captureStartedAt = Get-Date

$screenDc = [CodexWindowCapture]::GetDC([IntPtr]::Zero)
if ($screenDc -eq [IntPtr]::Zero) {
    throw "GetDC(screen) failed."
}

$bitmapPath = Join-Path $OutputDirectory "os_bitblt_client.png"
$printWindowPath = Join-Path $OutputDirectory "os_printwindow_full.png"
$printWindowClientPath = Join-Path $OutputDirectory "os_printwindow_client.png"
$windowRect = New-Object CodexWindowCapture+RECT
$hasWindowRect = [CodexWindowCapture]::GetWindowRect($hwnd, [ref]$windowRect)
try {
    $memoryDc = [CodexWindowCapture]::CreateCompatibleDC($screenDc)
    if ($memoryDc -eq [IntPtr]::Zero) {
        throw "CreateCompatibleDC failed."
    }
    $bitmapHandle = [CodexWindowCapture]::CreateCompatibleBitmap(
        $screenDc, $width, $height)
    if ($bitmapHandle -eq [IntPtr]::Zero) {
        throw "CreateCompatibleBitmap failed."
    }
    $previousObject = [CodexWindowCapture]::SelectObject($memoryDc, $bitmapHandle)
    try {
        $sourceFlags = [uint32](0x00CC0020 -bor 0x40000000)
        $ok = [CodexWindowCapture]::BitBlt(
            $memoryDc,
            0,
            0,
            $width,
            $height,
            $screenDc,
            $clientOrigin.X,
            $clientOrigin.Y,
            $sourceFlags)
        if (-not $ok) {
            throw "BitBlt failed."
        }
        $image = [System.Drawing.Image]::FromHbitmap($bitmapHandle)
        try {
            $image.Save($bitmapPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $image.Dispose()
        }
    }
    finally {
        [void][CodexWindowCapture]::SelectObject($memoryDc, $previousObject)
        [void][CodexWindowCapture]::DeleteObject($bitmapHandle)
        [void][CodexWindowCapture]::DeleteDC($memoryDc)
    }

    if ($hasWindowRect) {
        $windowWidth = $windowRect.Right - $windowRect.Left
        $windowHeight = $windowRect.Bottom - $windowRect.Top
        $printBitmap = New-Object System.Drawing.Bitmap(
            $windowWidth, $windowHeight,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $printGraphics = [System.Drawing.Graphics]::FromImage($printBitmap)
        try {
            $printDc = $printGraphics.GetHdc()
            try {
                [void][CodexWindowCapture]::PrintWindow($hwnd, $printDc, 2)
            }
            finally {
                $printGraphics.ReleaseHdc($printDc)
            }
            $printBitmap.Save(
                $printWindowPath,
                [System.Drawing.Imaging.ImageFormat]::Png)
            $clientOffsetX = $clientOrigin.X - $windowRect.Left
            $clientOffsetY = $clientOrigin.Y - $windowRect.Top
            $clientCrop = New-Object System.Drawing.Rectangle(
                $clientOffsetX,
                $clientOffsetY,
                $width,
                $height)
            $cropIsValid = ($clientCrop.Left -ge 0) -and
                ($clientCrop.Top -ge 0) -and
                ($clientCrop.Right -le $printBitmap.Width) -and
                ($clientCrop.Bottom -le $printBitmap.Height)
            if ($cropIsValid) {
                $printClientBitmap = $printBitmap.Clone(
                    $clientCrop,
                    $printBitmap.PixelFormat)
                try {
                    $printClientBitmap.Save(
                        $printWindowClientPath,
                        [System.Drawing.Imaging.ImageFormat]::Png)
                }
                finally {
                    $printClientBitmap.Dispose()
                }
            }
        }
        finally {
            $printGraphics.Dispose()
            $printBitmap.Dispose()
        }
    }
}
finally {
    [void][CodexWindowCapture]::ReleaseDC([IntPtr]::Zero, $screenDc)
}

$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
$metadata = [ordered]@{
    captured_at = $captureStartedAt.ToString("o")
    capture_method = "Windows GDI BitBlt(client) + PrintWindow(full)"
    process_id = $ProcessId
    process_name = $window.Process.ProcessName
    process_command_line = $processInfo.CommandLine
    window_handle = $hwnd.ToInt64()
    window_title = $window.Process.MainWindowTitle
    client_screen_x = $clientOrigin.X
    client_screen_y = $clientOrigin.Y
    client_width = $width
    client_height = $height
    window_left = if ($hasWindowRect) { $windowRect.Left } else { $null }
    window_top = if ($hasWindowRect) { $windowRect.Top } else { $null }
    window_width = if ($hasWindowRect) {
        $windowRect.Right - $windowRect.Left
    } else {
        $null
    }
    window_height = if ($hasWindowRect) {
        $windowRect.Bottom - $windowRect.Top
    } else {
        $null
    }
    client_capture = $bitmapPath
    printwindow_capture = if (Test-Path -LiteralPath $printWindowPath) {
        $printWindowPath
    } else {
        $null
    }
    printwindow_client_capture = if (Test-Path -LiteralPath $printWindowClientPath) {
        $printWindowClientPath
    } else {
        $null
    }
}
$metadataPath = Join-Path $OutputDirectory "os_capture_metadata.json"
$metadata | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $metadataPath -Encoding UTF8

Write-Output $bitmapPath
Write-Output $printWindowPath
if (Test-Path -LiteralPath $printWindowClientPath) {
    Write-Output $printWindowClientPath
}
Write-Output $metadataPath
