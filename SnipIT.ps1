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
    # Position the magnifier loupe near the cursor, flipping to the opposite side
    # when it would spill off the virtual screen.
    #   $Offset            — gap below/right of the cursor in the default position
    #   $FlipMarginX/Y     — gap above/left of the cursor after a flip (smaller than
    #                         $Offset so the flipped loupe sits tighter to the cursor)
    param(
        [Parameter(Mandatory)] [int]$MouseX,
        [Parameter(Mandatory)] [int]$MouseY,
        [Parameter(Mandatory)] [int]$VsX,
        [Parameter(Mandatory)] [int]$VsY,
        [Parameter(Mandatory)] [int]$VsWidth,
        [Parameter(Mandatory)] [int]$VsHeight,
        [int]$LoupeWidth  = 170,
        [int]$LoupeHeight = 190,
        [int]$Offset      = 24,
        [int]$FlipMarginX = 14,
        [int]$FlipMarginY = 10
    )
    $lx = $MouseX - $VsX + $Offset
    $ly = $MouseY - $VsY + $Offset
    if ($lx + $LoupeWidth  -gt $VsWidth)  { $lx = $MouseX - $VsX - $LoupeWidth  - $FlipMarginX }
    if ($ly + $LoupeHeight -gt $VsHeight) { $ly = $MouseY - $VsY - $LoupeHeight - $FlipMarginY }
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

function Resolve-SaveImagePath {
    # If the user typed a non-image extension (e.g. "foo.txt"), force it to match the
    # selected filter so we never save PNG bytes under a misleading extension.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [ValidateSet('Png','Jpeg','Bmp')] [string]$FilterFormat
    )
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    if ($ext -in '.png','.jpg','.jpeg','.bmp') { return $Path }
    $targetExt = switch ($FilterFormat) { 'Jpeg' { '.jpg' } 'Bmp' { '.bmp' } default { '.png' } }
    $dir  = [IO.Path]::GetDirectoryName($Path)
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ([string]::IsNullOrEmpty($dir)) { "$base$targetExt" } else { Join-Path $dir "$base$targetExt" }
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

function Get-TrimmedRecent {
    # Keep only the top N items (for capping unbounded undo/redo stacks).
    # $Items is expected in most-recent-first order, matching [Stack].ToArray().
    param(
        [AllowNull()][AllowEmptyCollection()] $Items,
        [int]$MaxDepth = 100
    )
    if ($null -eq $Items) { return @() }
    $arr = @($Items)
    if ($arr.Count -le $MaxDepth) { return $arr }
    return $arr[0..($MaxDepth - 1)]
}

#endregion

# Tests dot-source this script with -CoreOnly to load only the pure functions above.
if ($CoreOnly) { return }

#region Bootstrap ===========================================================

# Preview-window settings (tuned constants shared across functions)
$script:UndoStackMaxDepth = 100

# Diagnostic ring buffer — lightweight log for previously-silent catch {} blocks.
# Inspect with: Get-SnipDiag  (shows the last N entries; default 200 deep)
$script:DiagRingSize = 200
$script:DiagRing     = New-Object System.Collections.Generic.Queue[string]

function Write-SnipDiag {
    param([string]$Message, $ErrorRecord = $null)
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    $line = if ($ErrorRecord) { "[$ts] $Message :: $($ErrorRecord.Exception.Message)" }
            else              { "[$ts] $Message" }
    $script:DiagRing.Enqueue($line)
    while ($script:DiagRing.Count -gt $script:DiagRingSize) { [void]$script:DiagRing.Dequeue() }
}

function Get-SnipDiag { $script:DiagRing.ToArray() }

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

# Single-instance guard via named mutex (per user session).
# Must happen AFTER WinForms is loaded so we can MessageBox on conflict.
# Skipped in test mode so a harness can dot-source this script while the
# real app is also running.
if (-not $env:SNIPIT_TEST_MODE) {
    $script:SingleInstanceCreated = $false
    $script:SingleInstanceMutex   = New-Object System.Threading.Mutex(
        $true, 'Local\SnipIT-SingleInstance-v1', [ref]$script:SingleInstanceCreated)
    if (-not $script:SingleInstanceCreated) {
        try {
            [System.Windows.Forms.MessageBox]::Show(
                'SnipIT is already running. Check the system tray (bottom-right) or press Ctrl+Shift+S.',
                'SnipIT', 'OK', 'Information') | Out-Null
        } catch {}
        try { $script:SingleInstanceMutex.Dispose() } catch {}
        return
    }
}

# Compute the persistent home directory: 'snipIT-Home' alongside the script.
# If we're already running from inside snipIT-Home, use the current dir.
$scriptDir = Split-Path $PSCommandPath -Parent
if ((Split-Path $scriptDir -Leaf) -eq 'snipIT-Home') {
    $script:AppHomeDir = $scriptDir
} else {
    $script:AppHomeDir = Join-Path $scriptDir 'snipIT-Home'
}
New-Item -ItemType Directory -Force -Path $script:AppHomeDir | Out-Null

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

#region Icon generation =====================================================
# Defined before First-Run Install because Install-SnipIT needs Get-SnipITIconPath
# at script-load time.

function New-SnipITIcon {
    param([Parameter(Mandatory)] [string]$Path)
    # Draw at 256x256 so the icon is sharp at every shortcut size.
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # Rounded square background in system accent
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0, 120, 212))
    $rect = New-Object System.Drawing.Rectangle 24, 24, 208, 208
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 36
    $gp.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
    $gp.AddArc($rect.Right - $r, $rect.Y, $r, $r, 270, 90)
    $gp.AddArc($rect.Right - $r, $rect.Bottom - $r, $r, $r, 0, 90)
    $gp.AddArc($rect.X, $rect.Bottom - $r, $r, $r, 90, 90)
    $gp.CloseFigure()
    $g.FillPath($bg, $gp)
    $bg.Dispose(); $gp.Dispose()
    # White selection-corner brackets
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 18
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawLine($pen, 70,  70,  70,  110); $g.DrawLine($pen, 70,  70,  110, 70)
    $g.DrawLine($pen, 186, 70,  146, 70);  $g.DrawLine($pen, 186, 70,  186, 110)
    $g.DrawLine($pen, 70,  186, 70,  146); $g.DrawLine($pen, 70,  186, 110, 186)
    $g.DrawLine($pen, 186, 186, 186, 146); $g.DrawLine($pen, 186, 186, 146, 186)
    $pen.Dispose(); $g.Dispose()

    # Encode bitmap as PNG, then wrap in a real PNG-embedded .ICO container.
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $ms.Dispose(); $bmp.Dispose()

    $fs = [System.IO.File]::Open($Path, 'Create')
    $bw = New-Object System.IO.BinaryWriter $fs
    try {
        # ICONDIR (6 bytes)
        $bw.Write([uint16]0)             # reserved
        $bw.Write([uint16]1)             # type = icon
        $bw.Write([uint16]1)             # count
        # ICONDIRENTRY (16 bytes)
        $bw.Write([byte]0)               # width  (0 = 256)
        $bw.Write([byte]0)               # height (0 = 256)
        $bw.Write([byte]0)               # color count
        $bw.Write([byte]0)               # reserved
        $bw.Write([uint16]1)             # planes
        $bw.Write([uint16]32)            # bit count
        $bw.Write([uint32]$png.Length)   # bytes in resource
        $bw.Write([uint32]22)            # offset = 6 + 16
        # PNG payload
        $bw.Write($png)
        $bw.Flush()
    } finally {
        $bw.Close(); $fs.Close()
    }
    return $Path
}

function Get-SnipITIconPath {
    $p = Join-Path $script:AppHomeDir 'SnipIT.ico'
    # Always regenerate so upgrades pick up icon changes
    New-SnipITIcon -Path $p | Out-Null
    return $p
}

#endregion

#region First-Run Install ===================================================

function Write-SnipITShortcuts {
    # Idempotent: always (re)write Desktop + Startup shortcuts so the icon
    # path and arguments stay current across upgrades.
    param([Parameter(Mandatory)] [string]$AppDir, [Parameter(Mandatory)] [string]$ScriptTarget)
    $pwshExe      = (Get-Process -Id $PID).Path
    $shortcutArgs = "-NoProfile -WindowStyle Hidden -Sta -File `"$ScriptTarget`""
    $iconPath     = Get-SnipITIconPath
    $iconSource   = "$iconPath,0"
    $shell        = New-Object -ComObject WScript.Shell
    $links        = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SnipIT.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'SnipIT.lnk')
    )
    foreach ($linkPath in $links) {
        # Remove any stale shortcut so the icon cache is forced to refresh.
        if (Test-Path $linkPath) { Remove-Item -Force -ErrorAction SilentlyContinue $linkPath }
        $sc = $shell.CreateShortcut($linkPath)
        $sc.TargetPath       = $pwshExe
        $sc.Arguments        = $shortcutArgs
        $sc.WorkingDirectory = $AppDir
        $sc.IconLocation     = $iconSource
        $sc.WindowStyle      = 7
        $sc.Description      = 'SnipIT - professional snipping tool'
        $sc.Save()
    }
}

function Install-SnipIT {
    $appDir = $script:AppHomeDir
    $marker = Join-Path $appDir '.installed'
    $target = Join-Path $appDir 'SnipIT.ps1'

    $fresh = -not (Test-Path $marker)

    # Copy the running script into snipIT-Home unless we're already running
    # from there (compare normalized absolute paths).
    $runningFull = [System.IO.Path]::GetFullPath($PSCommandPath)
    $targetFull  = [System.IO.Path]::GetFullPath($target)
    if ($runningFull -ne $targetFull) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force
    }

    Write-SnipITShortcuts -AppDir $appDir -ScriptTarget $target

    if ($fresh) { Set-Content -LiteralPath $marker -Value (Get-Date -Format o) }
    return $fresh
}

function Uninstall-SnipIT {
    Remove-Item -Force -ErrorAction SilentlyContinue `
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SnipIT.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'SnipIT.lnk')
    # Remove everything inside snipIT-Home except the directory itself (so we
    # don't wipe the user's project dir if they put the script at its root).
    if (Test-Path $script:AppHomeDir) {
        Get-ChildItem -LiteralPath $script:AppHomeDir -Force |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    # Cached P/Invoke; compile-once so cleanup is guaranteed (no JIT per call, no silent failure).
    if (-not ('SnipIT.Gdi' -as [type])) {
        Add-Type -Namespace SnipIT -Name Gdi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern bool DeleteObject(System.IntPtr hObject);
'@
    }
    $hbmp = [IntPtr]::Zero
    try {
        $hbmp = $Bitmap.GetHbitmap()
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $hbmp, [IntPtr]::Zero,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        return $src
    } finally {
        if ($hbmp -ne [IntPtr]::Zero) { [SnipIT.Gdi]::DeleteObject($hbmp) | Out-Null }
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
        $filterFormat = switch ($dlg.FilterIndex) {
            2 { 'Jpeg' }
            3 { 'Bmp' }
            default { 'Png' }
        }
        $savePath = Resolve-SaveImagePath -Path $dlg.FileName -FilterFormat $filterFormat
        $fmt = switch (Get-ImageFormatNameFromPath $savePath) {
            'Jpeg' { [System.Drawing.Imaging.ImageFormat]::Jpeg }
            'Bmp'  { [System.Drawing.Imaging.ImageFormat]::Bmp  }
            default { [System.Drawing.Imaging.ImageFormat]::Png }
        }
        $Bitmap.Save($savePath, $fmt)
        return $savePath
    }
    return $null
}

function Show-AboutWindow {
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About SnipIT" Width="420" Height="300"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize"
        Background="#FF1B1B1B">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border x:Name="DragHeader" Grid.Row="0" Padding="20,14" Background="#22000000">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE722;" FontFamily="Segoe Fluent Icons" FontSize="22"
                   Foreground="#FF0078D4" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBlock Text="SnipIT" FontSize="18" FontWeight="SemiBold" Foreground="White"
                   VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
    <StackPanel Grid.Row="1" Margin="24,18,24,0">
      <TextBlock Text="Professional snipping tool" FontSize="13" Foreground="#CCFFFFFF" Margin="0,0,0,14"/>
      <TextBlock Text="PowerShell 7.5+ on .NET 9" FontSize="11" Foreground="#88FFFFFF" Margin="0,0,0,16"/>
      <TextBlock Text="Hotkeys" FontSize="12" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,6"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="140"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition/><RowDefinition/><RowDefinition/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Grid.Column="0" Text="Ctrl + Shift + S" FontFamily="Consolas" Foreground="#DDDDDD"/>
        <TextBlock Grid.Row="0" Grid.Column="1" Text="Smart capture"   Foreground="#BBBBBB"/>
        <TextBlock Grid.Row="1" Grid.Column="0" Text="Ctrl + Shift + F" FontFamily="Consolas" Foreground="#DDDDDD"/>
        <TextBlock Grid.Row="1" Grid.Column="1" Text="Full screen"     Foreground="#BBBBBB"/>
        <TextBlock Grid.Row="2" Grid.Column="0" Text="Ctrl + Shift + W" FontFamily="Consolas" Foreground="#DDDDDD"/>
        <TextBlock Grid.Row="2" Grid.Column="1" Text="Active window"   Foreground="#BBBBBB"/>
      </Grid>
    </StackPanel>
    <Border Grid.Row="2" Padding="20,12" Background="#22000000">
      <Button x:Name="OkBtn" HorizontalAlignment="Right" MinWidth="90" Padding="14,6" Content="Close"/>
    </Border>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $w = [System.Windows.Markup.XamlReader]::Load($reader)
    $w.FindName('DragHeader').Add_MouseLeftButtonDown({ $w.DragMove() })
    $w.FindName('OkBtn').Add_Click({ $w.Close() })
    $w.Add_PreviewKeyDown({ if ($_.Key -eq 'Escape') { $w.Close() } })
    $w.ShowDialog() | Out-Null
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
              Background="#CC1F1F1F" CornerRadius="0"
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
            $win.FindName('HintText').Text = ("{0} x {1} px" -f [int]$r.Width, [int]$r.Height)
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
    param(
        [System.Drawing.Bitmap]$Bitmap,
        # Harness hook. When a scriptblock is provided, Show-PreviewWindow
        # still calls ShowDialog() (so its local scope stays alive and the
        # event handlers keep working), but on the Loaded event it invokes
        # $TestAction with a hashtable of handles and then closes the window.
        # The window is positioned off-screen for a headless feel.
        [scriptblock]$TestAction
    )

    $src = Convert-BitmapToBitmapSource $Bitmap

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SnipIT — Preview"
        Width="980" Height="700" MinWidth="640" MinHeight="420"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="CanResize"
        Background="#FF1B1B1B">
  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border x:Name="DragHeader" Grid.Row="0" Padding="16,12" Background="#22000000">
      <DockPanel LastChildFill="False">
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
          <TextBlock Text="&#xE722;" FontFamily="Segoe Fluent Icons"
                     FontSize="20" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock Text="SnipIT" FontSize="16" FontWeight="SemiBold"
                     Foreground="White" VerticalAlignment="Center"/>
          <TextBlock x:Name="DimText" Margin="14,0,0,0" Foreground="#AAFFFFFF"
                     VerticalAlignment="Center" FontSize="12"/>
          <TextBlock x:Name="ZoomText" Margin="14,0,0,0" Foreground="#AAFFFFFF"
                     VerticalAlignment="Center" FontSize="12" Text="100%"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
          <Button x:Name="ZoomOutBtn" Width="32" Height="28" Padding="0" Margin="0,0,4,0" ToolTip="Zoom out (Ctrl + -)">
            <TextBlock Text="&#xE71F;" FontFamily="Segoe Fluent Icons" FontSize="14"/>
          </Button>
          <Button x:Name="FitBtn" Width="40" Height="28" Padding="0" Margin="0,0,4,0" ToolTip="Fit (Ctrl + 0)">
            <TextBlock Text="Fit" FontSize="12"/>
          </Button>
          <Button x:Name="ZoomInBtn" Width="32" Height="28" Padding="0" Margin="0,0,10,0" ToolTip="Zoom in (Ctrl + +)">
            <TextBlock Text="&#xE710;" FontFamily="Segoe Fluent Icons" FontSize="14"/>
          </Button>
          <ToggleButton x:Name="PinBtn" Width="36" Height="28" Padding="0" ToolTip="Always on top">
            <TextBlock Text="&#xE718;" FontFamily="Segoe Fluent Icons" FontSize="14"/>
          </ToggleButton>
        </StackPanel>
      </DockPanel>
    </Border>

    <ScrollViewer Grid.Row="1" x:Name="Scroller" Margin="16,12,16,6"
                  Background="#15000000"
                  HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto">
      <Grid x:Name="ImageHost" HorizontalAlignment="Left" VerticalAlignment="Top">
        <Image x:Name="PreviewImage" Stretch="None"
               HorizontalAlignment="Left" VerticalAlignment="Top"/>
        <Canvas x:Name="HighlightLayer" Background="Transparent"
                HorizontalAlignment="Left" VerticalAlignment="Top"
                IsHitTestVisible="True"/>
      </Grid>
    </ScrollViewer>

    <!-- Annotation toolbar row -->
    <Border Grid.Row="2" Padding="16,8,16,4" Background="#22000000">
      <DockPanel LastChildFill="False">
        <ToggleButton x:Name="HighlightBtn" DockPanel.Dock="Left" MinWidth="108" Margin="0,0,4,0" Padding="10,6" ToolTip="Highlight (filled)">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7E6;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Highlight"/>
          </StackPanel>
        </ToggleButton>
        <ToggleButton x:Name="RectBtn" DockPanel.Dock="Left" MinWidth="82" Margin="0,0,4,0" Padding="10,6" ToolTip="Rectangle outline">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE739;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Rect"/>
          </StackPanel>
        </ToggleButton>
        <ToggleButton x:Name="ArrowBtn" DockPanel.Dock="Left" MinWidth="86" Margin="0,0,4,0" Padding="10,6" ToolTip="Arrow">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE72A;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Arrow"/>
          </StackPanel>
        </ToggleButton>
        <ToggleButton x:Name="TextBtn" DockPanel.Dock="Left" MinWidth="82" Margin="0,0,10,0" Padding="10,6" ToolTip="Text">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE8D2;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Text"/>
          </StackPanel>
        </ToggleButton>
        <StackPanel x:Name="ColorBar" Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center"/>
        <Button x:Name="RedoBtn" DockPanel.Dock="Right" MinWidth="80" Margin="6,0,0,0" Padding="10,6" ToolTip="Redo (Ctrl+Shift+Z)">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7A6;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Redo"/>
          </StackPanel>
        </Button>
        <Button x:Name="UndoBtn" DockPanel.Dock="Right" MinWidth="80" Margin="6,0,0,0" Padding="10,6" ToolTip="Undo (Ctrl+Z)">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7A7;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Undo"/>
          </StackPanel>
        </Button>
        <Button x:Name="ClearBtn" DockPanel.Dock="Right" MinWidth="86" Padding="10,6">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE74D;" FontFamily="Segoe Fluent Icons" Margin="0,0,6,0"/>
            <TextBlock Text="Clear"/>
          </StackPanel>
        </Button>
      </DockPanel>
    </Border>

    <!-- Action button row -->
    <Border Grid.Row="3" Padding="16,4,16,12" Background="#22000000">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
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
    </Border>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $previewImage = $win.FindName('PreviewImage')
    $previewImage.Source = $src
    $win.FindName('DimText').Text = "$($Bitmap.Width) × $($Bitmap.Height) px"

    # Size the window to the bitmap's aspect ratio so the preview area fills
    # with the image instead of showing a tiny letterboxed thumbnail. Clamp to
    # 90% of the primary working area (DIPs — DPI-safe).
    $workW = [System.Windows.SystemParameters]::WorkArea.Width
    $workH = [System.Windows.SystemParameters]::WorkArea.Height
    $chromeW = 40
    $chromeH = 200
    $contentMaxW = ($workW * 0.9) - $chromeW
    $contentMaxH = ($workH * 0.9) - $chromeH
    $fitScale = [math]::Min($contentMaxW / $Bitmap.Width, $contentMaxH / $Bitmap.Height)
    if ($fitScale -gt 1) { $fitScale = 1 }
    $win.Width  = [math]::Max(640, $Bitmap.Width  * $fitScale + $chromeW)
    $win.Height = [math]::Max(420, $Bitmap.Height * $fitScale + $chromeH)

    $win.Add_SourceInitialized({ Set-MicaBackdrop -Window $win })

    # Surface ANY WPF dispatcher exception. Copy to clipboard AND write to
    # %LOCALAPPDATA%\SnipIT\last-error.txt — a plain MessageBox doesn't always
    # let you select text on Win11.
    $win.Dispatcher.add_UnhandledException({
        param($sender, $e)
        $ex = $e.Exception
        $msg = "$($ex.GetType().FullName)`n$($ex.Message)`n`n$($ex.StackTrace)"
        try {
            $logFile = Join-Path $script:AppHomeDir 'last-error.txt'
            Set-Content -LiteralPath $logFile -Value $msg -Encoding UTF8
        } catch {}
        try { [System.Windows.Clipboard]::SetText($msg) } catch {}
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "$msg`n`n--- ALSO COPIED TO CLIPBOARD ---`nFile: $logFile",
                'SnipIT preview error (text on clipboard)', 'OK', 'Error') | Out-Null
        } catch {}
        $e.Handled = $true
    })

    $highlightLayer = $win.FindName('HighlightLayer')
    $highlightBtn   = $win.FindName('HighlightBtn')
    $rectBtn        = $win.FindName('RectBtn')
    $arrowBtn       = $win.FindName('ArrowBtn')
    $textBtn        = $win.FindName('TextBtn')
    $imageHost      = $win.FindName('ImageHost')
    $colorBar       = $win.FindName('ColorBar')
    $scroller       = $win.FindName('Scroller')
    $zoomText       = $win.FindName('ZoomText')

    # Color palette: name → highlight (low alpha) and text (full alpha) variants
    # Each entry: HiR/HiG/HiB used for highlights @ alpha 110, text @ alpha 255.
    $palette = [ordered]@{
        Yellow = @{ R=255; G=222; B=0   }
        Green  = @{ R=70;  G=210; B=110 }
        Pink   = @{ R=255; G=90;  B=180 }
        Blue   = @{ R=80;  G=170; B=255 }
        Orange = @{ R=255; G=150; B=40  }
        Red    = @{ R=255; G=60;  B=60  }
    }

    $state = [pscustomobject]@{
        Annotations  = New-Object System.Collections.ArrayList   # image-pixel coords
        UndoStack    = New-Object System.Collections.Stack
        RedoStack    = New-Object System.Collections.Stack
        ActiveColor  = 'Yellow'
        Drawing      = $false
        DrawingTool  = $null
        AnchorCanvas = $null
        DraftRect    = $null
        EditingText  = $false
        Zoom         = 1.0
        # Pan (Hand) mode: active when no annotation tool is checked.
        Panning      = $false
        PanStartSv   = $null   # mouse position at pan-begin, in Scroller-local coords
        PanOrigX     = 0.0     # Scroller.HorizontalOffset at pan-begin
        PanOrigY     = 0.0     # Scroller.VerticalOffset   at pan-begin
    }

    function script:Get-DisplayedImageBounds {
        # Canvas coordinates are in natural image-pixel space — the
        # LayoutTransform only affects rendering, not local coords. Image
        # and Canvas are both sized to Bitmap.Width x Bitmap.Height.
        [pscustomobject]@{
            X     = 0
            Y     = 0
            W     = $Bitmap.Width
            H     = $Bitmap.Height
            Scale = 1.0
        }
    }

    function script:To-WpfColor {
        param([int]$A, [int]$R, [int]$G, [int]$B)
        [System.Windows.Media.Color]::FromArgb($A, $R, $G, $B)
    }

    function script:Render-Annotations {
        $highlightLayer.Children.Clear()
        $b = Get-DisplayedImageBounds
        if (-not $b) { return }
        foreach ($a in $state.Annotations) {
            $rgb = $palette[$a.Color]
            if (-not $rgb) { continue }
            if ($a.Type -eq 'highlight' -or $a.Type -eq 'rect') {
                $rect = New-Object System.Windows.Shapes.Rectangle
                if ($a.Type -eq 'highlight') {
                    $rect.Fill = New-Object System.Windows.Media.SolidColorBrush(
                        (To-WpfColor 110 $rgb.R $rgb.G $rgb.B))
                }
                $rect.Stroke = New-Object System.Windows.Media.SolidColorBrush(
                    (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
                $rect.StrokeThickness = if ($a.Type -eq 'rect') { 3 } else { 1.5 }
                $rect.Width  = $a.W * $b.Scale
                $rect.Height = $a.H * $b.Scale
                $rect.IsHitTestVisible = $false
                [System.Windows.Controls.Canvas]::SetLeft($rect, $b.X + $a.X * $b.Scale)
                [System.Windows.Controls.Canvas]::SetTop($rect,  $b.Y + $a.Y * $b.Scale)
                [void]$highlightLayer.Children.Add($rect)
            } elseif ($a.Type -eq 'arrow') {
                $line = New-Object System.Windows.Shapes.Line
                $line.X1 = $b.X + $a.X * $b.Scale
                $line.Y1 = $b.Y + $a.Y * $b.Scale
                $line.X2 = $b.X + ($a.X + $a.W) * $b.Scale
                $line.Y2 = $b.Y + ($a.Y + $a.H) * $b.Scale
                $line.Stroke = New-Object System.Windows.Media.SolidColorBrush(
                    (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
                $line.StrokeThickness = 4
                $line.StrokeStartLineCap = 'Round'
                $line.StrokeEndLineCap   = 'Triangle'
                $line.IsHitTestVisible = $false
                [void]$highlightLayer.Children.Add($line)
            } elseif ($a.Type -eq 'text') {
                $tb = New-Object System.Windows.Controls.TextBlock
                $tb.Text       = $a.Text
                $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
                $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
                $tb.FontSize   = $a.FontSize * $b.Scale
                $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                    (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
                $tb.IsHitTestVisible = $false
                [System.Windows.Controls.Canvas]::SetLeft($tb, $b.X + $a.X * $b.Scale)
                [System.Windows.Controls.Canvas]::SetTop($tb,  $b.Y + $a.Y * $b.Scale)
                [void]$highlightLayer.Children.Add($tb)
            }
        }
    }

    function script:Trim-SnipStack {
        # Cap a Stack<T> to its $Max most recent entries (oldest drop off the bottom).
        param($Stack, [int]$Max = $script:UndoStackMaxDepth)
        if ($Stack.Count -le $Max) { return }
        $keep = Get-TrimmedRecent -Items $Stack.ToArray() -MaxDepth $Max
        $Stack.Clear()
        for ($i = $keep.Count - 1; $i -ge 0; $i--) { [void]$Stack.Push($keep[$i]) }
    }

    function script:Snapshot-State {
        # Deep-copy current annotations into undo stack, clear redo
        $copy = New-Object System.Collections.ArrayList
        foreach ($a in $state.Annotations) {
            [void]$copy.Add([pscustomobject]@{
                Type=$a.Type; Color=$a.Color
                X=$a.X; Y=$a.Y; W=$a.W; H=$a.H
                Text=$a.Text; FontSize=$a.FontSize
            })
        }
        $state.UndoStack.Push($copy)
        $state.RedoStack.Clear()
        Trim-SnipStack $state.UndoStack
    }

    function script:Restore-State {
        param($snapshot)
        $state.Annotations.Clear()
        foreach ($a in $snapshot) {
            [void]$state.Annotations.Add([pscustomobject]@{
                Type=$a.Type; Color=$a.Color
                X=$a.X; Y=$a.Y; W=$a.W; H=$a.H
                Text=$a.Text; FontSize=$a.FontSize
            })
        }
        Render-Annotations
    }

    function script:Do-Undo {
        if ($state.UndoStack.Count -eq 0) { return }
        $current = New-Object System.Collections.ArrayList
        foreach ($a in $state.Annotations) {
            [void]$current.Add([pscustomobject]@{
                Type=$a.Type; Color=$a.Color
                X=$a.X; Y=$a.Y; W=$a.W; H=$a.H
                Text=$a.Text; FontSize=$a.FontSize
            })
        }
        $state.RedoStack.Push($current)
        Trim-SnipStack $state.RedoStack
        $prev = $state.UndoStack.Pop()
        Restore-State $prev
    }

    function script:Do-Redo {
        if ($state.RedoStack.Count -eq 0) { return }
        $current = New-Object System.Collections.ArrayList
        foreach ($a in $state.Annotations) {
            [void]$current.Add([pscustomobject]@{
                Type=$a.Type; Color=$a.Color
                X=$a.X; Y=$a.Y; W=$a.W; H=$a.H
                Text=$a.Text; FontSize=$a.FontSize
            })
        }
        $state.UndoStack.Push($current)
        Trim-SnipStack $state.UndoStack
        $next = $state.RedoStack.Pop()
        Restore-State $next
    }

    # Named color picker. Tests and the real swatch click handler both call
    # this. Also live-updates the foreground of any text box that is
    # currently being edited, so the user sees the color change immediately.
    $pickColor = {
        param([string]$Name)
        if (-not $palette.Contains($Name)) { return }
        $state.ActiveColor = $Name
        if ($state.EditingText) {
            foreach ($child in $highlightLayer.Children) {
                if ($child -is [System.Windows.Controls.TextBox]) {
                    $rgbL = $palette[$Name]
                    $child.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                        (To-WpfColor 255 $rgbL.R $rgbL.G $rgbL.B))
                    $child.BorderBrush = New-Object System.Windows.Media.SolidColorBrush(
                        (To-WpfColor 200 $rgbL.R $rgbL.G $rgbL.B))
                    break
                }
            }
        }
        Build-ColorBar
    }.GetNewClosure()

    # Build color swatches
    function script:Build-ColorBar {
        $colorBar.Children.Clear()
        foreach ($name in $palette.Keys) {
            $rgb = $palette[$name]
            $sw = New-Object System.Windows.Controls.Border
            $sw.Width = 26; $sw.Height = 26
            $sw.Margin = New-Object System.Windows.Thickness 3, 0, 3, 0
            $sw.CornerRadius = New-Object System.Windows.CornerRadius 0
            $sw.Background = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
            $sw.BorderBrush = New-Object System.Windows.Media.SolidColorBrush(
                ([System.Windows.Media.Colors]::White))
            $sw.BorderThickness = if ($state.ActiveColor -eq $name) {
                New-Object System.Windows.Thickness 2
            } else {
                New-Object System.Windows.Thickness 0
            }
            $sw.Cursor = [System.Windows.Input.Cursors]::Hand
            # Non-focusable so clicking a swatch while a text box is open
            # doesn't steal keyboard focus (which would fire LostFocus →
            # commit the text in the OLD color before we can update it).
            $sw.Focusable = $false
            $sw.ToolTip = $name
            $sw.Tag = $name
            $sw.Add_MouseLeftButtonDown({ & $pickColor $this.Tag }.GetNewClosure())
            [void]$colorBar.Children.Add($sw)
        }
    }
    Build-ColorBar

    # Tool toggle interlock — at most one tool active. No tool = pan (Hand) mode.
    $tools = @($highlightBtn, $rectBtn, $arrowBtn, $textBtn)
    foreach ($t in $tools) {
        $t.Add_Checked({
            $me = $this
            foreach ($other in $tools) { if ($other -ne $me) { $other.IsChecked = $false } }
        }.GetNewClosure())
    }
    # No tool checked by default → pan mode is active.
    # Note: $scroller is resolved later (XAML lookup). We bind the cursor
    # refresh to tool-button state changes so it stays in sync as the
    # user toggles tools on/off.
    $updateCursor = {
        $anyTool = $highlightBtn.IsChecked -or $rectBtn.IsChecked -or
                   $arrowBtn.IsChecked     -or $textBtn.IsChecked
        $highlightLayer.Cursor = if ($anyTool) {
            [System.Windows.Input.Cursors]::Cross
        } else {
            [System.Windows.Input.Cursors]::Hand
        }
    }.GetNewClosure()
    foreach ($t in $tools) {
        $t.Add_Checked($updateCursor)
        $t.Add_Unchecked($updateCursor)
    }
    & $updateCursor   # initial: Hand (no tool)

    # ---- Named core helpers (closures so tests can drive them directly) ----

    $beginPan = {
        param([System.Windows.Point]$SvPoint)
        $state.Panning    = $true
        $state.PanStartSv = $SvPoint
        $state.PanOrigX   = $scroller.HorizontalOffset
        $state.PanOrigY   = $scroller.VerticalOffset
        $highlightLayer.Cursor = [System.Windows.Input.Cursors]::SizeAll
        try { $highlightLayer.CaptureMouse() | Out-Null } catch {}
    }.GetNewClosure()

    $updatePan = {
        param([System.Windows.Point]$SvPoint)
        if (-not $state.Panning) { return }
        $dx = $SvPoint.X - $state.PanStartSv.X
        $dy = $SvPoint.Y - $state.PanStartSv.Y
        $scroller.ScrollToHorizontalOffset($state.PanOrigX - $dx)
        $scroller.ScrollToVerticalOffset(  $state.PanOrigY - $dy)
    }.GetNewClosure()

    $endPan = {
        if (-not $state.Panning) { return }
        $state.Panning = $false
        try { $highlightLayer.ReleaseMouseCapture() } catch {}
        $highlightLayer.Cursor = [System.Windows.Input.Cursors]::Hand
    }.GetNewClosure()

    $beginDraw = {
        param([string]$Tool, [System.Windows.Point]$P)
        $state.Drawing     = $true
        $state.DrawingTool = $Tool
        $state.AnchorCanvas = $P
        $rgb = $palette[$state.ActiveColor]
        if ($Tool -eq 'arrow') {
            $line = New-Object System.Windows.Shapes.Line
            $line.X1 = $P.X; $line.Y1 = $P.Y; $line.X2 = $P.X; $line.Y2 = $P.Y
            $line.Stroke = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
            $line.StrokeThickness = 4
            $line.StrokeStartLineCap = 'Round'
            $line.StrokeEndLineCap   = 'Triangle'
            $line.IsHitTestVisible = $false
            [void]$highlightLayer.Children.Add($line)
            $state.DraftRect = $line
        } else {
            $shape = New-Object System.Windows.Shapes.Rectangle
            if ($Tool -eq 'highlight') {
                $shape.Fill = New-Object System.Windows.Media.SolidColorBrush(
                    (To-WpfColor 110 $rgb.R $rgb.G $rgb.B))
            }
            $shape.Stroke = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor 220 $rgb.R $rgb.G $rgb.B))
            $shape.StrokeThickness = if ($Tool -eq 'rect') { 3 } else { 1.5 }
            $shape.IsHitTestVisible = $false
            [System.Windows.Controls.Canvas]::SetLeft($shape, $P.X)
            [System.Windows.Controls.Canvas]::SetTop($shape,  $P.Y)
            $shape.Width = 0; $shape.Height = 0
            [void]$highlightLayer.Children.Add($shape)
            $state.DraftRect = $shape
        }
        try { $highlightLayer.CaptureMouse() | Out-Null } catch {}
    }.GetNewClosure()

    $updateDraw = {
        param([System.Windows.Point]$P)
        if (-not $state.Drawing -or -not $state.DraftRect) { return }
        if ($state.DrawingTool -eq 'arrow') {
            $state.DraftRect.X2 = $P.X
            $state.DraftRect.Y2 = $P.Y
        } else {
            $r = Get-DragRectangle -AnchorX $state.AnchorCanvas.X -AnchorY $state.AnchorCanvas.Y `
                -CurrentX $P.X -CurrentY $P.Y
            [System.Windows.Controls.Canvas]::SetLeft($state.DraftRect, $r.X)
            [System.Windows.Controls.Canvas]::SetTop($state.DraftRect,  $r.Y)
            $state.DraftRect.Width  = $r.Width
            $state.DraftRect.Height = $r.Height
        }
    }.GetNewClosure()

    $openText = {
        param([System.Windows.Point]$P)
        $b = Get-DisplayedImageBounds
        if (-not $b) { return $null }

        # Locals the inner $commit closure needs to capture. PS's chained
        # GetNewClosure() does not propagate outer-closure captures into a
        # nested .GetNewClosure(), so we must materialize them as real
        # locals here before creating $commit.
        $stateL    = $state
        $winL      = $win
        $hlLayerL  = $highlightLayer
        $textBtnL  = $textBtn
        $paletteL  = $palette
        $bL        = $b

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Background = New-Object System.Windows.Media.SolidColorBrush(
            ([System.Windows.Media.Color]::FromArgb(180, 30, 30, 30)))
        $rgb = $palette[$state.ActiveColor]
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
        $tb.BorderBrush = New-Object System.Windows.Media.SolidColorBrush(
            (To-WpfColor 200 $rgb.R $rgb.G $rgb.B))
        $tb.BorderThickness = New-Object System.Windows.Thickness 1
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
        $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tb.FontSize   = 18
        $tb.Padding    = New-Object System.Windows.Thickness 4, 1, 4, 1
        $tb.MinWidth   = 80
        [System.Windows.Controls.Canvas]::SetLeft($tb, $P.X)
        [System.Windows.Controls.Canvas]::SetTop($tb,  $P.Y)
        [void]$highlightLayer.Children.Add($tb)
        $state.EditingText = $true

        # Reentrance guard: ClearFocus / Children.Remove can synchronously
        # fire LostFocus on the TextBox and recurse back into $commit. Using
        # a hashtable field so the mutation propagates across invocations.
        $commitGuard = @{ Done = $false }
        $commit = {
            if ($commitGuard.Done) { return }
            $commitGuard.Done = $true
            $stateL.EditingText = $false
            $text = $tb.Text
            try { [System.Windows.Input.Keyboard]::ClearFocus() } catch {}
            try { [System.Windows.Input.Mouse]::Capture($null) } catch {}
            try { $winL.Focus() | Out-Null } catch {}
            [void]$hlLayerL.Children.Remove($tb)
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            $imgX = [int][math]::Round(($P.X - $bL.X) / $bL.Scale)
            $imgY = [int][math]::Round(($P.Y - $bL.Y) / $bL.Scale)
            $fontSize = [int][math]::Round(18 / $bL.Scale)
            Snapshot-State
            [void]$stateL.Annotations.Add([pscustomobject]@{
                Type='text'; Color=$stateL.ActiveColor
                X=$imgX; Y=$imgY; W=0; H=0
                Text=$text; FontSize=$fontSize
            })
            Render-Annotations
        }.GetNewClosure()

        $tb.Add_KeyDown({
            if ($_.Key -eq 'Enter') {
                & $commit
                $textBtnL.IsChecked = $false
                $_.Handled = $true
            }
            elseif ($_.Key -eq 'Escape') {
                $stateL.EditingText = $false
                [void]$hlLayerL.Children.Remove($tb)
                $_.Handled = $true
            }
        }.GetNewClosure())
        $tb.Add_LostFocus({ & $commit }.GetNewClosure())
        try { $tb.Focus() | Out-Null } catch {}
        # Tests and external callers can drive commit via $tb.Tag
        $tb.Tag = $commit
        return $tb
    }.GetNewClosure()

    $finishDraw = {
        if (-not $state.Drawing) { return }
        $state.Drawing = $false
        try { $highlightLayer.ReleaseMouseCapture() } catch {}
        $b = Get-DisplayedImageBounds
        if (-not $b) {
            if ($state.DraftRect) { [void]$highlightLayer.Children.Remove($state.DraftRect) }
            $state.DraftRect = $null; return
        }
        if ($state.DrawingTool -eq 'arrow') {
            $line = $state.DraftRect
            $dx = $line.X2 - $line.X1; $dy = $line.Y2 - $line.Y1
            if ([math]::Sqrt($dx * $dx + $dy * $dy) -lt 6) {
                [void]$highlightLayer.Children.Remove($line); $state.DraftRect = $null; return
            }
            $x1 = [int][math]::Round(($line.X1 - $b.X) / $b.Scale)
            $y1 = [int][math]::Round(($line.Y1 - $b.Y) / $b.Scale)
            $x2 = [int][math]::Round(($line.X2 - $b.X) / $b.Scale)
            $y2 = [int][math]::Round(($line.Y2 - $b.Y) / $b.Scale)
            Snapshot-State
            [void]$state.Annotations.Add([pscustomobject]@{
                Type='arrow'; Color=$state.ActiveColor
                X=$x1; Y=$y1; W=($x2 - $x1); H=($y2 - $y1)
                Text=$null; FontSize=0
            })
            [void]$highlightLayer.Children.Remove($line)
            $state.DraftRect = $null
            Render-Annotations
            return
        }
        if ($state.DraftRect.Width -lt 3 -or $state.DraftRect.Height -lt 3) {
            [void]$highlightLayer.Children.Remove($state.DraftRect)
            $state.DraftRect = $null; return
        }
        $canvasX = [System.Windows.Controls.Canvas]::GetLeft($state.DraftRect)
        $canvasY = [System.Windows.Controls.Canvas]::GetTop($state.DraftRect)
        $px = [int][math]::Round(($canvasX - $b.X) / $b.Scale)
        $py = [int][math]::Round(($canvasY - $b.Y) / $b.Scale)
        $pw = [int][math]::Round($state.DraftRect.Width  / $b.Scale)
        $ph = [int][math]::Round($state.DraftRect.Height / $b.Scale)
        $px = [math]::Max(0, [math]::Min($Bitmap.Width  - 1, $px))
        $py = [math]::Max(0, [math]::Min($Bitmap.Height - 1, $py))
        $pw = [math]::Max(1, [math]::Min($Bitmap.Width  - $px, $pw))
        $ph = [math]::Max(1, [math]::Min($Bitmap.Height - $py, $ph))
        Snapshot-State
        [void]$state.Annotations.Add([pscustomobject]@{
            Type=$state.DrawingTool; Color=$state.ActiveColor
            X=$px; Y=$py; W=$pw; H=$ph
            Text=$null; FontSize=0
        })
        [void]$highlightLayer.Children.Remove($state.DraftRect)
        $state.DraftRect = $null
        Render-Annotations
    }.GetNewClosure()

    # ---- Mouse interactions on the highlight layer ----
    # Named dispatcher for MouseLeftButtonDown so tests can drive it with
    # synthetic points. Event handler below is a thin wrapper.
    $handleMouseDown = {
        param(
            [System.Windows.Point]$HlPoint,
            [System.Windows.Point]$SvPoint
        )
        if ($state.EditingText) { return }

        $anyTool = $highlightBtn.IsChecked -or $rectBtn.IsChecked -or
                   $arrowBtn.IsChecked     -or $textBtn.IsChecked
        if (-not $anyTool) {
            & $beginPan $SvPoint
            return
        }

        $b = Get-DisplayedImageBounds; if (-not $b) { return }
        $p = $HlPoint
        if ($p.X -lt $b.X -or $p.Y -lt $b.Y -or
            $p.X -gt $b.X + $b.W -or $p.Y -gt $b.Y + $b.H) { return }

        $tool = $null
        if     ($highlightBtn.IsChecked) { $tool = 'highlight' }
        elseif ($rectBtn.IsChecked)      { $tool = 'rect' }
        elseif ($arrowBtn.IsChecked)     { $tool = 'arrow' }

        if ($tool) {
            & $beginDraw $tool $p
        }
        elseif ($textBtn.IsChecked) {
            & $openText $p
        }
    }.GetNewClosure()

    $highlightLayer.Add_MouseLeftButtonDown({
        & $handleMouseDown ($_.GetPosition($highlightLayer)) ($_.GetPosition($scroller))
        if ($state.Panning -or $state.Drawing -or $state.EditingText) {
            $_.Handled = $true
        }
    }.GetNewClosure())

    $highlightLayer.Add_MouseMove({
        if ($state.Panning) { & $updatePan ($_.GetPosition($scroller)); return }
        if (-not $state.Drawing) { return }
        & $updateDraw ($_.GetPosition($highlightLayer))
    }.GetNewClosure())

    $highlightLayer.Add_MouseLeftButtonUp({
        if ($state.Panning) { & $endPan; return }
        if (-not $state.Drawing) { return }
        & $finishDraw
    }.GetNewClosure())

    # Re-render on resize (ImageHost growing/shrinking with zoom)
    $imageHost.Add_SizeChanged({ Render-Annotations })

    # Hit-test helper: returns the topmost annotation index under a canvas point, or -1
    function script:Find-AnnotationAt {
        param([double]$CanvasX, [double]$CanvasY)
        $bb = Get-DisplayedImageBounds
        if (-not $bb) { return -1 }
        for ($i = $state.Annotations.Count - 1; $i -ge 0; $i--) {
            $a = $state.Annotations[$i]
            if ($a.Type -eq 'highlight' -or $a.Type -eq 'rect' -or $a.Type -eq 'arrow') {
                # For arrow, W/H can be negative; normalize.
                $minX = $a.X; $maxX = $a.X + $a.W
                $minY = $a.Y; $maxY = $a.Y + $a.H
                if ($minX -gt $maxX) { $t = $minX; $minX = $maxX; $maxX = $t }
                if ($minY -gt $maxY) { $t = $minY; $minY = $maxY; $maxY = $t }
                # Small padding for thin arrows
                if ($a.Type -eq 'arrow') { $minX -= 6; $maxX += 6; $minY -= 6; $maxY += 6 }
                $x1 = $bb.X + $minX * $bb.Scale
                $y1 = $bb.Y + $minY * $bb.Scale
                $x2 = $bb.X + $maxX * $bb.Scale
                $y2 = $bb.Y + $maxY * $bb.Scale
            } else {
                # Rough text bounding box. FontSize is in image pixels.
                $approxW = [math]::Max(20, $a.Text.Length * $a.FontSize * 0.6)
                $approxH = $a.FontSize * 1.3
                $x1 = $bb.X + $a.X * $bb.Scale
                $y1 = $bb.Y + $a.Y * $bb.Scale
                $x2 = $x1 + $approxW * $bb.Scale
                $y2 = $y1 + $approxH * $bb.Scale
            }
            if ($CanvasX -ge $x1 -and $CanvasX -le $x2 -and
                $CanvasY -ge $y1 -and $CanvasY -le $y2) { return $i }
        }
        return -1
    }

    # Right-click an existing annotation → color/delete context menu
    $highlightLayer.Add_MouseRightButtonDown({
        if ($state.EditingText) { return }
        $p = $_.GetPosition($highlightLayer)
        $idx = Find-AnnotationAt -CanvasX $p.X -CanvasY $p.Y
        if ($idx -lt 0) { return }
        $_.Handled = $true

        # Local aliases so menu-item closures can find them
        $stateL   = $state
        $paletteL = $palette
        $idxL     = $idx

        $menu = New-Object System.Windows.Controls.ContextMenu
        foreach ($name in $paletteL.Keys) {
            $rgb = $paletteL[$name]
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = $name
            $swatch = New-Object System.Windows.Shapes.Rectangle
            $swatch.Width = 14; $swatch.Height = 14
            $swatch.Fill = New-Object System.Windows.Media.SolidColorBrush(
                ([System.Windows.Media.Color]::FromArgb(255, $rgb.R, $rgb.G, $rgb.B)))
            $mi.Icon = $swatch
            $nameL = $name
            $mi.Add_Click({
                Snapshot-State
                $stateL.Annotations[$idxL].Color = $nameL
                Render-Annotations
            }.GetNewClosure())
            [void]$menu.Items.Add($mi)
        }
        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
        $delMi = New-Object System.Windows.Controls.MenuItem
        $delMi.Header = 'Delete'
        $delMi.Add_Click({
            Snapshot-State
            $stateL.Annotations.RemoveAt($idxL)
            Render-Annotations
        }.GetNewClosure())
        [void]$menu.Items.Add($delMi)

        $menu.PlacementTarget = $highlightLayer
        $menu.IsOpen = $true
    })

    # Toolbar buttons
    $win.FindName('ClearBtn').Add_Click({
        if ($state.Annotations.Count -eq 0) { return }
        Snapshot-State
        $state.Annotations.Clear()
        Render-Annotations
    })
    $win.FindName('UndoBtn').Add_Click({ Do-Undo })
    $win.FindName('RedoBtn').Add_Click({ Do-Redo })

    # Chromeless: header bar drags the window, but skip if the click landed
    # on a button / togglebutton in the header (otherwise DragMove hijacks the
    # mouse before the button's click release).
    $win.FindName('DragHeader').Add_MouseLeftButtonDown({
        $src = $_.OriginalSource
        $p = $src
        while ($p -and -not ($p -is [System.Windows.Controls.Primitives.ButtonBase])) {
            $p = [System.Windows.Media.VisualTreeHelper]::GetParent($p)
        }
        if ($p -is [System.Windows.Controls.Primitives.ButtonBase]) { return }
        if ($_.ClickCount -eq 2) {
            $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
        } else {
            $win.DragMove()
        }
    })

    # Always-on-top pin
    $pinBtn = $win.FindName('PinBtn')
    $pinBtn.Add_Checked({   $win.Topmost = $true  })
    $pinBtn.Add_Unchecked({ $win.Topmost = $false })

    # Zoom controls. Uses LayoutTransform on ImageHost. The ScaleTransform
    # itself is the single source of truth for the current zoom — reading
    # $layoutScale.ScaleX through a captured object reference is immune to
    # the PS-scope / closure quirks that broke prior attempts using
    # $script: or $Global: variables inside WPF event handlers.
    # ($scroller and $zoomText already resolved near the top of this function)

    $highlightLayer.Width  = $Bitmap.Width
    $highlightLayer.Height = $Bitmap.Height

    $layoutScale = New-Object System.Windows.Media.ScaleTransform 1, 1
    $imageHost.LayoutTransform = $layoutScale

    $setZoom = {
        param([double]$s)
        # NB: literal doubles required. [math]::Min(10, 1.25) resolves to
        # the Min(int,int) overload in PowerShell and truncates to 1.
        $s = [math]::Max(0.05, [math]::Min(10.0, $s))
        $layoutScale.ScaleX = $s
        $layoutScale.ScaleY = $s
        $imageHost.InvalidateMeasure()
        $imageHost.UpdateLayout()
        try { $scroller.InvalidateScrollInfo() } catch {}
        if ($zoomText) { $zoomText.Text = '{0:P0}' -f $s }
    }.GetNewClosure()

    $zoomBy = {
        param([double]$factor)
        & $setZoom ($layoutScale.ScaleX * $factor)
    }.GetNewClosure()

    $fitToViewport = {
        if (-not $scroller -or $scroller.ViewportWidth -le 0) { return }
        $fw = $scroller.ViewportWidth  / $Bitmap.Width
        $fh = $scroller.ViewportHeight / $Bitmap.Height
        $fit = [math]::Min($fw, $fh)
        if ($fit -gt 1) { $fit = 1 }
        & $setZoom $fit
    }.GetNewClosure()

    $win.Add_Loaded({ & $fitToViewport }.GetNewClosure())

    $win.FindName('ZoomInBtn').Add_Click({  & $zoomBy 1.25       }.GetNewClosure())
    $win.FindName('ZoomOutBtn').Add_Click({ & $zoomBy (1 / 1.25) }.GetNewClosure())
    $win.FindName('FitBtn').Add_Click({     & $fitToViewport     }.GetNewClosure())

    $win.Add_PreviewMouseWheel({
        if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
            $factor = if ($_.Delta -gt 0) { 1.25 } else { 1 / 1.25 }
            & $zoomBy $factor
            $_.Handled = $true
        }
    }.GetNewClosure())

    # Keyboard shortcuts
    $fireClick = {
        param($btnName)
        $b = $win.FindName($btnName)
        if ($b) {
            $e = New-Object System.Windows.RoutedEventArgs(
                [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            $b.RaiseEvent($e)
        }
    }.GetNewClosure()

    $win.Add_PreviewKeyDown({
        if ($state.EditingText) { return }
        $ctrl  = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift)   -ne 0
        if ($ctrl -and $_.Key -eq 'Z') {
            if ($shift) { Do-Redo } else { Do-Undo }
            $_.Handled = $true
        } elseif ($ctrl -and $_.Key -eq 'C') { & $fireClick 'CopyBtn';  $_.Handled = $true }
        elseif   ($ctrl -and $_.Key -eq 'S') { & $fireClick 'SaveBtn';  $_.Handled = $true }
        elseif   ($ctrl -and $_.Key -eq 'N') { & $fireClick 'NewBtn';   $_.Handled = $true }
        elseif   ($ctrl -and $_.Key -eq 'D0') { & $setZoom 1.0;       $_.Handled = $true }
        elseif   ($ctrl -and ($_.Key -eq 'OemPlus'  -or $_.Key -eq 'Add'))      { & $zoomBy 1.25;       $_.Handled = $true }
        elseif   ($ctrl -and ($_.Key -eq 'OemMinus' -or $_.Key -eq 'Subtract')) { & $zoomBy (1 / 1.25); $_.Handled = $true }
        elseif   ($_.Key -eq 'Escape')       { & $fireClick 'CloseBtn'; $_.Handled = $true }
    })

    function script:Get-FlattenedBitmap {
        if ($state.Annotations.Count -eq 0) { return $Bitmap }
        $flat = New-Object System.Drawing.Bitmap $Bitmap.Width, $Bitmap.Height,
            ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($flat)
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.DrawImage($Bitmap, 0, 0, $Bitmap.Width, $Bitmap.Height)
        foreach ($a in $state.Annotations) {
            $rgb = $palette[$a.Color]
            if (-not $rgb) { continue }
            if ($a.Type -eq 'highlight') {
                $brush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb(110, $rgb.R, $rgb.G, $rgb.B))
                $g.FillRectangle($brush, [int]$a.X, [int]$a.Y, [int]$a.W, [int]$a.H)
                $brush.Dispose()
            } elseif ($a.Type -eq 'rect') {
                $pen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::FromArgb(255, $rgb.R, $rgb.G, $rgb.B), 4)
                $g.DrawRectangle($pen, [int]$a.X, [int]$a.Y, [int]$a.W, [int]$a.H)
                $pen.Dispose()
            } elseif ($a.Type -eq 'arrow') {
                $pen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::FromArgb(255, $rgb.R, $rgb.G, $rgb.B), 5)
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor
                $g.DrawLine($pen, [int]$a.X, [int]$a.Y, [int]($a.X + $a.W), [int]($a.Y + $a.H))
                $pen.Dispose()
            } elseif ($a.Type -eq 'text') {
                $brush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb(255, $rgb.R, $rgb.G, $rgb.B))
                $font = New-Object System.Drawing.Font 'Segoe UI', $a.FontSize,
                    ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
                $g.DrawString($a.Text, $font, $brush, [single]$a.X, [single]$a.Y)
                $font.Dispose(); $brush.Dispose()
            }
        }
        $g.Dispose()
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
    $script:CurrentPreviewWindow = $win
    $win.Add_Closed({
        $script:CurrentPreviewWindow = $null
        # Release the backing Bitmap — the frozen BitmapSource ($src) no longer depends on it.
        try { if ($Bitmap) { $Bitmap.Dispose() } } catch { Write-SnipDiag "Bitmap dispose failed" $_ }
    }.GetNewClosure())

    if ($TestAction) {
        $kit = @{
            Win            = $win
            State          = $state
            LayoutScale    = $layoutScale
            Scroller       = $scroller
            ImageHost      = $imageHost
            HighlightLayer = $highlightLayer
            ZoomText       = $zoomText
            HighlightBtn   = $highlightBtn
            RectBtn        = $rectBtn
            ArrowBtn       = $arrowBtn
            TextBtn        = $textBtn
            Bitmap         = $Bitmap
            Palette        = $palette
            SetZoom        = $setZoom
            ZoomBy         = $zoomBy
            FitToViewport  = $fitToViewport
            BeginPan       = $beginPan
            UpdatePan      = $updatePan
            EndPan         = $endPan
            BeginDraw      = $beginDraw
            UpdateDraw     = $updateDraw
            FinishDraw     = $finishDraw
            OpenText       = $openText
            HandleMouseDown = $handleMouseDown
            PickColor       = $pickColor
            Render         = ${function:script:Render-Annotations}
            Snapshot       = ${function:script:Snapshot-State}
            Undo           = ${function:script:Do-Undo}
            Redo           = ${function:script:Do-Redo}
            FindAt         = ${function:script:Find-AnnotationAt}
            Flatten        = ${function:script:Get-FlattenedBitmap}
        }
        $script:pwTestError = $null
        # Hide off-screen so the window is effectively headless.
        $win.WindowStartupLocation = 'Manual'
        $win.Left = -5000; $win.Top = -5000
        $win.Add_Loaded({
            try { & $TestAction $kit }
            catch { $script:pwTestError = $_ }
            finally { try { $win.Close() } catch {} }
        }.GetNewClosure())
        $win.ShowDialog() | Out-Null
        if ($script:pwTestError) { throw $script:pwTestError }
        return
    }

    $win.ShowDialog() | Out-Null
    $script:CurrentPreviewWindow = $null
    return $script:RequestNewSnip
}

#endregion

#region Capture Orchestration ===============================================

# When a hotkey fires while a preview window is open, the handler sets
# $script:PendingCaptureType and closes the preview. After ShowDialog returns,
# the capture loop checks the pending type and chains into the next capture.
$script:PendingCaptureType   = $null   # 1 = smart, 2 = full, 3 = window
$script:CurrentPreviewWindow = $null

function Invoke-PendingCapture {
    $next = $script:PendingCaptureType
    $script:PendingCaptureType = $null
    switch ($next) {
        1 { Invoke-SmartCapture }
        2 { Invoke-FullScreenCapture }
        3 { Invoke-WindowCapture }
    }
}

function Invoke-SmartCapture {
    do {
        $bmp = Show-SmartOverlay
        if (-not $bmp) { break }
        $again = Show-PreviewWindow -Bitmap $bmp
        $bmp.Dispose()
        if ($script:PendingCaptureType) { Invoke-PendingCapture; return }
    } while ($again)
}

function Invoke-FullScreenCapture {
    $vs = Get-VirtualScreenBounds
    $bmp = New-ScreenBitmap -X $vs.X -Y $vs.Y -Width $vs.Width -Height $vs.Height
    do {
        $again = Show-PreviewWindow -Bitmap $bmp
        if ($script:PendingCaptureType) {
            $bmp.Dispose()
            Invoke-PendingCapture; return
        }
    } while ($again)
    $bmp.Dispose()
}

function Invoke-WindowCapture {
    # Capture the currently foreground window. If that's one of SnipIT's own
    # windows (tray balloon clicked, etc.), fall back to the virtual desktop.
    $hwnd = [Native]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $r = New-Object Native+RECT
    $ok = ([Native]::DwmGetWindowAttribute($hwnd, [Native]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$r, 16) -eq 0)
    if (-not $ok) { [Native]::GetWindowRect($hwnd, [ref]$r) | Out-Null }
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { return }
    $bmp = New-ScreenBitmap -X $r.Left -Y $r.Top -Width $w -Height $h
    do {
        $again = Show-PreviewWindow -Bitmap $bmp
        if ($script:PendingCaptureType) {
            $bmp.Dispose()
            Invoke-PendingCapture; return
        }
    } while ($again)
    $bmp.Dispose()
}

function Start-DelayedCapture {
    param([int]$Seconds, [ValidateSet('smart','full','window')] [string]$Type)
    $plural = if ($Seconds -ne 1) { 's' } else { '' }
    try {
        $script:tray.BalloonTipTitle = 'SnipIT'
        $script:tray.BalloonTipText  = "Capturing ($Type) in $Seconds second$plural..."
        $script:tray.ShowBalloonTip(1500)
    } catch {}
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]($Seconds * 1000)
    $timer.Add_Tick({
        $timer.Stop(); $timer.Dispose()
        switch ($Type) {
            'smart'  { Invoke-SmartCapture }
            'full'   { Invoke-FullScreenCapture }
            'window' { Invoke-WindowCapture }
        }
    }.GetNewClosure())
    $timer.Start()
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
  <Border CornerRadius="0" Background="#E61F1F1F" BorderBrush="#330078D4" BorderThickness="1">
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

# Test mode: harness dot-sources this script to call Show-PreviewWindow
# directly. Skip the real tray, hotkey registration, and main loop.
if ($env:SNIPIT_TEST_MODE) { return }

# Hidden message-only window for hotkeys
$hotkeyForm = New-Object System.Windows.Forms.Form
$hotkeyForm.FormBorderStyle = 'FixedToolWindow'
$hotkeyForm.ShowInTaskbar = $false
$hotkeyForm.Opacity = 0
$hotkeyForm.Size = New-Object System.Drawing.Size 1, 1
$hotkeyForm.StartPosition = 'Manual'
$hotkeyForm.Location = New-Object System.Drawing.Point -2000, -2000

$MOD_CONTROL = 0x2; $MOD_SHIFT = 0x4
$HOTKEY_SMART  = 1
$HOTKEY_FULL   = 2
$HOTKEY_WINDOW = 3
$VK_S = 0x53
$VK_F = 0x46
$VK_W = 0x57
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
    public Action<int> Callback;
    private Control sync;
    public HotkeyWindow(Form host) {
        sync = host;
        AssignHandle(host.Handle);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Callback != null && sync != null && sync.IsHandleCreated) {
            int id = (int)m.WParam;
            Action<int> cb = Callback;
            sync.BeginInvoke(new Action(delegate { cb(id); }));
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
$hkWin.Callback = [Action[int]]{
    param([int]$id)
    try {
        # If a preview is already up, mark the new capture as pending and
        # close the preview. Its ShowDialog returns and the orchestration loop
        # in Invoke-* picks up $script:PendingCaptureType to chain.
        if ($script:CurrentPreviewWindow) {
            $script:PendingCaptureType = $id
            $script:CurrentPreviewWindow.Close()
            return
        }
        switch ($id) {
            1 { Invoke-SmartCapture }
            2 { Invoke-FullScreenCapture }
            3 { Invoke-WindowCapture }
        }
    } catch {
        try {
            $script:tray.BalloonTipTitle = 'SnipIT error'
            $script:tray.BalloonTipText  = $_.Exception.Message
            $script:tray.ShowBalloonTip(3000)
        } catch {}
    }
}

$hotkeyErrors = @()
if (-not [Native]::RegisterHotKey($hotkeyForm.Handle, $HOTKEY_SMART,  ($MOD_CONTROL -bor $MOD_SHIFT), $VK_S)) {
    $hotkeyErrors += 'Ctrl+Shift+S'
}
if (-not [Native]::RegisterHotKey($hotkeyForm.Handle, $HOTKEY_FULL,   ($MOD_CONTROL -bor $MOD_SHIFT), $VK_F)) {
    $hotkeyErrors += 'Ctrl+Shift+F'
}
if (-not [Native]::RegisterHotKey($hotkeyForm.Handle, $HOTKEY_WINDOW, ($MOD_CONTROL -bor $MOD_SHIFT), $VK_W)) {
    $hotkeyErrors += 'Ctrl+Shift+W'
}

# Tray icon
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$tray = $script:tray
$tray.Visible = $true
$tray.Text = 'SnipIT — Ctrl+Shift+S to snip'
try {
    $tray.Icon = New-Object System.Drawing.Icon (Get-SnipITIconPath)
} catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Smart capture (Ctrl+Shift+S)',     $null, { Invoke-SmartCapture })
[void]$menu.Items.Add('Full screen (Ctrl+Shift+F)',       $null, { Invoke-FullScreenCapture })
[void]$menu.Items.Add('Active window (Ctrl+Shift+W)',     $null, { Invoke-WindowCapture })
[void]$menu.Items.Add('-')
$delayMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Delay capture'
[void]$delayMenu.DropDownItems.Add('Smart in 3 seconds',  $null, { Start-DelayedCapture 3  'smart'  })
[void]$delayMenu.DropDownItems.Add('Smart in 5 seconds',  $null, { Start-DelayedCapture 5  'smart'  })
[void]$delayMenu.DropDownItems.Add('Smart in 10 seconds', $null, { Start-DelayedCapture 10 'smart'  })
[void]$delayMenu.DropDownItems.Add('-')
[void]$delayMenu.DropDownItems.Add('Full in 3 seconds',   $null, { Start-DelayedCapture 3  'full'   })
[void]$delayMenu.DropDownItems.Add('Window in 3 seconds', $null, { Start-DelayedCapture 3  'window' })
[void]$menu.Items.Add($delayMenu)
[void]$menu.Items.Add('Show floating widget',             $null, { Show-FloatingWidget })
[void]$menu.Items.Add('Open snips folder',             $null, {
    $dir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Snips'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Start-Process explorer.exe $dir
})
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('About', $null, { Show-AboutWindow })
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
} catch {
    # Surface the actual inner exception (PS wraps the .NET one in a
    # MethodInvocationException whose Message is unhelpfully generic).
    $msg = $_.Exception.Message
    if ($_.Exception.InnerException) {
        $inner = $_.Exception.InnerException
        $msg = "$($inner.GetType().FullName): $($inner.Message)`n`n$($inner.StackTrace)"
    }
    try {
        [System.Windows.Forms.MessageBox]::Show($msg, 'SnipIT runtime error', 'OK', 'Error') | Out-Null
    } catch {
        [Console]::Error.WriteLine($msg)
    }
} finally {
    try { [Native]::UnregisterHotKey($hotkeyForm.Handle, $HOTKEY_SMART)  | Out-Null } catch {}
    try { [Native]::UnregisterHotKey($hotkeyForm.Handle, $HOTKEY_FULL)   | Out-Null } catch {}
    try { [Native]::UnregisterHotKey($hotkeyForm.Handle, $HOTKEY_WINDOW) | Out-Null } catch {}
    if ($tray)        { try { $tray.Dispose() }        catch {} }
    if ($hotkeyForm)  { try { $hotkeyForm.Dispose() }  catch {} }
    if ($script:SingleInstanceMutex) {
        try { $script:SingleInstanceMutex.ReleaseMutex() } catch {}
        try { $script:SingleInstanceMutex.Dispose() }      catch {}
    }
}

#endregion
