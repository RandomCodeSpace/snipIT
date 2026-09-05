#requires -Version 7.5
<#
    SnipIT — professional snipping tool for Windows 11
    Pure PowerShell 7.5+ on .NET 9. No admin. No external dependencies.

    Capture modes:
      Smart    Hover-highlight a window or drag a region, with a magnifier loupe
      Full     The whole virtual desktop across every display
      Window   The active (foreground) window
      Display  A single monitor, picked from the live display list
      Delayed  Smart after 3 / 5 / 10 seconds, or Full / Window after 3 seconds

    Hotkey:
      Ctrl+Alt+Shift+Q  Smart capture (default binding; rebindable in Settings)

    Tray menu: Smart capture / Full desktop / Active window / Display >
      Delay capture > / Settings / Edge-reveal widget / Open snips folder /
      About SnipIT / Uninstall / Exit

    Only one instance runs per Windows session; a second launch reports that and exits.

    Run with -CoreOnly to dot-source cross-platform logic/contracts (used by tests).
#>
param([switch]$CoreOnly)

#region DPI awareness (must run before any UI assembly loads) ================
# Windows latches the process DPI awareness mode the first time anything in the
# process asks the display subsystem a question, and every UI framework does
# that while its assembly initializes. PresentationFramework, PresentationCore
# and System.Windows.Forms all load further down in the bootstrap initializer,
# so the SetProcessDpiAwarenessContext call that used to sit next to the P/Invoke
# definitions ran far too late: the request was refused, its return value was
# discarded, and the process stayed system-aware without anyone noticing.
#
# That matters because the two halves of the monitor topology disagree under
# system awareness. Screen.AllScreens hands back bounds virtualized to the
# primary monitor's DPI, while GetDpiForMonitor keeps reporting each monitor's
# true DPI, so pairing them produces layouts that are wrong on every display
# whose scale differs from the primary's.
#
# So ask here, first thing, and then record what we were actually granted.
# The request can still be refused — a host that pre-loads a UI framework into
# the PowerShell process (Citrix does this) latches system awareness before our
# script's first line runs — which is exactly why we read the result back
# instead of assuming it.

$script:SnipDpiAwarenessRequested = $false
$script:SnipDpiAwarenessGranted   = $false
$script:SnipProcessDpiAwareness   = 'Unknown'
$script:SnipThreadDpiAwareness    = 'Unknown'
$script:SnipDpiPerMonitorAware    = $false
$script:SnipDpiFallbackLogged     = $false

function Get-SnipDpiAwarenessName {
    # Maps the DPI_AWARENESS / PROCESS_DPI_AWARENESS enum (they share values)
    # onto the names SnipIT logs and branches on. Anything we do not recognise
    # is reported as 'Unknown' rather than guessed at, because the caller's
    # fallback for "unknown" and for "system" is deliberately the same.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$Value)

    switch ($Value) {
        0       { 'Unaware' }
        1       { 'System' }
        2       { 'PerMonitor' }
        default { 'Unknown' }
    }
}

function Resolve-SnipMonitorDpi {
    # Decides which DPI to report for a monitor given the awareness the process
    # actually holds.
    #
    # Per-monitor aware: the bounds we read are real physical pixels, so the
    # real per-monitor DPI belongs with them.
    #
    # Anything else: Windows has already scaled every monitor rectangle into the
    # primary monitor's DPI space, so the honest scale for those bounds is 1.0 —
    # 96 DPI everywhere. Reporting the true DPI here is what produced mixed-space
    # layouts: a true scale of 1.5 applied to bounds that were never in physical
    # pixels to begin with.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$RawDpiX,
        [Parameter(Mandatory)] [double]$RawDpiY,
        [bool]$PerMonitorAware = $false
    )

    $usable = $PerMonitorAware -and
        [double]::IsFinite($RawDpiX) -and $RawDpiX -gt 0 -and
        [double]::IsFinite($RawDpiY) -and $RawDpiY -gt 0
    if ($usable) {
        [pscustomobject][ordered]@{
            DpiX = [double]$RawDpiX
            DpiY = [double]$RawDpiY
            Normalized = $false
        }
    } else {
        [pscustomobject][ordered]@{
            DpiX = 96.0
            DpiY = 96.0
            Normalized = $true
        }
    }
}

# The request itself is a no-op for portable core loads, for test mode, and off
# Windows — all three either have no display subsystem to configure or must not
# mutate the host process that is running the suite.
if (-not $CoreOnly -and -not $env:SNIPIT_TEST_MODE -and $IsWindows) {
    try {
        if (-not ('SnipDpiBootstrap' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Deliberately minimal: this type exists only so the awareness request can run
// before any real UI assembly is loaded. Everything else lives in [Native].
public static class SnipDpiBootstrap {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")]
    public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")]
    public static extern int GetProcessDpiAwareness(IntPtr process, out int awareness);
    public static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);
}
'@
        }
        $script:SnipDpiAwarenessRequested = $true
        $script:SnipDpiAwarenessGranted = [bool][SnipDpiBootstrap]::SetProcessDpiAwarenessContext(
            [SnipDpiBootstrap]::PerMonitorAwareV2)
    } catch {
        $script:SnipDpiAwarenessGranted = $false
    }
    try {
        [int]$processAwareness = 1
        if ([SnipDpiBootstrap]::GetProcessDpiAwareness(
                [IntPtr]::Zero, [ref]$processAwareness) -eq 0) {
            $script:SnipProcessDpiAwareness = Get-SnipDpiAwarenessName -Value $processAwareness
        }
    } catch {}
    try {
        $threadContext = [SnipDpiBootstrap]::GetThreadDpiAwarenessContext()
        $script:SnipThreadDpiAwareness = Get-SnipDpiAwarenessName -Value (
            [SnipDpiBootstrap]::GetAwarenessFromDpiAwarenessContext($threadContext))
    } catch {}
    # Both have to agree: the process mode decides how Screen.AllScreens is
    # virtualized, and the thread mode decides how the Win32 rect queries behind
    # it answer. A thread that opted into per-monitor awareness inside a
    # system-aware process is not a topology we can read consistently.
    $script:SnipDpiPerMonitorAware =
        $script:SnipProcessDpiAwareness -eq 'PerMonitor' -and
        $script:SnipThreadDpiAwareness -eq 'PerMonitor'
}
#endregion

#region Core (pure logic, no UI / no Win32, cross-platform testable) =========

if (-not (Get-Variable -Name SnipEntryPath -Scope Script -ErrorAction Ignore)) {
    $script:SnipEntryPath = $PSCommandPath
}
if (-not (Get-Variable -Name SnipInstallSourcePath -Scope Script -ErrorAction Ignore)) {
    $script:SnipInstallSourcePath = $PSCommandPath
}

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

# Loupe geometry. The sampled patch is deliberately odd-sized so one pixel sits
# dead centre under the crosshair, and the viewport is a whole multiple of it so
# nearest-neighbour scaling paints square pixels of equal size instead of
# duplicating some rows and not others. Both numbers are mirrored in the
# SmartOverlay XAML (LoupeImage's parent Border) and asserted by the suite.
$script:SnipLoupeSourceSize   = 17
$script:SnipLoupeViewportSize = 136

function Get-LoupeMagnification {
    # Pure: how many device-independent pixels one captured pixel occupies in
    # the loupe, plus the two invariants the loupe depends on being true.
    param(
        [int]$ViewportSize = $script:SnipLoupeViewportSize,
        [int]$SourceSize   = $script:SnipLoupeSourceSize
    )
    if ($SourceSize -le 0) {
        throw "Loupe source size must be positive (got $SourceSize)."
    }
    [pscustomobject][ordered]@{
        Factor     = $ViewportSize / $SourceSize
        IsIntegral = (($ViewportSize % $SourceSize) -eq 0)
        IsCentred  = (($SourceSize % 2) -eq 1)
    }
}

function Get-LoupeSourceRect {
    param(
        [Parameter(Mandatory)] [int]$MouseX,
        [Parameter(Mandatory)] [int]$MouseY,
        [Parameter(Mandatory)] [int]$VsX,
        [Parameter(Mandatory)] [int]$VsY,
        [Parameter(Mandatory)] [int]$VsWidth,
        [Parameter(Mandatory)] [int]$VsHeight,
        [int]$Size = $script:SnipLoupeSourceSize
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
    param(
        [datetime]$Timestamp = (Get-Date),
        [ValidateSet('Png','Jpeg','Bmp')] [string]$Format = 'Png'
    )
    $extension = switch ($Format) { 'Jpeg' { '.jpg' } 'Bmp' { '.bmp' } default { '.png' } }
    "snip-{0:yyyyMMdd-HHmmss}{1}" -f $Timestamp, $extension
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

function Get-SnipSaveDialogDefaults {
    # Projects the persisted save preferences onto the three SaveFileDialog
    # fields that decide where the dialog opens, what it pre-fills, and which
    # format filter is selected. Pure: no dialog, no file system, no WPF.
    [CmdletBinding()]
    param(
        $Settings,
        [datetime]$Now = (Get-Date),
        [string]$PicturesDir = [Environment]::GetFolderPath('MyPictures')
    )

    $format = 'Png'
    $folder = ''
    if ($null -ne $Settings) {
        $formatProperty = $Settings.PSObject.Properties['SaveFormat']
        if ($null -ne $formatProperty) {
            $format = switch ([string]$formatProperty.Value) {
                'Jpeg'  { 'Jpeg' }
                'Bmp'   { 'Bmp' }
                default { 'Png' }
            }
        }
        $folderProperty = $Settings.PSObject.Properties['SaveFolder']
        if ($null -ne $folderProperty) { $folder = [string]$folderProperty.Value }
    }
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = if ([string]::IsNullOrWhiteSpace($PicturesDir)) {
            'Snips'
        } else {
            Join-Path $PicturesDir 'Snips'
        }
    }

    [pscustomobject][ordered]@{
        InitialDirectory = $folder
        FileName         = Get-DefaultSnipFilename -Timestamp $Now -Format $format
        FilterIndex      = switch ($format) { 'Jpeg' { 2 } 'Bmp' { 3 } default { 1 } }
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

# Builds the .lnk Description ("Comment"), which doubles as a stamp of the icon
# artwork the shortcut was last written against.
#
# Explorer caches the bitmap it drew for a Desktop shortcut. Regenerating
# SnipIT.ico under an unchanged path leaves both the .lnk and its recorded icon
# location identical, so the shortcut looked up to date and the Desktop kept
# showing the previous artwork. Folding the icon's SHA-256 into a compared field
# turns an artwork change into ordinary shortcut drift: the .lnk is rewritten and
# the shell gets told to refresh it.
#
# An empty stamp yields the plain description, which Test-SnipShortcutCurrent
# still compares — callers without an icon simply get the unstamped text.
function Get-SnipShortcutDescription {
    [OutputType([string])]
    param([string]$IconStamp)

    $base = 'SnipIT - professional snipping tool'
    $stamp = ([string]$IconStamp).Trim()
    if ($stamp -eq '') { return $base }
    # 16 hex chars is far more than enough to notice a change and keeps the
    # tooltip Windows shows for the shortcut readable.
    if ($stamp.Length -gt 16) { $stamp = $stamp.Substring(0, 16) }
    "$base (icon $($stamp.ToLowerInvariant()))"
}

# Reads a named shortcut field off a plain snapshot object (or hashtable) and
# normalizes it for comparison: a missing/null value and an all-whitespace
# value both collapse to ''.
function Get-SnipShortcutField {
    param(
        $Source,
        [Parameter(Mandatory)] [string]$Name
    )

    if ($null -eq $Source) { return '' }
    $value = $null
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { $value = $Source[$Name] }
    } else {
        $property = $Source.psobject.Properties[$Name]
        if ($property) { $value = $property.Value }
    }
    if ($null -eq $value) { return '' }
    ([string]$value).Trim()
}

# Decides whether a shortcut already on disk still matches what we would
# write, so the installer can leave it alone instead of deleting and
# recreating the .lnk on every launch (which churns the Desktop / Startup
# folders and throws away any user customization).
#
# -Existing is a snapshot of the shortcut on disk ($null when there is none).
# -Desired holds the values we intend to write. A desired field that is empty
# counts as unmanaged and is not compared, so a caller that passes no icon
# does not force a rewrite. Comparison is case-insensitive; Windows paths are.
#
# Description carries the icon-artwork stamp (see Get-SnipShortcutDescription),
# so new artwork under an unchanged SnipIT.ico path counts as drift and the .lnk
# is rewritten — otherwise Explorer keeps drawing the icon it already cached.
function Test-SnipShortcutCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $Existing,
        [Parameter(Mandatory)] $Desired
    )

    if ($null -eq $Existing) { return $false }

    foreach ($name in @('TargetPath', 'Arguments', 'IconLocation', 'Description')) {
        $wanted = Get-SnipShortcutField -Source $Desired -Name $name
        if ($wanted -eq '') { continue }
        if ((Get-SnipShortcutField -Source $Existing -Name $name) -ne $wanted) {
            return $false
        }
    }
    return $true
}

function Get-ClampedAnnotationRect {
    # Clamp an annotation rect (image-pixel coords) to a bitmap's bounds.
    # The origin is pinned to [0, W-1] / [0, H-1], and the width/height are
    # clamped so the rect still fits. Minimum size is 1x1 so the annotation
    # doesn't become zero-area if the user drew entirely past the right/bottom edge.
    param(
        [Parameter(Mandatory)] [int]$X,
        [Parameter(Mandatory)] [int]$Y,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [Parameter(Mandatory)] [int]$BitmapWidth,
        [Parameter(Mandatory)] [int]$BitmapHeight
    )
    $nx = [math]::Max(0, [math]::Min($BitmapWidth  - 1, $X))
    $ny = [math]::Max(0, [math]::Min($BitmapHeight - 1, $Y))
    $nw = [math]::Max(1, [math]::Min($BitmapWidth  - $nx, $Width))
    $nh = [math]::Max(1, [math]::Min($BitmapHeight - $ny, $Height))
    [pscustomobject]@{ X = $nx; Y = $ny; Width = $nw; Height = $nh }
}

function Get-ZoomCenteredOffset {
    # Compute the scroll offset that keeps the content point currently under
    # ($CursorX, $CursorY) anchored after a scale change (Ctrl+MouseWheel zoom).
    # Content coords = viewport-offset + viewport-position; if the same image
    # pixel should land on the same viewport pixel after scaling, the offset
    # must shift by (OldOffset + Cursor) * NewScale/OldScale - Cursor.
    # Result is clamped to [0, Content - Viewport].
    param(
        [Parameter(Mandatory)] [double]$CursorX,
        [Parameter(Mandatory)] [double]$CursorY,
        [Parameter(Mandatory)] [double]$OldScrollX,
        [Parameter(Mandatory)] [double]$OldScrollY,
        [Parameter(Mandatory)] [double]$OldScale,
        [Parameter(Mandatory)] [double]$NewScale,
        [Parameter(Mandatory)] [double]$ContentWidth,
        [Parameter(Mandatory)] [double]$ContentHeight,
        [Parameter(Mandatory)] [double]$ViewportWidth,
        [Parameter(Mandatory)] [double]$ViewportHeight
    )
    if ($OldScale -le 0) { $OldScale = 1.0 }
    $ratio = $NewScale / $OldScale
    $newX = ($OldScrollX + $CursorX) * $ratio - $CursorX
    $newY = ($OldScrollY + $CursorY) * $ratio - $CursorY
    $maxX = [math]::Max(0.0, $ContentWidth  - $ViewportWidth)
    $maxY = [math]::Max(0.0, $ContentHeight - $ViewportHeight)
    $newX = [math]::Max(0.0, [math]::Min($maxX, $newX))
    $newY = [math]::Max(0.0, [math]::Min($maxY, $newY))
    [pscustomobject]@{ X = $newX; Y = $newY }
}

function Get-SnipRecordValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string]$Name,
        [AllowNull()] $Default = $null,
        [switch]$Required
    )

    $found = $false
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) {
                $value = $InputObject[$key]
                $found = $true
                break
            }
        }
    } elseif ($null -ne $InputObject.PSObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            $value = $property.Value
            $found = $true
        }
    }

    if ($found) { return $value }
    if ($Required) {
        throw [ArgumentException]::new("Expected property '$Name'.", $Name)
    }
    return $Default
}

function Test-SnipAtomicSemanticValue {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $false }
    # Semantic records currently need only immutable text, booleans, characters,
    # and numeric scalars. An explicit list prevents arbitrary structs from
    # smuggling mutable or disposable references into history snapshots.
    $typeName = $Value.GetType().FullName
    $typeName -in @(
        'System.String', 'System.Boolean', 'System.Char',
        'System.SByte', 'System.Byte', 'System.Int16', 'System.UInt16',
        'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64',
        'System.Single', 'System.Double', 'System.Decimal'
    )
}

function Copy-SnipSemanticKey {
    param([AllowNull()] $Key)

    if ($null -eq $Key -or -not (Test-SnipAtomicSemanticValue -Value $Key)) {
        $typeName = if ($null -eq $Key) { '<null>' } else { $Key.GetType().FullName }
        throw [ArgumentException]::new(
            "Unsupported semantic dictionary key type '$typeName'.", 'Key')
    }
    if ($Key -is [string]) {
        # Materialize a separate immutable key object instead of retaining the
        # source dictionary's reference.
        return [string]::new($Key.ToCharArray())
    }
    return $Key
}

function Copy-SnipSemanticValue {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    # Disposable preview/cache objects are deliberately not semantic record
    # data. Reject them without disposing; Task 9 owns caches outside history.
    if ($Value -is [System.IDisposable]) {
        throw [ArgumentException]::new(
            "Disposable semantic values are unsupported ($($Value.GetType().FullName)).",
            'Value')
    }
    if (Test-SnipAtomicSemanticValue -Value $Value) { return $Value }
    if ($Value.GetType().IsValueType) {
        throw [ArgumentException]::new(
            "Unsupported semantic value type '$($Value.GetType().FullName)'.", 'Value')
    }

    if ($Value -is [System.Collections.Specialized.OrderedDictionary]) {
        $copy = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            $keyCopy = Copy-SnipSemanticKey -Key $entry.Key
            $valueCopy = Copy-SnipSemanticValue -Value $entry.Value
            $copy.Add($keyCopy, $valueCopy)
        }
        return $copy
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($entry in $Value.GetEnumerator()) {
            $keyCopy = Copy-SnipSemanticKey -Key $entry.Key
            $valueCopy = Copy-SnipSemanticValue -Value $entry.Value
            $copy.Add($keyCopy, $valueCopy)
        }
        return $copy
    }
    if ($Value.GetType().IsArray) {
        $copy = @($Value | ForEach-Object { Copy-SnipSemanticValue -Value $_ })
        return ,$copy
    }
    if ($Value -is [System.Collections.IList]) {
        $copy = [System.Collections.ArrayList]::new()
        foreach ($item in $Value) {
            [void]$copy.Add((Copy-SnipSemanticValue -Value $item))
        }
        return ,$copy
    }
    if ($Value -is [pscustomobject]) {
        $properties = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if (-not $property.IsGettable) { continue }
            $properties[$property.Name] = Copy-SnipSemanticValue -Value $property.Value
        }
        return [pscustomobject]$properties
    }

    # Unknown reference types could be mutable. Reject rather than introducing
    # a hidden alias or guessing at clone/ownership semantics.
    throw [ArgumentException]::new(
        "Unsupported semantic reference type '$($Value.GetType().FullName)'.", 'Value')
}

function ConvertTo-SnipAnnotationGeometry {
    param([Parameter(Mandatory)] $Geometry)

    $type = [string](Get-SnipRecordValue -InputObject $Geometry -Name Type -Required)
    switch ($type.ToLowerInvariant()) {
        'bounds' {
            return [pscustomobject][ordered]@{
                Type = 'Bounds'
                X = [int](Get-SnipRecordValue -InputObject $Geometry -Name X -Required)
                Y = [int](Get-SnipRecordValue -InputObject $Geometry -Name Y -Required)
                Width = [int](Get-SnipRecordValue -InputObject $Geometry -Name Width -Required)
                Height = [int](Get-SnipRecordValue -InputObject $Geometry -Name Height -Required)
            }
        }
        'textbounds' {
            return [pscustomobject][ordered]@{
                Type = 'TextBounds'
                X = [int](Get-SnipRecordValue -InputObject $Geometry -Name X -Required)
                Y = [int](Get-SnipRecordValue -InputObject $Geometry -Name Y -Required)
                Width = [int](Get-SnipRecordValue -InputObject $Geometry -Name Width -Required)
                Height = [int](Get-SnipRecordValue -InputObject $Geometry -Name Height -Required)
            }
        }
        'stepbounds' {
            return [pscustomobject][ordered]@{
                Type = 'StepBounds'
                X = [int](Get-SnipRecordValue -InputObject $Geometry -Name X -Required)
                Y = [int](Get-SnipRecordValue -InputObject $Geometry -Name Y -Required)
                Width = [int](Get-SnipRecordValue -InputObject $Geometry -Name Width -Required)
                Height = [int](Get-SnipRecordValue -InputObject $Geometry -Name Height -Required)
            }
        }
        'line' {
            $start = Get-SnipRecordValue -InputObject $Geometry -Name Start -Required
            $end = Get-SnipRecordValue -InputObject $Geometry -Name End -Required
            return [pscustomobject][ordered]@{
                Type = 'Line'
                Start = [pscustomobject][ordered]@{
                    X = [int](Get-SnipRecordValue -InputObject $start -Name X -Required)
                    Y = [int](Get-SnipRecordValue -InputObject $start -Name Y -Required)
                }
                End = [pscustomobject][ordered]@{
                    X = [int](Get-SnipRecordValue -InputObject $end -Name X -Required)
                    Y = [int](Get-SnipRecordValue -InputObject $end -Name Y -Required)
                }
            }
        }
        'points' {
            $sourcePoints = Get-SnipRecordValue -InputObject $Geometry -Name Points -Required
            $points = [System.Collections.ArrayList]::new()
            if ($null -ne $sourcePoints) {
                foreach ($point in $sourcePoints) {
                    [void]$points.Add([pscustomobject][ordered]@{
                        X = [int](Get-SnipRecordValue -InputObject $point -Name X -Required)
                        Y = [int](Get-SnipRecordValue -InputObject $point -Name Y -Required)
                    })
                }
            }
            return [pscustomobject][ordered]@{ Type = 'Points'; Points = @($points) }
        }
        default {
            # Unknown future geometry remains copyable and harmless. Consumers
            # that do not understand its discriminator must safely ignore it.
            return Copy-SnipSemanticValue -Value $Geometry
        }
    }
}

function New-SnipAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Kind,
        [Parameter(Mandatory)] $Geometry,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Color,
        [Parameter(Mandatory)] [double]$StrokeWidth,
        [Parameter(Mandatory)] [double]$Opacity,
        [Parameter(Mandatory)] [AllowNull()] $Properties,
        [Parameter(Mandatory)] [double]$Z,
        [AllowNull()] [AllowEmptyString()] [string]$Id
    )

    if ($PSBoundParameters.ContainsKey('Id')) {
        if ([string]::IsNullOrWhiteSpace($Id)) {
            throw [ArgumentException]::new('An explicit annotation Id must be nonempty.', 'Id')
        }
        $recordId = $Id
    } else {
        $recordId = [guid]::NewGuid().ToString()
    }
    $semanticProperties = if ($null -eq $Properties) {
        [ordered]@{}
    } else {
        Copy-SnipSemanticValue -Value $Properties
    }

    [pscustomobject][ordered]@{
        Id = $recordId
        Kind = $Kind
        Geometry = ConvertTo-SnipAnnotationGeometry -Geometry $Geometry
        Color = $Color
        StrokeWidth = $StrokeWidth
        Opacity = $Opacity
        Properties = $semanticProperties
        Z = $Z
    }
}

function Copy-SnipAnnotation {
    param([Parameter(Mandatory)] $Annotation)

    $kind = Get-SnipRecordValue -InputObject $Annotation -Name Kind
    $geometry = Get-SnipRecordValue -InputObject $Annotation -Name Geometry
    $id = [string](Get-SnipRecordValue -InputObject $Annotation -Name Id)
    if (-not [string]::IsNullOrWhiteSpace([string]$kind) -and $null -ne $geometry) {
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw [ArgumentException]::new(
                'A canonical annotation must already own a nonempty stable Id.', 'Annotation')
        }
        $arguments = @{
            Kind = [string]$kind
            Geometry = $geometry
            Color = [string](Get-SnipRecordValue -InputObject $Annotation -Name Color -Default '')
            StrokeWidth = [double](Get-SnipRecordValue -InputObject $Annotation -Name StrokeWidth -Default 1.0)
            Opacity = [double](Get-SnipRecordValue -InputObject $Annotation -Name Opacity -Default 1.0)
            Properties = Get-SnipRecordValue -InputObject $Annotation -Name Properties -Default ([ordered]@{})
            Z = [double](Get-SnipRecordValue -InputObject $Annotation -Name Z -Default 0)
            Id = $id
        }
        return New-SnipAnnotation @arguments
    }

    $legacyType = [string](Get-SnipRecordValue -InputObject $Annotation -Name Type -Required)
    $x = [int](Get-SnipRecordValue -InputObject $Annotation -Name X -Required)
    $y = [int](Get-SnipRecordValue -InputObject $Annotation -Name Y -Required)
    $width = [int](Get-SnipRecordValue -InputObject $Annotation -Name W -Required)
    $height = [int](Get-SnipRecordValue -InputObject $Annotation -Name H -Required)
    $properties = [ordered]@{}
    switch ($legacyType.ToLowerInvariant()) {
        'highlight' {
            $canonicalKind = 'Highlight'
            $canonicalGeometry = [pscustomobject]@{
                Type='Bounds'; X=$x; Y=$y; Width=$width; Height=$height
            }
        }
        'rect' {
            $canonicalKind = 'Rectangle'
            $canonicalGeometry = [pscustomobject]@{
                Type='Bounds'; X=$x; Y=$y; Width=$width; Height=$height
            }
        }
        'arrow' {
            $canonicalKind = 'Arrow'
            $canonicalGeometry = [pscustomobject]@{
                Type='Line'
                Start=[pscustomobject]@{X=$x;Y=$y}
                End=[pscustomobject]@{X=($x + $width);Y=($y + $height)}
            }
        }
        'text' {
            $canonicalKind = 'Text'
            $canonicalGeometry = [pscustomobject]@{
                Type='TextBounds'; X=$x; Y=$y; Width=$width; Height=$height
            }
            $properties.Text = Get-SnipRecordValue -InputObject $Annotation -Name Text
            $properties.FontSize = Get-SnipRecordValue -InputObject $Annotation -Name FontSize -Default 0
        }
        default {
            throw [ArgumentException]::new("Unsupported legacy annotation type '$legacyType'.", 'Annotation')
        }
    }

    $arguments = @{
        Kind = $canonicalKind
        Geometry = $canonicalGeometry
        Color = [string](Get-SnipRecordValue -InputObject $Annotation -Name Color -Default '')
        StrokeWidth = [double](Get-SnipRecordValue -InputObject $Annotation -Name StrokeWidth -Default 1.0)
        Opacity = [double](Get-SnipRecordValue -InputObject $Annotation -Name Opacity -Default 1.0)
        Properties = $properties
        Z = [double](Get-SnipRecordValue -InputObject $Annotation -Name Z -Default 0)
    }
    if (-not [string]::IsNullOrWhiteSpace($id)) { $arguments.Id = $id }
    New-SnipAnnotation @arguments
}

function Copy-AnnotationList {
    # Keep the historical non-enumerated ArrayList shape used by Preview history,
    # while routing every member through the one canonical stable-record copier.
    param([AllowNull()][AllowEmptyCollection()] $Annotations)
    $copy = [System.Collections.ArrayList]::new()
    if ($null -eq $Annotations) { return ,$copy }
    foreach ($annotation in $Annotations) {
        [void]$copy.Add((Copy-SnipAnnotation -Annotation $annotation))
    }
    return ,$copy
}

function New-SnipEditorSnapshot {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()] $Annotations,
        [AllowNull()] $CropRectangle
    )

    $cropCopy = $null
    if ($null -ne $CropRectangle) {
        $cropCopy = [pscustomobject][ordered]@{
            X = [int](Get-SnipRecordValue -InputObject $CropRectangle -Name X -Required)
            Y = [int](Get-SnipRecordValue -InputObject $CropRectangle -Name Y -Required)
            Width = [int](Get-SnipRecordValue -InputObject $CropRectangle -Name Width -Required)
            Height = [int](Get-SnipRecordValue -InputObject $CropRectangle -Name Height -Required)
        }
    }
    [pscustomobject][ordered]@{
        Version = 1
        Annotations = Copy-AnnotationList -Annotations $Annotations
        CropRectangle = $cropCopy
    }
}

function Test-SnipPointNearSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$PointX,
        [Parameter(Mandatory)] [double]$PointY,
        [Parameter(Mandatory)] [double]$StartX,
        [Parameter(Mandatory)] [double]$StartY,
        [Parameter(Mandatory)] [double]$EndX,
        [Parameter(Mandatory)] [double]$EndY,
        [Parameter(Mandatory)] [double]$Tolerance
    )

    $dx = $EndX - $StartX
    $dy = $EndY - $StartY
    $lengthSquared = ($dx * $dx) + ($dy * $dy)
    if ($lengthSquared -le 0) {
        $nearestX = $StartX
        $nearestY = $StartY
    } else {
        $projection = ((($PointX - $StartX) * $dx) + (($PointY - $StartY) * $dy)) / $lengthSquared
        $projection = [math]::Max(0.0, [math]::Min(1.0, $projection))
        $nearestX = $StartX + ($projection * $dx)
        $nearestY = $StartY + ($projection * $dy)
    }
    $distanceX = $PointX - $nearestX
    $distanceY = $PointY - $nearestY
    (($distanceX * $distanceX) + ($distanceY * $distanceY)) -le ($Tolerance * $Tolerance)
}

function Test-SnipAnnotationHit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Annotation,
        [Parameter(Mandatory)] [double]$ImageX,
        [Parameter(Mandatory)] [double]$ImageY,
        [Parameter(Mandatory)] [double]$Tolerance
    )

    $geometry = $Annotation.Geometry
    if ($null -eq $geometry) { return $false }
    $geometryType = [string](Get-SnipRecordValue -InputObject $geometry -Name Type)
    switch ($geometryType.ToLowerInvariant()) {
        { $_ -in 'bounds', 'textbounds', 'stepbounds' } {
            $x = [double](Get-SnipRecordValue -InputObject $geometry -Name X -Required)
            $y = [double](Get-SnipRecordValue -InputObject $geometry -Name Y -Required)
            $width = [double](Get-SnipRecordValue -InputObject $geometry -Name Width -Required)
            $height = [double](Get-SnipRecordValue -InputObject $geometry -Name Height -Required)
            if ($width -le 0 -or $height -le 0) { return $false }
            return ($ImageX -ge ($x - $Tolerance) -and
                    $ImageY -ge ($y - $Tolerance) -and
                    $ImageX -lt ($x + $width + $Tolerance) -and
                    $ImageY -lt ($y + $height + $Tolerance))
        }
        'line' {
            $start = Get-SnipRecordValue -InputObject $geometry -Name Start -Required
            $end = Get-SnipRecordValue -InputObject $geometry -Name End -Required
            $startX = [double](Get-SnipRecordValue -InputObject $start -Name X -Required)
            $startY = [double](Get-SnipRecordValue -InputObject $start -Name Y -Required)
            $endX = [double](Get-SnipRecordValue -InputObject $end -Name X -Required)
            $endY = [double](Get-SnipRecordValue -InputObject $end -Name Y -Required)
            if ($startX -eq $endX -and $startY -eq $endY) { return $false }
            return Test-SnipPointNearSegment -PointX $ImageX -PointY $ImageY `
                -StartX $startX -StartY $startY -EndX $endX -EndY $endY `
                -Tolerance $Tolerance
        }
        'points' {
            $points = @(Get-SnipRecordValue -InputObject $geometry -Name Points -Required)
            if ($points.Count -eq 0) { return $false }
            if ($points.Count -eq 1) {
                $point = $points[0]
                return Test-SnipPointNearSegment -PointX $ImageX -PointY $ImageY `
                    -StartX (Get-SnipRecordValue -InputObject $point -Name X -Required) `
                    -StartY (Get-SnipRecordValue -InputObject $point -Name Y -Required) `
                    -EndX (Get-SnipRecordValue -InputObject $point -Name X -Required) `
                    -EndY (Get-SnipRecordValue -InputObject $point -Name Y -Required) `
                    -Tolerance $Tolerance
            }
            for ($index = 1; $index -lt $points.Count; $index++) {
                $start = $points[$index - 1]
                $end = $points[$index]
                if (Test-SnipPointNearSegment -PointX $ImageX -PointY $ImageY `
                    -StartX (Get-SnipRecordValue -InputObject $start -Name X -Required) `
                    -StartY (Get-SnipRecordValue -InputObject $start -Name Y -Required) `
                    -EndX (Get-SnipRecordValue -InputObject $end -Name X -Required) `
                    -EndY (Get-SnipRecordValue -InputObject $end -Name Y -Required) `
                    -Tolerance $Tolerance) {
                    return $true
                }
            }
            return $false
        }
        default { return $false }
    }
}

function Get-SnipAnnotationHitView {
    param([Parameter(Mandatory)] $Annotation)

    $kind = Get-SnipRecordValue -InputObject $Annotation -Name Kind
    $geometry = Get-SnipRecordValue -InputObject $Annotation -Name Geometry
    if (-not [string]::IsNullOrWhiteSpace([string]$kind) -and $null -ne $geometry) {
        $id = [string](Get-SnipRecordValue -InputObject $Annotation -Name Id)
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw [ArgumentException]::new(
                'A canonical annotation must own a nonempty stable Id.', 'Annotation')
        }
        return [pscustomobject]@{
            Geometry = $geometry
            Z = [double](Get-SnipRecordValue -InputObject $Annotation -Name Z -Default 0)
        }
    }

    $legacyType = [string](Get-SnipRecordValue -InputObject $Annotation -Name Type -Required)
    $x = [int](Get-SnipRecordValue -InputObject $Annotation -Name X -Required)
    $y = [int](Get-SnipRecordValue -InputObject $Annotation -Name Y -Required)
    $width = [int](Get-SnipRecordValue -InputObject $Annotation -Name W -Required)
    $height = [int](Get-SnipRecordValue -InputObject $Annotation -Name H -Required)
    $geometry = switch ($legacyType.ToLowerInvariant()) {
        { $_ -in 'highlight', 'rect' } {
            [pscustomobject]@{ Type='Bounds'; X=$x; Y=$y; Width=$width; Height=$height }
            break
        }
        'arrow' {
            [pscustomobject]@{
                Type='Line'; Start=[pscustomobject]@{X=$x;Y=$y}
                End=[pscustomobject]@{X=($x + $width);Y=($y + $height)}
            }
            break
        }
        'text' {
            [pscustomobject]@{ Type='TextBounds'; X=$x; Y=$y; Width=$width; Height=$height }
            break
        }
        default {
            throw [ArgumentException]::new(
                "Unsupported legacy annotation type '$legacyType'.", 'Annotation')
        }
    }
    [pscustomobject]@{
        Geometry = $geometry
        Z = [double](Get-SnipRecordValue -InputObject $Annotation -Name Z -Default 0)
    }
}

# Solves one arrow into a shaft segment plus a filled triangular head.
#
# StrokeEndLineCap='Triangle' (WPF) and LineCap::ArrowAnchor (GDI+) draw two
# different, both barely visible, heads. Both renderers consume this instead so
# the on-screen arrow and the exported arrow are the same shape. The shaft stops
# just inside the head's base so the stroke never pokes through the tip.
function Get-SnipArrowGeometry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$StartX,
        [Parameter(Mandatory)] [double]$StartY,
        [Parameter(Mandatory)] [double]$EndX,
        [Parameter(Mandatory)] [double]$EndY,
        [double]$StrokeWidth = 4
    )

    $deltaX = $EndX - $StartX
    $deltaY = $EndY - $StartY
    $length = [math]::Sqrt($deltaX * $deltaX + $deltaY * $deltaY)
    $width = [math]::Max(1.0, [double]$StrokeWidth)
    $headLength = [math]::Max(10.0, 4.0 * $width)
    $headHalf = [math]::Max(5.0, 2.0 * $width)
    if ($length -lt 1e-6) {
        # Degenerate drag: no direction to point in, so there is no head to draw.
        return [pscustomobject][ordered]@{
            Length=0.0; HeadLength=0.0; HeadHalfWidth=0.0
            ShaftEndX=$EndX; ShaftEndY=$EndY
            TipX=$EndX; TipY=$EndY
            LeftX=$EndX; LeftY=$EndY; RightX=$EndX; RightY=$EndY
        }
    }
    # A head longer than the arrow itself would invert the shaft, so cap it.
    if ($headLength -gt $length) { $headLength = $length }
    $unitX = $deltaX / $length
    $unitY = $deltaY / $length
    $baseX = $EndX - $unitX * $headLength
    $baseY = $EndY - $unitY * $headLength
    $shaftInset = [math]::Min($headLength, $headLength * 0.75)

    [pscustomobject][ordered]@{
        Length = $length
        HeadLength = $headLength
        HeadHalfWidth = $headHalf
        ShaftEndX = $EndX - $unitX * $shaftInset
        ShaftEndY = $EndY - $unitY * $shaftInset
        TipX = $EndX
        TipY = $EndY
        LeftX = $baseX - $unitY * $headHalf
        LeftY = $baseY + $unitX * $headHalf
        RightX = $baseX + $unitY * $headHalf
        RightY = $baseY - $unitX * $headHalf
    }
}

# Solves one Steps badge into the square StepBounds geometry the record stores.
# The badge is an accent-filled circle with a white number, so the diameter has
# to grow with the stroke width the user picked while staying legible at the
# smallest one; 28 px is the floor at which the digit still reads.
function Get-SnipStepBadgeGeometry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$CenterX,
        [Parameter(Mandatory)] [double]$CenterY,
        [double]$StrokeWidth = 3
    )

    $width = [math]::Max(0.0, [double]$StrokeWidth)
    $diameter = [int][math]::Max(28.0, [math]::Round(
        (3.0 * $width) + 18.0, 0, [MidpointRounding]::AwayFromZero))
    [pscustomobject][ordered]@{
        Diameter = $diameter
        X = [int][math]::Round($CenterX - ($diameter / 2.0), 0, [MidpointRounding]::AwayFromZero)
        Y = [int][math]::Round($CenterY - ($diameter / 2.0), 0, [MidpointRounding]::AwayFromZero)
        Width = $diameter
        Height = $diameter
        FontSize = [int][math]::Max(11.0, [math]::Round(
            $diameter * 0.5, 0, [MidpointRounding]::AwayFromZero))
    }
}

# Step numbers are never stored on the record: they are derived from creation
# order among the Step records that still exist. Deleting or undoing one
# therefore renumbers the rest for free, in every consumer at once.
function Get-SnipStepNumbering {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Annotations)

    $numbering = [System.Collections.ArrayList]::new()
    if ($null -eq $Annotations) { return @() }
    $number = 0
    foreach ($annotation in $Annotations) {
        if ($null -eq $annotation) { continue }
        if ([string](Get-SnipRecordValue -InputObject $annotation -Name Kind) -ne 'Step') {
            continue
        }
        $number++
        [void]$numbering.Add([pscustomobject][ordered]@{
            Id = [string](Get-SnipRecordValue -InputObject $annotation -Name Id)
            Number = $number
        })
    }
    # Emitted unrolled: callers wrap the call in @() and expect the entries,
    # not a single nested array.
    $numbering.ToArray()
}

# Appends one freehand sample to a Points path, dropping samples that land on
# top of the previous one. Without the filter a slow drag produces thousands of
# duplicate vertices, which is both a fat record and a visibly lumpy Polyline.
function Add-SnipFreehandPoint {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()] $Points,
        [Parameter(Mandatory)] [double]$X,
        [Parameter(Mandatory)] [double]$Y,
        [double]$MinimumDistance = 2.0
    )

    $path = [System.Collections.ArrayList]::new()
    if ($null -ne $Points) {
        foreach ($point in $Points) {
            [void]$path.Add([pscustomobject][ordered]@{
                X = [int](Get-SnipRecordValue -InputObject $point -Name X -Required)
                Y = [int](Get-SnipRecordValue -InputObject $point -Name Y -Required)
            })
        }
    }
    $nextX = [int][math]::Round($X, 0, [MidpointRounding]::AwayFromZero)
    $nextY = [int][math]::Round($Y, 0, [MidpointRounding]::AwayFromZero)
    if ($path.Count -gt 0) {
        $last = $path[$path.Count - 1]
        $deltaX = $nextX - [int]$last.X
        $deltaY = $nextY - [int]$last.Y
        $threshold = [math]::Max(0.0, $MinimumDistance)
        if ((($deltaX * $deltaX) + ($deltaY * $deltaY)) -lt ($threshold * $threshold)) {
            return $path.ToArray()
        }
    }
    [void]$path.Add([pscustomobject][ordered]@{ X = $nextX; Y = $nextY })
    $path.ToArray()
}

# One source of truth for how hard Blur and Pixelate obscure, so the WPF preview
# effect and the flattened export are driven by the same numbers.
function Get-SnipObscureMetrics {
    [CmdletBinding()]
    param(
        [ValidateSet('Blur','Pixelate')] [string]$Mode = 'Blur',
        [double]$StrokeWidth = 3
    )

    $width = [math]::Max(0.0, [double]$StrokeWidth)
    [pscustomobject][ordered]@{
        Mode = $Mode
        BlockSize = [int][math]::Max(6.0, [math]::Round(
            $width * 3.0, 0, [MidpointRounding]::AwayFromZero))
        BlurRadius = [int][math]::Max(2.0, [math]::Round(
            $width * 2.0, 0, [MidpointRounding]::AwayFromZero))
    }
}

# Reference block average for the Pixelate mosaic: the colour one output block
# takes is the mean of the source pixels it covers.
function Get-SnipBlockAverage {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]] $Pixels)

    if ($null -eq $Pixels -or $Pixels.Count -eq 0) { return $null }
    $red = 0L; $green = 0L; $blue = 0L
    foreach ($pixel in $Pixels) {
        $red += [long](Get-SnipRecordValue -InputObject $pixel -Name R -Required)
        $green += [long](Get-SnipRecordValue -InputObject $pixel -Name G -Required)
        $blue += [long](Get-SnipRecordValue -InputObject $pixel -Name B -Required)
    }
    $count = [double]$Pixels.Count
    [pscustomobject][ordered]@{
        R = [int][math]::Round($red / $count, 0, [MidpointRounding]::AwayFromZero)
        G = [int][math]::Round($green / $count, 0, [MidpointRounding]::AwayFromZero)
        B = [int][math]::Round($blue / $count, 0, [MidpointRounding]::AwayFromZero)
        Count = [int]$Pixels.Count
    }
}

function Find-SnipAnnotation {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()] $Annotations,
        [Parameter(Mandatory)] [double]$ImageX,
        [Parameter(Mandatory)] [double]$ImageY,
        [double]$Tolerance = 6.0
    )

    if ($null -eq $Annotations) { return $null }
    $safeTolerance = [math]::Max(0.0, $Tolerance)
    $bestSource = $null
    $bestZ = [double]::NegativeInfinity
    $bestIndex = -1
    $index = 0
    foreach ($annotation in $Annotations) {
        try {
            $hitView = Get-SnipAnnotationHitView -Annotation $annotation
            if (-not (Test-SnipAnnotationHit -Annotation $hitView -ImageX $ImageX `
                -ImageY $ImageY -Tolerance $safeTolerance)) {
                $index++
                continue
            }
            $z = [double]$hitView.Z
            if ($null -eq $bestSource -or $z -gt $bestZ -or ($z -eq $bestZ -and $index -gt $bestIndex)) {
                $bestSource = $annotation
                $bestZ = $z
                $bestIndex = $index
            }
        } catch {
            # Malformed or unsupported records are not selectable; one bad
            # compatibility record must not break selection for the whole list.
            Write-Debug "Ignoring malformed annotation at list index $index."
        }
        $index++
    }
    if ($null -eq $bestSource) { return $null }
    try {
        Copy-SnipAnnotation -Annotation $bestSource
    } catch {
        Write-Debug 'The selected annotation could not be normalized safely.'
        return $null
    }
}

function Select-SnipAnnotation {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()] $Annotations,
        [Parameter(Mandatory)] [double]$ImageX,
        [Parameter(Mandatory)] [double]$ImageY,
        [double]$Tolerance = 6.0
    )

    $annotation = Find-SnipAnnotation -Annotations $Annotations -ImageX $ImageX `
        -ImageY $ImageY -Tolerance $Tolerance
    if ($null -eq $annotation) { return $null }
    [string]$annotation.Id
}

function Move-SnipAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Annotation,
        [Parameter(Mandatory)] [int]$DeltaX,
        [Parameter(Mandatory)] [int]$DeltaY,
        [Parameter(Mandatory)] [int]$SourceWidth,
        [Parameter(Mandatory)] [int]$SourceHeight
    )

    if ($SourceWidth -le 0) {
        throw [ArgumentOutOfRangeException]::new('SourceWidth', 'Source width must be positive.')
    }
    if ($SourceHeight -le 0) {
        throw [ArgumentOutOfRangeException]::new('SourceHeight', 'Source height must be positive.')
    }
    $copy = Copy-SnipAnnotation -Annotation $Annotation
    $geometry = $copy.Geometry
    switch ([string]$geometry.Type) {
        { $_ -in 'Bounds', 'TextBounds', 'StepBounds' } {
            if ([int]$geometry.Width -le 0 -or [int]$geometry.Height -le 0 -or
                [int]$geometry.Width -gt $SourceWidth -or [int]$geometry.Height -gt $SourceHeight) {
                throw [ArgumentException]::new(
                    'Bounds geometry must have positive dimensions no larger than the source.',
                    'Annotation')
            }
            $maxX = [math]::Max(0, $SourceWidth - [int]$geometry.Width)
            $maxY = [math]::Max(0, $SourceHeight - [int]$geometry.Height)
            $geometry.X = [int][math]::Max(0, [math]::Min($maxX, ([int]$geometry.X + $DeltaX)))
            $geometry.Y = [int][math]::Max(0, [math]::Min($maxY, ([int]$geometry.Y + $DeltaY)))
        }
        'Line' {
            $points = @($geometry.Start, $geometry.End)
            $minimumX = [int](($points | Measure-Object X -Minimum).Minimum)
            $maximumX = [int](($points | Measure-Object X -Maximum).Maximum)
            $minimumY = [int](($points | Measure-Object Y -Minimum).Minimum)
            $maximumY = [int](($points | Measure-Object Y -Maximum).Maximum)
            if (($maximumX - $minimumX) -gt ($SourceWidth - 1) -or
                ($maximumY - $minimumY) -gt ($SourceHeight - 1)) {
                throw [ArgumentException]::new(
                    'Line geometry span is larger than the source.', 'Annotation')
            }
            $actualDeltaX = [math]::Max(-$minimumX, [math]::Min(($SourceWidth - 1) - $maximumX, $DeltaX))
            $actualDeltaY = [math]::Max(-$minimumY, [math]::Min(($SourceHeight - 1) - $maximumY, $DeltaY))
            foreach ($point in $points) {
                $point.X = [int]$point.X + [int]$actualDeltaX
                $point.Y = [int]$point.Y + [int]$actualDeltaY
            }
        }
        'Points' {
            $points = @($geometry.Points)
            if ($points.Count -gt 0) {
                $minimumX = [int](($points | Measure-Object X -Minimum).Minimum)
                $maximumX = [int](($points | Measure-Object X -Maximum).Maximum)
                $minimumY = [int](($points | Measure-Object Y -Minimum).Minimum)
                $maximumY = [int](($points | Measure-Object Y -Maximum).Maximum)
                if (($maximumX - $minimumX) -gt ($SourceWidth - 1) -or
                    ($maximumY - $minimumY) -gt ($SourceHeight - 1)) {
                    throw [ArgumentException]::new(
                        'Point geometry span is larger than the source.', 'Annotation')
                }
                $actualDeltaX = [math]::Max(-$minimumX, [math]::Min(($SourceWidth - 1) - $maximumX, $DeltaX))
                $actualDeltaY = [math]::Max(-$minimumY, [math]::Min(($SourceHeight - 1) - $maximumY, $DeltaY))
                foreach ($point in $points) {
                    $point.X = [int]$point.X + [int]$actualDeltaX
                    $point.Y = [int]$point.Y + [int]$actualDeltaY
                }
            }
        }
    }
    $copy
}

function Resize-SnipAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Annotation,
        [Parameter(Mandatory)]
        [ValidateSet('TopLeft','Top','TopRight','Right','BottomRight','Bottom','BottomLeft','Left','Start','End')]
        [string]$Handle,
        [Parameter(Mandatory)] [int]$DeltaX,
        [Parameter(Mandatory)] [int]$DeltaY,
        [Parameter(Mandatory)] [int]$SourceWidth,
        [Parameter(Mandatory)] [int]$SourceHeight
    )

    if ($SourceWidth -le 0) {
        throw [ArgumentOutOfRangeException]::new('SourceWidth', 'Source width must be positive.')
    }
    if ($SourceHeight -le 0) {
        throw [ArgumentOutOfRangeException]::new('SourceHeight', 'Source height must be positive.')
    }
    $copy = Copy-SnipAnnotation -Annotation $Annotation
    $geometry = $copy.Geometry
    $boundsHandles = @('TopLeft','Top','TopRight','Right','BottomRight','Bottom','BottomLeft','Left')
    $clampCoordinate = {
        param([long]$Value, [long]$Maximum)
        [int][math]::Max(0L, [math]::Min($Maximum, $Value))
    }.GetNewClosure()
    $normalizePointGeometry = {
        param(
            [AllowNull()][AllowEmptyCollection()][object[]]$Points,
            [Parameter(Mandatory)][string]$Label
        )

        if ($null -eq $Points -or $Points.Count -eq 0) {
            throw [ArgumentException]::new(
                "$Label geometry must contain points.", 'Annotation')
        }
        $minimumX = [int]$Points[0].X
        $maximumX = $minimumX
        $minimumY = [int]$Points[0].Y
        $maximumY = $minimumY
        for ($index = 1; $index -lt $Points.Count; $index++) {
            $pointX = [int]$Points[$index].X
            $pointY = [int]$Points[$index].Y
            $minimumX = [math]::Min($minimumX, $pointX)
            $maximumX = [math]::Max($maximumX, $pointX)
            $minimumY = [math]::Min($minimumY, $pointY)
            $maximumY = [math]::Max($maximumY, $pointY)
        }
        $spanX = [long]$maximumX - [long]$minimumX
        $spanY = [long]$maximumY - [long]$minimumY
        if (($spanX -eq 0 -and $spanY -eq 0) -or
            $spanX -gt ($SourceWidth - 1) -or $spanY -gt ($SourceHeight - 1)) {
            throw [ArgumentException]::new(
                "$Label geometry must have positive extent and fit inside the source.",
                'Annotation')
        }

        $shiftX = 0L
        if ($minimumX -lt 0) {
            $shiftX = -[long]$minimumX
        } elseif ($maximumX -gt ($SourceWidth - 1)) {
            $shiftX = [long]($SourceWidth - 1) - [long]$maximumX
        }
        $shiftY = 0L
        if ($minimumY -lt 0) {
            $shiftY = -[long]$minimumY
        } elseif ($maximumY -gt ($SourceHeight - 1)) {
            $shiftY = [long]($SourceHeight - 1) - [long]$maximumY
        }
        foreach ($point in $Points) {
            $point.X = [int]([long]$point.X + $shiftX)
            $point.Y = [int]([long]$point.Y + $shiftY)
        }

        [pscustomobject]@{
            Points = $Points
            MinimumX = [int]([long]$minimumX + $shiftX)
            MaximumX = [int]([long]$maximumX + $shiftX)
            MinimumY = [int]([long]$minimumY + $shiftY)
            MaximumY = [int]([long]$maximumY + $shiftY)
        }
    }.GetNewClosure()

    if ([string]$geometry.Type -in @('Bounds','TextBounds','StepBounds')) {
        if ($Handle -notin $boundsHandles) {
            throw [ArgumentException]::new("Handle '$Handle' cannot resize $($geometry.Type) geometry.", 'Handle')
        }
        $width = [int]$geometry.Width
        $height = [int]$geometry.Height
        if ($width -le 0 -or $height -le 0 -or
            $width -gt $SourceWidth -or $height -gt $SourceHeight) {
            throw [ArgumentException]::new(
                'Bounds geometry must have positive dimensions no larger than the source.',
                'Annotation')
        }
        # Shift the intact starting rectangle inside the source before applying
        # a handle delta, including axes whose edges remain stationary.
        $left = [int][math]::Max(0, [math]::Min($SourceWidth - $width, [int]$geometry.X))
        $top = [int][math]::Max(0, [math]::Min($SourceHeight - $height, [int]$geometry.Y))
        $right = $left + $width
        $bottom = $top + $height
        $movesLeft = $Handle -in @('TopLeft','Left','BottomLeft')
        $movesRight = $Handle -in @('TopRight','Right','BottomRight')
        $movesTop = $Handle -in @('TopLeft','Top','TopRight')
        $movesBottom = $Handle -in @('BottomLeft','Bottom','BottomRight')
        if ($movesLeft) {
            $left = & $clampCoordinate ([long]$left + [long]$DeltaX) ([long]$SourceWidth)
        }
        if ($movesRight) {
            $right = & $clampCoordinate ([long]$right + [long]$DeltaX) ([long]$SourceWidth)
        }
        if ($movesTop) {
            $top = & $clampCoordinate ([long]$top + [long]$DeltaY) ([long]$SourceHeight)
        }
        if ($movesBottom) {
            $bottom = & $clampCoordinate ([long]$bottom + [long]$DeltaY) ([long]$SourceHeight)
        }

        if ($left -eq $right) {
            if ($movesLeft) {
                $normalizedLeft = [math]::Max(0, $right - 1)
                $normalizedRight = $normalizedLeft + 1
            } else {
                $normalizedLeft = [math]::Min($SourceWidth - 1, $left)
                $normalizedRight = $normalizedLeft + 1
            }
        } else {
            $normalizedLeft = [math]::Min($left, $right)
            $normalizedRight = [math]::Max($left, $right)
        }
        if ($top -eq $bottom) {
            if ($movesTop) {
                $normalizedTop = [math]::Max(0, $bottom - 1)
                $normalizedBottom = $normalizedTop + 1
            } else {
                $normalizedTop = [math]::Min($SourceHeight - 1, $top)
                $normalizedBottom = $normalizedTop + 1
            }
        } else {
            $normalizedTop = [math]::Min($top, $bottom)
            $normalizedBottom = [math]::Max($top, $bottom)
        }
        $geometry.X = [int]$normalizedLeft
        $geometry.Y = [int]$normalizedTop
        $geometry.Width = [int][math]::Max(1, $normalizedRight - $normalizedLeft)
        $geometry.Height = [int][math]::Max(1, $normalizedBottom - $normalizedTop)
        return $copy
    }

    if ([string]$geometry.Type -eq 'Line') {
        if ($Handle -notin @('Start','End')) {
            throw [ArgumentException]::new("Handle '$Handle' cannot resize Line geometry.", 'Handle')
        }
        [void](& $normalizePointGeometry -Points @($geometry.Start, $geometry.End) -Label Line)
        $point = if ($Handle -eq 'Start') { $geometry.Start } else { $geometry.End }
        $point.X = & $clampCoordinate ([long]$point.X + [long]$DeltaX) ([long]($SourceWidth - 1))
        $point.Y = & $clampCoordinate ([long]$point.Y + [long]$DeltaY) ([long]($SourceHeight - 1))
        [void](& $normalizePointGeometry -Points @($geometry.Start, $geometry.End) -Label Line)
        return $copy
    }

    if ([string]$geometry.Type -eq 'Points') {
        if ($Handle -notin $boundsHandles) {
            throw [ArgumentException]::new("Handle '$Handle' cannot resize Points geometry.", 'Handle')
        }
        $normalized = & $normalizePointGeometry -Points @($geometry.Points) -Label Points
        $points = @($normalized.Points)
        $minimumX = [double]$normalized.MinimumX
        $maximumX = [double]$normalized.MaximumX
        $minimumY = [double]$normalized.MinimumY
        $maximumY = [double]$normalized.MaximumY
        $movesLeft = $Handle -in @('TopLeft','Left','BottomLeft')
        $movesRight = $Handle -in @('TopRight','Right','BottomRight')
        $movesTop = $Handle -in @('TopLeft','Top','TopRight')
        $movesBottom = $Handle -in @('BottomLeft','Bottom','BottomRight')

        $anchorX = if ($movesLeft) { $maximumX } else { $minimumX }
        $movingOriginalX = if ($movesLeft) { $minimumX } else { $maximumX }
        $movingNewX = if ($movesLeft -or $movesRight) {
            & $clampCoordinate ([long]$movingOriginalX + [long]$DeltaX) ([long]($SourceWidth - 1))
        } else { $movingOriginalX }
        $anchorY = if ($movesTop) { $maximumY } else { $minimumY }
        $movingOriginalY = if ($movesTop) { $minimumY } else { $maximumY }
        $movingNewY = if ($movesTop -or $movesBottom) {
            & $clampCoordinate ([long]$movingOriginalY + [long]$DeltaY) ([long]($SourceHeight - 1))
        } else { $movingOriginalY }

        foreach ($point in $points) {
            if ($movesLeft -or $movesRight) {
                $ratioX = if ($movingOriginalX -eq $anchorX) { 0.0 } else {
                    ([double]$point.X - $anchorX) / ($movingOriginalX - $anchorX)
                }
                $scaledX = $anchorX + ($ratioX * ($movingNewX - $anchorX))
                $point.X = [int][math]::Max(0, [math]::Min($SourceWidth - 1,
                    [math]::Round($scaledX, 0, [MidpointRounding]::AwayFromZero)))
            }
            if ($movesTop -or $movesBottom) {
                $ratioY = if ($movingOriginalY -eq $anchorY) { 0.0 } else {
                    ([double]$point.Y - $anchorY) / ($movingOriginalY - $anchorY)
                }
                $scaledY = $anchorY + ($ratioY * ($movingNewY - $anchorY))
                $point.Y = [int][math]::Max(0, [math]::Min($SourceHeight - 1,
                    [math]::Round($scaledY, 0, [MidpointRounding]::AwayFromZero)))
            }
        }
        [void](& $normalizePointGeometry -Points $points -Label Points)
        return $copy
    }

    # Unknown future geometry is copied but intentionally not transformed.
    $copy
}

function Get-SnipCropRectangle {
    [CmdletBinding()]
    param(
        [AllowNull()] $Candidate,
        [Parameter(Mandatory)] [int]$SourceWidth,
        [Parameter(Mandatory)] [int]$SourceHeight,
        [ValidateSet('Free','Original','1:1','4:3','16:9')] [string]$Preset = 'Free'
    )

    if ($SourceWidth -le 0) {
        throw [ArgumentOutOfRangeException]::new('SourceWidth', 'Source width must be positive.')
    }
    if ($SourceHeight -le 0) {
        throw [ArgumentOutOfRangeException]::new('SourceHeight', 'Source height must be positive.')
    }
    $toIntegerRectangle = {
        param([double]$RectX, [double]$RectY, [double]$RectWidth, [double]$RectHeight)
        $integerX = [int][math]::Round($RectX, 0, [MidpointRounding]::AwayFromZero)
        $integerY = [int][math]::Round($RectY, 0, [MidpointRounding]::AwayFromZero)
        $integerWidth = [int][math]::Round($RectWidth, 0, [MidpointRounding]::AwayFromZero)
        $integerHeight = [int][math]::Round($RectHeight, 0, [MidpointRounding]::AwayFromZero)
        if ($integerWidth -le 0 -or $integerHeight -le 0 -or
            $integerX -ge $SourceWidth -or $integerY -ge $SourceHeight) {
            return $null
        }
        $integerX = [int][math]::Max(0, $integerX)
        $integerY = [int][math]::Max(0, $integerY)
        $integerWidth = [int][math]::Min($integerWidth, $SourceWidth - $integerX)
        $integerHeight = [int][math]::Min($integerHeight, $SourceHeight - $integerY)
        if ($integerWidth -le 0 -or $integerHeight -le 0) { return $null }
        [pscustomobject][ordered]@{
            X=$integerX; Y=$integerY; Width=$integerWidth; Height=$integerHeight
        }
    }.GetNewClosure()

    $usedFullSource = $null -eq $Candidate
    if ($usedFullSource) {
        $left = 0
        $top = 0
        $right = $SourceWidth
        $bottom = $SourceHeight
    } else {
        $candidateX = [double](Get-SnipRecordValue -InputObject $Candidate -Name X -Required)
        $candidateY = [double](Get-SnipRecordValue -InputObject $Candidate -Name Y -Required)
        $candidateWidth = [double](Get-SnipRecordValue -InputObject $Candidate -Name Width -Required)
        $candidateHeight = [double](Get-SnipRecordValue -InputObject $Candidate -Name Height -Required)
        if ($candidateWidth -eq 0 -or $candidateHeight -eq 0) { return $null }
        $candidateRight = $candidateX + $candidateWidth
        $candidateBottom = $candidateY + $candidateHeight
        # Keep the clamp in floating-point space. Mixing integer and double
        # arguments makes PowerShell bind Math.Min/Max to an integer overload,
        # which truncates midpoint coordinates before the explicit rounding step.
        $left = [math]::Max(0.0, [math]::Min($candidateX, $candidateRight))
        $top = [math]::Max(0.0, [math]::Min($candidateY, $candidateBottom))
        $right = [math]::Min([double]$SourceWidth, [math]::Max($candidateX, $candidateRight))
        $bottom = [math]::Min([double]$SourceHeight, [math]::Max($candidateY, $candidateBottom))
    }
    $width = [double]($right - $left)
    $height = [double]($bottom - $top)
    if ($width -le 0 -or $height -le 0) { return $null }

    if ($Preset -eq 'Free') {
        return & $toIntegerRectangle $left $top $width $height
    }

    $isPortrait = if ($usedFullSource) {
        $SourceHeight -gt $SourceWidth
    } else {
        $height -gt $width
    }
    $targetAspect = switch ($Preset) {
        'Original' { [double]$SourceWidth / [double]$SourceHeight }
        '1:1' { 1.0 }
        '4:3' { if ($isPortrait) { 3.0 / 4.0 } else { 4.0 / 3.0 } }
        '16:9' { if ($isPortrait) { 9.0 / 16.0 } else { 16.0 / 9.0 } }
    }
    $currentAspect = [double]$width / [double]$height
    if ($currentAspect -gt $targetAspect) {
        $targetHeight = $height
        $targetWidth = [int][math]::Round($targetHeight * $targetAspect, 0,
            [MidpointRounding]::AwayFromZero)
    } else {
        $targetWidth = $width
        $targetHeight = [int][math]::Round($targetWidth / $targetAspect, 0,
            [MidpointRounding]::AwayFromZero)
    }
    $targetWidth = [int][math]::Max(1, [math]::Min($width, $targetWidth))
    $targetHeight = [int][math]::Max(1, [math]::Min($height, $targetHeight))
    $offsetX = [int][math]::Round(($width - $targetWidth) / 2.0, 0,
        [MidpointRounding]::AwayFromZero)
    $offsetY = [int][math]::Round(($height - $targetHeight) / 2.0, 0,
        [MidpointRounding]::AwayFromZero)
    & $toIntegerRectangle ($left + $offsetX) ($top + $offsetY) $targetWidth $targetHeight
}

function Set-SnipCrop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Apply','Reset')] [string]$Action,
        [AllowNull()] $Candidate,
        [Parameter(Mandatory)] [int]$SourceWidth,
        [Parameter(Mandatory)] [int]$SourceHeight,
        [ValidateSet('Free','Original','1:1','4:3','16:9')] [string]$Preset = 'Free'
    )

    if ($Action -eq 'Reset') { return $null }
    Get-SnipCropRectangle -Candidate $Candidate -SourceWidth $SourceWidth `
        -SourceHeight $SourceHeight -Preset $Preset
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

function Test-IsSelfWindowHandle {
    # True when $Hwnd is one of SnipIT's own registered window handles.
    # Used by the window-capture path to avoid snapshotting our own UI
    # when the foreground window is SnipIT (tray balloon, widget, preview).
    param(
        [AllowNull()] $Hwnd,
        [AllowNull()][AllowEmptyCollection()] $SelfWindowHandles
    )
    if ($null -eq $Hwnd) { return $false }
    if ($Hwnd -eq 0) { return $false }
    if ($null -eq $SelfWindowHandles) { return $false }
    foreach ($h in @($SelfWindowHandles)) {
        if ($null -eq $h) { continue }
        if ($h -eq 0) { continue }
        if ($h -eq $Hwnd) { return $true }
    }
    return $false
}

function Resolve-WindowCaptureTarget {
    # Pure decision layer for active-window capture. Returns the HWND we
    # should capture, or $null to signal "skip this target, caller should
    # fall back (typically to the full virtual desktop)".
    #
    # - No foreground window (zero handle)      => $null
    # - Foreground belongs to SnipIT          => $null  (self-capture guard)
    # - Anything else                         => the HWND unchanged
    param(
        [AllowNull()] $ForegroundHwnd,
        [AllowNull()][AllowEmptyCollection()] $SelfWindowHandles
    )
    if ($null -eq $ForegroundHwnd) { return $null }
    if ($ForegroundHwnd -eq 0) { return $null }
    if (Test-IsSelfWindowHandle -Hwnd $ForegroundHwnd -SelfWindowHandles $SelfWindowHandles) {
        return $null
    }
    return $ForegroundHwnd
}

function Invoke-CaptureLoop {
    # Pure orchestration for the capture/preview/"New snip" loop.
    #
    # Contract (important — this encodes the capture-ownership invariant):
    # The preview window takes ownership of the capture it receives and
    # disposes it on close. The loop therefore MUST call $CaptureFactory
    # on every iteration to produce a fresh capture. A disposed capture
    # is never passed back into $PreviewHandler.
    #
    # Parameters:
    #   CaptureFactory   scriptblock () -> capture handle (or $null to abort the loop)
    #   PreviewHandler   scriptblock ($capture) -> $true to loop again, $false to exit
    #   MaxIterations    safety cap in case PreviewHandler always returns $true
    #
    # Returns the number of preview iterations actually run.
    param(
        [Parameter(Mandatory)] [scriptblock]$CaptureFactory,
        [Parameter(Mandatory)] [scriptblock]$PreviewHandler,
        [int]$MaxIterations = 32
    )
    $iterations = 0
    while ($iterations -lt $MaxIterations) {
        $capture = & $CaptureFactory
        if ($null -eq $capture) { break }
        $iterations++
        $again = & $PreviewHandler $capture
        if (-not $again) { break }
    }
    return $iterations
}

function Get-SnipContrastRatio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Foreground,
        [Parameter(Mandatory)] [string]$Background
    )

    function ConvertFrom-SnipHexColor {
        param([Parameter(Mandatory)] [string]$Hex)

        $value = $Hex.TrimStart('#')
        if ($value.Length -eq 8) {
            $alpha = [Convert]::ToInt32($value.Substring(0, 2), 16) / 255.0
            $offset = 2
        } elseif ($value.Length -eq 6) {
            $alpha = 1.0
            $offset = 0
        } else {
            throw [ArgumentException]::new('Expected #RRGGBB or #AARRGGBB')
        }
        $rgb = 0, 2, 4 | ForEach-Object {
            [Convert]::ToInt32($value.Substring($offset + $_, 2), 16)
        }
        [pscustomobject]@{ Alpha = $alpha; R = $rgb[0]; G = $rgb[1]; B = $rgb[2] }
    }

    function Get-RelativeLuminance {
        param([Parameter(Mandatory)] [double[]]$Rgb)

        $channels = $Rgb | ForEach-Object {
            $channel = $_ / 255.0
            if ($channel -le 0.03928) {
                $channel / 12.92
            } else {
                [math]::Pow(($channel + 0.055) / 1.055, 2.4)
            }
        }
        0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
    }

    $foregroundColor = ConvertFrom-SnipHexColor -Hex $Foreground
    $backgroundColor = ConvertFrom-SnipHexColor -Hex $Background
    $composite = @(
        $foregroundColor.R * $foregroundColor.Alpha + $backgroundColor.R * (1 - $foregroundColor.Alpha)
        $foregroundColor.G * $foregroundColor.Alpha + $backgroundColor.G * (1 - $foregroundColor.Alpha)
        $foregroundColor.B * $foregroundColor.Alpha + $backgroundColor.B * (1 - $foregroundColor.Alpha)
    )
    $foregroundLuminance = Get-RelativeLuminance -Rgb $composite
    $backgroundLuminance = Get-RelativeLuminance -Rgb @(
        $backgroundColor.R, $backgroundColor.G, $backgroundColor.B
    )
    [math]::Round(
        ([math]::Max($foregroundLuminance, $backgroundLuminance) + 0.05) /
        ([math]::Min($foregroundLuminance, $backgroundLuminance) + 0.05),
        2
    )
}

# Splits one colour into its four channels. -Color takes anything exposing byte
# A/R/G/B -- a WPF Color, a Drawing Color, a pscustomobject -- or a '#RRGGBB' /
# '#AARRGGBB' string, so every colour helper below stays arithmetic on integers
# and stays testable on a machine with no WPF.
#
# The result carries both spellings back: .Hex is '#AARRGGBB' for round-tripping
# a whole colour, .Rgb is '#RRGGBB' for identity comparisons where alpha is not
# part of the question -- which is how the accent swap recognises a colour as a
# member of the accent family whatever transparency the key applies to it.
function Get-SnipColorChannels {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)] $Color)

    if ($Color -is [string]) {
        $value = $Color.TrimStart('#')
        if ($value.Length -eq 8) {
            $alpha = [Convert]::ToInt32($value.Substring(0, 2), 16)
            $offset = 2
        } elseif ($value.Length -eq 6) {
            $alpha = 255
            $offset = 0
        } else {
            throw [ArgumentException]::new('Expected #RRGGBB or #AARRGGBB')
        }
        $channels = 0, 2, 4 | ForEach-Object {
            [Convert]::ToInt32($value.Substring($offset + $_, 2), 16)
        }
        $red, $green, $blue = $channels
    } else {
        $malformed = [ArgumentException]::new(
            'Expected a colour with A/R/G/B bytes or a #RRGGBB / #AARRGGBB string')
        if ($null -eq $Color) { throw $malformed }
        $members = $Color.psobject.Properties
        foreach ($channel in 'A', 'R', 'G', 'B') {
            if ($null -eq $members[$channel]) { throw $malformed }
        }
        try {
            $alpha = [int]$Color.A
            $red = [int]$Color.R
            $green = [int]$Color.G
            $blue = [int]$Color.B
        } catch { throw $malformed }
    }
    foreach ($channel in $alpha, $red, $green, $blue) {
        if ($channel -lt 0 -or $channel -gt 255) {
            throw [ArgumentException]::new('Colour channels must be 0..255')
        }
    }

    [pscustomobject]@{
        A = $alpha
        R = $red
        G = $green
        B = $blue
        Hex = ('#{0:X2}{1:X2}{2:X2}{3:X2}' -f $alpha, $red, $green, $blue)
        Rgb = ('#{0:X2}{1:X2}{2:X2}' -f $red, $green, $blue)
    }
}

# Collapses one colour onto the neutral grey axis. Alpha and perceived weight
# survive; hue does not. Rec.601 luma is the weight, so a surface keeps the same
# apparent lightness after the hue is removed and layered translucent fills keep
# stacking the way Fluent intends.
#
# Two snaps ride on top, and only for fully opaque colours: a near-black surface
# lands on #000000 and a near-white one on #FFFFFF, so the Dark ground really is
# black and the Light ground really is white instead of an almost-black or
# almost-white grey. Translucent fills are never snapped -- they composite over
# whatever is beneath them and snapping would change their weight.
#
# -Color takes anything exposing byte A/R/G/B (a WPF Color) or a '#RRGGBB' /
# '#AARRGGBB' string, so the arithmetic stays testable on a machine with no WPF.
function Get-SnipNeutralColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] $Color,
        [ValidateRange(0, 127)] [int]$BlackSnap = 10,
        [ValidateRange(128, 255)] [int]$WhiteSnap = 245
    )

    $channels = Get-SnipColorChannels -Color $Color
    $alpha = $channels.A

    $level = [int][math]::Round(
        0.299 * $channels.R + 0.587 * $channels.G + 0.114 * $channels.B)
    if ($level -lt 0) { $level = 0 } elseif ($level -gt 255) { $level = 255 }
    if ($alpha -eq 255) {
        if ($level -le $BlackSnap) {
            $level = 0
        } elseif ($level -ge $WhiteSnap) {
            $level = 255
        }
    }

    [pscustomobject]@{
        A = $alpha
        R = $level
        G = $level
        B = $level
        Level = $level
        Hex = ('#{0:X2}{1:X2}{1:X2}{1:X2}' -f $alpha, $level)
    }
}

# SnipIT's accent: Windows' own standard red, fixed rather than inherited.
#
# Everything else in the chrome is black, white and grey (see
# Set-SnipNeutralSurfaces), so the accent is the single colour the app spends,
# and it is spent on one thing: what is currently active or about to happen.
# Pinning it means a screenshot of SnipIT looks like SnipIT on any machine
# instead of taking on whatever hue the user set for the taskbar.
$script:SnipAccentBaseHex = '#E81123'

# The accent family, darkest to lightest. Windows derives six tints either side
# of the base and every Fluent accent key is one of these seven; keeping them in
# ladder order is what lets the swap below move a whole family by index.
$script:SnipAccentVariantOrder = @(
    'Dark3', 'Dark2', 'Dark1', 'Base', 'Light1', 'Light2', 'Light3')

# The Fluent keys that paint ink *on* an accent fill rather than the fill itself.
# Their value is not an accent colour -- it is the black or white Windows picked
# to read against the accent -- so they are matched by name, not by value.
$script:SnipOnAccentInkKeyPrefixes = @(
    'TextOnAccentFillColor'
    'AccentButtonForeground')

# Mixes a colour toward white or black by -Amount, which is how the Windows
# accent tints are derived: Light1/2/3 are the base mixed with white at
# 20 / 40 / 60 %, and Dark1/2/3 the same mix with black. Alpha rides along
# untouched, and each channel is rounded away from zero so the ladder is
# symmetric about the base rather than drifting on .5 like banker's rounding.
#
# Windows itself blends in a perceptual space, so a computed tint lands a level
# or two off the shell's own for the same base. The ratios are what matter --
# an evenly spaced ladder either side of the base -- and computing them keeps
# the palette a function of one hex instead of seven hardcoded literals.
function Get-SnipAccentTint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] $Color,
        [Parameter(Mandatory, Position = 1)]
        [ValidateSet('White', 'Black')] [string]$Toward,
        [Parameter(Mandatory, Position = 2)]
        [ValidateRange(0.0, 1.0)] [double]$Amount
    )

    $channels = Get-SnipColorChannels -Color $Color
    $ceiling = if ($Toward -eq 'White') { 255 } else { 0 }
    $mix = {
        param([int]$Value)
        $mixed = [int][math]::Round($Value + ($ceiling - $Value) * $Amount,
            [MidpointRounding]::AwayFromZero)
        if ($mixed -lt 0) { 0 } elseif ($mixed -gt 255) { 255 } else { $mixed }
    }
    Get-SnipColorChannels -Color ('#{0:X2}{1:X2}{2:X2}{3:X2}' -f $channels.A,
        (& $mix $channels.R), (& $mix $channels.G), (& $mix $channels.B))
}

# The whole accent palette derived from one base: Base, Light1-3, Dark1-3 and
# the ink that goes on top of them.
#
# OnAccent is pure white in both themes and is not derived. Stock Fluent flips
# to black ink when the ambient accent is a light one, which is the right call
# for a colour it does not control; a fixed red is dark at every tint the chrome
# actually fills with, so white is the legible answer in Dark and in Light and
# picking it per-mode would only produce black text on a red button.
function Get-SnipAccentPalette {
    [CmdletBinding()]
    param([Parameter(Position = 0)] $Base = $script:SnipAccentBaseHex)

    $anchor = Get-SnipColorChannels -Color $Base
    $palette = [ordered]@{ Base = $anchor }
    foreach ($step in 1, 2, 3) {
        $amount = $step * 0.2
        $palette["Light$step"] = Get-SnipAccentTint -Color $anchor -Toward White -Amount $amount
        $palette["Dark$step"] = Get-SnipAccentTint -Color $anchor -Toward Black -Amount $amount
    }
    $palette['OnAccent'] = Get-SnipColorChannels -Color '#FFFFFFFF'
    [pscustomobject]$palette
}

# Builds the lookup that turns one accent family into another.
#
# -Source is the family being replaced: variant name -> colour, normally the
# Windows accent and its six tints. Every colour Fluent baked into its accent
# keys is one of those seven values, so recognising them by value finds every
# accent use in the theme without a hand-maintained list of resource keys.
#
# -Anchor names the source variant the theme is currently using as its primary
# accent fill: stock Fluent picks Dark1 in Light mode and Light2 in Dark mode so
# that its own ink reads against it. The ladder is shifted so that variant lands
# on the red base, and the rest of the family keeps its relative position and
# clamps at the ends. That is what makes the Copy & close button the same red in
# both themes while the tints around it stay ordered the way Fluent expects --
# a straight variant-for-variant swap would instead hand Dark mode a pale pink
# button and Light mode a maroon one.
function Get-SnipAccentMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Source,
        $Palette = (Get-SnipAccentPalette),
        [string]$Anchor = 'Base'
    )

    $order = $script:SnipAccentVariantOrder
    $baseIndex = [array]::IndexOf($order, 'Base')
    $anchorIndex = [array]::IndexOf($order, $Anchor)
    if ($anchorIndex -lt 0) { $anchorIndex = $baseIndex }
    $shift = $baseIndex - $anchorIndex

    $variants = [ordered]@{}
    $colors = [ordered]@{}
    foreach ($name in $order) {
        $value = $null
        if ($Source -is [System.Collections.IDictionary]) {
            if ($Source.Contains($name)) { $value = $Source[$name] }
        } elseif ($null -ne $Source -and $null -ne $Source.psobject.Properties[$name]) {
            $value = $Source.$name
        }
        if ($null -eq $value) { continue }
        $index = [array]::IndexOf($order, $name) + $shift
        if ($index -lt 0) {
            $index = 0
        } elseif ($index -ge $order.Count) {
            $index = $order.Count - 1
        }
        $target = $Palette.($order[$index])
        $variants[$name] = $target
        $from = (Get-SnipColorChannels -Color $value).Rgb
        if (-not $colors.Contains($from)) { $colors[$from] = $target }
    }
    # The ink rides in the same table so a caller needs one object, not two.
    $variants['OnAccent'] = $Palette.OnAccent

    [pscustomobject]@{
        Anchor = $order[$anchorIndex]
        Shift = $shift
        Variants = $variants
        Colors = $colors
    }
}

# Decides what one themed colour becomes under an accent swap, and returns
# $null when it becomes nothing -- which is the answer for every neutral in the
# dictionary, so a caller can walk thousands of keys and touch only the accent.
#
# Alpha always survives: Fluent tints many accent keys down to a wash, and
# replacing the colour without keeping the transparency would turn a hover
# highlight into a solid block.
function Get-SnipAccentReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string]$Key,
        [Parameter(Mandatory, Position = 1)] $Color,
        [Parameter(Mandatory)] $Map
    )

    $channels = Get-SnipColorChannels -Color $Color
    $target = $null
    foreach ($prefix in $script:SnipOnAccentInkKeyPrefixes) {
        if ($Key.StartsWith($prefix, [StringComparison]::Ordinal)) {
            $target = $Map.Variants['OnAccent']
            break
        }
    }
    if ($null -eq $target) {
        $table = $Map.Colors
        if ($table -is [System.Collections.IDictionary] -and $table.Contains($channels.Rgb)) {
            $target = $table[$channels.Rgb]
        }
    }
    if ($null -eq $target) { return $null }

    $replacement = '#{0:X2}{1:X2}{2:X2}{3:X2}' -f $channels.A, $target.R, $target.G, $target.B
    if ($replacement -eq $channels.Hex) { return $null }
    $replacement
}

function Get-SnipDefaultSettings {
    param([string]$PicturesDir = [Environment]::GetFolderPath('MyPictures'))

    [pscustomobject][ordered]@{
        Version = 1
        Hotkey = [pscustomobject][ordered]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        SaveFolder = Join-Path $PicturesDir 'Snips'
        SaveFormat = 'Png'
        LaunchAtSignIn = $true
        WidgetVisible = $false
    }
}

function Test-SnipSettingsUnchanged {
    # Decides whether a settings write can be skipped. Save-SnipSettings runs on
    # every launch, and rewriting an identical file only bumps the mtime, churns
    # the disk and makes "when did settings last change?" unanswerable.
    #
    # Existing is the raw on-disk text ($null when the file is absent); Candidate
    # is the JSON we are about to write. Set-Content appends a line terminator
    # that ConvertTo-Json never produces, so trailing newlines are not a
    # difference — but any other byte is, and rewriting then restores the
    # canonical form on the next launch.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [string]$Existing,
        [AllowNull()] [AllowEmptyString()] [string]$Candidate
    )

    if ($null -eq $Existing -or $null -eq $Candidate) { return $false }
    return [string]::Equals(
        $Existing.TrimEnd("`r", "`n"),
        $Candidate.TrimEnd("`r", "`n"),
        [System.StringComparison]::Ordinal)
}

function Test-SnipHotkeyDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Modifiers,
        [Parameter(Mandatory)] [int]$VirtualKey
    )

    $knownModifiers = 0x4007
    if (($Modifiers -band (-bnot $knownModifiers)) -ne 0) { return $false }
    if (($Modifiers -band 0x4000) -eq 0) { return $false }

    $chordModifierCount = 0
    foreach ($modifier in 0x1, 0x2, 0x4) {
        if (($Modifiers -band $modifier) -ne 0) { $chordModifierCount++ }
    }
    if ($chordModifierCount -lt 2) { return $false }

    return $VirtualKey -eq 0x20 -or
        ($VirtualKey -ge 0x30 -and $VirtualKey -le 0x39) -or
        ($VirtualKey -ge 0x41 -and $VirtualKey -le 0x5A) -or
        ($VirtualKey -ge 0x70 -and $VirtualKey -le 0x87)
}

function Format-SnipHotkey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Modifiers,
        [Parameter(Mandatory)] [int]$VirtualKey
    )

    if (-not (Test-SnipHotkeyDefinition -Modifiers $Modifiers -VirtualKey $VirtualKey)) {
        throw [ArgumentException]::new('The hotkey definition is not supported.')
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if (($Modifiers -band 0x2) -ne 0) { $parts.Add('Ctrl') }
    if (($Modifiers -band 0x1) -ne 0) { $parts.Add('Alt') }
    if (($Modifiers -band 0x4) -ne 0) { $parts.Add('Shift') }

    $keyText = if ($VirtualKey -eq 0x20) {
        'Space'
    } elseif ($VirtualKey -ge 0x30 -and $VirtualKey -le 0x39) {
        [string][char]$VirtualKey
    } elseif ($VirtualKey -ge 0x41 -and $VirtualKey -le 0x5A) {
        [string][char]$VirtualKey
    } else {
        'F{0}' -f ($VirtualKey - 0x6F)
    }
    $parts.Add($keyText)
    $parts -join '+'
}

function Get-PreviewResponsiveMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$Width,
        [Parameter(Mandatory)] [double]$Height
    )

    if ($Width -lt 900 -or $Height -lt 600) { return 'Narrow' }
    if ($Width -lt 1200 -or $Height -lt 700) { return 'Compact' }
    'Wide'
}

function ConvertTo-SnipDipPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$PhysicalX,
        [Parameter(Mandatory)] [double]$PhysicalY,
        [Parameter(Mandatory)] [double]$MonitorPhysicalX,
        [Parameter(Mandatory)] [double]$MonitorPhysicalY,
        [Parameter(Mandatory)] [double]$ScaleX,
        [Parameter(Mandatory)] [double]$ScaleY
    )

    if ($ScaleX -le 0) {
        throw [ArgumentOutOfRangeException]::new('ScaleX', 'ScaleX must be greater than zero.')
    }
    if ($ScaleY -le 0) {
        throw [ArgumentOutOfRangeException]::new('ScaleY', 'ScaleY must be greater than zero.')
    }
    [pscustomobject][ordered]@{
        X = [double](($PhysicalX - $MonitorPhysicalX) / $ScaleX)
        Y = [double](($PhysicalY - $MonitorPhysicalY) / $ScaleY)
    }
}

function ConvertTo-SnipPhysicalPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$DipX,
        [Parameter(Mandatory)] [double]$DipY,
        [Parameter(Mandatory)] [double]$MonitorPhysicalX,
        [Parameter(Mandatory)] [double]$MonitorPhysicalY,
        [Parameter(Mandatory)] [double]$ScaleX,
        [Parameter(Mandatory)] [double]$ScaleY
    )

    if ($ScaleX -le 0) {
        throw [ArgumentOutOfRangeException]::new('ScaleX', 'ScaleX must be greater than zero.')
    }
    if ($ScaleY -le 0) {
        throw [ArgumentOutOfRangeException]::new('ScaleY', 'ScaleY must be greater than zero.')
    }
    [pscustomobject][ordered]@{
        X = [int][math]::Round(
            $MonitorPhysicalX + $DipX * $ScaleX,
            0,
            [MidpointRounding]::AwayFromZero
        )
        Y = [int][math]::Round(
            $MonitorPhysicalY + $DipY * $ScaleY,
            0,
            [MidpointRounding]::AwayFromZero
        )
    }
}

function Get-SnipMonitorDisplayName {
    # Turns whatever the EDID / display-config lookup produced into the label the
    # tray's Display submenu shows. EDID strings arrive NUL-padded out of a fixed
    # 13-byte descriptor block, so strip control characters before deciding
    # whether we actually got a name. The fallback is positional rather than
    # device-derived on purpose: '\\.\DISPLAY3' means nothing to a person, and
    # the menu appends each display's resolution to whatever we return here.
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$FriendlyName,
        [Parameter(Mandatory)] [int]$Index
    )

    $name = if ($null -eq $FriendlyName) { '' } else { [string]$FriendlyName }
    $name = ($name -replace '\p{C}', '').Trim()
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    'Display {0}' -f ($Index + 1)
}

function Get-SnipMonitorInstanceKey {
    # Normalizes the two spellings Windows uses for the same monitor instance so
    # a device-interface path can be matched against a WMI instance name:
    #
    #   \\?\DISPLAY#DEL4091#5&1a2b&0&UID4353#{e6f07b5f-...}   (EnumDisplayDevices)
    #   DISPLAY\DEL4091\5&1a2b&0&UID4353_0                    (WmiMonitorID)
    #
    # Both reduce to DISPLAY\DEL4091\5&1A2B&0&UID4353.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $key = ([string]$Value).Trim()
    $key = $key -replace '^\\\\[?.]\\', ''
    $key = $key -replace '#', '\'
    # The device-interface class GUID is the same for every monitor, so it
    # carries no identity — drop it rather than trying to match on it.
    $key = $key -replace '\\\{[0-9a-fA-F-]+\}\s*$', ''
    # WMI appends an output ordinal to the instance path; the interface path
    # does not have one.
    $key = $key -replace '_\d+$', ''
    $key.Trim('\').ToUpperInvariant()
}

function Get-SnipMonitorSortKey {
    # Orders monitors primary-first, then left-to-right, then top-to-bottom, so
    # the Display submenu reads the way the desks are actually arranged. Ties
    # fall back to the device id purely so the order is stable between calls.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Descriptor)

    [pscustomobject][ordered]@{
        PrimaryRank = if ([bool]$Descriptor.IsPrimary) { 0 } else { 1 }
        X = [int]$Descriptor.X
        Y = [int]$Descriptor.Y
        Id = [string]$Descriptor.Id
    }
}

function Sort-SnipMonitorDescriptors {
    # Puts monitors in the order a person would read them off the desk and gives
    # each one its final DisplayName.
    #
    # The naming has to happen after the sort, not before: the positional
    # fallback counts monitors in menu order, so 'Display 2' should mean the
    # second entry the user sees rather than whatever GDI happened to enumerate
    # second. A monitor that reported a real EDID name keeps it regardless.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Descriptors)

    $sorted = @($Descriptors | Sort-Object -Property `
        @{ Expression = { (Get-SnipMonitorSortKey -Descriptor $_).PrimaryRank } },
        @{ Expression = { (Get-SnipMonitorSortKey -Descriptor $_).X } },
        @{ Expression = { (Get-SnipMonitorSortKey -Descriptor $_).Y } },
        @{ Expression = { (Get-SnipMonitorSortKey -Descriptor $_).Id } })
    for ($index = 0; $index -lt $sorted.Count; $index++) {
        $descriptor = $sorted[$index]
        $existing = $descriptor.PSObject.Properties['DisplayName']
        $friendlyName = if ($null -ne $existing) { [string]$existing.Value } else { '' }
        $displayName = Get-SnipMonitorDisplayName -FriendlyName $friendlyName -Index $index
        if ($null -eq $existing) {
            $descriptor | Add-Member -NotePropertyName DisplayName -NotePropertyValue $displayName
        } else {
            $descriptor.DisplayName = $displayName
        }
        $descriptor
    }
}

function Get-SnipSizeChipPlacement {
    # Places the live "W x H px" chip against the bottom-right corner of the drag
    # rectangle, which is the corner the pointer is dragging, and flips it inside
    # the monitor when the chip would otherwise be clipped. Everything is in the
    # owning overlay's local DIPs.
    #
    # Preference order: just below the rectangle, then just above it, then tucked
    # inside its bottom edge for a selection that already fills the monitor.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$RectX,
        [Parameter(Mandatory)] [double]$RectY,
        [Parameter(Mandatory)] [double]$RectWidth,
        [Parameter(Mandatory)] [double]$RectHeight,
        [Parameter(Mandatory)] [double]$ChipWidth,
        [Parameter(Mandatory)] [double]$ChipHeight,
        [Parameter(Mandatory)] [double]$MonitorWidth,
        [Parameter(Mandatory)] [double]$MonitorHeight,
        [double]$Gap = 8
    )

    $rectBottom = $RectY + $RectHeight
    $below = $rectBottom + $Gap
    $above = $RectY - $ChipHeight - $Gap
    $edge = 'Below'
    $y = $below
    if ($below + $ChipHeight -gt $MonitorHeight) {
        if ($above -ge 0) {
            $y = $above
            $edge = 'Above'
        } else {
            $y = $rectBottom - $ChipHeight - $Gap
            $edge = 'Inside'
        }
    }
    $x = $RectX + $RectWidth - $ChipWidth
    $maxX = [math]::Max(0.0, $MonitorWidth - $ChipWidth)
    $maxY = [math]::Max(0.0, $MonitorHeight - $ChipHeight)
    [pscustomobject][ordered]@{
        X = [double][math]::Max(0.0, [math]::Min($maxX, $x))
        Y = [double][math]::Max(0.0, [math]::Min($maxY, $y))
        Edge = $edge
    }
}

function Test-SnipOverlayIdleTimeout {
    # The Smart overlay is a modal, always-on-top, full-desktop surface. If
    # something steals the foreground away from it — a UAC prompt, a session
    # switch, a remote-control tool grabbing focus — the overlay can be left
    # covering every monitor with no way for the user to reach it. This decides
    # when to give up: no input for the whole timeout AND no overlay window
    # holding the foreground.
    #
    # Both conditions are required. An idle overlay that still owns the
    # foreground is just a user who has not decided yet.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [datetime]$LastInputUtc,
        [Parameter(Mandatory)] [datetime]$NowUtc,
        [Parameter(Mandatory)] [timespan]$Timeout,
        [bool]$OverlayIsForeground = $true
    )

    if ($OverlayIsForeground) { return $false }
    if ($Timeout -le [timespan]::Zero) { return $false }
    ($NowUtc - $LastInputUtc) -ge $Timeout
}

function Get-SnipMonitorLayouts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$MonitorDescriptors
    )

    if ($null -eq $MonitorDescriptors -or $MonitorDescriptors.Count -eq 0) {
        throw [ArgumentException]::new(
            'At least one monitor descriptor is required.', 'MonitorDescriptors')
    }

    $layouts = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $MonitorDescriptors.Count; $index++) {
        $descriptor = $MonitorDescriptors[$index]
        if ($null -eq $descriptor) {
            throw [ArgumentException]::new(
                "Monitor descriptor at index $index is null.", 'MonitorDescriptors')
        }
        foreach ($propertyName in 'Id','X','Y','Width','Height','DpiX','DpiY') {
            if ($null -eq $descriptor.PSObject.Properties[$propertyName]) {
                throw [ArgumentException]::new(
                    "Monitor descriptor at index $index is missing '$propertyName'.",
                    'MonitorDescriptors')
            }
        }

        try {
            $id = [string]$descriptor.Id
            $physicalX = [double]$descriptor.X
            $physicalY = [double]$descriptor.Y
            $physicalWidth = [double]$descriptor.Width
            $physicalHeight = [double]$descriptor.Height
            $dpiX = [double]$descriptor.DpiX
            $dpiY = [double]$descriptor.DpiY
        } catch {
            throw [ArgumentException]::new(
                "Monitor descriptor at index $index contains a non-numeric coordinate, size, or DPI.",
                'MonitorDescriptors', $_.Exception)
        }

        if ([string]::IsNullOrWhiteSpace($id)) {
            throw [ArgumentException]::new(
                "Monitor descriptor at index $index has an empty Id.", 'MonitorDescriptors')
        }
        if (-not [double]::IsFinite($physicalX)) {
            throw [ArgumentOutOfRangeException]::new('X', 'X must be finite.')
        }
        if (-not [double]::IsFinite($physicalY)) {
            throw [ArgumentOutOfRangeException]::new('Y', 'Y must be finite.')
        }
        if (-not [double]::IsFinite($physicalWidth) -or $physicalWidth -le 0) {
            throw [ArgumentOutOfRangeException]::new('Width', 'Width must be greater than zero.')
        }
        if (-not [double]::IsFinite($physicalHeight) -or $physicalHeight -le 0) {
            throw [ArgumentOutOfRangeException]::new('Height', 'Height must be greater than zero.')
        }
        if (-not [double]::IsFinite($dpiX) -or $dpiX -le 0) {
            throw [ArgumentOutOfRangeException]::new('DpiX', 'DpiX must be greater than zero.')
        }
        if (-not [double]::IsFinite($dpiY) -or $dpiY -le 0) {
            throw [ArgumentOutOfRangeException]::new('DpiY', 'DpiY must be greater than zero.')
        }

        $physicalX = [int][math]::Round(
            $physicalX, 0, [MidpointRounding]::AwayFromZero)
        $physicalY = [int][math]::Round(
            $physicalY, 0, [MidpointRounding]::AwayFromZero)
        $physicalWidth = [int][math]::Round(
            $physicalWidth, 0, [MidpointRounding]::AwayFromZero)
        $physicalHeight = [int][math]::Round(
            $physicalHeight, 0, [MidpointRounding]::AwayFromZero)
        if ($physicalWidth -le 0) {
            throw [ArgumentOutOfRangeException]::new(
                'Width', 'Width must normalize to at least one physical pixel.')
        }
        if ($physicalHeight -le 0) {
            throw [ArgumentOutOfRangeException]::new(
                'Height', 'Height must normalize to at least one physical pixel.')
        }

        $scaleX = $dpiX / 96.0
        $scaleY = $dpiY / 96.0
        $isPrimaryProperty = $descriptor.PSObject.Properties['IsPrimary']
        $layouts.Add([pscustomobject][ordered]@{
            Id = $id
            Index = $index
            IsPrimary = if ($null -ne $isPrimaryProperty) {
                [bool]$isPrimaryProperty.Value
            } else {
                $false
            }
            PhysicalX = $physicalX
            PhysicalY = $physicalY
            PhysicalWidth = $physicalWidth
            PhysicalHeight = $physicalHeight
            PhysicalRight = $physicalX + $physicalWidth
            PhysicalBottom = $physicalY + $physicalHeight
            DpiX = $dpiX
            DpiY = $dpiY
            ScaleX = $scaleX
            ScaleY = $scaleY
            DipX = $physicalX / $scaleX
            DipY = $physicalY / $scaleY
            DipWidth = $physicalWidth / $scaleX
            DipHeight = $physicalHeight / $scaleY
            Descriptor = $descriptor
        })
    }

    $layouts
}

function Get-SnipOverlayIntersections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Rectangle,
        [Parameter(Mandatory)] [object[]]$MonitorLayouts
    )

    if ($null -eq $Rectangle) {
        throw [ArgumentNullException]::new('Rectangle')
    }
    foreach ($propertyName in 'X','Y','Width','Height') {
        if ($null -eq $Rectangle.PSObject.Properties[$propertyName]) {
            throw [ArgumentException]::new(
                "Selection rectangle is missing '$propertyName'.", 'Rectangle')
        }
    }
    try {
        $rectangleX = [double]$Rectangle.X
        $rectangleY = [double]$Rectangle.Y
        $rectangleWidth = [double]$Rectangle.Width
        $rectangleHeight = [double]$Rectangle.Height
    } catch {
        throw [ArgumentException]::new(
            'Selection rectangle contains a non-numeric coordinate or size.',
            'Rectangle', $_.Exception)
    }
    if (-not [double]::IsFinite($rectangleX) -or
        -not [double]::IsFinite($rectangleY) -or
        -not [double]::IsFinite($rectangleWidth) -or
        -not [double]::IsFinite($rectangleHeight)) {
        throw [ArgumentException]::new(
            'Selection rectangle coordinates and size must be finite.', 'Rectangle')
    }
    if ($rectangleWidth -le 0 -or $rectangleHeight -le 0) { return }

    $rectangleRight = $rectangleX + $rectangleWidth
    $rectangleBottom = $rectangleY + $rectangleHeight
    foreach ($layout in @($MonitorLayouts)) {
        if ($null -eq $layout) { continue }
        foreach ($propertyName in 'Id','Index','PhysicalX','PhysicalY',
            'PhysicalWidth','PhysicalHeight','ScaleX','ScaleY') {
            if ($null -eq $layout.PSObject.Properties[$propertyName]) {
                throw [ArgumentException]::new(
                    "Monitor layout is missing '$propertyName'.", 'MonitorLayouts')
            }
        }

        $left = [math]::Max($rectangleX, [double]$layout.PhysicalX)
        $top = [math]::Max($rectangleY, [double]$layout.PhysicalY)
        $right = [math]::Min(
            $rectangleRight,
            [double]$layout.PhysicalX + [double]$layout.PhysicalWidth)
        $bottom = [math]::Min(
            $rectangleBottom,
            [double]$layout.PhysicalY + [double]$layout.PhysicalHeight)
        if ($right -le $left -or $bottom -le $top) { continue }

        $localPhysicalX = $left - [double]$layout.PhysicalX
        $localPhysicalY = $top - [double]$layout.PhysicalY
        $physicalWidth = $right - $left
        $physicalHeight = $bottom - $top
        [pscustomobject][ordered]@{
            MonitorId = [string]$layout.Id
            MonitorIndex = [int]$layout.Index
            PhysicalX = $left
            PhysicalY = $top
            PhysicalWidth = $physicalWidth
            PhysicalHeight = $physicalHeight
            LocalPhysicalX = $localPhysicalX
            LocalPhysicalY = $localPhysicalY
            DipX = $localPhysicalX / [double]$layout.ScaleX
            DipY = $localPhysicalY / [double]$layout.ScaleY
            DipWidth = $physicalWidth / [double]$layout.ScaleX
            DipHeight = $physicalHeight / [double]$layout.ScaleY
        }
    }
}

function Get-SnipExportRectangle {
    # Resolves the source-pixel rectangle an export (Copy/Save) must cover.
    # No crop -> the whole bitmap; a crop -> the same clamp Get-SnipCropRectangle
    # already applies to editor state, so the flatten path stays a thin renderer
    # over a rectangle that is unit-testable without any GDI+ surface.
    # A degenerate crop (fully outside the source, or zero-sized) falls back to
    # the full bitmap rather than producing an unexportable empty image.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [AllowNull()] $CropRectangle
    )

    if ($Width -le 0) {
        throw [ArgumentOutOfRangeException]::new('Width', 'Width must be positive.')
    }
    if ($Height -le 0) {
        throw [ArgumentOutOfRangeException]::new('Height', 'Height must be positive.')
    }

    $fullSource = [pscustomobject][ordered]@{
        X = 0; Y = 0; Width = $Width; Height = $Height
    }
    if ($null -eq $CropRectangle) { return $fullSource }

    $clamped = Get-SnipCropRectangle -Candidate $CropRectangle `
        -SourceWidth $Width -SourceHeight $Height -Preset 'Free'
    if ($null -eq $clamped) { return $fullSource }
    $clamped
}

function ConvertTo-SnipCropLocalRect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Rectangle,
        [Parameter(Mandatory)] $Crop
    )

    if ($Rectangle.Width -le 0 -or $Rectangle.Height -le 0 -or
        $Crop.Width -le 0 -or $Crop.Height -le 0) {
        return $null
    }

    $intersectionLeft = [math]::Max([double]$Rectangle.X, [double]$Crop.X)
    $intersectionTop = [math]::Max([double]$Rectangle.Y, [double]$Crop.Y)
    $intersectionRight = [math]::Min(
        [double]$Rectangle.X + [double]$Rectangle.Width,
        [double]$Crop.X + [double]$Crop.Width
    )
    $intersectionBottom = [math]::Min(
        [double]$Rectangle.Y + [double]$Rectangle.Height,
        [double]$Crop.Y + [double]$Crop.Height
    )
    if ($intersectionRight -le $intersectionLeft -or $intersectionBottom -le $intersectionTop) {
        return $null
    }

    [pscustomobject][ordered]@{
        X = $intersectionLeft - [double]$Crop.X
        Y = $intersectionTop - [double]$Crop.Y
        Width = $intersectionRight - $intersectionLeft
        Height = $intersectionBottom - $intersectionTop
    }
}

function Resolve-PreviewKeyCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FocusedRole,
        [Parameter(Mandatory)] [hashtable]$EditorState,
        [Parameter(Mandatory)] [string]$Key,
        [AllowNull()][AllowEmptyCollection()] [string[]]$Modifiers = @()
    )

    $hasCtrl = @($Modifiers) -contains 'Ctrl'
    $hasShift = @($Modifiers) -contains 'Shift'
    $hasAlt = @($Modifiers) -contains 'Alt'

    if ($hasCtrl -and $hasShift -and $Key -eq 'C') { return 'CopyKeepOpen' }
    if ($hasAlt -and $Key -eq 'F4') { return 'ClosePreview' }
    if ($hasAlt -and $Key -eq 'Space') { return 'ShowSystemMenu' }

    if ($EditorState.PopupOpen -or $FocusedRole -eq 'Popup') {
        if ($Key -eq 'Escape') { return 'ClosePopup' }
        if ($Key -in 'Up', 'Down', 'Home', 'End', 'Enter') { return 'PopupNavigation' }
        return $null
    }

    if ($FocusedRole -eq 'TextEditor' -or $EditorState.EditingText) {
        if ($hasCtrl -and $Key -eq 'C') { return 'TextCopy' }
        if ($hasCtrl -and $Key -eq 'Enter') { return 'CommitText' }
        if ($Key -eq 'Escape') { return 'CancelTextEdit' }
        return 'TextInput'
    }

    if ($FocusedRole -eq 'PropertyEditor' -or $EditorState.EditingProperty) {
        if ($Key -eq 'Escape') { return 'CancelPropertyEdit' }
        return 'PropertyInput'
    }

    if ($FocusedRole -eq 'Button' -and @($Modifiers).Count -eq 0 -and
        $Key -in 'Space', 'Enter') {
        return 'ActivateFocusedButton'
    }
    if ($null -ne $EditorState.Draft -and $Key -eq 'Escape') { return 'CancelDraft' }
    if ($null -ne $EditorState.Draft -and $hasCtrl -and $Key -eq 'Z') { return $null }
    if ($null -ne $EditorState.SelectionId -and $Key -eq 'Escape') {
        return 'ClearSelection'
    }

    # Annotation movement/deletion belongs exclusively to the canvas focus
    # scope. Selection Escape is global after popup/editor/draft precedence so
    # it cannot fall through to tool deactivation or window close.
    if ($FocusedRole -eq 'Canvas' -and $null -ne $EditorState.SelectionId) {
        if ($Key -eq 'Delete') { return 'DeleteSelection' }
        if ($Key -in 'Left', 'Right', 'Up', 'Down') {
            $direction = switch ($Key.ToLowerInvariant()) {
                'left' { 'Left' }
                'right' { 'Right' }
                'up' { 'Up' }
                'down' { 'Down' }
            }
            $distance = if ($hasShift) { 10 } else { 1 }
            return "MoveSelection$direction$distance"
        }
    }

    if ($Key -eq 'Escape' -and
        -not [string]::IsNullOrEmpty([string]$EditorState.ActiveTool) -and
        $EditorState.ActiveTool -ne 'Select') {
        return 'ActivateSelect'
    }

    if ($hasCtrl) {
        switch ($Key.ToLowerInvariant()) {
            'c' { return 'CopyKeepOpen' }
            'z' { if ($hasShift) { return 'Redo' } else { return 'Undo' } }
            'enter' { return 'CopyAndClose' }
            's' { return 'Save' }
            'n' { return 'NewSmartCapture' }
            { $_ -in 'plus', 'oemplus', 'add' } { return 'ZoomIn' }
            { $_ -in 'minus', 'oemminus', 'subtract' } { return 'ZoomOut' }
            { $_ -in 'd0', 'numpad0' } { return 'ZoomFit' }
        }
    }

    if ($FocusedRole -eq 'Canvas' -and $Key -eq 'Space') { return 'TemporaryPan' }
    if ($Key -eq 'Escape') { return 'ClosePreview' }
    return $null
}

function Get-SnipCoordinatorDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Phase,
        [Parameter(Mandatory)] [string]$Event,
        [Parameter(Mandatory)] [bool]$HasPending
    )

    $validPhases = @(
        'Idle', 'DelayPending', 'CaptureStarting', 'Selecting', 'Previewing',
        'Completing', 'Recovering', 'Auxiliary', 'ShuttingDown'
    )
    $validEvents = @(
        'Submit', 'DelayElapsed', 'SmartReady', 'DirectReady', 'SelectionCompleted',
        'CopyClosed', 'SaveCompleted', 'SurfaceClosed', 'UserCancelled', 'Preempted',
        'Failed', 'Recovered', 'ShutdownRequested', 'CleanupFinished'
    )
    if ($Phase -notin $validPhases) {
        throw [ArgumentException]::new("Unknown coordinator phase '$Phase'.", 'Phase')
    }
    if ($Event -notin $validEvents) {
        throw [ArgumentException]::new("Unknown coordinator event '$Event'.", 'Event')
    }

    $newDecision = {
        param(
            [string]$Action,
            [string]$NextPhase,
            [bool]$QueueLatest = $false,
            [bool]$CloseSurface = $false,
            [bool]$Reject = $false
        )
        [pscustomobject][ordered]@{
            Action = $Action
            NextPhase = $NextPhase
            QueueLatest = $QueueLatest
            CloseSurface = $CloseSurface
            Reject = $Reject
        }
    }

    if ($Event -eq 'Submit') {
        $decision = switch ($Phase) {
            'Idle' { & $newDecision 'Start' 'CaptureStarting' }
            'DelayPending' { & $newDecision 'CancelDelayAndStart' 'CaptureStarting' }
            'CaptureStarting' { & $newDecision 'QueueLatest' 'CaptureStarting' $true }
            'Selecting' { & $newDecision 'QueueLatestAndClose' 'Selecting' $true $true }
            'Previewing' { & $newDecision 'QueueLatestAndClose' 'Previewing' $true $true }
            'Completing' { & $newDecision 'QueueLatest' 'Completing' $true }
            'Recovering' { & $newDecision 'QueueLatest' 'Recovering' $true }
            'Auxiliary' { & $newDecision 'QueueLatestAndClose' 'Auxiliary' $true $true }
            'ShuttingDown' { & $newDecision 'Reject' 'ShuttingDown' $false $false $true }
        }
        return $decision
    }

    if ($Event -eq 'ShutdownRequested') {
        return (& $newDecision 'BeginShutdown' 'ShuttingDown')
    }
    if ($Event -eq 'Failed') {
        if ($Phase -eq 'ShuttingDown') {
            return (& $newDecision 'Reject' 'ShuttingDown' $false $false $true)
        }
        return (& $newDecision 'BeginRecovery' 'Recovering')
    }

    $phaseEvent = "$Phase|$Event"
    switch ($phaseEvent) {
        'DelayPending|DelayElapsed' {
            return (& $newDecision 'Start' 'CaptureStarting')
        }
        'CaptureStarting|SmartReady' {
            if ($HasPending) { return (& $newDecision 'DiscardAndStartPending' 'CaptureStarting') }
            return (& $newDecision 'OpenSelector' 'Selecting')
        }
        'CaptureStarting|DirectReady' {
            if ($HasPending) { return (& $newDecision 'DiscardAndStartPending' 'CaptureStarting') }
            return (& $newDecision 'OpenPreview' 'Previewing')
        }
        'Selecting|SelectionCompleted' {
            if ($HasPending) { return (& $newDecision 'DiscardAndStartPending' 'CaptureStarting') }
            return (& $newDecision 'OpenPreview' 'Previewing')
        }
        'Completing|CopyClosed' {
            if ($HasPending) { return (& $newDecision 'StartPending' 'CaptureStarting') }
            return (& $newDecision 'ReturnIdle' 'Idle')
        }
        'Completing|SaveCompleted' {
            if ($HasPending) { return (& $newDecision 'ClosePreviewAndStartPending' 'CaptureStarting') }
            return (& $newDecision 'ReturnPreview' 'Previewing')
        }
        { $_ -in @(
                'Selecting|SurfaceClosed', 'Previewing|SurfaceClosed', 'Auxiliary|SurfaceClosed',
                'DelayPending|UserCancelled', 'CaptureStarting|UserCancelled',
                'Selecting|UserCancelled', 'Previewing|UserCancelled', 'Auxiliary|UserCancelled',
                'DelayPending|Preempted', 'CaptureStarting|Preempted',
                'Selecting|Preempted', 'Previewing|Preempted', 'Auxiliary|Preempted',
                'Recovering|Recovered'
            ) } {
            if ($HasPending) { return (& $newDecision 'StartPending' 'CaptureStarting') }
            return (& $newDecision 'ReturnIdle' 'Idle')
        }
        'ShuttingDown|CleanupFinished' {
            return (& $newDecision 'ShutdownComplete' 'ShuttingDown')
        }
    }

    throw [InvalidOperationException]::new(
        "Coordinator event '$Event' is not supported while in phase '$Phase'."
    )
}

function New-SnipCaptureRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Smart', 'Full', 'Window', 'Display')]
        [string]$Mode,

        [timespan]$Delay = [timespan]::Zero,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [guid]$Id = [guid]::NewGuid(),
        [datetimeoffset]$SubmittedAt = [datetimeoffset]::UtcNow,

        [string]$MonitorId
    )

    if ($Delay -lt [timespan]::Zero) {
        throw [ArgumentOutOfRangeException]::new('Delay', $Delay, 'Capture delay cannot be negative.')
    }
    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw [ArgumentException]::new('Capture source cannot be blank.', 'Source')
    }

    $normalizedMode = switch ($Mode.ToLowerInvariant()) {
        'smart' { 'Smart' }
        'full' { 'Full' }
        'window' { 'Window' }
        'display' { 'Display' }
    }
    $normalizedMonitorId = $null
    if ($normalizedMode -eq 'Display') {
        if ([string]::IsNullOrWhiteSpace($MonitorId)) {
            throw [ArgumentException]::new('Display capture requires a monitor ID.', 'MonitorId')
        }
        $normalizedMonitorId = $MonitorId.Trim()
    }
    [pscustomobject][ordered]@{
        Id = $Id
        Mode = $normalizedMode
        MonitorId = $normalizedMonitorId
        Delay = $Delay
        Source = $Source
        SubmittedAt = $SubmittedAt
    }
}

function Get-SnipCoordinatorService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Coordinator,
        [Parameter(Mandatory)] [string]$Name
    )

    $services = $Coordinator.Services
    if ($null -eq $services) { return $null }
    if ($services -is [System.Collections.IDictionary]) {
        return $services[$Name]
    }
    $property = $services.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Invoke-SnipResourceDispose {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    $method = $Resource.PSObject.Methods['Dispose']
    if ($null -ne $method) {
        $Resource.Dispose()
        return
    }
    $property = $Resource.PSObject.Properties['Dispose']
    if ($null -ne $property -and $property.Value -is [scriptblock]) {
        & $property.Value
    }
}

function Remove-SnipCoordinatorBitmap {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Coordinator)

    $owned = $Coordinator.OwnedBitmap
    # Clear first so an exceptional Dispose cannot be attempted a second time
    # by a recovery or shutdown path.
    $Coordinator.OwnedBitmap = $null
    if ($null -eq $owned) { return }
    try {
        Invoke-SnipResourceDispose -Resource $owned
    } catch {
        $Coordinator.LastError = $_
    }
}

function ConvertTo-SnipSurfaceResult {
    [CmdletBinding()]
    param(
        $Value,
        [switch]$CaptureResult
    )

    $validResults = @('Completed', 'UserCancelled', 'Preempted', 'Failed', 'Shutdown')
    if ($null -eq $Value) {
        return [pscustomobject][ordered]@{ Result = 'UserCancelled'; Bitmap = $null; ErrorRecord = $null }
    }
    if ($Value -is [string]) {
        if ($Value -notin $validResults) {
            throw [InvalidOperationException]::new("Unknown surface result '$Value'.")
        }
        return [pscustomobject][ordered]@{ Result = $Value; Bitmap = $null; ErrorRecord = $null }
    }

    $resultProperty = $Value.PSObject.Properties['Result']
    if ($null -ne $resultProperty) {
        $result = [string]$resultProperty.Value
        if ($result -notin $validResults) {
            throw [InvalidOperationException]::new("Unknown surface result '$result'.")
        }
        $bitmapProperty = $Value.PSObject.Properties['Bitmap']
        $errorProperty = $Value.PSObject.Properties['ErrorRecord']
        return [pscustomobject][ordered]@{
            Result = $result
            Bitmap = if ($null -ne $bitmapProperty) { $bitmapProperty.Value } else { $null }
            ErrorRecord = if ($null -ne $errorProperty) { $errorProperty.Value } else { $null }
        }
    }

    if ($CaptureResult) {
        return [pscustomobject][ordered]@{ Result = 'Completed'; Bitmap = $Value; ErrorRecord = $null }
    }
    throw [InvalidOperationException]::new('A modal surface must return a supported result value.')
}

function New-SnipCaptureCoordinator {
    [CmdletBinding()]
    param(
        [scriptblock]$Post = { param($work) & $work },
        $Services = $null,
        $Settings = $null,
        $RegisteredHotkey = $null
    )

    [pscustomobject][ordered]@{
        Phase = 'Idle'
        ActiveRequest = $null
        PendingRequest = $null
        ActiveSurface = $null
        OwnedBitmap = $null
        PreviewWindow = $null
        Settings = $Settings
        RegisteredHotkey = $RegisteredHotkey
        ShutdownRequested = $false
        PumpScheduled = $false
        Post = $Post
        Services = $Services
        DelayHandle = $null
        LastResult = $null
        LastError = $null
        PumpRunning = $false
        PumpDispatching = $false
        PumpRescheduleRequested = $false
        PumpDepth = 0
        MaxPumpDepth = 0
        SurfaceCloseRequested = $false
    }
}

function Invoke-SnipCancelDelay {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Coordinator)

    $handle = $Coordinator.DelayHandle
    $Coordinator.DelayHandle = $null
    if ($null -eq $handle) { return }
    $cancel = Get-SnipCoordinatorService -Coordinator $Coordinator -Name CancelDelay
    try {
        if ($cancel -is [scriptblock]) {
            & $cancel $handle
        } else {
            Invoke-SnipResourceDispose -Resource $handle
        }
    } catch {
        $Coordinator.LastError = $_
    }
}

function Send-SnipCapturePump {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Coordinator)

    if ($Coordinator.ShutdownRequested -or $Coordinator.PumpScheduled) { return }
    $Coordinator.PumpScheduled = $true
    $coordinatorForPost = $Coordinator
    $dispatch = [pscustomobject]@{ Invoked = $false }
    $work = {
        $dispatch.Invoked = $true
        # A synchronous test Post, or a WinForms BeginInvoke that runs through a
        # nested modal dispatcher, may execute while an earlier posted work item
        # is still active.  Record a continuation instead of recursively pumping.
        if ($coordinatorForPost.PumpDispatching) {
            $coordinatorForPost.PumpRescheduleRequested = $true
            return
        }
        $coordinatorForPost.PumpDispatching = $true
        try {
            do {
                $coordinatorForPost.PumpRescheduleRequested = $false
                $coordinatorForPost.PumpScheduled = $false
                Invoke-SnipCapturePump -Coordinator $coordinatorForPost
            } while ($coordinatorForPost.PumpRescheduleRequested -and
                -not $coordinatorForPost.ShutdownRequested)
        } finally {
            $coordinatorForPost.PumpDispatching = $false
        }
    }.GetNewClosure()
    try {
        $postOutput = @(& $Coordinator.Post $work)
        $postValue = if ($postOutput.Count -gt 0) { $postOutput[-1] } else { $null }
        if (-not $dispatch.Invoked -and
            $postValue -is [bool] -and -not $postValue) {
            throw [InvalidOperationException]::new('Capture pump dispatch was declined.')
        }
    } catch {
        $Coordinator.LastError = $_
        if (-not $dispatch.Invoked) {
            $Coordinator.PumpScheduled = $false
            $Coordinator.PumpRescheduleRequested = $false
            $Coordinator.Phase = if ($Coordinator.ShutdownRequested) {
                'ShuttingDown'
            } else {
                'Recovering'
            }
        }
    }
}

function Request-SnipCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Coordinator,
        [ValidateSet('Smart', 'Full', 'Window', 'Display')] [string]$Mode,
        [timespan]$Delay = [timespan]::Zero,
        [string]$Source,
        $Request = $null,
        [switch]$DelayElapsed,
        [string]$MonitorId
    )

    if ($Coordinator.ShutdownRequested -or $Coordinator.Phase -eq 'ShuttingDown') {
        return $null
    }
    if ($null -eq $Request) {
        if ([string]::IsNullOrWhiteSpace($Mode)) {
            throw [ArgumentException]::new('Mode is required when Request is not supplied.', 'Mode')
        }
        if ([string]::IsNullOrWhiteSpace($Source)) {
            throw [ArgumentException]::new('Source is required when Request is not supplied.', 'Source')
        }
        $Request = New-SnipCaptureRequest -Mode $Mode -Delay $Delay -Source $Source `
            -MonitorId $MonitorId
    }

    if ($DelayElapsed) {
        if ($Coordinator.Phase -ne 'DelayPending' -or
            $null -eq $Coordinator.ActiveRequest -or
            $Coordinator.ActiveRequest.Id -ne $Request.Id) {
            return $null
        }
        Invoke-SnipCancelDelay -Coordinator $Coordinator
        $Coordinator.Phase = 'CaptureStarting'
        Send-SnipCapturePump -Coordinator $Coordinator
        return $Request
    }

    $decision = Get-SnipCoordinatorDecision -Phase $Coordinator.Phase `
        -Event Submit -HasPending ($null -ne $Coordinator.PendingRequest)
    if ($decision.Reject) { return $null }

    if ($Coordinator.Phase -eq 'Idle') {
        $Coordinator.ActiveRequest = $Request
        if ($Request.Delay -gt [timespan]::Zero) {
            $Coordinator.Phase = 'DelayPending'
            $startDelay = Get-SnipCoordinatorService -Coordinator $Coordinator -Name StartDelay
            if ($startDelay -isnot [scriptblock]) {
                $Coordinator.ActiveRequest = $null
                $Coordinator.Phase = 'Idle'
                throw [InvalidOperationException]::new('A delayed capture requires the StartDelay service.')
            }
            $coordinatorForDelay = $Coordinator
            $requestForDelay = $Request
            $elapsed = {
                Request-SnipCapture -Coordinator $coordinatorForDelay `
                    -Request $requestForDelay -DelayElapsed | Out-Null
            }.GetNewClosure()
            try {
                $Coordinator.DelayHandle = & $startDelay $Request.Delay $elapsed $Request $Coordinator
            } catch {
                $Coordinator.LastError = $_
                $Coordinator.Phase = 'Recovering'
                Send-SnipCapturePump -Coordinator $Coordinator
            }
            return $Request
        }
        $Coordinator.Phase = 'CaptureStarting'
        Send-SnipCapturePump -Coordinator $Coordinator
        return $Request
    }

    if ($Coordinator.Phase -eq 'DelayPending') {
        Invoke-SnipCancelDelay -Coordinator $Coordinator
        $Coordinator.ActiveRequest = $Request
        $Coordinator.PendingRequest = $null
        # Per the approved transition table, a new request superseding a delay
        # starts immediately even if the new request also carries a delay.
        $Coordinator.Phase = 'CaptureStarting'
        Send-SnipCapturePump -Coordinator $Coordinator
        return $Request
    }

    $Coordinator.PendingRequest = $Request
    if ($Coordinator.Phase -eq 'Recovering') {
        # A transient Post failure leaves scheduling flags clear.  Retry once
        # when new external work arrives; persistent failure waits for the next
        # request instead of spinning, and PumpScheduled preserves latest-only.
        Send-SnipCapturePump -Coordinator $Coordinator
        return $Request
    }
    if ($decision.CloseSurface) {
        Close-SnipActiveSurface -Coordinator $Coordinator -Result Preempted | Out-Null
    }
    $Request
}

function Invoke-SnipPreviewTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Bitmap,
        [Parameter(Mandatory)] [scriptblock]$Preview
    )

    $ownership = [pscustomobject]@{ Accepted = $false }
    $accept = {
        $ownership.Accepted = $true
    }.GetNewClosure()
    $result = 'Failed'
    $errorRecord = $null
    try {
        $output = @(& $Preview $Bitmap $accept)
        $value = if ($output.Count -gt 0) { $output[-1] } else { $null }
        $surfaceResult = ConvertTo-SnipSurfaceResult -Value $value
        $result = $surfaceResult.Result
        $errorRecord = $surfaceResult.ErrorRecord
    } catch {
        $result = 'Failed'
        $errorRecord = $_
    } finally {
        if (-not $ownership.Accepted) {
            try { Invoke-SnipResourceDispose -Resource $Bitmap }
            catch { if ($null -eq $errorRecord) { $errorRecord = $_ } }
        }
    }

    [pscustomobject][ordered]@{
        Result = $result
        OwnershipTransferred = [bool]$ownership.Accepted
        ErrorRecord = $errorRecord
    }
}

function Set-SnipAuxiliarySurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Coordinator,
        [Parameter(Mandatory)] $Surface
    )

    $canPublish = -not $Coordinator.ShutdownRequested -and
        $Coordinator.Phase -eq 'Idle' -and
        $null -eq $Coordinator.ActiveSurface -and
        $null -eq $Coordinator.PreviewWindow
    if (-not $canPublish) {
        $closeResult = if ($Coordinator.ShutdownRequested -or
            $Coordinator.Phase -eq 'ShuttingDown') { 'Shutdown' } else { 'Preempted' }
        try {
            $closeProperty = $Surface.PSObject.Properties['Close']
            if ($null -ne $closeProperty -and $closeProperty.Value -is [scriptblock]) {
                & $closeProperty.Value $closeResult
            } elseif ($null -ne $Surface.PSObject.Methods['Close']) {
                $requestedProperty = $Surface.PSObject.Properties['RequestedResult']
                if ($null -ne $requestedProperty) { $requestedProperty.Value = $closeResult }
                $Surface.Close()
            }
        } catch {
            $Coordinator.LastError = $_
        }
        return $false
    }

    $Coordinator.Phase = 'Auxiliary'
    $Coordinator.ActiveSurface = $Surface
    $Coordinator.SurfaceCloseRequested = $false
    $true
}

function Complete-SnipAuxiliarySurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Coordinator,
        [Parameter(Mandatory)] $Surface,
        [Parameter(Mandatory)]
        [ValidateSet('Completed', 'UserCancelled', 'Preempted', 'Failed', 'Shutdown')]
        [string]$Result
    )

    if ($Coordinator.Phase -ne 'Auxiliary' -or
        $null -eq $Coordinator.ActiveSurface -or
        -not [object]::ReferenceEquals($Coordinator.ActiveSurface, $Surface)) {
        return $false
    }

    Complete-SnipSurface -Coordinator $Coordinator -Result $Result -Operation Preview
    $true
}

function Close-SnipActiveSurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Coordinator,
        [ValidateSet('Completed', 'UserCancelled', 'Preempted', 'Failed', 'Shutdown')]
        [string]$Result = 'Preempted'
    )

    if ($Coordinator.Phase -eq 'DelayPending') {
        Invoke-SnipCancelDelay -Coordinator $Coordinator
        $Coordinator.LastResult = $Result
        $Coordinator.ActiveRequest = $null
        if ($null -ne $Coordinator.PendingRequest) {
            $Coordinator.ActiveRequest = $Coordinator.PendingRequest
            $Coordinator.PendingRequest = $null
            $Coordinator.Phase = 'CaptureStarting'
            Send-SnipCapturePump -Coordinator $Coordinator
        } elseif ($Result -eq 'Shutdown') {
            $Coordinator.Phase = 'ShuttingDown'
        } else {
            $Coordinator.Phase = 'Idle'
        }
        return $true
    }

    if ($Coordinator.SurfaceCloseRequested) { return $true }
    $surface = $Coordinator.ActiveSurface
    if ($null -eq $surface -and $null -ne $Coordinator.PreviewWindow) {
        $surface = $Coordinator.PreviewWindow
    }
    if ($null -eq $surface) { return $false }

    $Coordinator.SurfaceCloseRequested = $true
    try {
        $closeProperty = $surface.PSObject.Properties['Close']
        if ($null -ne $closeProperty -and $closeProperty.Value -is [scriptblock]) {
            & $closeProperty.Value $Result
        } elseif ($null -ne $surface.PSObject.Methods['Close']) {
            $requestedProperty = $surface.PSObject.Properties['RequestedResult']
            if ($null -ne $requestedProperty) { $requestedProperty.Value = $Result }
            $surface.Close()
        } else {
            $Coordinator.SurfaceCloseRequested = $false
            return $false
        }
    } catch {
        $Coordinator.LastError = $_
        $Coordinator.SurfaceCloseRequested = $false
        return $false
    }
    $true
}

function Complete-SnipSurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Coordinator,
        [Parameter(Mandatory)]
        [ValidateSet('Completed', 'UserCancelled', 'Preempted', 'Failed', 'Shutdown')]
        [string]$Result,
        [ValidateSet('Capture', 'Selection', 'Preview', 'Copy', 'CopyKeepOpen', 'Save')]
        [string]$Operation = 'Preview'
    )

    if ($Result -eq 'Shutdown') {
        $Coordinator.LastResult = $Result
        Stop-SnipCaptureCoordinator -Coordinator $Coordinator
        return
    }
    if ($Coordinator.ShutdownRequested -or $Coordinator.Phase -eq 'ShuttingDown') {
        return
    }
    $Coordinator.LastResult = $Result

    # Output operations are deliberately non-preemptible.  A successful Save
    # (and today's keep-open Copy) returns to Preview unless a pending request
    # exists, in which case the installed Preview surface is asked to close.
    if ($Coordinator.Phase -eq 'Completing') {
        if ($Result -eq 'Completed' -and $Operation -in @('CopyKeepOpen', 'Save')) {
            $Coordinator.Phase = 'Previewing'
            if ($null -ne $Coordinator.PendingRequest) {
                Close-SnipActiveSurface -Coordinator $Coordinator -Result Preempted | Out-Null
            }
            return
        }
        if ($Result -in @('UserCancelled', 'Failed') -and
            $Operation -in @('Copy', 'CopyKeepOpen', 'Save')) {
            $Coordinator.Phase = 'Previewing'
            if ($null -ne $Coordinator.PendingRequest) {
                Close-SnipActiveSurface -Coordinator $Coordinator -Result Preempted | Out-Null
            }
            return
        }
    }

    Remove-SnipCoordinatorBitmap -Coordinator $Coordinator
    $Coordinator.ActiveSurface = $null
    $Coordinator.PreviewWindow = $null
    $Coordinator.SurfaceCloseRequested = $false
    $Coordinator.ActiveRequest = $null

    if ($Result -eq 'Failed') {
        $Coordinator.Phase = 'Recovering'
        Send-SnipCapturePump -Coordinator $Coordinator
        return
    }

    if ($null -ne $Coordinator.PendingRequest) {
        $Coordinator.ActiveRequest = $Coordinator.PendingRequest
        $Coordinator.PendingRequest = $null
        $Coordinator.Phase = 'CaptureStarting'
        Send-SnipCapturePump -Coordinator $Coordinator
    } else {
        $Coordinator.Phase = 'Idle'
    }
}

function Stop-SnipCaptureCoordinator {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Coordinator)

    # Idempotence here means every call may finish newly-available cleanup
    # (for example after a modal surface returns), while one-shot handles and
    # close signals are never repeated.
    $Coordinator.ShutdownRequested = $true
    $Coordinator.Phase = 'ShuttingDown'
    $Coordinator.PendingRequest = $null
    Invoke-SnipCancelDelay -Coordinator $Coordinator
    Remove-SnipCoordinatorBitmap -Coordinator $Coordinator
    Close-SnipActiveSurface -Coordinator $Coordinator -Result Shutdown | Out-Null
    if ($null -eq $Coordinator.ActiveSurface -and $null -eq $Coordinator.PreviewWindow) {
        $Coordinator.ActiveRequest = $null
    }
}

function Invoke-SnipCapturePump {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Coordinator)

    if ($Coordinator.PumpRunning) {
        $Coordinator.PumpRescheduleRequested = $true
        return
    }
    if ($Coordinator.ShutdownRequested) { return }

    if ($Coordinator.Phase -eq 'Recovering') {
        if ($null -ne $Coordinator.PendingRequest) {
            $Coordinator.ActiveRequest = $Coordinator.PendingRequest
            $Coordinator.PendingRequest = $null
            $Coordinator.Phase = 'CaptureStarting'
            Send-SnipCapturePump -Coordinator $Coordinator
        } else {
            $Coordinator.ActiveRequest = $null
            $Coordinator.Phase = 'Idle'
        }
        return
    }
    if ($Coordinator.Phase -ne 'CaptureStarting' -or
        $null -eq $Coordinator.ActiveRequest) {
        return
    }

    $Coordinator.PumpRunning = $true
    $Coordinator.PumpDepth++
    if ($Coordinator.PumpDepth -gt $Coordinator.MaxPumpDepth) {
        $Coordinator.MaxPumpDepth = $Coordinator.PumpDepth
    }
    try {
        $request = $Coordinator.ActiveRequest
        $captureServiceName = switch ($request.Mode) {
            'Smart' { 'SmartCapture' }
            'Full' { 'FullCapture' }
            'Window' { 'WindowCapture' }
            'Display' { 'DisplayCapture' }
        }
        $captureService = Get-SnipCoordinatorService -Coordinator $Coordinator -Name $captureServiceName
        if ($captureService -isnot [scriptblock]) {
            Complete-SnipSurface -Coordinator $Coordinator -Result UserCancelled `
                -Operation $(if ($request.Mode -eq 'Smart') { 'Selection' } else { 'Capture' })
            return
        }

        try {
            $captureOutput = @(& $captureService $Coordinator $request)
            $captureValue = if ($captureOutput.Count -gt 0) { $captureOutput[-1] } else { $null }
            $captureResult = ConvertTo-SnipSurfaceResult -Value $captureValue -CaptureResult
        } catch {
            $Coordinator.LastError = $_
            Complete-SnipSurface -Coordinator $Coordinator -Result Failed `
                -Operation $(if ($request.Mode -eq 'Smart') { 'Selection' } else { 'Capture' })
            return
        }

        $Coordinator.ActiveSurface = $null
        $Coordinator.PreviewWindow = $null
        $Coordinator.SurfaceCloseRequested = $false
        if ($null -ne $captureResult.ErrorRecord) { $Coordinator.LastError = $captureResult.ErrorRecord }
        if ($captureResult.Result -ne 'Completed') {
            Complete-SnipSurface -Coordinator $Coordinator -Result $captureResult.Result `
                -Operation $(if ($request.Mode -eq 'Smart') { 'Selection' } else { 'Capture' })
            return
        }
        if ($null -eq $captureResult.Bitmap) {
            $Coordinator.LastError = [InvalidOperationException]::new('Completed capture returned no bitmap.')
            Complete-SnipSurface -Coordinator $Coordinator -Result Failed -Operation Capture
            return
        }

        $Coordinator.OwnedBitmap = $captureResult.Bitmap
        if ($Coordinator.ShutdownRequested) {
            Complete-SnipSurface -Coordinator $Coordinator -Result Shutdown -Operation Capture
            return
        }
        if ($null -ne $Coordinator.PendingRequest) {
            # CaptureStarting cannot be interrupted, but a stale completed
            # bitmap is still coordinator-owned and must be disposed before the
            # latest request is posted.
            Complete-SnipSurface -Coordinator $Coordinator -Result Preempted -Operation Capture
            return
        }

        $Coordinator.Phase = 'Previewing'
        $previewService = Get-SnipCoordinatorService -Coordinator $Coordinator -Name Preview
        if ($previewService -isnot [scriptblock]) {
            Complete-SnipSurface -Coordinator $Coordinator -Result UserCancelled -Operation Preview
            return
        }
        $coordinatorForPreview = $Coordinator
        $requestForPreview = $request
        $previewInvoker = {
            param($bitmap,$accept)
            $handoff = [pscustomobject]@{
                Coordinator = $coordinatorForPreview
                Accept = $accept
            }
            $acceptAndRelinquish = {
                # Preview calls this only after its Closed cleanup is installed.
                # Relinquish synchronously so shutdown cannot dispose the same
                # bitmap while the modal Preview is still open.
                $handoff.Coordinator.OwnedBitmap = $null
                & $handoff.Accept
            }.GetNewClosure()
            & $previewService $bitmap $acceptAndRelinquish `
                $coordinatorForPreview $requestForPreview
        }.GetNewClosure()
        $transfer = Invoke-SnipPreviewTransfer -Bitmap $Coordinator.OwnedBitmap -Preview $previewInvoker
        # Transfer either handed ownership to Preview or disposed the bitmap;
        # in both cases the coordinator must forget it before any continuation.
        $Coordinator.OwnedBitmap = $null
        $Coordinator.ActiveSurface = $null
        $Coordinator.PreviewWindow = $null
        $Coordinator.SurfaceCloseRequested = $false
        if ($null -ne $transfer.ErrorRecord) { $Coordinator.LastError = $transfer.ErrorRecord }
        Complete-SnipSurface -Coordinator $Coordinator -Result $transfer.Result -Operation Preview
    } finally {
        $Coordinator.PumpDepth--
        $Coordinator.PumpRunning = $false
    }
}

$script:SnipEmbeddedXaml = [ordered]@{
    PreviewWindow = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SnipIT Preview" Width="1180" Height="760" MinWidth="760" MinHeight="540"
        WindowStartupLocation="Manual" WindowStyle="SingleBorderWindow"
        ResizeMode="CanResize" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal"
        AutomationProperties.Name="SnipIT preview editor">
  <!-- Stock Fluent only. No local styles, no brushes of our own: every colour
       comes from the theme dictionary that Window.ThemeMode installs, so the
       editor follows the Windows app theme and the Windows accent colour. -->
  <Grid x:Name="StudioRoot" KeyboardNavigation.TabNavigation="Cycle">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Two bands: what you do with the snip, then what you draw on it.
         IsLocked hides the drag grips so the bands cannot be pulled apart. -->
    <ToolBarTray x:Name="PreviewToolBarTray" Grid.Row="0" IsLocked="True">
      <ToolBar x:Name="PreviewActionToolBar" Band="0" BandIndex="0"
               KeyboardNavigation.TabNavigation="Continue"
               AutomationProperties.Name="Preview actions"/>
      <ToolBar x:Name="PreviewEditorToolBar" Band="1" BandIndex="0"
               KeyboardNavigation.TabNavigation="Continue"
               AutomationProperties.Name="Editing tools"/>
    </ToolBarTray>

    <!-- Contextual row for the active tool. One hairline divider separates it
         from the canvas so the canvas edge is legible in both modes. -->
    <DockPanel x:Name="PreviewPropertyBar" Grid.Row="1" MinHeight="40"
               LastChildFill="True">
      <Border x:Name="PropertyIsland" Padding="8,4"
              BorderThickness="0,0,0,1"
              BorderBrush="{DynamicResource DividerStrokeColorDefaultBrush}"
              AutomationProperties.Name="Tool properties">
        <StackPanel x:Name="PropertyPanel" Orientation="Horizontal"
                    HorizontalAlignment="Left" VerticalAlignment="Center"/>
      </Border>
    </DockPanel>

    <!-- The mat behind the capture is the application ground, which
         Set-SnipNeutralSurfaces pins to pure black in Dark and pure white in
         Light, so nothing tints the image the user is about to annotate. -->
    <ScrollViewer x:Name="Scroller" Grid.Row="2"
                  Background="{DynamicResource ApplicationBackgroundBrush}"
                  HorizontalScrollBarVisibility="Hidden"
                  VerticalScrollBarVisibility="Hidden"
                  AutomationProperties.Name="Capture viewport">
      <Grid x:Name="ImageHost" HorizontalAlignment="Left" VerticalAlignment="Top">
        <Image x:Name="PreviewImage" Stretch="None" HorizontalAlignment="Left"
               VerticalAlignment="Top"/>
        <Canvas x:Name="AnnotationLayer" Background="Transparent"
                HorizontalAlignment="Left" VerticalAlignment="Top"
                IsHitTestVisible="False"/>
        <Canvas x:Name="InteractionLayer" Background="Transparent"
                HorizontalAlignment="Left" VerticalAlignment="Top"
                IsHitTestVisible="False"/>
        <Canvas x:Name="SelectionLayer" Background="Transparent"
                HorizontalAlignment="Left" VerticalAlignment="Top"
                IsHitTestVisible="False"/>
        <Canvas x:Name="HighlightLayer" Background="Transparent"
                HorizontalAlignment="Left" VerticalAlignment="Top"
                IsHitTestVisible="True" Focusable="True"
                KeyboardNavigation.IsTabStop="True"
                AutomationProperties.Name="Image editing canvas"/>
      </Grid>
    </ScrollViewer>

    <StatusBar x:Name="PreviewStatusBar" Grid.Row="3">
      <Border x:Name="StatusIsland" Padding="4,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="StatusIndicator" Width="8" Height="8" Margin="2,0,8,0"
                   Fill="{DynamicResource SystemFillColorSuccessBrush}"
                   AutomationProperties.Name="Editor state"/>
          <TextBlock x:Name="StatusText" Text="Non-destructive edit"
                     VerticalAlignment="Center"
                     AutomationProperties.Name="Editor status"/>
        </StackPanel>
      </Border>
      <Separator/>
      <Border x:Name="ViewportIsland">
        <StackPanel x:Name="ViewportPanel" Orientation="Horizontal"
                    VerticalAlignment="Center">
          <TextBlock x:Name="CoordinateText" Text="x 0  y 0" Margin="4,0,12,0"
                     VerticalAlignment="Center" MinWidth="86"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                     ToolTip="Pointer position in image pixels"
                     AutomationProperties.Name="Pointer position"/>
          <Button x:Name="ZoomOutBtn" MinWidth="32" Height="26" Padding="0"
                  ToolTip="Zoom out (Ctrl+-)"
                  AutomationProperties.Name="Zoom out">
            <TextBlock Text="&#xE738;" FontFamily="Segoe Fluent Icons" FontSize="14"/>
          </Button>
          <TextBlock x:Name="ZoomText" Text="100%" Width="52" Margin="4,0"
                     TextAlignment="Center" VerticalAlignment="Center"
                     ToolTip="Current zoom level"
                     AutomationProperties.Name="Zoom level"/>
          <Button x:Name="ZoomInBtn" MinWidth="32" Height="26" Padding="0"
                  ToolTip="Zoom in (Ctrl++)"
                  AutomationProperties.Name="Zoom in">
            <TextBlock Text="&#xE710;" FontFamily="Segoe Fluent Icons" FontSize="14"/>
          </Button>
          <Button x:Name="FitBtn" MinWidth="44" Height="26" Margin="8,0,0,0"
                  Padding="6,0" ToolTip="Fit to viewport (Ctrl+0)"
                  AutomationProperties.Name="Fit to viewport">
            <AccessText Text="_Fit"/>
          </Button>
        </StackPanel>
      </Border>
      <!-- StatusBar's ItemsPanel is a DockPanel with LastChildFill, so the final
           item stretches instead of honouring Dock=Right; right-align inside it. -->
      <StatusBarItem x:Name="StatusHintItem" HorizontalContentAlignment="Right">
        <TextBlock x:Name="StatusHintText" Margin="0,0,8,0"
                   Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                   VerticalAlignment="Center" HorizontalAlignment="Right"
                   TextTrimming="CharacterEllipsis"
                   AutomationProperties.Name="Keyboard shortcuts"
                   Text="Ctrl+Enter copy &#183; Ctrl+S save &#183; Esc close"/>
      </StatusBarItem>
    </StatusBar>

    <Grid x:Name="HiddenLegacyControls" Visibility="Collapsed">
      <StackPanel x:Name="DragHeader">
        <TextBlock x:Name="BrandZoomText"/>
      </StackPanel>
      <Border x:Name="ActionsIsland"><StackPanel x:Name="ActionsPanel"/></Border>
      <Border x:Name="ToolDock"><StackPanel x:Name="ToolPanel"/></Border>
      <StackPanel x:Name="ColorBar"/>
      <Button x:Name="ClearBtn"/>
      <Button x:Name="NewBtn"/>
      <ToggleButton x:Name="RectBtn"/>
      <ToggleButton x:Name="ArrowBtn"/>
    </Grid>
  </Grid>
</Window>

'@
    SmartOverlay = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        ShowActivated="True" Cursor="Cross" UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <!-- The overlay is deliberately the one chromeless window: it has to cover the
       desktop edge to edge. Its banner, size chip and loupe are plain Fluent
       Borders, so they follow the app theme like every other surface. -->
  <Grid ClipToBounds="True">
    <Image x:Name="BgImage" Stretch="Fill"
           RenderOptions.BitmapScalingMode="NearestNeighbor"/>
    <Rectangle x:Name="Dimmer" Fill="#66000000"/>
    <Canvas x:Name="OverlayCanvas">
      <Rectangle x:Name="HoverRect" StrokeThickness="2" Fill="#26FFFFFF"
                 SnapsToDevicePixels="True" Visibility="Collapsed"/>
      <Rectangle x:Name="DragRect" StrokeThickness="2" Fill="#33FFFFFF"
                 SnapsToDevicePixels="True" Visibility="Collapsed"/>
      <!-- Live selection size. Lives on the Canvas rather than the Grid because
           it tracks the drag rectangle's corner; HintBorder below stays put as
           the static instruction banner. Plain Fluent Border, no glass. -->
      <Border x:Name="SizeChip" Padding="10,6" CornerRadius="6"
              Background="{DynamicResource SolidBackgroundFillColorBaseBrush}"
              BorderBrush="{DynamicResource SurfaceStrokeColorDefaultBrush}"
              BorderThickness="1" Visibility="Collapsed"
              AutomationProperties.Name="Selection size">
        <TextBlock x:Name="SizeChipText" FontSize="12"
                   Foreground="{DynamicResource TextFillColorPrimaryBrush}"
                   Text="0 &#215; 0 px"/>
      </Border>
      <Border x:Name="LoupeBorder" Width="170" Height="190" CornerRadius="8"
              Background="{DynamicResource SolidBackgroundFillColorBaseBrush}"
              BorderBrush="{DynamicResource SurfaceStrokeColorDefaultBrush}"
              BorderThickness="1" Visibility="Collapsed"
              AutomationProperties.Name="Pixel loupe">
        <StackPanel>
          <!-- 138 = 136 viewport + the 1 px border on each side, so the image
               lands on exactly 136 DIPs: 17 source pixels blown up 8x (see
               Get-LoupeMagnification). The centre source pixel then covers
               64..72, which is why the crosshair sits at 68. -->
          <Border Width="138" Height="138" Margin="14,12,14,5"
                  BorderBrush="{DynamicResource ControlStrokeColorSecondaryBrush}"
                  BorderThickness="1" ClipToBounds="True">
            <Grid>
              <Image x:Name="LoupeImage" Stretch="Fill"
                     RenderOptions.BitmapScalingMode="NearestNeighbor"/>
              <Line X1="68" Y1="0" X2="68" Y2="136"
                    Stroke="{DynamicResource AccentFillColorDefaultBrush}"
                    StrokeThickness="1"/>
              <Line X1="0" Y1="68" X2="136" Y2="68"
                    Stroke="{DynamicResource AccentFillColorDefaultBrush}"
                    StrokeThickness="1"/>
              <Rectangle x:Name="LoupeCentreCell" Width="8" Height="8"
                         Stroke="{DynamicResource SystemFillColorAttentionBrush}"
                         StrokeThickness="1"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <TextBlock x:Name="LoupeText" FontSize="12"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                     HorizontalAlignment="Center"/>
        </StackPanel>
      </Border>
    </Canvas>
    <!-- Instruction banner before a drag; live W x H size chip during one. -->
    <Border x:Name="HintBorder" HorizontalAlignment="Center"
            VerticalAlignment="Top" Margin="24" Padding="16,10" CornerRadius="8"
            Background="{DynamicResource SolidBackgroundFillColorBaseBrush}"
            BorderBrush="{DynamicResource SurfaceStrokeColorDefaultBrush}"
            BorderThickness="1">
      <TextBlock x:Name="HintText" FontSize="13"
                 Foreground="{DynamicResource TextFillColorPrimaryBrush}"
                 AutomationProperties.Name="Smart capture hint"
                 Text="Click a window &#183; Drag a region &#183; Esc to cancel"/>
    </Border>
  </Grid>
</Window>

'@
    SettingsWindow = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SnipIT Settings" Width="560" Height="720"
        MinWidth="480" MinHeight="480" WindowStartupLocation="CenterScreen"
        WindowStyle="SingleBorderWindow" ResizeMode="CanResize"
        ShowInTaskbar="False" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal"
        AutomationProperties.Name="SnipIT Settings">
  <!-- One scrolling column of sections, one sticky footer. Stock Fluent only. -->
  <DockPanel LastChildFill="True">
    <Border DockPanel.Dock="Bottom" BorderThickness="0,1,0,0"
            BorderBrush="{DynamicResource DividerStrokeColorDefaultBrush}"
            Background="{DynamicResource SolidBackgroundFillColorSecondaryBrush}">
      <Grid Margin="24,16,24,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <!-- Status sits beside the buttons, so an empty message leaves no gap
             and a long one wraps without shifting them. -->
        <TextBlock x:Name="ErrorText" Margin="0,0,16,0" TextWrapping="Wrap"
                   VerticalAlignment="Center"
                   Foreground="{DynamicResource SystemFillColorCriticalBrush}"
                   AutomationProperties.Name="Settings status"
                   AutomationProperties.LiveSetting="Assertive"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal"
                    VerticalAlignment="Center">
          <Button x:Name="CancelBtn" TabIndex="6" MinWidth="104" Height="32"
                  Margin="0,0,8,0" ToolTip="Close without saving (Esc)"
                  AutomationProperties.Name="Cancel and close Settings">
            <AccessText Text="_Cancel"/>
          </Button>
          <Button x:Name="SaveBtn" TabIndex="7" MinWidth="132" Height="32"
                  Style="{DynamicResource AccentButtonStyle}"
                  ToolTip="Save these settings"
                  AutomationProperties.Name="Save Settings changes">
            <AccessText Text="Save c_hanges"/>
          </Button>
        </StackPanel>
      </Grid>
    </Border>

    <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="24,20,24,20"
                  Focusable="False">
      <StackPanel>
        <TextBlock Text="Shortcut" Margin="0,0,0,4"
                   Style="{DynamicResource BodyStrongTextBlockStyle}"/>
        <Separator Margin="0,0,0,12"/>
        <Label Target="{Binding ElementName=ShortcutRecorder}" Padding="0"
               Margin="0,0,0,2" Content="_Global capture shortcut"/>
        <TextBlock Margin="0,0,0,8" TextWrapping="Wrap"
                   Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                   Style="{DynamicResource CaptionTextBlockStyle}"
                   Text="Focus the recorder, then press one key with at least two modifiers."/>
        <Button x:Name="ShortcutRecorder" TabIndex="1" Height="48"
                HorizontalContentAlignment="Stretch" Padding="12,0"
                ToolTip="Record the Smart capture shortcut"
                AutomationProperties.Name="Record Smart capture shortcut"
                AutomationProperties.HelpText="Press one key with Control, Alt, or Shift modifiers">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="ShortcutText" VerticalAlignment="Center"
                       FontSize="15" FontWeight="SemiBold"/>
            <TextBlock Grid.Column="1" Text="Press a key" VerticalAlignment="Center"
                       Margin="16,0,0,0"
                       Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                       Style="{DynamicResource CaptionTextBlockStyle}"/>
          </Grid>
        </Button>

        <TextBlock Text="Saving" Margin="0,24,0,4"
                   Style="{DynamicResource BodyStrongTextBlockStyle}"/>
        <Separator Margin="0,0,0,12"/>
        <Label Target="{Binding ElementName=SaveFolderBox}" Padding="0"
               Margin="0,0,0,6" Content="Default save _folder"/>
        <TextBox x:Name="SaveFolderBox" TabIndex="2" Height="32"
                 VerticalContentAlignment="Center" Padding="10,0"
                 ToolTip="Folder used by Save actions"
                 AutomationProperties.Name="Default save folder"/>
        <Label Target="{Binding ElementName=SaveFormatBox}" Padding="0"
               Margin="0,16,0,2" Content="Default save f_ormat"/>
        <TextBlock Margin="0,0,0,8" TextWrapping="Wrap"
                   Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                   Style="{DynamicResource CaptionTextBlockStyle}"
                   Text="Preselected in the Save dialog; you can still switch format there."/>
        <ComboBox x:Name="SaveFormatBox" TabIndex="3" Height="32"
                  HorizontalAlignment="Left" MinWidth="200"
                  VerticalContentAlignment="Center"
                  ToolTip="Image format preselected by Save actions"
                  AutomationProperties.Name="Default save format">
          <ComboBoxItem Content="PNG" Tag="Png"/>
          <ComboBoxItem Content="JPEG" Tag="Jpeg"/>
          <ComboBoxItem Content="BMP" Tag="Bmp"/>
        </ComboBox>

        <TextBlock Text="Startup" Margin="0,24,0,4"
                   Style="{DynamicResource BodyStrongTextBlockStyle}"/>
        <Separator Margin="0,0,0,12"/>
        <CheckBox x:Name="LaunchCheck" TabIndex="4" Margin="0,0,0,10"
                  Content="_Launch SnipIT at sign-in"
                  ToolTip="Start SnipIT automatically after signing in"
                  AutomationProperties.Name="Launch SnipIT at sign-in"/>
        <CheckBox x:Name="WidgetCheck" TabIndex="5"
                  Content="Show the _edge-reveal capture widget"
                  ToolTip="Show capture controls at the top screen edge"
                  AutomationProperties.Name="Show edge-reveal capture widget"/>
        <TextBlock Margin="0,20,0,0" TextWrapping="Wrap"
                   Foreground="{DynamicResource TextFillColorTertiaryBrush}"
                   Style="{DynamicResource CaptionTextBlockStyle}"
                   Text="Changes stay local to this Windows account."/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>

'@
    AboutWindow = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About SnipIT" Width="520" Height="440"
        WindowStartupLocation="CenterScreen" WindowStyle="SingleBorderWindow"
        ResizeMode="NoResize" ShowInTaskbar="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal"
        AutomationProperties.Name="About SnipIT">
  <DockPanel LastChildFill="True">
    <Border DockPanel.Dock="Bottom" BorderThickness="0,1,0,0"
            BorderBrush="{DynamicResource DividerStrokeColorDefaultBrush}"
            Background="{DynamicResource SolidBackgroundFillColorSecondaryBrush}">
      <Grid Margin="24,12,24,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock VerticalAlignment="Center" TextWrapping="Wrap"
                   Foreground="{DynamicResource TextFillColorTertiaryBrush}"
                   Style="{DynamicResource CaptionTextBlockStyle}"
                   Text="Single script &#183; no admin &#183; no external runtime"/>
        <Button x:Name="CloseBtn" Grid.Column="1" TabIndex="1" MinWidth="104"
                Height="32" Style="{DynamicResource AccentButtonStyle}"
                ToolTip="Close About (Esc)"
                AutomationProperties.Name="Close About">
          <AccessText Text="_Close"/>
        </Button>
      </Grid>
    </Border>

    <StackPanel Margin="24,20,24,20">
      <TextBlock Text="SnipIT" Style="{DynamicResource TitleTextBlockStyle}"/>
      <TextBlock Margin="0,4,0,20" TextWrapping="Wrap"
                 Foreground="{DynamicResource TextFillColorSecondaryBrush}"
                 Text="A transient-first capture studio for Windows 11."/>
      <Border Padding="16" CornerRadius="6"
              Background="{DynamicResource CardBackgroundFillColorDefaultBrush}"
              BorderBrush="{DynamicResource CardStrokeColorDefaultBrush}"
              BorderThickness="1">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="132"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Version" Margin="0,0,12,8"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
          <TextBlock x:Name="VersionText" Grid.Row="0" Grid.Column="1" Margin="0,0,0,8"
                     AutomationProperties.Name="Version"/>
          <TextBlock Grid.Row="1" Text="PowerShell" Margin="0,0,12,8"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
          <TextBlock x:Name="PowerShellText" Grid.Row="1" Grid.Column="1" Margin="0,0,0,8"
                     AutomationProperties.Name="PowerShell version"/>
          <TextBlock Grid.Row="2" Text=".NET runtime" Margin="0,0,12,8"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
          <TextBlock x:Name="DotNetText" Grid.Row="2" Grid.Column="1" Margin="0,0,0,8"
                     AutomationProperties.Name=".NET runtime version"/>
          <TextBlock Grid.Row="3" Text="Smart shortcut" Margin="0,0,12,8"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
          <TextBlock x:Name="ShortcutText" Grid.Row="3" Grid.Column="1" Margin="0,0,0,8"
                     FontWeight="SemiBold"
                     AutomationProperties.Name="Active Smart capture shortcut"/>
          <TextBlock Grid.Row="4" Text="Repository" Margin="0,0,12,8"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
          <TextBlock Grid.Row="4" Grid.Column="1" Margin="0,0,0,8"
                     TextTrimming="CharacterEllipsis"
                     AutomationProperties.Name="Repository"><Hyperlink
              x:Name="RepositoryLink" ToolTip="Open the repository in your browser"><Run
              x:Name="RepositoryText"/></Hyperlink></TextBlock>
          <TextBlock Grid.Row="5" Text="Licence" Margin="0,0,12,0"
                     Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
          <TextBlock x:Name="LicenseText" Grid.Row="5" Grid.Column="1"
                     AutomationProperties.Name="Licence"/>
        </Grid>
      </Border>
    </StackPanel>
  </DockPanel>
</Window>

'@
    FloatingWidget = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SnipIT capture widget" WindowStyle="ToolWindow"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        ResizeMode="NoResize" Width="452" Height="112"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal"
        AutomationProperties.Name="SnipIT capture widget">
  <UniformGrid Rows="1" Columns="4" Margin="12">
    <Button x:Name="SmartBtn" TabIndex="0" Height="32" Margin="0,0,4,0"
            Style="{DynamicResource AccentButtonStyle}"
            ToolTip="Smart capture: click a window or drag a region"
            AutomationProperties.Name="Smart capture">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE7C5;" FontFamily="Segoe Fluent Icons" FontSize="14"
                   VerticalAlignment="Center" Margin="0,0,8,0"/>
        <AccessText Text="_Smart" VerticalAlignment="Center"/>
      </StackPanel>
    </Button>
    <Button x:Name="FullBtn" TabIndex="1" Height="32" Margin="4,0"
            ToolTip="Capture the full desktop"
            AutomationProperties.Name="Full desktop capture">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE740;" FontFamily="Segoe Fluent Icons" FontSize="14"
                   VerticalAlignment="Center" Margin="0,0,8,0"/>
        <AccessText Text="_Full" VerticalAlignment="Center"/>
      </StackPanel>
    </Button>
    <Button x:Name="WindowBtn" TabIndex="2" Height="32" Margin="4,0"
            ToolTip="Capture the active window"
            AutomationProperties.Name="Active window capture">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE737;" FontFamily="Segoe Fluent Icons" FontSize="14"
                   VerticalAlignment="Center" Margin="0,0,8,0"/>
        <AccessText Text="_Window" VerticalAlignment="Center"/>
      </StackPanel>
    </Button>
    <Button x:Name="SettingsBtn" TabIndex="3" Height="32" Margin="4,0,0,0"
            ToolTip="Open SnipIT Settings"
            AutomationProperties.Name="Open SnipIT Settings">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE713;" FontFamily="Segoe Fluent Icons" FontSize="14"
                   VerticalAlignment="Center" Margin="0,0,8,0"/>
        <AccessText Text="Se_ttings" VerticalAlignment="Center"/>
      </StackPanel>
    </Button>
  </UniformGrid>
</Window>

'@
}

# Portable presentation and display policy. No Windows runtime types belong here.

function New-SnipDisplayTopology {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$MonitorDescriptors,
        [string]$RequestId = ([guid]::NewGuid().ToString('N')),
        [datetime]$CapturedAtUtc = [datetime]::UtcNow
    )

    if ($null -eq $MonitorDescriptors -or $MonitorDescriptors.Count -eq 0) {
        throw [ArgumentException]::new(
            'At least one monitor descriptor is required.', 'MonitorDescriptors')
    }
    $descriptors = [Collections.Generic.List[object]]::new()
    foreach ($inputDescriptor in $MonitorDescriptors) {
        $descriptors.Add((Copy-SnipSemanticValue -Value $inputDescriptor))
    }
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $descriptors.ToArray())

    foreach ($layout in $layouts) {
        $descriptor = $layout.Descriptor
        $workDefaults = [ordered]@{
            WorkX = [double]$layout.PhysicalX
            WorkY = [double]$layout.PhysicalY
            WorkWidth = [double]$layout.PhysicalWidth
            WorkHeight = [double]$layout.PhysicalHeight
        }
        foreach ($entry in $workDefaults.GetEnumerator()) {
            if ($null -eq $descriptor.PSObject.Properties[$entry.Key]) {
                $descriptor | Add-Member -NotePropertyName $entry.Key `
                    -NotePropertyValue $entry.Value
            }
        }
    }

    $left = [double]($layouts | Measure-Object -Property PhysicalX -Minimum).Minimum
    $top = [double]($layouts | Measure-Object -Property PhysicalY -Minimum).Minimum
    $right = [double]($layouts | ForEach-Object {
        [double]$_.PhysicalX + [double]$_.PhysicalWidth
    } | Measure-Object -Maximum).Maximum
    $bottom = [double]($layouts | ForEach-Object {
        [double]$_.PhysicalY + [double]$_.PhysicalHeight
    } | Measure-Object -Maximum).Maximum

    $fingerprintRows = foreach ($layout in $layouts) {
        $descriptor = $layout.Descriptor
        $idBytes = [Text.Encoding]::UTF8.GetBytes([string]$layout.Id)
        $format = [Globalization.CultureInfo]::InvariantCulture
        [string]::Format($format,
            '{0}|{1}|{2}|{3}|{4}|{5:R}|{6:R}|{7:R}|{8:R}|{9:R}|{10:R}|{11}',
            [Convert]::ToBase64String($idBytes),
            [int]$layout.PhysicalX, [int]$layout.PhysicalY,
            [int]$layout.PhysicalWidth, [int]$layout.PhysicalHeight,
            [double]$descriptor.WorkX, [double]$descriptor.WorkY,
            [double]$descriptor.WorkWidth, [double]$descriptor.WorkHeight,
            [double]$layout.DpiX, [double]$layout.DpiY,
            [bool]$layout.IsPrimary)
    }
    $fingerprintBytes = [Text.Encoding]::UTF8.GetBytes(
        [string]::Join("`n", [string[]]@($fingerprintRows)))
    $fingerprint = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($fingerprintBytes)).ToLowerInvariant()

    [pscustomobject][ordered]@{
        RequestId = [string]$RequestId
        CapturedAtUtc = $CapturedAtUtc.ToUniversalTime().ToString(
            'O', [Globalization.CultureInfo]::InvariantCulture)
        Descriptors = [object[]]@($descriptors.ToArray() | ForEach-Object {
            Copy-SnipSemanticValue -Value $_
        })
        Layouts = [object[]]@($layouts | ForEach-Object {
            Copy-SnipSemanticValue -Value $_
        })
        VirtualPhysicalBounds = [pscustomobject][ordered]@{
            X = [int][math]::Round($left)
            Y = [int][math]::Round($top)
            Width = [int][math]::Round($right - $left)
            Height = [int][math]::Round($bottom - $top)
        }
        Fingerprint = $fingerprint
    }
}

# Rows for the tray's Display submenu, one per monitor. Pure so the WinForms
# side has nothing left to decide: the list seeded at menu construction and the
# list rebuilt on DropDownOpening come from this one builder. An empty monitor
# list yields a single disabled placeholder row, because WinForms gates both the
# submenu arrow and DropDownOpening on HasDropDownItems - a submenu that starts
# empty and hoped to fill itself on opening never opens at all.
function Get-SnipDisplayMenuModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Descriptors
    )

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($descriptor in @($Descriptors)) {
        if ($null -eq $descriptor) { continue }
        $monitorId = [string]$descriptor.Id
        $displayName = if ($null -ne $descriptor.PSObject.Properties['DisplayName'] -and
            -not [string]::IsNullOrWhiteSpace([string]$descriptor.DisplayName)) {
            [string]$descriptor.DisplayName
        } else { $monitorId }
        $primarySuffix = if ([bool]$descriptor.IsPrimary) { ' (Primary)' } else { '' }
        $itemName = 'Display_' + [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($monitorId)).TrimEnd('=')
        $itemText = '{0} - {1} x {2}{3}' -f $displayName,
            [int]$descriptor.Width, [int]$descriptor.Height, $primarySuffix
        $rows.Add([pscustomobject][ordered]@{
            Name = $itemName
            Text = $itemText
            MonitorId = $monitorId
            Enabled = $true
            IsPlaceholder = $false
        })
    }
    if ($rows.Count -eq 0) {
        $rows.Add([pscustomobject][ordered]@{
            Name = 'Display_None'
            Text = 'No displays detected'
            MonitorId = ''
            Enabled = $false
            IsPlaceholder = $true
        })
    }
    [object[]]@($rows.ToArray())
}

function Get-SnipWidgetPlacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Topology,
        [Parameter(Mandatory)] $PointerPhysicalPosition,
        [AllowNull()][string]$LastValidMonitorId = $null
    )

    foreach ($propertyName in 'X','Y') {
        if ($null -eq $PointerPhysicalPosition.PSObject.Properties[$propertyName]) {
            throw [ArgumentException]::new(
                "Pointer position is missing '$propertyName'.", 'PointerPhysicalPosition')
        }
    }
    $descriptors = @($Topology.Descriptors)
    if ($descriptors.Count -eq 0) {
        throw [ArgumentException]::new(
            'At least one monitor descriptor is required.', 'Topology')
    }

    $pointerX = [double]$PointerPhysicalPosition.X
    $pointerY = [double]$PointerPhysicalPosition.Y
    $monitor = $null
    foreach ($candidate in $descriptors) {
        $left = [double]$candidate.X
        $top = [double]$candidate.Y
        $right = $left + [double]$candidate.Width
        $bottom = $top + [double]$candidate.Height
        if ($pointerX -ge $left -and $pointerX -lt $right -and
            $pointerY -ge $top -and $pointerY -lt $bottom) {
            $monitor = $candidate
            break
        }
    }
    $virtualBounds = $Topology.VirtualPhysicalBounds
    $pointerIsInsideVirtualBounds = $pointerX -ge [double]$virtualBounds.X -and
        $pointerX -lt ([double]$virtualBounds.X + [double]$virtualBounds.Width) -and
        $pointerY -ge [double]$virtualBounds.Y -and
        $pointerY -lt ([double]$virtualBounds.Y + [double]$virtualBounds.Height)
    if ($null -eq $monitor -and $pointerIsInsideVirtualBounds -and
        -not [string]::IsNullOrWhiteSpace($LastValidMonitorId)) {
        $monitor = @($descriptors | Where-Object {
            [string]$_.Id -ceq $LastValidMonitorId
        }) | Select-Object -First 1
    }
    if ($null -eq $monitor) {
        $monitor = @($descriptors | Where-Object { [bool]$_.IsPrimary }) |
            Select-Object -First 1
    }
    if ($null -eq $monitor) {
        $monitor = $descriptors[0]
    }

    foreach ($propertyName in 'WorkX','WorkY','WorkWidth','WorkHeight','DpiX','DpiY') {
        if ($null -eq $monitor.PSObject.Properties[$propertyName]) {
            throw [ArgumentException]::new(
                "Monitor descriptor is missing '$propertyName'.", 'Topology')
        }
    }
    $monitorX = [double]$monitor.X
    $monitorY = [double]$monitor.Y
    $workX = [double]$monitor.WorkX
    $workY = [double]$monitor.WorkY
    $workWidth = [double]$monitor.WorkWidth
    $workHeight = [double]$monitor.WorkHeight
    $scaleX = [double]$monitor.DpiX / 96.0
    $scaleY = [double]$monitor.DpiY / 96.0

    [pscustomobject][ordered]@{
        MonitorId = [string]$monitor.Id
        Monitor = Copy-SnipSemanticValue -Value $monitor
        WorkAreaPhysicalBounds = [pscustomobject][ordered]@{
            X = [int][math]::Round($workX)
            Y = [int][math]::Round($workY)
            Width = [int][math]::Round($workWidth)
            Height = [int][math]::Round($workHeight)
        }
        MonitorLocalDipWorkArea = [pscustomobject][ordered]@{
            X = (ConvertTo-SnipDipPoint -PhysicalX $workX -PhysicalY $workY `
                -MonitorPhysicalX $monitorX -MonitorPhysicalY $monitorY `
                -ScaleX $scaleX -ScaleY $scaleY).X
            Y = (ConvertTo-SnipDipPoint -PhysicalX $workX -PhysicalY $workY `
                -MonitorPhysicalX $monitorX -MonitorPhysicalY $monitorY `
                -ScaleX $scaleX -ScaleY $scaleY).Y
            Width = $workWidth / $scaleX
            Height = $workHeight / $scaleY
        }
    }
}

function Get-SnipPreviewPlacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $CaptureBounds,
        [Parameter(Mandatory)] $Topology,
        [AllowNull()] $PointerPhysicalPosition = $null,
        [double]$SpanningCoverage = 0.8
    )

    foreach ($propertyName in 'X','Y','Width','Height') {
        if ($null -eq $CaptureBounds.PSObject.Properties[$propertyName]) {
            throw [ArgumentException]::new(
                "Capture bounds is missing '$propertyName'.", 'CaptureBounds')
        }
    }
    $descriptors = @($Topology.Descriptors)
    if ($descriptors.Count -eq 0) {
        throw [ArgumentException]::new(
            'At least one monitor descriptor is required.', 'Topology')
    }

    $captureLeft = [double]$CaptureBounds.X
    $captureTop = [double]$CaptureBounds.Y
    $captureRight = $captureLeft + [double]$CaptureBounds.Width
    $captureBottom = $captureTop + [double]$CaptureBounds.Height
    $captureCenterX = $captureLeft + ([double]$CaptureBounds.Width / 2)
    $captureCenterY = $captureTop + ([double]$CaptureBounds.Height / 2)
    $captureMonitor = $null
    $largestIntersection = -1.0
    $captureMonitorContainsCenter = $false
    $fullyCoveredCount = 0
    foreach ($monitor in $descriptors) {
        $left = [double]$monitor.X
        $top = [double]$monitor.Y
        $right = $left + [double]$monitor.Width
        $bottom = $top + [double]$monitor.Height
        $intersectionWidth = [math]::Max(0.0,
            [math]::Min($captureRight, $right) - [math]::Max($captureLeft, $left))
        $intersectionHeight = [math]::Max(0.0,
            [math]::Min($captureBottom, $bottom) - [math]::Max($captureTop, $top))
        $intersection = $intersectionWidth * $intersectionHeight
        $monitorArea = [double]$monitor.Width * [double]$monitor.Height
        if ($monitorArea -gt 0 -and ($intersection / $monitorArea) -ge $SpanningCoverage) {
            $fullyCoveredCount++
        }
        $containsCenter = $captureCenterX -ge $left -and $captureCenterX -lt $right -and
            $captureCenterY -ge $top -and $captureCenterY -lt $bottom
        $shouldSelect = $intersection -gt $largestIntersection
        if (-not $shouldSelect -and $intersection -eq $largestIntersection) {
            if ($containsCenter -and -not $captureMonitorContainsCenter) {
                $shouldSelect = $true
            } elseif ($containsCenter -eq $captureMonitorContainsCenter -and
                [bool]$monitor.IsPrimary -and -not [bool]$captureMonitor.IsPrimary) {
                $shouldSelect = $true
            }
        }
        if ($shouldSelect) {
            $captureMonitor = $monitor
            $largestIntersection = $intersection
            $captureMonitorContainsCenter = $containsCenter
        }
    }

    # Largest-intersection is the right answer for a capture that lives on one
    # monitor. It is the wrong answer for a full-desktop capture, which covers
    # every monitor and therefore always resolves to whichever display happens
    # to have the most pixels — the editor opens on the 4K panel even when the
    # user pressed the hotkey on the laptop screen. When the capture covers most
    # of more than one monitor there is no "capture monitor" to speak of, so
    # follow the user instead: the pointer's display, else the primary.
    $spansMultipleMonitors = $fullyCoveredCount -gt 1
    $placementReason = 'LargestIntersection'
    if ($spansMultipleMonitors) {
        $pointerMonitor = $null
        if ($null -ne $PointerPhysicalPosition -and
            $null -ne $PointerPhysicalPosition.PSObject.Properties['X'] -and
            $null -ne $PointerPhysicalPosition.PSObject.Properties['Y']) {
            $pointerX = [double]$PointerPhysicalPosition.X
            $pointerY = [double]$PointerPhysicalPosition.Y
            foreach ($monitor in $descriptors) {
                $left = [double]$monitor.X
                $top = [double]$monitor.Y
                if ($pointerX -ge $left -and $pointerX -lt ($left + [double]$monitor.Width) -and
                    $pointerY -ge $top -and $pointerY -lt ($top + [double]$monitor.Height)) {
                    $pointerMonitor = $monitor
                    break
                }
            }
        }
        if ($null -ne $pointerMonitor) {
            $captureMonitor = $pointerMonitor
            $placementReason = 'PointerMonitor'
        } else {
            $primaryMonitor = @($descriptors | Where-Object { [bool]$_.IsPrimary }) |
                Select-Object -First 1
            if ($null -ne $primaryMonitor) {
                $captureMonitor = $primaryMonitor
                $placementReason = 'PrimaryMonitor'
            } else {
                $placementReason = 'SpanningFallback'
            }
        }
    }

    $workX = [double]$captureMonitor.WorkX
    $workY = [double]$captureMonitor.WorkY
    $workWidth = [double]$captureMonitor.WorkWidth
    $workHeight = [double]$captureMonitor.WorkHeight
    $scaleX = [double]$captureMonitor.DpiX / 96.0
    $scaleY = [double]$captureMonitor.DpiY / 96.0
    $initialPhysicalWidth = [math]::Min(
        $workWidth, [math]::Round(1180.0 * $scaleX))
    $initialPhysicalHeight = [math]::Min(
        $workHeight, [math]::Round(760.0 * $scaleY))
    $initialPhysicalWidth = [math]::Max(
        [math]::Min($workWidth, [math]::Round(760.0 * $scaleX)),
        $initialPhysicalWidth)
    $initialPhysicalHeight = [math]::Max(
        [math]::Min($workHeight, [math]::Round(540.0 * $scaleY)),
        $initialPhysicalHeight)
    # Centring on the capture only means something when the capture's centre is
    # on the display we are placing onto. Clamping a far-away centre into the
    # work area pins the window against whichever edge is nearest — a
    # full-desktop capture centred over the neighbouring monitor used to open
    # flush against this one's left edge. Once the centre is outside, drop the
    # pretence and centre the window on the work area itself.
    $centreIsOnWorkArea = $captureCenterX -ge $workX -and
        $captureCenterX -lt ($workX + $workWidth) -and
        $captureCenterY -ge $workY -and
        $captureCenterY -lt ($workY + $workHeight)
    if ($centreIsOnWorkArea) {
        $initialX = [math]::Max($workX, [math]::Min(
            $captureCenterX - ($initialPhysicalWidth / 2),
            $workX + $workWidth - $initialPhysicalWidth))
        $initialY = [math]::Max($workY, [math]::Min(
            $captureCenterY - ($initialPhysicalHeight / 2),
            $workY + $workHeight - $initialPhysicalHeight))
        $anchor = 'CaptureCentre'
    } else {
        $initialX = $workX + (($workWidth - $initialPhysicalWidth) / 2)
        $initialY = $workY + (($workHeight - $initialPhysicalHeight) / 2)
        $anchor = 'WorkAreaCentre'
    }

    $initialDip = ConvertTo-SnipDipPoint -PhysicalX $initialX -PhysicalY $initialY `
        -MonitorPhysicalX 0 -MonitorPhysicalY 0 -ScaleX $scaleX -ScaleY $scaleY
    $initialPhysical = ConvertTo-SnipPhysicalPoint -DipX $initialDip.X -DipY $initialDip.Y `
        -MonitorPhysicalX 0 -MonitorPhysicalY 0 -ScaleX $scaleX -ScaleY $scaleY

    [pscustomobject][ordered]@{
        CaptureMonitor = $captureMonitor
        PlacementReason = $placementReason
        Anchor = $anchor
        SpansMultipleMonitors = $spansMultipleMonitors
        InitialBounds = [pscustomobject][ordered]@{
            X = $initialDip.X
            Y = $initialDip.Y
            Width = $initialPhysicalWidth / $scaleX
            Height = $initialPhysicalHeight / $scaleY
        }
        InitialPhysicalBounds = [pscustomobject][ordered]@{
            X = $initialPhysical.X
            Y = $initialPhysical.Y
            Width = [int][math]::Round($initialPhysicalWidth)
            Height = [int][math]::Round($initialPhysicalHeight)
        }
    }
}

function New-SnipPresentationState {
    [CmdletBinding()]
    param(
        [string]$ActiveTool = 'Select',
        [AllowNull()][AllowEmptyCollection()] [string[]]$RecentTools = @('Highlight','ArrowLine'),
        [double]$ViewportWidth = 1200,
        [double]$ViewportHeight = 760,
        [string]$StatusKind = 'Idle',
        [AllowNull()][string]$StatusText = '',
        [AllowNull()][string]$SelectionId = $null,
        [bool]$CanUndo = $false,
        [bool]$CanRedo = $false,
        [bool]$HasCrop = $false,
        [AllowNull()]$CaptureBounds = $null,
        [AllowNull()]$DisplayTopology = $null
    )

    [pscustomobject][ordered]@{
        ActiveTool = [string](Copy-SnipSemanticValue -Value $ActiveTool)
        RecentTools = [string[]](Copy-SnipSemanticValue -Value @($RecentTools))
        ViewportWidth = [double]$ViewportWidth
        ViewportHeight = [double]$ViewportHeight
        StatusKind = [string](Copy-SnipSemanticValue -Value $StatusKind)
        StatusText = [string](Copy-SnipSemanticValue -Value $StatusText)
        SelectionId = Copy-SnipSemanticValue -Value $SelectionId
        CanUndo = [bool]$CanUndo
        CanRedo = [bool]$CanRedo
        HasCrop = [bool]$HasCrop
        CaptureBounds = Copy-SnipSemanticValue -Value $CaptureBounds
        DisplayTopology = Copy-SnipSemanticValue -Value $DisplayTopology
    }
}

function Get-SnipPreviewCapabilities {
    [CmdletBinding()]
    param()

    [pscustomobject][ordered]@{
        SupportedTools = [string[]]@(
            'Select','Highlight','RectangleEllipse','ArrowLine','Text','Pen','Steps',
            'BlurPixelate','Crop')
        ExposedTools = [string[]]@(
            'Select','Highlight','RectangleEllipse','ArrowLine','Text','Pen','Steps',
            'BlurPixelate','Crop')
        Commands = [string[]]@(
            'CopyAndClose','CopyKeepOpen','Save','Close','NewSnip','Undo','Redo',
            'DeleteSelection','DuplicateSelection','ApplyCrop','ResetCrop','FocusCanvas')
    }
}

function Get-SnipToolbarPresentation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    $mode = 'Native'
    $order = [string[]]@(
        'Select','Highlight','RectangleEllipse','ArrowLine','Text','Pen','Steps',
        'BlurPixelate','Crop','Undo','Redo')
    $activeTool = if ([string]::IsNullOrWhiteSpace([string]$State.ActiveTool)) {
        'Select'
    } else {
        [string]$State.ActiveTool
    }
    [pscustomobject][ordered]@{
        Mode = $mode
        Order = [string[]]$order
        CheckedTool = $activeTool
        MoreActive = $false
        MoreTool = $null
    }
}

function Get-SnipStatusPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][double]$WindowWidth
    )

    $mode = Get-PreviewResponsiveMode -Width $State.ViewportWidth `
        -Height $State.ViewportHeight
    if ($State.StatusKind -eq 'Idle') {
        return [pscustomobject][ordered]@{
            Text = if ($mode -eq 'Narrow') {
                [string][char]0x25CF
            } else {
                'Non-destructive edit'
            }
            ToolTip = $null
            HelpText = ''
            Width = if ($mode -eq 'Narrow') { 42.0 } else { 150.0 }
            PaddingHorizontal = if ($mode -eq 'Narrow') { 0.0 } else { 10.0 }
            Trimming = 'None'
            IndicatorVisible = $mode -ne 'Narrow'
        }
    }

    $text = [string]$State.StatusText
    $desiredWidth = [math]::Max(150.0, 34.0 + $text.Length * 7.0)
    $width = switch ($mode) {
        'Compact' { 150.0 }
        'Narrow' {
            [math]::Min($desiredWidth, [math]::Max(150.0, $WindowWidth - 60.0))
        }
        default { $desiredWidth }
    }
    [pscustomobject][ordered]@{
        Text = $text
        ToolTip = $text
        HelpText = $text
        Width = [double]$width
        PaddingHorizontal = 10.0
        Trimming = if ($width -lt $desiredWidth) { 'CharacterEllipsis' } else { 'None' }
        IndicatorVisible = $mode -ne 'Narrow'
    }
}

function Get-SnipCommandPresentation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    $capabilities = Get-SnipPreviewCapabilities
    $selectionEnabled = -not [string]::IsNullOrWhiteSpace([string]$State.SelectionId)
    for ($index = 0; $index -lt $capabilities.Commands.Count; $index++) {
        $name = $capabilities.Commands[$index]
        $enabled = switch ($name) {
            'Undo' { [bool]$State.CanUndo }
            'Redo' { [bool]$State.CanRedo }
            { $_ -in @('DeleteSelection','DuplicateSelection') } { $selectionEnabled }
            { $_ -in @('ApplyCrop','ResetCrop') } { [bool]$State.HasCrop }
            default { $true }
        }
        [pscustomobject][ordered]@{
            Name = $name
            Visible = $true
            Enabled = [bool]$enabled
            Checked = $false
            Priority = $index
        }
    }
}

function Resolve-SnipPresentationKeyIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$FocusedRole,
        [Parameter(Mandatory)][hashtable]$EditorState,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][AllowEmptyCollection()][string[]]$Modifiers = @()
    )

    $command = Resolve-PreviewKeyCommand -FocusedRole $FocusedRole `
        -EditorState $EditorState -Key $Key -Modifiers $Modifiers
    if ($null -eq $command) { return $null }
    $canonicalCommand = switch ($command) {
        'NewSmartCapture' { 'NewSnip' }
        'ClosePreview' { 'Close' }
        default { [string]$command }
    }
    $type = if ($canonicalCommand -in @(
        'CopyKeepOpen','CopyAndClose','Save','NewSnip','Close')) {
        'InvokeCommand'
    } else {
        'RouteCommand'
    }
    [pscustomobject][ordered]@{
        Type = $type
        Command = $canonicalCommand
        SourceCommand = [string]$command
    }
}

function Invoke-SnipPresentationIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Intent
    )

    $nextState = Copy-SnipSemanticValue -Value $State
    $effects = [Collections.Generic.List[object]]::new()
    $type = [string]$Intent.Type
    switch ($type) {
        'ActivateTool' {
            $tool = [string]$Intent.Tool
            $changed = [string]$nextState.ActiveTool -ne $tool
            if ($changed) {
                $effects.Add([pscustomobject][ordered]@{ Name='CancelDraft' })
            }
            $nextState.ActiveTool = $tool
            if ($tool -in @('Highlight','ArrowLine','RectangleEllipse','Steps')) {
                $recent = [Collections.Generic.List[string]]::new()
                foreach ($candidate in @($tool) + @($nextState.RecentTools)) {
                    if (-not $recent.Contains([string]$candidate)) {
                        $recent.Add([string]$candidate)
                    }
                    if ($recent.Count -eq 2) { break }
                }
                $nextState.RecentTools = [string[]]$recent.ToArray()
            }
            $effects.Add([pscustomobject][ordered]@{ Name='RefreshActiveChrome' })
            if ($tool -in @(
                'Select','Crop','Pen','Highlight','ArrowLine','RectangleEllipse',
                'Text','Steps','BlurPixelate')) {
                $effects.Add([pscustomobject][ordered]@{ Name='RefreshPropertyIsland' })
            }
            $effects.Add([pscustomobject][ordered]@{ Name='RefreshResponsiveChrome' })
        }
        'ResizeViewport' {
            $nextState.ViewportWidth = [double]$Intent.Width
            $nextState.ViewportHeight = [double]$Intent.Height
            $effects.Add([pscustomobject][ordered]@{ Name='RefreshResponsiveChrome' })
            $effects.Add([pscustomobject][ordered]@{ Name='RefreshStatus' })
        }
        'SetStatus' {
            $nextState.StatusKind = [string]$Intent.Kind
            $nextState.StatusText = [string]$Intent.Text
            $effects.Add([pscustomobject][ordered]@{ Name='RefreshStatus' })
        }
        'ClearStatus' {
            $nextState.StatusKind = 'Idle'
            $nextState.StatusText = ''
            $effects.Add([pscustomobject][ordered]@{ Name='RefreshStatus' })
        }
        'SyncCommandState' {
            $nextState.SelectionId = Copy-SnipSemanticValue -Value $Intent.SelectionId
            $nextState.CanUndo = [bool]$Intent.CanUndo
            $nextState.CanRedo = [bool]$Intent.CanRedo
            $nextState.HasCrop = [bool]$Intent.HasCrop
        }
        'InvokeCommand' {
            $command = [string]$Intent.Command
            $commandState = @(Get-SnipCommandPresentation -State $nextState |
                Where-Object Name -eq $command | Select-Object -First 1)
            if ($commandState.Count -gt 0 -and $commandState[0].Enabled) {
                if ($command -in @('CopyAndClose','CopyKeepOpen')) {
                    $effects.Add([pscustomobject][ordered]@{
                        Name = 'Copy'
                        CloseAfter = $command -eq 'CopyAndClose'
                    })
                } else {
                    $effects.Add([pscustomobject][ordered]@{ Name=$command })
                }
            }
        }
        'UpdateDisplayTopology' {
            $nextState.DisplayTopology = Copy-SnipSemanticValue -Value $Intent.DisplayTopology
            $effects.Add([pscustomobject][ordered]@{ Name='ApplyPlacement' })
        }
        default {
            throw "Unknown presentation intent '$type'."
        }
    }

    [pscustomobject][ordered]@{
        State = $nextState
        Effects = [object[]]$effects.ToArray()
    }
}

if ($CoreOnly) { return }

if (-not $IsWindows) { throw 'SnipIT full runtime requires Windows. Use -CoreOnly for portable development.' }

$script:UndoStackMaxDepth = 100

$script:DiagRingSize = 200

$script:DiagRing     = New-Object System.Collections.Generic.Queue[string]

$script:SnipITAppVersion = '0.2.0'

$script:UtilityContext = $null

# Cached EDID friendly names, keyed by the device-interface paths they were
# built from, so a monitor being plugged in invalidates them by itself.
$script:SnipMonitorNameCache = $null

$script:SingleInstanceMutex = $null

$script:SnipBootstrapInitializer = {

    param([ValidateSet('Bootstrap', 'Settings')][string]$Phase)

    if ($Phase -eq 'Bootstrap') {

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process -FilePath $pwsh `
        -ArgumentList @('-Sta','-NoProfile','-WindowStyle','Hidden','-File',$script:SnipEntryPath) `
        -WindowStyle Hidden
    return
}

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

if ($h -ne [IntPtr]::Zero) {
    [ConsoleHider]::ShowWindow($h, 0) | Out-Null
    # Track even though hidden — a future ShowWindow we don't control could
    # bring it back, and the capture-target guard wants it in the self set.
    $script:ConsoleHwnd = $h
}

Add-Type -AssemblyName PresentationFramework

Add-Type -AssemblyName PresentationCore

Add-Type -AssemblyName WindowsBase

Add-Type -AssemblyName System.Windows.Forms

Add-Type -AssemblyName System.Drawing

if (-not $env:SNIPIT_TEST_MODE) {
    $script:SingleInstanceCreated = $false
    $script:SingleInstanceMutex   = New-Object System.Threading.Mutex(
        $true, 'Local\SnipIT-SingleInstance-v1', [ref]$script:SingleInstanceCreated)
    if (-not $script:SingleInstanceCreated) {
        try {
            [System.Windows.Forms.MessageBox]::Show(
                'SnipIT is already running. Check the system tray (bottom-right) or press Ctrl+Alt+Shift+Q.',
                'SnipIT', 'OK', 'Information') | Out-Null
        } catch {}
        try { $script:SingleInstanceMutex.Dispose() } catch {}
        return
    }
}

$desktopDir = [Environment]::GetFolderPath('Desktop')

$startupDir = [Environment]::GetFolderPath('Startup')

$script:InstallPaths = Get-InstallPaths -LocalAppData $env:LOCALAPPDATA `
    -DesktopDir $desktopDir -StartupDir $startupDir

$script:AppHomeDir = $script:InstallPaths.AppDir

$script:SettingsPath = Get-SnipSettingsPath

if (-not $env:SNIPIT_TEST_MODE) {
    New-Item -ItemType Directory -Force -Path $script:AppHomeDir | Out-Null
}

try { [System.Windows.Application]::Current.ThemeMode = 'System' } catch {}

        return $true

    }

$script:Settings = Get-SnipDefaultSettings

$script:SnipFreshInstall = $false

if (-not $env:SNIPIT_TEST_MODE) {
    $script:Settings = Read-SnipSettings -Path $script:SettingsPath
    Save-SnipSettings -Settings $script:Settings -Path $script:SettingsPath
    $script:SnipFreshInstall = Install-SnipIT -Paths $script:InstallPaths
    # This replaces the legacy unconditional Startup link with settings-owned
    # synchronization. Re-running is idempotent after the one-time migration.
    Sync-SnipStartupShortcut -Settings $script:Settings -Paths $script:InstallPaths
}

    $true

}

function Get-SnipXamlText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -ne $script:SnipEmbeddedXaml -and
        $script:SnipEmbeddedXaml.Contains($Name)) {
        return [string]$script:SnipEmbeddedXaml[$Name]
    }

    $resolver = Get-Variable -Name SnipDevelopmentXamlResolver -Scope Script `
        -ValueOnly -ErrorAction Ignore
    if ($resolver -is [scriptblock]) {
        return & $resolver $Name
    }

    throw ("Embedded XAML '$Name' is unavailable and no development XAML " +
        'resolver is configured.')
}

function Get-SnipSettingsPath {
    param([string]$LocalAppData = $env:LOCALAPPDATA)

    if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
        $LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
    }
    Join-Path $LocalAppData 'SnipIT\settings.json'
}

function Write-SnipDiag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        $ErrorRecord = $null,
        [string]$Path
    )

    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = if ($ErrorRecord) { "[$ts] $Message :: $($ErrorRecord.Exception.Message)" }
            else              { "[$ts] $Message" }
    $script:DiagRing.Enqueue($line)
    while ($script:DiagRing.Count -gt $script:DiagRingSize) { [void]$script:DiagRing.Dequeue() }

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            if ($env:SNIPIT_TEST_MODE) {
                # Test runs must never append to the installed app's log.
                $Path = Join-Path ([IO.Path]::GetTempPath()) 'snipit-test-logs\snipit.log'
            } else {
                $settingsDir = Split-Path (Get-SnipSettingsPath) -Parent
                $Path = Join-Path $settingsDir 'logs\snipit.log'
            }
        }
        $logDir = Split-Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir -ErrorAction Stop | Out-Null
        }
        Add-Content -LiteralPath $Path -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        # Diagnostics must never become a second application failure.
    }
}

function Get-SnipDiag { $script:DiagRing.ToArray() }

function Read-SnipSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string]$PicturesDir = [Environment]::GetFolderPath('MyPictures')
    )

    $defaults = Get-SnipDefaultSettings -PicturesDir $PicturesDir
    $diagPath = Join-Path (Split-Path $Path -Parent) 'logs\snipit.log'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) {
        Write-SnipDiag -Message "Settings file not found; using defaults: $Path" -Path $diagPath
        return $defaults
    }

    try {
        $loaded = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-SnipDiag -Message "Settings file is malformed; using defaults: $Path" -ErrorRecord $_ -Path $diagPath
        return $defaults
    }

    function Get-LoadedSetting {
        param([Parameter(Mandatory)] [string]$Name)
        $property = $loaded.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        $property.Value
    }

    # Version 1 is the only supported schema. Unknown or ill-typed versions
    # are normalized property-by-property through the same defaults below.
    $version = $defaults.Version

    $hotkey = $defaults.Hotkey
    $loadedHotkey = Get-LoadedSetting -Name 'Hotkey'
    if ($null -ne $loadedHotkey) {
        try {
            $modifiersProperty = $loadedHotkey.PSObject.Properties['Modifiers']
            $virtualKeyProperty = $loadedHotkey.PSObject.Properties['VirtualKey']
            if ($null -ne $modifiersProperty -and $null -ne $virtualKeyProperty) {
                $modifiers = [int]$modifiersProperty.Value
                $virtualKey = [int]$virtualKeyProperty.Value
                if (Test-SnipHotkeyDefinition -Modifiers $modifiers -VirtualKey $virtualKey) {
                    $hotkey = [pscustomobject][ordered]@{
                        Modifiers = $modifiers
                        VirtualKey = $virtualKey
                    }
                }
            }
        } catch {
            $hotkey = $defaults.Hotkey
        }
    }

    $saveFolderValue = Get-LoadedSetting -Name 'SaveFolder'
    $saveFolder = if ($saveFolderValue -is [string] -and
        -not [string]::IsNullOrWhiteSpace($saveFolderValue)) {
        $saveFolderValue
    } else {
        $defaults.SaveFolder
    }

    $saveFormatValue = Get-LoadedSetting -Name 'SaveFormat'
    $saveFormat = if ($saveFormatValue -is [string] -and
        $saveFormatValue -cin @('Png', 'Jpeg', 'Bmp')) {
        $saveFormatValue
    } else {
        $defaults.SaveFormat
    }

    $launchValue = Get-LoadedSetting -Name 'LaunchAtSignIn'
    $launchAtSignIn = if ($launchValue -is [bool]) { $launchValue } else { $defaults.LaunchAtSignIn }
    $widgetValue = Get-LoadedSetting -Name 'WidgetVisible'
    $widgetVisible = if ($widgetValue -is [bool]) { $widgetValue } else { $defaults.WidgetVisible }

    [pscustomobject][ordered]@{
        Version = $version
        Hotkey = $hotkey
        SaveFolder = $saveFolder
        SaveFormat = $saveFormat
        LaunchAtSignIn = $launchAtSignIn
        WidgetVisible = $widgetVisible
    }
}

function Save-SnipSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Settings,
        [Parameter(Mandatory)] [string]$Path
    )

    $directory = Split-Path $Path -Parent
    $candidate = $Settings | ConvertTo-Json -Depth 4 -ErrorAction Stop

    # Startup calls this unconditionally right after Read-SnipSettings, so the
    # common case is "nothing changed". Skip the write then: the temp-file+move
    # path below is still the only way the file is ever modified.
    $existing = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        try { $existing = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop }
        catch { $existing = $null }
    }
    if (Test-SnipSettingsUnchanged -Existing $existing -Candidate $candidate) { return }

    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
    }
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid())
    try {
        $candidate |
            Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM -ErrorAction Stop
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -ErrorAction Stop) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

# Embedded logo artwork, base64-encoded transparent PNGs. The 256 px master
# drives the large ICO entry and the 48 px downscale; the simplified 32 px
# variant drives the 32 / 24 / 16 px slots, where the master's fine detail
# would collapse into mush. Both are the single source of the artwork:
# Get-SnipITLogoBitmap / Get-SnipITLogoSmallBitmap decode them and the ICO
# writer never touches the encoding.
$script:SnipLogoPng256 = @'
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
/x9u+4KtBbU8WwAAAABJRU5ErkJggg==
'@

$script:SnipLogoPng32 = @'
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
'@

# Decodes one of the embedded base64 PNG constants. Returns $null when the
# constant is empty (which is what selects the procedural fallback).
function Get-SnipLogoPngBytes {
    [CmdletBinding()]
    param([ValidateSet('Master', 'Small')] [string]$Variant = 'Master')

    $encoded = if ($Variant -eq 'Small') { [string]$script:SnipLogoPng32 }
               else                      { [string]$script:SnipLogoPng256 }
    if ([string]::IsNullOrWhiteSpace($encoded)) { return $null }
    # The constants are wrapped for readability, so strip the line breaks.
    $compact = [System.Text.RegularExpressions.Regex]::Replace($encoded, '\s+', '')
    if ([string]::IsNullOrWhiteSpace($compact)) { return $null }
    return , [System.Convert]::FromBase64String($compact)
}

# Decodes PNG bytes into an owned 32-bpp ARGB Bitmap of the requested size.
function ConvertFrom-SnipLogoPng {
    [CmdletBinding()]
    [OutputType([System.Drawing.Bitmap])]
    param(
        [Parameter(Mandatory)] [byte[]]$Bytes,
        [Parameter(Mandatory)] [int]$Size
    )

    $stream = New-Object System.IO.MemoryStream (, $Bytes)
    try {
        $decoded = [System.Drawing.Image]::FromStream($stream)
        try {
            $canvas = New-Object System.Drawing.Bitmap $Size, $Size, `
                ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $painter = [System.Drawing.Graphics]::FromImage($canvas)
            try {
                $painter.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $painter.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $painter.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $painter.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $painter.DrawImage($decoded, (New-Object System.Drawing.Rectangle 0, 0, $Size, $Size))
            } finally { $painter.Dispose() }
            return $canvas
        } finally { $decoded.Dispose() }
    } finally { $stream.Dispose() }
}

# Resolves everything the ICO writer needs from the embedded artwork:
#
#   Master    - a 256x256 Bitmap, always present; the procedural mark when
#               the embedded asset is absent or fails to decode.
#   MasterPng - the master's original encoded PNG bytes, so the 256 entry can
#               travel into the .ico byte-for-byte. $null when the procedural
#               fallback was used, which is what stops the writer from
#               pairing a fallback bitmap with unrelated PNG bytes.
#   Small     - the simplified 32x32 Bitmap for the small entries, or $null.
#
# Caller owns and must dispose Master and Small.
function Get-SnipITLogoSource {
    [CmdletBinding()]
    param()

    $masterPng = $null
    $master = $null
    try {
        $masterPng = Get-SnipLogoPngBytes -Variant Master
        if ($null -ne $masterPng) {
            $master = ConvertFrom-SnipLogoPng -Bytes $masterPng -Size 256
        }
    } catch {
        Write-SnipDiag -Message 'Embedded 256 px logo could not be decoded; using the procedural mark' -ErrorRecord $_
        $master = $null
    }
    if ($null -eq $master) {
        $masterPng = $null
        $master = New-SnipITProceduralLogoBitmap
    }

    $small = $null
    try {
        $smallPng = Get-SnipLogoPngBytes -Variant Small
        if ($null -ne $smallPng) {
            $small = ConvertFrom-SnipLogoPng -Bytes $smallPng -Size 32
        }
    } catch {
        Write-SnipDiag -Message 'Embedded 32 px logo could not be decoded; deriving small sizes from the master' -ErrorRecord $_
        $small = $null
    }

    [pscustomobject]@{ Master = $master; MasterPng = $masterPng; Small = $small }
}

# Returns the 256x256 master bitmap. Caller owns it and must dispose it.
function Get-SnipITLogoBitmap {
    [CmdletBinding()]
    [OutputType([System.Drawing.Bitmap])]
    param()

    $source = Get-SnipITLogoSource
    if ($null -ne $source.Small) { $source.Small.Dispose() }
    return $source.Master
}

# Returns the simplified 32x32 artwork used for the small ICO entries, or
# $null when there is none (the master then covers every size).
function Get-SnipITLogoSmallBitmap {
    [CmdletBinding()]
    [OutputType([System.Drawing.Bitmap])]
    param()

    $source = Get-SnipITLogoSource
    $source.Master.Dispose()
    return $source.Small
}

# Fallback mark, drawn at 256x256 so every downscaled ICO entry still has
# real detail to work from.
function New-SnipITProceduralLogoBitmap {
    [CmdletBinding()]
    [OutputType([System.Drawing.Bitmap])]
    param()

    $size = 256
    $bmp = New-Object System.Drawing.Bitmap $size, $size, `
        ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
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

    return $bmp
}

# Renders one 32-bpp BGRA ICONDIRENTRY payload: a BITMAPINFOHEADER whose
# height is doubled (XOR colour bitmap stacked over the AND mask), the XOR
# rows bottom-up, then an all-zero AND mask. Windows picks these DIB entries
# for tray / taskbar / Explorer sizes; without them System.Drawing.Icon has
# only the 256 px PNG to squash down and the glyph reads as a blur.
function ConvertTo-SnipIconDibBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Bitmap,
        [Parameter(Mandatory)] [int]$Size
    )

    $scaled = New-Object System.Drawing.Bitmap $Size, $Size, `
        ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    $attributes = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($scaled)
        # SourceCopy keeps the master's alpha instead of blending it against
        # the (transparent) canvas, which is what preserves crisp edges.
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $attributes = New-Object System.Drawing.Imaging.ImageAttributes
        # Mirror at the edges so bicubic sampling never reaches past the
        # source rectangle and ghosts a transparent border in.
        $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $graphics.DrawImage($Bitmap,
            (New-Object System.Drawing.Rectangle 0, 0, $Size, $Size),
            0, 0, $Bitmap.Width, $Bitmap.Height,
            [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    } finally {
        if ($null -ne $graphics)   { $graphics.Dispose() }
        if ($null -ne $attributes) { $attributes.Dispose() }
    }

    $lockRect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $locked = $scaled.LockBits($lockRect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = [int]$locked.Stride
    $pixels = New-Object byte[] ($stride * $Size)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $pixels, 0, $pixels.Length)
    } finally {
        $scaled.UnlockBits($locked)
        $scaled.Dispose()
    }

    $rowBytes = $Size * 4
    $maskStride = [int]([math]::Floor(($Size + 31) / 32) * 4)
    $xorLength = $rowBytes * $Size
    $andLength = $maskStride * $Size

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        # BITMAPINFOHEADER (40 bytes)
        $writer.Write([uint32]40)                          # biSize
        $writer.Write([int32]$Size)                        # biWidth
        $writer.Write([int32]($Size * 2))                  # biHeight (XOR + AND)
        $writer.Write([uint16]1)                           # biPlanes
        $writer.Write([uint16]32)                          # biBitCount
        $writer.Write([uint32]0)                           # biCompression = BI_RGB
        $writer.Write([uint32]($xorLength + $andLength))   # biSizeImage
        $writer.Write([int32]0)                            # biXPelsPerMeter
        $writer.Write([int32]0)                            # biYPelsPerMeter
        $writer.Write([uint32]0)                           # biClrUsed
        $writer.Write([uint32]0)                           # biClrImportant
        # XOR bitmap, bottom-up. Format32bppArgb is already B,G,R,A in memory.
        for ($y = $Size - 1; $y -ge 0; $y--) {
            $writer.Write($pixels, ($y * $stride), $rowBytes)
        }
        # AND mask: ignored for 32-bpp entries, but the row-padded block has
        # to be present or the entry parses as truncated.
        $writer.Write((New-Object byte[] $andLength))
        $writer.Flush()
        return , $stream.ToArray()
    } finally {
        $writer.Dispose(); $stream.Dispose()
    }
}

# Builds a complete multi-entry .ICO: one 32-bpp DIB entry per requested
# -Sizes value plus the master as a trailing PNG entry. Pure with respect to
# the filesystem so it can be unit tested.
#
# -SmallBitmap is the optional simplified artwork used for every size at or
# below -SmallSizeMax; the master covers the rest. -MasterPngBytes embeds an
# already-encoded PNG for the trailing entry instead of re-encoding, which is
# what lets the shipped 256 px asset travel into the .ico byte-for-byte.
function ConvertTo-SnipIcoBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Bitmap,
        [int[]]$Sizes = @(16, 24, 32, 48),
        $SmallBitmap = $null,
        [int]$SmallSizeMax = 32,
        [byte[]]$MasterPngBytes = $null
    )

    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($size in @($Sizes | Sort-Object -Unique)) {
        $source = if ($null -ne $SmallBitmap -and [int]$size -le $SmallSizeMax) {
            $SmallBitmap
        } else {
            $Bitmap
        }
        $entries.Add([pscustomobject]@{
            Width  = [int]$size
            Height = [int]$size
            Data   = (ConvertTo-SnipIconDibBytes -Bitmap $source -Size ([int]$size))
        })
    }

    # The master ships last, PNG-compressed. Windows uses it for the 256 px
    # "Extra large icons" view and for anything above the DIB set.
    if ($null -ne $MasterPngBytes -and $MasterPngBytes.Length -gt 0) {
        $entries.Add([pscustomobject]@{
            Width  = [int]$Bitmap.Width
            Height = [int]$Bitmap.Height
            Data   = $MasterPngBytes
        })
    } else {
        $pngStream = New-Object System.IO.MemoryStream
        try {
            $Bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
            $entries.Add([pscustomobject]@{
                Width  = [int]$Bitmap.Width
                Height = [int]$Bitmap.Height
                Data   = $pngStream.ToArray()
            })
        } finally { $pngStream.Dispose() }
    }

    $offset = 6 + (16 * $entries.Count)

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        # ICONDIR (6 bytes)
        $writer.Write([uint16]0)                  # idReserved
        $writer.Write([uint16]1)                  # idType = icon
        $writer.Write([uint16]$entries.Count)     # idCount
        # ICONDIRENTRY table (16 bytes each), offsets running past the table.
        foreach ($entry in $entries) {
            $writer.Write([byte]($entry.Width % 256))   # 256 encodes as 0
            $writer.Write([byte]($entry.Height % 256))
            $writer.Write([byte]0)                      # bColorCount (0 = truecolor)
            $writer.Write([byte]0)                      # bReserved
            $writer.Write([uint16]1)                    # wPlanes
            $writer.Write([uint16]32)                   # wBitCount
            $writer.Write([uint32]$entry.Data.Length)   # dwBytesInRes
            $writer.Write([uint32]$offset)              # dwImageOffset
            $offset += $entry.Data.Length
        }
        foreach ($entry in $entries) { $writer.Write($entry.Data) }
        $writer.Flush()
        return , $stream.ToArray()
    } finally {
        $writer.Dispose(); $stream.Dispose()
    }
}

# Writes the .ICO only when its content actually changed, tracked by a
# SnipIT.ico.sha256 sidecar. Returns $true when the file was rewritten.
function Save-SnipIconFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [byte[]]$Bytes
    )

    $sidecar = "$Path.sha256"
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
        $recorded = $null
        try { $recorded = (Get-Content -LiteralPath $sidecar -Raw -ErrorAction Stop).Trim() }
        catch { $recorded = $null }
        if ($recorded -eq $hash) { return $false }
    }

    $parent = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
    Set-Content -LiteralPath $sidecar -Value $hash -Encoding ascii -NoNewline
    return $true
}

# Reads the SHA-256 recorded beside an .ico by Save-SnipIconFile, so the caller
# can tell one build of the artwork from another without re-rendering it. Falls
# back to hashing the file when the sidecar is missing (an .ico written by an
# older SnipIT), and returns '' when there is no icon at all — which
# Test-SnipShortcutCurrent then treats as an unmanaged field.
function Get-SnipIconStamp {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$IconPath)

    if ([string]::IsNullOrWhiteSpace($IconPath)) { return '' }

    $sidecar = "$IconPath.sha256"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        try {
            $recorded = (Get-Content -LiteralPath $sidecar -Raw -ErrorAction Stop).Trim()
            if ($recorded -ne '') { return $recorded }
        } catch { }
    }
    if (Test-Path -LiteralPath $IconPath -PathType Leaf) {
        try { return (Get-FileHash -LiteralPath $IconPath -Algorithm SHA256 -ErrorAction Stop).Hash }
        catch { }
    }
    return ''
}

# Returns $true when the .ico bytes on disk actually changed.
function New-SnipITIcon {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int[]]$Sizes = @(16, 24, 32, 48)
    )

    # 48 px comes off the 256 master; 32 / 24 / 16 come off the simplified
    # small variant, and the master's own PNG bytes ship as the 256 entry.
    $logo = Get-SnipITLogoSource
    try {
        $bytes = ConvertTo-SnipIcoBytes -Bitmap $logo.Master -Sizes $Sizes `
            -SmallBitmap $logo.Small -SmallSizeMax 32 -MasterPngBytes $logo.MasterPng
    } finally {
        if ($null -ne $logo.Small) { $logo.Small.Dispose() }
        $logo.Master.Dispose()
    }

    return (Save-SnipIconFile -Path $Path -Bytes $bytes)
}

$script:SnipIconEnsuredPath = $null

# True once this launch has actually rewritten SnipIT.ico. Explorer's icon cache
# is keyed on the source path, not its contents, so new artwork under the same
# path needs an explicit shell notification before anyone sees it.
$script:SnipIconContentChanged = $false

function Get-SnipITIconPath {
    $p = Join-Path $script:AppHomeDir 'SnipIT.ico'
    # Called twice per launch (Install-SnipIT, then the tray). The second call
    # is a no-op, and even a cold call only touches the disk when the rendered
    # bytes differ from the hash recorded beside the .ico.
    if ($script:SnipIconEnsuredPath -eq $p) { return $p }
    if (New-SnipITIcon -Path $p) { $script:SnipIconContentChanged = $true }
    $script:SnipIconEnsuredPath = $p
    return $p
}

# Tells the shell that one item changed, so Explorer re-reads the icon for it
# instead of redrawing the bitmap it cached the first time it saw the .lnk.
# Best-effort: an icon that fails to refresh is cosmetic, never fatal.
function Update-SnipShellItem {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not ('Native' -as [type])) { return $false }

    $buffer = [IntPtr]::Zero
    try {
        $buffer = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($Path)
        [Native]::SHChangeNotify([Native]::SHCNE_UPDATEITEM, [Native]::SHCNF_PATHW,
            $buffer, [IntPtr]::Zero)
        return $true
    } catch {
        Write-SnipDiag -Message "SHChangeNotify(UPDATEITEM) failed for '$Path': $($_.Exception.Message)"
        return $false
    } finally {
        if ($buffer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeCoTaskMem($buffer)
        }
    }
}

$script:SnipShellIconCacheFlushed = $false

# SHCNE_UPDATEITEM refreshes the view entry for a shortcut but does not evict the
# icon bitmap the shell already cached for SnipIT.ico; only SHCNE_ASSOCCHANGED
# does that. It is a broadcast to every shell window, so it is sent at most once
# per launch and only when the .ico bytes really changed.
function Invoke-SnipShellIconCacheFlush {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:SnipShellIconCacheFlushed) { return $false }
    if (-not ('Native' -as [type])) { return $false }

    try {
        [Native]::SHChangeNotify([Native]::SHCNE_ASSOCCHANGED, [Native]::SHCNF_IDLIST,
            [IntPtr]::Zero, [IntPtr]::Zero)
        $script:SnipShellIconCacheFlushed = $true
        return $true
    } catch {
        Write-SnipDiag -Message "SHChangeNotify(ASSOCCHANGED) failed: $($_.Exception.Message)"
        return $false
    }
}

function Write-SnipITShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Paths,
        [string]$IconPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$Paths.DesktopShortcut)) { return }
    Write-SnipITShortcut -Path $Paths.DesktopShortcut -AppDir $Paths.AppDir `
        -ScriptTarget $Paths.ScriptPath -IconPath $IconPath | Out-Null
}

# Creates or repairs the .lnk. The shortcut is only saved when it is missing
# or its TargetPath / Arguments / IconLocation drifted from what we want; an
# up-to-date shortcut is left completely untouched (never deleted first).
# Returns $true when the shortcut was written.
function Write-SnipITShortcut {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$AppDir,
        [Parameter(Mandatory)] [string]$ScriptTarget,
        [string]$IconPath
    )

    $parent = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $desiredIcon = ''
    if (-not [string]::IsNullOrWhiteSpace($IconPath) -and
        (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
        $desiredIcon = "$IconPath,0"
    }
    $desired = [pscustomobject]@{
        TargetPath   = (Get-Process -Id $PID).Path
        Arguments    = Get-ShortcutArguments -ScriptPath $ScriptTarget
        IconLocation = $desiredIcon
        # Carries the icon's content hash, so redrawn artwork counts as drift.
        Description  = Get-SnipShortcutDescription -IconStamp (Get-SnipIconStamp -IconPath $IconPath)
    }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        # CreateShortcut loads the existing .lnk when one is there, so this
        # doubles as the read for the drift comparison below.
        $shortcut = $shell.CreateShortcut($Path)

        $existing = $null
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $existing = [pscustomobject]@{
                TargetPath   = [string]$shortcut.TargetPath
                Arguments    = [string]$shortcut.Arguments
                IconLocation = [string]$shortcut.IconLocation
                Description  = [string]$shortcut.Description
            }
        }
        if (Test-SnipShortcutCurrent -Existing $existing -Desired $desired) {
            return $false
        }

        $shortcut.TargetPath = $desired.TargetPath
        $shortcut.Arguments = $desired.Arguments
        $shortcut.WorkingDirectory = $AppDir
        if ($desired.IconLocation -ne '') {
            $shortcut.IconLocation = $desired.IconLocation
        }
        $shortcut.WindowStyle = 7
        $shortcut.Description = $desired.Description
        $shortcut.Save()
        # The bytes on disk are right, but Explorer is still holding the bitmap
        # it drew the first time it saw this .lnk. Ask it to re-read the item.
        Update-SnipShellItem -Path $Path | Out-Null
        return $true
    } finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Sync-SnipStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Settings,
        [Parameter(Mandatory)] [object]$Paths
    )

    if ($env:SNIPIT_TEST_MODE -or
        [string]::IsNullOrWhiteSpace([string]$Paths.StartupShortcut)) {
        return
    }

    if ([bool]$Settings.LaunchAtSignIn) {
        $iconPath = Join-Path $Paths.AppDir 'SnipIT.ico'
        Write-SnipITShortcut -Path $Paths.StartupShortcut -AppDir $Paths.AppDir `
            -ScriptTarget $Paths.ScriptPath -IconPath $iconPath | Out-Null
    } elseif (Test-Path -LiteralPath $Paths.StartupShortcut) {
        Remove-Item -LiteralPath $Paths.StartupShortcut -Force -ErrorAction Stop
    }
}

function Install-SnipIT {
    param([object]$Paths = $script:InstallPaths)

    if ($env:SNIPIT_TEST_MODE) { return $false }

    $appDir = $Paths.AppDir
    $marker = $Paths.Marker
    $target = $Paths.ScriptPath

    $fresh = -not (Test-Path $marker)
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null

    # Copy the running script into the per-user app directory unless it is
    # already the executing copy.
    $runningFull = [System.IO.Path]::GetFullPath($script:SnipInstallSourcePath)
    $targetFull  = [System.IO.Path]::GetFullPath($target)
    if ($runningFull -ne $targetFull) {
        Copy-Item -LiteralPath $script:SnipInstallSourcePath -Destination $target -Force
    }

    $iconPath = Get-SnipITIconPath
    Write-SnipITShortcuts -Paths $Paths -IconPath $iconPath

    # Rewriting the .lnk above is not enough on its own: the shell caches icon
    # bitmaps per source module, and only SHCNE_ASSOCCHANGED drops the one it
    # holds for SnipIT.ico. Sent only when this launch redrew the artwork.
    if ($script:SnipIconContentChanged) { Invoke-SnipShellIconCacheFlush | Out-Null }

    if ($fresh) { Set-Content -LiteralPath $marker -Value (Get-Date -Format o) }
    return $fresh
}

function Uninstall-SnipIT {
    Remove-Item -Force -ErrorAction SilentlyContinue `
        $script:InstallPaths.DesktopShortcut,
        $script:InstallPaths.StartupShortcut
    # Remove the app's user-scoped LocalAppData contents.
    if (Test-Path $script:AppHomeDir) {
        Get-ChildItem -LiteralPath $script:AppHomeDir -Force |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Reports the Windows app theme as 'Light' or 'Dark'. The registry read is
# injected through -Reader so tests can pin a value without touching HKCU;
# a missing or unreadable value falls back to 'Light'.
function Get-SnipSystemThemeMode {
    [CmdletBinding()]
    param(
        [scriptblock]$Reader = {
            try {
                Get-ItemPropertyValue `
                    -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                    -Name 'AppsUseLightTheme' -ErrorAction Stop
            } catch { $null }
        }
    )

    $value = & $Reader
    $numeric = $value -as [int]
    if ($null -ne $value -and $null -ne $numeric -and $numeric -eq 0) { 'Dark' } else { 'Light' }
}

# Reports whether Windows is in High Contrast. The read is injected through
# -Reader so the suite can pin either answer; a reader that cannot answer -- no
# UI assemblies, a hostile host -- reads as $false, which is the safe default
# because it only means the ordinary theme path runs.
function Test-SnipHighContrast {
    [CmdletBinding()]
    param(
        [scriptblock]$Reader = { [System.Windows.SystemParameters]::HighContrast }
    )

    try { [bool](& $Reader) } catch { $false }
}

# Opts WinForms into the system colour mode, so the one piece of chrome SnipIT
# does not draw in WPF -- the tray context menu -- follows the Windows app theme.
#
# That menu is a stock ContextMenuStrip on the stock ToolStripProfessionalRenderer
# and it stays that way: no custom renderer, no colour table of ours. What it
# needed was the opt-in, because WinForms renders its light palette whatever the
# system theme says until an app asks otherwise, which is why the menu came up
# white on a Dark desktop. SetColorMode is that vanilla opt-in and it has to run
# before the first Form, NotifyIcon or ContextMenuStrip exists.
#
# It arrived in .NET 9 and is still marked experimental, so it is reached by
# reflection: an absent type, an absent method or a host that refuses all land on
# $false and the menu simply looks the way it did before.
function Enable-SnipWinFormsColorMode {
    [CmdletBinding()]
    param(
        [ValidateSet('Classic', 'System', 'Dark')]
        [string]$ColorMode = 'System'
    )

    $modeType = 'System.Windows.Forms.SystemColorMode' -as [type]
    $applicationType = 'System.Windows.Forms.Application' -as [type]
    if ($null -eq $modeType -or $null -eq $applicationType) { return $false }
    try {
        $method = $applicationType.GetMethod('SetColorMode', [type[]]@($modeType))
        if ($null -eq $method) { return $false }
        [void]$method.Invoke($null, @([Enum]::Parse($modeType, $ColorMode)))
        $true
    } catch {
        Write-SnipDiag -Message 'WinForms colour mode opt-in failed' -ErrorRecord $_
        $false
    }
}

# Every Fluent resource key whose value paints a surface, a bar, a card, a
# border or text -- i.e. everything that is not an accent control. Matching is
# by prefix so each family's variants (…Brush, …Alt, …Solid, …PointerOver,
# …Disabled) come along without listing them one by one, and any key holding
# 'Accent' is skipped outright: the Windows accent is the one colour in the app.
$script:SnipNeutralSurfaceKeyPrefixes = @(
    'ApplicationBackground'
    'SolidBackgroundFillColor'
    'LayerFillColor'
    'LayerOnAcrylicFillColor'
    'LayerOnMicaBaseAltFillColor'
    'AcrylicBackgroundFillColor'
    'CardBackgroundFillColor'
    'CardStrokeColor'
    'ControlFillColor'
    'ControlAltFillColor'
    'ControlStrokeColor'
    'ControlStrongFillColor'
    'ControlStrongStrokeColor'
    'DividerStrokeColor'
    'SubtleFillColor'
    'SurfaceStrokeColor'
    'TextFillColor'
    'ToolBarBackground'
    'ToolBarTrayBackground'
    'ToolBarHorizontalBackground'
    'ToolBarVerticalBackground'
    'StatusBarBackground'
    'StatusBarItemBackground'
)

# Rewrites those keys, in whichever merged dictionary owns them, to the neutral
# colour of the same alpha and the same weight (see Get-SnipNeutralColor), and
# pins the application ground to pure black in Dark and pure white in Light.
#
# Stock Fluent is already neutral on a clean Windows install, so on most
# machines this only moves the ground (#202020 -> #000000, #FAFAFA -> #FFFFFF)
# and snaps the near-black / near-white surfaces. It is a guard as much as a
# repaint: an OEM, high-contrast or future Fluent dictionary that ships a warm
# grey cannot leak a hue into the chrome, whatever the ambient theme does.
#
# Nothing is added to Window.Resources and no key holding 'Accent' is read or
# written, so the accent controls stay exactly as Windows painted them.
function Set-SnipNeutralSurfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window,
        [Parameter(Mandatory)]
        [ValidateSet('Light','Dark')]
        [string]$Mode
    )

    $black = [System.Windows.Media.Color]::FromRgb(0, 0, 0)
    $white = [System.Windows.Media.Color]::FromRgb(255, 255, 255)
    $ground = if ($Mode -eq 'Dark') { $black } else { $white }
    # The ground is not a luminance question: the window is the bottom layer, so
    # it is pinned to the pure value rather than to Fluent's near-black grey.
    $groundKeys = @{
        'ApplicationBackgroundColor' = $ground
        'ApplicationBackgroundBrush' = $ground
        'ApplicationBackgroundColorDark' = $black
        'ApplicationBackgroundColorDarkBrush' = $black
        'ApplicationBackgroundColorLight' = $white
        'ApplicationBackgroundColorLightBrush' = $white
    }

    $visited = [System.Collections.Generic.HashSet[int]]::new()
    $pending = [System.Collections.Generic.Queue[System.Windows.ResourceDictionary]]::new()
    $pending.Enqueue($Window.Resources)
    $application = [System.Windows.Application]::Current
    if ($null -ne $application -and $null -ne $application.Resources) {
        $pending.Enqueue($application.Resources)
    }

    $changed = 0
    while ($pending.Count -gt 0) {
        $dictionary = $pending.Dequeue()
        if ($null -eq $dictionary) { continue }
        # Fluent merges the same dictionary instance into several parents;
        # reference identity, not Equals, is what stops the walk looping.
        $identity = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($dictionary)
        if (-not $visited.Add($identity)) { continue }
        foreach ($merged in @($dictionary.MergedDictionaries)) { $pending.Enqueue($merged) }

        foreach ($key in @($dictionary.Keys)) {
            $name = [string]$key
            if ($name -like '*Accent*') { continue }
            $forced = $null
            if ($groundKeys.ContainsKey($name)) {
                $forced = $groundKeys[$name]
            } else {
                $matched = $false
                foreach ($prefix in $script:SnipNeutralSurfaceKeyPrefixes) {
                    if ($name.StartsWith($prefix, [StringComparison]::Ordinal)) {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) { continue }
            }

            $current = $null
            try { $current = $dictionary[$key] } catch { continue }
            $source = if ($current -is [System.Windows.Media.Color]) {
                $current
            } elseif ($current -is [System.Windows.Media.SolidColorBrush]) {
                $current.Color
            } else { $null }
            if ($null -eq $source) { continue }

            if ($null -ne $forced) {
                $target = [System.Windows.Media.Color]::FromArgb(
                    $source.A, $forced.R, $forced.G, $forced.B)
            } else {
                $neutral = Get-SnipNeutralColor -Color $source
                $target = [System.Windows.Media.Color]::FromArgb(
                    [byte]$neutral.A, [byte]$neutral.R, [byte]$neutral.G, [byte]$neutral.B)
            }
            if ($target -eq $source) { continue }

            try {
                if ($current -is [System.Windows.Media.Color]) {
                    $dictionary[$key] = $target
                } else {
                    $brush = [System.Windows.Media.SolidColorBrush]::new($target)
                    $brush.Freeze()
                    $dictionary[$key] = $brush
                }
                $changed++
            } catch {
                Write-SnipDiag -Message "neutralise failed for '$name'" -ErrorRecord $_
            }
        }
    }

    $changed
}

# Reports the Windows accent family -- variant name -> '#AARRGGBB' -- as the
# stock Fluent dictionaries were built from it. This is the set of colours the
# red swap has to find, so it is read from the same place Fluent read it rather
# than from the dictionary, whose SystemAccentColor* entries are unresolved
# dynamic references until something asks a control for them.
#
# The read goes through -Reader so the suite can pin a synthetic family, and a
# reader that cannot answer yields an empty family, which makes the swap a no-op
# instead of an error on a host with no accent to speak of.
function Get-SnipSystemAccentFamily {
    [CmdletBinding()]
    param(
        [scriptblock]$Reader = {
            param([string]$Property)
            [System.Windows.SystemColors]::$Property
        }
    )

    $family = [ordered]@{}
    foreach ($name in $script:SnipAccentVariantOrder) {
        $property = if ($name -eq 'Base') { 'AccentColor' } else { "AccentColor$name" }
        try {
            $value = & $Reader $property
            if ($null -eq $value) { continue }
            $family[$name] = (Get-SnipColorChannels -Color $value).Hex
        } catch {
            Write-SnipDiag -Message "system accent read failed for '$property'" -ErrorRecord $_
        }
    }
    $family
}

# Repaints every accent the Fluent dictionaries carry in SnipIT's red.
#
# Discovery is by value, not by key name. Fluent bakes the Windows accent and
# its six tints into ~70 keys per theme -- AccentFillColor*, AccentButton*,
# ToggleButtonBackgroundChecked*, CheckBoxCheckBackgroundFill*, SliderThumb*,
# ProgressBar/Ring, ToggleSwitchFillOn*, RadioButton*, Hyperlink*, ComboBox and
# TextControl focus borders, ListBox/ListView/TreeView/DataGrid selection,
# CalendarView, SystemFillColorAttention, TextControlSelectionHighlightColor --
# and only about half of them are spelled with 'Accent' in the name. Matching
# the colour instead of the name catches all of them, including whatever a
# future Fluent release adds, and touches nothing else: a key is rewritten only
# when its value is a member of the accent family.
#
# Three shapes are handled. A Color or SolidColorBrush is swapped outright. A
# GradientBrush is rebuilt when any of its stops is an accent colour, which is
# what carries the ComboBox / TextBox focus underline. And the SystemAccentColor*
# seeds are written by name, because their entries hold dynamic references to
# the Windows values rather than colours -- left alone, anything resolving a seed
# at runtime would still come back purple.
#
# Frozen brushes are immutable, so every replacement is a new frozen brush
# assigned over the entry, never a mutation of the one already there.
function Set-SnipAccentColors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window,
        $Palette = (Get-SnipAccentPalette),
        $SystemAccent = (Get-SnipSystemAccentFamily)
    )

    if ($null -eq $SystemAccent -or $SystemAccent.Count -eq 0) { return 0 }

    # Which family member the theme currently spends as its primary fill decides
    # how the ladder is shifted; see Get-SnipAccentMap. Read it off the live
    # window so the answer is the mode's, not a mode name this function guesses.
    $anchor = $null
    $primary = $Window.TryFindResource('AccentFillColorDefaultBrush')
    if ($primary -is [System.Windows.Media.SolidColorBrush]) {
        $primaryRgb = (Get-SnipColorChannels -Color $primary.Color).Rgb
        foreach ($entry in $SystemAccent.GetEnumerator()) {
            if ((Get-SnipColorChannels -Color $entry.Value).Rgb -eq $primaryRgb) {
                $anchor = $entry.Key
                break
            }
        }
        if ($null -eq $anchor) {
            # Already one of ours: Show() has not rebuilt the dictionaries since
            # the last pass. Re-deriving the shift from a red primary would only
            # scramble a ladder that is already where it belongs, so stop here --
            # this is what makes the second pass a genuine no-op.
            foreach ($name in $script:SnipAccentVariantOrder) {
                if ($Palette.$name.Rgb -eq $primaryRgb) { return 0 }
            }
        }
    }
    if ($null -eq $anchor) { $anchor = 'Base' }
    $map = Get-SnipAccentMap -Source $SystemAccent -Palette $Palette -Anchor $anchor

    $seeds = [ordered]@{}
    foreach ($name in $script:SnipAccentVariantOrder) {
        if (-not $map.Variants.Contains($name)) { continue }
        $seed = if ($name -eq 'Base') { 'SystemAccentColor' } else { "SystemAccentColor$name" }
        $seeds[$seed] = $map.Variants[$name]
    }
    # Aliases some dictionaries carry for the primary fill and the two steps
    # below it. Written only where they already exist, like every other key.
    foreach ($alias in @(@('SystemAccentColorPrimary', 'Base'),
            @('SystemAccentColorSecondary', 'Dark1'),
            @('SystemAccentColorTertiary', 'Dark2'))) {
        if ($map.Variants.Contains($alias[1])) { $seeds[$alias[0]] = $map.Variants[$alias[1]] }
    }

    $toColor = {
        param($Channels)
        [System.Windows.Media.Color]::FromArgb(
            [byte]$Channels.A, [byte]$Channels.R, [byte]$Channels.G, [byte]$Channels.B)
    }

    $visited = [System.Collections.Generic.HashSet[int]]::new()
    $pending = [System.Collections.Generic.Queue[System.Windows.ResourceDictionary]]::new()
    $pending.Enqueue($Window.Resources)
    $application = [System.Windows.Application]::Current
    if ($null -ne $application -and $null -ne $application.Resources) {
        $pending.Enqueue($application.Resources)
    }

    $changed = 0
    while ($pending.Count -gt 0) {
        $dictionary = $pending.Dequeue()
        if ($null -eq $dictionary) { continue }
        # Fluent merges the same dictionary instance into several parents;
        # reference identity, not Equals, is what stops the walk looping.
        $identity = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($dictionary)
        if (-not $visited.Add($identity)) { continue }
        foreach ($merged in @($dictionary.MergedDictionaries)) { $pending.Enqueue($merged) }

        foreach ($key in @($dictionary.Keys)) {
            $name = [string]$key
            $current = $null
            try { $current = $dictionary[$key] } catch { continue }
            try {
                if ($seeds.Contains($name)) {
                    # Seeds hold an unresolved dynamic reference the first time
                    # round and a concrete Color afterwards, so 'already red' is
                    # the only case worth skipping -- and skipping it is what
                    # makes a second pass over a swapped dictionary a no-op.
                    $seed = & $toColor $seeds[$name]
                    if ($current -is [System.Windows.Media.Color] -and $current -eq $seed) {
                        continue
                    }
                    $dictionary[$key] = $seed
                    $changed++
                    continue
                }
                if ($current -is [System.Windows.Media.Color]) {
                    $replacement = Get-SnipAccentReplacement $name $current -Map $map
                    if ($null -eq $replacement) { continue }
                    $dictionary[$key] = & $toColor (Get-SnipColorChannels -Color $replacement)
                    $changed++
                } elseif ($current -is [System.Windows.Media.SolidColorBrush]) {
                    $replacement = Get-SnipAccentReplacement $name $current.Color -Map $map
                    if ($null -eq $replacement) { continue }
                    $brush = [System.Windows.Media.SolidColorBrush]::new(
                        (& $toColor (Get-SnipColorChannels -Color $replacement)))
                    $brush.Freeze()
                    $dictionary[$key] = $brush
                    $changed++
                } elseif ($current -is [System.Windows.Media.GradientBrush]) {
                    $stops = @($current.GradientStops)
                    $replacements = @($stops | ForEach-Object {
                        Get-SnipAccentReplacement $name $_.Color -Map $map
                    })
                    if (-not ($replacements | Where-Object { $null -ne $_ })) { continue }
                    $rebuilt = $current.Clone()
                    for ($index = 0; $index -lt $stops.Count; $index++) {
                        if ($null -eq $replacements[$index]) { continue }
                        $rebuilt.GradientStops[$index].Color =
                            & $toColor (Get-SnipColorChannels -Color $replacements[$index])
                    }
                    $rebuilt.Freeze()
                    $dictionary[$key] = $rebuilt
                    $changed++
                }
            } catch {
                Write-SnipDiag -Message "accent swap failed for '$name'" -ErrorRecord $_
            }
        }
    }

    $changed
}

# Windows 11 21H2 is where the caption, border and backdrop attributes below
# arrived. Below it DWM ignores them and the caption stays the system's.
$script:SnipChromeBuildFloor = 22000

# Paints the chrome WPF does not own -- the caption bar, its text, the window
# border and the system backdrop behind them.
#
# ThemeMode opts every window into Mica, which composites the desktop wallpaper
# through the caption. On a coloured desktop that reads as a tinted band sitting
# above a pure black or pure white client area: exactly the hue the neutral pass
# exists to keep out of the chrome, arriving through the one surface WPF cannot
# repaint. DWMSBT_NONE turns the backdrop off, and the caption is then filled
# with the literal handed to it -- the same ground the client area uses -- with
# the border taking the accent, the one place the red is structural rather than
# a signal that something is active.
#
# COLORREF is 0x00BBGGRR, not RGB. Everything here is best-effort by design: the
# attributes are Windows 11 only, DWM rejects them on a window with no caption,
# and a machine that is simply older wants the system chrome anyway.
function Set-SnipWindowChrome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [IntPtr]$Hwnd,
        [Parameter(Mandatory)] [ValidateSet('Light', 'Dark')] [string]$Mode,
        $Accent = (Get-SnipAccentPalette).Base,
        [version]$OSVersion = [Environment]::OSVersion.Version
    )

    if ($Hwnd -eq [IntPtr]::Zero) { return $false }
    if ($OSVersion.Major -lt 10 -or $OSVersion.Build -lt $script:SnipChromeBuildFloor) {
        return $false
    }

    $accentChannels = Get-SnipColorChannels -Color $Accent
    $toColorRef = {
        param([int]$Red, [int]$Green, [int]$Blue)
        ($Blue -shl 16) -bor ($Green -shl 8) -bor $Red
    }
    $ink = if ($Mode -eq 'Dark') { 255 } else { 0 }
    $ground = 255 - $ink
    # The backdrop goes first: on some builds DWM keeps compositing Mica over
    # the caption fill unless it has already been told there is no backdrop.
    $attributes = @(
        [pscustomobject]@{
            Name = 'DWMWA_SYSTEMBACKDROP_TYPE'
            Id = [Native]::DWMWA_SYSTEMBACKDROP_TYPE
            Value = [Native]::DWMSBT_NONE
        }
        [pscustomobject]@{
            Name = 'DWMWA_USE_IMMERSIVE_DARK_MODE'
            Id = [Native]::DWMWA_USE_IMMERSIVE_DARK_MODE
            Value = $(if ($Mode -eq 'Dark') { 1 } else { 0 })
        }
        [pscustomobject]@{
            Name = 'DWMWA_CAPTION_COLOR'
            Id = [Native]::DWMWA_CAPTION_COLOR
            Value = (& $toColorRef $ground $ground $ground)
        }
        [pscustomobject]@{
            Name = 'DWMWA_TEXT_COLOR'
            Id = [Native]::DWMWA_TEXT_COLOR
            Value = (& $toColorRef $ink $ink $ink)
        }
        [pscustomobject]@{
            Name = 'DWMWA_BORDER_COLOR'
            Id = [Native]::DWMWA_BORDER_COLOR
            Value = (& $toColorRef $accentChannels.R $accentChannels.G $accentChannels.B)
        })

    $applied = $true
    foreach ($attribute in $attributes) {
        try {
            $value = [int]$attribute.Value
            if ([Native]::DwmSetWindowAttribute($Hwnd, [int]$attribute.Id, [ref]$value, 4) -ne 0) {
                $applied = $false
            }
        } catch {
            $applied = $false
            Write-SnipDiag -Message "window chrome attribute '$($attribute.Name)' failed" `
                -ErrorRecord $_
        }
    }
    $applied
}

# Applies the stock WPF Fluent theme to one window and returns the mode used.
#
# This is the whole theme layer. SnipIT owns no styles and no control templates:
# setting ThemeMode installs Microsoft's own Fluent dictionaries and everything
# else in the UI reads those keys by name. Two passes then edit the values in
# place, and between them they are the entire palette:
#
#   Set-SnipNeutralSurfaces  every surface, bar, card, border and text key goes
#                            strictly neutral, so the chrome is black, white and
#                            grey whatever hue an OEM Fluent shipped.
#   Set-SnipAccentColors     every accent goes to the fixed red, so the one
#                            colour in the chrome is the same on every machine
#                            instead of the user's taskbar hue.
#
# Colour in the app therefore means one of two things: something is active, or
# the user drew it.
#
# High Contrast is the one theme SnipIT must not touch: those palettes are
# deliberately coloured and the user chose them to be legible, so -HighContrast
# turns both passes off and grounds the window by resource reference the way it
# did before. The value is a parameter so the suite can exercise both paths.
#
# ThemeMode is the experimental .NET 9 API, so it is set through reflection and
# the whole call is a no-op on a runtime where the type is absent.
function Initialize-SnipWindowTheme {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window,
        [ValidateSet('Light','Dark')]
        [string]$Mode,
        [bool]$HighContrast = (Test-SnipHighContrast)
    )

    if (-not $Mode) {
        # Test-mode escape hatch so the screenshot driver can render both modes
        # without touching HKCU. Ignored outside SNIPIT_TEST_MODE.
        $override = if ($env:SNIPIT_TEST_MODE) { [string]$env:SNIPIT_THEME_MODE } else { '' }
        $Mode = if ($override -in @('Light','Dark')) {
            $override
        } else {
            Get-SnipSystemThemeMode
        }
    }

    $themeModeType = 'System.Windows.ThemeMode' -as [type]
    if ($null -ne $themeModeType) {
        try {
            $themeMode = [Activator]::CreateInstance($themeModeType, @($Mode))
            $app = [System.Windows.Application]::Current
            if ($null -ne $app) {
                $app.GetType().GetProperty('ThemeMode').SetValue($app, $themeMode)
            }
            $Window.GetType().GetProperty('ThemeMode').SetValue($Window, $themeMode)
        } catch {
            Write-SnipDiag -Message 'ThemeMode apply failed' -ErrorRecord $_
        }
    }

    # Applying ThemeMode leaves Window.Background transparent so a DWM backdrop
    # can show through, and Fluent's ToolBarTray / StatusBar fills are themselves
    # translucent (#B3FFFFFF in Light, #0FFFFFFF in Dark). Ungrounded, those bars
    # composite over whatever is behind the window -- the wallpaper, through the
    # Mica backdrop -- rather than over the theme surface, which is where a warm
    # cast gets into the chrome on screen even though every Fluent surface key is
    # neutral. Ground the window on an opaque literal instead: pure black in
    # Dark, pure white in Light, frozen so it is cheap and thread-safe.
    # AllowsTransparency surfaces (the Smart overlay) must stay transparent.
    if ($HighContrast) {
        # Leave the High Contrast palette exactly as Windows built it, ground
        # included -- by reference, so a dictionary rebuild still resolves.
        if (-not $Window.AllowsTransparency) {
            $Window.SetResourceReference(
                [System.Windows.Controls.Control]::BackgroundProperty,
                'ApplicationBackgroundBrush')
        }
        return $Mode
    }
    $groundBrush = [System.Windows.Media.SolidColorBrush]::new(
        $(if ($Mode -eq 'Dark') {
            [System.Windows.Media.Color]::FromRgb(0, 0, 0)
        } else {
            [System.Windows.Media.Color]::FromRgb(255, 255, 255)
        }))
    $groundBrush.Freeze()
    if (-not $Window.AllowsTransparency) { $Window.Background = $groundBrush }
    [void](Set-SnipNeutralSurfaces -Window $Window -Mode $Mode)
    # Accent second: the neutral pass skips every key holding 'Accent', but half
    # the accent-valued keys are not spelled that way, so the red goes on after
    # the grey rather than under it.
    [void](Set-SnipAccentColors -Window $Window)

    # Show() rebuilds the Fluent dictionaries from scratch (the same rebuild that
    # invalidates brushes cached before the window is up), which restores the
    # stock entries this function just rewrote. Re-run once the tree is loaded,
    # then unhook: the handler is a fixup for that one rebuild, not a live theme
    # watcher.
    #
    # GetNewClosure() runs the handler inside a dynamic module, whose command
    # lookup does not always reach the scope this script was dot-sourced into, so
    # the two functions it needs are captured as scriptblocks rather than called
    # by name -- the same idiom Connect-SnipWindowLifecycle uses for its seams.
    #
    # The caption bar rides along on the same hook. It is DWM's surface, not
    # WPF's, so it needs an HWND, and Loaded is the first moment one exists --
    # SourceInitialized would be earlier but the window is not on screen until
    # Loaded anyway, so nothing is visible in between.
    $themeState = [pscustomobject]@{
        Mode = $Mode
        Ground = $groundBrush
        Handler = $null
        Neutralise = ${function:Set-SnipNeutralSurfaces}
        Accent = ${function:Set-SnipAccentColors}
        Chrome = ${function:Set-SnipWindowChrome}
        Diagnose = ${function:Write-SnipDiag}
    }
    $reapply = [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        try {
            if (-not $sender.AllowsTransparency) { $sender.Background = $themeState.Ground }
            [void](& $themeState.Neutralise -Window $sender -Mode $themeState.Mode)
            [void](& $themeState.Accent -Window $sender)
            [void](& $themeState.Chrome `
                -Hwnd ([System.Windows.Interop.WindowInteropHelper]::new($sender).Handle) `
                -Mode $themeState.Mode)
        } catch {
            & $themeState.Diagnose -Message 'theme reapply failed' -ErrorRecord $_
        } finally {
            if ($null -ne $themeState.Handler) { $sender.Remove_Loaded($themeState.Handler) }
        }
    }.GetNewClosure()
    $themeState.Handler = $reapply
    $Window.Add_Loaded($reapply)
    # A window that is already up -- a re-theme rather than a first paint --
    # never raises Loaded again, so take the handle now if there is one.
    [void](Set-SnipWindowChrome -Mode $Mode `
        -Hwnd ([System.Windows.Interop.WindowInteropHelper]::new($Window).Handle))

    $Mode
}


function Connect-SnipWindowLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Window]$Window,
        [scriptblock]$Register = { param($hwnd) Register-SelfWindowHandle -Hwnd $hwnd },
        [scriptblock]$Unregister = { param($hwnd) Unregister-SelfWindowHandle -Hwnd $hwnd }
    )

    $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
    $state = [pscustomobject]@{
        Window = $Window
        Handle = [IntPtr]::Zero
        Connected = $false
        SourceInitializedHandler = $null
        ClosedHandler = $null
    }
    $registerWindow = $Register
    $unregisterWindow = $Unregister
    $sourceInitialized = [EventHandler]{
        param($sender, $eventArgs)
        $handle = $helper.Handle
        if ($handle -eq [IntPtr]::Zero -or $state.Connected) { return }
        & $registerWindow $handle
        $state.Handle = $handle
        $state.Connected = $true
    }.GetNewClosure()
    $closed = [EventHandler]{
        param($sender, $eventArgs)
        try {
            if ($state.Connected -and $state.Handle -ne [IntPtr]::Zero) {
                & $unregisterWindow $state.Handle
            }
        } finally {
            $state.Connected = $false
            $Window.Remove_SourceInitialized($sourceInitialized)
            $Window.Remove_Closed($state.ClosedHandler)
        }
    }.GetNewClosure()
    $state.SourceInitializedHandler = $sourceInitialized
    $state.ClosedHandler = $closed
    $Window.Add_SourceInitialized($sourceInitialized)
    $Window.Add_Closed($closed)
    $state
}

function Convert-BitmapToBitmapSource {
    param([System.Drawing.Bitmap]$Bitmap)
    # DeleteObject lives on the main [Native] class defined at startup — no per-call JIT.
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
        if ($hbmp -ne [IntPtr]::Zero) { [Native]::DeleteObject($hbmp) | Out-Null }
    }
}

function Save-CaptureToFile {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        $Settings = $script:Settings
    )
    $dialogDefaults = Get-SnipSaveDialogDefaults -Settings $Settings
    $defaultDir = $dialogDefaults.InitialDirectory
    $fallbackDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Snips'
    try {
        New-Item -ItemType Directory -Force -Path $defaultDir -ErrorAction Stop | Out-Null
    } catch {
        Write-SnipDiag -Message ("Default save folder '{0}' is unavailable; using '{1}'." -f
            $defaultDir, $fallbackDir) -ErrorRecord $_
        $defaultDir = $fallbackDir
        try {
            New-Item -ItemType Directory -Force -Path $defaultDir -ErrorAction Stop | Out-Null
        } catch {
            Write-SnipDiag -Message ("Fallback save folder '{0}' could not be created." -f
                $fallbackDir) -ErrorRecord $_
        }
    }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'PNG image (*.png)|*.png|JPEG (*.jpg)|*.jpg|Bitmap (*.bmp)|*.bmp'
    $dlg.FileName = $dialogDefaults.FileName
    $dlg.FilterIndex = $dialogDefaults.FilterIndex
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

$script:SnipNativeInitializer = {

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
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT point, uint flags);
    public const uint GA_ROOT = 2;
    public const uint GW_HWNDNEXT = 2;
    public const uint MONITOR_DEFAULTTONEAREST = 2;

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    // Visibility + show/hide for SnipIT-owned windows. We hide our chrome
    // around CopyFromScreen so widget / preview UI doesn't get baked into
    // captures, then SW_SHOWNA back without stealing focus.
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter,
        int x, int y, int width, int height, uint flags);
    public const int SW_HIDE   = 0;
    public const int SW_SHOWNA = 8;   // show without activating (don't steal focus)
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr monitor, int dpiType,
        out uint dpiX, out uint dpiY);
    public const int MDT_EFFECTIVE_DPI = 0;

    // Monitor identity. EDD_GET_DEVICE_INTERFACE_NAME swaps DeviceID from a
    // MONITOR\... key to the \\?\DISPLAY#... interface path, which is the form
    // that lines up with WmiMonitorID's InstanceName.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string device, uint deviceIndex,
        ref DISPLAY_DEVICE displayDevice, uint flags);
    public const uint EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001;

    // DWM extended frame bounds (no drop shadow)
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT rect, int size);
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    // Window chrome the app does not draw: the caption bar, its text, the
    // window border and the system backdrop behind them all. Win11 21H2+.
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hWnd, int attr, ref int value, int size);
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    public const int DWMSBT_NONE = 1;           // no backdrop: the caption is opaque
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_BORDER_COLOR = 34;
    public const int DWMWA_CAPTION_COLOR = 35;
    public const int DWMWA_TEXT_COLOR = 36;

    // Cursor pos in screen pixels
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);

    // GDI cleanup for handles returned by Bitmap.GetHbitmap()
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);

    // Shell change notification. Explorer caches the bitmap it drew for a
    // shortcut and does not re-read the icon source just because that file's
    // bytes changed under an unchanged path, so a regenerated SnipIT.ico stays
    // invisible on the Desktop until the shell is told about it.
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
    public const int SHCNE_UPDATEITEM = 0x00002000;
    public const int SHCNE_ASSOCCHANGED = 0x08000000;
    public const uint SHCNF_IDLIST = 0x0000;
    public const uint SHCNF_PATHW = 0x0005;
}
'@

if (-not ('Native' -as [type])) {
    Add-Type -TypeDefinition $pinvoke -ReferencedAssemblies ([System.Drawing.Bitmap].Assembly.Location)
}

# Blur and Pixelate rewrite every pixel under their region. A PowerShell loop
# over a 600x400 selection is seconds of dead UI, so the two kernels live in
# compiled code and operate on the raw BGRA buffer LockBits hands back.
$pixelKernels = @'
using System;

public static class SnipPixels {
    // Separable box blur. Two passes over a summed row/column window give an
    // O(pixels) approximation of a gaussian that is visually indistinguishable
    // from WPF's BlurEffect at the radii the editor offers.
    public static void BoxBlur(byte[] buffer, int width, int height, int stride, int radius) {
        if (buffer == null || width <= 0 || height <= 0 || radius <= 0) { return; }
        byte[] scratch = new byte[buffer.Length];
        Array.Copy(buffer, scratch, buffer.Length);
        BlurHorizontal(scratch, buffer, width, height, stride, radius);
        Array.Copy(buffer, scratch, buffer.Length);
        BlurVertical(scratch, buffer, width, height, stride, radius);
    }

    private static void BlurHorizontal(byte[] source, byte[] target,
        int width, int height, int stride, int radius) {
        for (int y = 0; y < height; y++) {
            int row = y * stride;
            for (int x = 0; x < width; x++) {
                int from = x - radius; if (from < 0) { from = 0; }
                int to = x + radius; if (to > width - 1) { to = width - 1; }
                int blue = 0, green = 0, red = 0, count = 0;
                for (int sample = from; sample <= to; sample++) {
                    int offset = row + (sample * 4);
                    blue += source[offset];
                    green += source[offset + 1];
                    red += source[offset + 2];
                    count++;
                }
                int write = row + (x * 4);
                target[write] = (byte)(blue / count);
                target[write + 1] = (byte)(green / count);
                target[write + 2] = (byte)(red / count);
            }
        }
    }

    private static void BlurVertical(byte[] source, byte[] target,
        int width, int height, int stride, int radius) {
        for (int x = 0; x < width; x++) {
            int column = x * 4;
            for (int y = 0; y < height; y++) {
                int from = y - radius; if (from < 0) { from = 0; }
                int to = y + radius; if (to > height - 1) { to = height - 1; }
                int blue = 0, green = 0, red = 0, count = 0;
                for (int sample = from; sample <= to; sample++) {
                    int offset = (sample * stride) + column;
                    blue += source[offset];
                    green += source[offset + 1];
                    red += source[offset + 2];
                    count++;
                }
                int write = (y * stride) + column;
                target[write] = (byte)(blue / count);
                target[write + 1] = (byte)(green / count);
                target[write + 2] = (byte)(red / count);
            }
        }
    }

    // Mosaic: every block takes the mean colour of the source pixels it covers,
    // the same rule Get-SnipBlockAverage states portably.
    public static void Pixelate(byte[] buffer, int width, int height, int stride, int block) {
        if (buffer == null || width <= 0 || height <= 0 || block <= 1) { return; }
        for (int blockTop = 0; blockTop < height; blockTop += block) {
            int blockBottom = blockTop + block; if (blockBottom > height) { blockBottom = height; }
            for (int blockLeft = 0; blockLeft < width; blockLeft += block) {
                int blockRight = blockLeft + block; if (blockRight > width) { blockRight = width; }
                int blue = 0, green = 0, red = 0, count = 0;
                for (int y = blockTop; y < blockBottom; y++) {
                    int row = y * stride;
                    for (int x = blockLeft; x < blockRight; x++) {
                        int offset = row + (x * 4);
                        blue += buffer[offset];
                        green += buffer[offset + 1];
                        red += buffer[offset + 2];
                        count++;
                    }
                }
                if (count == 0) { continue; }
                byte averageBlue = (byte)((blue + (count / 2)) / count);
                byte averageGreen = (byte)((green + (count / 2)) / count);
                byte averageRed = (byte)((red + (count / 2)) / count);
                for (int y = blockTop; y < blockBottom; y++) {
                    int row = y * stride;
                    for (int x = blockLeft; x < blockRight; x++) {
                        int offset = row + (x * 4);
                        buffer[offset] = averageBlue;
                        buffer[offset + 1] = averageGreen;
                        buffer[offset + 2] = averageRed;
                    }
                }
            }
        }
    }
}
'@

if (-not ('SnipPixels' -as [type])) {
    Add-Type -TypeDefinition $pixelKernels
}

# Harmless second attempt. The request that matters is the one at the very top
# of this file, before any UI assembly is loaded; by the time we get here the
# awareness mode has been latched for a long while and this call can only be
# refused. It stays as a belt-and-braces retry for the one case where it could
# still succeed — a host that somehow loaded nothing at all before us — and its
# result is deliberately not recorded, because $script:SnipDpiPerMonitorAware
# was already resolved from what Windows reported back then.
[Native]::SetProcessDpiAwarenessContext([Native]::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) | Out-Null

$script:SelfWindowHandles = New-Object System.Collections.Generic.List[IntPtr]

$script:ActivePreviewContext = $null

}

function Get-VirtualScreenBounds {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    [pscustomobject]@{ X=$vs.X; Y=$vs.Y; Width=$vs.Width; Height=$vs.Height }
}

function Get-SnipPhysicalCursorPosition {
    # Returns $null rather than throwing: every caller has a sane answer for
    # "we do not know where the pointer is".
    [CmdletBinding()]
    param()

    try {
        $point = [Native+POINT]::new()
        if (-not [Native]::GetCursorPos([ref]$point)) { return $null }
        [pscustomobject][ordered]@{ X = [int]$point.X; Y = [int]$point.Y }
    } catch {
        $null
    }
}

function Get-SnipMonitorFriendlyNameMap {
    # Builds a '\\.\DISPLAY1' -> 'DELL U2412M' map from the EDID names Windows
    # already parsed into root\wmi. Getting from a GDI display name to an EDID
    # record takes two hops, because they are keyed on different things:
    #
    #   Screen.DeviceName  \\.\DISPLAY1                  (GDI adapter output)
    #     -> EnumDisplayDevices with the device-interface flag
    #   DeviceID           \\?\DISPLAY#DEL4091#5&1a2b&0&UID4353#{guid}
    #     -> normalize separators
    #   WmiMonitorID       DISPLAY\DEL4091\5&1a2b&0&UID4353_0
    #
    # The whole lookup is best effort. WMI can be disabled, a monitor can report
    # no EDID name, and a virtual / remote display has no EDID at all — in every
    # one of those cases the caller falls back to a positional label, which is
    # strictly better than showing '\\.\DISPLAY3' in a menu.
    #
    # Results are cached against the set of device paths they were built from, so
    # reopening the tray menu is free but plugging a monitor in rebuilds the map.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$DeviceNames)

    $devicePaths = [ordered]@{}
    foreach ($deviceName in $DeviceNames) {
        $devicePaths[$deviceName] = ''
        try {
            $device = [Native+DISPLAY_DEVICE]::new()
            $device.cb = [Runtime.InteropServices.Marshal]::SizeOf($device)
            if ([Native]::EnumDisplayDevices(
                    $deviceName, 0, [ref]$device,
                    [Native]::EDD_GET_DEVICE_INTERFACE_NAME)) {
                $devicePaths[$deviceName] = [string]$device.DeviceID
            }
        } catch {}
    }

    $cacheKey = ($devicePaths.Values -join '|')
    if ($null -ne $script:SnipMonitorNameCache -and
        [string]$script:SnipMonitorNameCache.Key -ceq $cacheKey) {
        return $script:SnipMonitorNameCache.Map
    }

    $edidNames = @{}
    try {
        foreach ($record in @(Get-CimInstance -Namespace 'root\wmi' `
                -ClassName 'WmiMonitorID' -ErrorAction Stop)) {
            $codes = @($record.UserFriendlyName)
            if ($codes.Count -eq 0) { continue }
            # UserFriendlyName is a UInt16[] of character codes padded with
            # zeroes out to UserFriendlyNameLength; stop at the first zero.
            $builder = [Text.StringBuilder]::new()
            foreach ($code in $codes) {
                $value = [int]$code
                if ($value -le 0) { break }
                [void]$builder.Append([char]$value)
            }
            $name = $builder.ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $key = Get-SnipMonitorInstanceKey -Value ([string]$record.InstanceName)
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $edidNames.ContainsKey($key)) {
                $edidNames[$key] = $name
            }
        }
    } catch {}

    $map = @{}
    foreach ($entry in $devicePaths.GetEnumerator()) {
        $key = Get-SnipMonitorInstanceKey -Value ([string]$entry.Value)
        if (-not [string]::IsNullOrWhiteSpace($key) -and $edidNames.ContainsKey($key)) {
            $map[$entry.Key] = $edidNames[$key]
        }
    }
    $script:SnipMonitorNameCache = [pscustomobject]@{ Key = $cacheKey; Map = $map }
    $map
}

function Get-SnipMonitorDescriptors {
    [CmdletBinding()]
    param()

    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    $perMonitorAware = [bool]$script:SnipDpiPerMonitorAware
    $friendlyNames = @{}
    try {
        $friendlyNames = Get-SnipMonitorFriendlyNameMap -DeviceNames (
            [string[]]@($screens | ForEach-Object { [string]$_.DeviceName }))
    } catch {}

    $descriptors = foreach ($screen in $screens) {
        $bounds = $screen.Bounds
        $workingArea = $screen.WorkingArea
        $point = [Native+POINT]::new()
        $point.X = [int]($bounds.Left + [math]::Floor($bounds.Width / 2))
        $point.Y = [int]($bounds.Top + [math]::Floor($bounds.Height / 2))
        $monitor = [Native]::MonitorFromPoint(
            $point, [Native]::MONITOR_DEFAULTTONEAREST)
        [uint32]$dpiX = 96
        [uint32]$dpiY = 96
        if ($monitor -ne [IntPtr]::Zero) {
            try {
                if ([Native]::GetDpiForMonitor(
                        $monitor, [Native]::MDT_EFFECTIVE_DPI,
                        [ref]$dpiX, [ref]$dpiY) -ne 0) {
                    $dpiX = 96
                    $dpiY = 96
                }
            } catch {
                $dpiX = 96
                $dpiY = 96
            }
        }
        # $bounds came from Screen.AllScreens, which is virtualized unless the
        # process is per-monitor aware; $dpiX/$dpiY came from GetDpiForMonitor,
        # which never is. Resolve-SnipMonitorDpi keeps the pair in one space.
        $resolvedDpi = Resolve-SnipMonitorDpi -RawDpiX ([double]$dpiX) `
            -RawDpiY ([double]$dpiY) -PerMonitorAware $perMonitorAware
        if ($resolvedDpi.Normalized -and -not $script:SnipDpiFallbackLogged -and
            ([double]$dpiX -ne 96 -or [double]$dpiY -ne 96)) {
            $script:SnipDpiFallbackLogged = $true
            Write-SnipDiag -Message (
                ('Process DPI awareness is {0} (thread {1}; Per-Monitor v2 request ' +
                 'granted={2}); monitor bounds are virtualized, so reporting 96 DPI ' +
                 'for every display instead of the true {3}x{4}.') -f
                $script:SnipProcessDpiAwareness, $script:SnipThreadDpiAwareness,
                $script:SnipDpiAwarenessGranted, [int]$dpiX, [int]$dpiY)
        }
        $deviceName = [string]$screen.DeviceName
        $friendlyName = if ($friendlyNames.ContainsKey($deviceName)) {
            [string]$friendlyNames[$deviceName]
        } else { '' }
        [pscustomobject][ordered]@{
            # Id stays the raw GDI device name: capture resolves a requested
            # display by matching on it, and a friendly name is not unique.
            Id = $deviceName
            DisplayName = $friendlyName
            X = [int]$bounds.X
            Y = [int]$bounds.Y
            Width = [int]$bounds.Width
            Height = [int]$bounds.Height
            WorkX = [int]$workingArea.X
            WorkY = [int]$workingArea.Y
            WorkWidth = [int]$workingArea.Width
            WorkHeight = [int]$workingArea.Height
            DpiX = [double]$resolvedDpi.DpiX
            DpiY = [double]$resolvedDpi.DpiY
            IsPrimary = [bool]$screen.Primary
        }
    }

    # Primary first, then left-to-right, so the tray's Display submenu matches
    # the physical arrangement instead of GDI enumeration order.
    Sort-SnipMonitorDescriptors -Descriptors ([object[]]@($descriptors))
}

function Get-SnipWindowAtPhysicalPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Point,
        [object[]]$OwnHandles = @()
    )

    $nativePoint = [Native+POINT]::new()
    $nativePoint.X = [int]$Point.X
    $nativePoint.Y = [int]$Point.Y
    $candidate = [Native]::WindowFromPoint($nativePoint)
    if ($candidate -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    $candidate = [Native]::GetAncestor($candidate, [Native]::GA_ROOT)
    $own = [System.Collections.Generic.HashSet[Int64]]::new()
    foreach ($handle in @($OwnHandles)) {
        if ($null -ne $handle -and [IntPtr]$handle -ne [IntPtr]::Zero) {
            [void]$own.Add(([IntPtr]$handle).ToInt64())
        }
    }

    for ($attempt = 0; $attempt -lt 256 -and
        $candidate -ne [IntPtr]::Zero; $attempt++) {
        if (-not $own.Contains($candidate.ToInt64())) { return $candidate }
        $candidate = [Native]::GetWindow($candidate, [Native]::GW_HWNDNEXT)
        while ($candidate -ne [IntPtr]::Zero) {
            if ([Native]::IsWindowVisible($candidate)) {
                $bounds = [Native+RECT]::new()
                if ([Native]::GetWindowRect($candidate, [ref]$bounds) -and
                    $nativePoint.X -ge $bounds.Left -and $nativePoint.X -lt $bounds.Right -and
                    $nativePoint.Y -ge $bounds.Top -and $nativePoint.Y -lt $bounds.Bottom) {
                    break
                }
            }
            $candidate = [Native]::GetWindow($candidate, [Native]::GW_HWNDNEXT)
        }
    }
    [IntPtr]::Zero
}

function Get-SnipWindowBounds {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [IntPtr]$Hwnd)

    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    $bounds = [Native+RECT]::new()
    $ok = ([Native]::DwmGetWindowAttribute(
        $Hwnd, [Native]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$bounds, 16) -eq 0)
    if (-not $ok) { $ok = [Native]::GetWindowRect($Hwnd, [ref]$bounds) }
    $width = $bounds.Right - $bounds.Left
    $height = $bounds.Bottom - $bounds.Top
    if (-not $ok -or $width -le 0 -or $height -le 0) { return $null }
    [pscustomobject][ordered]@{
        X = [int]$bounds.Left
        Y = [int]$bounds.Top
        Width = [int]$width
        Height = [int]$height
    }
}

function Register-SelfWindowHandle {
    # Tracks an HWND we own (widget, preview, hotkey form, console) so the
    # capture path can exclude it via Resolve-WindowCaptureTarget and the
    # snapshot path can hide it via Hide-OwnSnipITWindowsForCapture.
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return }
    if (-not $script:SelfWindowHandles.Contains($Hwnd)) {
        [void]$script:SelfWindowHandles.Add($Hwnd)
    }
}

function Unregister-SelfWindowHandle {
    param([IntPtr]$Hwnd)
    [void]$script:SelfWindowHandles.Remove($Hwnd)
}

function Hide-OwnSnipITWindowsForCapture {
    # Hides every registered SnipIT-owned hwnd that is currently visible so
    # our widget / preview / etc. don't get baked into a desktop snapshot.
    # Returns the list of hidden hwnds; pass it to
    # Show-OwnSnipITWindowsForCapture to restore them without stealing focus.
    [OutputType([System.Collections.Generic.List[IntPtr]])]
    [CmdletBinding()]
    param()

    if ($null -ne $script:ActivePreviewContext -and
        $null -ne $script:ActivePreviewContext.CommandRouter) {
        try { & $script:ActivePreviewContext.CommandRouter.CloseTransientMenus }
        catch { Write-SnipDiag -Message 'Preview transient-menu cleanup failed' -ErrorRecord $_ }
    }
    $hidden = New-Object System.Collections.Generic.List[IntPtr]
    foreach ($h in @($script:SelfWindowHandles)) {
        if ($h -eq [IntPtr]::Zero) { continue }
        if (-not [Native]::IsWindowVisible($h)) { continue }
        if ([Native]::ShowWindow($h, [Native]::SW_HIDE)) { $hidden.Add($h) }
    }
    if ($hidden.Count -gt 0) {
        # Pump pending UI work and yield briefly so DWM composes a frame
        # without our chrome before CopyFromScreen samples the desktop.
        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
        Start-Sleep -Milliseconds 80
    }
    # Wrap in a single-element array so PowerShell does not unroll the List
    # across the output stream.
    ,$hidden
}

function Show-OwnSnipITWindowsForCapture {
    param($Hidden)
    if (-not $Hidden -or $Hidden.Count -eq 0) { return }
    foreach ($h in $Hidden) {
        # SW_SHOWNA = show without activating, so we don't yank focus from
        # whatever window the user was on while the snapshot ran.
        [void][Native]::ShowWindow([IntPtr]$h, [Native]::SW_SHOWNA)
    }
}

$script:CaptureCoordinator = $null

function New-ScreenBitmap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$X,
        [Parameter(Mandatory)] [int]$Y,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [scriptblock]$BitmapFactory = {
            param($width,$height,$pixelFormat)
            [System.Drawing.Bitmap]::new($width, $height, $pixelFormat)
        },
        [scriptblock]$GraphicsFactory = {
            param($bitmap)
            [System.Drawing.Graphics]::FromImage($bitmap)
        },
        [scriptblock]$CopyPixels = {
            param($graphics,$x,$y,$width,$height)
            $graphics.CopyFromScreen(
                $x, $y, 0, 0,
                [System.Drawing.Size]::new($width, $height),
                [System.Drawing.CopyPixelOperation]::SourceCopy)
        }
    )

    $bmp = $null
    $graphics = $null
    $captureSucceeded = $false
    $graphicsCleanupFailed = $false
    try {
        $bmp = & $BitmapFactory $Width $Height `
            ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = & $GraphicsFactory $bmp
        & $CopyPixels $graphics $X $Y $Width $Height | Out-Null
        $captureSucceeded = $true
    } finally {
        try {
            if ($null -ne $graphics) {
                Invoke-SnipResourceDispose -Resource $graphics
            }
        } catch {
            # A bitmap cannot be transferred when its Graphics cleanup failed.
            $graphicsCleanupFailed = $true
            throw
        } finally {
            if ((-not $captureSucceeded -or $graphicsCleanupFailed) -and
                $null -ne $bmp) {
                Invoke-SnipResourceDispose -Resource $bmp
            }
        }
    }

    return $bmp
}

function Get-SnipOverlayService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Services,
        [Parameter(Mandatory)] [string]$Name
    )

    $property = $Services.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw [ArgumentException]::new(
            "Smart overlay services are missing '$Name'.", 'Services')
    }
    $property.Value
}

function New-SnipOverlayContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Snapshot,
        $SnapshotSource,
        [Parameter(Mandatory)] $VirtualBounds,
        [Parameter(Mandatory)] [object[]]$MonitorLayouts,
        [Parameter(Mandatory)] $Services,
        [bool]$HighContrast = $false,
        [timespan]$IdleTimeout = ([timespan]::FromSeconds(20))
    )

    $context = [pscustomobject][ordered]@{
        Snapshot = $Snapshot
        SnapshotSource = $SnapshotSource
        VirtualBounds = $VirtualBounds
        MonitorLayouts = @($MonitorLayouts)
        Services = $Services
        HighContrast = $HighContrast
        Overlays = [System.Collections.ArrayList]::new()
        # Watchdog state. See Test-SnipOverlayIdleTimeout for why both halves
        # are needed before the overlay gives up on itself.
        IdleTimeout = $IdleTimeout
        LastInputUtc = [datetime]::UtcNow
        IdleCancelled = $false
        Dragging = $false
        AnchorPhysical = $null
        PointerPhysical = $null
        Selection = $null
        HoverHwnd = [IntPtr]::Zero
        HoverBounds = $null
        ClickCandidateBounds = $null
        PendingOverlay = $null
        PointerDirty = $false
        RenderCount = 0
        CaptureOverlay = $null
        SurfaceResult = 'UserCancelled'
        ErrorRecord = $null
        Closing = $false
        RenderingHandler = $null
        RenderingAttached = $false
        Actions = $null
    }

    $readCursor = {
        $getCursor = Get-SnipOverlayService -Services $context.Services `
            -Name GetCursorPosition
        $output = @(& $getCursor)
        $point = if ($output.Count -gt 0) { $output[-1] } else { $null }
        if ($null -eq $point -or $null -eq $point.PSObject.Properties['X'] -or
            $null -eq $point.PSObject.Properties['Y']) {
            throw [InvalidOperationException]::new(
                'GetCursorPosition returned no physical point.')
        }
        [pscustomobject][ordered]@{ X=[int]$point.X; Y=[int]$point.Y }
    }.GetNewClosure()
    $close = {
        param(
            [ValidateSet('Completed','UserCancelled','Preempted','Failed','Shutdown')]
            [string]$Result = 'UserCancelled'
        )
        if ($context.Closing) { return }
        $context.Closing = $true
        $context.SurfaceResult = $Result
        if ($Result -ne 'Completed') { $context.Selection = $null }
        if ($null -ne $context.CaptureOverlay) {
            try { $context.CaptureOverlay.Window.ReleaseMouseCapture() } catch {}
        }
        $context.Dragging = $false
        foreach ($overlay in @($context.Overlays)) {
            if ($null -ne $overlay.Window) { try { $overlay.Window.Close() } catch {} }
        }
    }.GetNewClosure()
    $queuePointer = {
        param($Overlay)
        if ($context.Closing) { return }
        $context.LastInputUtc = [datetime]::UtcNow
        $context.PendingOverlay = $Overlay
        $context.PointerDirty = $true
    }.GetNewClosure()
    $beginDrag = {
        param($Overlay)
        if ($context.Closing) { return }
        $context.LastInputUtc = [datetime]::UtcNow
        $point = & $readCursor
        # Flush the newest queued hover against this exact physical point so
        # a fast move/down/up cannot commit the previous frame's target.
        $context.PendingOverlay = $Overlay
        $context.PointerDirty = $true
        Invoke-SnipOverlayRenderTick -Context $context -PhysicalPoint $point
        $context.PointerPhysical = $point
        $context.AnchorPhysical = $point
        $context.Selection = [pscustomobject][ordered]@{
            X=$point.X; Y=$point.Y; Width=0; Height=0
        }
        $context.ClickCandidateBounds = $context.HoverBounds
        $context.Dragging = $true
        $context.HoverHwnd = [IntPtr]::Zero
        $context.HoverBounds = $null
        $context.CaptureOverlay = $Overlay
        $context.PointerDirty = $true
        # The instruction banner has served its purpose once a drag starts; the
        # render tick takes over and shows the live size chip instead. Hiding it
        # here (rather than leaving it to the tick) keeps the banner from
        # flashing on the frame between mouse-down and the next render.
        foreach ($item in @($context.Overlays)) {
            $item.HintBorder.Visibility = 'Collapsed'
        }
        try { $Overlay.Window.CaptureMouse() | Out-Null } catch {}
    }.GetNewClosure()
    $completeDrag = {
        if (-not $context.Dragging -or $context.Closing) { return }
        $context.LastInputUtc = [datetime]::UtcNow
        $point = & $readCursor
        $context.PointerPhysical = $point
        $kind = Test-IsClickVsDrag `
            -AnchorX $context.AnchorPhysical.X -AnchorY $context.AnchorPhysical.Y `
            -CurrentX $point.X -CurrentY $point.Y
        if ($kind -eq 'click') {
            $context.Selection = $context.ClickCandidateBounds
        } else {
            $context.Selection = Get-DragRectangle `
                -AnchorX $context.AnchorPhysical.X -AnchorY $context.AnchorPhysical.Y `
                -CurrentX $point.X -CurrentY $point.Y
        }
        try { $context.CaptureOverlay.Window.ReleaseMouseCapture() } catch {}
        $context.Dragging = $false
        $valid = $null -ne $context.Selection -and
            (Test-CaptureRectValid -Width ([int]$context.Selection.Width) `
                -Height ([int]$context.Selection.Height))
        & $close $(if ($valid) { 'Completed' } else { 'UserCancelled' })
    }.GetNewClosure()
    $cancel = { & $close 'UserCancelled' }.GetNewClosure()
    $context.Actions = [pscustomobject][ordered]@{
        ReadCursor = $readCursor
        Close = $close
        QueuePointer = $queuePointer
        BeginDrag = $beginDrag
        CompleteDrag = $completeDrag
        Cancel = $cancel
    }
    $context
}

function Remove-SnipOverlayWindowEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Overlay)

    if (-not $Overlay.EventsAttached) { return }
    $Overlay.EventsAttached = $false
    try { $Overlay.Window.Remove_MouseMove($Overlay.MouseMoveHandler) } catch {}
    try { $Overlay.Window.Remove_MouseLeftButtonDown($Overlay.MouseDownHandler) } catch {}
    try { $Overlay.Window.Remove_MouseLeftButtonUp($Overlay.MouseUpHandler) } catch {}
    try { $Overlay.Window.Remove_MouseRightButtonDown($Overlay.RightDownHandler) } catch {}
    try { $Overlay.Window.Remove_KeyDown($Overlay.KeyDownHandler) } catch {}
    try { $Overlay.Window.Remove_SourceInitialized($Overlay.PositionHandler) } catch {}
    try { $Overlay.Window.Remove_Closed($Overlay.ClosedHandler) } catch {}
}

function New-SnipOverlayWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $MonitorLayout
    )

    [xml]$xaml = [xml](Get-SnipXamlText -Name 'SmartOverlay')
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    # Installs the stock Fluent dictionaries so the banner, size chip and loupe
    # resolve their DynamicResource keys. The AllowsTransparency guard inside
    # keeps the window itself transparent.
    [void](Initialize-SnipWindowTheme -Window $window)
    $window.Left = [double]$MonitorLayout.DipX
    $window.Top = [double]$MonitorLayout.DipY
    $window.Width = [double]$MonitorLayout.DipWidth
    $window.Height = [double]$MonitorLayout.DipHeight

    $bgImage = $window.FindName('BgImage')
    $bgImage.Width = [double]$MonitorLayout.DipWidth
    $bgImage.Height = [double]$MonitorLayout.DipHeight
    if ($Context.SnapshotSource -is [System.Windows.Media.Imaging.BitmapSource]) {
        $sourceX = [int][math]::Round(
            [double]$MonitorLayout.PhysicalX - [double]$Context.VirtualBounds.X,
            0, [MidpointRounding]::AwayFromZero)
        $sourceY = [int][math]::Round(
            [double]$MonitorLayout.PhysicalY - [double]$Context.VirtualBounds.Y,
            0, [MidpointRounding]::AwayFromZero)
        $sourceWidth = [int][math]::Round(
            [double]$MonitorLayout.PhysicalWidth,
            0, [MidpointRounding]::AwayFromZero)
        $sourceHeight = [int][math]::Round(
            [double]$MonitorLayout.PhysicalHeight,
            0, [MidpointRounding]::AwayFromZero)
        $monitorSource = [System.Windows.Media.Imaging.CroppedBitmap]::new(
            $Context.SnapshotSource,
            [System.Windows.Int32Rect]::new(
                $sourceX, $sourceY, $sourceWidth, $sourceHeight))
        $monitorSource.Freeze()
        $bgImage.Source = $monitorSource
    }

    $overlay = [pscustomobject][ordered]@{
        Context = $Context
        Layout = $MonitorLayout
        Window = $window
        Lifecycle = $null
        BackgroundImage = $bgImage
        Dimmer = $window.FindName('Dimmer')
        HoverRect = $window.FindName('HoverRect')
        DragRect = $window.FindName('DragRect')
        HintBorder = $window.FindName('HintBorder')
        HintText = $window.FindName('HintText')
        SizeChip = $window.FindName('SizeChip')
        SizeChipText = $window.FindName('SizeChipText')
        DimBrushFocused = $null
        DimBrushUnfocused = $null
        LoupeBorder = $window.FindName('LoupeBorder')
        LoupeImage = $window.FindName('LoupeImage')
        LoupeText = $window.FindName('LoupeText')
        LoupeBounds = $null
        RenderedSelection = $null
        RenderedHover = $null
        RenderedCutout = $null
        RenderedChipPlacement = $null
        Closed = $false
        EventsAttached = $false
        MouseMoveHandler = $null
        MouseDownHandler = $null
        MouseUpHandler = $null
        RightDownHandler = $null
        KeyDownHandler = $null
        PositionHandler = $null
        ClosedHandler = $null
    }
    # Both marquees take the Windows accent through the Fluent key, so they track
    # the theme without SnipIT owning a colour. High Contrast still wins.
    foreach ($marquee in @($overlay.HoverRect, $overlay.DragRect)) {
        $marquee.SetResourceReference(
            [System.Windows.Shapes.Shape]::StrokeProperty, 'AccentFillColorDefaultBrush')
    }
    # Two dim levels: the monitor the pointer is on stays lighter so it reads as
    # the one being worked on, and the rest recede. High contrast opts out — the
    # system brush is the accessibility contract there, and darkening it would
    # break it.
    if ([bool]$Context.HighContrast) {
        $overlay.Dimmer.Fill = [System.Windows.SystemColors]::WindowBrush
        $overlay.DragRect.Fill = [System.Windows.SystemColors]::HighlightBrush
        $overlay.DimBrushFocused = $overlay.Dimmer.Fill
        $overlay.DimBrushUnfocused = $overlay.Dimmer.Fill
    } else {
        $overlay.DimBrushFocused = [System.Windows.Media.SolidColorBrush]::new(
            [System.Windows.Media.Color]::FromArgb(0x66, 0, 0, 0))
        $overlay.DimBrushUnfocused = [System.Windows.Media.SolidColorBrush]::new(
            [System.Windows.Media.Color]::FromArgb(0x80, 0, 0, 0))
        $overlay.DimBrushFocused.Freeze()
        $overlay.DimBrushUnfocused.Freeze()
        $overlay.Dimmer.Fill = $overlay.DimBrushFocused
    }
    [System.Windows.Automation.AutomationProperties]::SetName(
        $window, "Smart capture overlay on $($MonitorLayout.Id)")

    $register = Get-SnipOverlayService -Services $Context.Services -Name RegisterWindow
    $unregister = Get-SnipOverlayService -Services $Context.Services -Name UnregisterWindow
    $overlay.Lifecycle = Connect-SnipWindowLifecycle -Window $window `
        -Register $register -Unregister $unregister
    $positionState = [pscustomobject]@{ Overlay=$overlay }
    $position = [EventHandler]{
        param($sender,$eventArgs)
        $item = $positionState.Overlay
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($item.Window).Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        try {
            $positionWindow = Get-SnipOverlayService `
                -Services $item.Context.Services -Name PositionWindow
            $positionOutput = @(& $positionWindow $handle $item.Layout)
            $positioned = $positionOutput.Count -gt 0 -and
                $positionOutput[-1] -is [bool] -and [bool]$positionOutput[-1]
            if (-not $positioned) {
                throw [ComponentModel.Win32Exception]::new(
                    "SetWindowPos returned false for monitor '$($item.Layout.Id)'.")
            }
        } catch {
            throw [InvalidOperationException]::new(
                "SetWindowPos failed for monitor '$($item.Layout.Id)'.",
                $_.Exception)
        }
    }.GetNewClosure()
    $mouseMove = [System.Windows.Input.MouseEventHandler]{
        param($sender,$eventArgs)
        & $overlay.Context.Actions.QueuePointer $overlay | Out-Null
    }.GetNewClosure()
    $mouseDown = [System.Windows.Input.MouseButtonEventHandler]{
        param($sender,$eventArgs)
        if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
            & $overlay.Context.Actions.BeginDrag $overlay | Out-Null
            $eventArgs.Handled = $true
        }
    }.GetNewClosure()
    $mouseUp = [System.Windows.Input.MouseButtonEventHandler]{
        param($sender,$eventArgs)
        if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
            & $overlay.Context.Actions.CompleteDrag | Out-Null
            $eventArgs.Handled = $true
        }
    }.GetNewClosure()
    $rightDown = [System.Windows.Input.MouseButtonEventHandler]{
        param($sender,$eventArgs)
        & $overlay.Context.Actions.Cancel | Out-Null
        $eventArgs.Handled = $true
    }.GetNewClosure()
    $keyDown = [System.Windows.Input.KeyEventHandler]{
        param($sender,$eventArgs)
        $overlay.Context.LastInputUtc = [datetime]::UtcNow
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
            & $overlay.Context.Actions.Cancel | Out-Null
            $eventArgs.Handled = $true
        }
    }.GetNewClosure()
    $closedState = [pscustomobject]@{ Overlay=$overlay }
    $closed = [EventHandler]{
        param($sender,$eventArgs)
        $closedState.Overlay.Closed = $true
        Remove-SnipOverlayWindowEvents -Overlay $closedState.Overlay
    }.GetNewClosure()
    $overlay.PositionHandler = $position
    $overlay.MouseMoveHandler = $mouseMove
    $overlay.MouseDownHandler = $mouseDown
    $overlay.MouseUpHandler = $mouseUp
    $overlay.RightDownHandler = $rightDown
    $overlay.KeyDownHandler = $keyDown
    $overlay.ClosedHandler = $closed
    $window.Add_SourceInitialized($position)
    $window.Add_MouseMove($mouseMove)
    $window.Add_MouseLeftButtonDown($mouseDown)
    $window.Add_MouseLeftButtonUp($mouseUp)
    $window.Add_MouseRightButtonDown($rightDown)
    $window.Add_KeyDown($keyDown)
    $window.Add_Closed($closed)
    $overlay.EventsAttached = $true
    [void]$Context.Overlays.Add($overlay)
    $overlay
}

function Set-SnipOverlayRectangleVisual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $RectangleControl,
        $Intersection
    )

    if ($null -eq $Intersection) {
        $RectangleControl.Visibility = 'Collapsed'
        return
    }
    [System.Windows.Controls.Canvas]::SetLeft(
        $RectangleControl, [double]$Intersection.DipX)
    [System.Windows.Controls.Canvas]::SetTop(
        $RectangleControl, [double]$Intersection.DipY)
    $RectangleControl.Width = [double]$Intersection.DipWidth
    $RectangleControl.Height = [double]$Intersection.DipHeight
    $RectangleControl.Visibility = 'Visible'
}

function Set-SnipOverlayDimmerCutout {
    # Punches the hovered / dragged region out of this overlay's scrim so the
    # user sees the real pixels they are about to capture instead of a dimmed
    # approximation of them. Clip does the work: the dimmer paints the whole
    # monitor minus the hole, on every overlay the region crosses, so a
    # selection spanning a seam is undimmed on both sides of it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Dimmer,
        [Parameter(Mandatory)] [double]$MonitorDipWidth,
        [Parameter(Mandatory)] [double]$MonitorDipHeight,
        $Cutout
    )

    if ($null -eq $Cutout -or
        [double]$Cutout.DipWidth -le 0 -or [double]$Cutout.DipHeight -le 0) {
        $Dimmer.Clip = $null
        return $null
    }
    $full = [System.Windows.Media.RectangleGeometry]::new(
        [System.Windows.Rect]::new(0, 0, $MonitorDipWidth, $MonitorDipHeight))
    $hole = [System.Windows.Media.RectangleGeometry]::new(
        [System.Windows.Rect]::new(
            [double]$Cutout.DipX, [double]$Cutout.DipY,
            [double]$Cutout.DipWidth, [double]$Cutout.DipHeight))
    $combined = [System.Windows.Media.CombinedGeometry]::new(
        [System.Windows.Media.GeometryCombineMode]::Exclude, $full, $hole)
    $combined.Freeze()
    $Dimmer.Clip = $combined
    $combined
}

function Invoke-SnipOverlayWatchdog {
    # Runs on every composition tick, including the ones with no pointer work to
    # do, because "nothing has happened for a while" is exactly the state it
    # exists to notice. Services are looked up optionally: a caller that cannot
    # answer "is an overlay in the foreground?" gets no watchdog rather than a
    # watchdog that guesses.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if ($Context.Closing -or $Context.Dragging) { return $false }
    $foregroundProperty = $Context.Services.PSObject.Properties['GetForegroundWindow']
    if ($null -eq $foregroundProperty -or $null -eq $foregroundProperty.Value) {
        return $false
    }
    $nowUtc = [datetime]::UtcNow
    $nowProperty = $Context.Services.PSObject.Properties['GetUtcNow']
    if ($null -ne $nowProperty -and $null -ne $nowProperty.Value) {
        try {
            $nowOutput = @(& $nowProperty.Value)
            if ($nowOutput.Count) { $nowUtc = [datetime]$nowOutput[-1] }
        } catch { return $false }
    }

    $foreground = [IntPtr]::Zero
    try {
        $foregroundOutput = @(& $foregroundProperty.Value)
        if ($foregroundOutput.Count) { $foreground = [IntPtr]$foregroundOutput[-1] }
    } catch { return $false }
    $overlayIsForeground = $false
    foreach ($overlay in @($Context.Overlays)) {
        $handle = [IntPtr]$overlay.Lifecycle.Handle
        if ($handle -ne [IntPtr]::Zero -and $handle -eq $foreground) {
            $overlayIsForeground = $true
            break
        }
    }

    $shouldCancel = Test-SnipOverlayIdleTimeout -LastInputUtc $Context.LastInputUtc `
        -NowUtc $nowUtc -Timeout $Context.IdleTimeout `
        -OverlayIsForeground $overlayIsForeground
    if (-not $shouldCancel) { return $false }

    $Context.IdleCancelled = $true
    $message = ('Smart overlay self-cancelled: no pointer or key input for {0:n1}s ' +
        'and no overlay window held the foreground.') -f
        ($nowUtc - $Context.LastInputUtc).TotalSeconds
    $diagProperty = $Context.Services.PSObject.Properties['WriteDiagnostic']
    if ($null -ne $diagProperty -and $null -ne $diagProperty.Value) {
        try { & $diagProperty.Value $message | Out-Null } catch {}
    } else {
        try { Write-SnipDiag -Message $message } catch {}
    }
    & $Context.Actions.Close 'UserCancelled' | Out-Null
    $true
}

function Invoke-SnipOverlayRenderTick {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        $PhysicalPoint
    )

    if ($Context.Closing) { return }
    # Ahead of the dirty check on purpose: an idle overlay produces no pointer
    # events, so a watchdog behind that check could never fire.
    [void](Invoke-SnipOverlayWatchdog -Context $Context)
    if ($Context.Closing -or -not $Context.PointerDirty) { return }
    $Context.PointerDirty = $false
    $point = if ($PSBoundParameters.ContainsKey('PhysicalPoint')) {
        [pscustomobject][ordered]@{
            X = [int]$PhysicalPoint.X
            Y = [int]$PhysicalPoint.Y
        }
    } else {
        & $Context.Actions.ReadCursor
    }
    $Context.PointerPhysical = $point

    if ($Context.Dragging) {
        $Context.Selection = Get-DragRectangle `
            -AnchorX $Context.AnchorPhysical.X -AnchorY $Context.AnchorPhysical.Y `
            -CurrentX $point.X -CurrentY $point.Y
        $Context.HoverHwnd = [IntPtr]::Zero
        $Context.HoverBounds = $null
    } else {
        $ownHandles = [System.Collections.Generic.List[IntPtr]]::new()
        $ownValues = [System.Collections.Generic.HashSet[Int64]]::new()
        foreach ($handle in @(
                $Context.Overlays | ForEach-Object { $_.Lifecycle.Handle })) {
            $nativeHandle = [IntPtr]$handle
            if ($nativeHandle -ne [IntPtr]::Zero -and
                $ownValues.Add($nativeHandle.ToInt64())) {
                $ownHandles.Add($nativeHandle)
            }
        }
        $getOwnHandles = Get-SnipOverlayService -Services $Context.Services `
            -Name GetOwnWindowHandles
        $registeredOutput = @(& $getOwnHandles)
        foreach ($handle in $registeredOutput) {
            if ($null -eq $handle) { continue }
            $nativeHandle = [IntPtr]$handle
            if ($nativeHandle -ne [IntPtr]::Zero -and
                $ownValues.Add($nativeHandle.ToInt64())) {
                $ownHandles.Add($nativeHandle)
            }
        }
        $getWindow = Get-SnipOverlayService -Services $Context.Services -Name GetWindowAtPoint
        $windowOutput = @(& $getWindow $point ([IntPtr[]]$ownHandles.ToArray()))
        $hwnd = if ($windowOutput.Count -gt 0) {
            [IntPtr]$windowOutput[-1]
        } else {
            [IntPtr]::Zero
        }
        $Context.HoverHwnd = $hwnd
        $Context.HoverBounds = $null
        if ($hwnd -ne [IntPtr]::Zero) {
            $getBounds = Get-SnipOverlayService -Services $Context.Services -Name GetWindowBounds
            $boundsOutput = @(& $getBounds $hwnd)
            $bounds = if ($boundsOutput.Count -gt 0) { $boundsOutput[-1] } else { $null }
            if ($null -ne $bounds -and
                $null -ne $bounds.PSObject.Properties['X'] -and
                $null -ne $bounds.PSObject.Properties['Y'] -and
                $null -ne $bounds.PSObject.Properties['Width'] -and
                $null -ne $bounds.PSObject.Properties['Height'] -and
                [double]$bounds.Width -gt 0 -and [double]$bounds.Height -gt 0) {
                $Context.HoverBounds = [pscustomobject][ordered]@{
                    X=[double]$bounds.X; Y=[double]$bounds.Y
                    Width=[double]$bounds.Width; Height=[double]$bounds.Height
                }
            }
        }
    }

    # The outer @() matters: assigning an empty array out of an if-expression
    # unrolls it to $null, and these are asked for their .Count below.
    $selectionParts = @(if ($Context.Dragging -and $null -ne $Context.Selection) {
        @(Get-SnipOverlayIntersections -Rectangle $Context.Selection `
            -MonitorLayouts $Context.MonitorLayouts)
    })
    $hoverParts = @(if (-not $Context.Dragging -and $null -ne $Context.HoverBounds) {
        @(Get-SnipOverlayIntersections -Rectangle $Context.HoverBounds `
            -MonitorLayouts $Context.MonitorLayouts)
    })

    $pointerOverlay = @($Context.Overlays | Where-Object {
        $point.X -ge $_.Layout.PhysicalX -and
        $point.X -lt ($_.Layout.PhysicalX + $_.Layout.PhysicalWidth) -and
        $point.Y -ge $_.Layout.PhysicalY -and
        $point.Y -lt ($_.Layout.PhysicalY + $_.Layout.PhysicalHeight)
    } | Select-Object -First 1)
    $pointerOverlayItem = if ($pointerOverlay.Count) { $pointerOverlay[0] } else { $null }

    # The size chip belongs to exactly one overlay: the one under the pointer,
    # which owns the corner of the drag rectangle the user is actually moving.
    # If the pointer has left the desktop mid-drag, fall back to the overlay
    # holding the largest piece of the selection so the readout never vanishes.
    $chipOverlay = $null
    if ($Context.Dragging -and $selectionParts.Count -gt 0) {
        if ($null -ne $pointerOverlayItem -and @($selectionParts | Where-Object {
                $_.MonitorIndex -eq $pointerOverlayItem.Layout.Index
            }).Count -gt 0) {
            $chipOverlay = $pointerOverlayItem
        } else {
            $largestPart = @($selectionParts | Sort-Object -Property @{
                Expression = { [double]$_.DipWidth * [double]$_.DipHeight }
            } -Descending | Select-Object -First 1)
            if ($largestPart.Count) {
                $chipOverlay = @($Context.Overlays | Where-Object {
                    $_.Layout.Index -eq $largestPart[0].MonitorIndex
                } | Select-Object -First 1)[0]
            }
        }
    }

    foreach ($overlay in @($Context.Overlays)) {
        $selectionPart = @($selectionParts | Where-Object {
            $_.MonitorIndex -eq $overlay.Layout.Index
        } | Select-Object -First 1)
        $selectionPart = if ($selectionPart.Count) { $selectionPart[0] } else { $null }
        $overlay.RenderedSelection = $selectionPart
        Set-SnipOverlayRectangleVisual -RectangleControl $overlay.DragRect `
            -Intersection $selectionPart

        $hoverPart = @($hoverParts | Where-Object {
            $_.MonitorIndex -eq $overlay.Layout.Index
        } | Select-Object -First 1)
        $hoverPart = if ($hoverPart.Count) { $hoverPart[0] } else { $null }
        $overlay.RenderedHover = $hoverPart
        Set-SnipOverlayRectangleVisual -RectangleControl $overlay.HoverRect `
            -Intersection $hoverPart

        $isPointerOverlay = $null -ne $pointerOverlayItem -and
            [object]::ReferenceEquals($overlay, $pointerOverlayItem)
        $overlay.Dimmer.Fill = if ($isPointerOverlay) {
            $overlay.DimBrushFocused
        } else {
            $overlay.DimBrushUnfocused
        }
        $cutout = if ($Context.Dragging) { $selectionPart } else { $hoverPart }
        $overlay.RenderedCutout = Set-SnipOverlayDimmerCutout -Dimmer $overlay.Dimmer `
            -MonitorDipWidth ([double]$overlay.Layout.DipWidth) `
            -MonitorDipHeight ([double]$overlay.Layout.DipHeight) `
            -Cutout $cutout

        # Instruction banner before a drag, on the pointer's monitor only; the
        # live size chip during one, on the chip overlay only. They are never
        # both up, and neither is ever duplicated across displays.
        $overlay.HintBorder.Visibility = if (-not $Context.Dragging -and $isPointerOverlay) {
            'Visible'
        } else {
            'Collapsed'
        }

        if ($null -ne $chipOverlay -and
            [object]::ReferenceEquals($overlay, $chipOverlay) -and
            $null -ne $selectionPart) {
            $overlay.SizeChipText.Text = ('{0} × {1} px' -f
                [int]$Context.Selection.Width, [int]$Context.Selection.Height)
            # Make it visible before measuring: a Collapsed element measures to
            # zero, which would place the chip as though it had no width and
            # left-align it against the corner instead of right-aligning it.
            $overlay.SizeChip.Visibility = 'Visible'
            $overlay.SizeChip.Measure([System.Windows.Size]::new(
                [double]::PositiveInfinity, [double]::PositiveInfinity))
            $chipSize = $overlay.SizeChip.DesiredSize
            $placement = Get-SnipSizeChipPlacement `
                -RectX ([double]$selectionPart.DipX) `
                -RectY ([double]$selectionPart.DipY) `
                -RectWidth ([double]$selectionPart.DipWidth) `
                -RectHeight ([double]$selectionPart.DipHeight) `
                -ChipWidth ([double]$chipSize.Width) `
                -ChipHeight ([double]$chipSize.Height) `
                -MonitorWidth ([double]$overlay.Layout.DipWidth) `
                -MonitorHeight ([double]$overlay.Layout.DipHeight)
            $overlay.RenderedChipPlacement = $placement
            [System.Windows.Controls.Canvas]::SetLeft($overlay.SizeChip, $placement.X)
            [System.Windows.Controls.Canvas]::SetTop($overlay.SizeChip, $placement.Y)
        } else {
            $overlay.RenderedChipPlacement = $null
            $overlay.SizeChip.Visibility = 'Collapsed'
        }
    }

    foreach ($overlay in @($Context.Overlays)) {
        if ($null -eq $pointerOverlayItem -or
            -not [object]::ReferenceEquals($overlay, $pointerOverlayItem)) {
            $overlay.LoupeBorder.Visibility = 'Collapsed'
            $overlay.LoupeBounds = $null
            continue
        }

        $loupeWidth = [int][math]::Round(
            $overlay.LoupeBorder.Width * $overlay.Layout.ScaleX,
            0, [MidpointRounding]::AwayFromZero)
        $loupeHeight = [int][math]::Round(
            $overlay.LoupeBorder.Height * $overlay.Layout.ScaleY,
            0, [MidpointRounding]::AwayFromZero)
        $position = Get-LoupePosition -MouseX $point.X -MouseY $point.Y `
            -VsX ([int]$overlay.Layout.PhysicalX) `
            -VsY ([int]$overlay.Layout.PhysicalY) `
            -VsWidth ([int]$overlay.Layout.PhysicalWidth) `
            -VsHeight ([int]$overlay.Layout.PhysicalHeight) `
            -LoupeWidth $loupeWidth -LoupeHeight $loupeHeight
        $pointerLocalX = $point.X - [double]$overlay.Layout.PhysicalX
        $pointerLocalY = $point.Y - [double]$overlay.Layout.PhysicalY
        $candidates = @(
            [pscustomobject]@{ X=$position.X; Y=$position.Y },
            [pscustomobject]@{
                X=$pointerLocalX - $loupeWidth - 14
                Y=$pointerLocalY - $loupeHeight - 10
            },
            [pscustomobject]@{
                X=$pointerLocalX + 24
                Y=$pointerLocalY - $loupeHeight - 10
            },
            [pscustomobject]@{
                X=$pointerLocalX - $loupeWidth - 14
                Y=$pointerLocalY + 24
            },
            [pscustomobject]@{ X=$pointerLocalX + 24; Y=$pointerLocalY + 24 }
        )
        # What the loupe must not sit on top of: the selection it is helping the
        # user aim, and the size chip, which is anchored to the same corner the
        # loupe wants to hug and would otherwise be covered by it. Both are in
        # global physical pixels.
        $avoidRects = [System.Collections.Generic.List[object]]::new()
        if ($Context.Dragging -and $null -ne $Context.Selection) {
            $avoidRects.Add([pscustomobject]@{
                X = [double]$Context.Selection.X
                Y = [double]$Context.Selection.Y
                Width = [double]$Context.Selection.Width
                Height = [double]$Context.Selection.Height
            })
        }
        if ($null -ne $overlay.RenderedChipPlacement -and
            $overlay.SizeChip.Visibility -eq 'Visible') {
            $chipSize = $overlay.SizeChip.DesiredSize
            $chipOrigin = ConvertTo-SnipPhysicalPoint `
                -DipX ([double]$overlay.RenderedChipPlacement.X) `
                -DipY ([double]$overlay.RenderedChipPlacement.Y) `
                -MonitorPhysicalX ([double]$overlay.Layout.PhysicalX) `
                -MonitorPhysicalY ([double]$overlay.Layout.PhysicalY) `
                -ScaleX ([double]$overlay.Layout.ScaleX) `
                -ScaleY ([double]$overlay.Layout.ScaleY)
            $avoidRects.Add([pscustomobject]@{
                X = [double]$chipOrigin.X
                Y = [double]$chipOrigin.Y
                Width = [double]$chipSize.Width * [double]$overlay.Layout.ScaleX
                Height = [double]$chipSize.Height * [double]$overlay.Layout.ScaleY
            })
        }

        $localX = 0
        $localY = 0
        $bestOverlap = [double]::PositiveInfinity
        foreach ($candidate in $candidates) {
            $candidateX = [math]::Max(0, [math]::Min(
                [double]$overlay.Layout.PhysicalWidth - $loupeWidth,
                [double]$candidate.X))
            $candidateY = [math]::Max(0, [math]::Min(
                [double]$overlay.Layout.PhysicalHeight - $loupeHeight,
                [double]$candidate.Y))
            $overlap = 0.0
            $candidateGlobalX = [double]$overlay.Layout.PhysicalX + $candidateX
            $candidateGlobalY = [double]$overlay.Layout.PhysicalY + $candidateY
            foreach ($avoid in $avoidRects) {
                $overlapWidth = [math]::Min(
                    $candidateGlobalX + $loupeWidth, $avoid.X + $avoid.Width) -
                    [math]::Max($candidateGlobalX, $avoid.X)
                $overlapHeight = [math]::Min(
                    $candidateGlobalY + $loupeHeight, $avoid.Y + $avoid.Height) -
                    [math]::Max($candidateGlobalY, $avoid.Y)
                if ($overlapWidth -gt 0 -and $overlapHeight -gt 0) {
                    $overlap += $overlapWidth * $overlapHeight
                }
            }
            if ($overlap -lt $bestOverlap) {
                $bestOverlap = $overlap
                $localX = $candidateX
                $localY = $candidateY
                if ($bestOverlap -eq 0) { break }
            }
        }
        # $localX/$localY are monitor-local physical pixels; the Canvas wants
        # monitor-local DIPs.
        $loupeDip = ConvertTo-SnipDipPoint `
            -PhysicalX ([double]$overlay.Layout.PhysicalX + $localX) `
            -PhysicalY ([double]$overlay.Layout.PhysicalY + $localY) `
            -MonitorPhysicalX ([double]$overlay.Layout.PhysicalX) `
            -MonitorPhysicalY ([double]$overlay.Layout.PhysicalY) `
            -ScaleX ([double]$overlay.Layout.ScaleX) `
            -ScaleY ([double]$overlay.Layout.ScaleY)
        [System.Windows.Controls.Canvas]::SetLeft($overlay.LoupeBorder, $loupeDip.X)
        [System.Windows.Controls.Canvas]::SetTop($overlay.LoupeBorder, $loupeDip.Y)
        $overlay.LoupeBounds = [pscustomobject][ordered]@{
            X = [double]$overlay.Layout.PhysicalX + $localX
            Y = [double]$overlay.Layout.PhysicalY + $localY
            Width = $loupeWidth
            Height = $loupeHeight
        }
        if ($Context.SnapshotSource -is [System.Windows.Media.Imaging.BitmapSource]) {
            $source = Get-LoupeSourceRect -MouseX $point.X -MouseY $point.Y `
                -VsX ([int]$Context.VirtualBounds.X) -VsY ([int]$Context.VirtualBounds.Y) `
                -VsWidth ([int]$Context.VirtualBounds.Width) `
                -VsHeight ([int]$Context.VirtualBounds.Height) `
                -Size $script:SnipLoupeSourceSize
            $loupeSource = [System.Windows.Media.Imaging.CroppedBitmap]::new(
                $Context.SnapshotSource,
                [System.Windows.Int32Rect]::new($source.X, $source.Y, $source.Size, $source.Size))
            $loupeSource.Freeze()
            # Stretch="Fill" over an exact multiple: the patch is magnified, and
            # NearestNeighbor keeps the enlarged pixels square-edged.
            $overlay.LoupeImage.Width = $script:SnipLoupeViewportSize
            $overlay.LoupeImage.Height = $script:SnipLoupeViewportSize
            $overlay.LoupeImage.Source = $loupeSource
        }
        $overlay.LoupeText.Text = ('{0} , {1}' -f $point.X, $point.Y)
        $overlay.LoupeBorder.Visibility = 'Visible'
    }
    $Context.RenderCount++
}

function Show-SmartOverlaySet {
    [CmdletBinding()]
    param(
        [scriptblock]$OnSurfaceReady,
        $Services,
        [scriptblock]$TestAction,
        [scriptblock]$HideWindows,
        [scriptblock]$RestoreWindows,
        [scriptblock]$CaptureFactory,
        [scriptblock]$BitmapSourceFactory,
        $DisplayTopology,
        [timespan]$IdleTimeout = ([timespan]::FromSeconds(20))
    )

    $snapshot = $null
    $context = $null
    $overlayServices = $Services
    try {
        if ($null -eq $overlayServices) {
            $overlayServices = [pscustomobject][ordered]@{
                GetMonitorDescriptors = { @(Get-SnipMonitorDescriptors) }
                GetVirtualBounds = { Get-VirtualScreenBounds }
                HideWindows = $HideWindows
                RestoreWindows = $RestoreWindows
                CaptureSnapshot = $CaptureFactory
                ConvertSnapshotSource = $BitmapSourceFactory
                GetCursorPosition = {
                    $point = [Native+POINT]::new()
                    if (-not [Native]::GetCursorPos([ref]$point)) {
                        throw [InvalidOperationException]::new('GetCursorPos failed.')
                    }
                    [pscustomobject][ordered]@{ X=$point.X; Y=$point.Y }
                }
                GetWindowAtPoint = {
                    param($point,$ownHandles)
                    Get-SnipWindowAtPhysicalPoint -Point $point -OwnHandles $ownHandles
                }
                GetWindowBounds = { param($hwnd) Get-SnipWindowBounds -Hwnd $hwnd }
                GetOwnWindowHandles = { @($script:SelfWindowHandles) }
                GetForegroundWindow = { [Native]::GetForegroundWindow() }
                GetUtcNow = { [datetime]::UtcNow }
                WriteDiagnostic = { param($message) Write-SnipDiag -Message $message }
                PositionWindow = {
                    param($hwnd,$layout)
                    if (-not [Native]::SetWindowPos(
                            $hwnd, [Native]::HWND_TOPMOST,
                            [int]$layout.PhysicalX, [int]$layout.PhysicalY,
                            [int]$layout.PhysicalWidth, [int]$layout.PhysicalHeight,
                            [Native]::SWP_NOACTIVATE -bor [Native]::SWP_SHOWWINDOW)) {
                        $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw [ComponentModel.Win32Exception]::new(
                            $nativeError,
                            "SetWindowPos failed for monitor '$($layout.Id)'.")
                    }
                    $true
                }
                AddRenderingHandler = {
                    param($handler)
                    [System.Windows.Media.CompositionTarget]::add_Rendering($handler)
                }
                RemoveRenderingHandler = {
                    param($handler)
                    [System.Windows.Media.CompositionTarget]::remove_Rendering($handler)
                }
                RegisterWindow = { param($hwnd) Register-SelfWindowHandle -Hwnd $hwnd }
                UnregisterWindow = { param($hwnd) Unregister-SelfWindowHandle -Hwnd $hwnd }
                HighContrast = [bool][System.Windows.SystemParameters]::HighContrast
            }
        }

        $topologyWasSupplied = $null -ne $DisplayTopology
        $requiredServices = @('HideWindows','RestoreWindows','CaptureSnapshot',
            'ConvertSnapshotSource','GetCursorPosition',
            'GetWindowAtPoint','GetWindowBounds','GetOwnWindowHandles','PositionWindow',
            'AddRenderingHandler',
            'RemoveRenderingHandler','RegisterWindow','UnregisterWindow','HighContrast')
        if (-not $topologyWasSupplied) {
            $requiredServices = @('GetMonitorDescriptors','GetVirtualBounds') + $requiredServices
        }
        foreach ($name in $requiredServices) {
            [void](Get-SnipOverlayService -Services $overlayServices -Name $name)
        }
        if ($topologyWasSupplied) {
            $layouts = @($DisplayTopology.Layouts)
            $virtualBounds = $DisplayTopology.VirtualPhysicalBounds
        } else {
            $getDescriptors = Get-SnipOverlayService -Services $overlayServices `
                -Name GetMonitorDescriptors
            $descriptors = @(& $getDescriptors)
            $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $descriptors)
            $getVirtualBounds = Get-SnipOverlayService -Services $overlayServices `
                -Name GetVirtualBounds
            $virtualOutput = @(& $getVirtualBounds)
            $virtualBounds = if ($virtualOutput.Count) { $virtualOutput[-1] } else { $null }
        }
        if ($null -eq $virtualBounds) {
            throw [InvalidOperationException]::new('Virtual screen bounds are unavailable.')
        }

        $hide = Get-SnipOverlayService -Services $overlayServices -Name HideWindows
        $restore = Get-SnipOverlayService -Services $overlayServices -Name RestoreWindows
        $capture = Get-SnipOverlayService -Services $overlayServices -Name CaptureSnapshot
        $convert = Get-SnipOverlayService -Services $overlayServices -Name ConvertSnapshotSource
        $hidden = & $hide
        try {
            $captureOutput = @(& $capture $virtualBounds)
            $snapshot = if ($captureOutput.Count) { $captureOutput[-1] } else { $null }
        } finally {
            & $restore $hidden | Out-Null
        }
        if ($null -eq $snapshot) {
            throw [InvalidOperationException]::new('Virtual snapshot creation returned null.')
        }
        $sourceOutput = @(& $convert $snapshot)
        $snapshotSource = if ($sourceOutput.Count) { $sourceOutput[-1] } else { $null }
        $highContrast = [bool](Get-SnipOverlayService `
            -Services $overlayServices -Name HighContrast)
        $context = New-SnipOverlayContext -Snapshot $snapshot `
            -SnapshotSource $snapshotSource -VirtualBounds $virtualBounds `
            -MonitorLayouts $layouts -Services $overlayServices `
            -HighContrast $highContrast -IdleTimeout $IdleTimeout
        foreach ($layout in $layouts) {
            New-SnipOverlayWindow -Context $context -MonitorLayout $layout | Out-Null
        }

        $renderState = [pscustomobject]@{ Context=$context }
        $renderHandler = [EventHandler]{
            param($sender,$eventArgs)
            try {
                Invoke-SnipOverlayRenderTick -Context $renderState.Context
            } catch {
                $renderState.Context.ErrorRecord = $_
                & $renderState.Context.Actions.Close 'Failed' | Out-Null
            }
        }.GetNewClosure()
        $context.RenderingHandler = $renderHandler
        $surface = [pscustomobject][ordered]@{
            Kind = 'Selecting'
            Window = $context.Overlays[0].Window
            Windows = @($context.Overlays | ForEach-Object Window)
            Context = $context
            Close = {
                param([string]$result)
                & $context.Actions.Close $result
            }.GetNewClosure()
        }
        $showSurface = $true
        if ($OnSurfaceReady) {
            $readyOutput = @(& $OnSurfaceReady $surface)
            $readyValue = if ($readyOutput.Count) { $readyOutput[-1] } else { $null }
            if ($readyValue -is [bool] -and -not $readyValue) { $showSurface = $false }
        }

        if ($showSurface) {
            $addRendering = Get-SnipOverlayService -Services $overlayServices `
                -Name AddRenderingHandler
            # Treat subscription as owned before invoking the injected seam so
            # a service that attaches and then throws is still detached.
            $context.RenderingAttached = $true
            & $addRendering $renderHandler | Out-Null
            if ($TestAction) {
                foreach ($overlay in @($context.Overlays)) {
                    $overlay.Window.Opacity = 0
                    $overlay.Window.ShowActivated = $false
                    $overlay.Window.Show()
                    $overlay.Window.UpdateLayout()
                }
                $kit = [pscustomobject][ordered]@{
                    Context = $context
                    Overlays = @($context.Overlays)
                    QueuePointer = $context.Actions.QueuePointer
                    BeginDrag = $context.Actions.BeginDrag
                    CompleteDrag = $context.Actions.CompleteDrag
                    Cancel = $context.Actions.Cancel
                    Close = $context.Actions.Close
                    RenderTick = { Invoke-SnipOverlayRenderTick -Context $context }.GetNewClosure()
                }
                & $TestAction $kit | Out-Null
                if (-not $context.Closing) { & $context.Actions.Cancel | Out-Null }
            } else {
                for ($index = 1; $index -lt $context.Overlays.Count; $index++) {
                    $context.Overlays[$index].Window.Show()
                }
                $context.Overlays[0].Window.ShowDialog() | Out-Null
            }
        }

        if ($context.SurfaceResult -eq 'Completed') {
            $validSelection = $null -ne $context.Selection
            if ($validSelection) {
                foreach ($propertyName in 'X','Y','Width','Height') {
                    if ($null -eq $context.Selection.PSObject.Properties[$propertyName]) {
                        $validSelection = $false
                        break
                    }
                }
            }
            if ($validSelection) {
                try {
                    $selection = [pscustomobject][ordered]@{
                        X = [int][math]::Round([double]$context.Selection.X, 0,
                            [MidpointRounding]::AwayFromZero)
                        Y = [int][math]::Round([double]$context.Selection.Y, 0,
                            [MidpointRounding]::AwayFromZero)
                        Width = [int][math]::Round([double]$context.Selection.Width, 0,
                            [MidpointRounding]::AwayFromZero)
                        Height = [int][math]::Round([double]$context.Selection.Height, 0,
                            [MidpointRounding]::AwayFromZero)
                    }
                    $validSelection = Test-CaptureRectValid `
                        -Width $selection.Width -Height $selection.Height
                } catch {
                    $validSelection = $false
                }
            }
            if (-not $validSelection) {
                $context.SurfaceResult = 'UserCancelled'
                $selection = $null
            }
        } else {
            $selection = $null
        }
        [pscustomobject][ordered]@{
            Result = $context.SurfaceResult
            Selection = $selection
            Bitmap = $null
            ErrorRecord = $context.ErrorRecord
        }
    } catch {
        [pscustomobject][ordered]@{
            Result = 'Failed'
            Selection = $null
            Bitmap = $null
            ErrorRecord = $_
        }
    } finally {
        if ($null -ne $context) {
            if ($context.RenderingAttached) {
                try {
                    $removeRendering = Get-SnipOverlayService `
                        -Services $context.Services -Name RemoveRenderingHandler
                    & $removeRendering $context.RenderingHandler | Out-Null
                } catch {}
                $context.RenderingAttached = $false
            }
            foreach ($overlay in @($context.Overlays)) {
                try { $overlay.Window.Close() } catch {}
                Remove-SnipOverlayWindowEvents -Overlay $overlay
            }
        }
        if ($null -ne $snapshot) {
            try { Invoke-SnipResourceDispose -Resource $snapshot } catch {}
        }
    }
}

function Show-SmartOverlay {
    [CmdletBinding()]
    param(
        [scriptblock]$OnSurfaceReady,
        $Services,
        [scriptblock]$TestAction,
        [scriptblock]$HideWindows = { Hide-OwnSnipITWindowsForCapture },
        [scriptblock]$RestoreWindows = {
            param($hidden)
            Show-OwnSnipITWindowsForCapture -Hidden $hidden
        },
        [scriptblock]$CaptureFactory = {
            param($bounds)
            New-ScreenBitmap -X $bounds.X -Y $bounds.Y `
                -Width $bounds.Width -Height $bounds.Height
        },
        [scriptblock]$BitmapSourceFactory = {
            param($bitmap)
            Convert-BitmapToBitmapSource $bitmap
        },
        $DisplayTopology,
        [timespan]$IdleTimeout = ([timespan]::FromSeconds(20))
    )

    Show-SmartOverlaySet -OnSurfaceReady $OnSurfaceReady `
        -Services $Services -TestAction $TestAction `
        -HideWindows $HideWindows -RestoreWindows $RestoreWindows `
        -CaptureFactory $CaptureFactory -BitmapSourceFactory $BitmapSourceFactory `
        -DisplayTopology $DisplayTopology -IdleTimeout $IdleTimeout
}

function New-SnipRuntimeCaptureServices {
    [CmdletBinding()]
    param(
        [scriptblock]$SmartOverlay = {
            param($onSurfaceReady,$coordinator,$request,$displayTopology)
            Show-SmartOverlay -OnSurfaceReady $onSurfaceReady `
                -DisplayTopology $displayTopology
        },
        [scriptblock]$GetMonitorDescriptors = { @(Get-SnipMonitorDescriptors) },
        [scriptblock]$GetVirtualBounds = { Get-VirtualScreenBounds },
        [scriptblock]$GetTopology,
        [scriptblock]$ResolveWindow = {
            $foreground = [Native]::GetForegroundWindow()
            $target = Resolve-WindowCaptureTarget -ForegroundHwnd $foreground `
                -SelfWindowHandles $script:SelfWindowHandles
            if ($null -eq $target) { return $null }

            $bounds = New-Object Native+RECT
            $gotBounds = ([Native]::DwmGetWindowAttribute(
                $target, [Native]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$bounds, 16) -eq 0)
            if (-not $gotBounds) {
                $gotBounds = [Native]::GetWindowRect($target, [ref]$bounds)
            }
            $width = $bounds.Right - $bounds.Left
            $height = $bounds.Bottom - $bounds.Top
            if (-not $gotBounds -or $width -le 0 -or $height -le 0) {
                return $null
            }
            [pscustomobject][ordered]@{
                Hwnd = $target
                X = $bounds.Left
                Y = $bounds.Top
                Width = $width
                Height = $height
            }
        },
        [scriptblock]$HideWindows = { Hide-OwnSnipITWindowsForCapture },
        [scriptblock]$RestoreWindows = {
            param($hidden)
            Show-OwnSnipITWindowsForCapture -Hidden $hidden
        },
        [scriptblock]$CaptureRectangle = {
            param($bounds)
            New-ScreenBitmap -X $bounds.X -Y $bounds.Y `
                -Width $bounds.Width -Height $bounds.Height
        },
        [scriptblock]$NotifyFailure = {
            param($message)
            try {
                if ($null -ne $script:tray) {
                    $script:tray.BalloonTipTitle = 'SnipIT'
                    $script:tray.BalloonTipText = [string]$message
                    $script:tray.ShowBalloonTip(3000)
                }
            } catch {}
        }
    )

    $smartOverlayForCapture = $SmartOverlay
    $getMonitorDescriptorsForCapture = $GetMonitorDescriptors
    $getVirtualBoundsForCapture = $GetVirtualBounds
    $getTopologyForCapture = $GetTopology
    $resolveWindowForCapture = $ResolveWindow
    $hideWindowsForCapture = $HideWindows
    $restoreWindowsForCapture = $RestoreWindows
    $captureRectangleForCapture = $CaptureRectangle
    $notifyFailureForCapture = $NotifyFailure
    $useCompatibilityVirtualBounds = $PSBoundParameters.ContainsKey('GetVirtualBounds') -and
        -not $PSBoundParameters.ContainsKey('GetMonitorDescriptors') -and
        -not $PSBoundParameters.ContainsKey('GetTopology')
    $resolveTopology = {
        if ($null -ne $getTopologyForCapture) {
            $output = @(& $getTopologyForCapture)
            $topology = if ($output.Count) { $output[-1] } else { $null }
        } elseif ($useCompatibilityVirtualBounds) {
            $boundsOutput = @(& $getVirtualBoundsForCapture)
            $bounds = if ($boundsOutput.Count) { $boundsOutput[-1] } else { $null }
            if ($null -eq $bounds) {
                throw [InvalidOperationException]::new('Virtual screen bounds are unavailable.')
            }
            $topology = New-SnipDisplayTopology -MonitorDescriptors @(
                [pscustomobject][ordered]@{
                    Id='virtual-screen'; X=[int]$bounds.X; Y=[int]$bounds.Y
                    Width=[int]$bounds.Width; Height=[int]$bounds.Height
                    WorkX=[int]$bounds.X; WorkY=[int]$bounds.Y
                    WorkWidth=[int]$bounds.Width; WorkHeight=[int]$bounds.Height
                    DpiX=96.0; DpiY=96.0; IsPrimary=$true
                }
            )
        } else {
            $descriptorOutput = @(& $getMonitorDescriptorsForCapture)
            $descriptors = @($descriptorOutput)
            $topology = New-SnipDisplayTopology -MonitorDescriptors $descriptors
        }
        foreach ($propertyName in 'Descriptors','Layouts','VirtualPhysicalBounds','Fingerprint') {
            if ($null -eq $topology -or $null -eq $topology.PSObject.Properties[$propertyName]) {
                throw [InvalidOperationException]::new(
                    "Display topology is missing '$propertyName'.")
            }
        }
        $topology
    }.GetNewClosure()
    $newCaptureFailure = {
        param([string]$message,[string]$errorId)
        & $notifyFailureForCapture $message | Out-Null
        $exception = [InvalidOperationException]::new($message)
        [pscustomobject][ordered]@{
            Result='Failed'
            Bitmap=$null
            ErrorRecord=[Management.Automation.ErrorRecord]::new(
                $exception, $errorId,
                [Management.Automation.ErrorCategory]::InvalidOperation, $null)
        }
    }.GetNewClosure()
    $captureBounds = {
        param($bounds,$displayTopology)
        $hidden = & $hideWindowsForCapture
        try {
            $captured = & $captureRectangleForCapture $bounds
            if ($captured -is [System.Drawing.Image]) {
                $captured.Tag = [pscustomobject][ordered]@{
                    X=[int]$bounds.X; Y=[int]$bounds.Y
                    Width=[int]$bounds.Width; Height=[int]$bounds.Height
                    DisplayTopology=$displayTopology
                }
            }
            $captured
        } finally {
            & $restoreWindowsForCapture $hidden | Out-Null
        }
    }.GetNewClosure()

    $fullCapture = {
        param($coordinator,$request)
        $topology = & $resolveTopology
        & $captureBounds $topology.VirtualPhysicalBounds $topology
    }.GetNewClosure()

    $windowCapture = {
        param($coordinator,$request)
        $topology = & $resolveTopology
        # Foreground HWND and bounds are deliberately resolved for every fresh
        # Window request, immediately before that request's snapshot.
        $descriptor = & $resolveWindowForCapture
        $validDescriptor = $null -ne $descriptor
        $captureDescriptor = $null
        if ($validDescriptor) {
            foreach ($propertyName in 'X','Y','Width','Height') {
                if ($null -eq $descriptor.PSObject.Properties[$propertyName]) {
                    $validDescriptor = $false
                    break
                }
            }
        }
        if ($validDescriptor) {
            try {
                $x = [int]$descriptor.X
                $y = [int]$descriptor.Y
                $width = [int]$descriptor.Width
                $height = [int]$descriptor.Height
                $validDescriptor = ($width -gt 0 -and $height -gt 0)
                if ($validDescriptor) {
                    $hwndProperty = $descriptor.PSObject.Properties['Hwnd']
                    $captureDescriptor = [pscustomobject][ordered]@{
                        Hwnd = if ($null -ne $hwndProperty) { $hwndProperty.Value } else { $null }
                        X = $x
                        Y = $y
                        Width = $width
                        Height = $height
                    }
                }
            } catch {
                $validDescriptor = $false
            }
        }
        if (-not $validDescriptor) {
            return (& $newCaptureFailure 'No capturable active window' `
                'SnipIT.NoCapturableActiveWindow')
        }
        & $captureBounds $captureDescriptor $topology
    }.GetNewClosure()

    $displayCapture = {
        param($coordinator,$request)
        $topology = & $resolveTopology
        $monitorId = [string]$request.MonitorId
        $layout = @($topology.Layouts | Where-Object {
            [string]$_.Id -ceq $monitorId
        } | Select-Object -First 1)
        if ($layout.Count -eq 0) {
            return (& $newCaptureFailure `
                "Display '$monitorId' is no longer available" `
                'SnipIT.DisplayNoLongerAvailable')
        }
        $bounds = [pscustomobject][ordered]@{
            X=[int]$layout[0].PhysicalX
            Y=[int]$layout[0].PhysicalY
            Width=[int]$layout[0].PhysicalWidth
            Height=[int]$layout[0].PhysicalHeight
        }
        & $captureBounds $bounds $topology
    }.GetNewClosure()

    $smartCapture = {
        param($coordinator,$request)
        $topology = $null
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            $candidate = & $resolveTopology
            $verification = & $resolveTopology
            if ([string]$candidate.Fingerprint -ceq [string]$verification.Fingerprint) {
                $topology = $candidate
                break
            }
        }
        if ($null -eq $topology) {
            return (& $newCaptureFailure `
                'The display configuration changed during capture. Try again.' `
                'SnipIT.DisplayTopologyChanged')
        }
        $surfaceContext = [pscustomobject]@{
            Coordinator = $coordinator
            Request = $request
        }
        $surfaceReady = {
            param($surface)
            $owner = $surfaceContext.Coordinator

            if ($owner.ShutdownRequested -or $owner.Phase -eq 'ShuttingDown') {
                $owner.ActiveSurface = $surface
                $owner.SurfaceCloseRequested = $false
                $owner.Phase = 'ShuttingDown'
                Close-SnipActiveSurface -Coordinator $owner -Result Shutdown | Out-Null
                return $false
            }

            if ($null -ne $owner.PendingRequest -or
                $null -eq $owner.ActiveRequest -or
                $owner.ActiveRequest.Id -ne $surfaceContext.Request.Id) {
                # Register only long enough to close the stale surface.  Its
                # transaction never exposes Selecting.
                $owner.ActiveSurface = $surface
                $owner.SurfaceCloseRequested = $false
                Close-SnipActiveSurface -Coordinator $owner -Result Preempted | Out-Null
                return $false
            }

            # The current request publishes its closable surface and Selecting
            # atomically on this UI-thread callback.
            $owner.ActiveSurface = $surface
            $owner.SurfaceCloseRequested = $false
            $owner.Phase = 'Selecting'
            return $true
        }.GetNewClosure()
        $overlayOutput = @(& $smartOverlayForCapture $surfaceReady $coordinator $request $topology)
        $overlayResult = if ($overlayOutput.Count) { $overlayOutput[-1] } else { $null }
        if ($null -eq $overlayResult) {
            return [pscustomobject][ordered]@{
                Result='UserCancelled'; Bitmap=$null; ErrorRecord=$null
            }
        }
        $resultProperty = $overlayResult.PSObject.Properties['Result']
        $resultName = if ($null -ne $resultProperty) {
            [string]$resultProperty.Value
        } else {
            'UserCancelled'
        }
        if ($resultName -ne 'Completed') { return $overlayResult }

        $selectionProperty = $overlayResult.PSObject.Properties['Selection']
        $selection = if ($null -ne $selectionProperty) {
            $selectionProperty.Value
        } else {
            $null
        }
        $validSelection = $null -ne $selection
        if ($validSelection) {
            foreach ($propertyName in 'X','Y','Width','Height') {
                if ($null -eq $selection.PSObject.Properties[$propertyName]) {
                    $validSelection = $false
                    break
                }
            }
        }
        if ($validSelection) {
            try {
                $selectionBounds = [pscustomobject][ordered]@{
                    X = [int]$selection.X
                    Y = [int]$selection.Y
                    Width = [int]$selection.Width
                    Height = [int]$selection.Height
                }
                $validSelection = Test-CaptureRectValid `
                    -Width $selectionBounds.Width -Height $selectionBounds.Height
            } catch {
                $validSelection = $false
            }
        }
        if (-not $validSelection) {
            return [pscustomobject][ordered]@{
                Result='UserCancelled'; Bitmap=$null; ErrorRecord=$null
            }
        }

        # Overlay returns only physical geometry.  The coordinator-owned
        # capture service creates the fresh crop after all overlay HWNDs close.
        & $captureBounds $selectionBounds $topology
    }.GetNewClosure()

    $preview = {
        param($bitmap,$accept,$coordinator,$request)
        $coordinatorForPreview = $coordinator
        $surfaceReady = {
            param($surface)
            $coordinatorForPreview.ActiveSurface = $surface
            $coordinatorForPreview.PreviewWindow = $surface.Window
            $coordinatorForPreview.SurfaceCloseRequested = $false
        }.GetNewClosure()
        $newSnip = {
            Request-SnipCapture -Coordinator $coordinatorForPreview `
                -Mode Smart -Source PreviewNew | Out-Null
        }.GetNewClosure()
        $outputStarting = {
            param($kind)
            if ($coordinatorForPreview.Phase -eq 'Previewing') {
                $coordinatorForPreview.Phase = 'Completing'
            }
        }.GetNewClosure()
        $outputCompleted = {
            param($kind,$success)
            $result = if ($success) { 'Completed' } else { 'UserCancelled' }
            $operation = switch ($kind) {
                'CopyAndClose' { 'Copy' }
                'CopyKeepOpen' { 'CopyKeepOpen' }
                default { 'Save' }
            }
            Complete-SnipSurface -Coordinator $coordinatorForPreview `
                -Result $result -Operation $operation | Out-Null
        }.GetNewClosure()
        $tag = if ($bitmap -is [System.Drawing.Image]) { $bitmap.Tag } else { $null }
        $displayTopology = if ($null -ne $tag -and
            $null -ne $tag.PSObject.Properties['DisplayTopology']) {
            $tag.DisplayTopology
        } else { $null }
        $settingsProperty = if ($null -ne $coordinatorForPreview) {
            $coordinatorForPreview.PSObject.Properties['Settings']
        } else { $null }
        $previewSettings = if ($null -ne $settingsProperty -and $null -ne $settingsProperty.Value) {
            $settingsProperty.Value
        } else { $script:Settings }
        Show-PreviewWindow -Bitmap $bitmap -DisplayTopology $displayTopology `
            -Settings $previewSettings `
            -OnOwnershipAccepted $accept `
            -OnSurfaceReady $surfaceReady `
            -OnNewSnip $newSnip `
            -OnOutputStarting $outputStarting `
            -OnOutputCompleted $outputCompleted
    }.GetNewClosure()

    $startDelay = {
        param($delay,$callback,$request,$coordinator)
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = [math]::Max(1, [int][math]::Ceiling($delay.TotalMilliseconds))
        $timer.Add_Tick({
            $timer.Stop()
            # The timer continuation re-enters the one public request API;
            # Request-SnipCapture owns cancellation and disposal of this timer.
            & $callback
        }.GetNewClosure())
        $timer.Start()
        $timer
    }.GetNewClosure()

    $cancelDelay = {
        param($timer)
        try { $timer.Stop() } finally { $timer.Dispose() }
    }

    [pscustomobject]@{
        SmartCapture = $smartCapture
        FullCapture = $fullCapture
        WindowCapture = $windowCapture
        DisplayCapture = $displayCapture
        Preview = $preview
        StartDelay = $startDelay
        CancelDelay = $cancelDelay
    }
}

function Invoke-SmartCapture {
    Request-SnipCapture -Coordinator $script:CaptureCoordinator `
        -Mode Smart -Source Legacy | Out-Null
}

function Invoke-FullScreenCapture {
    Request-SnipCapture -Coordinator $script:CaptureCoordinator `
        -Mode Full -Source Legacy | Out-Null
}

function Invoke-WindowCapture {
    Request-SnipCapture -Coordinator $script:CaptureCoordinator `
        -Mode Window -Source Legacy | Out-Null
}

function Start-DelayedCapture {
    [CmdletBinding()]
    param([int]$Seconds, [ValidateSet('smart','full','window')] [string]$Type)
    $plural = if ($Seconds -ne 1) { 's' } else { '' }
    try {
        $script:tray.BalloonTipTitle = 'SnipIT'
        $script:tray.BalloonTipText  = "Capturing ($Type) in $Seconds second$plural..."
        $script:tray.ShowBalloonTip(1500)
    } catch {}
    Request-SnipCapture -Coordinator $script:CaptureCoordinator `
        -Mode $Type -Delay ([timespan]::FromSeconds($Seconds)) -Source TrayDelay | Out-Null
}

$script:CurrentPreviewWindow = $null

function New-SnipPreviewContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Drawing.Bitmap]$Bitmap,
        [System.Windows.Media.Imaging.BitmapSource]$BitmapSource,
        $CaptureBounds,
        [object[]]$MonitorDescriptors,
        $DisplayTopology,
        $Settings = $script:Settings,
        [scriptblock]$RegisterWindow = { param($hwnd) Register-SelfWindowHandle -Hwnd $hwnd },
        [scriptblock]$UnregisterWindow = { param($hwnd) Unregister-SelfWindowHandle -Hwnd $hwnd },
        # Only consulted for captures that span most of several monitors, where
        # "the monitor the capture is on" has no answer and the pointer's
        # display is the best stand-in for where the user is looking.
        [scriptblock]$GetPointerPosition = { Get-SnipPhysicalCursorPosition },
        [scriptblock]$SetWindowPosition = {
            param($hwnd, $bounds)
            [Native]::SetWindowPos(
                $hwnd, [IntPtr]::Zero,
                [int]$bounds.X, [int]$bounds.Y,
                [int]$bounds.Width, [int]$bounds.Height,
                [Native]::SWP_NOZORDER -bor [Native]::SWP_NOACTIVATE)
        }
    )

    if ($null -ne $DisplayTopology) {
        $MonitorDescriptors = @($DisplayTopology.Descriptors)
    } elseif ($null -eq $MonitorDescriptors -or $MonitorDescriptors.Count -eq 0) {
        $MonitorDescriptors = @(Get-SnipMonitorDescriptors)
    }
    if ($null -eq $BitmapSource) {
        $BitmapSource = Convert-BitmapToBitmapSource $Bitmap
    }
    if (-not $BitmapSource.IsFrozen -and $BitmapSource.CanFreeze) {
        $BitmapSource.Freeze()
    }
    if ($null -eq $CaptureBounds) {
        $tag = $Bitmap.Tag
        if ($null -ne $tag -and
            $null -ne $tag.PSObject.Properties['X'] -and
            $null -ne $tag.PSObject.Properties['Y'] -and
            $null -ne $tag.PSObject.Properties['Width'] -and
            $null -ne $tag.PSObject.Properties['Height']) {
            $CaptureBounds = $tag
        } elseif ($MonitorDescriptors.Count -gt 0) {
            $fallback = @($MonitorDescriptors | Where-Object IsPrimary | Select-Object -First 1)
            if ($fallback.Count -eq 0) { $fallback = @($MonitorDescriptors[0]) }
            $CaptureBounds = [pscustomobject]@{
                X = [double]$fallback[0].X
                Y = [double]$fallback[0].Y
                Width = [double]$fallback[0].Width
                Height = [double]$fallback[0].Height
            }
        } else {
            $CaptureBounds = [pscustomobject]@{ X=0; Y=0; Width=$Bitmap.Width; Height=$Bitmap.Height }
        }
    }

    $topology = if ($null -ne $DisplayTopology) {
        $DisplayTopology
    } else {
        New-SnipDisplayTopology -MonitorDescriptors $MonitorDescriptors
    }
    # A pointer we cannot read is not a failure — placement falls back to the
    # primary monitor on its own — so never let it take the capture down.
    $pointerPosition = $null
    try {
        $pointerOutput = @(& $GetPointerPosition)
        if ($pointerOutput.Count) { $pointerPosition = $pointerOutput[-1] }
    } catch {
        $pointerPosition = $null
    }
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds $CaptureBounds -Topology $topology `
        -PointerPhysicalPosition $pointerPosition
    $presentationState = New-SnipPresentationState `
        -ViewportWidth $placement.InitialBounds.Width `
        -ViewportHeight $placement.InitialBounds.Height `
        -CaptureBounds $CaptureBounds
    $topologyResult = Invoke-SnipPresentationIntent `
        -State $presentationState `
        -Intent ([pscustomobject]@{
            Type = 'UpdateDisplayTopology'
            DisplayTopology = $topology
        })
    $presentationState = $topologyResult.State
    $placementEffect = @($topologyResult.Effects |
        Where-Object Name -eq 'ApplyPlacement' | Select-Object -First 1)[0]

    [pscustomobject][ordered]@{
        Bitmap = $Bitmap
        BitmapSource = $BitmapSource
        Annotations = [System.Collections.ArrayList]::new()
        SelectedAnnotationId = $null
        CropRectangle = $null
        Draft = $null
        Interaction = $null
        AnnotationDraftClearCount = 0
        UndoStack = [System.Collections.Stack]::new()
        RedoStack = [System.Collections.Stack]::new()
        PresentationState = $presentationState
        ActiveTool = 'Select'
        # Per-tool property-row state. Width/Opacity/Fill back the contextual row's
        # editors so the row reports a real value instead of a bare caption.
        ToolProperties = [ordered]@{
            Select = [pscustomobject]@{ Width=3.0; Opacity=1.0; Fill=$false }
            Crop = [pscustomobject]@{ Preset='Free'; Width=3.0; Opacity=1.0; Fill=$false }
            Pen = [pscustomobject]@{ Width=3.0; Opacity=1.0; Fill=$false }
            Highlight = [pscustomobject]@{ Width=1.5; Opacity=0.43; Fill=$true }
            ArrowLine = [pscustomobject]@{ Width=4.0; Opacity=1.0; Fill=$false }
            RectangleEllipse = [pscustomobject]@{ Width=3.0; Opacity=1.0; Fill=$false }
            Text = [pscustomobject]@{ Width=3.0; Opacity=1.0; Fill=$false }
            Steps = [pscustomobject]@{ Width=3.0; Opacity=1.0; Fill=$false }
            # Width doubles as the obscure strength: Get-SnipObscureMetrics turns
            # it into a mosaic block size and a blur radius.
            BlurPixelate = [pscustomobject]@{ Width=3.0; Opacity=1.0; Fill=$false }
        }
        # Mirrors the editor's active annotation colour so the property row's
        # swatch can paint it without reaching into Show-PreviewWindow locals.
        ActiveColor = 'Yellow'
        ActiveColorHex = '#FFFFDE00'
        CaptureBounds = $CaptureBounds
        CaptureMonitor = $placement.CaptureMonitor
        InitialBounds = $placement.InitialBounds
        InitialPhysicalBounds = $placement.InitialPhysicalBounds
        Settings = $Settings
        RegisterWindow = $RegisterWindow
        UnregisterWindow = $UnregisterWindow
        SetWindowPosition = $SetWindowPosition
        GetKeyboardModifiers = { [System.Windows.Input.Keyboard]::Modifiers }
        ClipboardSetter = { param($image) [System.Windows.Clipboard]::SetImage($image) }
        SaveBitmap = { param($image) Save-CaptureToFile -Bitmap $image -Settings $Settings }.GetNewClosure()
        RetryDelay = { param($milliseconds) [System.Threading.Thread]::Sleep($milliseconds) }
        PlacementState = [pscustomobject]@{
            HandlersAttached=$false
            IsApplied=$false
            Effect=$placementEffect
        }
        Window = $null
        Chrome = $null
        Shell = $null
        EditorState = $null
        PropertyControls = [ordered]@{}
        PropertyBindings = [System.Collections.ArrayList]::new()
        CropAspectMenuControl = $null
        PropertyModeMenuControl = $null
        SelectCropPreset = $null
        ApplySplitSubtype = $null
        PlaceStep = $null
        ApplyCrop = $null
        ResetCrop = $null
        CancelDraft = $null
        DeleteSelection = $null
        DuplicateSelection = $null
        LastHitRoute = $null
        EditingProperty = $false
        ApplySelectionProperty = $null
        ModeState = [pscustomobject]@{ Value = 'Wide' }
        ActivePropertyTool = 'Select'
        RecentTools = [System.Collections.ArrayList]@('Highlight','ArrowLine')
        ToolMetadata = [ordered]@{
            Select=[pscustomobject]@{ Icon='↖'; DisplayName='Select' }
            Crop=[pscustomobject]@{ Icon='⌗'; DisplayName='Crop' }
            Pen=[pscustomobject]@{ Icon='✎'; DisplayName='Pen' }
            Highlight=[pscustomobject]@{ Icon='▰'; DisplayName='Highlight' }
            ArrowLine=[pscustomobject]@{ Icon='↗'; DisplayName='Arrow/Line' }
            RectangleEllipse=[pscustomobject]@{ Icon='□'; DisplayName='Rectangle/Ellipse' }
            Text=[pscustomobject]@{ Icon='T'; DisplayName='Text' }
            Steps=[pscustomobject]@{ Icon='①'; DisplayName='Steps' }
            BlurPixelate=[pscustomobject]@{ Icon='▒'; DisplayName='Blur/Pixelate' }
            Color=[pscustomobject]@{ Icon='●'; DisplayName='Color' }
        }
        ToolControls = [ordered]@{}
        ToolOrder = [System.Collections.ArrayList]::new()
        MoreState = [pscustomobject]@{
            IsActive=$false; Tool=$null; Name='More'; Icon='…'
        }
        StatusState = [pscustomobject]@{ Kind='Idle'; Text='' }
        SetStatus = $null
        ClearStatus = $null
        ApplyResponsivePresentation = $null
        ApplyPropertyPresentation = $null
        PropertyState = [pscustomobject]@{
            Tool='Select'; Visible=[string[]]@(); Overflow=[string[]]@()
            HorizontalScrollBarVisibility=[System.Windows.Controls.ScrollBarVisibility]::Disabled
        }
        SplitControls = [ordered]@{}
        TransientMenus = [System.Collections.ArrayList]::new()
        PropertyMenuControl = $null
        AnnotationMenuControl = $null
        CommandRouter = $null
        RoutePreviewKeyDown = $null
        PopupRouteMenu = $null
    }
}

function Set-SnipPreviewMenuStyle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.ContextMenu]$Menu,
        [Parameter(Mandatory)] $Context
    )

    $pending = [System.Collections.Generic.Queue[System.Windows.Controls.MenuItem]]::new()
    $menuItems = [System.Collections.ArrayList]::new()
    foreach ($rootItem in @($Menu.Items)) {
        if ($rootItem -is [System.Windows.Controls.MenuItem]) {
            $pending.Enqueue($rootItem)
        }
    }
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $menuItems.Add($item) | Out-Null
        foreach ($childItem in @($item.Items)) {
            if ($childItem -is [System.Windows.Controls.MenuItem]) {
                $pending.Enqueue($childItem)
            }
        }
    }

    $existingLifecycle = $Menu.Tag
    if ($null -ne $existingLifecycle -and
        $null -ne $existingLifecycle.PSObject.Properties['Kind'] -and
        $existingLifecycle.Kind -eq 'SnipPreviewMenuLifecycle' -and
        $existingLifecycle.HandlersAttached) {
        return $Menu
    }

    $nestedStates = [System.Collections.ArrayList]::new()
    $lifecycle = [pscustomobject][ordered]@{
        Kind = 'SnipPreviewMenuLifecycle'
        Menu = $Menu
        NestedStates = $nestedStates
        CloseNestedPopups = $null
        Disconnect = $null
        WindowClosedHandler = $null
        PopupKeyRouteHandler = $null
        PopupKeyRouteAttached = $false
        PopupKeyRouteAttachCount = 0
        PopupKeyRouteInvocationCount = 0
        LastPopupKeyOrigin = $null
        LastPopupRouteCommand = $null
        LastPopupRouteHandled = $false
        HandlersAttached = $true
    }
    $popupKeyRouteHandler = [System.Windows.Input.KeyEventHandler]({
        param($sender,$eventArgs)
        $lifecycle.PopupKeyRouteInvocationCount++
        $lifecycle.LastPopupKeyOrigin = $eventArgs.OriginalSource
        $previousRouteMenu = $Context.PopupRouteMenu
        $Context.PopupRouteMenu = $Menu
        try {
            if ($null -ne $Context.RoutePreviewKeyDown) {
                & $Context.RoutePreviewKeyDown $eventArgs
            }
            $lifecycle.LastPopupRouteCommand = if ($null -ne $Context.CommandRouter) {
                $Context.CommandRouter.LastCommand
            } else { $null }
        } finally {
            $lifecycle.LastPopupRouteHandled = [bool]$eventArgs.Handled
            $Context.PopupRouteMenu = $previousRouteMenu
        }
    }.GetNewClosure())
    $lifecycle.PopupKeyRouteHandler = $popupKeyRouteHandler
    $Menu.AddHandler(
        [System.Windows.Input.Keyboard]::PreviewKeyDownEvent,
        $popupKeyRouteHandler,
        $true)
    $lifecycle.PopupKeyRouteAttached = $true
    $lifecycle.PopupKeyRouteAttachCount++
    $unregisterNested = {
        param($NestedState)
        if ($NestedState.IsRegistered -and $NestedState.Handle -ne [IntPtr]::Zero) {
            & $Context.UnregisterWindow $NestedState.Handle
        }
        $NestedState.Handle = [IntPtr]::Zero
        $NestedState.IsRegistered = $false
    }.GetNewClosure()
    # A MenuItem's ControlTemplate is re-resolved when the menu is opened (a themed
    # window and the ContextMenu's own popup tree resolve different templates), which
    # replaces PART_Popup and would strand the lifecycle handlers on a dead Popup.
    # Rebind the state to whichever Popup the live template currently carries.
    $bindNestedPopup = {
        param($NestedState)
        $livePopup = $NestedState.Item.Template.FindName('PART_Popup',$NestedState.Item)
        if ($livePopup -isnot [System.Windows.Controls.Primitives.Popup]) { return }
        if ([object]::ReferenceEquals($livePopup,$NestedState.Popup)) { return }
        if ($null -ne $NestedState.Popup -and $NestedState.HandlersAttached) {
            $NestedState.Popup.Remove_Opened($NestedState.OpenedHandler)
            $NestedState.Popup.Remove_Closed($NestedState.ClosedHandler)
        }
        # The outgoing Popup can never raise Closed for us again, so release its HWND
        # here. Without this, a swap that lands while the old Popup is registered would
        # leave IsRegistered true and the catch-up below would skip the new HWND.
        if ($null -ne $NestedState.Popup) { & $unregisterNested $NestedState }
        # Honour the OS "show animations" preference rather than a theme token.
        $livePopup.PopupAnimation =
            if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
                [System.Windows.Controls.Primitives.PopupAnimation]::Fade
            } else {
                [System.Windows.Controls.Primitives.PopupAnimation]::None
            }
        $livePopup.Tag = $NestedState
        $NestedState.Popup = $livePopup
        if ($NestedState.HandlersAttached) {
            $livePopup.Add_Opened($NestedState.OpenedHandler)
            $livePopup.Add_Closed($NestedState.ClosedHandler)
            # A swap can land after the replacement Popup already opened, so the
            # Opened event is gone; register the live HWND directly instead.
            if ($livePopup.IsOpen) { & $NestedState.OpenedHandler }
        }
    }.GetNewClosure()
    foreach ($menuItem in @($menuItems)) {
        $menuItem.ApplyTemplate() | Out-Null
        $popup = $menuItem.Template.FindName('PART_Popup',$menuItem)
        if ($popup -isnot [System.Windows.Controls.Primitives.Popup]) { continue }
        $nestedState = [pscustomobject][ordered]@{
            Item = $menuItem
            Popup = $null
            Handle = [IntPtr]::Zero
            IsRegistered = $false
            OpenedHandler = $null
            ClosedHandler = $null
            ItemLoadedHandler = $null
            HandlersAttached = $true
        }
        $stateForHandler = $nestedState
        $openedHandler = {
            $livePopup = $stateForHandler.Popup
            $source = if ($null -ne $livePopup -and $null -ne $livePopup.Child) {
                [System.Windows.PresentationSource]::FromVisual($livePopup.Child)
            } else { $null }
            if ($source -is [System.Windows.Interop.HwndSource] -and
                $source.Handle -ne [IntPtr]::Zero -and
                -not $stateForHandler.IsRegistered) {
                & $Context.RegisterWindow $source.Handle
                $stateForHandler.Handle = $source.Handle
                $stateForHandler.IsRegistered = $true
            }
        }.GetNewClosure()
        $closedHandler = {
            & $unregisterNested $stateForHandler
        }.GetNewClosure()
        $nestedState.OpenedHandler = $openedHandler
        $nestedState.ClosedHandler = $closedHandler
        & $bindNestedPopup $nestedState
        # Opening the menu reloads its items; that is where the template swap lands.
        $itemLoadedHandler = [System.Windows.RoutedEventHandler]{
            param($sender,$eventArgs)
            & $bindNestedPopup $stateForHandler
        }.GetNewClosure()
        $nestedState.ItemLoadedHandler = $itemLoadedHandler
        $menuItem.Add_Loaded($itemLoadedHandler)
        $nestedStates.Add($nestedState) | Out-Null
    }
    $closeNestedPopups = {
        for ($index = $nestedStates.Count - 1; $index -ge 0; $index--) {
            $nestedState = $nestedStates[$index]
            if ($nestedState.Item.IsSubmenuOpen) {
                $nestedState.Item.IsSubmenuOpen = $false
            }
            & $unregisterNested $nestedState
        }
    }.GetNewClosure()
    $disconnect = {
        & $closeNestedPopups
        if ($lifecycle.PopupKeyRouteAttached) {
            $Menu.RemoveHandler(
                [System.Windows.Input.Keyboard]::PreviewKeyDownEvent,
                $lifecycle.PopupKeyRouteHandler)
            $lifecycle.PopupKeyRouteAttached = $false
        }
        foreach ($nestedState in @($nestedStates)) {
            if (-not $nestedState.HandlersAttached) { continue }
            if ($null -ne $nestedState.ItemLoadedHandler) {
                $nestedState.Item.Remove_Loaded($nestedState.ItemLoadedHandler)
            }
            if ($null -ne $nestedState.Popup) {
                $nestedState.Popup.Remove_Opened($nestedState.OpenedHandler)
                $nestedState.Popup.Remove_Closed($nestedState.ClosedHandler)
            }
            $nestedState.HandlersAttached = $false
        }
        if ($null -ne $Context.Window -and
            $null -ne $lifecycle.WindowClosedHandler) {
            $Context.Window.Remove_Closed($lifecycle.WindowClosedHandler)
        }
        $lifecycle.HandlersAttached = $false
    }.GetNewClosure()
    $lifecycle.CloseNestedPopups = $closeNestedPopups
    $lifecycle.Disconnect = $disconnect
    if ($null -ne $Context.Window) {
        $windowClosedHandler = { & $lifecycle.Disconnect }.GetNewClosure()
        $lifecycle.WindowClosedHandler = $windowClosedHandler
        $Context.Window.Add_Closed($windowClosedHandler)
    }
    $Menu.Tag = $lifecycle
    $Menu
}

function Connect-SnipPreviewMenuButton {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.Button]$Button,
        [Parameter(Mandatory)] [System.Windows.Controls.ContextMenu]$Menu,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Name
    )

    Set-SnipPreviewMenuStyle -Menu $Menu -Context $Context | Out-Null
    $Menu.PlacementTarget = $Button
    $Button.ContextMenu = $Menu
    [System.Windows.Automation.AutomationProperties]::SetItemStatus($Button, 'Collapsed')
    $state = [pscustomobject]@{
        IsExpanded=$false; MenuHandle=[IntPtr]::Zero; IsMenuWindowRegistered=$false
        HandlersAttached=$false
    }
    $open = {
        $Menu.PlacementTarget = $Button
        $Menu.IsOpen = $true
    }.GetNewClosure()
    $close = {
        if ($null -ne $Menu.Tag -and $null -ne $Menu.Tag.CloseNestedPopups) {
            & $Menu.Tag.CloseNestedPopups
        }
        if ($Menu.IsOpen) { $Menu.IsOpen = $false }
        if ($state.IsMenuWindowRegistered -and $state.MenuHandle -ne [IntPtr]::Zero) {
            & $Context.UnregisterWindow $state.MenuHandle
        }
        $state.IsExpanded = $false
        $state.MenuHandle = [IntPtr]::Zero
        $state.IsMenuWindowRegistered = $false
        [System.Windows.Automation.AutomationProperties]::SetItemStatus($Button, 'Collapsed')
        try { $Button.Focus() | Out-Null } catch {}
    }.GetNewClosure()
    $openedHandler = {
        $state.IsExpanded = $true
        [System.Windows.Automation.AutomationProperties]::SetItemStatus($Button, 'Expanded')
        $source = [System.Windows.PresentationSource]::FromVisual($Menu)
        if ($source -is [System.Windows.Interop.HwndSource] -and
            $source.Handle -ne [IntPtr]::Zero -and -not $state.IsMenuWindowRegistered) {
            & $Context.RegisterWindow $source.Handle
            $state.MenuHandle = $source.Handle
            $state.IsMenuWindowRegistered = $true
        }
    }.GetNewClosure()
    $closedHandler = { & $close }.GetNewClosure()
    $buttonClickHandler = { & $open }.GetNewClosure()
    $disconnect = $null
    $windowClosedHandler = $null
    $disconnect = {
        & $close
        if ($state.HandlersAttached) {
            $Menu.Remove_Opened($openedHandler)
            $Menu.Remove_Closed($closedHandler)
            $Button.Remove_Click($buttonClickHandler)
            if ($null -ne $Context.Window -and $null -ne $windowClosedHandler) {
                $Context.Window.Remove_Closed($windowClosedHandler)
            }
            $state.HandlersAttached = $false
        }
        if ($null -ne $Menu.Tag -and $null -ne $Menu.Tag.Disconnect) {
            & $Menu.Tag.Disconnect
        }
    }.GetNewClosure()
    $windowClosedHandler = { & $disconnect }.GetNewClosure()
    $Menu.Add_Opened($openedHandler)
    $Menu.Add_Closed($closedHandler)
    $Button.Add_Click($buttonClickHandler)
    if ($null -ne $Context.Window) { $Context.Window.Add_Closed($windowClosedHandler) }
    $state.HandlersAttached = $true
    $control = [pscustomobject]@{
        Name=$Name; State=$state; Menu=$Menu; Button=$Button
        OpenOptions=$open; CloseOptions=$close; Disconnect=$disconnect
    }
    $Context.TransientMenus.Add($control) | Out-Null
    $control
}

function Connect-SnipPreviewTransientContextMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.ContextMenu]$Menu,
        [Parameter(Mandatory)] [System.Windows.FrameworkElement]$PlacementTarget,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Name,
        [scriptblock]$Cleanup = {}
    )

    Set-SnipPreviewMenuStyle -Menu $Menu -Context $Context | Out-Null
    $Menu.PlacementTarget = $PlacementTarget
    $state = [pscustomobject][ordered]@{
        IsExpanded = $false
        MenuHandle = [IntPtr]::Zero
        IsMenuWindowRegistered = $false
        HandlersAttached = $false
        CleanupRan = $false
    }
    $open = {
        $Menu.PlacementTarget = $PlacementTarget
        $Menu.IsOpen = $true
    }.GetNewClosure()
    $close = {
        if ($null -ne $Menu.Tag -and $null -ne $Menu.Tag.CloseNestedPopups) {
            & $Menu.Tag.CloseNestedPopups
        }
        if ($Menu.IsOpen) { $Menu.IsOpen = $false }
        if ($state.IsMenuWindowRegistered -and $state.MenuHandle -ne [IntPtr]::Zero) {
            & $Context.UnregisterWindow $state.MenuHandle
        }
        $state.IsExpanded = $false
        $state.MenuHandle = [IntPtr]::Zero
        $state.IsMenuWindowRegistered = $false
        try { $PlacementTarget.Focus() | Out-Null } catch {}
    }.GetNewClosure()
    $registerMenuWindow = {
        if (-not $Menu.IsOpen) { return }
        $source = [System.Windows.PresentationSource]::FromVisual($Menu)
        if ($source -is [System.Windows.Interop.HwndSource] -and
            $source.Handle -ne [IntPtr]::Zero -and
            -not $state.IsMenuWindowRegistered) {
            & $Context.RegisterWindow $source.Handle
            $state.MenuHandle = $source.Handle
            $state.IsMenuWindowRegistered = $true
        }
    }.GetNewClosure()
    $openedHandler = {
        $state.IsExpanded = $true
        & $registerMenuWindow
        if (-not $state.IsMenuWindowRegistered) {
            $retryRegistration = [Action]{ & $registerMenuWindow }.GetNewClosure()
            [void]$Menu.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Render,
                $retryRegistration)
        }
    }.GetNewClosure()
    $closedHandler = { & $close }.GetNewClosure()
    $disconnect = $null
    $windowClosedHandler = $null
    $disconnect = {
        & $close
        if ($state.HandlersAttached) {
            $Menu.Remove_Opened($openedHandler)
            $Menu.Remove_Closed($closedHandler)
            if ($null -ne $Context.Window -and $null -ne $windowClosedHandler) {
                $Context.Window.Remove_Closed($windowClosedHandler)
            }
            $state.HandlersAttached = $false
        }
        if ($null -ne $Menu.Tag -and $null -ne $Menu.Tag.Disconnect) {
            & $Menu.Tag.Disconnect
        }
        if (-not $state.CleanupRan) {
            & $Cleanup
            $state.CleanupRan = $true
        }
    }.GetNewClosure()
    $windowClosedHandler = { & $disconnect }.GetNewClosure()
    $Menu.Add_Opened($openedHandler)
    $Menu.Add_Closed($closedHandler)
    if ($null -ne $Context.Window) { $Context.Window.Add_Closed($windowClosedHandler) }
    $state.HandlersAttached = $true
    $control = [pscustomobject][ordered]@{
        Name = $Name
        State = $state
        Menu = $Menu
        PlacementTarget = $PlacementTarget
        OpenOptions = $open
        CloseOptions = $close
        Disconnect = $disconnect
    }
    $Context.TransientMenus.Add($control) | Out-Null
    $control
}

function Set-SnipPropertyIsland {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)]
        [ValidateSet('Select','Crop','Pen','Highlight','ArrowLine','RectangleEllipse','Text','Steps','BlurPixelate')]
        [string]$Tool
    )

    $definitions = [ordered]@{
        Select = @('Position','Size')
        Crop = @('Aspect','Apply','Reset')
        Pen = @('Color','Width','Opacity')
        Highlight = @('Color','Width','Opacity')
        ArrowLine = @('Color','Width','Opacity','StartStyle','EndStyle')
        RectangleEllipse = @('StrokeColor','Fill','Width','Opacity')
        Text = @('Color','FontSize','Weight','Background')
        Steps = @('Color','Size')
        BlurPixelate = @('Strength','Mode')
    }
    $Context.ActivePropertyTool = $Tool
    foreach ($binding in @($Context.PropertyBindings)) {
        $bindingEvent = if ($null -ne $binding.PSObject.Properties['Event']) {
            [string]$binding.Event
        } else { 'Click' }
        switch ($bindingEvent) {
            'GotKeyboardFocus' { $binding.Target.Remove_GotKeyboardFocus($binding.Handler) }
            'LostKeyboardFocus' { $binding.Target.Remove_LostKeyboardFocus($binding.Handler) }
            'KeyDown' { $binding.Target.Remove_KeyDown($binding.Handler) }
            default { $binding.Target.Remove_Click($binding.Handler) }
        }
    }
    $Context.PropertyBindings.Clear()
    foreach ($controlName in @(
        'PropertyMenuControl','CropAspectMenuControl','PropertyModeMenuControl')) {
        $control = $Context.$controlName
        if ($null -eq $control) { continue }
        if ($null -ne $control.Disconnect) { & $control.Disconnect }
        try { & $control.CloseOptions } catch {}
        [void]$Context.TransientMenus.Remove($control)
        $Context.$controlName = $null
    }
    $Context.PropertyControls.Clear()
    $hasSelection = $null -ne $Context.SelectedAnnotationId
    if ($Tool -eq 'Select' -and -not $hasSelection) {
        $Context.PropertyState.Tool = 'Select'
        $Context.PropertyState.Visible = [string[]]@()
        $Context.PropertyState.Overflow = [string[]]@()
        if ($null -ne $Context.Shell -and $null -ne $Context.Shell.PropertyIsland) {
            $Context.Shell.PropertyPanel.Children.Clear()
            $Context.Shell.PropertyIsland.Visibility = [System.Windows.Visibility]::Collapsed
        }
        return $Context.PropertyState
    }
    if ($null -ne $Context.Shell -and $null -ne $Context.Shell.PropertyIsland) {
        $Context.Shell.PropertyIsland.Visibility = [System.Windows.Visibility]::Visible
    }
    $mode = [string]$Context.ModeState.Value
    $all = [string[]]@($definitions[$Tool])
    [string[]]$visible = $all
    [string[]]$overflow = @()
    $Context.PropertyState.Tool = $Tool
    $Context.PropertyState.Visible = $visible
    $Context.PropertyState.Overflow = $overflow
    $panel = $Context.Shell.PropertyPanel
    if ($null -ne $panel) {
        $panel.Children.Clear()
        $toolState = $Context.ToolProperties[$Tool]
        # Tool badge: the row says what it is editing before it says what it edits.
        $toolBadge = [System.Windows.Controls.TextBlock]::new()
        $toolBadge.Text = if ($null -ne $Context.ToolMetadata[$Tool]) {
            [string]$Context.ToolMetadata[$Tool].DisplayName
        } else { $Tool }
        $toolBadge.FontWeight = [System.Windows.FontWeights]::SemiBold
        $toolBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $toolBadge.Margin = [System.Windows.Thickness]::new(6,0,12,0)
        $toolBadge.SetResourceReference(
            [System.Windows.Controls.TextBlock]::ForegroundProperty,
            'AccentTextFillColorPrimaryBrush')
        [System.Windows.Automation.AutomationProperties]::SetName(
            $toolBadge, "$($toolBadge.Text) properties")
        $panel.Children.Add($toolBadge) | Out-Null
        $newPropertyCaption = {
            param([string]$Text)
            $caption = [System.Windows.Controls.TextBlock]::new()
            $caption.Text = $Text
            $caption.Opacity = 0.8
            $caption.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $caption.Margin = [System.Windows.Thickness]::new(0,0,6,0)
            $caption
        }
        foreach ($propertyName in $visible) {
            if ($Tool -eq 'Select' -and $propertyName -in @('Position','Size')) {
                $selectedRecords = @($Context.Annotations | Where-Object {
                    [string]$_.Id -eq [string]$Context.SelectedAnnotationId
                } | Select-Object -First 1)
                $selectedRecord = if($selectedRecords.Count -gt 0){
                    $selectedRecords[0]
                }else{$null}
                $geometry = if ($null -ne $selectedRecord) {
                    $sourceGeometry=$selectedRecord.Geometry
                    if($sourceGeometry.Type -in @('Bounds','TextBounds','StepBounds')){
                        $sourceGeometry
                    }elseif($sourceGeometry.Type -eq 'Line'){
                        [pscustomobject]@{
                            X=[math]::Min($sourceGeometry.Start.X,$sourceGeometry.End.X)
                            Y=[math]::Min($sourceGeometry.Start.Y,$sourceGeometry.End.Y)
                            Width=[math]::Max(1,[math]::Abs($sourceGeometry.End.X-$sourceGeometry.Start.X))
                            Height=[math]::Max(1,[math]::Abs($sourceGeometry.End.Y-$sourceGeometry.Start.Y))
                        }
                    }elseif($sourceGeometry.Type -eq 'Points' -and @($sourceGeometry.Points).Count -gt 0){
                        $xs=@($sourceGeometry.Points|ForEach-Object X)
                        $ys=@($sourceGeometry.Points|ForEach-Object Y)
                        $minimumX=($xs|Measure-Object -Minimum).Minimum
                        $minimumY=($ys|Measure-Object -Minimum).Minimum
                        [pscustomobject]@{
                            X=$minimumX;Y=$minimumY
                            Width=[math]::Max(1,($xs|Measure-Object -Maximum).Maximum-$minimumX)
                            Height=[math]::Max(1,($ys|Measure-Object -Maximum).Maximum-$minimumY)
                        }
                    }else{$null}
                } else { $null }
                $editor = [System.Windows.Controls.TextBox]::new()
                $editor.Height=36; $editor.MinWidth=96
                $editor.Margin=[System.Windows.Thickness]::new(2,0,2,0)
                $editor.Padding=[System.Windows.Thickness]::new(8,6,8,4)
                $editor.Text = if ($null -eq $geometry) { '' } elseif ($propertyName -eq 'Position') {
                    "$([int]$geometry.X), $([int]$geometry.Y)"
                } else { "$([int]$geometry.Width) × $([int]$geometry.Height)" }
                $editor.Tag=[pscustomobject]@{
                    Role='PropertyEditor';Name=$propertyName;OriginalText=$editor.Text
                }
                [System.Windows.Automation.AutomationProperties]::SetName(
                    $editor,"Selected annotation $propertyName")
                $commitProperty={
                    if($Context.ApplySelectionProperty){
                        & $Context.ApplySelectionProperty $propertyName $editor.Text
                    }
                    $Context.EditingProperty=$false
                    $editor.Tag.OriginalText=$editor.Text
                }.GetNewClosure()
                $focusHandler={
                    $Context.EditingProperty=$true
                    $editor.Tag.OriginalText=$editor.Text
                }.GetNewClosure()
                $lostFocusHandler={
                    if($Context.EditingProperty){& $commitProperty}
                }.GetNewClosure()
                $editorKeyHandler={
                    if($_.Key -eq [System.Windows.Input.Key]::Enter){
                        & $commitProperty; $_.Handled=$true
                    }elseif($_.Key -eq [System.Windows.Input.Key]::Escape){
                        $editor.Text=[string]$editor.Tag.OriginalText
                        $Context.EditingProperty=$false
                        $_.Handled=$true
                    }
                }.GetNewClosure()
                $editor.Add_GotKeyboardFocus($focusHandler)
                $editor.Add_LostKeyboardFocus($lostFocusHandler)
                $editor.Add_KeyDown($editorKeyHandler)
                foreach($bindingSpec in @(
                    [pscustomobject]@{Event='GotKeyboardFocus';Handler=$focusHandler},
                    [pscustomobject]@{Event='LostKeyboardFocus';Handler=$lostFocusHandler},
                    [pscustomobject]@{Event='KeyDown';Handler=$editorKeyHandler})){
                    $Context.PropertyBindings.Add([pscustomobject]@{
                        Target=$editor;Event=$bindingSpec.Event;Handler=$bindingSpec.Handler
                    })|Out-Null
                }
                $Context.PropertyControls[$propertyName]=[pscustomobject][ordered]@{
                    Name=$propertyName;Element=$editor;Button=$null
                    Menu=$null;MenuItems=$null;Controller=$null;Swatch=$null
                }
                $panel.Children.Add($editor)|Out-Null
                continue
            }
            if ($propertyName -in @('Color','StrokeColor')) {
                # Swatch button: reports the live annotation colour, not just a caption.
                $swatchButton = [System.Windows.Controls.Button]::new()
                $swatchContent = [System.Windows.Controls.StackPanel]::new()
                $swatchContent.Orientation = [System.Windows.Controls.Orientation]::Horizontal
                $swatch = [System.Windows.Controls.Border]::new()
                $swatch.Width = 16
                $swatch.Height = 16
                $swatch.CornerRadius = [System.Windows.CornerRadius]::new(3)
                $swatch.BorderThickness = [System.Windows.Thickness]::new(1)
                $swatch.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.Color]::FromArgb(102,0,0,0))
                $swatch.Margin = [System.Windows.Thickness]::new(0,0,8,0)
                $swatch.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $swatch.Background = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString(
                        [string]$Context.ActiveColorHex))
                $swatchContent.Children.Add($swatch) | Out-Null
                $swatchCaption = [System.Windows.Controls.TextBlock]::new()
                $swatchCaption.Text = if ($propertyName -eq 'StrokeColor') {
                    'Stroke'
                } else { 'Color' }
                $swatchCaption.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $swatchContent.Children.Add($swatchCaption) | Out-Null
                $swatchButton.Content = $swatchContent
                $swatchButton.Height = 32
                $swatchButton.Margin = [System.Windows.Thickness]::new(2,0,6,0)
                $swatchButton.Padding = [System.Windows.Thickness]::new(9,4,11,5)
                $swatchButton.ToolTip = "Annotation colour: $($Context.ActiveColor)"
                [System.Windows.Automation.AutomationProperties]::SetName(
                    $swatchButton, [string]$swatchCaption.Text)
                $Context.PropertyControls[$propertyName] = [pscustomobject][ordered]@{
                    Name=$propertyName; Element=$swatchButton; Button=$swatchButton
                    Menu=$null; MenuItems=$null; Controller=$null; Swatch=$swatch
                }
                $panel.Children.Add($swatchButton) | Out-Null
                continue
            }
            # Width, the Steps badge Size and the Blur Strength are the same
            # editor over the same per-tool number; only the wording differs.
            if ($propertyName -in @('Width','Size','Strength') -and $null -ne $toolState) {
                $widthPanel = [System.Windows.Controls.StackPanel]::new()
                $widthPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
                $widthPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $widthPanel.Margin = [System.Windows.Thickness]::new(2,0,6,0)
                $widthPanel.Children.Add((& $newPropertyCaption $propertyName)) | Out-Null
                $widthBox = [System.Windows.Controls.TextBox]::new()
                $widthBox.Width = 46
                $widthBox.Height = 32
                $widthBox.TextAlignment = [System.Windows.TextAlignment]::Center
                $widthBox.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
                $widthBox.Text = '{0:0.##}' -f [double]$toolState.Width
                $widthBox.ToolTip = switch ($propertyName) {
                    'Size' { 'Step badge size' }
                    'Strength' { 'Obscure strength; drives blur radius and mosaic block size' }
                    default { 'Stroke width in pixels' }
                }
                [System.Windows.Automation.AutomationProperties]::SetName(
                    $widthBox,$propertyName)
                $widthPanel.Children.Add($widthBox) | Out-Null
                $setWidth = {
                    param([double]$Value)
                    $toolState.Width = [math]::Max(1.0,[math]::Min(48.0,$Value))
                    $widthBox.Text = '{0:0.##}' -f [double]$toolState.Width
                }.GetNewClosure()
                $commitWidth = {
                    $parsed = 0.0
                    if ([double]::TryParse([string]$widthBox.Text,
                            [System.Globalization.NumberStyles]::Float,
                            [System.Globalization.CultureInfo]::CurrentCulture,
                            [ref]$parsed)) {
                        & $setWidth $parsed
                    } else {
                        $widthBox.Text = '{0:0.##}' -f [double]$toolState.Width
                    }
                }.GetNewClosure()
                $widthLostFocus = { & $commitWidth }.GetNewClosure()
                $widthKeyDown = {
                    if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
                        & $commitWidth; $_.Handled = $true
                    } elseif ($_.Key -eq [System.Windows.Input.Key]::Escape) {
                        $widthBox.Text = '{0:0.##}' -f [double]$toolState.Width
                        $_.Handled = $true
                    }
                }.GetNewClosure()
                $widthBox.Add_LostKeyboardFocus($widthLostFocus)
                $widthBox.Add_KeyDown($widthKeyDown)
                foreach ($bindingSpec in @(
                    [pscustomobject]@{Event='LostKeyboardFocus';Handler=$widthLostFocus},
                    [pscustomobject]@{Event='KeyDown';Handler=$widthKeyDown})) {
                    $Context.PropertyBindings.Add([pscustomobject]@{
                        Target=$widthBox;Event=$bindingSpec.Event;Handler=$bindingSpec.Handler
                    }) | Out-Null
                }
                $widthStepper = [System.Windows.Controls.StackPanel]::new()
                $widthStepper.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $widthStepper.Margin = [System.Windows.Thickness]::new(2,0,0,0)
                foreach ($stepSpec in @(
                    [pscustomobject]@{ Glyph=[char]0x25B4; Delta=1.0
                        Label="Increase $($propertyName.ToLowerInvariant())" },
                    [pscustomobject]@{ Glyph=[char]0x25BE; Delta=-1.0
                        Label="Decrease $($propertyName.ToLowerInvariant())" })) {
                    $stepButton = [System.Windows.Controls.Primitives.RepeatButton]::new()
                    $stepGlyph = [System.Windows.Controls.TextBlock]::new()
                    $stepGlyph.Text = [string]$stepSpec.Glyph
                    $stepGlyph.FontSize = 11
                    $stepGlyph.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                    $stepGlyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                    $stepButton.Content = $stepGlyph
                    $stepButton.Padding = [System.Windows.Thickness]::new(0)
                    $stepButton.MinWidth = 26
                    $stepButton.MinHeight = 0
                    $stepButton.Height = 16
                    $stepButton.Focusable = $false
                    [System.Windows.Automation.AutomationProperties]::SetName(
                        $stepButton, [string]$stepSpec.Label)
                    $stepDelta = [double]$stepSpec.Delta
                    $stepHandler = {
                        & $setWidth ([double]$toolState.Width + $stepDelta)
                    }.GetNewClosure()
                    $stepButton.Add_Click($stepHandler)
                    $Context.PropertyBindings.Add([pscustomobject]@{
                        Target=$stepButton; Handler=$stepHandler
                    }) | Out-Null
                    $widthStepper.Children.Add($stepButton) | Out-Null
                }
                $widthPanel.Children.Add($widthStepper) | Out-Null
                $Context.PropertyControls[$propertyName] = [pscustomobject][ordered]@{
                    Name=$propertyName; Element=$widthBox; Button=$null
                    Menu=$null; MenuItems=$null; Controller=$null; Swatch=$null
                }
                $panel.Children.Add($widthPanel) | Out-Null
                continue
            }
            if ($propertyName -eq 'Opacity' -and $null -ne $toolState) {
                $opacityPanel = [System.Windows.Controls.StackPanel]::new()
                $opacityPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
                $opacityPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $opacityPanel.Margin = [System.Windows.Thickness]::new(2,0,6,0)
                $opacityPanel.Children.Add((& $newPropertyCaption 'Opacity')) | Out-Null
                $opacitySlider = [System.Windows.Controls.Slider]::new()
                $opacitySlider.Minimum = 0
                $opacitySlider.Maximum = 100
                $opacitySlider.SmallChange = 1
                $opacitySlider.LargeChange = 10
                $opacitySlider.TickFrequency = 1
                $opacitySlider.IsSnapToTickEnabled = $true
                $opacitySlider.Width = 116
                $opacitySlider.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $opacitySlider.Value = [math]::Round([double]$toolState.Opacity * 100.0)
                [System.Windows.Automation.AutomationProperties]::SetName(
                    $opacitySlider,'Opacity percent')
                $opacityPanel.Children.Add($opacitySlider) | Out-Null
                $opacityValue = [System.Windows.Controls.TextBlock]::new()
                $opacityValue.Width = 42
                $opacityValue.Margin = [System.Windows.Thickness]::new(8,0,0,0)
                $opacityValue.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $opacityValue.Text = '{0:0}%' -f $opacitySlider.Value
                $opacityPanel.Children.Add($opacityValue) | Out-Null
                # Slider exposes no Click to unhook and the whole row is rebuilt from
                # scratch on every tool change, so this handler dies with the control.
                $opacitySlider.Add_ValueChanged({
                    $toolState.Opacity = [double]$opacitySlider.Value / 100.0
                    $opacityValue.Text = '{0:0}%' -f $opacitySlider.Value
                }.GetNewClosure())
                $Context.PropertyControls[$propertyName] = [pscustomobject][ordered]@{
                    Name=$propertyName; Element=$opacitySlider; Button=$null
                    Menu=$null; MenuItems=$null; Controller=$null; Swatch=$null
                }
                $panel.Children.Add($opacityPanel) | Out-Null
                continue
            }
            if ($propertyName -eq 'Fill' -and $null -ne $toolState) {
                $fillToggle = [System.Windows.Controls.Primitives.ToggleButton]::new()
                $fillToggle.Height = 32
                $fillToggle.MinWidth = 76
                $fillToggle.Margin = [System.Windows.Thickness]::new(2,0,6,0)
                $fillToggle.Padding = [System.Windows.Thickness]::new(11,4,11,5)
                $fillToggle.IsChecked = [bool]$toolState.Fill
                $fillToggle.Content = if ($toolState.Fill) { 'Fill  On' } else { 'Fill  Off' }
                $fillToggle.ToolTip = 'Fill the shape as well as stroking it'
                [System.Windows.Automation.AutomationProperties]::SetName($fillToggle,'Fill')
                $fillHandler = {
                    $toolState.Fill = [bool]$fillToggle.IsChecked
                    $fillToggle.Content = if ($toolState.Fill) { 'Fill  On' } else { 'Fill  Off' }
                }.GetNewClosure()
                $fillToggle.Add_Click($fillHandler)
                $Context.PropertyBindings.Add([pscustomobject]@{
                    Target=$fillToggle; Handler=$fillHandler
                }) | Out-Null
                $Context.PropertyControls[$propertyName] = [pscustomobject][ordered]@{
                    Name=$propertyName; Element=$fillToggle; Button=$fillToggle
                    Menu=$null; MenuItems=$null; Controller=$null; Swatch=$null
                }
                $panel.Children.Add($fillToggle) | Out-Null
                continue
            }
            $button = [System.Windows.Controls.Button]::new()
            $button.Height = 36
            $button.MinWidth = if ($mode -eq 'Narrow') { 68 } else { 76 }
            $button.Margin = [System.Windows.Thickness]::new(2,0,2,0)
            $button.Padding = [System.Windows.Thickness]::new(8,4,8,4)
            $obscureMode = if ($null -ne $Context.SplitControls -and
                $null -ne $Context.SplitControls['BlurPixelate']) {
                [string]$Context.SplitControls['BlurPixelate'].DefaultCommand
            } else { 'Blur' }
            $button.Content = switch ($propertyName) {
                'MoreProperties' { 'More properties' }
                'StartStyle' { 'Start' }
                'EndStyle' { 'End' }
                'StrokeColor' { 'Stroke' }
                'ResetSequence' { 'Reset' }
                'Mode' { "Mode  $obscureMode" }
                default { $propertyName }
            }
            [System.Windows.Automation.AutomationProperties]::SetName(
                $button, [string]$button.Content)
            if ($propertyName -eq 'MoreProperties') {
                $propertyMenu = [System.Windows.Controls.ContextMenu]::new()
                foreach ($overflowName in $overflow) {
                    $propertyItem = [System.Windows.Controls.MenuItem]::new()
                    $propertyItem.Header = switch ($overflowName) {
                        'StartStyle' { 'Start' }
                        'EndStyle' { 'End' }
                        'StrokeColor' { 'Stroke' }
                        'ResetSequence' { 'Reset' }
                        default { $overflowName }
                    }
                    [System.Windows.Automation.AutomationProperties]::SetName(
                        $propertyItem, [string]$propertyItem.Header)
                    $propertyMenu.Items.Add($propertyItem) | Out-Null
                    $overflowEntry = [pscustomobject][ordered]@{
                        Name=$overflowName; Element=$propertyItem; Button=$null
                        Menu=$null; MenuItems=$null; Controller=$null; Swatch=$null
                    }
                    $Context.PropertyControls[$overflowName] = $overflowEntry
                    if (($Tool -eq 'Crop' -and $overflowName -in @('Reset','Apply')) -or
                        ($Tool -eq 'Select' -and
                            $overflowName -in @('Duplicate','Delete'))) {
                        $semanticName = $overflowName
                        $semanticHandler = {
                            switch ("$Tool/$semanticName") {
                                'Crop/Reset' { if ($Context.ResetCrop) { & $Context.ResetCrop } }
                                'Crop/Apply' { if ($Context.ApplyCrop) { & $Context.ApplyCrop } }
                                'Select/Duplicate' { if ($Context.DuplicateSelection) { & $Context.DuplicateSelection } }
                                'Select/Delete' { if ($Context.DeleteSelection) { & $Context.DeleteSelection } }
                            }
                            if ($null -ne $Context.PropertyMenuControl) {
                                & $Context.PropertyMenuControl.CloseOptions
                            }
                        }.GetNewClosure()
                        $propertyItem.Add_Click($semanticHandler)
                        $Context.PropertyBindings.Add([pscustomobject]@{
                            Target=$propertyItem; Handler=$semanticHandler
                        }) | Out-Null
                    }
                }
                $Context.PropertyMenuControl = Connect-SnipPreviewMenuButton `
                    -Button $button -Menu $propertyMenu -Context $Context -Name MoreProperties
                $Context.PropertyControls.MoreProperties = [pscustomobject][ordered]@{
                    Name='MoreProperties'; Element=$button; Button=$button
                    Menu=$propertyMenu; MenuItems=$null
                    Controller=$Context.PropertyMenuControl; Swatch=$null
                }
            } elseif ($Tool -eq 'BlurPixelate' -and $propertyName -eq 'Mode') {
                # The row's Mode entry and the tool band's split chevron pick the
                # same thing, so both route through the one subtype applier.
                $modeMenu = [System.Windows.Controls.ContextMenu]::new()
                $modeItems = [ordered]@{}
                foreach ($modeName in @('Blur','Pixelate')) {
                    $modeItem = [System.Windows.Controls.MenuItem]::new()
                    $modeItem.Header = $modeName
                    $modeItem.IsCheckable = $true
                    $modeItem.IsChecked = $obscureMode -eq $modeName
                    [System.Windows.Automation.AutomationProperties]::SetName(
                        $modeItem, "Obscure mode $modeName")
                    $selectedMode = $modeName
                    $modeHandler = {
                        if ($Context.ApplySplitSubtype) {
                            & $Context.ApplySplitSubtype 'BlurPixelate' $selectedMode
                        }
                        $button.Content = "Mode  $selectedMode"
                        foreach ($sibling in @($modeItems.Values)) {
                            $sibling.IsChecked = [string]$sibling.Header -eq $selectedMode
                        }
                        if ($null -ne $Context.PropertyModeMenuControl) {
                            & $Context.PropertyModeMenuControl.CloseOptions
                        }
                    }.GetNewClosure()
                    $modeItem.Add_Click($modeHandler)
                    $Context.PropertyBindings.Add([pscustomobject]@{
                        Target=$modeItem; Handler=$modeHandler
                    }) | Out-Null
                    $modeMenu.Items.Add($modeItem) | Out-Null
                    $modeItems[$modeName] = $modeItem
                }
                $Context.PropertyModeMenuControl = Connect-SnipPreviewMenuButton `
                    -Button $button -Menu $modeMenu -Context $Context -Name ObscureMode
                $Context.PropertyControls.Mode = [pscustomobject][ordered]@{
                    Name='Mode'; Element=$button; Button=$button
                    Menu=$modeMenu; MenuItems=$modeItems
                    Controller=$Context.PropertyModeMenuControl; Swatch=$null
                }
            } elseif ($Tool -eq 'Crop' -and $propertyName -eq 'Aspect') {
                $aspectMenu = [System.Windows.Controls.ContextMenu]::new()
                $aspectItems = [ordered]@{}
                foreach ($presetName in @('Free','Original','1:1','4:3','16:9')) {
                    $presetItem = [System.Windows.Controls.MenuItem]::new()
                    $presetItem.Header = $presetName
                    $presetItem.IsCheckable = $true
                    $presetItem.IsChecked = $Context.ToolProperties.Crop.Preset -eq $presetName
                    [System.Windows.Automation.AutomationProperties]::SetName(
                        $presetItem, "Crop aspect $presetName")
                    $selectedPreset = $presetName
                    $presetHandler = {
                        if ($Context.SelectCropPreset) {
                            & $Context.SelectCropPreset $selectedPreset
                        }
                        if ($null -ne $Context.CropAspectMenuControl) {
                            & $Context.CropAspectMenuControl.CloseOptions
                        }
                    }.GetNewClosure()
                    $presetItem.Add_Click($presetHandler)
                    $Context.PropertyBindings.Add([pscustomobject]@{
                        Target=$presetItem; Handler=$presetHandler
                    }) | Out-Null
                    $aspectMenu.Items.Add($presetItem) | Out-Null
                    $aspectItems[$presetName] = $presetItem
                }
                $Context.CropAspectMenuControl = Connect-SnipPreviewMenuButton `
                    -Button $button -Menu $aspectMenu -Context $Context -Name CropAspect
                $Context.PropertyControls.Aspect = [pscustomobject][ordered]@{
                    Name='Aspect'; Element=$button; Button=$button
                    Menu=$aspectMenu; MenuItems=$aspectItems
                    Controller=$Context.CropAspectMenuControl; Swatch=$null
                }
            } else {
                $Context.PropertyControls[$propertyName] = [pscustomobject][ordered]@{
                    Name=$propertyName; Element=$button; Button=$button
                    Menu=$null; MenuItems=$null; Controller=$null; Swatch=$null
                }
                if (($Tool -eq 'Crop' -and $propertyName -in @('Reset','Apply')) -or
                    ($Tool -eq 'Select' -and
                        $propertyName -in @('Duplicate','Delete'))) {
                    $semanticName = $propertyName
                    $semanticHandler = {
                        switch ("$Tool/$semanticName") {
                            'Crop/Reset' { if ($Context.ResetCrop) { & $Context.ResetCrop } }
                            'Crop/Apply' { if ($Context.ApplyCrop) { & $Context.ApplyCrop } }
                            'Select/Duplicate' { if ($Context.DuplicateSelection) { & $Context.DuplicateSelection } }
                            'Select/Delete' { if ($Context.DeleteSelection) { & $Context.DeleteSelection } }
                        }
                    }.GetNewClosure()
                    $button.Add_Click($semanticHandler)
                    $Context.PropertyBindings.Add([pscustomobject]@{
                        Target=$button; Handler=$semanticHandler
                    }) | Out-Null
                }
            }
            $panel.Children.Add($button) | Out-Null
        }
        $Context.Shell.PropertyIsland.Width = [double]::NaN
    }
    $Context.PropertyState
}

function Set-SnipPreviewStatusPresentation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if ($null -eq $Context.Shell -or $null -eq $Context.Shell.StatusText) { return }
    $presentation = Get-SnipStatusPresentation `
        -State $Context.PresentationState `
        -WindowWidth ([double]$Context.PresentationState.ViewportWidth)
    $statusText = $Context.Shell.StatusText
    $statusIsland = $Context.Shell.StatusIsland
    if ($null -ne $Context.Shell.PSObject.Properties['StatusIndicator']) {
        $Context.Shell.StatusIndicator.Visibility = if ($presentation.IndicatorVisible) {
            [System.Windows.Visibility]::Visible
        } else { [System.Windows.Visibility]::Collapsed }
    }
    $statusText.Text = [string]$presentation.Text
    $statusText.TextTrimming = [System.Windows.TextTrimming]::$($presentation.Trimming)
    $statusText.ToolTip = $presentation.ToolTip
    [System.Windows.Automation.AutomationProperties]::SetHelpText(
        $statusText, [string]$presentation.HelpText)
    $statusIsland.Width = [double]$presentation.Width
    $statusIsland.Padding = [System.Windows.Thickness]::new(
        [double]$presentation.PaddingHorizontal, 0,
        [double]$presentation.PaddingHorizontal, 0)
}

# Marks (or releases) the "this control is the active tool" state on one
# toolbar control. It sets IsChecked and nothing else: the Fluent ToggleButton
# style already paints a checked state with the Windows accent that reads in
# both modes, so painting a plate of our own here would only fight it.
function Set-SnipPreviewActiveChrome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.Control]$Control,
        [bool]$Active
    )

    if ($Control -is [System.Windows.Controls.Primitives.ToggleButton]) {
        $Control.IsChecked = [bool]$Active
    }
    $Control
}

function Set-SnipPreviewResponsiveMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [double]$Width,
        [Parameter(Mandatory)] [double]$Height
    )

    $Context.PresentationState.ActiveTool = [string]$Context.ActiveTool
    $Context.PresentationState.RecentTools = [string[]]@($Context.RecentTools)
    $result = Invoke-SnipPresentationIntent `
        -State $Context.PresentationState `
        -Intent ([pscustomobject]@{
            Type='ResizeViewport'; Width=$Width; Height=$Height
        })
    $Context.PresentationState = $result.State
    $presentation = Get-SnipToolbarPresentation -State $Context.PresentationState
    foreach ($effect in @($result.Effects)) {
        switch ([string]$effect.Name) {
            'RefreshResponsiveChrome' {
                & $Context.ApplyResponsivePresentation $presentation | Out-Null
            }
            'RefreshStatus' {
                Set-SnipPreviewStatusPresentation -Context $Context
            }
        }
    }
    [string]$Context.ModeState.Value
}

function Initialize-SnipPreviewAnnotations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IList]$Annotations
    )

    for ($index = 0; $index -lt $Annotations.Count; $index++) {
        $annotation = $Annotations[$index]
        $kind = Get-SnipRecordValue -InputObject $annotation -Name Kind
        $geometry = Get-SnipRecordValue -InputObject $annotation -Name Geometry
        $id = [string](Get-SnipRecordValue -InputObject $annotation -Name Id)
        if (-not [string]::IsNullOrWhiteSpace([string]$kind) -and
            $null -ne $geometry -and
            -not [string]::IsNullOrWhiteSpace($id)) {
            continue
        }
        $Annotations[$index] = Copy-SnipAnnotation -Annotation $annotation
    }
    $Annotations
}

function New-SnipPreviewWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    Initialize-SnipPreviewAnnotations -Annotations $Context.Annotations | Out-Null

    [xml]$xaml = [xml](Get-SnipXamlText -Name 'PreviewWindow')
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    # Same seam Settings/About/Widget use: theme immediately after the load so the
    # Fluent dictionaries (and therefore AccentButtonStyle and the ToolBar style
    # keys) are resolvable while the toolbars below are being populated, and long
    # before ShowDialog realises any template.
    [void](Initialize-SnipWindowTheme -Window $window)
    $window.Left = [double]$Context.InitialBounds.X
    $window.Top = [double]$Context.InitialBounds.Y
    $window.Width = [double]$Context.InitialBounds.Width
    $window.Height = [double]$Context.InitialBounds.Height
    $placementState = $Context.PlacementState
    $setWindowPosition = $Context.SetWindowPosition
    $initialPhysicalBounds = $Context.InitialPhysicalBounds
    $placementHelper = [System.Windows.Interop.WindowInteropHelper]::new($window)
    $sourceInitializedHandler = {
        if ($placementState.Effect.Name -eq 'ApplyPlacement' -and
            $placementHelper.Handle -ne [IntPtr]::Zero) {
            $placementState.IsApplied = [bool](& $setWindowPosition `
                $placementHelper.Handle $initialPhysicalBounds)
        }
    }.GetNewClosure()
    $closedPlacementHandler = $null
    $closedPlacementHandler = {
        $window.Remove_SourceInitialized($sourceInitializedHandler)
        $placementState.HandlersAttached = $false
    }.GetNewClosure()
    $window.Add_SourceInitialized($sourceInitializedHandler)
    $window.Add_Closed($closedPlacementHandler)
    $placementState.HandlersAttached = $true
    $Context.Window = $window
    $Context.Chrome = $null

    $actionBar = $window.FindName('PreviewActionToolBar')
    $toolBar = $window.FindName('PreviewEditorToolBar')
    $glyphFont = [System.Windows.Media.FontFamily]::new('Segoe Fluent Icons')
    # Glyph + label content. The label is an AccessText, not a TextBlock, so the
    # mnemonic underscore drives Alt navigation instead of rendering literally.
    $newGlyphContent = {
        param([int]$Glyph,[string]$Label,[double]$GlyphSize = 15)
        $panel = [System.Windows.Controls.StackPanel]::new()
        $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $icon = [System.Windows.Controls.TextBlock]::new()
        $icon.Text = [string][char]$Glyph
        $icon.FontFamily = $glyphFont
        $icon.FontSize = $GlyphSize
        $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $icon.Margin = [System.Windows.Thickness]::new(0,0,7,0)
        $panel.Children.Add($icon) | Out-Null
        if (-not [string]::IsNullOrEmpty($Label)) {
            $access = [System.Windows.Controls.AccessText]::new()
            $access.Text = $Label
            $access.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $panel.Children.Add($access) | Out-Null
        }
        $panel
    }.GetNewClosure()
    $newButton = {
        param([string]$Name,[string]$Text,[string]$AutomationName,[int]$Glyph = 0)
        $button = [System.Windows.Controls.Button]::new()
        $button.Name = $Name
        $button.Content = if ($Glyph -ne 0) {
            & $newGlyphContent $Glyph $Text
        } else { $Text }
        $button.Padding = [System.Windows.Thickness]::new(9,4,10,5)
        $button.Margin = [System.Windows.Thickness]::new(1,0,1,0)
        [System.Windows.Automation.AutomationProperties]::SetName($button, $AutomationName)
        $window.RegisterName($Name, $button)
        $button
    }.GetNewClosure()
    $newToggle = {
        param([string]$Name,[string]$Text,[string]$AutomationName,[int]$Glyph = 0)
        $button = [System.Windows.Controls.Primitives.ToggleButton]::new()
        $button.Name = $Name
        $button.Content = if ($Glyph -ne 0) {
            & $newGlyphContent $Glyph $Text
        } else { $Text }
        $button.Padding = [System.Windows.Thickness]::new(9,4,10,5)
        $button.Margin = [System.Windows.Thickness]::new(1,0,1,0)
        [System.Windows.Automation.AutomationProperties]::SetName($button, $AutomationName)
        $window.RegisterName($Name, $button)
        $button
    }.GetNewClosure()

    $copy = & $newButton 'CopyBtn' '_Copy & close' 'Copy and close' 0xE8C8
    # AccentButtonStyle sets RecognizesAccessKey=False, so the mnemonic only works
    # because the content above is an explicit AccessText rather than a string.
    $accentButtonStyle = $window.TryFindResource('AccentButtonStyle')
    if ($null -ne $accentButtonStyle) { $copy.Style = $accentButtonStyle }
    $save = & $newButton 'SaveBtn' '_Save' 'Save snip' 0xE74E
    $pin = & $newToggle 'PinBtn' '_Pin' 'Pin window on top' 0xE718
    $close = & $newButton 'CloseBtn' 'C_lose' 'Close preview' 0xE711
    $newSnip = $window.FindName('NewBtn')
    $window.FindName('HiddenLegacyControls').Children.Remove($newSnip)
    $newSnip.Content = & $newGlyphContent 0xE710 '_New snip'
    $newSnip.Padding = [System.Windows.Thickness]::new(9,4,10,5)
    [System.Windows.Automation.AutomationProperties]::SetName($newSnip, 'New snip')
    $duplicate = & $newButton 'DuplicateBtn' '_Duplicate' 'Duplicate selection' 0xE7C4
    $delete = & $newButton 'DeleteBtn' 'De_lete' 'Delete selection' 0xE74D
    $pin.ToolTip = 'Keep preview on top'
    $save.ToolTip = 'Save (Ctrl+S)'
    $copy.ToolTip = 'Copy and close (Ctrl+Enter)'
    $close.ToolTip = 'Close preview (Alt+F4)'
    foreach ($secondary in @($newSnip,$duplicate,$delete)) {
        [System.Windows.Controls.ToolBar]::SetOverflowMode(
            $secondary, [System.Windows.Controls.OverflowMode]::Always)
    }
    $actionSeparator = [System.Windows.Controls.Separator]::new()
    foreach ($control in @(
            $copy,$save,$pin,$actionSeparator,$close,$newSnip,$duplicate,$delete)) {
        $actionBar.Items.Add($control) | Out-Null
    }

    # Read-only capture size, pushed to the right edge of the action band. DimText
    # used to be a dead element parked in HiddenLegacyControls; this is its home.
    $dimensionText = [System.Windows.Controls.TextBlock]::new()
    $dimensionText.Name = 'DimText'
    $dimensionText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $dimensionText.Opacity = 0.85
    $dimensionText.IsHitTestVisible = $false
    $dimensionText.ToolTip = 'Capture size in pixels'
    [System.Windows.Automation.AutomationProperties]::SetName($dimensionText, 'Capture size')
    $window.RegisterName('DimText', $dimensionText)
    $actionBar.Items.Add($dimensionText) | Out-Null

    # ToolBar has no right-alignment of its own, so the leading margin is computed
    # once real widths exist and refreshed whenever the band is re-measured. Every
    # input is measured off the tray and the *other* items, never off the toolbar's
    # own width, so growing the margin cannot feed back into the next computation.
    $toolBarTray = $window.FindName('PreviewToolBarTray')
    $alignDimensionReadout = {
        if ($null -eq $toolBarTray -or $toolBarTray.ActualWidth -le 0) { return }
        $used = 0.0
        foreach ($item in $actionBar.Items) {
            if ([object]::ReferenceEquals($item, $dimensionText)) { continue }
            if ([System.Windows.Controls.ToolBar]::GetOverflowMode($item) -eq
                [System.Windows.Controls.OverflowMode]::Always) { continue }
            $element = $item -as [System.Windows.FrameworkElement]
            if ($null -eq $element) { continue }
            $used += $element.DesiredSize.Width
        }
        # 44px covers the ToolBar's own chrome: grip, padding and overflow button.
        $gap = $toolBarTray.ActualWidth - $used - $dimensionText.ActualWidth - 44
        if ($gap -lt 12) { $gap = 12 }
        if ([math]::Abs($gap - $dimensionText.Margin.Left) -gt 0.5) {
            $dimensionText.Margin = [System.Windows.Thickness]::new($gap,0,8,0)
        }
    }.GetNewClosure()
    $refreshDimensionReadout = { & $alignDimensionReadout }.GetNewClosure()
    $window.Add_Loaded($refreshDimensionReadout)
    $toolBarTray.Add_SizeChanged($refreshDimensionReadout)
    $actionBar.Add_SizeChanged($refreshDimensionReadout)

    $select = & $newButton 'SelectToolBtn' '_Select' 'Select tool' 0xE8B3
    $highlight = & $newToggle 'HighlightBtn' '_Highlight' 'Highlight tool' 0xE7E6
    $rectangle = & $newToggle 'RectangleToolBtn' '_Rectangle' 'Rectangle tool' 0xE739
    $arrow = & $newToggle 'ArrowToolBtn' '_Arrow' 'Arrow tool' 0xE72A
    $text = & $newToggle 'TextBtn' '_Text' 'Text tool' 0xE8D2
    $pen = & $newButton 'PenToolBtn' 'P_en' 'Pen tool' 0xE70F
    $steps = & $newButton 'StepsToolBtn' '_Steps' 'Numbered steps tool' 0xE8FD
    $privacy = & $newToggle 'BlurPixelateToolBtn' '_Blur' 'Blur tool' 0xEB42
    $crop = & $newButton 'CropToolBtn' 'C_rop' 'Crop tool' 0xE7A8
    # Every tool states what it does on hover; a glyph plus a two-word label is
    # not enough on its own, and the tooltip is what assistive tech reads out.
    $select.ToolTip = 'Select and move an annotation'
    $highlight.ToolTip = 'Highlight a region'
    $rectangle.ToolTip = 'Draw a rectangle or ellipse'
    $arrow.ToolTip = 'Draw an arrow or line'
    $text.ToolTip = 'Add a text label'
    $pen.ToolTip = 'Freehand pen'
    $steps.ToolTip = 'Numbered step badges'
    $privacy.ToolTip = 'Blur or pixelate a region'
    $crop.ToolTip = 'Crop the capture'
    $undo = & $newButton 'UndoBtn' '_Undo' 'Undo' 0xE7A7
    $redo = & $newButton 'RedoBtn' '_Redo' 'Redo' 0xE7A6
    $undo.ToolTip = 'Undo (Ctrl+Z)'
    $redo.ToolTip = 'Redo (Ctrl+Shift+Z)'
    $undo.IsEnabled = $false
    $redo.IsEnabled = $false
    $duplicate.IsEnabled = $false
    $delete.IsEnabled = $false

    # Stock split-button shape: the existing tool ToggleButton plus a chevron.
    # ToolBar only pushes ButtonStyleKey/ToggleButtonStyleKey onto its own direct
    # children, so anything nested in a panel falls back to the plain Fluent style
    # and stops matching its neighbours; both keys are re-applied by hand here.
    $toolBarToggleStyle = $window.TryFindResource(
        [System.Windows.Controls.ToolBar]::ToggleButtonStyleKey)
    $toolBarButtonStyle = $window.TryFindResource(
        [System.Windows.Controls.ToolBar]::ButtonStyleKey)
    # The chevron owns a real ContextMenu whose entries swap which shape the
    # primary draws, so the split is a working choice rather than decoration.
    $newSplitHost = {
        param([string]$Name,$Primary,[string]$Tip,[string]$SplitName,[string[]]$Options)
        $panel = [System.Windows.Controls.StackPanel]::new()
        $panel.Name = $Name
        $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $panel.Margin = [System.Windows.Thickness]::new(1,0,1,0)
        $window.RegisterName($Name, $panel)
        $Primary.Margin = [System.Windows.Thickness]::new(0)
        $Primary.Padding = [System.Windows.Thickness]::new(9,4,8,5)
        if ($null -ne $toolBarToggleStyle) { $Primary.Style = $toolBarToggleStyle }
        $chevron = [System.Windows.Controls.Button]::new()
        $chevron.Name = "$($SplitName)Options"
        $chevronGlyph = [System.Windows.Controls.TextBlock]::new()
        $chevronGlyph.Text = [string][char]0xE70D
        $chevronGlyph.FontFamily = $glyphFont
        $chevronGlyph.FontSize = 9
        $chevronGlyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $chevron.Content = $chevronGlyph
        $chevron.Padding = [System.Windows.Thickness]::new(5,4,5,5)
        $chevron.MinWidth = 22
        $chevron.Margin = [System.Windows.Thickness]::new(-3,0,0,0)
        $chevron.Focusable = $true
        $chevron.ToolTip = $Tip
        [System.Windows.Automation.AutomationProperties]::SetName($chevron, $Tip)
        if ($null -ne $toolBarButtonStyle) { $chevron.Style = $toolBarButtonStyle }
        $window.RegisterName($chevron.Name, $chevron)
        $panel.Children.Add($Primary) | Out-Null
        $panel.Children.Add($chevron) | Out-Null
        $menu = [System.Windows.Controls.ContextMenu]::new()
        $menuItems = [ordered]@{}
        foreach ($optionName in $Options) {
            $item = [System.Windows.Controls.MenuItem]::new()
            $item.Header = $optionName
            $item.IsCheckable = $true
            $item.IsChecked = [string]$optionName -eq [string]$Options[0]
            [System.Windows.Automation.AutomationProperties]::SetName($item, $optionName)
            $menu.Items.Add($item) | Out-Null
            $menuItems[[string]$optionName] = $item
        }
        $controller = Connect-SnipPreviewMenuButton `
            -Button $chevron -Menu $menu -Context $Context -Name $SplitName
        [pscustomobject]@{
            Panel=$panel; Chevron=$chevron; Menu=$menu
            MenuItems=$menuItems; Controller=$controller
        }
    }.GetNewClosure()
    $rectangleSplitHost = & $newSplitHost 'RectangleSplit' $rectangle `
        'Rectangle or Ellipse options' 'RectangleEllipse' @('Rectangle','Ellipse')
    $arrowSplitHost = & $newSplitHost 'ArrowSplit' $arrow `
        'Arrow or Line options' 'ArrowLine' @('Arrow','Line')
    $privacySplitHost = & $newSplitHost 'BlurSplit' $privacy `
        'Blur or Pixelate options' 'BlurPixelate' @('Blur','Pixelate')
    $rectangleSplit = $rectangleSplitHost.Panel
    $arrowSplit = $arrowSplitHost.Panel
    $privacySplit = $privacySplitHost.Panel

    # Showing the window rebuilds the merged Fluent dictionaries, so the Style
    # instances resolved during construction are replaced by fresh ones. Re-resolve
    # once loaded, otherwise the hand-styled controls silently drift out of step
    # with the neighbours the ToolBar styled for itself.
    $refreshFluentStyles = {
        $liveAccent = $window.TryFindResource('AccentButtonStyle')
        if ($null -ne $liveAccent) { $copy.Style = $liveAccent }
        $liveToggle = $window.TryFindResource(
            [System.Windows.Controls.ToolBar]::ToggleButtonStyleKey)
        $liveButton = $window.TryFindResource(
            [System.Windows.Controls.ToolBar]::ButtonStyleKey)
        foreach ($splitPanel in @($rectangleSplit,$arrowSplit,$privacySplit)) {
            if ($null -ne $liveToggle) { $splitPanel.Children[0].Style = $liveToggle }
            if ($null -ne $liveButton) { $splitPanel.Children[1].Style = $liveButton }
        }
        # ToolBar's own overflow toggle is an unnamed template part, so it ships
        # with no accessible name and announces as an unlabelled button. The
        # Fluent template does not expose it under a known part name, so find it
        # structurally: it is the only ToggleButton in the band's own visual tree
        # that is not one of the tool toggles we named ourselves.
        foreach ($band in @(
            [pscustomobject]@{ Bar=$actionBar; Label='More preview actions' },
            [pscustomobject]@{ Bar=$toolBar; Label='More editing tools' })) {
            $pendingVisuals =
                [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
            $pendingVisuals.Enqueue($band.Bar)
            while ($pendingVisuals.Count -gt 0) {
                $visual = $pendingVisuals.Dequeue()
                $toggle = $visual -as [System.Windows.Controls.Primitives.ToggleButton]
                if ($null -ne $toggle -and [string]::IsNullOrEmpty($toggle.Name) -and
                    [string]::IsNullOrWhiteSpace(
                        [System.Windows.Automation.AutomationProperties]::GetName($toggle))) {
                    [System.Windows.Automation.AutomationProperties]::SetName(
                        $toggle, $band.Label)
                    $toggle.ToolTip = $band.Label
                }
                $visualChildCount =
                    [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($visual)
                for ($visualIndex = 0; $visualIndex -lt $visualChildCount; $visualIndex++) {
                    $pendingVisuals.Enqueue(
                        [System.Windows.Media.VisualTreeHelper]::GetChild($visual, $visualIndex))
                }
            }
        }
    }.GetNewClosure()
    $window.Add_Loaded($refreshFluentStyles)
    foreach ($control in @(
            $select,$highlight,$rectangleSplit,$arrowSplit,$text,$pen,$steps,
            $privacySplit,$crop,
            [System.Windows.Controls.Separator]::new(),$undo,$redo)) {
        $toolBar.Items.Add($control) | Out-Null
    }

    # Compatibility controls remain routable for existing editor internals but are
    # deliberately absent from the visible presentation.
    $color = & $newButton 'ColorToolBtn' 'Color' 'Annotation color'
    $more = & $newButton 'MoreBtn' 'More' 'More tools'
    foreach ($hiddenControl in @($color,$more)) {
        $hiddenControl.Visibility = [System.Windows.Visibility]::Collapsed
    }
    $colorMenu = [System.Windows.Controls.ContextMenu]::new()
    $colorMenuItems = [ordered]@{}
    foreach ($colorName in @('Yellow','Green','Pink','Blue','Orange','Red')) {
        $colorItem = [System.Windows.Controls.MenuItem]::new()
        $colorItem.Header = $colorName
        [System.Windows.Automation.AutomationProperties]::SetName($colorItem, $colorName)
        $colorMenu.Items.Add($colorItem) | Out-Null
        $colorMenuItems[$colorName] = $colorItem
    }
    $colorMenuControl = Connect-SnipPreviewMenuButton `
        -Button $color -Menu $colorMenu -Context $Context -Name Color
    $copyKeepOpenItem = [System.Windows.Controls.MenuItem]::new()
    $copyKeepOpenItem.Header = 'Copy and keep open'
    $copyMenu = [System.Windows.Controls.ContextMenu]::new()
    $copyMenu.Items.Add($copyKeepOpenItem) | Out-Null
    $copy.ContextMenu = $copyMenu
    $Context.SplitControls.Copy = [pscustomobject]@{
        Name='CopyAndClose'; DefaultCommand='CopyAndClose'; OptionOrder=@('CopyKeepOpen')
        Root=$copy; PrimaryButton=$copy; OptionsButton=$null; Menu=$copyMenu
        MenuItems=[ordered]@{ CopyKeepOpen=$copyKeepOpenItem }
        State=[pscustomobject]@{ HandlersAttached=$false }
    }
    # A split tool's Label/Glyph point at the live content of its primary button,
    # so choosing the alternate shape restyles the button the user is looking at
    # instead of updating a detached string.
    $newToolSplitControl = {
        param([string]$Name,[string]$DefaultCommand,$Primary,$SplitHost)
        $content = $Primary.Content
        [pscustomobject]@{
            Name=$Name; DefaultCommand=$DefaultCommand
            OptionOrder=[string[]]@($SplitHost.MenuItems.Keys)
            Root=$SplitHost.Panel; PrimaryButton=$Primary
            OptionsButton=$SplitHost.Chevron; Menu=$SplitHost.Menu; MenuItems=$SplitHost.MenuItems
            Glyph=$content.Children[0]; Label=$content.Children[1]
            Controller=$SplitHost.Controller; State=$SplitHost.Controller.State
            OpenOptions=$SplitHost.Controller.OpenOptions
            CloseOptions=$SplitHost.Controller.CloseOptions
        }
    }.GetNewClosure()
    $Context.SplitControls.ArrowLine = & $newToolSplitControl `
        'ArrowLine' 'Arrow' $arrow $arrowSplitHost
    $Context.SplitControls.RectangleEllipse = & $newToolSplitControl `
        'RectangleEllipse' 'Rectangle' $rectangle $rectangleSplitHost
    $Context.SplitControls.BlurPixelate = & $newToolSplitControl `
        'BlurPixelate' 'Blur' $privacy $privacySplitHost
    $Context.ToolControls = [ordered]@{
        Select=$select; Crop=$crop; Pen=$pen; Highlight=$highlight; ArrowLine=$arrow
        RectangleEllipse=$rectangle; Text=$text; Steps=$steps; BlurPixelate=$privacy
        Color=$color; More=$more; Undo=$undo; Redo=$redo
    }
    $moreMenu = [System.Windows.Controls.ContextMenu]::new()
    $moreMenuItems = [ordered]@{}
    $moreColorMenuItems = [ordered]@{}
    foreach ($toolSpec in @(
        @('Highlight','Highlight'), @('ArrowLine','Arrow/Line'),
        @('RectangleEllipse','Rectangle/Ellipse'), @('Steps','Steps'), @('Color','Color'))) {
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $toolSpec[1]
        [System.Windows.Automation.AutomationProperties]::SetName($item, $toolSpec[1])
        if ($toolSpec[0] -eq 'Color') {
            foreach ($colorName in @('Yellow','Green','Pink','Blue','Orange','Red')) {
                $colorItem = [System.Windows.Controls.MenuItem]::new()
                $colorItem.Header = $colorName
                [System.Windows.Automation.AutomationProperties]::SetName(
                    $colorItem, $colorName)
                $item.Items.Add($colorItem) | Out-Null
                $moreColorMenuItems[$colorName] = $colorItem
            }
        }
        $moreMenu.Items.Add($item) | Out-Null
        $moreMenuItems[$toolSpec[0]] = $item
    }
    $moreMenu.PlacementTarget = $more
    $moreMenuState = [pscustomobject]@{
        IsExpanded=$false; MenuHandle=[IntPtr]::Zero; IsMenuWindowRegistered=$false
        HandlersAttached=$false
    }
    $moreOpen = { }.GetNewClosure()
    $moreClose = { }.GetNewClosure()
    $moreIcon = [pscustomobject]@{ Text='' }
    $moreName = [pscustomobject]@{ Text='' }
    $moreIndicator = [pscustomobject]@{ Visibility=[System.Windows.Visibility]::Collapsed }
    $Context.Shell = [pscustomobject][ordered]@{
        Window=$window; StudioRoot=$window.FindName('StudioRoot'); Scroller=$window.FindName('Scroller')
        ImageHost=$window.FindName('ImageHost'); PreviewImage=$window.FindName('PreviewImage')
        AnnotationLayer=$window.FindName('AnnotationLayer')
        InteractionLayer=$window.FindName('InteractionLayer')
        SelectionLayer=$window.FindName('SelectionLayer')
        HighlightLayer=$window.FindName('HighlightLayer'); BrandIsland=$actionBar
        ActionsIsland=$actionBar; PropertyIsland=$window.FindName('PropertyIsland')
        ToolDock=$toolBar; ViewportIsland=$window.FindName('ViewportIsland')
        StatusIsland=$window.FindName('StatusIsland'); ToolPanel=$toolBar
        PropertyPanel=$window.FindName('PropertyPanel'); MoreButton=$more
        MoreMenu=$moreMenu; MoreMenuItems=$moreMenuItems; MoreMenuState=$moreMenuState
        MoreColorMenuItems=$moreColorMenuItems; CloseMoreMenu=$moreClose
        MoreIcon=$moreIcon; MoreName=$moreName; MoreIndicator=$moreIndicator
        ColorMenu=$colorMenu; ColorMenuItems=$colorMenuItems; ColorMenuControl=$colorMenuControl
        CoordinateText=$window.FindName('CoordinateText'); ZoomOutButton=$window.FindName('ZoomOutBtn')
        ZoomInButton=$window.FindName('ZoomInBtn'); StatusText=$window.FindName('StatusText')
        StatusIndicator=$window.FindName('StatusIndicator')
        PreviewToolBarTray=$window.FindName('PreviewToolBarTray')
        PreviewActionToolBar=$actionBar; PreviewEditorToolBar=$toolBar
        PreviewPropertyBar=$window.FindName('PreviewPropertyBar')
        PreviewStatusBar=$window.FindName('PreviewStatusBar')
    }
    $setPropertyIslandPresentation = ${function:Set-SnipPropertyIsland}
    $Context.ApplyPropertyPresentation = {
        param([string]$Tool)
        & $setPropertyIslandPresentation -Context $Context -Tool $Tool | Out-Null
    }.GetNewClosure()
    $Context.ApplyResponsivePresentation = {
        param($Presentation = $null)
        if ($null -eq $Presentation) {
            $Presentation = Get-SnipToolbarPresentation `
                -State $Context.PresentationState
        }
        $mode = 'Native'
        $Context.ModeState.Value = 'Native'
        $order = [string[]]@($Presentation.Order)
        $Context.ToolOrder.Clear()
        foreach ($name in $order) { $Context.ToolOrder.Add($name) | Out-Null }
        $Context.MoreState.IsActive = $false
        $Context.MoreState.Tool = $null
        & $setPropertyIslandPresentation `
            -Context $Context -Tool $Context.ActivePropertyTool | Out-Null
        'Native'
    }.GetNewClosure()
    $closeMenus = {
        foreach ($splitControl in @($Context.TransientMenus)) {
            if ($null -ne $splitControl -and $null -ne $splitControl.CloseOptions) {
                & $splitControl.CloseOptions
            }
        }
    }.GetNewClosure()
    $resolveCommand = {
        param([string]$FocusedRole,[hashtable]$EditorState,[string]$Key,$Modifiers)
        Resolve-SnipPresentationKeyIntent -State $Context.PresentationState `
            -FocusedRole $FocusedRole -EditorState $EditorState `
            -Key $Key -Modifiers @($Modifiers)
    }.GetNewClosure()
    $clearStatus = {
        $result = Invoke-SnipPresentationIntent `
            -State $Context.PresentationState `
            -Intent ([pscustomobject]@{ Type='ClearStatus' })
        $Context.PresentationState = $result.State
        $Context.StatusState.Kind = [string]$result.State.StatusKind
        $Context.StatusState.Text = [string]$result.State.StatusText
        foreach ($effect in @($result.Effects)) {
            if ([string]$effect.Name -eq 'RefreshStatus') {
                Set-SnipPreviewStatusPresentation -Context $Context
            }
        }
    }.GetNewClosure()
    $setStatus = {
        param([string]$Text, [string]$Kind = 'Info')
        if ([string]::IsNullOrWhiteSpace($Text)) {
            & $clearStatus
            return
        }
        $result = Invoke-SnipPresentationIntent `
            -State $Context.PresentationState `
            -Intent ([pscustomobject]@{ Type='SetStatus'; Kind=$Kind; Text=$Text })
        $Context.PresentationState = $result.State
        $Context.StatusState.Kind = [string]$result.State.StatusKind
        $Context.StatusState.Text = [string]$result.State.StatusText
        foreach ($effect in @($result.Effects)) {
            if ([string]$effect.Name -eq 'RefreshStatus') {
                Set-SnipPreviewStatusPresentation -Context $Context
            }
        }
    }.GetNewClosure()
    $Context.ClearStatus = $clearStatus
    $Context.SetStatus = $setStatus

    $defaultSystemMenuAction = {
        $point = $window.PointToScreen([System.Windows.Point]::new(0, 0))
        [System.Windows.SystemCommands]::ShowSystemMenu($window, $point)
    }.GetNewClosure()
    $closePreviewAction = { $window.Close() }.GetNewClosure()
    $commandRouter = [pscustomobject][ordered]@{
        Resolve = $resolveCommand
        CloseTransientMenus = $closeMenus
        SupportsNativeSystemMenu = $true
        LastCommand = $null
        ResolveCount = 0
        SystemMenuAction = $defaultSystemMenuAction
        CloseAction = $closePreviewAction
    }
    $Context.CommandRouter = $commandRouter
    Set-SnipPreviewResponsiveMode -Context $Context -Width $window.Width -Height $window.Height | Out-Null
    $Context.Shell
}

function Show-PreviewWindow {
    [CmdletBinding()]
    param(
        [System.Drawing.Bitmap]$Bitmap,
        # Harness hook. When a scriptblock is provided, Show-PreviewWindow
        # still calls ShowDialog() (so its local scope stays alive and the
        # event handlers keep working), but on the Loaded event it posts
        # $TestAction back to the dispatcher, which then invokes it with a
        # hashtable of handles and closes the window.
        # The window is positioned off-screen for a headless feel.
        [scriptblock]$TestAction,
        $DisplayTopology,
        $Settings = $script:Settings,
        [scriptblock]$OnOwnershipAccepted,
        [scriptblock]$OnSurfaceReady,
        [scriptblock]$OnNewSnip,
        [scriptblock]$OnOutputStarting,
        [scriptblock]$OnOutputCompleted
    )

    $previewLifecycle = [pscustomobject]@{
        Result = 'UserCancelled'
        CleanupInstalled = $false
        OwnershipAccepted = $false
        BitmapDisposed = $false
    }
    $src = Convert-BitmapToBitmapSource $Bitmap

    # The legacy editor below remains the annotation engine; the Floating
    # Studio owns only construction, layout, chrome, and command surfaces.
    # Keeping this adapter at the old construction seam preserves every named
    # closure and the public Show-PreviewWindow signature.
    $previewContext = New-SnipPreviewContext -Bitmap $Bitmap -BitmapSource $src `
        -DisplayTopology $DisplayTopology -Settings $Settings
    $studioShell = New-SnipPreviewWindow -Context $previewContext
    $script:ActivePreviewContext = $previewContext
    $win = $studioShell.Window

    # Selection outlines, resize handles and the crop frame are the only chrome
    # the annotation renderer paints itself. They read the stock Fluent keys
    # through the live window rather than a palette of ours, so they follow the
    # Windows accent and the app theme; resolving per call matters because
    # Show() rebuilds the theme dictionaries and invalidates cached brushes.
    $findThemeBrush = {
        param([string]$Key, [System.Windows.Media.Brush]$Fallback)
        $resolved = $win.TryFindResource($Key)
        if ($resolved -is [System.Windows.Media.Brush]) { $resolved } else { $Fallback }
    }.GetNewClosure()
    $getSelectionBrush = {
        & $findThemeBrush 'AccentFillColorDefaultBrush' `
            ([System.Windows.Media.Brushes]::DodgerBlue)
    }.GetNewClosure()
    $getSurfaceBrush = {
        & $findThemeBrush 'SolidBackgroundFillColorBaseBrush' `
            ([System.Windows.Media.Brushes]::White)
    }.GetNewClosure()
    $getPrimaryTextBrush = {
        & $findThemeBrush 'TextFillColorPrimaryBrush' `
            ([System.Windows.Media.Brushes]::Black)
    }.GetNewClosure()

    $previewImage = $win.FindName('PreviewImage')
    $previewImage.Source = $previewContext.BitmapSource
    $win.Title = "SnipIT Preview - $($Bitmap.Width) x $($Bitmap.Height) px"
    $dimensionReadout = $win.FindName('DimText')
    if ($null -ne $dimensionReadout) {
        $dimensionReadout.Text =
            "$($Bitmap.Width) $([char]0x00D7) $($Bitmap.Height) px"
    }

    # Surface ANY WPF dispatcher exception. Copy to clipboard AND write to
    # %LOCALAPPDATA%\SnipIT\last-error.txt — a plain MessageBox doesn't always
    # let you select text on Win11.
    $win.Dispatcher.add_UnhandledException({
        param($sender, $e)
        $ex = $e.Exception
        $msg = "$($ex.GetType().FullName)`n$($ex.Message)`n`n$($ex.StackTrace)"
        # Seed the path before the try. The report below interpolates $logFile
        # from outside that block, so if Join-Path throws (unset $script:AppHomeDir
        # on an early-failing launch) the variable would never be set and the
        # interpolation would itself fail under Set-StrictMode — losing the crash
        # report inside the handler whose only job is to surface crashes.
        $logFile = '<unavailable>'
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
    $annotationLayer = $win.FindName('AnnotationLayer')
    $interactionLayer = $win.FindName('InteractionLayer')
    $selectionLayer = $win.FindName('SelectionLayer')
    $highlightBtn   = $win.FindName('HighlightBtn')
    $rectBtn        = $win.FindName('RectBtn')
    $arrowBtn       = $win.FindName('ArrowBtn')
    $textBtn        = $win.FindName('TextBtn')
    $imageHost      = $win.FindName('ImageHost')
    $colorBar       = $win.FindName('ColorBar')
    $scroller       = $win.FindName('Scroller')
    $zoomText       = $win.FindName('ZoomText')
    # Create the shared transform before any gesture closure captures it.
    # Selection/crop hit tolerances and handle sizes must observe the live
    # object rather than a pre-initialization $null captured by GetNewClosure().
    $layoutScale = [System.Windows.Media.ScaleTransform]::new(1,1)
    $imageHost.LayoutTransform = $layoutScale

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
        Annotations  = $previewContext.Annotations
        UndoStack    = $previewContext.UndoStack
        RedoStack    = $previewContext.RedoStack
        SelectionId  = $previewContext.SelectedAnnotationId
        CropRectangle = $previewContext.CropRectangle
        Draft        = $previewContext.Draft
        ActiveColor  = 'Yellow'
        Drawing      = $false
        DrawingTool  = $null
        AnchorCanvas = $null
        DraftRect    = $null
        EditingText  = $false
        Zoom         = 1.0
        # Pan (Hand) mode: active when no annotation tool is checked.
        Panning      = $false
        TemporaryPan = $false
        PanStartSv   = $null   # mouse position at pan-begin, in Scroller-local coords
        PanOrigX     = 0.0     # Scroller.HorizontalOffset at pan-begin
        PanOrigY     = 0.0     # Scroller.VerticalOffset   at pan-begin
        ActiveStudioTool = $previewContext.ActiveTool
    }
    $previewContext.EditorState = $state

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

    function script:Get-PreviewAnnotationBounds {
        param($Annotation)
        if ($null -eq $Annotation -or $null -eq $Annotation.Geometry) { return $null }
        $geometry = $Annotation.Geometry
        switch ([string]$geometry.Type) {
            { $_ -in @('Bounds','TextBounds','StepBounds') } {
                return [pscustomobject]@{
                    X=[double]$geometry.X; Y=[double]$geometry.Y
                    Width=[double]$geometry.Width; Height=[double]$geometry.Height
                }
            }
            'Line' {
                $left = [math]::Min([double]$geometry.Start.X,[double]$geometry.End.X)
                $top = [math]::Min([double]$geometry.Start.Y,[double]$geometry.End.Y)
                return [pscustomobject]@{
                    X=$left; Y=$top
                    Width=[math]::Max(1.0,[math]::Abs([double]$geometry.End.X-[double]$geometry.Start.X))
                    Height=[math]::Max(1.0,[math]::Abs([double]$geometry.End.Y-[double]$geometry.Start.Y))
                }
            }
            'Points' {
                $points = @($geometry.Points)
                if ($points.Count -eq 0) { return $null }
                $xs = @($points | ForEach-Object { [double]$_.X })
                $ys = @($points | ForEach-Object { [double]$_.Y })
                $left = [double](($xs | Measure-Object -Minimum).Minimum)
                $top = [double](($ys | Measure-Object -Minimum).Minimum)
                return [pscustomobject]@{
                    X=$left; Y=$top
                    Width=[math]::Max(1.0,[double](($xs | Measure-Object -Maximum).Maximum)-$left)
                    Height=[math]::Max(1.0,[double](($ys | Measure-Object -Maximum).Maximum)-$top)
                }
            }
        }
        $null
    }

    function script:Get-PreviewAnnotationById {
        param([AllowNull()][string]$Id)
        if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
        $matches=@($previewContext.Annotations | Where-Object {
            [string]$_.Id -eq $Id
        } | Select-Object -First 1)
        if($matches.Count -gt 0){return $matches[0]}
        $null
    }

    function script:Get-PreviewAnnotationIndexById {
        param([AllowNull()][string]$Id)
        if ([string]::IsNullOrWhiteSpace($Id)) { return -1 }
        for ($index = 0; $index -lt $previewContext.Annotations.Count; $index++) {
            if ([string]$previewContext.Annotations[$index].Id -eq $Id) { return $index }
        }
        -1
    }

    function script:Test-PreviewAnnotationEqual {
        param($Left,$Right)
        if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
        (ConvertTo-Json $Left -Depth 32 -Compress) -ceq
            (ConvertTo-Json $Right -Depth 32 -Compress)
    }

    function script:Test-PreviewCropEqual {
        param($Left,$Right)
        if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
        [int]$Left.X -eq [int]$Right.X -and [int]$Left.Y -eq [int]$Right.Y -and
            [int]$Left.Width -eq [int]$Right.Width -and
            [int]$Left.Height -eq [int]$Right.Height
    }

    function script:Get-PreviewWpfBrush {
        param([string]$Color,[int]$Alpha=255)
        $rgb = $palette[$Color]
        if ($null -eq $rgb) { return (& $getPrimaryTextBrush) }
        [System.Windows.Media.SolidColorBrush]::new(
            (To-WpfColor $Alpha $rgb.R $rgb.G $rgb.B))
    }

    function script:Add-PreviewHandleSet {
        param(
            [Parameter(Mandatory)] [System.Windows.Controls.Canvas]$Layer,
            [Parameter(Mandatory)] $Bounds,
            [Parameter(Mandatory)] [string]$Role,
            [string[]]$Handles = @('TopLeft','Top','TopRight','Right','BottomRight','Bottom','BottomLeft','Left')
        )
        $zoom = if ($null -ne $layoutScale -and $layoutScale.ScaleX -gt 0) {
            [double]$layoutScale.ScaleX
        } else { 1.0 }
        $diameter = 10.0 / $zoom
        $half = $diameter / 2.0
        $centers = @{
            TopLeft=@(([double]$Bounds.X),([double]$Bounds.Y))
            Top=@(([double]$Bounds.X + [double]$Bounds.Width/2.0),([double]$Bounds.Y))
            TopRight=@(([double]$Bounds.X + [double]$Bounds.Width),([double]$Bounds.Y))
            Right=@(([double]$Bounds.X + [double]$Bounds.Width),([double]$Bounds.Y + [double]$Bounds.Height/2.0))
            BottomRight=@(([double]$Bounds.X + [double]$Bounds.Width),([double]$Bounds.Y + [double]$Bounds.Height))
            Bottom=@(([double]$Bounds.X + [double]$Bounds.Width/2.0),([double]$Bounds.Y + [double]$Bounds.Height))
            BottomLeft=@(([double]$Bounds.X),([double]$Bounds.Y + [double]$Bounds.Height))
            Left=@(([double]$Bounds.X),([double]$Bounds.Y + [double]$Bounds.Height/2.0))
        }
        foreach ($handleName in $Handles) {
            $handle = [System.Windows.Shapes.Ellipse]::new()
            $handle.Width = $diameter; $handle.Height = $diameter
            $handle.Fill = & $getSelectionBrush
            $handle.Stroke = & $getSurfaceBrush
            $handle.StrokeThickness = 1.0 / $zoom
            $handle.IsHitTestVisible = $false
            $handle.Tag = [pscustomobject]@{ Role=$Role; Handle=$handleName }
            [System.Windows.Controls.Canvas]::SetLeft($handle,[double]$centers[$handleName][0]-$half)
            [System.Windows.Controls.Canvas]::SetTop($handle,[double]$centers[$handleName][1]-$half)
            $Layer.Children.Add($handle) | Out-Null
        }
    }

    function script:Render-PreviewInteraction {
        $interactionLayer.Children.Clear()
        $selectionLayer.Children.Clear()
        $zoom = if ($null -ne $layoutScale -and $layoutScale.ScaleX -gt 0) {
            [double]$layoutScale.ScaleX
        } else { 1.0 }

        $crop = if ($null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Crop') {
            $previewContext.Draft.Candidate
        } else { $previewContext.CropRectangle }
        if ($null -ne $crop) {
            $cropOutline = [System.Windows.Shapes.Rectangle]::new()
            $cropOutline.Width=[double]$crop.Width; $cropOutline.Height=[double]$crop.Height
            $cropOutline.Stroke=(& $getSelectionBrush)
            $cropOutline.StrokeThickness=2.0/$zoom
            $cropOutline.Fill=[System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.Color]::FromArgb(20,168,239,215))
            $cropOutline.IsHitTestVisible=$false
            $cropOutline.Tag=[pscustomobject]@{ Role='CropOverlay' }
            [System.Windows.Controls.Canvas]::SetLeft($cropOutline,[double]$crop.X)
            [System.Windows.Controls.Canvas]::SetTop($cropOutline,[double]$crop.Y)
            $interactionLayer.Children.Add($cropOutline) | Out-Null
            Add-PreviewHandleSet -Layer $interactionLayer -Bounds $crop `
                -Role CropHandle
        }

        $selected = Get-PreviewAnnotationById $previewContext.SelectedAnnotationId
        if ($null -eq $selected) {
            if ($null -ne $previewContext.SelectedAnnotationId) {
                $previewContext.SelectedAnnotationId = $null
                $state.SelectionId = $null
            }
            return
        }
        if ($null -ne $previewContext.Interaction -and
            $previewContext.Interaction.Kind -eq 'Select' -and
            $null -ne $previewContext.Interaction.Candidate) {
            $selected = $previewContext.Interaction.Candidate
        }
        $geometry = $selected.Geometry
        if ($geometry.Type -eq 'Line') {
            $outline = [System.Windows.Shapes.Line]::new()
            $outline.X1=[double]$geometry.Start.X; $outline.Y1=[double]$geometry.Start.Y
            $outline.X2=[double]$geometry.End.X; $outline.Y2=[double]$geometry.End.Y
            $outline.Stroke=(& $getSelectionBrush); $outline.StrokeThickness=2.0/$zoom
            $outline.IsHitTestVisible=$false
            $outline.Tag=[pscustomobject]@{ Role='SelectionOutline' }
            $selectionLayer.Children.Add($outline) | Out-Null
            foreach ($endpoint in @(
                [pscustomobject]@{ Name='Start'; X=$geometry.Start.X; Y=$geometry.Start.Y },
                [pscustomobject]@{ Name='End'; X=$geometry.End.X; Y=$geometry.End.Y })) {
                $diameter=10.0/$zoom; $handle=[System.Windows.Shapes.Ellipse]::new()
                $handle.Width=$diameter; $handle.Height=$diameter
                $handle.Fill=(& $getSelectionBrush); $handle.IsHitTestVisible=$false
                $handle.Tag=[pscustomobject]@{ Role='SelectionHandle'; Handle=$endpoint.Name }
                [System.Windows.Controls.Canvas]::SetLeft($handle,[double]$endpoint.X-$diameter/2)
                [System.Windows.Controls.Canvas]::SetTop($handle,[double]$endpoint.Y-$diameter/2)
                $selectionLayer.Children.Add($handle) | Out-Null
            }
            return
        }
        $bounds = Get-PreviewAnnotationBounds $selected
        if ($null -eq $bounds) { return }
        $selectionOutline = [System.Windows.Shapes.Rectangle]::new()
        $selectionOutline.Width=$bounds.Width; $selectionOutline.Height=$bounds.Height
        $selectionOutline.Stroke=(& $getSelectionBrush)
        $selectionOutline.StrokeThickness=2.0/$zoom
        $dashPattern=[System.Windows.Media.DoubleCollection]::new()
        $dashPattern.Add(3.0/$zoom)
        $dashPattern.Add(2.0/$zoom)
        $selectionOutline.StrokeDashArray=$dashPattern
        $selectionOutline.IsHitTestVisible=$false
        $selectionOutline.Tag=[pscustomobject]@{ Role='SelectionOutline' }
        [System.Windows.Controls.Canvas]::SetLeft($selectionOutline,$bounds.X)
        [System.Windows.Controls.Canvas]::SetTop($selectionOutline,$bounds.Y)
        $selectionLayer.Children.Add($selectionOutline) | Out-Null
        Add-PreviewHandleSet -Layer $selectionLayer -Bounds $bounds `
            -Role SelectionHandle
    }

    # Both WPF composition and compatibility bitmap output consume this same
    # stable projection. Sorting the wrapper records leaves the authoritative
    # annotation list and its canonical record identities untouched.
    $getOrderedAnnotations = {
        Initialize-SnipPreviewAnnotations `
            -Annotations $previewContext.Annotations | Out-Null
        $entries = for ($index = 0;
            $index -lt $previewContext.Annotations.Count; $index++) {
            [pscustomobject]@{
                Annotation = $previewContext.Annotations[$index]
                Index = $index
            }
        }
        @($entries | Sort-Object `
            @{Expression={ [double]$_.Annotation.Z };Ascending=$true}, `
            @{Expression={ $_.Index };Ascending=$true} |
            ForEach-Object Annotation)
    }.GetNewClosure()

    # Blur and Pixelate show the capture's own pixels re-rendered, not a grey
    # box, so the preview reads exactly like the exported file.
    #
    # Both modes are one operation with two scaling modes: reduce the cropped
    # region, then blow it back up — nearest-neighbour gives the mosaic, Fant
    # gives the blur. Doing it with bitmap scaling rather than a BlurEffect
    # keeps the result inside its own bounds (an Effect smears well past the
    # region) and keeps it visible to RenderTargetBitmap, which ignores Effects.
    $newObscureVisual = {
        param($Annotation)
        $geometry = $Annotation.Geometry
        $left = [int]$geometry.X
        $top = [int]$geometry.Y
        $width = [int]$geometry.Width
        $height = [int]$geometry.Height
        $source = $previewContext.BitmapSource
        if ($null -eq $source) { return $null }
        $left = [math]::Max(0,[math]::Min($source.PixelWidth - 1,$left))
        $top = [math]::Max(0,[math]::Min($source.PixelHeight - 1,$top))
        $width = [math]::Max(1,[math]::Min($source.PixelWidth - $left,$width))
        $height = [math]::Max(1,[math]::Min($source.PixelHeight - $top,$height))
        $metrics = Get-SnipObscureMetrics -Mode ([string]$Annotation.Kind) `
            -StrokeWidth ([double]$Annotation.StrokeWidth)
        try {
            $cropped = [System.Windows.Media.Imaging.CroppedBitmap]::new(
                $source, [System.Windows.Int32Rect]::new($left,$top,$width,$height))
            if ($cropped.CanFreeze) { $cropped.Freeze() }
        } catch {
            Write-Debug 'The obscured region could not be cropped from the capture.'
            return $null
        }
        $image = [System.Windows.Controls.Image]::new()
        $image.Width = $width
        $image.Height = $height
        $image.Stretch = [System.Windows.Media.Stretch]::Fill
        $isMosaic = [string]$Annotation.Kind -eq 'Pixelate'
        # Pixelate reduces by the mosaic block; Blur by its radius, which is the
        # same neighbourhood SnipPixels::BoxBlur averages over on export.
        $factor = [double][math]::Min(
            [int]$(if ($isMosaic) { $metrics.BlockSize } else { $metrics.BlurRadius }),
            [math]::Max(1,[math]::Min($width,$height)))
        $reduced = [System.Windows.Media.Imaging.TransformedBitmap]::new(
            $cropped, [System.Windows.Media.ScaleTransform]::new(
                1.0 / $factor, 1.0 / $factor))
        if ($reduced.CanFreeze) { $reduced.Freeze() }
        $image.Source = $reduced
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image,
            $(if ($isMosaic) {
                [System.Windows.Media.BitmapScalingMode]::NearestNeighbor
            } else {
                [System.Windows.Media.BitmapScalingMode]::Fant
            }))
        $clipHost = [System.Windows.Controls.Canvas]::new()
        $clipHost.Width = $width
        $clipHost.Height = $height
        $clipHost.ClipToBounds = $true
        $clipHost.IsHitTestVisible = $false
        $clipHost.Tag = [pscustomobject]@{ Role='Annotation'; Id=$Annotation.Id }
        $clipHost.Children.Add($image) | Out-Null
        $clipHost
    }.GetNewClosure()

    function script:Render-Annotations {
        $annotationLayer.Children.Clear()
        $ordered = @(& $getOrderedAnnotations)
        # Step numbers are positional, so they are resolved once per render from
        # the same ordering the visuals are built in.
        $stepNumbers = @{}
        foreach ($entry in @(Get-SnipStepNumbering -Annotations $ordered)) {
            $stepNumbers[[string]$entry.Id] = [int]$entry.Number
        }
        foreach ($a in $ordered) {
            $geometry = $a.Geometry
            $alpha = [int][math]::Round(255.0 * [math]::Max(0.0,[math]::Min(1.0,[double]$a.Opacity)))
            $brush = Get-PreviewWpfBrush -Color ([string]$a.Color) -Alpha $alpha
            switch ([string]$a.Kind) {
                { $_ -in @('Highlight','Rectangle','Ellipse') } {
                    $shape = if ($a.Kind -eq 'Ellipse') {
                        [System.Windows.Shapes.Ellipse]::new()
                    } else { [System.Windows.Shapes.Rectangle]::new() }
                    $shape.Width=[double]$geometry.Width; $shape.Height=[double]$geometry.Height
                    if ($a.Kind -eq 'Highlight') { $shape.Fill=$brush }
                    elseif ([bool](Get-SnipRecordValue -InputObject $a.Properties `
                        -Name Fill -Default $false)) {
                        $shape.Fill=$brush
                    }
                    $shape.Stroke=$brush
                    $shape.StrokeThickness=[double]$a.StrokeWidth
                    $shape.IsHitTestVisible=$false
                    $shape.Tag=[pscustomobject]@{ Role='Annotation'; Id=$a.Id }
                    [System.Windows.Controls.Canvas]::SetLeft($shape,[double]$geometry.X)
                    [System.Windows.Controls.Canvas]::SetTop($shape,[double]$geometry.Y)
                    $annotationLayer.Children.Add($shape) | Out-Null
                }
                { $_ -in @('Arrow','Line') } {
                    $line=[System.Windows.Shapes.Line]::new()
                    $line.X1=[double]$geometry.Start.X; $line.Y1=[double]$geometry.Start.Y
                    $line.X2=[double]$geometry.End.X; $line.Y2=[double]$geometry.End.Y
                    $line.Stroke=$brush; $line.StrokeThickness=[double]$a.StrokeWidth
                    $line.StrokeStartLineCap='Round'
                    $line.StrokeEndLineCap='Round'
                    $line.IsHitTestVisible=$false
                    $line.Tag=[pscustomobject]@{ Role='Annotation'; Id=$a.Id }
                    $arrowGeometry = if ($a.Kind -eq 'Arrow') {
                        Get-SnipArrowGeometry `
                            -StartX ([double]$geometry.Start.X) -StartY ([double]$geometry.Start.Y) `
                            -EndX ([double]$geometry.End.X) -EndY ([double]$geometry.End.Y) `
                            -StrokeWidth ([double]$a.StrokeWidth)
                    } else { $null }
                    if ($null -ne $arrowGeometry -and $arrowGeometry.Length -gt 0) {
                        $line.X2=$arrowGeometry.ShaftEndX
                        $line.Y2=$arrowGeometry.ShaftEndY
                    }
                    $annotationLayer.Children.Add($line) | Out-Null
                    if ($null -ne $arrowGeometry -and $arrowGeometry.Length -gt 0) {
                        $head=[System.Windows.Shapes.Polygon]::new()
                        $head.Fill=$brush
                        foreach ($vertex in @(
                            @($arrowGeometry.TipX,$arrowGeometry.TipY),
                            @($arrowGeometry.LeftX,$arrowGeometry.LeftY),
                            @($arrowGeometry.RightX,$arrowGeometry.RightY))) {
                            $head.Points.Add(
                                [System.Windows.Point]::new($vertex[0],$vertex[1]))
                        }
                        $head.IsHitTestVisible=$false
                        # Deliberately not Role='Annotation': the head is a second visual
                        # for one record, and the Z-order probes count records by role.
                        $head.Tag=[pscustomobject]@{ Role='ArrowHead'; Id=$a.Id }
                        $annotationLayer.Children.Add($head) | Out-Null
                    }
                }
                'Text' {
                    $textBlock=[System.Windows.Controls.TextBlock]::new()
                    $textBlock.Text=[string]$a.Properties.Text
                    $textBlock.FontFamily=[System.Windows.Media.FontFamily]::new('Segoe UI')
                    $textBlock.FontWeight=[System.Windows.FontWeights]::SemiBold
                    $textBlock.FontSize=[double]$a.Properties.FontSize
                    $textBlock.Foreground=$brush; $textBlock.IsHitTestVisible=$false
                    $textBlock.Tag=[pscustomobject]@{ Role='Annotation'; Id=$a.Id }
                    [System.Windows.Controls.Canvas]::SetLeft($textBlock,[double]$geometry.X)
                    [System.Windows.Controls.Canvas]::SetTop($textBlock,[double]$geometry.Y)
                    $annotationLayer.Children.Add($textBlock) | Out-Null
                }
                'Step' {
                    # Circle plus centred number in one visual, so the Z-order
                    # probes still count one Role='Annotation' element per record.
                    $diameter = [double]$geometry.Width
                    $badge=[System.Windows.Controls.Border]::new()
                    $badge.Width=$diameter; $badge.Height=[double]$geometry.Height
                    $badge.CornerRadius=[System.Windows.CornerRadius]::new($diameter/2.0)
                    $badge.Background=$brush
                    $badge.BorderBrush=[System.Windows.Media.Brushes]::White
                    $badge.BorderThickness=[System.Windows.Thickness]::new(
                        [math]::Max(2.0,[double]$a.StrokeWidth * 0.6))
                    $badge.IsHitTestVisible=$false
                    $badge.Tag=[pscustomobject]@{ Role='Annotation'; Id=$a.Id }
                    $numberText=[System.Windows.Controls.TextBlock]::new()
                    $stepNumber = if ($stepNumbers.ContainsKey([string]$a.Id)) {
                        $stepNumbers[[string]$a.Id]
                    } else { 1 }
                    $numberText.Text=[string]$stepNumber
                    $numberText.Foreground=[System.Windows.Media.Brushes]::White
                    $numberText.FontFamily=[System.Windows.Media.FontFamily]::new('Segoe UI')
                    $numberText.FontWeight=[System.Windows.FontWeights]::Bold
                    $numberText.FontSize=[double](Get-SnipRecordValue `
                        -InputObject $a.Properties -Name FontSize `
                        -Default ([math]::Max(11.0,$diameter * 0.5)))
                    $numberText.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Center
                    $numberText.VerticalAlignment=[System.Windows.VerticalAlignment]::Center
                    $badge.Child=$numberText
                    [System.Windows.Controls.Canvas]::SetLeft($badge,[double]$geometry.X)
                    [System.Windows.Controls.Canvas]::SetTop($badge,[double]$geometry.Y)
                    $annotationLayer.Children.Add($badge) | Out-Null
                }
                { $_ -in @('Blur','Pixelate') } {
                    $obscured = & $newObscureVisual $a
                    if ($null -ne $obscured) {
                        [System.Windows.Controls.Canvas]::SetLeft($obscured,[double]$geometry.X)
                        [System.Windows.Controls.Canvas]::SetTop($obscured,[double]$geometry.Y)
                        $annotationLayer.Children.Add($obscured) | Out-Null
                    }
                }
                default {
                    if ($geometry.Type -eq 'Points') {
                        $polyline=[System.Windows.Shapes.Polyline]::new()
                        foreach ($point in @($geometry.Points)) {
                            $polyline.Points.Add([System.Windows.Point]::new($point.X,$point.Y))
                        }
                        $polyline.Stroke=$brush; $polyline.StrokeThickness=[double]$a.StrokeWidth
                        $polyline.StrokeStartLineCap='Round'
                        $polyline.StrokeEndLineCap='Round'
                        $polyline.StrokeLineJoin='Round'
                        $polyline.IsHitTestVisible=$false
                        $polyline.Tag=[pscustomobject]@{ Role='Annotation'; Id=$a.Id }
                        $annotationLayer.Children.Add($polyline) | Out-Null
                    }
                }
            }
        }
        Render-PreviewInteraction
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
        $previewContext.UndoStack.Push((New-SnipEditorSnapshot `
            -Annotations $previewContext.Annotations `
            -CropRectangle $previewContext.CropRectangle))
        $previewContext.RedoStack.Clear()
        Trim-SnipStack $previewContext.UndoStack
    }

    function script:Restore-State {
        param($snapshot)
        $restored = New-SnipEditorSnapshot -Annotations $snapshot.Annotations `
            -CropRectangle $snapshot.CropRectangle
        $previewContext.Annotations.Clear()
        foreach ($a in $restored.Annotations) {
            [void]$previewContext.Annotations.Add($a)
        }
        $previewContext.CropRectangle = $restored.CropRectangle
        $state.CropRectangle = $previewContext.CropRectangle
        $previewContext.Draft = $null; $state.Draft = $null
        $previewContext.Interaction = $null
        if ($null -eq (Get-PreviewAnnotationById $previewContext.SelectedAnnotationId)) {
            $previewContext.SelectedAnnotationId = $null
            $state.SelectionId = $null
        }
        Render-Annotations
    }

    function script:Do-Undo {
        if ($previewContext.UndoStack.Count -eq 0) { return }
        $previewContext.RedoStack.Push((New-SnipEditorSnapshot `
            -Annotations $previewContext.Annotations `
            -CropRectangle $previewContext.CropRectangle))
        Trim-SnipStack $previewContext.RedoStack
        Restore-State $previewContext.UndoStack.Pop()
    }

    function script:Do-Redo {
        if ($previewContext.RedoStack.Count -eq 0) { return }
        $previewContext.UndoStack.Push((New-SnipEditorSnapshot `
            -Annotations $previewContext.Annotations `
            -CropRectangle $previewContext.CropRectangle))
        Trim-SnipStack $previewContext.UndoStack
        Restore-State $previewContext.RedoStack.Pop()
    }

    # Named color picker. Tests and the real swatch click handler both call
    # this. Also live-updates the foreground of any text box that is
    # currently being edited, so the user sees the color change immediately.
    $pickColor = {
        param([string]$Name)
        if (-not $palette.Contains($Name)) { return }
        $state.ActiveColor = $Name
        $activeRgb = $palette[$Name]
        $previewContext.ActiveColor = $Name
        $previewContext.ActiveColorHex = '#FF{0:X2}{1:X2}{2:X2}' -f `
            [int]$activeRgb.R, [int]$activeRgb.G, [int]$activeRgb.B
        # Repaint the property row's swatch in place. Rebuilding the whole row here
        # would tear down the very menu whose click is still being routed.
        foreach ($swatchKey in @('Color','StrokeColor')) {
            $swatchEntry = $previewContext.PropertyControls[$swatchKey]
            if ($null -eq $swatchEntry -or $null -eq $swatchEntry.Swatch) { continue }
            $swatchEntry.Swatch.Background = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor 255 $activeRgb.R $activeRgb.G $activeRgb.B))
        }
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
        # Update the active swatch in-place instead of rebuilding the bar.
        # Rebuilding would re-attach click handlers, and because $pickColor
        # self-reference inside its own body resolves to $null (the closure
        # captured it before assignment completed), the rebuilt handlers
        # would carry a dead reference. Keep the original handlers alive.
        $accentRingBrush = & $getSelectionBrush
        foreach ($ring in $colorBar.Children) {
            if ($ring.Tag -eq $Name) {
                $ring.BorderBrush = $accentRingBrush
            } else {
                $ring.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            }
        }
    }.GetNewClosure()

    # Build color swatches.
    # $pickColor is passed explicitly: `function script:` creates a new scope
    # that does NOT inherit Show-PreviewWindow's locals for closure purposes,
    # so a { & $pickColor ... }.GetNewClosure() inside this body would capture
    # $null. Accept it as a parameter so the closure has a real reference.
    function script:Build-ColorBar {
        param([scriptblock]$pickColor)
        $colorBar.Children.Clear()
        # Circular swatches with a 2px accent outline ring on the active one.
        # Fixed size (no jump) — the ring lives on an outer Border + padding.
        # The ring is the Windows accent, straight off the stock Fluent key.
        $accentRingBrush = & $getSelectionBrush
        foreach ($name in $palette.Keys) {
            $rgb      = $palette[$name]
            $isActive = ($state.ActiveColor -eq $name)

            $ring = New-Object System.Windows.Controls.Border
            $ring.Width  = 22
            $ring.Height = 22
            $ring.CornerRadius = New-Object System.Windows.CornerRadius 11
            $ring.Margin = New-Object System.Windows.Thickness 3, 0, 3, 0
            $ring.Padding = New-Object System.Windows.Thickness 2
            if ($isActive) {
                $ring.BorderBrush = $accentRingBrush
                $ring.BorderThickness = New-Object System.Windows.Thickness 2
            } else {
                $ring.BorderBrush = [System.Windows.Media.Brushes]::Transparent
                $ring.BorderThickness = New-Object System.Windows.Thickness 2
            }
            $ring.Cursor = [System.Windows.Input.Cursors]::Hand
            # Non-focusable so clicking a swatch while a text box is open
            # doesn't steal keyboard focus (which would fire LostFocus →
            # commit the text in the OLD color before we can update it).
            $ring.Focusable = $false
            $ring.ToolTip = $name
            $ring.Tag = $name

            $dot = New-Object System.Windows.Controls.Border
            $dot.Width  = 14
            $dot.Height = 14
            $dot.CornerRadius = New-Object System.Windows.CornerRadius 7
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor 255 $rgb.R $rgb.G $rgb.B))
            $ring.Child = $dot

            $ring.Add_MouseLeftButtonDown({ & $pickColor $this.Tag }.GetNewClosure())
            [void]$colorBar.Children.Add($ring)
        }
    }
    Build-ColorBar $pickColor
    foreach ($colorName in @('Yellow','Green','Pink','Blue','Orange','Red')) {
        $selectedColor = $colorName
        $studioShell.ColorMenuItems[$colorName].Add_Click({
            & $pickColor $selectedColor
        }.GetNewClosure())
        $studioShell.MoreColorMenuItems[$colorName].Add_Click({
            & $pickColor $selectedColor
            & $studioShell.CloseMoreMenu
        }.GetNewClosure())
    }

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
                   $arrowBtn.IsChecked     -or $textBtn.IsChecked -or
                   ([string]$previewContext.ActiveTool -in
                       @('Pen','Steps','BlurPixelate','Crop'))
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

    $invokeCopy = $null
    $invokeSave = $null
    $invokeNewSnip = $null
    $focusCanvas = { $highlightLayer.Focus() | Out-Null }.GetNewClosure()
    $platformActions = [pscustomobject]@{
        Copy=$null; Save=$null; NewSnip=$null; FocusCanvas=$focusCanvas
    }
    $applyPresentationEffect = {
        param($Effect)
        switch ([string]$Effect.Name) {
            'CancelDraft' {
                if ($previewContext.CancelDraft) { & $previewContext.CancelDraft }
            }
            'RefreshActiveChrome' {
                $activeTool = [string]$previewContext.PresentationState.ActiveTool
                foreach ($buttonName in @('Select','Crop','Pen','Steps')) {
                    Set-SnipPreviewActiveChrome `
                        -Control $previewContext.ToolControls[$buttonName] -Active $false | Out-Null
                }
                foreach ($splitName in @('ArrowLine','RectangleEllipse','BlurPixelate')) {
                    Set-SnipPreviewActiveChrome `
                        -Control $previewContext.SplitControls[$splitName].PrimaryButton `
                        -Active $false | Out-Null
                }
                switch ($activeTool) {
                    'Highlight' { $highlightBtn.IsChecked = $true }
                    'RectangleEllipse' { $rectBtn.IsChecked = $true }
                    'ArrowLine' { $arrowBtn.IsChecked = $true }
                    'Text' { $textBtn.IsChecked = $true }
                    default {
                        foreach ($legacyTool in $tools) { $legacyTool.IsChecked = $false }
                    }
                }
                $activeButton = switch ($activeTool) {
                    'Select' { $previewContext.ToolControls.Select }
                    'Crop' { $previewContext.ToolControls.Crop }
                    'Pen' { $previewContext.ToolControls.Pen }
                    'Steps' { $previewContext.ToolControls.Steps }
                    'ArrowLine' { $previewContext.SplitControls.ArrowLine.PrimaryButton }
                    'RectangleEllipse' { $previewContext.SplitControls.RectangleEllipse.PrimaryButton }
                    'BlurPixelate' { $previewContext.SplitControls.BlurPixelate.PrimaryButton }
                    default { $null }
                }
                if ($null -ne $activeButton) {
                    Set-SnipPreviewActiveChrome -Control $activeButton -Active $true | Out-Null
                }
            }
            'RefreshPropertyIsland' {
                & $previewContext.ApplyPropertyPresentation `
                    ([string]$previewContext.PresentationState.ActiveTool)
            }
            'RefreshResponsiveChrome' {
                & $previewContext.ApplyResponsivePresentation | Out-Null
            }
            'Copy' { & $platformActions.Copy ([bool]$Effect.CloseAfter) | Out-Null }
            'Save' { & $platformActions.Save }
            'Close' { & $previewContext.CommandRouter.CloseAction }
            'NewSnip' { & $platformActions.NewSnip }
            'FocusCanvas' { & $platformActions.FocusCanvas }
        }
    }.GetNewClosure()
    $setStudioTool = {
        param([string]$Tool)
        $previewContext.PresentationState.RecentTools =
            [string[]]@($previewContext.RecentTools)
        $result = Invoke-SnipPresentationIntent `
            -State $previewContext.PresentationState `
            -Intent ([pscustomobject]@{ Type='ActivateTool'; Tool=$Tool })
        foreach ($effect in @($result.Effects | Where-Object Name -eq 'CancelDraft')) {
            & $applyPresentationEffect $effect
        }
        $previewContext.PresentationState = $result.State
        $previewContext.ActiveTool = [string]$result.State.ActiveTool
        $state.ActiveStudioTool = [string]$result.State.ActiveTool
        $previewContext.RecentTools.Clear()
        foreach ($recentTool in @($result.State.RecentTools)) {
            $previewContext.RecentTools.Add([string]$recentTool) | Out-Null
        }
        foreach ($effect in @($result.Effects | Where-Object Name -ne 'CancelDraft')) {
            & $applyPresentationEffect $effect
        }
        # Pen/Steps/Blur/Crop are plain Buttons, so no Checked event reaches the
        # cursor updater; drive it from the one place every tool change lands.
        & $updateCursor
    }.GetNewClosure()
    $highlightBtn.Add_Checked({ & $setStudioTool 'Highlight' }.GetNewClosure())
    $textBtn.Add_Checked({ & $setStudioTool 'Text' }.GetNewClosure())
    $arrowBtn.Add_Checked({ & $setStudioTool 'ArrowLine' }.GetNewClosure())
    $rectBtn.Add_Checked({ & $setStudioTool 'RectangleEllipse' }.GetNewClosure())
    foreach ($legacySpec in @(
        [pscustomobject]@{ Button=$highlightBtn; Tool='Highlight' },
        [pscustomobject]@{ Button=$textBtn; Tool='Text' },
        [pscustomobject]@{ Button=$arrowBtn; Tool='ArrowLine' },
        [pscustomobject]@{ Button=$rectBtn; Tool='RectangleEllipse' })) {
        $legacyToolName=$legacySpec.Tool
        $legacySpec.Button.Add_Unchecked({
            $anyLegacy=$highlightBtn.IsChecked -or $rectBtn.IsChecked -or
                $arrowBtn.IsChecked -or $textBtn.IsChecked
            if(-not $anyLegacy -and $previewContext.ActiveTool -eq $legacyToolName){
                $previewContext.PresentationState.ActiveTool=''
                $previewContext.ActiveTool=$null
                $state.ActiveStudioTool=$null
            }
        }.GetNewClosure())
    }

    $previewContext.SplitControls.ArrowLine.PrimaryButton.Add_Click({
        & $setStudioTool 'ArrowLine'
    }.GetNewClosure())
    $previewContext.SplitControls.RectangleEllipse.PrimaryButton.Add_Click({
        & $setStudioTool 'RectangleEllipse'
    }.GetNewClosure())
    $previewContext.SplitControls.BlurPixelate.PrimaryButton.Add_Click({
        & $setStudioTool 'BlurPixelate'
    }.GetNewClosure())
    # Choosing an alternate shape restyles the primary button in place — glyph,
    # mnemonic label, accessible name and the menu's own check state — so the
    # band always reports which of the two shapes the next drag will draw.
    $applySplitSubtype = {
        param([string]$SplitName,[string]$Subtype)
        $split = $previewContext.SplitControls[$SplitName]
        $split.DefaultCommand = $Subtype
        $presentation = switch ($Subtype) {
            'Arrow' { @(0xE72A,'_Arrow') }
            'Line' { @(0xE738,'_Line') }
            'Rectangle' { @(0xE739,'_Rectangle') }
            'Ellipse' { @(0xEA3A,'_Ellipse') }
            'Blur' { @(0xEB42,'_Blur') }
            'Pixelate' { @(0xECA5,'_Pixelate') }
            default { $null }
        }
        if ($null -ne $presentation) {
            $split.Glyph.Text = [string][char][int]$presentation[0]
            $split.Label.Text = [string]$presentation[1]
        }
        [System.Windows.Automation.AutomationProperties]::SetName(
            $split.PrimaryButton, "$($previewContext.ToolMetadata[$SplitName].DisplayName) tool, selected subtype $Subtype")
        foreach ($entry in $split.MenuItems.GetEnumerator()) {
            $entry.Value.IsChecked = [string]$entry.Key -eq $Subtype
        }
    }.GetNewClosure()
    $previewContext.ApplySplitSubtype = $applySplitSubtype
    foreach ($splitSpec in @(
        [pscustomobject]@{ Split='ArrowLine'; Subtypes=@('Arrow','Line') },
        [pscustomobject]@{ Split='RectangleEllipse'; Subtypes=@('Rectangle','Ellipse') },
        [pscustomobject]@{ Split='BlurPixelate'; Subtypes=@('Blur','Pixelate') })) {
        $splitName = [string]$splitSpec.Split
        foreach ($subtype in $splitSpec.Subtypes) {
            $selectedSubtype = [string]$subtype
            $selectedSplit = $splitName
            $previewContext.SplitControls[$splitName].MenuItems[$subtype].Add_Click({
                & $applySplitSubtype $selectedSplit $selectedSubtype
                if ($null -ne $previewContext.SplitControls[$selectedSplit].CloseOptions) {
                    & $previewContext.SplitControls[$selectedSplit].CloseOptions
                }
                & $setStudioTool $selectedSplit
            }.GetNewClosure())
        }
    }
    $previewContext.ToolControls.Select.Add_Click({ & $setStudioTool 'Select' }.GetNewClosure())
    $previewContext.ToolControls.Crop.Add_Click({ & $setStudioTool 'Crop' }.GetNewClosure())
    $previewContext.ToolControls.Pen.Add_Click({ & $setStudioTool 'Pen' }.GetNewClosure())
    $previewContext.ToolControls.Steps.Add_Click({ & $setStudioTool 'Steps' }.GetNewClosure())
    foreach ($toolName in @('Highlight','ArrowLine','RectangleEllipse','Steps')) {
        $selectedTool = $toolName
        $studioShell.MoreMenuItems[$toolName].Add_Click({
            & $setStudioTool $selectedTool
        }.GetNewClosure())
    }
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
        $state.TemporaryPan = $false
        if (-not $state.Panning) {
            $highlightLayer.Cursor = [System.Windows.Input.Cursors]::Hand
            return
        }
        $state.Panning = $false
        try { $highlightLayer.ReleaseMouseCapture() } catch {}
        $highlightLayer.Cursor = [System.Windows.Input.Cursors]::Hand
    }.GetNewClosure()

    # Context owns annotation draft semantics and the active interaction.
    # The legacy state fields are kept as reference mirrors for older preview
    # helpers and the interactive harness; no caller writes them independently.
    $setAnnotationDraft = {
        param([AllowNull()]$Draft)
        $clearedAnnotation = $null -eq $Draft -and
            $null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Annotation'
        $previewContext.Draft = $Draft
        $state.Draft = $Draft
        if ($null -eq $Draft) {
            if ($null -ne $previewContext.Interaction -and
                $previewContext.Interaction.Kind -eq 'Annotation') {
                $previewContext.Interaction = $null
            }
            $state.Drawing = $false
            $state.DrawingTool = $null
            $state.AnchorCanvas = $null
            $state.DraftRect = $null
            if ($clearedAnnotation) {
                $previewContext.AnnotationDraftClearCount++
            }
            return
        }
        $previewContext.Interaction = [pscustomobject][ordered]@{
            Kind = 'Annotation'
            Mode = 'Create'
            Draft = $Draft
        }
        $state.Drawing = $true
        $state.DrawingTool = $Draft.Tool
        $state.AnchorCanvas = $Draft.Anchor
        $state.DraftRect = $Draft.Visual
    }.GetNewClosure()

    # Maps a draw-tool token onto the property-row bucket that owns its
    # Colour/Width/Opacity/Fill, and onto the annotation Kind it commits.
    $toolPropertyKey = {
        param([string]$Tool)
        switch ([string]$Tool) {
            'highlight' { 'Highlight' }
            'rect' { 'RectangleEllipse' }
            'ellipse' { 'RectangleEllipse' }
            'arrow' { 'ArrowLine' }
            'line' { 'ArrowLine' }
            'pen' { 'Pen' }
            'step' { 'Steps' }
            'blur' { 'BlurPixelate' }
            'pixelate' { 'BlurPixelate' }
            default { 'Select' }
        }
    }.GetNewClosure()
    $recordKindForTool = {
        param([string]$Tool)
        switch ([string]$Tool) {
            'highlight' { 'Highlight' }
            'rect' { 'Rectangle' }
            'ellipse' { 'Ellipse' }
            'arrow' { 'Arrow' }
            'line' { 'Line' }
            'pen' { 'Pen' }
            'step' { 'Step' }
            'blur' { 'Blur' }
            'pixelate' { 'Pixelate' }
            default { 'Rectangle' }
        }
    }.GetNewClosure()
    # The property row is the single source of truth for a new annotation's
    # width, opacity and fill. Context.ToolProperties is seeded with exactly the
    # constants the editor used before, so an untouched row draws as it always did.
    $getToolProperties = {
        param([string]$Tool)
        $key = & $toolPropertyKey $Tool
        $stored = $previewContext.ToolProperties[$key]
        [pscustomobject][ordered]@{
            Key = $key
            Width = if ($null -ne $stored) {
                [math]::Max(0.5,[double]$stored.Width)
            } else { 3.0 }
            Opacity = if ($null -ne $stored) {
                [math]::Max(0.0,[math]::Min(1.0,[double]$stored.Opacity))
            } else { 1.0 }
            Fill = if ($null -ne $stored) { [bool]$stored.Fill } else { $false }
        }
    }.GetNewClosure()

    $beginDraw = {
        param([string]$Tool, [System.Windows.Point]$P)
        $rgb = $palette[$state.ActiveColor]
        $visual = $null
        $kind = & $recordKindForTool $Tool
        $toolProperties = & $getToolProperties $Tool
        $strokeWidth = [double]$toolProperties.Width
        $opacity = [double]$toolProperties.Opacity
        $fillAlpha = [int][math]::Round(255.0 * $opacity)
        $geometry = if ($Tool -in @('arrow','line')) {
            [pscustomobject][ordered]@{
                Type='Line'
                Start=[pscustomobject]@{ X=$P.X; Y=$P.Y }
                End=[pscustomobject]@{ X=$P.X; Y=$P.Y }
            }
        } elseif ($Tool -eq 'pen') {
            [pscustomobject][ordered]@{
                Type='Points'
                Points=@([pscustomobject]@{ X=$P.X; Y=$P.Y })
            }
        } else {
            [pscustomobject][ordered]@{
                Type='Bounds'; X=$P.X; Y=$P.Y; Width=0.0; Height=0.0
            }
        }
        $headVisual = $null
        if ($Tool -in @('arrow','line')) {
            $arrowBrush = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor $fillAlpha $rgb.R $rgb.G $rgb.B))
            $line = New-Object System.Windows.Shapes.Line
            $line.X1 = $P.X; $line.Y1 = $P.Y; $line.X2 = $P.X; $line.Y2 = $P.Y
            $line.Stroke = $arrowBrush
            $line.StrokeThickness = $strokeWidth
            $line.StrokeStartLineCap = 'Round'
            $line.StrokeEndLineCap   = 'Round'
            $line.IsHitTestVisible = $false
            [void]$interactionLayer.Children.Add($line)
            if ($Tool -eq 'arrow') {
                # The draft carries the same filled head the committed arrow gets,
                # so the shape does not change under the pointer on mouse-up.
                $headVisual = New-Object System.Windows.Shapes.Polygon
                $headVisual.Fill = $arrowBrush
                $headVisual.IsHitTestVisible = $false
                [void]$interactionLayer.Children.Add($headVisual)
            }
            $visual = $line
        } elseif ($Tool -eq 'pen') {
            $stroke = New-Object System.Windows.Shapes.Polyline
            $stroke.Stroke = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor $fillAlpha $rgb.R $rgb.G $rgb.B))
            $stroke.StrokeThickness = $strokeWidth
            $stroke.StrokeStartLineCap = 'Round'
            $stroke.StrokeEndLineCap = 'Round'
            $stroke.StrokeLineJoin = 'Round'
            $stroke.IsHitTestVisible = $false
            $stroke.Points.Add([System.Windows.Point]::new($P.X,$P.Y))
            [void]$interactionLayer.Children.Add($stroke)
            $visual = $stroke
        } else {
            $shape = if ($Tool -eq 'ellipse') {
                New-Object System.Windows.Shapes.Ellipse
            } else {
                New-Object System.Windows.Shapes.Rectangle
            }
            if ($Tool -eq 'highlight' -or
                ($toolProperties.Fill -and $Tool -in @('rect','ellipse'))) {
                $shape.Fill = New-Object System.Windows.Media.SolidColorBrush(
                    (To-WpfColor $fillAlpha $rgb.R $rgb.G $rgb.B))
            }
            $shape.Stroke = New-Object System.Windows.Media.SolidColorBrush(
                (To-WpfColor 220 $rgb.R $rgb.G $rgb.B))
            $shape.StrokeThickness = $strokeWidth
            if ($Tool -in @('blur','pixelate')) {
                # Nothing is obscured until the drag commits, so the draft states
                # the region with a marching-ants outline rather than a fake blur.
                $dashes = [System.Windows.Media.DoubleCollection]::new()
                $dashes.Add(4.0); $dashes.Add(3.0)
                $shape.StrokeDashArray = $dashes
                $shape.Fill = New-Object System.Windows.Media.SolidColorBrush(
                    (To-WpfColor 40 $rgb.R $rgb.G $rgb.B))
            }
            $shape.IsHitTestVisible = $false
            [System.Windows.Controls.Canvas]::SetLeft($shape, $P.X)
            [System.Windows.Controls.Canvas]::SetTop($shape,  $P.Y)
            $shape.Width = 0; $shape.Height = 0
            [void]$interactionLayer.Children.Add($shape)
            $visual = $shape
        }
        $candidateProperties = [ordered]@{}
        if ($toolProperties.Fill -and $Tool -in @('rect','ellipse')) {
            $candidateProperties.Fill = $true
        }
        & $setAnnotationDraft ([pscustomobject][ordered]@{
            Kind='Annotation'; Tool=$Tool; RecordKind=$kind; Anchor=$P
            Candidate=[pscustomobject][ordered]@{
                Kind=$kind; Geometry=$geometry; Color=$state.ActiveColor
                StrokeWidth=$strokeWidth; Opacity=$opacity
                Properties=$candidateProperties
            }
            Visual=$visual
            HeadVisual=$headVisual
        })
        try { $highlightLayer.CaptureMouse() | Out-Null } catch {}
    }.GetNewClosure()

    $updateDraw = {
        param([System.Windows.Point]$P)
        $draft = $previewContext.Draft
        if ($null -eq $draft -or $draft.Kind -ne 'Annotation' -or
            $null -eq $draft.Visual) { return }
        if ($draft.Tool -eq 'pen') {
            # Sampled in canvas space so the min-distance filter stays honest at
            # any zoom; the record is converted to image space once on commit.
            $before = @($draft.Candidate.Geometry.Points).Count
            $draft.Candidate.Geometry = [pscustomobject][ordered]@{
                Type='Points'
                Points=@(Add-SnipFreehandPoint `
                    -Points @($draft.Candidate.Geometry.Points) `
                    -X $P.X -Y $P.Y -MinimumDistance 2.0)
            }
            $points = @($draft.Candidate.Geometry.Points)
            if ($points.Count -ne $before) {
                $last = $points[$points.Count - 1]
                $draft.Visual.Points.Add(
                    [System.Windows.Point]::new([double]$last.X,[double]$last.Y))
            }
            return
        }
        if ($draft.Tool -in @('arrow','line')) {
            $draft.Visual.X2 = $P.X
            $draft.Visual.Y2 = $P.Y
            $draft.Candidate.Geometry.End = [pscustomobject]@{ X=$P.X; Y=$P.Y }
            $headVisual = if ($null -ne $draft.PSObject.Properties['HeadVisual']) {
                $draft.HeadVisual
            } else { $null }
            if ($null -ne $headVisual) {
                $headVisual.Points.Clear()
                $draftArrow = Get-SnipArrowGeometry `
                    -StartX $draft.Visual.X1 -StartY $draft.Visual.Y1 `
                    -EndX $P.X -EndY $P.Y `
                    -StrokeWidth ([double]$draft.Candidate.StrokeWidth)
                if ($draftArrow.Length -gt 0) {
                    $draft.Visual.X2 = $draftArrow.ShaftEndX
                    $draft.Visual.Y2 = $draftArrow.ShaftEndY
                    foreach ($vertex in @(
                        @($draftArrow.TipX,$draftArrow.TipY),
                        @($draftArrow.LeftX,$draftArrow.LeftY),
                        @($draftArrow.RightX,$draftArrow.RightY))) {
                        $headVisual.Points.Add(
                            [System.Windows.Point]::new($vertex[0],$vertex[1]))
                    }
                }
            }
        } else {
            $r = Get-DragRectangle -AnchorX $draft.Anchor.X -AnchorY $draft.Anchor.Y `
                -CurrentX $P.X -CurrentY $P.Y
            [System.Windows.Controls.Canvas]::SetLeft($draft.Visual, $r.X)
            [System.Windows.Controls.Canvas]::SetTop($draft.Visual,  $r.Y)
            $draft.Visual.Width  = $r.Width
            $draft.Visual.Height = $r.Height
            $draft.Candidate.Geometry = [pscustomobject][ordered]@{
                Type='Bounds'; X=$r.X; Y=$r.Y; Width=$r.Width; Height=$r.Height
            }
        }
    }.GetNewClosure()

    $getNextAnnotationZ = {
        if ($previewContext.Annotations.Count -eq 0) { return 0.0 }
        $maximum = @($previewContext.Annotations | ForEach-Object {
            if ($null -ne $_.PSObject.Properties['Z']) { [double]$_.Z } else { 0.0 }
        } | Measure-Object -Maximum).Maximum
        [double]$maximum + 1.0
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
        $getNextAnnotationZL = $getNextAnnotationZ

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
            $textWidth = [math]::Max(1,[int][math]::Ceiling(
                $text.Length * $fontSize * 0.6))
            $textHeight = [math]::Max(1,[int][math]::Ceiling($fontSize * 1.3))
            [void]$stateL.Annotations.Add((New-SnipAnnotation -Kind Text `
                -Geometry ([pscustomobject]@{
                    Type='TextBounds'; X=$imgX; Y=$imgY
                    Width=$textWidth; Height=$textHeight
                }) -Color $stateL.ActiveColor -StrokeWidth 1 -Opacity 1 `
                -Properties ([ordered]@{ Text=$text; FontSize=$fontSize }) `
                -Z (& $getNextAnnotationZL)))
            Render-Annotations
        }.GetNewClosure()

        $tb.Add_KeyDown({
            if ($_.Key -eq 'Enter') {
                & $commit
                $textBtnL.IsChecked = $false
                $_.Handled = $true
            }
            elseif ($_.Key -eq 'Escape') {
                $commitGuard.Done = $true
                $stateL.EditingText = $false
                [void]$hlLayerL.Children.Remove($tb)
                try { [System.Windows.Input.Keyboard]::ClearFocus() } catch {}
                try { $hlLayerL.Focus() | Out-Null } catch {}
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
        $draft = $previewContext.Draft
        if ($null -eq $draft -or $draft.Kind -ne 'Annotation') { return }
        $visual = $draft.Visual
        if ($null -ne $visual) {
            [void]$interactionLayer.Children.Remove($visual)
        }
        if ($null -ne $draft.PSObject.Properties['HeadVisual'] -and
            $null -ne $draft.HeadVisual) {
            [void]$interactionLayer.Children.Remove($draft.HeadVisual)
        }
        & $setAnnotationDraft $null
        try { $highlightLayer.ReleaseMouseCapture() } catch {}
        $b = Get-DisplayedImageBounds
        if (-not $b) {
            Render-PreviewInteraction
            return
        }
        $candidate = $draft.Candidate
        if ($draft.Tool -in @('arrow','line')) {
            $start = $candidate.Geometry.Start
            $end = $candidate.Geometry.End
            $dx = $end.X - $start.X; $dy = $end.Y - $start.Y
            if ([math]::Sqrt($dx * $dx + $dy * $dy) -lt 6) {
                Render-PreviewInteraction
                return
            }
            $x1 = [int][math]::Round(($start.X - $b.X) / $b.Scale)
            $y1 = [int][math]::Round(($start.Y - $b.Y) / $b.Scale)
            $x2 = [int][math]::Round(($end.X - $b.X) / $b.Scale)
            $y2 = [int][math]::Round(($end.Y - $b.Y) / $b.Scale)
            Snapshot-State
            [void]$previewContext.Annotations.Add((New-SnipAnnotation `
                -Kind ([string]$candidate.Kind) `
                -Geometry ([pscustomobject]@{
                    Type='Line'
                    Start=[pscustomobject]@{ X=$x1; Y=$y1 }
                    End=[pscustomobject]@{ X=$x2; Y=$y2 }
                }) -Color $candidate.Color -StrokeWidth $candidate.StrokeWidth `
                -Opacity $candidate.Opacity `
                -Properties ([ordered]@{}) -Z (& $getNextAnnotationZ)))
            Render-Annotations
            return
        }
        if ($draft.Tool -eq 'pen') {
            $canvasPoints = @($candidate.Geometry.Points)
            $imagePoints = [System.Collections.ArrayList]::new()
            foreach ($point in $canvasPoints) {
                [void]$imagePoints.Add([pscustomobject]@{
                    X = [int][math]::Max(0,[math]::Min($Bitmap.Width - 1,
                        [math]::Round(([double]$point.X - $b.X) / $b.Scale)))
                    Y = [int][math]::Max(0,[math]::Min($Bitmap.Height - 1,
                        [math]::Round(([double]$point.Y - $b.Y) / $b.Scale)))
                })
            }
            # One tap is a dot, not a stroke; drop it rather than store a
            # zero-extent path the selection maths cannot resize.
            if ($imagePoints.Count -lt 2) {
                Render-PreviewInteraction
                return
            }
            Snapshot-State
            [void]$previewContext.Annotations.Add((New-SnipAnnotation -Kind Pen `
                -Geometry ([pscustomobject]@{
                    Type='Points'; Points=@($imagePoints.ToArray())
                }) -Color $candidate.Color -StrokeWidth $candidate.StrokeWidth `
                -Opacity $candidate.Opacity `
                -Properties ([ordered]@{}) -Z (& $getNextAnnotationZ)))
            Render-Annotations
            return
        }
        if ($candidate.Geometry.Width -lt 3 -or $candidate.Geometry.Height -lt 3) {
            Render-PreviewInteraction
            return
        }
        $canvasX = [double]$candidate.Geometry.X
        $canvasY = [double]$candidate.Geometry.Y
        $rawX = [int][math]::Round(($canvasX - $b.X) / $b.Scale)
        $rawY = [int][math]::Round(($canvasY - $b.Y) / $b.Scale)
        $rawW = [int][math]::Round($candidate.Geometry.Width  / $b.Scale)
        $rawH = [int][math]::Round($candidate.Geometry.Height / $b.Scale)
        $clamped = Get-ClampedAnnotationRect -X $rawX -Y $rawY -Width $rawW -Height $rawH `
            -BitmapWidth $Bitmap.Width -BitmapHeight $Bitmap.Height
        Snapshot-State
        [void]$previewContext.Annotations.Add((New-SnipAnnotation `
            -Kind $candidate.Kind `
            -Geometry ([pscustomobject]@{
                Type='Bounds'; X=$clamped.X; Y=$clamped.Y
                Width=$clamped.Width; Height=$clamped.Height
            }) -Color $candidate.Color -StrokeWidth $candidate.StrokeWidth `
            -Opacity $candidate.Opacity -Properties $candidate.Properties `
            -Z (& $getNextAnnotationZ)))
        Render-Annotations
    }.GetNewClosure()

    # Steps is a click tool, not a drag tool: one click drops one badge. The
    # badge carries no number of its own — Get-SnipStepNumbering derives it from
    # creation order at render time, so deleting or undoing one renumbers the rest.
    $placeStep = {
        param([System.Windows.Point]$P)
        $b = Get-DisplayedImageBounds
        if (-not $b) { return $null }
        $toolProperties = & $getToolProperties 'step'
        $centerX = ([double]$P.X - $b.X) / $b.Scale
        $centerY = ([double]$P.Y - $b.Y) / $b.Scale
        $badge = Get-SnipStepBadgeGeometry -CenterX $centerX -CenterY $centerY `
            -StrokeWidth ([double]$toolProperties.Width)
        $clamped = Get-ClampedAnnotationRect -X $badge.X -Y $badge.Y `
            -Width $badge.Width -Height $badge.Height `
            -BitmapWidth $Bitmap.Width -BitmapHeight $Bitmap.Height
        Snapshot-State
        $record = New-SnipAnnotation -Kind Step -Geometry ([pscustomobject]@{
                Type='StepBounds'; X=$clamped.X; Y=$clamped.Y
                Width=$clamped.Width; Height=$clamped.Height
            }) -Color $state.ActiveColor `
            -StrokeWidth ([double]$toolProperties.Width) `
            -Opacity ([double]$toolProperties.Opacity) `
            -Properties ([ordered]@{ FontSize=[int]$badge.FontSize }) `
            -Z (& $getNextAnnotationZ)
        [void]$previewContext.Annotations.Add($record)
        Render-Annotations
        $record
    }.GetNewClosure()
    $previewContext.PlaceStep = $placeStep

    $setSelectedAnnotation = {
        param([AllowNull()][string]$Id)
        if (-not [string]::IsNullOrWhiteSpace($Id) -and
            $null -eq (Get-PreviewAnnotationById $Id)) {
            $Id = $null
        }
        $previewContext.SelectedAnnotationId = $Id
        $state.SelectionId = $Id
        $win.FindName('DuplicateBtn').IsEnabled = `
            -not [string]::IsNullOrWhiteSpace($Id)
        $win.FindName('DeleteBtn').IsEnabled = `
            -not [string]::IsNullOrWhiteSpace($Id)
        if ($previewContext.ActiveTool -eq 'Select') {
            Set-SnipPropertyIsland -Context $previewContext -Tool Select | Out-Null
        }
        Render-PreviewInteraction
        $Id
    }.GetNewClosure()

    $getResizeHandleAt = {
        param([System.Windows.Point]$Point)
        $annotation = Get-PreviewAnnotationById $previewContext.SelectedAnnotationId
        if ($null -eq $annotation) { return $null }
        $zoom = if ($layoutScale.ScaleX -gt 0) { [double]$layoutScale.ScaleX } else { 1.0 }
        $tolerance = 7.0 / $zoom
        if ($annotation.Geometry.Type -eq 'Line') {
            foreach ($endpoint in @(
                [pscustomobject]@{ Name='Start'; Point=$annotation.Geometry.Start },
                [pscustomobject]@{ Name='End'; Point=$annotation.Geometry.End })) {
                $dx=$Point.X-[double]$endpoint.Point.X
                $dy=$Point.Y-[double]$endpoint.Point.Y
                if ([math]::Sqrt($dx*$dx+$dy*$dy) -le $tolerance) {
                    return $endpoint.Name
                }
            }
            return $null
        }
        $bounds = Get-PreviewAnnotationBounds $annotation
        if ($null -eq $bounds) { return $null }
        $centers = [ordered]@{
            TopLeft=@(([double]$bounds.X),([double]$bounds.Y))
            Top=@(([double]$bounds.X+([double]$bounds.Width/2.0)),([double]$bounds.Y))
            TopRight=@(([double]$bounds.X+[double]$bounds.Width),([double]$bounds.Y))
            Right=@(([double]$bounds.X+[double]$bounds.Width),
                ([double]$bounds.Y+([double]$bounds.Height/2.0)))
            BottomRight=@(([double]$bounds.X+[double]$bounds.Width),
                ([double]$bounds.Y+[double]$bounds.Height))
            Bottom=@(([double]$bounds.X+([double]$bounds.Width/2.0)),
                ([double]$bounds.Y+[double]$bounds.Height))
            BottomLeft=@(([double]$bounds.X),([double]$bounds.Y+[double]$bounds.Height))
            Left=@(([double]$bounds.X),
                ([double]$bounds.Y+([double]$bounds.Height/2.0)))
        }
        foreach ($entry in $centers.GetEnumerator()) {
            $dx=$Point.X-[double]$entry.Value[0]
            $dy=$Point.Y-[double]$entry.Value[1]
            if ([math]::Sqrt($dx*$dx+$dy*$dy) -le $tolerance) {
                return [string]$entry.Key
            }
        }
        $null
    }.GetNewClosure()

    $beginSelectGesture = {
        param([System.Windows.Point]$Point)
        $highlightLayer.Focus() | Out-Null
        $handle = & $getResizeHandleAt $Point
        $selectedId = $previewContext.SelectedAnnotationId
        if ($null -eq $handle) {
            $previewContext.LastHitRoute = 'Find-SnipAnnotation'
            $selectedId = Select-SnipAnnotation -Annotations $previewContext.Annotations `
                -ImageX $Point.X -ImageY $Point.Y `
                -Tolerance (6.0/[math]::Max(0.05,[double]$layoutScale.ScaleX))
            if ([string]::IsNullOrWhiteSpace([string]$selectedId)) {
                & $setSelectedAnnotation $null | Out-Null
                $previewContext.Interaction = $null
                return
            }
            & $setSelectedAnnotation $selectedId | Out-Null
        }
        $original = Get-PreviewAnnotationById $selectedId
        if ($null -eq $original) { return }
        $previewContext.Interaction = [pscustomobject][ordered]@{
            Kind='Select'; Mode=if($null -ne $handle){'Resize'}else{'Move'}
            Handle=$handle; Start=$Point
            Original=(Copy-SnipAnnotation -Annotation $original)
            Candidate=(Copy-SnipAnnotation -Annotation $original)
            Changed=$false
        }
        try { $highlightLayer.CaptureMouse() | Out-Null } catch {}
        Render-PreviewInteraction
    }.GetNewClosure()

    $updateSelectGesture = {
        param([System.Windows.Point]$Point)
        $interaction = $previewContext.Interaction
        if ($null -eq $interaction -or $interaction.Kind -ne 'Select') { return }
        $deltaX=[int][math]::Round($Point.X-[double]$interaction.Start.X)
        $deltaY=[int][math]::Round($Point.Y-[double]$interaction.Start.Y)
        try {
            $candidate = if ($interaction.Mode -eq 'Resize') {
                Resize-SnipAnnotation -Annotation $interaction.Original `
                    -Handle $interaction.Handle -DeltaX $deltaX -DeltaY $deltaY `
                    -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height
            } else {
                Move-SnipAnnotation -Annotation $interaction.Original `
                    -DeltaX $deltaX -DeltaY $deltaY `
                    -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height
            }
        } catch [System.ArgumentException] {
            # A transient pointer sample may exactly collapse a Line or Points
            # extent. Keep the last valid immutable candidate; release or a
            # later valid sample remains safe and unexpected faults still escape.
            Render-PreviewInteraction
            return
        }
        $interaction.Candidate = $candidate
        $interaction.Changed = -not (Test-PreviewAnnotationEqual `
            $interaction.Original $candidate)
        Render-PreviewInteraction
    }.GetNewClosure()

    $completeSelectGesture = {
        $interaction = $previewContext.Interaction
        if ($null -eq $interaction -or $interaction.Kind -ne 'Select') { return }
        $previewContext.Interaction = $null
        try { $highlightLayer.ReleaseMouseCapture() } catch {}
        if ($interaction.Changed) {
            $index = Get-PreviewAnnotationIndexById $interaction.Original.Id
            if ($index -ge 0) {
                Snapshot-State
                $previewContext.Annotations[$index] =
                    Copy-SnipAnnotation -Annotation $interaction.Candidate
            }
        }
        Render-Annotations
    }.GetNewClosure()

    $cancelSelectGesture = {
        if ($null -ne $previewContext.Interaction -and
            $previewContext.Interaction.Kind -eq 'Select') {
            $previewContext.Interaction = $null
            try { $highlightLayer.ReleaseMouseCapture() } catch {}
            Render-PreviewInteraction
        }
    }.GetNewClosure()

    $getCropHandleAt = {
        param([System.Windows.Point]$Point)
        $crop = if ($null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Crop') {
            $previewContext.Draft.Candidate
        } else { $previewContext.CropRectangle }
        if ($null -eq $crop) { return $null }
        $zoom=[math]::Max(0.05,[double]$layoutScale.ScaleX)
        $tolerance=7.0/$zoom
        $centers=[ordered]@{
            TopLeft=@(([double]$crop.X),([double]$crop.Y))
            Top=@(([double]$crop.X+([double]$crop.Width/2.0)),([double]$crop.Y))
            TopRight=@(([double]$crop.X+[double]$crop.Width),([double]$crop.Y))
            Right=@(([double]$crop.X+[double]$crop.Width),
                ([double]$crop.Y+([double]$crop.Height/2.0)))
            BottomRight=@(([double]$crop.X+[double]$crop.Width),
                ([double]$crop.Y+[double]$crop.Height))
            Bottom=@(([double]$crop.X+([double]$crop.Width/2.0)),
                ([double]$crop.Y+[double]$crop.Height))
            BottomLeft=@(([double]$crop.X),([double]$crop.Y+[double]$crop.Height))
            Left=@(([double]$crop.X),
                ([double]$crop.Y+([double]$crop.Height/2.0)))
        }
        foreach($entry in $centers.GetEnumerator()){
            $dx=$Point.X-[double]$entry.Value[0]
            $dy=$Point.Y-[double]$entry.Value[1]
            if([math]::Sqrt($dx*$dx+$dy*$dy) -le $tolerance){return [string]$entry.Key}
        }
        $null
    }.GetNewClosure()

    $beginCropDraft = {
        param([System.Windows.Point]$Point)
        $highlightLayer.Focus() | Out-Null
        $resizeHandle=& $getCropHandleAt $Point
        if($null -ne $resizeHandle){
            $existing=if($null -ne $previewContext.Draft -and
                $previewContext.Draft.Kind -eq 'Crop'){
                $previewContext.Draft.Candidate
            }else{$previewContext.CropRectangle}
            $baseCandidate=[pscustomobject]@{
                X=[int]$existing.X;Y=[int]$existing.Y
                Width=[int]$existing.Width;Height=[int]$existing.Height
            }
            $previewContext.Draft=[pscustomobject][ordered]@{
                Kind='Crop';Anchor=$Point;BaseCandidate=$baseCandidate
                OriginalCandidate=$baseCandidate;Candidate=(Get-SnipCropRectangle `
                    -Candidate $baseCandidate -SourceWidth $Bitmap.Width `
                    -SourceHeight $Bitmap.Height -Preset Free)
                Preset=$previewContext.ToolProperties.Crop.Preset
                ResizeHandle=$resizeHandle
            }
            $state.Draft=$previewContext.Draft
            $previewContext.Interaction=[pscustomobject]@{Kind='Crop'}
            try{$highlightLayer.CaptureMouse()|Out-Null}catch{}
            Render-PreviewInteraction
            return
        }
        $anchor = [System.Windows.Point]::new(
            [math]::Max(0,[math]::Min($Bitmap.Width-1,[int][math]::Round($Point.X))),
            [math]::Max(0,[math]::Min($Bitmap.Height-1,[int][math]::Round($Point.Y))))
        $baseCandidate = [pscustomobject]@{
            X=[int]$anchor.X; Y=[int]$anchor.Y; Width=1; Height=1
        }
        $candidate = Get-SnipCropRectangle -Candidate $baseCandidate `
            -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height `
            -Preset $previewContext.ToolProperties.Crop.Preset
        $previewContext.Draft = [pscustomobject][ordered]@{
            Kind='Crop'; Anchor=$anchor; BaseCandidate=$baseCandidate
            Candidate=$candidate; Preset=$previewContext.ToolProperties.Crop.Preset
        }
        $state.Draft = $previewContext.Draft
        $previewContext.Interaction = [pscustomobject]@{ Kind='Crop' }
        try { $highlightLayer.CaptureMouse() | Out-Null } catch {}
        Render-PreviewInteraction
    }.GetNewClosure()

    $updateCropDraft = {
        param([System.Windows.Point]$Point)
        $draft = $previewContext.Draft
        if ($null -eq $draft -or $draft.Kind -ne 'Crop') { return }
        if($null -ne $draft.PSObject.Properties['ResizeHandle'] -and
            -not [string]::IsNullOrWhiteSpace([string]$draft.ResizeHandle)){
            $deltaX=[int][math]::Round($Point.X-[double]$draft.Anchor.X)
            $deltaY=[int][math]::Round($Point.Y-[double]$draft.Anchor.Y)
            $left=[int]$draft.OriginalCandidate.X
            $top=[int]$draft.OriginalCandidate.Y
            $right=$left+[int]$draft.OriginalCandidate.Width
            $bottom=$top+[int]$draft.OriginalCandidate.Height
            switch([string]$draft.ResizeHandle){
                'TopLeft'{$left+=$deltaX;$top+=$deltaY}
                'Top'{$top+=$deltaY}
                'TopRight'{$right+=$deltaX;$top+=$deltaY}
                'Right'{$right+=$deltaX}
                'BottomRight'{$right+=$deltaX;$bottom+=$deltaY}
                'Bottom'{$bottom+=$deltaY}
                'BottomLeft'{$left+=$deltaX;$bottom+=$deltaY}
                'Left'{$left+=$deltaX}
            }
            $raw=[pscustomobject]@{
                X=$left;Y=$top;Width=($right-$left);Height=($bottom-$top)
            }
            $draft.BaseCandidate=$raw
            $draft.Candidate=Get-SnipCropRectangle -Candidate $raw `
                -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height `
                -Preset $draft.Preset
            Render-PreviewInteraction
            return
        }
        $rectangle = Get-DragRectangle -AnchorX $draft.Anchor.X -AnchorY $draft.Anchor.Y `
            -CurrentX $Point.X -CurrentY $Point.Y
        if ($rectangle.Width -le 0 -or $rectangle.Height -le 0) { return }
        $draft.BaseCandidate = [pscustomobject]@{
            X=[int][math]::Round($rectangle.X); Y=[int][math]::Round($rectangle.Y)
            Width=[int][math]::Round($rectangle.Width)
            Height=[int][math]::Round($rectangle.Height)
        }
        $draft.Candidate = Get-SnipCropRectangle -Candidate $draft.BaseCandidate `
            -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height `
            -Preset $draft.Preset
        Render-PreviewInteraction
    }.GetNewClosure()

    $selectCropPreset = {
        param([ValidateSet('Free','Original','1:1','4:3','16:9')][string]$Preset)
        $previewContext.ToolProperties.Crop.Preset = $Preset
        $baseCandidate = if ($null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Crop') {
            $previewContext.Draft.BaseCandidate
        } elseif ($null -ne $previewContext.CropRectangle) {
            $previewContext.CropRectangle
        } else { $null }
        $candidate = Get-SnipCropRectangle -Candidate $baseCandidate `
            -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height -Preset $Preset
        $previewContext.Draft = [pscustomobject][ordered]@{
            Kind='Crop'; Anchor=$null; BaseCandidate=$baseCandidate
            Candidate=$candidate; Preset=$Preset
        }
        $state.Draft = $previewContext.Draft
        foreach ($item in @($previewContext.PropertyControls.Aspect.MenuItems.Values)) {
            $item.IsChecked = [string]$item.Header -eq $Preset
        }
        Render-PreviewInteraction
    }.GetNewClosure()

    $cancelCropDraft = {
        if ($null -ne $previewContext.Draft -and $previewContext.Draft.Kind -eq 'Crop') {
            $previewContext.Draft = $null; $state.Draft = $null
            $previewContext.Interaction = $null
            try { $highlightLayer.ReleaseMouseCapture() } catch {}
            Render-PreviewInteraction
        }
    }.GetNewClosure()

    $applyCropDraft = {
        $draft = $previewContext.Draft
        if ($null -eq $draft -or $draft.Kind -ne 'Crop' -or $null -eq $draft.Candidate) {
            return
        }
        $applied = Set-SnipCrop -Action Apply -Candidate $draft.Candidate `
            -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height `
            -Preset $draft.Preset
        if (-not (Test-PreviewCropEqual $previewContext.CropRectangle $applied)) {
            Snapshot-State
            $previewContext.CropRectangle = $applied
            $state.CropRectangle = $applied
        }
        $previewContext.Draft = $null; $state.Draft = $null
        $previewContext.Interaction = $null
        try { $highlightLayer.ReleaseMouseCapture() } catch {}
        Render-PreviewInteraction
    }.GetNewClosure()

    $resetCrop = {
        & $cancelCropDraft
        if ($null -eq $previewContext.CropRectangle) { return }
        Snapshot-State
        $previewContext.CropRectangle = Set-SnipCrop -Action Reset `
            -Candidate $previewContext.CropRectangle `
            -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height
        $state.CropRectangle = $previewContext.CropRectangle
        Render-PreviewInteraction
    }.GetNewClosure()

    $deleteSelection = {
        $index = Get-PreviewAnnotationIndexById $previewContext.SelectedAnnotationId
        if ($index -lt 0) {
            & $setSelectedAnnotation $null | Out-Null
            return
        }
        Snapshot-State
        $previewContext.Annotations.RemoveAt($index)
        & $setSelectedAnnotation $null | Out-Null
        Render-Annotations
    }.GetNewClosure()

    $duplicateSelection = {
        $source = Get-PreviewAnnotationById $previewContext.SelectedAnnotationId
        if ($null -eq $source) { return $null }
        $offsetCopy = Move-SnipAnnotation -Annotation $source `
            -DeltaX 12 -DeltaY 12 -SourceWidth $Bitmap.Width `
            -SourceHeight $Bitmap.Height
        $duplicate = New-SnipAnnotation -Kind $source.Kind `
            -Geometry $offsetCopy.Geometry -Color $source.Color `
            -StrokeWidth $source.StrokeWidth -Opacity $source.Opacity `
            -Properties $source.Properties -Z (& $getNextAnnotationZ)
        Snapshot-State
        $previewContext.Annotations.Add($duplicate) | Out-Null
        & $setSelectedAnnotation $duplicate.Id | Out-Null
        Render-Annotations
        $duplicate
    }.GetNewClosure()

    $applySelectionProperty = {
        param([ValidateSet('Position','Size')][string]$Name,[string]$Text)
        if($Text -notmatch '^\s*(-?\d+)\s*[,x×]\s*(-?\d+)\s*$'){return $false}
        $first=[int]$Matches[1];$second=[int]$Matches[2]
        $current=Get-PreviewAnnotationById $previewContext.SelectedAnnotationId
        if($null -eq $current){return $false}
        $bounds=Get-PreviewAnnotationBounds $current
        if($null -eq $bounds){return $false}
        $updated=if($Name -eq 'Position'){
            Move-SnipAnnotation -Annotation $current `
                -DeltaX ($first-[int]$bounds.X) -DeltaY ($second-[int]$bounds.Y) `
                -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height
        }elseif($current.Geometry.Type -ne 'Line'){
            Resize-SnipAnnotation -Annotation $current -Handle BottomRight `
                -DeltaX ($first-[int]$bounds.Width) `
                -DeltaY ($second-[int]$bounds.Height) `
                -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height
        }else{return $false}
        if(Test-PreviewAnnotationEqual $current $updated){return $false}
        Snapshot-State
        $index=Get-PreviewAnnotationIndexById $current.Id
        if($index -ge 0){$previewContext.Annotations[$index]=$updated}
        Render-Annotations
        $true
    }.GetNewClosure()

    $cancelDraft = {
        if ($null -ne $previewContext.Interaction -and
            $previewContext.Interaction.Kind -eq 'Select') {
            & $cancelSelectGesture
            return
        }
        if ($null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Annotation') {
            $visual = $previewContext.Draft.Visual
            if ($null -ne $visual) {
                [void]$interactionLayer.Children.Remove($visual)
            }
            & $setAnnotationDraft $null
            try { $highlightLayer.ReleaseMouseCapture() } catch {}
            Render-PreviewInteraction
            return
        }
        if ($null -ne $previewContext.Draft -and $previewContext.Draft.Kind -eq 'Crop') {
            & $cancelCropDraft
            return
        }
    }.GetNewClosure()
    $previewContext.SelectCropPreset = $selectCropPreset
    $previewContext.ApplyCrop = $applyCropDraft
    $previewContext.ResetCrop = $resetCrop
    $previewContext.CancelDraft = $cancelDraft
    $previewContext.DeleteSelection = $deleteSelection
    $previewContext.DuplicateSelection = $duplicateSelection
    $previewContext.ApplySelectionProperty = $applySelectionProperty

    # ---- Mouse interactions on the highlight layer ----
    # Named dispatcher for MouseLeftButtonDown so tests can drive it with
    # synthetic points. Event handler below is a thin wrapper.
    $handleMouseDown = {
        param(
            [System.Windows.Point]$HlPoint,
            [System.Windows.Point]$SvPoint
        )
        if ($state.EditingText) { return }
        if ($state.Panning) { return }
        $b = Get-DisplayedImageBounds; if (-not $b) { return }
        $p = $HlPoint
        if ($p.X -lt $b.X -or $p.Y -lt $b.Y -or
            $p.X -gt $b.X + $b.W -or $p.Y -gt $b.Y + $b.H) { return }

        switch ([string]$previewContext.ActiveTool) {
            'Select' { & $beginSelectGesture $p; return }
            'Crop' { & $beginCropDraft $p; return }
            'Steps' { & $placeStep $p | Out-Null; return }
        }

        $tool = $null
        if     ($highlightBtn.IsChecked) { $tool = 'highlight' }
        elseif ($rectBtn.IsChecked)      {
            # The split's DefaultCommand decides which of the two shapes the
            # shared toggle draws; the toggle itself only says "this pair".
            $tool = if ($previewContext.SplitControls.RectangleEllipse.DefaultCommand -eq
                'Ellipse') { 'ellipse' } else { 'rect' }
        }
        elseif ($arrowBtn.IsChecked)     {
            $tool = if ($previewContext.SplitControls.ArrowLine.DefaultCommand -eq
                'Line') { 'line' } else { 'arrow' }
        }
        elseif ($previewContext.ActiveTool -eq 'Pen') { $tool = 'pen' }
        elseif ($previewContext.ActiveTool -eq 'BlurPixelate') {
            $tool = if ($previewContext.SplitControls.BlurPixelate.DefaultCommand -eq
                'Pixelate') { 'pixelate' } else { 'blur' }
        }

        if ($tool) {
            & $beginDraw $tool $p
        }
        elseif ($textBtn.IsChecked) {
            & $openText $p
        } elseif ([string]::IsNullOrWhiteSpace([string]$previewContext.ActiveTool)) {
            & $beginPan $SvPoint
        }
    }.GetNewClosure()

    $handleMouseMove = {
        param(
            [System.Windows.Point]$HlPoint,
            [System.Windows.Point]$SvPoint
        )
        if ($state.Panning) { & $updatePan $SvPoint; return }
        if ($null -ne $previewContext.Interaction) {
            switch ($previewContext.Interaction.Kind) {
                'Select' { & $updateSelectGesture $HlPoint; return }
                'Crop' { & $updateCropDraft $HlPoint; return }
            }
        }
        if ($null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Annotation') {
            & $updateDraw $HlPoint
        }
    }.GetNewClosure()

    $handleMouseUp = {
        param([System.Windows.Point]$HlPoint)
        if ($state.Panning) {
            if (-not $state.TemporaryPan) { & $endPan }
            return
        }
        if ($null -ne $previewContext.Interaction) {
            switch ($previewContext.Interaction.Kind) {
                'Select' { & $completeSelectGesture; return }
                'Crop' {
                    & $updateCropDraft $HlPoint
                    $previewContext.Interaction = $null
                    try { $highlightLayer.ReleaseMouseCapture() } catch {}
                    Render-PreviewInteraction
                    return
                }
            }
        }
        if ($null -ne $previewContext.Draft -and
            $previewContext.Draft.Kind -eq 'Annotation') {
            & $finishDraw
        }
    }.GetNewClosure()

    $highlightLayer.Add_MouseLeftButtonDown({
        & $handleMouseDown ($_.GetPosition($highlightLayer)) ($_.GetPosition($scroller))
        if ($state.Panning -or $state.Drawing -or $state.EditingText -or
            $null -ne $previewContext.Interaction -or $null -ne $previewContext.Draft) {
            $_.Handled = $true
        }
    }.GetNewClosure())

    $highlightLayer.Add_MouseMove({
        $isSynthetic = $_.GetType().Name -eq 'SnipTestMouseEventArgs'
        if ($state.TemporaryPan -or $isSynthetic -or
            $_.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            & $handleMouseMove ($_.GetPosition($highlightLayer)) ($_.GetPosition($scroller))
        }
    }.GetNewClosure())

    $highlightLayer.Add_MouseLeftButtonUp({
        & $handleMouseUp ($_.GetPosition($highlightLayer))
    }.GetNewClosure())
    $highlightLayer.Add_LostMouseCapture({
        if ($null -ne $previewContext.Interaction -or
            ($null -ne $previewContext.Draft -and
                $previewContext.Draft.Kind -eq 'Annotation')) {
            & $cancelDraft
        } elseif ($state.Panning) {
            & $endPan
        }
    }.GetNewClosure())

    # Re-render on resize (ImageHost growing/shrinking with zoom)
    $imageHost.Add_SizeChanged({ Render-Annotations })

    # Hit-test helper: returns the topmost annotation index under a canvas point, or -1
    function script:Find-AnnotationAt {
        param([double]$CanvasX, [double]$CanvasY)
        $hit = Find-SnipAnnotation -Annotations $state.Annotations `
            -ImageX $CanvasX -ImageY $CanvasY -Tolerance 6
        $previewContext.LastHitRoute = 'Find-SnipAnnotation'
        if ($null -eq $hit) { return -1 }
        Get-PreviewAnnotationIndexById $hit.Id
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
        $targetId = [string]$state.Annotations[$idx].Id

        if ($null -ne $previewContext.AnnotationMenuControl) {
            & $previewContext.AnnotationMenuControl.Disconnect
            $previewContext.TransientMenus.Remove(
                $previewContext.AnnotationMenuControl)
            $previewContext.AnnotationMenuControl = $null
        }

        $menu = New-Object System.Windows.Controls.ContextMenu
        $menu.StaysOpen = $true
        $menuBindings = [System.Collections.ArrayList]::new()
        foreach ($name in $paletteL.Keys) {
            $rgb = $paletteL[$name]
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = $name
            $swatch = New-Object System.Windows.Shapes.Rectangle
            $swatch.Width = 14; $swatch.Height = 14
            $swatch.Fill = New-Object System.Windows.Media.SolidColorBrush(
                ([System.Windows.Media.Color]::FromArgb(255, $rgb.R, $rgb.G, $rgb.B)))
            $mi.Icon = $swatch
            [System.Windows.Automation.AutomationProperties]::SetName($mi, $name)
            $nameL = $name
            $colorClickHandler = {
                $currentIndex = Get-PreviewAnnotationIndexById $targetId
                if ($currentIndex -ge 0 -and
                    [string]$stateL.Annotations[$currentIndex].Color -ne $nameL) {
                    Snapshot-State
                    $updated = Copy-SnipAnnotation `
                        -Annotation $stateL.Annotations[$currentIndex]
                    $updated.Color = $nameL
                    $stateL.Annotations[$currentIndex] = $updated
                    Render-Annotations
                }
                if ($null -ne $previewContext.AnnotationMenuControl) {
                    & $previewContext.AnnotationMenuControl.CloseOptions
                }
            }.GetNewClosure()
            $mi.Add_Click($colorClickHandler)
            $menuBindings.Add([pscustomobject]@{
                Item=$mi; Handler=$colorClickHandler
            }) | Out-Null
            [void]$menu.Items.Add($mi)
        }
        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
        $delMi = New-Object System.Windows.Controls.MenuItem
        $delMi.Header = 'Delete'
        [System.Windows.Automation.AutomationProperties]::SetName($delMi, 'Delete')
        $deleteClickHandler = {
            $currentIndex = Get-PreviewAnnotationIndexById $targetId
            if ($currentIndex -ge 0) {
                Snapshot-State
                $stateL.Annotations.RemoveAt($currentIndex)
                if ($previewContext.SelectedAnnotationId -eq $targetId) {
                    & $setSelectedAnnotation $null | Out-Null
                }
                Render-Annotations
            }
            if ($null -ne $previewContext.AnnotationMenuControl) {
                & $previewContext.AnnotationMenuControl.CloseOptions
            }
        }.GetNewClosure()
        $delMi.Add_Click($deleteClickHandler)
        $menuBindings.Add([pscustomobject]@{
            Item=$delMi; Handler=$deleteClickHandler
        }) | Out-Null
        [void]$menu.Items.Add($delMi)

        $annotationCleanup = {
            foreach ($binding in @($menuBindings)) {
                $binding.Item.Remove_Click($binding.Handler)
            }
        }.GetNewClosure()
        $previewContext.AnnotationMenuControl =
            Connect-SnipPreviewTransientContextMenu -Menu $menu `
                -PlacementTarget $highlightLayer -Context $previewContext `
                -Name Annotation -Cleanup $annotationCleanup
        & $previewContext.AnnotationMenuControl.OpenOptions
    })

    # Toolbar buttons
    $win.FindName('ClearBtn').Add_Click({
        if ($state.Annotations.Count -eq 0) { return }
        Snapshot-State
        $state.Annotations.Clear()
        & $setSelectedAnnotation $null | Out-Null
        Render-Annotations
    })
    $win.FindName('UndoBtn').Add_Click({ Do-Undo })
    $win.FindName('RedoBtn').Add_Click({ Do-Redo })

    $toggleMaximize = {
        $win.WindowState = if ($win.WindowState -eq [System.Windows.WindowState]::Maximized) {
            [System.Windows.WindowState]::Normal
        } else { [System.Windows.WindowState]::Maximized }
    }.GetNewClosure()
    $beginWindowDrag = {
        if ($win.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $win.WindowState = [System.Windows.WindowState]::Normal
        }
        try { $win.DragMove() } catch {}
    }.GetNewClosure()
    $showSystemMenu = {
        & $previewContext.CommandRouter.SystemMenuAction
    }.GetNewClosure()
    $resizeHitTest = {
        param([double]$X,[double]$Y,[double]$Width,[double]$Height)
        $left = $X -lt 6; $right = $X -ge ($Width - 6)
        $top = $Y -lt 6; $bottom = $Y -ge ($Height - 6)
        if ($top -and $left) { return 'TopLeft' }
        if ($top -and $right) { return 'TopRight' }
        if ($bottom -and $left) { return 'BottomLeft' }
        if ($bottom -and $right) { return 'BottomRight' }
        if ($top) { return 'Top' }; if ($bottom) { return 'Bottom' }
        if ($left) { return 'Left' }; if ($right) { return 'Right' }
        'Client'
    }.GetNewClosure()
    $setResponsiveMode = {
        param([double]$Width,[double]$Height)
        Set-SnipPreviewResponsiveMode -Context $previewContext -Width $Width -Height $Height | Out-Null
    }.GetNewClosure()
    $setPropertyIsland = {
        param([string]$Tool)
        & $previewContext.ApplyPropertyPresentation $Tool
    }.GetNewClosure()
    $getIslandBounds = {
        param([double]$Width,[double]$Height)
        $win.Width = $Width; $win.Height = $Height
        & $setResponsiveMode $Width $Height
        $win.UpdateLayout()
        $root = $studioShell.StudioRoot
        $measurementHost = [System.Windows.Controls.Grid]::new()
        $measurementHost.Width = $Width
        $measurementHost.Height = $Height
        $win.Content = $null
        $win.UpdateLayout()
        try {
            $measurementHost.Children.Add($root) | Out-Null
            $measurementHost.Measure([System.Windows.Size]::new($Width,$Height))
            $measurementHost.Arrange([System.Windows.Rect]::new(0,0,$Width,$Height))
            $measurementHost.UpdateLayout()
            $result = @{}
            foreach ($entry in ([ordered]@{
                Brand=$studioShell.BrandIsland; Actions=$studioShell.ActionsIsland
                Property=$studioShell.PropertyIsland; ToolDock=$studioShell.ToolDock
                Viewport=$studioShell.ViewportIsland; Status=$studioShell.StatusIsland
            }).GetEnumerator()) {
                $origin = $entry.Value.TranslatePoint(
                    [System.Windows.Point]::new(0,0), $root)
                $result[$entry.Key] = [System.Windows.Rect]::new(
                    $origin.X, $origin.Y, $entry.Value.ActualWidth,
                    $entry.Value.ActualHeight)
            }
        } finally {
            $measurementHost.Children.Remove($root)
            $win.Content = $root
            $win.UpdateLayout()
        }
        $result
    }.GetNewClosure()
    $responsiveSizeChanged = [System.Windows.SizeChangedEventHandler]{
        param($sender,$eventArgs)
        & $setResponsiveMode $eventArgs.NewSize.Width $eventArgs.NewSize.Height
    }.GetNewClosure()
    $win.Add_SizeChanged($responsiveSizeChanged)

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

    foreach ($canvas in @($annotationLayer,$interactionLayer,$selectionLayer,$highlightLayer)) {
        $canvas.Width = $Bitmap.Width
        $canvas.Height = $Bitmap.Height
    }

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
        $brandZoomText = $win.FindName('BrandZoomText')
        if ($brandZoomText) { $brandZoomText.Text = '{0:P0}' -f $s }
        Render-PreviewInteraction
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
            $factor    = if ($_.Delta -gt 0) { 1.25 } else { 1 / 1.25 }
            $oldScale  = $layoutScale.ScaleX
            $cursor    = $_.GetPosition($scroller)
            $oldSx     = $scroller.HorizontalOffset
            $oldSy     = $scroller.VerticalOffset
            & $zoomBy $factor
            $newScale  = $layoutScale.ScaleX
            $offset    = Get-ZoomCenteredOffset `
                -CursorX $cursor.X -CursorY $cursor.Y `
                -OldScrollX $oldSx -OldScrollY $oldSy `
                -OldScale $oldScale -NewScale $newScale `
                -ContentWidth  ($Bitmap.Width  * $newScale) `
                -ContentHeight ($Bitmap.Height * $newScale) `
                -ViewportWidth  $scroller.ViewportWidth `
                -ViewportHeight $scroller.ViewportHeight
            $scroller.ScrollToHorizontalOffset($offset.X)
            $scroller.ScrollToVerticalOffset(  $offset.Y)
            $_.Handled = $true
        }
    }.GetNewClosure())

    # Keyboard shortcuts
    $syncPresentationCommandState = {
        $syncResult = Invoke-SnipPresentationIntent `
            -State $previewContext.PresentationState `
            -Intent ([pscustomobject]@{
                Type='SyncCommandState'
                SelectionId=$previewContext.SelectedAnnotationId
                CanUndo=($previewContext.UndoStack.Count -gt 0)
                CanRedo=($previewContext.RedoStack.Count -gt 0)
                HasCrop=($null -ne $previewContext.CropRectangle)
            })
        $previewContext.PresentationState = $syncResult.State
        $win.FindName('UndoBtn').IsEnabled = [bool]$syncResult.State.CanUndo
        $win.FindName('RedoBtn').IsEnabled = [bool]$syncResult.State.CanRedo
        $win.FindName('DuplicateBtn').IsEnabled = `
            -not [string]::IsNullOrWhiteSpace([string]$syncResult.State.SelectionId)
        $win.FindName('DeleteBtn').IsEnabled = `
            -not [string]::IsNullOrWhiteSpace([string]$syncResult.State.SelectionId)
        $syncResult.State
    }.GetNewClosure()

    $handlePreviewKeyDown = {
        param([System.Windows.Input.KeyEventArgs]$EventArgs)
        $modifierFlags = & $previewContext.GetKeyboardModifiers
        $eventKey = if ($EventArgs.Key -eq [System.Windows.Input.Key]::System) {
            $EventArgs.SystemKey
        } else { $EventArgs.Key }
        $eventKeyName = [string]$eventKey
        if ($eventKeyName -eq 'Return') { $eventKeyName = 'Enter' }
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        $openMenus = @($previewContext.TransientMenus | Where-Object {
            $null -ne $_.State -and $_.State.IsExpanded
        })
        $focusedRole = if ($openMenus.Count -gt 0 -or
            $focused -is [System.Windows.Controls.MenuItem] -or
            $focused -is [System.Windows.Controls.ContextMenu]) {
            'Popup'
        } elseif ($null -ne $focused -and $null -ne $focused.PSObject.Properties['Tag'] -and
            $null -ne $focused.Tag -and
            $null -ne $focused.Tag.PSObject.Properties['Role'] -and
            $focused.Tag.Role -eq 'PropertyEditor') {
            'PropertyEditor'
        } elseif ($state.EditingText -or
            $focused -is [System.Windows.Controls.TextBox] -or
            $focused -is [System.Windows.Controls.RichTextBox]) {
            'TextEditor'
        } elseif ($focused -is [System.Windows.Controls.Primitives.ButtonBase]) {
            'Button'
        } elseif ($highlightLayer.IsKeyboardFocusWithin -or
            [object]::ReferenceEquals($focused,$highlightLayer)) {
            'Canvas'
        } else { 'Window' }
        $modifierNames = @()
        if (($modifierFlags -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
            $modifierNames += 'Ctrl'
        }
        if (($modifierFlags -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) {
            $modifierNames += 'Shift'
        }
        if (($modifierFlags -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0) {
            $modifierNames += 'Alt'
        }
        $draftForKeys = if ($null -ne $previewContext.Interaction) {
            $previewContext.Interaction
        } else { $previewContext.Draft }
        $editorState = @{
            PopupOpen=($openMenus.Count -gt 0)
            EditingText=[bool]$state.EditingText
            EditingProperty=[bool]$previewContext.EditingProperty
            Draft=$draftForKeys
            SelectionId=$previewContext.SelectedAnnotationId
            ActiveTool=$previewContext.ActiveTool
        }
        $previewContext.CommandRouter.ResolveCount++
        $intent = & $previewContext.CommandRouter.Resolve $focusedRole `
            $editorState $eventKeyName $modifierNames
        $previewContext.CommandRouter.LastCommand = if ($null -eq $intent) {
            $null
        } else { [string]$intent.SourceCommand }
        if ($null -eq $intent) { return }
        if ([string]$intent.Type -eq 'InvokeCommand') {
            & $syncPresentationCommandState | Out-Null
            $commandResult = Invoke-SnipPresentationIntent `
                -State $previewContext.PresentationState `
                -Intent ([pscustomobject]@{
                    Type='InvokeCommand'; Command=[string]$intent.Command
                })
            $previewContext.PresentationState = $commandResult.State
            foreach ($effect in @($commandResult.Effects)) {
                & $applyPresentationEffect $effect
            }
            $EventArgs.Handled=$true
            return
        }
        $command = [string]$intent.SourceCommand

        switch -Regex ($command) {
            '^ClosePopup$' {
                $owningMenu = $null
                if ($null -ne $previewContext.PopupRouteMenu) {
                    $owningMenu = @($openMenus | Where-Object {
                        [object]::ReferenceEquals(
                            $_.Menu,$previewContext.PopupRouteMenu)
                    } | Select-Object -Last 1)
                    $owningMenu = if ($owningMenu.Count -gt 0) {
                        $owningMenu[0]
                    } else { $null }
                }
                if ($null -eq $owningMenu -and $openMenus.Count -gt 0) {
                    $owningMenu = $openMenus[-1]
                }
                if ($null -ne $owningMenu) { & $owningMenu.CloseOptions }
                $EventArgs.Handled=$true; return
            }
            '^(TextCopy|TextInput|CommitText|CancelTextEdit|PropertyInput|CancelPropertyEdit|ActivateFocusedButton|PopupNavigation)$' {
                return
            }
            '^CancelDraft$' {
                & $cancelDraft; $EventArgs.Handled=$true; return
            }
            '^ClearSelection$' {
                & $setSelectedAnnotation $null | Out-Null
                $EventArgs.Handled=$true; return
            }
            '^DeleteSelection$' {
                & $deleteSelection; $EventArgs.Handled=$true; return
            }
            '^MoveSelection(Left|Right|Up|Down)(1|10)$' {
                $direction=$Matches[1]; $distance=[int]$Matches[2]
                $deltaX=0; $deltaY=0
                switch ($direction) {
                    'Left' { $deltaX=-$distance }
                    'Right' { $deltaX=$distance }
                    'Up' { $deltaY=-$distance }
                    'Down' { $deltaY=$distance }
                }
                $current = Get-PreviewAnnotationById $previewContext.SelectedAnnotationId
                if ($null -ne $current) {
                    $moved = Move-SnipAnnotation -Annotation $current `
                        -DeltaX $deltaX -DeltaY $deltaY `
                        -SourceWidth $Bitmap.Width -SourceHeight $Bitmap.Height
                    if (-not (Test-PreviewAnnotationEqual $current $moved)) {
                        Snapshot-State
                        $index=Get-PreviewAnnotationIndexById $current.Id
                        if ($index -ge 0) { $previewContext.Annotations[$index]=$moved }
                        Render-Annotations
                    }
                }
                $EventArgs.Handled=$true; return
            }
            '^ActivateSelect$' {
                & $setStudioTool Select
                $EventArgs.Handled=$true; return
            }
            '^Undo$' { Do-Undo; $EventArgs.Handled=$true; return }
            '^Redo$' { Do-Redo; $EventArgs.Handled=$true; return }
            '^ZoomIn$' { & $zoomBy 1.25; $EventArgs.Handled=$true; return }
            '^ZoomOut$' { & $zoomBy (1/1.25); $EventArgs.Handled=$true; return }
            '^ZoomFit$' { & $fitToViewport; $EventArgs.Handled=$true; return }
            '^TemporaryPan$' {
                if (-not $state.Panning) {
                    $state.TemporaryPan = $true
                    & $beginPan ([System.Windows.Input.Mouse]::GetPosition($scroller))
                }
                $EventArgs.Handled=$true; return
            }
            '^ShowSystemMenu$' {
                & $previewContext.CommandRouter.SystemMenuAction
                $EventArgs.Handled=$true; return
            }
        }
    }.GetNewClosure()
    $previewContext.RoutePreviewKeyDown = $handlePreviewKeyDown
    $previewKeyDownHandler = {
        & $handlePreviewKeyDown $_
    }.GetNewClosure()
    $win.Add_PreviewKeyDown($previewKeyDownHandler)
    $previewKeyUpHandler = [System.Windows.Input.KeyEventHandler]({
        param($sender,$eventArgs)
        $eventKey = if ($eventArgs.Key -eq [System.Windows.Input.Key]::System) {
            $eventArgs.SystemKey
        } else { $eventArgs.Key }
        if ($eventKey -eq [System.Windows.Input.Key]::Space -and
            $state.TemporaryPan) {
            & $endPan
            $eventArgs.Handled = $true
        }
    }.GetNewClosure())
    $win.Add_PreviewKeyUp($previewKeyUpHandler)

    # Rewrites the pixels under one region in place. The kernels are compiled
    # because a PowerShell loop over a large selection would freeze the editor;
    # the Graphics is torn down first so GDI+ never holds the bitmap while
    # LockBits does, and the caller rebuilds it.
    $applyObscureRegion = {
        param($Target, $Annotation)
        $left = [int][math]::Max(0,[int]$Annotation.Geometry.X)
        $top = [int][math]::Max(0,[int]$Annotation.Geometry.Y)
        $width = [int][math]::Min([int]$Annotation.Geometry.Width, $Target.Width - $left)
        $height = [int][math]::Min([int]$Annotation.Geometry.Height, $Target.Height - $top)
        if ($width -le 0 -or $height -le 0) { return }
        if (-not ('SnipPixels' -as [type])) { return }
        $metrics = Get-SnipObscureMetrics -Mode ([string]$Annotation.Kind) `
            -StrokeWidth ([double]$Annotation.StrokeWidth)
        $region = [System.Drawing.Rectangle]::new($left,$top,$width,$height)
        $data = $Target.LockBits($region,
            [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $stride = [int]$data.Stride
            $buffer = New-Object byte[] ($stride * $height)
            [System.Runtime.InteropServices.Marshal]::Copy(
                $data.Scan0, $buffer, 0, $buffer.Length)
            if ([string]$Annotation.Kind -eq 'Pixelate') {
                [SnipPixels]::Pixelate($buffer,$width,$height,$stride,
                    [int]$metrics.BlockSize)
            } else {
                [SnipPixels]::BoxBlur($buffer,$width,$height,$stride,
                    [int]$metrics.BlurRadius)
            }
            [System.Runtime.InteropServices.Marshal]::Copy(
                $buffer, 0, $data.Scan0, $buffer.Length)
        } finally {
            $Target.UnlockBits($data)
        }
    }.GetNewClosure()

    function script:Get-FlattenedBitmap {
        $exportCrop = $previewContext.CropRectangle
        $orderedAnnotations = @(& $getOrderedAnnotations)
        # Nothing to compose and nothing to trim: hand back the shared source.
        # Callers guard disposal with `$flat -ne $Bitmap`.
        if ($orderedAnnotations.Count -eq 0 -and $null -eq $exportCrop) {
            return $Bitmap
        }
        $stepNumbers = @{}
        foreach ($stepEntry in @(Get-SnipStepNumbering -Annotations $orderedAnnotations)) {
            $stepNumbers[[string]$stepEntry.Id] = [int]$stepEntry.Number
        }
        $flat = New-Object System.Drawing.Bitmap $Bitmap.Width, $Bitmap.Height,
            ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($flat)
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.DrawImage($Bitmap, 0, 0, $Bitmap.Width, $Bitmap.Height)
        foreach ($a in $orderedAnnotations) {
            $rgb = $palette[$a.Color]
            if (-not $rgb) { continue }
            $alpha = [int][math]::Round(255.0 *
                [math]::Max(0.0,[math]::Min(1.0,[double]$a.Opacity)))
            if ($a.Kind -eq 'Highlight') {
                $brush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb($alpha, $rgb.R, $rgb.G, $rgb.B))
                $g.FillRectangle($brush, [int]$a.Geometry.X, [int]$a.Geometry.Y,
                    [int]$a.Geometry.Width, [int]$a.Geometry.Height)
                $brush.Dispose()
            } elseif ($a.Kind -in @('Rectangle','Ellipse')) {
                if ([bool](Get-SnipRecordValue -InputObject $a.Properties `
                    -Name Fill -Default $false)) {
                    $fillBrush = New-Object System.Drawing.SolidBrush(
                        [System.Drawing.Color]::FromArgb($alpha, $rgb.R, $rgb.G, $rgb.B))
                    if ($a.Kind -eq 'Ellipse') {
                        $g.FillEllipse($fillBrush, [int]$a.Geometry.X, [int]$a.Geometry.Y,
                            [int]$a.Geometry.Width, [int]$a.Geometry.Height)
                    } else {
                        $g.FillRectangle($fillBrush, [int]$a.Geometry.X, [int]$a.Geometry.Y,
                            [int]$a.Geometry.Width, [int]$a.Geometry.Height)
                    }
                    $fillBrush.Dispose()
                }
                $pen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::FromArgb($alpha, $rgb.R, $rgb.G, $rgb.B),
                    [single]$a.StrokeWidth)
                if ($a.Kind -eq 'Ellipse') {
                    $g.DrawEllipse($pen, [int]$a.Geometry.X, [int]$a.Geometry.Y,
                        [int]$a.Geometry.Width, [int]$a.Geometry.Height)
                } else {
                    $g.DrawRectangle($pen, [int]$a.Geometry.X, [int]$a.Geometry.Y,
                        [int]$a.Geometry.Width, [int]$a.Geometry.Height)
                }
                $pen.Dispose()
            } elseif ($a.Kind -in @('Arrow','Line')) {
                $strokeColor = [System.Drawing.Color]::FromArgb(
                    $alpha, $rgb.R, $rgb.G, $rgb.B)
                $pen = New-Object System.Drawing.Pen($strokeColor, [single]$a.StrokeWidth)
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                # Same solver as Render-Annotations, so export matches the screen.
                $arrowGeometry = if ($a.Kind -eq 'Arrow') {
                    Get-SnipArrowGeometry `
                        -StartX ([double]$a.Geometry.Start.X) `
                        -StartY ([double]$a.Geometry.Start.Y) `
                        -EndX ([double]$a.Geometry.End.X) `
                        -EndY ([double]$a.Geometry.End.Y) `
                        -StrokeWidth ([double]$a.StrokeWidth)
                } else { $null }
                if ($null -ne $arrowGeometry -and $arrowGeometry.Length -gt 0) {
                    $g.DrawLine($pen, [single]$a.Geometry.Start.X,
                        [single]$a.Geometry.Start.Y,
                        [single]$arrowGeometry.ShaftEndX, [single]$arrowGeometry.ShaftEndY)
                    $headBrush = New-Object System.Drawing.SolidBrush($strokeColor)
                    $g.FillPolygon($headBrush, [System.Drawing.PointF[]]@(
                        [System.Drawing.PointF]::new(
                            [single]$arrowGeometry.TipX, [single]$arrowGeometry.TipY),
                        [System.Drawing.PointF]::new(
                            [single]$arrowGeometry.LeftX, [single]$arrowGeometry.LeftY),
                        [System.Drawing.PointF]::new(
                            [single]$arrowGeometry.RightX, [single]$arrowGeometry.RightY)))
                    $headBrush.Dispose()
                } else {
                    $g.DrawLine($pen, [int]$a.Geometry.Start.X, [int]$a.Geometry.Start.Y,
                        [int]$a.Geometry.End.X, [int]$a.Geometry.End.Y)
                }
                $pen.Dispose()
            } elseif ($a.Kind -eq 'Text') {
                $brush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb($alpha, $rgb.R, $rgb.G, $rgb.B))
                $font = New-Object System.Drawing.Font 'Segoe UI', $a.Properties.FontSize,
                    ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
                $g.DrawString([string]$a.Properties.Text, $font, $brush,
                    [single]$a.Geometry.X, [single]$a.Geometry.Y)
                $font.Dispose(); $brush.Dispose()
            } elseif ($a.Kind -eq 'Step') {
                # Same badge the canvas draws: filled disc, white ring, white
                # bold number centred, numbered by position not by record.
                $diameter = [single][int]$a.Geometry.Width
                $bounds = New-Object System.Drawing.RectangleF(
                    [single][int]$a.Geometry.X, [single][int]$a.Geometry.Y,
                    $diameter, [single][int]$a.Geometry.Height)
                $badgeBrush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb($alpha, $rgb.R, $rgb.G, $rgb.B))
                $g.FillEllipse($badgeBrush, $bounds)
                $ringPen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::White,
                    [single][math]::Max(2.0,[double]$a.StrokeWidth * 0.6))
                $g.DrawEllipse($ringPen, $bounds)
                $badgeFontSize = [double](Get-SnipRecordValue -InputObject $a.Properties `
                    -Name FontSize -Default ([math]::Max(11.0,[double]$diameter * 0.5)))
                $badgeFont = New-Object System.Drawing.Font 'Segoe UI',
                    ([single]$badgeFontSize), ([System.Drawing.FontStyle]::Bold),
                    ([System.Drawing.GraphicsUnit]::Pixel)
                $badgeFormat = New-Object System.Drawing.StringFormat
                $badgeFormat.Alignment = [System.Drawing.StringAlignment]::Center
                $badgeFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
                $badgeNumber = if ($stepNumbers.ContainsKey([string]$a.Id)) {
                    $stepNumbers[[string]$a.Id]
                } else { 1 }
                $whiteBrush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::White)
                $g.DrawString([string]$badgeNumber, $badgeFont, $whiteBrush,
                    $bounds, $badgeFormat)
                $whiteBrush.Dispose(); $badgeFormat.Dispose(); $badgeFont.Dispose()
                $ringPen.Dispose(); $badgeBrush.Dispose()
            } elseif ($a.Kind -in @('Blur','Pixelate')) {
                # Obscures whatever is already composited underneath, so the
                # Graphics is released for the duration of the pixel pass.
                $g.Flush()
                $g.Dispose()
                & $applyObscureRegion $flat $a
                $g = [System.Drawing.Graphics]::FromImage($flat)
                $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            } elseif ($a.Geometry.Type -eq 'Points') {
                $points = @($a.Geometry.Points)
                if ($points.Count -gt 1) {
                    $pen = New-Object System.Drawing.Pen(
                        [System.Drawing.Color]::FromArgb($alpha,$rgb.R,$rgb.G,$rgb.B),
                        [single]$a.StrokeWidth)
                    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
                    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
                        $points | ForEach-Object {
                            [System.Drawing.PointF]::new(
                                [single][int]$_.X,[single][int]$_.Y)
                        }))
                    $pen.Dispose()
                }
            }
        }
        $g.Dispose()
        if ($null -eq $exportCrop) { return $flat }
        # Annotations were painted in source coordinates, so trimming the
        # composed bitmap is enough: the crop needs no per-annotation maths.
        $exportRectangle = Get-SnipExportRectangle -Width $Bitmap.Width `
            -Height $Bitmap.Height -CropRectangle $exportCrop
        $cropped = New-Object System.Drawing.Bitmap $exportRectangle.Width,
            $exportRectangle.Height,
            ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $cropGraphics = [System.Drawing.Graphics]::FromImage($cropped)
        # Nearest-neighbour + SourceCopy keeps the blit pixel-exact: no
        # resampling, no half-pixel shift, and source alpha is preserved.
        $cropGraphics.InterpolationMode =
            [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $cropGraphics.PixelOffsetMode =
            [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $cropGraphics.CompositingMode =
            [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $cropGraphics.DrawImage($flat,
            [System.Drawing.Rectangle]::new(0, 0,
                [int]$exportRectangle.Width, [int]$exportRectangle.Height),
            [System.Drawing.Rectangle]::new([int]$exportRectangle.X,
                [int]$exportRectangle.Y, [int]$exportRectangle.Width,
                [int]$exportRectangle.Height),
            [System.Drawing.GraphicsUnit]::Pixel)
        $cropGraphics.Dispose()
        $flat.Dispose()
        return $cropped
    }

    $copyBtn = $win.FindName('CopyBtn')
    $invokeCopy = {
        param([bool]$CloseAfterCopy)
        $operation = if ($CloseAfterCopy) { 'CopyAndClose' } else { 'CopyKeepOpen' }
        if ($OnOutputStarting) { & $OnOutputStarting $operation }
        $flat = $null
        $success = $false
        $copyError = $null
        try {
            $flat = Get-FlattenedBitmap
            $clipSrc = Convert-BitmapToBitmapSource $flat
            $retrySchedule = @(50, 100, 200)
            for ($attempt = 0; $attempt -le $retrySchedule.Count; $attempt++) {
                try {
                    & $previewContext.ClipboardSetter $clipSrc
                    $success = $true
                    break
                } catch {
                    $copyError = $_
                    if ($attempt -lt $retrySchedule.Count) {
                        & $previewContext.RetryDelay $retrySchedule[$attempt]
                    }
                }
            }
            if ($success) {
                # A crop changes what the clipboard actually holds, so say so.
                $copyStatus = if ($null -ne $previewContext.CropRectangle) {
                    'Copied {0} {1} {2} px' -f $clipSrc.PixelWidth,
                        ([char]0x00D7), $clipSrc.PixelHeight
                } else { 'Copied to clipboard' }
                & $previewContext.SetStatus $copyStatus 'Success'
            } else {
                & $previewContext.SetStatus 'Clipboard is unavailable' 'Error'
                if ($null -ne $copyError) {
                    Write-SnipDiag -Message 'Clipboard copy failed' -ErrorRecord $copyError
                }
            }
        } catch {
            & $previewContext.SetStatus 'Clipboard is unavailable' 'Error'
            Write-SnipDiag -Message 'Clipboard copy failed' -ErrorRecord $_
        } finally {
            if ($null -ne $flat -and $flat -ne $Bitmap) {
                try { $flat.Dispose() } catch {}
            }
            if ($OnOutputCompleted) { & $OnOutputCompleted $operation $success }
        }
        if ($success -and $CloseAfterCopy) {
            $previewLifecycle.Result = 'Completed'
            $win.Close()
        }
        $success
    }.GetNewClosure()
    $platformActions.Copy = $invokeCopy
    $copyBtn.Add_Click({
        & $applyPresentationEffect ([pscustomobject]@{ Name='Copy'; CloseAfter=$true })
    }.GetNewClosure())
    $previewContext.SplitControls.Copy.MenuItems.CopyKeepOpen.Add_Click({
        & $applyPresentationEffect ([pscustomobject]@{ Name='Copy'; CloseAfter=$false })
    }.GetNewClosure())
    $invokeSave = {
        if ($OnOutputStarting) { & $OnOutputStarting 'Save' }
        $flat = $null
        $success = $false
        try {
            $flat = Get-FlattenedBitmap
            $savedPath = & $previewContext.SaveBitmap $flat
            $success = -not [string]::IsNullOrWhiteSpace([string]$savedPath)
            # Only announce on a cropped save: the uncropped path keeps its
            # existing silent-status behaviour.
            if ($success -and $null -ne $previewContext.CropRectangle) {
                & $previewContext.SetStatus (
                    'Saved {0} {1} {2} px' -f $flat.Width,
                        ([char]0x00D7), $flat.Height) 'Success'
            }
        } catch {
            Write-SnipDiag -Message 'Save failed' -ErrorRecord $_
        } finally {
            if ($null -ne $flat -and $flat -ne $Bitmap) {
                try { $flat.Dispose() } catch {}
            }
            if ($OnOutputCompleted) { & $OnOutputCompleted 'Save' $success }
        }
    }.GetNewClosure()
    $platformActions.Save = $invokeSave
    $win.FindName('SaveBtn').Add_Click({
        & $applyPresentationEffect ([pscustomobject]@{ Name='Save' })
    }.GetNewClosure())
    $invokeNewSnip = {
        $previewLifecycle.Result = 'Preempted'
        if ($OnNewSnip) { & $OnNewSnip }
        $win.Close()
    }.GetNewClosure()
    $platformActions.NewSnip = $invokeNewSnip
    $win.FindName('NewBtn').Add_Click({
        & $applyPresentationEffect ([pscustomobject]@{ Name='NewSnip' })
    }.GetNewClosure())
    $win.FindName('DuplicateBtn').Add_Click({ & $duplicateSelection }.GetNewClosure())
    $win.FindName('DeleteBtn').Add_Click({ & $deleteSelection }.GetNewClosure())
    $win.FindName('CloseBtn').Add_Click({
        & $applyPresentationEffect ([pscustomobject]@{ Name='Close' })
    }.GetNewClosure())

    $script:CurrentPreviewWindow = $win
    $previewHelper = New-Object System.Windows.Interop.WindowInteropHelper $win
    # SourceInitialized fires once the OS hwnd exists but before the window
    # paints. Register here so a window-capture triggered with the preview
    # in focus correctly falls back to the virtual desktop.
    $win.Add_SourceInitialized({
        Register-SelfWindowHandle -Hwnd $previewHelper.Handle
    }.GetNewClosure())
    $previewSurface = [pscustomobject]@{
        Kind = 'Preview'
        Window = $win
        Close = {
            param([string]$result)
            $previewLifecycle.Result = $result
            $win.Close()
        }.GetNewClosure()
    }
    $win.Add_Closed({
        try { $win.Remove_SizeChanged($responsiveSizeChanged) } catch {}
        try { & $cancelDraft } catch {}
        try { & $previewContext.CommandRouter.CloseTransientMenus } catch {}
        if ([object]::ReferenceEquals($script:ActivePreviewContext, $previewContext)) {
            $script:ActivePreviewContext = $null
        }
        try { Unregister-SelfWindowHandle -Hwnd $previewHelper.Handle } catch {}
        $script:CurrentPreviewWindow = $null
        # Preview owns the original only after the transfer callback succeeds.
        # The one-shot guard protects exceptional close paths from re-disposal.
        if ($previewLifecycle.OwnershipAccepted -and -not $previewLifecycle.BitmapDisposed) {
            $previewLifecycle.BitmapDisposed = $true
            try { if ($Bitmap) { $Bitmap.Dispose() } }
            catch { Write-SnipDiag -Message 'Bitmap dispose failed' -ErrorRecord $_ }
        }
    }.GetNewClosure())
    $previewLifecycle.CleanupInstalled = $true
    try {
        if ($OnSurfaceReady) { & $OnSurfaceReady $previewSurface }
        if ($OnOwnershipAccepted) { & $OnOwnershipAccepted $previewLifecycle }
        $previewLifecycle.OwnershipAccepted = $true
    } catch {
        try { $win.Close() } catch {}
        throw
    }

    if ($TestAction) {
        $kit = @{
            Win            = $win
            Context        = $previewContext
            ResponsiveMode = $previewContext.ModeState
            CommandRouter  = $previewContext.CommandRouter
            StudioRoot     = $studioShell.StudioRoot
            State          = $state
            LayoutScale    = $layoutScale
            Scroller       = $scroller
            ImageHost      = $imageHost
            PreviewImage   = $previewImage
            AnnotationLayer = $annotationLayer
            InteractionLayer = $interactionLayer
            SelectionLayer = $selectionLayer
            HighlightLayer = $highlightLayer
            BrandIsland    = $studioShell.BrandIsland
            ActionsIsland  = $studioShell.ActionsIsland
            PropertyIsland = $studioShell.PropertyIsland
            ToolDock       = $studioShell.ToolDock
            ViewportIsland = $studioShell.ViewportIsland
            StatusIsland   = $studioShell.StatusIsland
            ActionOrder    = [string[]]@('CopyAndClose','Save','Pin','Close')
            SplitControls  = $previewContext.SplitControls
            ToolOrder      = $previewContext.ToolOrder
            MoreState      = $previewContext.MoreState
            PropertyState  = $previewContext.PropertyState
            SetResponsiveMode = $setResponsiveMode
            SetPropertyIsland = $setPropertyIsland
            SetStudioTool   = $setStudioTool
            SyncPresentationCommandState = $syncPresentationCommandState
            SetSelectedAnnotation = $setSelectedAnnotation
            SetStatus       = $previewContext.SetStatus
            ClearStatus     = $previewContext.ClearStatus
            GetIslandBounds = $getIslandBounds
            ResizeHitTest  = $resizeHitTest
            ToggleMaximize = $toggleMaximize
            BeginWindowDrag = $beginWindowDrag
            ShowSystemMenu = $showSystemMenu
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
            PlaceStep      = $placeStep
            ApplySplitSubtype = $applySplitSubtype
            GetToolProperties = $getToolProperties
            OpenText       = $openText
            HandleMouseDown = $handleMouseDown
            HandleMouseMove = $handleMouseMove
            HandleMouseUp = $handleMouseUp
            HandlePreviewKeyDown = $handlePreviewKeyDown
            BeginSelectGesture = $beginSelectGesture
            UpdateSelectGesture = $updateSelectGesture
            CompleteSelectGesture = $completeSelectGesture
            CancelSelectGesture = $cancelSelectGesture
            BeginCropDraft = $beginCropDraft
            GetCropHandleAt = $getCropHandleAt
            UpdateCropDraft = $updateCropDraft
            ApplyCropDraft = $applyCropDraft
            CancelCropDraft = $cancelCropDraft
            ResetCrop = $resetCrop
            PickColor       = $pickColor
            Render         = ${function:script:Render-Annotations}
            Snapshot       = ${function:script:Snapshot-State}
            Undo           = ${function:script:Do-Undo}
            Redo           = ${function:script:Do-Redo}
            FindAt         = ${function:script:Find-AnnotationAt}
            Flatten        = ${function:script:Get-FlattenedBitmap}
            Surface        = $previewSurface
            OwnershipState = $previewLifecycle
        }
        $script:pwTestError = $null
        # Hide off-screen so the window is effectively headless.
        $win.WindowStartupLocation = 'Manual'
        $win.Left = -5000; $win.Top = -5000
        # Loaded is raised before the first present, so running the test body
        # inline there leaves the client area unpainted for any TestAction that
        # pumps a nested DispatcherFrame (screenshot/driver harnesses capture a
        # blank window). Post the invocation instead so Loaded returns and the
        # window renders once before the test body runs.
        $win.Add_Loaded({
            $win.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
                [action]{
                    try { & $TestAction $kit }
                    catch { $script:pwTestError = $_ }
                    finally { try { $win.Close() } catch {} }
                }) | Out-Null
        }.GetNewClosure())
        $win.ShowDialog() | Out-Null
        if ($script:pwTestError) { throw $script:pwTestError }
        return $previewLifecycle.Result
    }

    try {
        $win.ShowDialog() | Out-Null
    } catch {
        $previewLifecycle.Result = 'Failed'
        try { $win.Close() } catch {}
    }
    $script:CurrentPreviewWindow = $null
    return $previewLifecycle.Result
}

$script:WidgetWindow = $null

function Show-SettingsWindow {
    [CmdletBinding()]
    param(
        $Context = $script:UtilityContext,
        [scriptblock]$TestAction
    )

    if ($null -eq $Context) {
        throw [ArgumentNullException]::new('Context')
    }
    foreach ($requiredProperty in 'Settings','SettingsPath','RegisteredHotkey','Hwnd') {
        if ($null -eq $Context.PSObject.Properties[$requiredProperty]) {
            throw [ArgumentException]::new("Settings context is missing '$requiredProperty'.", 'Context')
        }
    }

    [xml]$xaml = [xml](Get-SnipXamlText -Name 'SettingsWindow')
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Dispose()
    }
    [void](Initialize-SnipWindowTheme -Window $window)

    $shortcutRecorder = $window.FindName('ShortcutRecorder')
    $shortcutText = $window.FindName('ShortcutText')
    $saveFolderBox = $window.FindName('SaveFolderBox')
    $saveFormatBox = $window.FindName('SaveFormatBox')
    $launchCheck = $window.FindName('LaunchCheck')
    $widgetCheck = $window.FindName('WidgetCheck')
    $errorText = $window.FindName('ErrorText')
    $cancelButton = $window.FindName('CancelBtn')
    $saveButton = $window.FindName('SaveBtn')

    $saveFolderBox.Text = [string]$Context.Settings.SaveFolder
    # The ComboBox carries the persisted token on each item Tag so the UI label
    # ("PNG") stays free of the settings vocabulary ("Png").
    $normalizeSaveFormat = {
        param($Value)
        switch ([string]$Value) { 'Jpeg' { 'Jpeg' } 'Bmp' { 'Bmp' } default { 'Png' } }
    }
    $formatSettingProperty = $Context.Settings.PSObject.Properties['SaveFormat']
    $seededFormatValue = if ($null -ne $formatSettingProperty) { $formatSettingProperty.Value } else { 'Png' }
    $seededFormat = & $normalizeSaveFormat $seededFormatValue
    $saveFormatBox.SelectedIndex = switch ($seededFormat) { 'Jpeg' { 1 } 'Bmp' { 2 } default { 0 } }
    $readSaveFormat = {
        $selectedItem = $saveFormatBox.SelectedItem
        $selectedTag = if ($null -ne $selectedItem) { $selectedItem.Tag } else { 'Png' }
        & $normalizeSaveFormat $selectedTag
    }.GetNewClosure()
    $launchCheck.IsChecked = [bool]$Context.Settings.LaunchAtSignIn
    $widgetCheck.IsChecked = [bool]$Context.Settings.WidgetVisible
    $formatActiveShortcut = {
        param($binding)
        if ($null -eq $binding) { return 'Unavailable' }
        Format-SnipHotkey -Modifiers ([int]$binding.Modifiers) -VirtualKey ([int]$binding.VirtualKey)
    }
    $shortcutText.Text = & $formatActiveShortcut $Context.RegisteredHotkey

    $registerProperty = $Context.PSObject.Properties['RegisterHotkey']
    $registerHotkey = if ($null -ne $registerProperty -and $registerProperty.Value -is [scriptblock]) {
        $registerProperty.Value
    } else {
        { param($hwnd,$id,$modifiers,$virtualKey) [Native]::RegisterHotKey($hwnd,$id,$modifiers,$virtualKey) }
    }
    $unregisterProperty = $Context.PSObject.Properties['UnregisterHotkey']
    $unregisterHotkey = if ($null -ne $unregisterProperty -and $unregisterProperty.Value -is [scriptblock]) {
        $unregisterProperty.Value
    } else {
        { param($hwnd,$id) [Native]::UnregisterHotKey($hwnd,$id) }
    }
    $setFeedback = {
        param([string]$Message, [ValidateSet('Error','Success','Neutral')] [string]$Kind = 'Error')
        $errorText.Text = $Message
        # Stock Fluent semantic fills, referenced by key so they follow the mode.
        $brushKey = switch ($Kind) {
            'Success' { 'SystemFillColorSuccessBrush' }
            'Neutral' { 'TextFillColorSecondaryBrush' }
            default { 'SystemFillColorCriticalBrush' }
        }
        $errorText.SetResourceReference(
            [System.Windows.Controls.TextBlock]::ForegroundProperty, $brushKey)
    }.GetNewClosure()
    $recordShortcut = {
        param([int]$Modifiers, [int]$VirtualKey)

        $result = Set-SnipHotkeyBinding -Context $Context `
            -Candidate ([pscustomobject]@{ Modifiers = $Modifiers; VirtualKey = $VirtualKey }) `
            -Register $registerHotkey -Unregister $unregisterHotkey
        $shortcutText.Text = & $formatActiveShortcut $result.ActiveBinding
        if ($result.Success) {
            & $setFeedback '' Neutral
        } elseif ($result.RollbackError -and $null -ne $result.ActiveBinding) {
            & $setFeedback ("{0} {1} Retry with another shortcut or close SnipIT to retry cleanup." -f
                $result.CandidateError, $result.RollbackError) Error
        } elseif ($result.RollbackError) {
            & $setFeedback ("{0} {1} No global shortcut is active; capture remains available from the tray." -f
                $result.CandidateError, $result.RollbackError) Error
        } elseif ($null -ne $result.ActiveBinding) {
            & $setFeedback ("{0}; previous shortcut remains active." -f $result.CandidateError) Error
        } else {
            & $setFeedback ("{0} No global shortcut is active; capture remains available from the tray." -f
                $result.CandidateError) Error
        }

        $hotkeyChangedProperty = $Context.PSObject.Properties['OnHotkeyChanged']
        if ($null -ne $hotkeyChangedProperty -and $hotkeyChangedProperty.Value -is [scriptblock]) {
            & $hotkeyChangedProperty.Value $result | Out-Null
        }
        $result
    }.GetNewClosure()
    $recorderState = [pscustomobject]@{ LastHandled = $false }
    $recordKey = {
        param(
            [System.Windows.Input.Key]$Key,
            [System.Windows.Input.Key]$SystemKey,
            [System.Windows.Input.ModifierKeys]$Modifiers
        )

        $recorderState.LastHandled = $false
        $resolvedKey = if ($Key -eq [System.Windows.Input.Key]::System) { $SystemKey } else { $Key }
        if ($resolvedKey -eq [System.Windows.Input.Key]::Tab) {
            return $null
        }
        $recorderState.LastHandled = $true
        if ($resolvedKey -in @(
            [System.Windows.Input.Key]::LeftCtrl, [System.Windows.Input.Key]::RightCtrl,
            [System.Windows.Input.Key]::LeftAlt, [System.Windows.Input.Key]::RightAlt,
            [System.Windows.Input.Key]::LeftShift, [System.Windows.Input.Key]::RightShift,
            [System.Windows.Input.Key]::LWin, [System.Windows.Input.Key]::RWin)) {
            return $null
        }

        $modifierBits = 0x4000
        if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) { $modifierBits = $modifierBits -bor 0x2 }
        if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0) { $modifierBits = $modifierBits -bor 0x1 }
        if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) { $modifierBits = $modifierBits -bor 0x4 }
        if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Windows) -ne 0) { $modifierBits = $modifierBits -bor 0x8 }
        $virtualKey = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($resolvedKey)
        & $recordShortcut $modifierBits $virtualKey
    }.GetNewClosure()
    $saveChanges = {
        $previousSettings = [pscustomobject][ordered]@{
            Version = $Context.Settings.Version
            Hotkey = $Context.Settings.Hotkey
            SaveFolder = $Context.Settings.SaveFolder
            SaveFormat = $Context.Settings.SaveFormat
            LaunchAtSignIn = $Context.Settings.LaunchAtSignIn
            WidgetVisible = $Context.Settings.WidgetVisible
        }
        $candidatePersisted = $false
        $startupAttempted = $false
        $widgetAttempted = $false
        try {
            $folder = $saveFolderBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($folder)) {
                throw [ArgumentException]::new('Choose a default save folder.')
            }
            $updatedSettings = [pscustomobject][ordered]@{
                Version = $Context.Settings.Version
                Hotkey = $Context.Settings.Hotkey
                SaveFolder = $folder
                SaveFormat = & $readSaveFormat
                LaunchAtSignIn = [bool]$launchCheck.IsChecked
                WidgetVisible = [bool]$widgetCheck.IsChecked
            }
            Save-SnipSettings -Settings $updatedSettings -Path ([string]$Context.SettingsPath)
            $candidatePersisted = $true

            $Context.Settings.SaveFolder = $updatedSettings.SaveFolder
            $Context.Settings.SaveFormat = $updatedSettings.SaveFormat
            $Context.Settings.LaunchAtSignIn = $updatedSettings.LaunchAtSignIn
            $Context.Settings.WidgetVisible = $updatedSettings.WidgetVisible
            $syncProperty = $Context.PSObject.Properties['SyncStartup']
            if ($null -ne $syncProperty -and $syncProperty.Value -is [scriptblock]) {
                $startupAttempted = $true
                & $syncProperty.Value $Context.Settings | Out-Null
            }
            $widgetProperty = $Context.PSObject.Properties['SetWidgetVisible']
            if ($null -ne $widgetProperty -and $widgetProperty.Value -is [scriptblock]) {
                $widgetAttempted = $true
                & $widgetProperty.Value ([bool]$Context.Settings.WidgetVisible) | Out-Null
            }
            & $setFeedback 'Settings saved.' Success
            return $true
        } catch {
            $failureMessage = $_.Exception.Message
            $rollbackErrors = [System.Collections.Generic.List[string]]::new()
            try {
                $Context.Settings.SaveFolder = $previousSettings.SaveFolder
                $Context.Settings.SaveFormat = $previousSettings.SaveFormat
                $Context.Settings.LaunchAtSignIn = $previousSettings.LaunchAtSignIn
                $Context.Settings.WidgetVisible = $previousSettings.WidgetVisible
            } catch {
                $rollbackErrors.Add("in-memory settings: $($_.Exception.Message)")
            }
            if ($startupAttempted) {
                try { & $syncProperty.Value $previousSettings | Out-Null }
                catch { $rollbackErrors.Add("launch-at-sign-in: $($_.Exception.Message)") }
            }
            if ($widgetAttempted) {
                try { & $widgetProperty.Value ([bool]$previousSettings.WidgetVisible) | Out-Null }
                catch { $rollbackErrors.Add("widget visibility: $($_.Exception.Message)") }
            }
            if ($candidatePersisted) {
                try {
                    Save-SnipSettings -Settings $previousSettings -Path ([string]$Context.SettingsPath)
                } catch {
                    $rollbackErrors.Add("settings file: $($_.Exception.Message)")
                }
            }
            if ($rollbackErrors.Count -eq 0) {
                & $setFeedback ("Settings could not be saved: {0} Previous settings were restored." -f
                    $failureMessage) Error
            } else {
                & $setFeedback ("Settings could not be saved: {0} Previous settings could not be fully restored: {1}" -f
                    $failureMessage, ($rollbackErrors -join '; ')) Error
            }
            return $false
        }
    }.GetNewClosure()

    $surfaceState = [pscustomobject]@{ Result = 'UserCancelled'; Published = $false }
    $surface = [pscustomobject]@{ Window = $window; RequestedResult = 'UserCancelled'; Close = $null }
    $closeSurface = {
        param([string]$Result = 'Preempted')
        $surfaceState.Result = $Result
        $surface.RequestedResult = $Result
        if ($window.IsVisible) { $window.Close() }
    }.GetNewClosure()
    $surface.Close = $closeSurface

    $lifecycleParameters = @{ Window = $window }
    $registerWindowProperty = $Context.PSObject.Properties['RegisterWindow']
    $unregisterWindowProperty = $Context.PSObject.Properties['UnregisterWindow']
    if ($null -ne $registerWindowProperty -and $registerWindowProperty.Value -is [scriptblock]) {
        $lifecycleParameters.Register = $registerWindowProperty.Value
    }
    if ($null -ne $unregisterWindowProperty -and $unregisterWindowProperty.Value -is [scriptblock]) {
        $lifecycleParameters.Unregister = $unregisterWindowProperty.Value
    }
    $lifecycle = Connect-SnipWindowLifecycle @lifecycleParameters
    $surfaceReadyProperty = $Context.PSObject.Properties['OnSurfaceReady']
    $surfaceReadyHandler = [EventHandler]{
        param($sender, $eventArgs)
        if (-not $surfaceState.Published -and $null -ne $surfaceReadyProperty -and
            $surfaceReadyProperty.Value -is [scriptblock]) {
            $surfaceState.Published = $true
            & $surfaceReadyProperty.Value $surface | Out-Null
        }
    }.GetNewClosure()

    $recorderKeyHandler = [System.Windows.Input.KeyEventHandler]{
        param($sender, $eventArgs)
        & $recordKey $eventArgs.Key $eventArgs.SystemKey ([System.Windows.Input.Keyboard]::Modifiers) | Out-Null
        $eventArgs.Handled = [bool]$recorderState.LastHandled
    }.GetNewClosure()
    $windowKeyHandler = [System.Windows.Input.KeyEventHandler]{
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
            $surfaceState.Result = 'UserCancelled'
            $window.Close()
            $eventArgs.Handled = $true
        }
    }.GetNewClosure()
    $closeClickHandler = [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        $surfaceState.Result = 'UserCancelled'
        $window.Close()
    }.GetNewClosure()
    $saveClickHandler = [System.Windows.RoutedEventHandler]{ param($sender,$eventArgs) & $saveChanges | Out-Null }.GetNewClosure()
    $window.Add_SourceInitialized($surfaceReadyHandler)
    $shortcutRecorder.Add_PreviewKeyDown($recorderKeyHandler)
    $window.Add_KeyDown($windowKeyHandler)
    $cancelButton.Add_Click($closeClickHandler)
    $saveButton.Add_Click($saveClickHandler)

    $kit = [pscustomobject]@{
        Window = $window
        Lifecycle = $lifecycle
        ShortcutRecorder = $shortcutRecorder
        ShortcutText = $shortcutText
        SaveFolderBox = $saveFolderBox
        SaveFormatBox = $saveFormatBox
        ReadSaveFormat = $readSaveFormat
        LaunchCheck = $launchCheck
        WidgetCheck = $widgetCheck
        ErrorText = $errorText
        RecordShortcut = $recordShortcut
        RecordKey = $recordKey
        RecorderState = $recorderState
        SaveChanges = $saveChanges
        Close = $closeSurface
    }

    try {
        if ($TestAction) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000
            $window.Top = -10000
            $window.ShowActivated = $false
            $window.Show()
            $window.UpdateLayout()
            & $TestAction $kit | Out-Null
            if ($window.IsVisible) { $window.Close() }
        } else {
            $window.ShowDialog() | Out-Null
        }
    } catch {
        $surfaceState.Result = 'Failed'
        throw
    } finally {
        try {
            if ($window.IsVisible) { $window.Close() }
            $window.Remove_SourceInitialized($surfaceReadyHandler)
            $shortcutRecorder.Remove_PreviewKeyDown($recorderKeyHandler)
            $window.Remove_KeyDown($windowKeyHandler)
            $cancelButton.Remove_Click($closeClickHandler)
            $saveButton.Remove_Click($saveClickHandler)
        } finally {
            $surfaceClosedProperty = $Context.PSObject.Properties['OnSurfaceClosed']
            if ($null -ne $surfaceClosedProperty -and
                $surfaceClosedProperty.Value -is [scriptblock]) {
                & $surfaceClosedProperty.Value $surfaceState.Result $surface | Out-Null
            }
        }
    }
    $surfaceState.Result
}

function Show-AboutWindow {
    [CmdletBinding()]
    param(
        $Context = $script:UtilityContext,
        [scriptblock]$TestAction
    )

    if ($null -eq $Context) { $Context = [pscustomobject]@{} }
    $appVersionProperty = $Context.PSObject.Properties['AppVersion']
    $repositoryProperty = $Context.PSObject.Properties['Repository']
    $licenseProperty = $Context.PSObject.Properties['License']
    $hotkeyProperty = $Context.PSObject.Properties['RegisteredHotkey']
    $activeBinding = if ($null -ne $hotkeyProperty) { $hotkeyProperty.Value } else { $null }
    $metadata = [pscustomobject][ordered]@{
        Version = if ($null -ne $appVersionProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$appVersionProperty.Value)) {
            [string]$appVersionProperty.Value
        } else { $script:SnipITAppVersion }
        PowerShell = $PSVersionTable.PSVersion.ToString()
        DotNet = [Environment]::Version.ToString()
        Repository = if ($null -ne $repositoryProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$repositoryProperty.Value)) {
            [string]$repositoryProperty.Value
        } else { 'https://github.com/RandomCodeSpace/snipIT' }
        License = if ($null -ne $licenseProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$licenseProperty.Value)) {
            [string]$licenseProperty.Value
        } else { 'MIT License' }
        ActiveShortcut = if ($null -eq $activeBinding) {
            'Unavailable'
        } else {
            Format-SnipHotkey -Modifiers ([int]$activeBinding.Modifiers) `
                -VirtualKey ([int]$activeBinding.VirtualKey)
        }
    }

    [xml]$xaml = [xml](Get-SnipXamlText -Name 'AboutWindow')
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    try { $window = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    [void](Initialize-SnipWindowTheme -Window $window)

    $window.FindName('VersionText').Text = $metadata.Version
    $window.FindName('PowerShellText').Text = $metadata.PowerShell
    $window.FindName('DotNetText').Text = $metadata.DotNet
    $window.FindName('ShortcutText').Text = $metadata.ActiveShortcut
    $window.FindName('RepositoryText').Text = $metadata.Repository
    $window.FindName('LicenseText').Text = $metadata.License
    # The repository row is a real Hyperlink: it opens in the default browser
    # through the shell, and only for an absolute http(s) URI.
    $repositoryLink = $window.FindName('RepositoryLink')
    $repositoryUri = $null
    if ([Uri]::TryCreate([string]$metadata.Repository,
            [UriKind]::Absolute, [ref]$repositoryUri) -and
        $repositoryUri.Scheme -in @('http','https')) {
        $repositoryLink.NavigateUri = $repositoryUri
    } else {
        $repositoryLink.IsEnabled = $false
    }
    $navigateHandler = [System.Windows.Navigation.RequestNavigateEventHandler]{
        param($sender, $eventArgs)
        try {
            Start-Process -FilePath ([string]$eventArgs.Uri.AbsoluteUri) | Out-Null
        } catch {
            Write-SnipDiag -Message 'Repository link launch failed' -ErrorRecord $_
        }
        $eventArgs.Handled = $true
    }
    $repositoryLink.Add_RequestNavigate($navigateHandler)
    $closeButton = $window.FindName('CloseBtn')

    $lifecycleParameters = @{ Window = $window }
    $registerWindowProperty = $Context.PSObject.Properties['RegisterWindow']
    $unregisterWindowProperty = $Context.PSObject.Properties['UnregisterWindow']
    if ($null -ne $registerWindowProperty -and $registerWindowProperty.Value -is [scriptblock]) {
        $lifecycleParameters.Register = $registerWindowProperty.Value
    }
    if ($null -ne $unregisterWindowProperty -and $unregisterWindowProperty.Value -is [scriptblock]) {
        $lifecycleParameters.Unregister = $unregisterWindowProperty.Value
    }
    $lifecycle = Connect-SnipWindowLifecycle @lifecycleParameters
    $surfaceState = [pscustomobject]@{ Result = 'UserCancelled'; Published = $false }
    $surface = [pscustomobject]@{ Window = $window; RequestedResult = 'UserCancelled'; Close = $null }
    $closeSurface = {
        param([string]$Result = 'Preempted')
        $surfaceState.Result = $Result
        $surface.RequestedResult = $Result
        if ($window.IsVisible) { $window.Close() }
    }.GetNewClosure()
    $surface.Close = $closeSurface
    $surfaceReadyProperty = $Context.PSObject.Properties['OnSurfaceReady']
    $surfaceReadyHandler = [EventHandler]{
        param($sender,$eventArgs)
        if (-not $surfaceState.Published -and $null -ne $surfaceReadyProperty -and
            $surfaceReadyProperty.Value -is [scriptblock]) {
            $surfaceState.Published = $true
            & $surfaceReadyProperty.Value $surface | Out-Null
        }
    }.GetNewClosure()
    $closeClickHandler = [System.Windows.RoutedEventHandler]{
        param($sender,$eventArgs)
        $surfaceState.Result = 'UserCancelled'
        $window.Close()
    }.GetNewClosure()
    $keyHandler = [System.Windows.Input.KeyEventHandler]{
        param($sender,$eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
            $surfaceState.Result = 'UserCancelled'
            $window.Close()
            $eventArgs.Handled = $true
        }
    }.GetNewClosure()
    $window.Add_SourceInitialized($surfaceReadyHandler)
    $window.Add_KeyDown($keyHandler)
    $closeButton.Add_Click($closeClickHandler)

    $kit = [pscustomobject]@{
        Window = $window
        Lifecycle = $lifecycle
        Metadata = $metadata
        Close = $closeSurface
    }
    try {
        if ($TestAction) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000
            $window.Top = -10000
            $window.ShowActivated = $false
            $window.Show()
            $window.UpdateLayout()
            & $TestAction $kit | Out-Null
            if ($window.IsVisible) { $window.Close() }
        } else {
            $window.ShowDialog() | Out-Null
        }
    } catch {
        $surfaceState.Result = 'Failed'
        throw
    } finally {
        try {
            if ($window.IsVisible) { $window.Close() }
            $window.Remove_SourceInitialized($surfaceReadyHandler)
            $window.Remove_KeyDown($keyHandler)
            $repositoryLink.Remove_RequestNavigate($navigateHandler)
            $closeButton.Remove_Click($closeClickHandler)
        } finally {
            $surfaceClosedProperty = $Context.PSObject.Properties['OnSurfaceClosed']
            if ($null -ne $surfaceClosedProperty -and
                $surfaceClosedProperty.Value -is [scriptblock]) {
                & $surfaceClosedProperty.Value $surfaceState.Result $surface | Out-Null
            }
        }
    }
    $surfaceState.Result
}

function Clear-SnipWidgetWindow {
    param([System.Windows.Window]$Window)
    if ($script:WidgetWindow -eq $Window) { $script:WidgetWindow = $null }
}

function Show-FloatingWidget {
    [CmdletBinding()]
    param(
        $Context = $script:UtilityContext,
        [scriptblock]$TestAction
    )

    if ($null -eq $Context -or $null -eq $Context.PSObject.Properties['Settings']) {
        throw [ArgumentException]::new('The widget requires a settings context.', 'Context')
    }
    if (-not [bool]$Context.Settings.WidgetVisible) {
        if ($script:WidgetWindow -and $script:WidgetWindow.IsVisible) {
            $script:WidgetWindow.Close()
        }
        return $null
    }
    if ($script:WidgetWindow -and -not $TestAction) {
        if (-not $script:WidgetWindow.IsVisible) { $script:WidgetWindow.Show() }
        return $script:WidgetWindow
    }

    $submitProperty = $Context.PSObject.Properties['SubmitRequest']
    $settingsProperty = $Context.PSObject.Properties['OpenSettings']
    if ($null -eq $submitProperty -or $submitProperty.Value -isnot [scriptblock]) {
        throw [ArgumentException]::new('The widget requires a SubmitRequest service.', 'Context')
    }
    if ($null -eq $settingsProperty -or $settingsProperty.Value -isnot [scriptblock]) {
        throw [ArgumentException]::new('The widget requires an OpenSettings service.', 'Context')
    }
    $submitRequest = $submitProperty.Value
    $openSettings = $settingsProperty.Value
    $topologyProviderProperty = $Context.PSObject.Properties['GetDisplayTopology']
    $topologyProvider = if ($null -ne $topologyProviderProperty -and
        $topologyProviderProperty.Value -is [scriptblock]) {
        $topologyProviderProperty.Value
    } else {
        { New-SnipDisplayTopology -MonitorDescriptors @(Get-SnipMonitorDescriptors) }
    }
    $pointerProviderProperty = $Context.PSObject.Properties['GetPointerPhysicalPosition']
    $pointerProvider = if ($null -ne $pointerProviderProperty -and
        $pointerProviderProperty.Value -is [scriptblock]) {
        $pointerProviderProperty.Value
    } else {
        {
            $position = [System.Windows.Forms.Control]::MousePosition
            [pscustomobject]@{ X=[int]$position.X; Y=[int]$position.Y }
        }
    }
    $setWidgetPositionProperty = $Context.PSObject.Properties['SetWidgetPosition']
    $setWidgetPosition = if ($null -ne $setWidgetPositionProperty -and
        $setWidgetPositionProperty.Value -is [scriptblock]) {
        $setWidgetPositionProperty.Value
    } else {
        {
            param($hwnd,$bounds)
            [Native]::SetWindowPos(
                $hwnd, [IntPtr]::Zero,
                [int]$bounds.X, [int]$bounds.Y,
                [int]$bounds.Width, [int]$bounds.Height,
                [Native]::SWP_NOZORDER -bor [Native]::SWP_NOACTIVATE)
        }
    }

    [xml]$xaml = [xml](Get-SnipXamlText -Name 'FloatingWidget')
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    try { $window = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    [void](Initialize-SnipWindowTheme -Window $window)

    $widgetState = [pscustomobject]@{
        LastAnimationDuration = [timespan]::Zero
        Closed = $false
        ClosedHandler = $null
        LastValidMonitorId = $null
        Placement = $null
        PhysicalBounds = $null
        ShownPhysicalBounds = $null
        HiddenPhysicalBounds = $null
        CurrentPhysicalBounds = $null
    }
    $refreshWidgetPlacement = {
        param($PointerPhysicalPosition = $null)
        $topology = & $topologyProvider
        $pointer = if ($null -eq $PointerPhysicalPosition) {
            & $pointerProvider
        } else { $PointerPhysicalPosition }
        $placement = Get-SnipWidgetPlacement -Topology $topology `
            -PointerPhysicalPosition $pointer `
            -LastValidMonitorId $widgetState.LastValidMonitorId
        $pointerIsOnMonitor = $false
        foreach ($descriptor in @($topology.Descriptors)) {
            if ([double]$pointer.X -ge [double]$descriptor.X -and
                [double]$pointer.X -lt ([double]$descriptor.X + [double]$descriptor.Width) -and
                [double]$pointer.Y -ge [double]$descriptor.Y -and
                [double]$pointer.Y -lt ([double]$descriptor.Y + [double]$descriptor.Height)) {
                $pointerIsOnMonitor = $true
                break
            }
        }
        if ($pointerIsOnMonitor) { $widgetState.LastValidMonitorId = $placement.MonitorId }

        $scaleX = [double]$placement.Monitor.DpiX / 96.0
        $scaleY = [double]$placement.Monitor.DpiY / 96.0
        $width = [int][math]::Round([double]$window.Width * $scaleX)
        $height = [int][math]::Round([double]$window.Height * $scaleY)
        $workArea = $placement.WorkAreaPhysicalBounds
        $left = [int][math]::Round([double]$workArea.X +
            (([double]$workArea.Width - $width) / 2.0))
        $shownTop = [int][math]::Round([double]$workArea.Y + (10.0 * $scaleY))
        $hiddenTop = [int][math]::Round([double]$workArea.Y - $height + (9.0 * $scaleY))
        $widgetState.Placement = $placement
        $widgetState.PhysicalBounds = [pscustomobject]@{
            X=$left; Y=$hiddenTop; Width=$width; Height=$height
        }
        $widgetState.ShownPhysicalBounds = [pscustomobject]@{
            X=$left; Y=$shownTop; Width=$width; Height=$height
        }
        $widgetState.HiddenPhysicalBounds = [pscustomobject]@{
            X=$left; Y=$hiddenTop; Width=$width; Height=$height
        }
        $placement
    }.GetNewClosure()
    & $refreshWidgetPlacement | Out-Null

    $applyWidgetPosition = {
        param([Parameter(Mandatory)] $PhysicalBounds)
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($window)
        if ($helper.Handle -eq [IntPtr]::Zero) { return }
        [void](& $setWidgetPosition $helper.Handle $PhysicalBounds)
        $widgetState.CurrentPhysicalBounds = $PhysicalBounds
    }.GetNewClosure()
    $sourceInitializedHandler = [EventHandler]{
        param($sender,$eventArgs)
        & $applyWidgetPosition $widgetState.HiddenPhysicalBounds
    }.GetNewClosure()
    $window.Add_SourceInitialized($sourceInitializedHandler)
    $moveWidget = {
        param([bool]$Reveal)
        & $refreshWidgetPlacement | Out-Null
        $targetPhysicalBounds = if ($Reveal) {
            $widgetState.ShownPhysicalBounds
        } else {
            $widgetState.HiddenPhysicalBounds
        }
        $widgetState.LastAnimationDuration = [timespan]::Zero
        & $applyWidgetPosition $targetPhysicalBounds
    }.GetNewClosure()
    $reveal = { & $moveWidget $true }.GetNewClosure()
    $conceal = { & $moveWidget $false }.GetNewClosure()

    $buttons = [ordered]@{
        SmartBtn = $window.FindName('SmartBtn')
        FullBtn = $window.FindName('FullBtn')
        WindowBtn = $window.FindName('WindowBtn')
        SettingsBtn = $window.FindName('SettingsBtn')
    }
    $activeShortcutProperty = $Context.PSObject.Properties['ActiveShortcut']
    $activeShortcut = if ($null -ne $activeShortcutProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$activeShortcutProperty.Value)) {
        [string]$activeShortcutProperty.Value
    } elseif ($null -ne $Context.PSObject.Properties['RegisteredHotkey'] -and
        $null -ne $Context.RegisteredHotkey) {
        Format-SnipHotkey -Modifiers ([int]$Context.RegisteredHotkey.Modifiers) `
            -VirtualKey ([int]$Context.RegisteredHotkey.VirtualKey)
    } else { 'Unavailable' }
    $buttons.SmartBtn.ToolTip = "Smart capture ($activeShortcut)"
    $smartClick = [System.Windows.RoutedEventHandler]{ param($sender,$eventArgs) & $submitRequest 'Smart' ([timespan]::Zero) 'Widget' | Out-Null }.GetNewClosure()
    $fullClick = [System.Windows.RoutedEventHandler]{ param($sender,$eventArgs) & $submitRequest 'Full' ([timespan]::Zero) 'Widget' | Out-Null }.GetNewClosure()
    $windowClick = [System.Windows.RoutedEventHandler]{ param($sender,$eventArgs) & $submitRequest 'Window' ([timespan]::Zero) 'Widget' | Out-Null }.GetNewClosure()
    $settingsClick = [System.Windows.RoutedEventHandler]{ param($sender,$eventArgs) & $openSettings | Out-Null }.GetNewClosure()
    $buttons.SmartBtn.Add_Click($smartClick)
    $buttons.FullBtn.Add_Click($fullClick)
    $buttons.WindowBtn.Add_Click($windowClick)
    $buttons.SettingsBtn.Add_Click($settingsClick)

    $mouseEnterHandler = [System.Windows.Input.MouseEventHandler]{ param($sender,$eventArgs) & $reveal }.GetNewClosure()
    $mouseLeaveHandler = [System.Windows.Input.MouseEventHandler]{
        param($sender,$eventArgs)
        if (-not $window.IsMouseOver) { & $conceal }
    }.GetNewClosure()
    $window.Add_MouseEnter($mouseEnterHandler)
    $window.Add_MouseLeave($mouseLeaveHandler)

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [timespan]::FromMilliseconds(150)
    $timerTickHandler = [EventHandler]{
        param($sender,$eventArgs)
        $position = & $pointerProvider
        & $refreshWidgetPlacement $position | Out-Null
        $shownBounds = $widgetState.ShownPhysicalBounds
        $workArea = $widgetState.Placement.WorkAreaPhysicalBounds
        if ([double]$position.Y -le ([double]$workArea.Y + 4.0) -and
            [double]$position.X -ge [double]$shownBounds.X -and
            [double]$position.X -le ([double]$shownBounds.X + [double]$shownBounds.Width)) {
            & $reveal
        } elseif (-not $window.IsMouseOver -and
            [double]$position.Y -gt ([double]$shownBounds.Y + [double]$shownBounds.Height + 8.0)) {
            & $conceal
        }
    }.GetNewClosure()
    $timer.Add_Tick($timerTickHandler)
    $tickWidgetTimer = {
        $timerTickHandler.Invoke($timer, [EventArgs]::Empty)
    }.GetNewClosure()

    $lifecycleParameters = @{ Window = $window }
    $registerWindowProperty = $Context.PSObject.Properties['RegisterWindow']
    $unregisterWindowProperty = $Context.PSObject.Properties['UnregisterWindow']
    if ($null -ne $registerWindowProperty -and $registerWindowProperty.Value -is [scriptblock]) {
        $lifecycleParameters.Register = $registerWindowProperty.Value
    }
    if ($null -ne $unregisterWindowProperty -and $unregisterWindowProperty.Value -is [scriptblock]) {
        $lifecycleParameters.Unregister = $unregisterWindowProperty.Value
    }
    $lifecycle = Connect-SnipWindowLifecycle @lifecycleParameters
    $closedHandler = [EventHandler]{
        param($sender,$eventArgs)
        if ($widgetState.Closed) { return }
        $widgetState.Closed = $true
        $timer.Stop()
        $timer.Remove_Tick($timerTickHandler)
        $window.Remove_SourceInitialized($sourceInitializedHandler)
        $window.Remove_MouseEnter($mouseEnterHandler)
        $window.Remove_MouseLeave($mouseLeaveHandler)
        $buttons.SmartBtn.Remove_Click($smartClick)
        $buttons.FullBtn.Remove_Click($fullClick)
        $buttons.WindowBtn.Remove_Click($windowClick)
        $buttons.SettingsBtn.Remove_Click($settingsClick)
        Clear-SnipWidgetWindow -Window $window
        $window.Remove_Closed($widgetState.ClosedHandler)
    }.GetNewClosure()
    $widgetState.ClosedHandler = $closedHandler
    $window.Add_Closed($closedHandler)

    $click = {
        param([Parameter(Mandatory)] [string]$Name)
        if (-not $buttons.Contains($Name)) { throw [ArgumentException]::new("Unknown widget control '$Name'.") }
        $eventArgs = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)
        $buttons[$Name].RaiseEvent($eventArgs)
    }.GetNewClosure()
    $kit = [pscustomobject]@{
        Window = $window
        Lifecycle = $lifecycle
        Order = [string[]]@('Smart','Full','Window','Settings')
        Buttons = $buttons
        Click = $click
        Reveal = $reveal
        Conceal = $conceal
        TimerTick = $tickWidgetTimer
        State = $widgetState
    }

    $script:WidgetWindow = $window
    if ($TestAction) {
        $window.Left = -10000
        $window.Top = -10000
        $window.Show()
        $window.UpdateLayout()
        try { & $TestAction $kit | Out-Null }
        finally {
            if ($window.IsVisible) { $window.Close() }
            Clear-SnipWidgetWindow -Window $window
        }
        return $null
    }

    $window.Show()
    $timer.Start()
    $window
}

function Register-SnipHotkeyBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [IntPtr]$Hwnd,
        [Parameter(Mandatory)] [object]$Binding,
        [Parameter(Mandatory)] [scriptblock]$Register
    )

    $activeBinding = $null
    $candidateError = $null
    try {
        $modifiers = [int]$Binding.Modifiers
        $virtualKey = [int]$Binding.VirtualKey
        if (-not (Test-SnipHotkeyDefinition -Modifiers $modifiers -VirtualKey $virtualKey)) {
            throw [ArgumentException]::new('The hotkey definition is not supported.')
        }
        $normalized = [pscustomobject][ordered]@{
            Modifiers = $modifiers
            VirtualKey = $virtualKey
        }
        if ([bool](& $Register $Hwnd 1 $modifiers $virtualKey)) {
            $activeBinding = $normalized
        } else {
            $candidateError = "RegisterHotKey rejected $(Format-SnipHotkey -Modifiers $modifiers -VirtualKey $virtualKey)."
        }
    } catch {
        $candidateError = $_.Exception.Message
    }

    [pscustomobject]@{
        Success = $null -ne $activeBinding
        ActiveBinding = $activeBinding
        CandidateError = $candidateError
        RollbackError = $null
    }
}

function Set-SnipHotkeyBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Context,
        [Parameter(Mandatory)] [object]$Candidate,
        [Parameter(Mandatory)] [scriptblock]$Register,
        [Parameter(Mandatory)] [scriptblock]$Unregister
    )

    $hwnd = [IntPtr]::Zero
    $hwndProperty = $Context.PSObject.Properties['Hwnd']
    if ($null -ne $hwndProperty -and $null -ne $hwndProperty.Value) {
        $hwnd = [IntPtr]$hwndProperty.Value
    }

    $previousBinding = $null
    if ($null -ne $Context.RegisteredHotkey) {
        $previousBinding = [pscustomobject][ordered]@{
            Modifiers = [int]$Context.RegisteredHotkey.Modifiers
            VirtualKey = [int]$Context.RegisteredHotkey.VirtualKey
        }
    }

    $candidateError = $null
    $rollbackError = $null
    try {
        $candidateBinding = [pscustomobject][ordered]@{
            Modifiers = [int]$Candidate.Modifiers
            VirtualKey = [int]$Candidate.VirtualKey
        }
        if (-not (Test-SnipHotkeyDefinition -Modifiers $candidateBinding.Modifiers `
            -VirtualKey $candidateBinding.VirtualKey)) {
            throw [ArgumentException]::new('The hotkey definition is not supported.')
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            ActiveBinding = $previousBinding
            CandidateError = $_.Exception.Message
            RollbackError = $null
        }
    }

    if ($null -ne $previousBinding) {
        try {
            if (-not [bool](& $Unregister $hwnd 1)) {
                throw [InvalidOperationException]::new('Could not unregister the active hotkey.')
            }
        } catch {
            return [pscustomobject]@{
                Success = $false
                ActiveBinding = $previousBinding
                CandidateError = $_.Exception.Message
                RollbackError = $null
            }
        }
    }

    $candidateResult = Register-SnipHotkeyBinding -Hwnd $hwnd -Binding $candidateBinding -Register $Register
    if (-not $candidateResult.Success) {
        $candidateError = $candidateResult.CandidateError
        $activeBinding = $null
        if ($null -ne $previousBinding) {
            $rollbackResult = Register-SnipHotkeyBinding -Hwnd $hwnd -Binding $previousBinding -Register $Register
            if ($rollbackResult.Success) {
                $activeBinding = $rollbackResult.ActiveBinding
                $Context.RegisteredHotkey = $activeBinding
            } else {
                $rollbackError = "Could not restore the previous hotkey: $($rollbackResult.CandidateError)"
                $Context.RegisteredHotkey = $null
            }
        } else {
            $Context.RegisteredHotkey = $null
        }

        $diagPath = $null
        $settingsPathProperty = $Context.PSObject.Properties['SettingsPath']
        if ($null -ne $settingsPathProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$settingsPathProperty.Value)) {
            $diagPath = Join-Path (Split-Path $settingsPathProperty.Value -Parent) 'logs\snipit.log'
        }
        $message = "Hotkey replacement failed: $candidateError"
        if ($rollbackError) { $message += " Rollback failed: $rollbackError" }
        Write-SnipDiag -Message $message -Path $diagPath

        return [pscustomobject]@{
            Success = $false
            ActiveBinding = $activeBinding
            CandidateError = $candidateError
            RollbackError = $rollbackError
        }
    }

    $updatedSettings = [pscustomobject][ordered]@{
        Version = $Context.Settings.Version
        Hotkey = $candidateBinding
        SaveFolder = $Context.Settings.SaveFolder
        SaveFormat = $Context.Settings.SaveFormat
        LaunchAtSignIn = $Context.Settings.LaunchAtSignIn
        WidgetVisible = $Context.Settings.WidgetVisible
    }
    try {
        Save-SnipSettings -Settings $updatedSettings -Path $Context.SettingsPath
    } catch {
        $candidateError = "The new hotkey registered but its settings could not be saved: $($_.Exception.Message)"
        $activeBinding = $null
        $candidateRemoved = $false
        try {
            if (-not [bool](& $Unregister $hwnd 1)) {
                throw [InvalidOperationException]::new('Could not unregister the unsaved candidate hotkey.')
            }
            $candidateRemoved = $true
        } catch {
            $candidateText = Format-SnipHotkey -Modifiers $candidateBinding.Modifiers `
                -VirtualKey $candidateBinding.VirtualKey
            $rollbackError = "The unsaved shortcut $candidateText may remain active because native cleanup failed: $($_.Exception.Message)"
            $activeBinding = $candidateBinding
            $Context.RegisteredHotkey = $candidateBinding
        }
        if ($candidateRemoved) {
            try {
                if ($null -ne $previousBinding) {
                    $rollbackResult = Register-SnipHotkeyBinding -Hwnd $hwnd `
                        -Binding $previousBinding -Register $Register
                    if (-not $rollbackResult.Success) {
                        throw [InvalidOperationException]::new($rollbackResult.CandidateError)
                    }
                    $Context.RegisteredHotkey = $rollbackResult.ActiveBinding
                } else {
                    $Context.RegisteredHotkey = $null
                }
                $activeBinding = $Context.RegisteredHotkey
            } catch {
                $rollbackError = "Could not restore the previous hotkey: $($_.Exception.Message)"
                $Context.RegisteredHotkey = $null
                $activeBinding = $null
            }
        }
        $diagPath = Join-Path (Split-Path $Context.SettingsPath -Parent) 'logs\snipit.log'
        $message = "Hotkey persistence failed: $candidateError"
        if ($rollbackError) { $message += " Rollback failed: $rollbackError" }
        Write-SnipDiag -Message $message -Path $diagPath
        return [pscustomobject]@{
            Success = $false
            ActiveBinding = $activeBinding
            CandidateError = $candidateError
            RollbackError = $rollbackError
        }
    }

    $Context.Settings.Hotkey = $candidateBinding
    $Context.RegisteredHotkey = $candidateBinding
    [pscustomobject]@{
        Success = $true
        ActiveBinding = $candidateBinding
        CandidateError = $null
        RollbackError = $null
    }
}

# One factory for every Display submenu entry, so the items seeded when the menu
# is built and the items rebuilt on DropDownOpening are wired identically: same
# Name, same Tag shape, same click handler. Placeholder rows carry no handler.
function New-SnipDisplayMenuItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Model,
        [Parameter(Mandatory)] [scriptblock]$SubmitRequest
    )

    $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$Model.Text)
    $item.Name = [string]$Model.Name
    $item.Enabled = [bool]$Model.Enabled
    $item.Tag = [pscustomobject]@{
        MonitorId = [string]$Model.MonitorId
        SubmitRequest = $SubmitRequest
        ClickHandler = $null
        IsPlaceholder = [bool]$Model.IsPlaceholder
    }
    if (-not [bool]$Model.IsPlaceholder) {
        $displayClick = [EventHandler]{
            param($sender,$eventArgs)
            & $sender.Tag.SubmitRequest 'Display' ([timespan]::Zero) 'Tray' `
                ([string]$sender.Tag.MonitorId) | Out-Null
        }.GetNewClosure()
        $item.Tag.ClickHandler = $displayClick
        $item.Add_Click($displayClick)
    }
    $item
}

# The tray menu is WinForms, so it never inherits the WPF Fluent theme that
# Initialize-SnipWindowTheme applies to every window. Rather than reimplement
# that theme in GDI+, it uses the shell's own ToolStripProfessionalRenderer and
# the system menu colours: no owner drawing, no colours of ours, and High
# Contrast stays correct for free. -ThemeMode is recorded on the menu's Tag for
# the suite (the tray rebuilds its menu per open) but nothing is painted from it.
function New-SnipTrayMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [ValidateSet('Light','Dark')]
        [string]$ThemeMode = (Get-SnipSystemThemeMode)
    )

    foreach ($requiredService in 'SubmitRequest','OpenSettings','OpenAbout','Exit') {
        $property = $Context.PSObject.Properties[$requiredService]
        if ($null -eq $property -or $property.Value -isnot [scriptblock]) {
            throw [ArgumentException]::new("Tray context is missing the $requiredService service.", 'Context')
        }
    }
    # Stock WinForms chrome. The tray menu is the one surface WPF's Fluent theme
    # cannot reach, so it uses the system ToolStripProfessionalRenderer with the
    # system menu colours instead of a palette of ours. No owner drawing, no
    # custom colours: selection, borders, separators and the check glyph are all
    # the shell's own, which is also what keeps High Contrast correct for free.
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $menu.Name = 'SnipTrayMenu'
    $menu.ShowImageMargin = $false
    $menu.ShowCheckMargin = $true
    $menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::Professional
    $renderer = [System.Windows.Forms.ToolStripProfessionalRenderer]::new()
    $renderer.RoundedEdges = $true
    $menu.Renderer = $renderer

    $submitRequest = $Context.SubmitRequest
    $openSettings = $Context.OpenSettings
    $openAbout = $Context.OpenAbout
    $exitApplication = $Context.Exit
    $handlerList = [System.Collections.Generic.List[object]]::new()
    $items = [ordered]@{}
    $activeShortcutProperty = $Context.PSObject.Properties['ActiveShortcut']
    $activeShortcut = if ($null -ne $activeShortcutProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$activeShortcutProperty.Value)) {
        [string]$activeShortcutProperty.Value
    } else { 'Unavailable' }

    $items.Smart = [System.Windows.Forms.ToolStripMenuItem]::new("Smart capture ($activeShortcut)")
    $items.Smart.Name = 'Smart'
    $smartClick = [EventHandler]{ param($sender,$eventArgs) & $submitRequest 'Smart' ([timespan]::Zero) | Out-Null }.GetNewClosure()
    $items.Smart.Add_Click($smartClick); $handlerList.Add($smartClick)
    [void]$menu.Items.Add($items.Smart)

    $items.Full = [System.Windows.Forms.ToolStripMenuItem]::new('Full desktop')
    $items.Full.Name = 'Full'
    $fullClick = [EventHandler]{ param($sender,$eventArgs) & $submitRequest 'Full' ([timespan]::Zero) | Out-Null }.GetNewClosure()
    $items.Full.Add_Click($fullClick); $handlerList.Add($fullClick)
    [void]$menu.Items.Add($items.Full)

    $items.Window = [System.Windows.Forms.ToolStripMenuItem]::new('Active window')
    $items.Window.Name = 'Window'
    $windowClick = [EventHandler]{ param($sender,$eventArgs) & $submitRequest 'Window' ([timespan]::Zero) | Out-Null }.GetNewClosure()
    $items.Window.Add_Click($windowClick); $handlerList.Add($windowClick)
    [void]$menu.Items.Add($items.Window)

    $items.Display = [System.Windows.Forms.ToolStripMenuItem]::new('Display')
    $items.Display.Name = 'Display'
    [void]$menu.Items.Add($items.Display)
    $topologyProviderProperty = $Context.PSObject.Properties['GetDisplayTopology']
    $displayTopologyProvider = if ($null -ne $topologyProviderProperty -and
        $topologyProviderProperty.Value -is [scriptblock]) {
        $topologyProviderProperty.Value
    } else {
        { New-SnipDisplayTopology -MonitorDescriptors @(Get-SnipMonitorDescriptors) }
    }
    $displayChildHandlers = [System.Collections.Generic.List[object]]::new()
    $clearDisplayItems = {
        foreach ($child in @($items.Display.DropDownItems)) {
            $handler = $child.Tag
            if ($handler -is [pscustomobject] -and
                $null -ne $handler.PSObject.Properties['ClickHandler'] -and
                $handler.ClickHandler -is [EventHandler]) {
                $child.Remove_Click($handler.ClickHandler)
            }
            try { $child.Dispose() } catch {}
        }
        $items.Display.DropDownItems.Clear()
        $displayChildHandlers.Clear()
    }.GetNewClosure()
    $rebuildDisplayItems = {
        & $clearDisplayItems
        # Enumeration is hardware-facing and now runs during construction too, so
        # a failing provider must degrade to the placeholder rather than take the
        # whole tray menu down with it.
        $descriptors = @()
        try {
            $topology = & $displayTopologyProvider
            if ($null -ne $topology) { $descriptors = @($topology.Descriptors) }
        } catch {
            $descriptors = @()
        }
        foreach ($model in @(Get-SnipDisplayMenuModel -Descriptors $descriptors)) {
            $displayItem = New-SnipDisplayMenuItem -Model $model -SubmitRequest $submitRequest
            if ($displayItem.Tag.ClickHandler -is [EventHandler]) {
                $displayChildHandlers.Add($displayItem.Tag.ClickHandler)
            }
            [void]$items.Display.DropDownItems.Add($displayItem)
        }
    }.GetNewClosure()
    # Seed the submenu now. WinForms gates both the submenu arrow and the whole
    # open path on HasDropDownItems, so a Display item added with an empty
    # DropDownItems collection never raises DropDownOpening and can never open:
    # populating it only from that event left the submenu permanently dead.
    & $rebuildDisplayItems
    $displayOpeningHandler = [EventHandler]{
        param($sender,$eventArgs)
        & $rebuildDisplayItems
    }.GetNewClosure()
    # Still rebuilt on every open, so hot-plugged or removed monitors show up.
    $items.Display.Add_DropDownOpening($displayOpeningHandler)

    $items.Separator1 = [System.Windows.Forms.ToolStripSeparator]::new()
    $items.Separator1.Name = 'Separator1'
    [void]$menu.Items.Add($items.Separator1)

    $items.Delay = [System.Windows.Forms.ToolStripMenuItem]::new('Delay capture')
    $items.Delay.Name = 'Delay'
    foreach ($delaySpec in @(
        [pscustomobject]@{ Text='Smart in 3 seconds'; Mode='Smart'; Seconds=3 },
        [pscustomobject]@{ Text='Smart in 5 seconds'; Mode='Smart'; Seconds=5 },
        [pscustomobject]@{ Text='Smart in 10 seconds'; Mode='Smart'; Seconds=10 },
        [pscustomobject]@{ Text='Full in 3 seconds'; Mode='Full'; Seconds=3 },
        [pscustomobject]@{ Text='Window in 3 seconds'; Mode='Window'; Seconds=3 })) {
        $delayItem = [System.Windows.Forms.ToolStripMenuItem]::new($delaySpec.Text)
        $delayItem.Tag = $delaySpec
        $delayClick = [EventHandler]{
            param($sender,$eventArgs)
            & $submitRequest $sender.Tag.Mode ([timespan]::FromSeconds([int]$sender.Tag.Seconds)) | Out-Null
        }.GetNewClosure()
        $delayItem.Add_Click($delayClick)
        $handlerList.Add($delayClick)
        [void]$items.Delay.DropDownItems.Add($delayItem)
    }
    [void]$menu.Items.Add($items.Delay)

    $items.Settings = [System.Windows.Forms.ToolStripMenuItem]::new('Settings')
    $items.Settings.Name = 'Settings'
    $settingsClick = [EventHandler]{ param($sender,$eventArgs) & $openSettings | Out-Null }.GetNewClosure()
    $items.Settings.Add_Click($settingsClick); $handlerList.Add($settingsClick)
    [void]$menu.Items.Add($items.Settings)

    $items.Widget = [System.Windows.Forms.ToolStripMenuItem]::new('Edge-reveal widget')
    $items.Widget.Name = 'Widget'
    $items.Widget.CheckOnClick = $true
    $items.Widget.Checked = [bool]$Context.Settings.WidgetVisible
    $toggleWidgetProperty = $Context.PSObject.Properties['SetWidgetVisible']
    $widgetClick = [EventHandler]{
        param($sender,$eventArgs)
        $visible = [bool]$sender.Checked
        if ($null -ne $toggleWidgetProperty -and $toggleWidgetProperty.Value -is [scriptblock]) {
            & $toggleWidgetProperty.Value $visible | Out-Null
        } else {
            $Context.Settings.WidgetVisible = $visible
        }
    }.GetNewClosure()
    $items.Widget.Add_Click($widgetClick); $handlerList.Add($widgetClick)
    [void]$menu.Items.Add($items.Widget)

    $items.OpenFolder = [System.Windows.Forms.ToolStripMenuItem]::new('Open snips folder')
    $items.OpenFolder.Name = 'OpenFolder'
    $openFolderProperty = $Context.PSObject.Properties['OpenFolder']
    $openFolderClick = [EventHandler]{
        param($sender,$eventArgs)
        if ($null -ne $openFolderProperty -and $openFolderProperty.Value -is [scriptblock]) {
            & $openFolderProperty.Value | Out-Null
        }
    }.GetNewClosure()
    $items.OpenFolder.Add_Click($openFolderClick); $handlerList.Add($openFolderClick)
    [void]$menu.Items.Add($items.OpenFolder)

    $items.Separator2 = [System.Windows.Forms.ToolStripSeparator]::new()
    $items.Separator2.Name = 'Separator2'
    [void]$menu.Items.Add($items.Separator2)

    $items.About = [System.Windows.Forms.ToolStripMenuItem]::new('About SnipIT')
    $items.About.Name = 'About'
    $aboutClick = [EventHandler]{ param($sender,$eventArgs) & $openAbout | Out-Null }.GetNewClosure()
    $items.About.Add_Click($aboutClick); $handlerList.Add($aboutClick)
    [void]$menu.Items.Add($items.About)

    $items.Uninstall = [System.Windows.Forms.ToolStripMenuItem]::new('Uninstall')
    $items.Uninstall.Name = 'Uninstall'
    $uninstallProperty = $Context.PSObject.Properties['Uninstall']
    $uninstallClick = [EventHandler]{
        param($sender,$eventArgs)
        if ($null -ne $uninstallProperty -and $uninstallProperty.Value -is [scriptblock]) {
            & $uninstallProperty.Value | Out-Null
        }
    }.GetNewClosure()
    $items.Uninstall.Add_Click($uninstallClick); $handlerList.Add($uninstallClick)
    [void]$menu.Items.Add($items.Uninstall)

    $items.Exit = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
    $items.Exit.Name = 'Exit'
    $exitClick = [EventHandler]{ param($sender,$eventArgs) & $exitApplication | Out-Null }.GetNewClosure()
    $items.Exit.Add_Click($exitClick); $handlerList.Add($exitClick)
    [void]$menu.Items.Add($items.Exit)

    $registerWindowProperty = $Context.PSObject.Properties['RegisterWindow']
    $unregisterWindowProperty = $Context.PSObject.Properties['UnregisterWindow']
    $registerMenuWindow = if ($null -ne $registerWindowProperty -and
        $registerWindowProperty.Value -is [scriptblock]) { $registerWindowProperty.Value } else { $null }
    $unregisterMenuWindow = if ($null -ne $unregisterWindowProperty -and
        $unregisterWindowProperty.Value -is [scriptblock]) { $unregisterWindowProperty.Value } else { $null }
    $dropDownLifecycles = [System.Collections.Generic.List[object]]::new()
    $connectDropDownLifecycle = {
        param([Parameter(Mandatory)] [System.Windows.Forms.ToolStripDropDown]$DropDown)

        $windowState = [pscustomobject]@{
            DropDown = $DropDown
            Handle = [IntPtr]::Zero
            Registered = $false
            OpenedHandler = $null
            ClosedHandler = $null
            DisposedHandler = $null
            RegisterWindow = $registerMenuWindow
            UnregisterWindow = $unregisterMenuWindow
        }
        $disconnect = {
            if (-not $windowState.Registered) { return }
            try {
                if ($null -ne $windowState.UnregisterWindow -and
                    $windowState.Handle -ne [IntPtr]::Zero) {
                    & $windowState.UnregisterWindow $windowState.Handle
                }
            } finally {
                $windowState.Handle = [IntPtr]::Zero
                $windowState.Registered = $false
            }
        }.GetNewClosure()
        $opened = [EventHandler]{
            param($sender,$eventArgs)
            if ($windowState.Registered -or $null -eq $windowState.RegisterWindow) { return }
            $handle = $DropDown.Handle
            if ($handle -eq [IntPtr]::Zero) { return }
            & $windowState.RegisterWindow $handle
            $windowState.Handle = $handle
            $windowState.Registered = $true
        }.GetNewClosure()
        $closed = [System.Windows.Forms.ToolStripDropDownClosedEventHandler]{
            param($sender,$eventArgs)
            & $disconnect
        }.GetNewClosure()
        $disposed = [EventHandler]{
            param($sender,$eventArgs)
            try { & $disconnect }
            finally {
                $DropDown.Remove_Opened($windowState.OpenedHandler)
                $DropDown.Remove_Closed($windowState.ClosedHandler)
                $DropDown.Remove_Disposed($windowState.DisposedHandler)
            }
        }.GetNewClosure()
        $windowState.OpenedHandler = $opened
        $windowState.ClosedHandler = $closed
        $windowState.DisposedHandler = $disposed
        $DropDown.Add_Opened($opened)
        $DropDown.Add_Closed($closed)
        $DropDown.Add_Disposed($disposed)
        $dropDownLifecycles.Add($windowState)
        $windowState
    }.GetNewClosure()

    $pendingDropDowns = [System.Collections.Generic.Queue[System.Windows.Forms.ToolStripDropDown]]::new()
    # Display is seeded, so the child walk finds it like any other submenu; the
    # explicit enqueue stays as the guarantee that its drop-down is styled and
    # lifecycle-tracked, and the visited set keeps that from double-registering.
    $visitedDropDowns = [System.Collections.Generic.HashSet[object]]::new()
    $pendingDropDowns.Enqueue($menu)
    $pendingDropDowns.Enqueue($items.Display.DropDown)
    while ($pendingDropDowns.Count -gt 0) {
        $dropDown = $pendingDropDowns.Dequeue()
        if (-not $visitedDropDowns.Add($dropDown)) { continue }
        # One renderer instance for the whole tree so nested drop-downs cannot
        # fall back to a different stock look than the root.
        $dropDown.Renderer = $renderer
        $dropDown.BackColor = $menu.BackColor
        $dropDown.ForeColor = $menu.ForeColor
        $dropDown.Font = $menu.Font
        $dropDown.Margin = $menu.Margin
        $dropDown.Padding = $menu.Padding
        if ($dropDown -is [System.Windows.Forms.ToolStripDropDownMenu]) {
            $dropDown.ShowImageMargin = $menu.ShowImageMargin
            $dropDown.ShowCheckMargin = $menu.ShowCheckMargin
        }
        & $connectDropDownLifecycle $dropDown | Out-Null
        foreach ($item in $dropDown.Items) {
            if ($item -is [System.Windows.Forms.ToolStripDropDownItem] -and
                $item.HasDropDownItems) {
                $pendingDropDowns.Enqueue($item.DropDown)
            }
        }
    }
    $rootWindowState = $dropDownLifecycles[0]

    $state = [pscustomobject]@{
        ThemeMode = $ThemeMode
        OwnerDrawn = $false
        PrimaryOrder = [string[]]@('Smart','Full','Window','Display','Settings','About','Exit')
        Order = [string[]]@(
            'Smart','Full','Window','Display','Separator1','Delay','Settings','Widget',
            'OpenFolder','Separator2','About','Uninstall','Exit')
        Items = $items
        Handlers = $handlerList
        Renderer = $renderer
        WindowState = $rootWindowState
        OpenedHandler = $rootWindowState.OpenedHandler
        ClosedHandler = $rootWindowState.ClosedHandler
        DropDownLifecycles = $dropDownLifecycles
        DisplayOpeningHandler = $displayOpeningHandler
        DisplayChildHandlers = $displayChildHandlers
        ClearDisplayItems = $clearDisplayItems
        DisposeHandler = $null
    }
    $menu.Tag = $state
    $disposeHandler = [EventHandler]{
        param($sender,$eventArgs)
        $items.Display.Remove_DropDownOpening($state.DisplayOpeningHandler)
        & $state.ClearDisplayItems
        $menu.Remove_Disposed($state.DisposeHandler)
    }.GetNewClosure()
    $state.DisposeHandler = $disposeHandler
    $menu.Add_Disposed($disposeHandler)
    $menu
}

$hotkeyForm = $null

$tray = $null

$menu = $null

$trayDoubleClickHandler = $null

$hkWin = $null

$registeredHotkey = $null

$applicationExitHandler = $null

$processExitHandler = $null

$script:SnipEmergencyTeardownDone = $false

try {
$bootstrapReady = & $script:SnipBootstrapInitializer -Phase Bootstrap

if (-not $bootstrapReady) { return }

& $script:SnipNativeInitializer

$null = & $script:SnipBootstrapInitializer -Phase Settings

$script:SnipBootstrapInitializer = $null

$script:SnipNativeInitializer = $null

if ($env:SNIPIT_TEST_MODE) { return }

# Before the first Form, NotifyIcon or ContextMenuStrip: WinForms latches its
# palette on first use, so the tray menu only follows the Windows theme if the
# opt-in happens here rather than anywhere later.
[void](Enable-SnipWinFormsColorMode)

$hotkeyForm = New-Object System.Windows.Forms.Form

$hotkeyForm.FormBorderStyle = 'FixedToolWindow'

$hotkeyForm.ShowInTaskbar = $false

$hotkeyForm.Opacity = 0

$hotkeyForm.Size = New-Object System.Drawing.Size 1, 1

$hotkeyForm.StartPosition = 'Manual'

$hotkeyForm.Location = New-Object System.Drawing.Point -2000, -2000

$HOTKEY_SMART = 1

$WM_HOTKEY = 0x0312

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

Register-SelfWindowHandle -Hwnd $hotkeyForm.Handle

if ($script:ConsoleHwnd) { Register-SelfWindowHandle -Hwnd $script:ConsoleHwnd }

$postToHost = {
    param($work)
    if ($null -eq $hotkeyForm -or $hotkeyForm.IsDisposed -or
        -not $hotkeyForm.IsHandleCreated) { return $false }
    $postedAction = [Action]{ & $work }.GetNewClosure()
    [void]$hotkeyForm.BeginInvoke($postedAction)
    return $true
}.GetNewClosure()

$script:CaptureCoordinator = New-SnipCaptureCoordinator `
    -Post $postToHost `
    -Services (New-SnipRuntimeCaptureServices) `
    -Settings $script:Settings

$hkWin = New-Object HotkeyWindow $hotkeyForm

$hkWin.Callback = [Action[int]]{
    param([int]$id)
    try {
        if ($id -eq $HOTKEY_SMART) {
            Request-SnipCapture -Coordinator $script:CaptureCoordinator `
                -Mode Smart -Source Hotkey | Out-Null
        }
    } catch {
        Write-SnipDiag -Message 'Hotkey capture failed' -ErrorRecord $_
        try {
            $script:tray.BalloonTipTitle = 'SnipIT error'
            $script:tray.BalloonTipText  = $_.Exception.Message
            $script:tray.ShowBalloonTip(3000)
        } catch {}
    }
}

$registerNativeHotkey = {
    param($hwnd, $id, $modifiers, $virtualKey)
    [Native]::RegisterHotKey($hwnd, $id, $modifiers, $virtualKey)
}

$initialHotkeyResult = Register-SnipHotkeyBinding -Hwnd $hotkeyForm.Handle `
    -Binding $script:Settings.Hotkey -Register $registerNativeHotkey

$registeredHotkey = $initialHotkeyResult.ActiveBinding

$script:CaptureCoordinator.RegisteredHotkey = $registeredHotkey

$configuredHotkeyText = Format-SnipHotkey -Modifiers $script:Settings.Hotkey.Modifiers `
    -VirtualKey $script:Settings.Hotkey.VirtualKey

$hotkeyText = if ($registeredHotkey) {
    Format-SnipHotkey -Modifiers $registeredHotkey.Modifiers -VirtualKey $registeredHotkey.VirtualKey
} else {
    'Unavailable'
}

$script:tray = New-Object System.Windows.Forms.NotifyIcon

$tray = $script:tray

$tray.Visible = $true

$tray.Text = if ($registeredHotkey) { "SnipIT - $hotkeyText to snip" } else { 'SnipIT - use tray to capture' }

try {
    # Ask for the shell's small-icon metric so the multi-entry .ico resolves to
    # the 16/24 px entry instead of squashing the 256 px master.
    $tray.Icon = New-Object System.Drawing.Icon (
        (Get-SnipITIconPath), [System.Windows.Forms.SystemInformation]::SmallIconSize)
} catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }

$utilityState = [pscustomobject]@{
    Coordinator = $script:CaptureCoordinator
    Tray = $tray
    Menu = $null
    Context = $null
}

$installPathsForUtilities = $script:InstallPaths

$unregisterNativeHotkey = {
    param($hwnd, $id)
    [Native]::UnregisterHotKey($hwnd, $id)
}

$submitUtilityRequest = {
    param(
        [string]$Mode,
        [timespan]$Delay = [timespan]::Zero,
        [string]$Source = 'Tray',
        [string]$MonitorId
    )
    Request-SnipCapture -Coordinator $utilityState.Coordinator `
        -Mode $Mode -Delay $Delay -Source $Source -MonitorId $MonitorId | Out-Null
}.GetNewClosure()

$getDisplayTopology = {
    New-SnipDisplayTopology -MonitorDescriptors @(Get-SnipMonitorDescriptors)
}.GetNewClosure()

$getPointerPhysicalPosition = {
    $position = [System.Windows.Forms.Control]::MousePosition
    [pscustomobject]@{ X=[int]$position.X; Y=[int]$position.Y }
}.GetNewClosure()

$publishAuxiliarySurface = {
    param($surface)
    Set-SnipAuxiliarySurface -Coordinator $utilityState.Coordinator -Surface $surface
}.GetNewClosure()

$completeAuxiliarySurface = {
    param([string]$Result, $surface)
    Complete-SnipAuxiliarySurface -Coordinator $utilityState.Coordinator `
        -Surface $surface -Result $Result | Out-Null
}.GetNewClosure()

$openSettings = {
    if ($utilityState.Coordinator.Phase -ne 'Idle') {
        $utilityState.Tray.BalloonTipTitle = 'SnipIT is busy'
        $utilityState.Tray.BalloonTipText = 'Finish or cancel the current capture before opening Settings.'
        $utilityState.Tray.ShowBalloonTip(2500)
        return
    }
    try { Show-SettingsWindow -Context $utilityState.Context | Out-Null }
    catch {
        Write-SnipDiag -Message 'Settings window failed' -ErrorRecord $_
        $utilityState.Tray.BalloonTipTitle = 'SnipIT Settings error'
        $utilityState.Tray.BalloonTipText = $_.Exception.Message
        $utilityState.Tray.ShowBalloonTip(3000)
    }
}.GetNewClosure()

$openAbout = {
    if ($utilityState.Coordinator.Phase -ne 'Idle') {
        $utilityState.Tray.BalloonTipTitle = 'SnipIT is busy'
        $utilityState.Tray.BalloonTipText = 'Finish or cancel the current capture before opening About.'
        $utilityState.Tray.ShowBalloonTip(2500)
        return
    }
    try { Show-AboutWindow -Context $utilityState.Context | Out-Null }
    catch {
        Write-SnipDiag -Message 'About window failed' -ErrorRecord $_
        $utilityState.Tray.BalloonTipTitle = 'SnipIT About error'
        $utilityState.Tray.BalloonTipText = $_.Exception.Message
        $utilityState.Tray.ShowBalloonTip(3000)
    }
}.GetNewClosure()

$syncStartup = {
    param($settings)
    Sync-SnipStartupShortcut -Settings $settings -Paths $installPathsForUtilities
}.GetNewClosure()

$setWidgetVisible = {
    param([bool]$Visible)
    $previous = [bool]$utilityState.Context.Settings.WidgetVisible
    if ($previous -ne $Visible) {
        $utilityState.Context.Settings.WidgetVisible = $Visible
        try {
            Save-SnipSettings -Settings $utilityState.Context.Settings `
                -Path $utilityState.Context.SettingsPath
        } catch {
            $utilityState.Context.Settings.WidgetVisible = $previous
            $Visible = $previous
            Write-SnipDiag -Message 'Widget visibility could not be saved' -ErrorRecord $_
            $utilityState.Tray.BalloonTipTitle = 'SnipIT Settings error'
            $utilityState.Tray.BalloonTipText = 'Widget visibility could not be saved.'
            $utilityState.Tray.ShowBalloonTip(3000)
        }
    }
    if ($utilityState.Menu -and $utilityState.Menu.Tag -and
        $utilityState.Menu.Tag.Items['Widget']) {
        $utilityState.Menu.Tag.Items['Widget'].Checked = $Visible
    }
    Show-FloatingWidget -Context $utilityState.Context | Out-Null
}.GetNewClosure()

$openFolder = {
    $directory = [string]$utilityState.Context.Settings.SaveFolder
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Start-Process explorer.exe -ArgumentList $directory
}.GetNewClosure()

$exitApplication = {
    Stop-SnipCaptureCoordinator -Coordinator $utilityState.Coordinator
    $utilityState.Tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}.GetNewClosure()

$uninstallApplication = {
    $response = [System.Windows.Forms.MessageBox]::Show(
        'Remove SnipIT shortcuts and AppData folder?',
        'Uninstall SnipIT', 'YesNo', 'Warning')
    if ($response -eq 'Yes') {
        Stop-SnipCaptureCoordinator -Coordinator $utilityState.Coordinator
        Uninstall-SnipIT
        $utilityState.Tray.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    }
}.GetNewClosure()

$hotkeyChanged = {
    param($result)
    $active = $result.ActiveBinding
    $utilityState.Coordinator.RegisteredHotkey = $active
    $utilityState.Context.RegisteredHotkey = $active
    $text = if ($null -eq $active) {
        'Unavailable'
    } else {
        Format-SnipHotkey -Modifiers ([int]$active.Modifiers) -VirtualKey ([int]$active.VirtualKey)
    }
    $utilityState.Context.ActiveShortcut = $text
    $utilityState.Tray.Text = if ($null -eq $active) { 'SnipIT - use tray to capture' } else { "SnipIT - $text to snip" }
    if ($utilityState.Menu -and $utilityState.Menu.Tag -and
        $utilityState.Menu.Tag.Items['Smart']) {
        $utilityState.Menu.Tag.Items['Smart'].Text = "Smart capture ($text)"
    }
}.GetNewClosure()

$script:UtilityContext = [pscustomobject][ordered]@{
    AppVersion = $script:SnipITAppVersion
    Repository = 'https://github.com/RandomCodeSpace/snipIT'
    License = 'MIT License'
    Settings = $script:Settings
    SettingsPath = $script:SettingsPath
    RegisteredHotkey = $registeredHotkey
    ActiveShortcut = $hotkeyText
    Hwnd = $hotkeyForm.Handle
    RegisterHotkey = $registerNativeHotkey
    UnregisterHotkey = $unregisterNativeHotkey
    SubmitRequest = $submitUtilityRequest
    GetDisplayTopology = $getDisplayTopology
    GetPointerPhysicalPosition = $getPointerPhysicalPosition
    OpenSettings = $openSettings
    OpenAbout = $openAbout
    OpenFolder = $openFolder
    Exit = $exitApplication
    Uninstall = $uninstallApplication
    SyncStartup = $syncStartup
    SetWidgetVisible = $setWidgetVisible
    OnHotkeyChanged = $hotkeyChanged
    OnSurfaceReady = $publishAuxiliarySurface
    OnSurfaceClosed = $completeAuxiliarySurface
    RegisterWindow = { param($hwnd) Register-SelfWindowHandle -Hwnd $hwnd }
    UnregisterWindow = { param($hwnd) Unregister-SelfWindowHandle -Hwnd $hwnd }
}

$utilityState.Context = $script:UtilityContext

$menu = New-SnipTrayMenu -Context $script:UtilityContext

$utilityState.Menu = $menu

$tray.ContextMenuStrip = $menu

$trayDoubleClickHandler = [EventHandler]{
    param($sender,$eventArgs)
    & $utilityState.Context.SubmitRequest 'Smart' ([timespan]::Zero) 'Tray' | Out-Null
}.GetNewClosure()

$tray.Add_DoubleClick($trayDoubleClickHandler)

if ($script:Settings.WidgetVisible) {
    Show-FloatingWidget -Context $script:UtilityContext | Out-Null
}

if (-not $initialHotkeyResult.Success) {
    Write-SnipDiag -Message "Hotkey registration failed: $($initialHotkeyResult.CandidateError)"
    $tray.BalloonTipTitle = 'SnipIT — hotkey conflict'
    $tray.BalloonTipText  = "Could not register $configuredHotkeyText. Choose another shortcut in Settings; capture remains available from the tray."
    $tray.ShowBalloonTip(5000)
    $conflictSettingsAction = [Action]{
        & $utilityState.Context.OpenSettings | Out-Null
    }.GetNewClosure()
    [void]$hotkeyForm.BeginInvoke($conflictSettingsAction)
} elseif ($script:SnipFreshInstall) {
    $tray.BalloonTipTitle = 'SnipIT installed'
    $tray.BalloonTipText  = "Press $hotkeyText to capture. Right-click the tray icon for options."
    $tray.ShowBalloonTip(4000)
}

# Last-resort teardown. The normal path is the `finally` at the bottom of this
# try, but an unexpected message-loop exit (or a process shutdown that skips
# it) would otherwise leave the NotifyIcon registered with the shell — a ghost
# tray icon that only disappears when the user hovers it — and the global
# hotkey still owned by a dead window. Both handlers funnel through one
# idempotent block so running twice is harmless.
$snipEmergencyTeardown = {
    if ($script:SnipEmergencyTeardownDone) { return }
    $script:SnipEmergencyTeardownDone = $true
    try {
        if ($script:tray) {
            $script:tray.Visible = $false
            $script:tray.Dispose()
        }
    } catch {}
    try {
        if ($hotkeyForm -and -not $hotkeyForm.IsDisposed) {
            [Native]::UnregisterHotKey($hotkeyForm.Handle, $HOTKEY_SMART) | Out-Null
        }
    } catch {}
}.GetNewClosure()

$applicationExitHandler = [EventHandler]{
    param($sender, $eventArgs)
    & $snipEmergencyTeardown
}.GetNewClosure()

$processExitHandler = [EventHandler]{
    param($sender, $eventArgs)
    & $snipEmergencyTeardown
}.GetNewClosure()

[System.Windows.Forms.Application]::add_ApplicationExit($applicationExitHandler)
[AppDomain]::CurrentDomain.add_ProcessExit($processExitHandler)

[System.Windows.Forms.Application]::Run()
}
catch {
    # Surface the actual inner exception (PS wraps the .NET one in a
    # MethodInvocationException whose Message is unhelpfully generic).
    $msg = $_.Exception.Message
    if ($_.Exception.InnerException) {
        $inner = $_.Exception.InnerException
        $msg = "$($inner.GetType().FullName): $($inner.Message)`n`n$($inner.StackTrace)"
    }
    Write-SnipDiag -Message 'Unhandled SnipIT failure' -ErrorRecord $_
    if ($env:SNIPIT_TEST_MODE) { throw }
    try {
        [System.Windows.Forms.MessageBox]::Show($msg, 'SnipIT runtime error', 'OK', 'Error') | Out-Null
    } catch {
        [Console]::Error.WriteLine($msg)
    }
}
finally {
    if ($applicationExitHandler) {
        try { [System.Windows.Forms.Application]::remove_ApplicationExit($applicationExitHandler) } catch {}
    }
    if ($processExitHandler) {
        try { [AppDomain]::CurrentDomain.remove_ProcessExit($processExitHandler) } catch {}
    }
    if ($script:CaptureCoordinator) {
        try { Stop-SnipCaptureCoordinator -Coordinator $script:CaptureCoordinator }
        catch { Write-SnipDiag -Message 'Capture coordinator cleanup failed' -ErrorRecord $_ }
    }
    $activeHotkeyAtShutdown = if ($script:UtilityContext) {
        $script:UtilityContext.RegisteredHotkey
    } else {
        $registeredHotkey
    }
    if ($activeHotkeyAtShutdown -and $hotkeyForm) {
        try { [Native]::UnregisterHotKey($hotkeyForm.Handle, 1) | Out-Null }
        catch { Write-SnipDiag -Message 'Hotkey cleanup failed' -ErrorRecord $_ }
    }
    if ($script:WidgetWindow -and $script:WidgetWindow.IsVisible) {
        try { $script:WidgetWindow.Close() } catch {}
    }
    if ($tray -and $trayDoubleClickHandler) {
        try { $tray.Remove_DoubleClick($trayDoubleClickHandler) } catch {}
    }
    if ($menu)        { try { $menu.Dispose() }        catch {} }
    if ($tray)        { try { $tray.Dispose() }        catch {} }
    if ($hotkeyForm)  { try { $hotkeyForm.Dispose() }  catch {} }
    if ($script:SingleInstanceMutex) {
        try { $script:SingleInstanceMutex.ReleaseMutex() } catch {}
        try { $script:SingleInstanceMutex.Dispose() }      catch {}
    }
    $script:SnipBootstrapInitializer = $null
    $script:SnipNativeInitializer = $null
}
