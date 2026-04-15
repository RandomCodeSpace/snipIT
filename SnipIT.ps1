#requires -Version 7.5
<#
    SnipIT — professional snipping tool for Windows 11
    Pure PowerShell 7.5+ on .NET 9. No admin. No external dependencies.

    Hotkeys:
      Ctrl+Shift+S  Smart capture (hover-window or drag-region) with magnifier
      Ctrl+Shift+F  Full virtual-desktop capture

    Tray menu: Capture region / Capture full screen / Show widget / About / Uninstall / Exit

    Run with -CoreOnly to dot-source only the pure logic functions (used by tests).
#>
param([switch]$CoreOnly)

#region Core (pure logic, no UI / no Win32, cross-platform testable) =========

function Get-DragRectangle {
    param(
        [Parameter(Mandatory)] [double]$AnchorX,
        [Parameter(Mandatory)] [double]$AnchorY,
        [Parameter(Mandatory)] [double]$CurrentX,
        [Parameter(Mandatory)] [double]$CurrentY
    )
    [pscustomobject]@{
        X      = [math]::Min($AnchorX, $CurrentX)
        Y      = [math]::Min($AnchorY, $CurrentY)
        Width  = [math]::Abs($CurrentX - $AnchorX)
        Height = [math]::Abs($CurrentY - $AnchorY)
    }
}

function Test-IsClickVsDrag {
    param(
        [Parameter(Mandatory)] [double]$AnchorX,
        [Parameter(Mandatory)] [double]$AnchorY,
        [Parameter(Mandatory)] [double]$CurrentX,
        [Parameter(Mandatory)] [double]$CurrentY,
        [double]$Threshold = 4
    )
    $dx = [math]::Abs($CurrentX - $AnchorX)
    $dy = [math]::Abs($CurrentY - $AnchorY)
    if ($dx -lt $Threshold -and $dy -lt $Threshold) { 'click' } else { 'drag' }
}

function Get-LoupeSourceRect {
    param(
        [Parameter(Mandatory)] [int]$MouseX,
        [Parameter(Mandatory)] [int]$MouseY,
        [Parameter(Mandatory)] [int]$VsX,
        [Parameter(Mandatory)] [int]$VsY,
        [Parameter(Mandatory)] [int]$VsWidth,
        [Parameter(Mandatory)] [int]$VsHeight,
        [int]$Size = 18
    )
    $half = [math]::Floor($Size / 2)
    $sx = $MouseX - $VsX - $half
    $sy = $MouseY - $VsY - $half
    $sx = [math]::Max(0, [math]::Min($VsWidth  - $Size, $sx))
    $sy = [math]::Max(0, [math]::Min($VsHeight - $Size, $sy))
    [pscustomobject]@{ X = [int]$sx; Y = [int]$sy; Size = $Size }
}

function Get-LoupePosition {
    param(
        [Parameter(Mandatory)] [int]$MouseX,
        [Parameter(Mandatory)] [int]$MouseY,
        [Parameter(Mandatory)] [int]$VsX,
        [Parameter(Mandatory)] [int]$VsY,
        [Parameter(Mandatory)] [int]$VsWidth,
        [Parameter(Mandatory)] [int]$VsHeight,
        [int]$LoupeWidth  = 170,
        [int]$LoupeHeight = 190,
        [int]$Offset = 24
    )
    $lx = $MouseX - $VsX + $Offset
    $ly = $MouseY - $VsY + $Offset
    if ($lx + $LoupeWidth  -gt $VsWidth)  { $lx = $MouseX - $VsX - $LoupeWidth  - 14 }
    if ($ly + $LoupeHeight -gt $VsHeight) { $ly = $MouseY - $VsY - $LoupeHeight - 10 }
    [pscustomobject]@{ X = [int]$lx; Y = [int]$ly }
}

function Get-DefaultSnipFilename {
    param([datetime]$Timestamp = (Get-Date))
    "snip-{0:yyyyMMdd-HHmmss}.png" -f $Timestamp
}

function Get-ImageFormatNameFromPath {
    param([Parameter(Mandatory)] [string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLower()) {
        '.jpg'  { 'Jpeg' }
        '.jpeg' { 'Jpeg' }
        '.bmp'  { 'Bmp'  }
        default { 'Png'  }
    }
}

function Test-CaptureRectValid {
    param(
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [int]$MinSize = 2
    )
    ($Width -ge $MinSize) -and ($Height -ge $MinSize)
}

function Get-CropBounds {
    param(
        [Parameter(Mandatory)] [int]$RectX,
        [Parameter(Mandatory)] [int]$RectY,
        [Parameter(Mandatory)] [int]$RectW,
        [Parameter(Mandatory)] [int]$RectH,
        [Parameter(Mandatory)] [int]$VsX,
        [Parameter(Mandatory)] [int]$VsY
    )
    [pscustomobject]@{
        X      = $RectX - $VsX
        Y      = $RectY - $VsY
        Width  = $RectW
        Height = $RectH
    }
}

function Get-InstallPaths {
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$DesktopDir,
        [string]$StartupDir
    )
    [pscustomobject]@{
        AppDir          = Join-Path $LocalAppData 'SnipIT'
        ScriptPath      = Join-Path (Join-Path $LocalAppData 'SnipIT') 'SnipIT.ps1'
        Marker          = Join-Path (Join-Path $LocalAppData 'SnipIT') '.installed'
        DesktopShortcut = if ($DesktopDir) { Join-Path $DesktopDir 'SnipIT.lnk' } else { $null }
        StartupShortcut = if ($StartupDir) { Join-Path $StartupDir 'SnipIT.lnk' } else { $null }
    }
}

function Get-ShortcutArguments {
    param([Parameter(Mandatory)] [string]$ScriptPath)
    "-NoProfile -WindowStyle Hidden -Sta -File `"$ScriptPath`""
}

#endregion

# Tests dot-source this script with -CoreOnly to load only the pure functions above.
if ($CoreOnly) { return }

#region Bootstrap ===========================================================

# Self-relaunch in STA (PowerShell 7 defaults to MTA; WPF requires STA)
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process -FilePath $pwsh `
        -ArgumentList @('-Sta','-NoProfile','-WindowStyle','Hidden','-File',$PSCommandPath) `
        -WindowStyle Hidden
    return
}

# Hide console window if launched visibly
if (-not ('ConsoleHider' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleHider {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
}
$h = [ConsoleHider]::GetConsoleWindow()
if ($h -ne [IntPtr]::Zero) { [ConsoleHider]::ShowWindow($h, 0) | Out-Null }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# .NET 9 WPF Fluent theme
try { [System.Windows.Application]::Current.ThemeMode = 'System' } catch {}

#endregion

#region PInvoke =============================================================

$pinvoke = @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;

public static class Native {
    // DPI awareness
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    // Hotkey
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    // Window discovery
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    public const uint GA_ROOT = 2;

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    // DWM extended frame bounds (no drop shadow)
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT rect, int size);
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    // Mica backdrop (Win11)
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hWnd, int attr, ref int value, int size);
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    public const int DWMSBT_MAINWINDOW = 2;     // Mica
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    // Cursor pos in screen pixels
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
}
'@
if (-not ('Native' -as [type])) {
    Add-Type -TypeDefinition $pinvoke -ReferencedAssemblies ([System.Drawing.Bitmap].Assembly.Location)
}
[Native]::SetProcessDpiAwarenessContext([Native]::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) | Out-Null

#endregion

#region First-Run Install ===================================================

function Install-SnipIT {
    $appDir   = Join-Path $env:LOCALAPPDATA 'SnipIT'
    $marker   = Join-Path $appDir '.installed'
    $target   = Join-Path $appDir 'SnipIT.ps1'

    if (Test-Path $marker) { return $false }   # already installed

    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force

    $pwshExe   = (Get-Process -Id $PID).Path
    $shortcutArgs = "-NoProfile -WindowStyle Hidden -Sta -File `"$target`""
    $iconPath = Get-SnipITIconPath
    $iconSource = "$iconPath,0"

    function New-Lnk($linkPath) {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($linkPath)
        $sc.TargetPath       = $pwshExe
        $sc.Arguments        = $shortcutArgs
        $sc.WorkingDirectory = $appDir
        $sc.IconLocation     = $iconSource
        $sc.WindowStyle      = 7   # minimized
        $sc.Description      = 'SnipIT - professional snipping tool'
        $sc.Save()
    }

    New-Lnk (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SnipIT.lnk')
    New-Lnk (Join-Path ([Environment]::GetFolderPath('Startup')) 'SnipIT.lnk')

    Set-Content -LiteralPath $marker -Value (Get-Date -Format o)
    return $true
}

function Uninstall-SnipIT {
    $appDir = Join-Path $env:LOCALAPPDATA 'SnipIT'
    Remove-Item -Force -ErrorAction SilentlyContinue `
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SnipIT.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'SnipIT.lnk')
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $appDir
}

$freshInstall = Install-SnipIT

#endregion

#region Capture Core ========================================================

function Get-VirtualScreenBounds {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    [pscustomobject]@{ X=$vs.X; Y=$vs.Y; Width=$vs.Width; Height=$vs.Height }
}

function New-ScreenBitmap {
    param($X, $Y, $Width, $Height)
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height,
        ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0,
        (New-Object System.Drawing.Size $Width, $Height),
        [System.Drawing.CopyPixelOperation]::SourceCopy)
    $g.Dispose()
    return $bmp
}

function Convert-BitmapToBitmapSource {
    param([System.Drawing.Bitmap]$Bitmap)
    $hbmp = $Bitmap.GetHbitmap()
    try {
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $hbmp, [IntPtr]::Zero,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        return $src
    } finally {
        # GDI handle leak guard
        $del = Add-Type -PassThru -Name GdiCleanup$([guid]::NewGuid().ToString('N')) -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern bool DeleteObject(System.IntPtr hObject);
'@ -ErrorAction SilentlyContinue
        if ($del) { $del::DeleteObject($hbmp) | Out-Null }
    }
}

function Save-CaptureToFile {
    param([System.Drawing.Bitmap]$Bitmap)
    $defaultDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Snips'
    New-Item -ItemType Directory -Force -Path $defaultDir | Out-Null
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'PNG image (*.png)|*.png|JPEG (*.jpg)|*.jpg|Bitmap (*.bmp)|*.bmp'
    $dlg.FileName = Get-DefaultSnipFilename
    $dlg.InitialDirectory = $defaultDir
    if ($dlg.ShowDialog()) {
        $fmt = switch (Get-ImageFormatNameFromPath $dlg.FileName) {
            'Jpeg' { [System.Drawing.Imaging.ImageFormat]::Jpeg }
            'Bmp'  { [System.Drawing.Imaging.ImageFormat]::Bmp  }
            default { [System.Drawing.Imaging.ImageFormat]::Png }
        }
        $Bitmap.Save($dlg.FileName, $fmt)
        return $dlg.FileName
    }
    return $null
}

function New-SnipITIcon {
    param([Parameter(Mandatory)] [string]$Path)
    $bmp = New-Object System.Drawing.Bitmap 64, 64
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # Rounded background tile in system accent
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,0,120,212))
    $g.FillRectangle($bg, 6, 6, 52, 52)
    $bg.Dispose()
    # White selection-corner brackets
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 5
    $g.DrawLine($pen, 16, 16, 16, 26); $g.DrawLine($pen, 16, 16, 26, 16)
    $g.DrawLine($pen, 48, 16, 38, 16); $g.DrawLine($pen, 48, 16, 48, 26)
    $g.DrawLine($pen, 16, 48, 16, 38); $g.DrawLine($pen, 16, 48, 26, 48)
    $g.DrawLine($pen, 48, 48, 48, 38); $g.DrawLine($pen, 48, 48, 38, 48)
    $pen.Dispose(); $g.Dispose()
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    $fs = [System.IO.File]::Open($Path, 'Create')
    try { $icon.Save($fs) } finally { $fs.Close(); $icon.Dispose(); $bmp.Dispose() }
    return $Path
}

function Get-SnipITIconPath {
    $dir = Join-Path $env:LOCALAPPDATA 'SnipIT'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Join-Path $dir 'SnipIT.ico'
    if (-not (Test-Path $p)) { New-SnipITIcon -Path $p | Out-Null }
    return $p
}

function Set-MicaBackdrop {
    param([System.Windows.Window]$Window)
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper $Window
        $hwnd = $helper.Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $val = [Native]::DWMSBT_MAINWINDOW
        [Native]::DwmSetWindowAttribute($hwnd, [Native]::DWMWA_SYSTEMBACKDROP_TYPE, [ref]$val, 4) | Out-Null
        $dark = 1
        [Native]::DwmSetWindowAttribute($hwnd, [Native]::DWMWA_USE_IMMERSIVE_DARK_MODE, [ref]$dark, 4) | Out-Null
    } catch {}
}

#endregion

#region Smart Overlay (hover + drag + magnifier) ============================

function Show-SmartOverlay {
    $vs   = Get-VirtualScreenBounds
    $snap = New-ScreenBitmap -X $vs.X -Y $vs.Y -Width $vs.Width -Height $vs.Height
    $snapSrc = Convert-BitmapToBitmapSource $snap

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Left="$($vs.X)" Top="$($vs.Y)" Width="$($vs.Width)" Height="$($vs.Height)"
        Cursor="Cross">
  <Grid>
    <Image x:Name="BgImage" Stretch="None"/>
    <Rectangle Fill="#80000000"/>
    <Canvas x:Name="OverlayCanvas">
      <Rectangle x:Name="HoverRect" Stroke="#0078D4" StrokeThickness="2"
                 Fill="#330078D4" Visibility="Collapsed"/>
      <Rectangle x:Name="DragRect"  Stroke="#FFFFFF" StrokeThickness="1.5"
                 StrokeDashArray="4 2" Fill="#33FFFFFF" Visibility="Collapsed"/>
      <Border x:Name="LoupeBorder" Width="160" Height="180"
              Background="#CC1F1F1F" CornerRadius="8"
              BorderBrush="#FF0078D4" BorderThickness="1" Visibility="Collapsed">
        <StackPanel>
          <Border Width="144" Height="144" Margin="8,8,8,4"
                  BorderBrush="#55FFFFFF" BorderThickness="1" ClipToBounds="True">
            <Grid>
              <Image x:Name="LoupeImage" Stretch="None"
                     RenderOptions.BitmapScalingMode="NearestNeighbor"/>
              <Line X1="72" Y1="0" X2="72" Y2="144" Stroke="#990078D4" StrokeThickness="1"/>
              <Line X1="0"  Y1="72" X2="144" Y2="72" Stroke="#990078D4" StrokeThickness="1"/>
            </Grid>
          </Border>
          <TextBlock x:Name="LoupeText" Foreground="White" FontFamily="Consolas"
                     FontSize="11" HorizontalAlignment="Center" Margin="0,0,0,6"/>
        </StackPanel>
      </Border>
      <TextBlock x:Name="HintText" Foreground="#CCFFFFFF" FontSize="13"
                 Canvas.Left="20" Canvas.Top="20"
                 Text="Click a window to capture it · Drag for a region · Esc to cancel"/>
    </Canvas>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $bg     = $win.FindName('BgImage')
    $bg.Source = $snapSrc
    $hoverRect = $win.FindName('HoverRect')
    $dragRect  = $win.FindName('DragRect')
    $loupe     = $win.FindName('LoupeBorder')
    $loupeImg  = $win.FindName('LoupeImage')
    $loupeText = $win.FindName('LoupeText')

    $state = [pscustomobject]@{
        Dragging   = $false
        Anchor     = $null
        HoverHwnd  = [IntPtr]::Zero
        HoverRect  = $null
        Result     = $null   # System.Drawing.Rectangle in screen coords
        Snapshot   = $snap
        VS         = $vs
        SnapSrc    = $snapSrc
    }

    $updateLoupe = {
        param($mx, $my)
        $src = Get-LoupeSourceRect -MouseX $mx -MouseY $my `
            -VsX $vs.X -VsY $vs.Y -VsWidth $vs.Width -VsHeight $vs.Height -Size 18
        $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap(
            $state.SnapSrc,
            (New-Object System.Windows.Int32Rect $src.X, $src.Y, $src.Size, $src.Size))
        $loupeImg.Width  = $src.Size * 8
        $loupeImg.Height = $src.Size * 8
        $loupeImg.Source = $crop
        $loupeText.Text  = ('{0,4} , {1,4}' -f $mx, $my)
        $pos = Get-LoupePosition -MouseX $mx -MouseY $my `
            -VsX $vs.X -VsY $vs.Y -VsWidth $vs.Width -VsHeight $vs.Height
        [System.Windows.Controls.Canvas]::SetLeft($loupe, $pos.X)
        [System.Windows.Controls.Canvas]::SetTop($loupe,  $pos.Y)
        $loupe.Visibility = 'Visible'
    }

    $win.Add_MouseMove({
        $p = [System.Windows.Input.Mouse]::GetPosition($win)
        $mx = [int]($p.X + $vs.X)
        $my = [int]($p.Y + $vs.Y)
        & $updateLoupe $mx $my

        if ($state.Dragging) {
            $hoverRect.Visibility = 'Collapsed'
            $r = Get-DragRectangle -AnchorX $state.Anchor.X -AnchorY $state.Anchor.Y `
                -CurrentX $p.X -CurrentY $p.Y
            [System.Windows.Controls.Canvas]::SetLeft($dragRect, $r.X)
            [System.Windows.Controls.Canvas]::SetTop($dragRect,  $r.Y)
            $dragRect.Width  = $r.Width
            $dragRect.Height = $r.Height
            $dragRect.Visibility = 'Visible'
            return
        }

        # Hover-window detection
        $pt = New-Object Native+POINT
        $pt.X = $mx; $pt.Y = $my
        $hwnd = [Native]::WindowFromPoint($pt)
        if ($hwnd -ne [IntPtr]::Zero) {
            $top = [Native]::GetAncestor($hwnd, [Native]::GA_ROOT)
            # Skip our own overlay
            $myHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
            if ($top -eq $myHwnd) { return }
            if ($top -ne $state.HoverHwnd) {
                $state.HoverHwnd = $top
                $r = New-Object Native+RECT
                $ok = ([Native]::DwmGetWindowAttribute($top, [Native]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$r, 16) -eq 0)
                if (-not $ok) { [Native]::GetWindowRect($top, [ref]$r) | Out-Null }
                $state.HoverRect = [pscustomobject]@{
                    X = $r.Left; Y = $r.Top
                    W = $r.Right - $r.Left; H = $r.Bottom - $r.Top
                }
            }
            if ($state.HoverRect) {
                [System.Windows.Controls.Canvas]::SetLeft($hoverRect, $state.HoverRect.X - $vs.X)
                [System.Windows.Controls.Canvas]::SetTop($hoverRect,  $state.HoverRect.Y - $vs.Y)
                $hoverRect.Width  = $state.HoverRect.W
                $hoverRect.Height = $state.HoverRect.H
                $hoverRect.Visibility = 'Visible'
            }
        }
    })

    $win.Add_MouseLeftButtonDown({
        $state.Dragging = $true
        $state.Anchor = [System.Windows.Input.Mouse]::GetPosition($win)
    })

    $win.Add_MouseLeftButtonUp({
        $p = [System.Windows.Input.Mouse]::GetPosition($win)
        $kind = Test-IsClickVsDrag -AnchorX $state.Anchor.X -AnchorY $state.Anchor.Y `
            -CurrentX $p.X -CurrentY $p.Y
        if ($kind -eq 'click') {
            if ($state.HoverRect) {
                $state.Result = New-Object System.Drawing.Rectangle (
                    [int]$state.HoverRect.X, [int]$state.HoverRect.Y,
                    [int]$state.HoverRect.W, [int]$state.HoverRect.H)
            }
        } else {
            $r = Get-DragRectangle -AnchorX $state.Anchor.X -AnchorY $state.Anchor.Y `
                -CurrentX $p.X -CurrentY $p.Y
            $state.Result = New-Object System.Drawing.Rectangle (
                [int]($r.X + $vs.X), [int]($r.Y + $vs.Y),
                [int]$r.Width, [int]$r.Height)
        }
        $win.Close()
    })

    $win.Add_KeyDown({
        if ($_.Key -eq 'Escape') { $state.Result = $null; $win.Close() }
    })

    $win.Add_MouseRightButtonDown({
        $state.Result = $null
        $state.Dragging = $false
        $win.Close()
    })

    $win.Add_Loaded({ $win.Activate() | Out-Null })
    $win.ShowDialog() | Out-Null

    if (-not $state.Result -or -not (Test-CaptureRectValid -Width $state.Result.Width -Height $state.Result.Height)) {
        $snap.Dispose()
        return $null
    }

    # Crop snapshot to chosen rect
    $crop = Get-CropBounds -RectX $state.Result.X -RectY $state.Result.Y `
        -RectW $state.Result.Width -RectH $state.Result.Height -VsX $vs.X -VsY $vs.Y
    $cropX = $crop.X
    $cropY = $crop.Y
    $cropped = New-Object System.Drawing.Bitmap $state.Result.Width, $state.Result.Height,
        ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($cropped)
    $g.DrawImage($snap,
        (New-Object System.Drawing.Rectangle 0, 0, $state.Result.Width, $state.Result.Height),
        (New-Object System.Drawing.Rectangle $cropX, $cropY, $state.Result.Width, $state.Result.Height),
        [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $snap.Dispose()
    return $cropped
}

#endregion

#region Preview Window ======================================================

function Show-PreviewWindow {
    param([System.Drawing.Bitmap]$Bitmap)

    $src = Convert-BitmapToBitmapSource $Bitmap

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SnipIT — Preview"
        Width="900" Height="640" MinWidth="500" MinHeight="360"
        WindowStartupLocation="CenterScreen"
        Background="Transparent">
  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Padding="16,12" Background="#22000000">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE722;" FontFamily="Segoe Fluent Icons"
                   FontSize="20" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBlock Text="SnipIT" FontSize="16" FontWeight="SemiBold"
                   Foreground="White" VerticalAlignment="Center"/>
        <TextBlock x:Name="DimText" Margin="14,0,0,0" Foreground="#AAFFFFFF"
                   VerticalAlignment="Center" FontSize="12"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" Margin="16,12" Background="#15000000" CornerRadius="8">
      <Grid x:Name="ImageHost" ClipToBounds="True">
        <Image x:Name="PreviewImage" Stretch="Uniform" Margin="8"/>
        <Canvas x:Name="HighlightLayer" Background="Transparent" IsHitTestVisible="True"/>
      </Grid>
    </Border>

    <Border Grid.Row="2" Padding="16,12" Background="#22000000">
      <DockPanel LastChildFill="False">
        <ToggleButton x:Name="HighlightBtn" DockPanel.Dock="Left" MinWidth="120" Margin="0,0,8,0" Padding="14,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7E6;" FontFamily="Segoe Fluent Icons" Margin="0,0,8,0"/>
            <TextBlock Text="Highlight"/>
          </StackPanel>
        </ToggleButton>
        <Button x:Name="ClearBtn" DockPanel.Dock="Left" MinWidth="100" Margin="0,0,8,0" Padding="14,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE74D;" FontFamily="Segoe Fluent Icons" Margin="0,0,8,0"/>
            <TextBlock Text="Clear"/>
          </StackPanel>
        </Button>
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
          <Button x:Name="CopyBtn"  MinWidth="110" Margin="0,0,8,0" Padding="14,8">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE8C8;" FontFamily="Segoe Fluent Icons" Margin="0,0,8,0"/>
              <TextBlock Text="Copy"/>
            </StackPanel>
          </Button>
          <Button x:Name="SaveBtn"  MinWidth="110" Margin="0,0,8,0" Padding="14,8">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE74E;" FontFamily="Segoe Fluent Icons" Margin="0,0,8,0"/>
              <TextBlock Text="Save"/>
            </StackPanel>
          </Button>
          <Button x:Name="NewBtn"   MinWidth="110" Margin="0,0,8,0" Padding="14,8">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE7C5;" FontFamily="Segoe Fluent Icons" Margin="0,0,8,0"/>
              <TextBlock Text="New snip"/>
            </StackPanel>
          </Button>
          <Button x:Name="CloseBtn" MinWidth="110" Padding="14,8">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE711;" FontFamily="Segoe Fluent Icons" Margin="0,0,8,0"/>
              <TextBlock Text="Close"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $previewImage = $win.FindName('PreviewImage')
    $previewImage.Source = $src
    $win.FindName('DimText').Text = "$($Bitmap.Width) × $($Bitmap.Height) px"

    $win.Add_SourceInitialized({ Set-MicaBackdrop -Window $win })

    # Highlight annotation state — list of System.Drawing.Rectangle in IMAGE pixels
    $highlights      = New-Object System.Collections.ArrayList
    $highlightLayer  = $win.FindName('HighlightLayer')
    $highlightBtn    = $win.FindName('HighlightBtn')
    $clearBtn        = $win.FindName('ClearBtn')
    $imageHost       = $win.FindName('ImageHost')
    $drawing         = [pscustomobject]@{ Active=$false; Anchor=$null; Rect=$null }

    function script:Get-DisplayedImageBounds {
        # Returns the rectangle (within ImageHost) where PreviewImage actually paints,
        # accounting for Stretch=Uniform letterboxing. Margin is 8 on each side.
        $hostW = $imageHost.ActualWidth  - 16
        $hostH = $imageHost.ActualHeight - 16
        if ($hostW -le 0 -or $hostH -le 0) { return $null }
        $imgW = $Bitmap.Width; $imgH = $Bitmap.Height
        $scale = [math]::Min($hostW / $imgW, $hostH / $imgH)
        $w = $imgW * $scale; $h = $imgH * $scale
        $offX = 8 + ($hostW - $w) / 2
        $offY = 8 + ($hostH - $h) / 2
        [pscustomobject]@{ X=$offX; Y=$offY; W=$w; H=$h; Scale=$scale }
    }

    $highlightLayer.Add_MouseLeftButtonDown({
        if (-not $highlightBtn.IsChecked) { return }
        $b = Get-DisplayedImageBounds; if (-not $b) { return }
        $p = $_.GetPosition($highlightLayer)
        $drawing.Active = $true
        $drawing.Anchor = $p
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Fill   = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb(110, 255, 235, 0))
        $rect.Stroke = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb(220, 255, 200, 0))
        $rect.StrokeThickness = 1.5
        [System.Windows.Controls.Canvas]::SetLeft($rect, $p.X)
        [System.Windows.Controls.Canvas]::SetTop($rect,  $p.Y)
        $rect.Width = 0; $rect.Height = 0
        $highlightLayer.Children.Add($rect) | Out-Null
        $drawing.Rect = $rect
        $highlightLayer.CaptureMouse() | Out-Null
    })

    $highlightLayer.Add_MouseMove({
        if (-not $drawing.Active -or -not $drawing.Rect) { return }
        $p = $_.GetPosition($highlightLayer)
        $r = Get-DragRectangle -AnchorX $drawing.Anchor.X -AnchorY $drawing.Anchor.Y `
            -CurrentX $p.X -CurrentY $p.Y
        [System.Windows.Controls.Canvas]::SetLeft($drawing.Rect, $r.X)
        [System.Windows.Controls.Canvas]::SetTop($drawing.Rect,  $r.Y)
        $drawing.Rect.Width  = $r.Width
        $drawing.Rect.Height = $r.Height
    })

    $highlightLayer.Add_MouseLeftButtonUp({
        if (-not $drawing.Active) { return }
        $drawing.Active = $false
        $highlightLayer.ReleaseMouseCapture()
        $b = Get-DisplayedImageBounds
        if (-not $b -or $drawing.Rect.Width -lt 3 -or $drawing.Rect.Height -lt 3) {
            if ($drawing.Rect) { $highlightLayer.Children.Remove($drawing.Rect) }
            $drawing.Rect = $null
            return
        }
        # Convert canvas coords → image-pixel coords, clamped
        $canvasX = [System.Windows.Controls.Canvas]::GetLeft($drawing.Rect)
        $canvasY = [System.Windows.Controls.Canvas]::GetTop($drawing.Rect)
        $px = [int][math]::Round(($canvasX - $b.X) / $b.Scale)
        $py = [int][math]::Round(($canvasY - $b.Y) / $b.Scale)
        $pw = [int][math]::Round($drawing.Rect.Width  / $b.Scale)
        $ph = [int][math]::Round($drawing.Rect.Height / $b.Scale)
        $px = [math]::Max(0, [math]::Min($Bitmap.Width  - 1, $px))
        $py = [math]::Max(0, [math]::Min($Bitmap.Height - 1, $py))
        $pw = [math]::Max(1, [math]::Min($Bitmap.Width  - $px, $pw))
        $ph = [math]::Max(1, [math]::Min($Bitmap.Height - $py, $ph))
        [void]$highlights.Add([pscustomobject]@{ X=$px; Y=$py; W=$pw; H=$ph })
        $drawing.Rect = $null
    })

    $clearBtn.Add_Click({
        $highlightLayer.Children.Clear()
        $highlights.Clear()
    })

    function script:Get-FlattenedBitmap {
        if ($highlights.Count -eq 0) { return $Bitmap }
        $flat = New-Object System.Drawing.Bitmap $Bitmap.Width, $Bitmap.Height,
            ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($flat)
        $g.DrawImage($Bitmap, 0, 0, $Bitmap.Width, $Bitmap.Height)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 255, 235, 0))
        foreach ($h in $highlights) {
            $g.FillRectangle($brush, [int]$h.X, [int]$h.Y, [int]$h.W, [int]$h.H)
        }
        $brush.Dispose(); $g.Dispose()
        return $flat
    }

    $win.FindName('CopyBtn').Add_Click({
        $flat = Get-FlattenedBitmap
        $clipSrc = Convert-BitmapToBitmapSource $flat
        [System.Windows.Clipboard]::SetImage($clipSrc)
        if ($flat -ne $Bitmap) { $flat.Dispose() }
    })
    $win.FindName('SaveBtn').Add_Click({
        $flat = Get-FlattenedBitmap
        Save-CaptureToFile -Bitmap $flat | Out-Null
        if ($flat -ne $Bitmap) { $flat.Dispose() }
    })
    $win.FindName('NewBtn').Add_Click({
        $win.Close()
        $script:RequestNewSnip = $true
    })
    $win.FindName('CloseBtn').Add_Click({ $win.Close() })

    $script:RequestNewSnip = $false
    $win.ShowDialog() | Out-Null
    return $script:RequestNewSnip
}

#endregion

#region Capture Orchestration ===============================================

function Invoke-SmartCapture {
    do {
        $bmp = Show-SmartOverlay
        if (-not $bmp) { return }
        $again = Show-PreviewWindow -Bitmap $bmp
        $bmp.Dispose()
    } while ($again)
}

function Invoke-FullScreenCapture {
    $vs = Get-VirtualScreenBounds
    $bmp = New-ScreenBitmap -X $vs.X -Y $vs.Y -Width $vs.Width -Height $vs.Height
    do {
        $again = Show-PreviewWindow -Bitmap $bmp
    } while ($again)
    $bmp.Dispose()
}

#endregion

#region Floating Widget =====================================================

$script:WidgetWindow = $null

function Show-FloatingWidget {
    if ($script:WidgetWindow) { $script:WidgetWindow.Show(); $script:WidgetWindow.Activate(); return }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="240" Height="56" SizeToContent="Manual">
  <Border CornerRadius="14" Background="#E61F1F1F" BorderBrush="#330078D4" BorderThickness="1">
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
      <Button x:Name="SmartBtn" Width="96" Height="36" Margin="8,0,4,0">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE7C5;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
          <TextBlock Text="Snip"/>
        </StackPanel>
      </Button>
      <Button x:Name="FullBtn"  Width="112" Height="36" Margin="4,0,8,0">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE740;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
          <TextBlock Text="Full screen"/>
        </StackPanel>
      </Button>
    </StackPanel>
  </Border>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [System.Windows.Markup.XamlReader]::Load($reader)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $win.Left = $screen.X + ($screen.Width - $win.Width) / 2
    $shownTop  = $screen.Y + 8
    $hiddenTop = $screen.Y - $win.Height + 6
    $win.Top = $hiddenTop

    $win.FindName('SmartBtn').Add_Click({ Invoke-SmartCapture })
    $win.FindName('FullBtn').Add_Click({  Invoke-FullScreenCapture })

    $win.Add_MouseEnter({ $win.Top = $shownTop })
    $win.Add_MouseLeave({
        $p = [System.Windows.Forms.Control]::MousePosition
        if ($p.Y -gt $shownTop + $win.Height + 4) { $win.Top = $hiddenTop }
    })

    # Poll mouse position to slide down when cursor approaches top edge
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        $p = [System.Windows.Forms.Control]::MousePosition
        if ($p.Y -le $screen.Y + 4 -and $p.X -ge $win.Left -and $p.X -le $win.Left + $win.Width) {
            $win.Top = $shownTop
        } elseif (-not $win.IsMouseOver -and $win.Top -ne $hiddenTop) {
            if ($p.Y -gt $shownTop + $win.Height + 8) { $win.Top = $hiddenTop }
        }
    })
    $timer.Start()
    $win.Add_Closed({ $timer.Stop(); $script:WidgetWindow = $null })

    $script:WidgetWindow = $win
    $win.Show()
}

#endregion

#region Tray + Hotkeys ======================================================

# Hidden message-only window for hotkeys
$hotkeyForm = New-Object System.Windows.Forms.Form
$hotkeyForm.FormBorderStyle = 'FixedToolWindow'
$hotkeyForm.ShowInTaskbar = $false
$hotkeyForm.Opacity = 0
$hotkeyForm.Size = New-Object System.Drawing.Size 1, 1
$hotkeyForm.StartPosition = 'Manual'
$hotkeyForm.Location = New-Object System.Drawing.Point -2000, -2000
$hotkeyForm.Add_Shown({ $hotkeyForm.Hide() })

$MOD_CONTROL = 0x2; $MOD_SHIFT = 0x4
$HOTKEY_SMART = 1
$HOTKEY_FULL  = 2
$VK_S = 0x53
$VK_F = 0x46
$WM_HOTKEY = 0x0312

# Subclass via NativeWindow. WndProc must NOT do work directly — it BeginInvokes
# the action on the form so the message returns immediately. Doing UI work
# (especially opening a WPF window) inside WndProc reentrantly causes hangs on
# some Win11 builds.
if (-not ('HotkeyWindow' -as [type])) {
    $nativeWindowSrc = @'
using System;
using System.Windows.Forms;
public class HotkeyWindow : NativeWindow {
    public event Action<int> HotkeyPressed;
    private Control sync;
    public HotkeyWindow(Form host) {
        sync = host;
        AssignHandle(host.Handle);
    }
    private void Fire(int id) {
        Action<int> h = HotkeyPressed;
        if (h != null) { h(id); }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) {
            int id = (int)m.WParam;
            if (sync != null && sync.IsHandleCreated) {
                sync.BeginInvoke(new Action(delegate { Fire(id); }));
            }
        }
        base.WndProc(ref m);
    }
}
'@
    # .NET 9 splits WinForms across multiple assemblies. Reference each by
    # resolving a type that lives in it.
    $refs = @(
        [System.Windows.Forms.Form].Assembly.Location,        # System.Windows.Forms
        [System.Windows.Forms.Message].Assembly.Location,     # System.Windows.Forms.Primitives
        [System.ComponentModel.Component].Assembly.Location,  # System.ComponentModel.Primitives
        [System.Drawing.Bitmap].Assembly.Location,            # System.Drawing.Common
        [System.Drawing.Color].Assembly.Location              # System.Drawing.Primitives
    ) | Sort-Object -Unique
    Add-Type -TypeDefinition $nativeWindowSrc -ReferencedAssemblies $refs
}

$hotkeyForm.CreateControl()
$null = $hotkeyForm.Handle
$hkWin = New-Object HotkeyWindow $hotkeyForm
$hkWin.add_HotkeyPressed({
    param($id)
    try {
        switch ($id) {
            1 { Invoke-SmartCapture }
            2 { Invoke-FullScreenCapture }
        }
    } catch {
        $tray.BalloonTipTitle = 'SnipIT error'
        $tray.BalloonTipText  = $_.Exception.Message
        $tray.ShowBalloonTip(3000)
    }
})

$hotkeyErrors = @()
if (-not [Native]::RegisterHotKey($hotkeyForm.Handle, $HOTKEY_SMART, ($MOD_CONTROL -bor $MOD_SHIFT), $VK_S)) {
    $hotkeyErrors += 'Ctrl+Shift+S'
}
if (-not [Native]::RegisterHotKey($hotkeyForm.Handle, $HOTKEY_FULL,  ($MOD_CONTROL -bor $MOD_SHIFT), $VK_F)) {
    $hotkeyErrors += 'Ctrl+Shift+F'
}

# Tray icon
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true
$tray.Text = 'SnipIT — Ctrl+Shift+S to snip'
try {
    $tray.Icon = New-Object System.Drawing.Icon (Get-SnipITIconPath)
} catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Smart capture (Ctrl+Shift+S)', $null, { Invoke-SmartCapture })
[void]$menu.Items.Add('Full screen (Ctrl+Shift+F)',   $null, { Invoke-FullScreenCapture })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Show floating widget',          $null, { Show-FloatingWidget })
[void]$menu.Items.Add('Open snips folder',             $null, {
    $dir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Snips'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Start-Process explorer.exe $dir
})
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('About', $null, {
    [System.Windows.Forms.MessageBox]::Show(
        "SnipIT`nProfessional snipping tool`nPowerShell 7.5+ on .NET 9`n`nCtrl+Shift+S — smart capture`nCtrl+Shift+F — full screen",
        'About SnipIT', 'OK', 'Information') | Out-Null
})
[void]$menu.Items.Add('Uninstall', $null, {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Remove SnipIT shortcuts and AppData folder?",
        'Uninstall SnipIT', 'YesNo', 'Warning')
    if ($r -eq 'Yes') {
        Uninstall-SnipIT
        $tray.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    }
})
[void]$menu.Items.Add('Exit', $null, {
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Invoke-SmartCapture })

if ($hotkeyErrors.Count -gt 0) {
    $tray.BalloonTipTitle = 'SnipIT — hotkey conflict'
    $tray.BalloonTipText  = "Could not register: $($hotkeyErrors -join ', '). Use the tray menu instead."
    $tray.ShowBalloonTip(5000)
} elseif ($freshInstall) {
    $tray.BalloonTipTitle = 'SnipIT installed'
    $tray.BalloonTipText  = 'Press Ctrl+Shift+S to capture. Right-click the tray icon for options.'
    $tray.ShowBalloonTip(4000)
}

#endregion

#region Main loop & cleanup =================================================

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    [Native]::UnregisterHotKey($hotkeyForm.Handle, $HOTKEY_SMART) | Out-Null
    [Native]::UnregisterHotKey($hotkeyForm.Handle, $HOTKEY_FULL)  | Out-Null
    $tray.Dispose()
    $hotkeyForm.Dispose()
}

#endregion
