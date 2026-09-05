#requires -Version 7.5
# Integration harness for the SnipIT preview window. Dot-sources SnipIT.ps1
# in test mode (skips mutex, tray, hotkeys, main loop), creates a synthetic
# bitmap, launches Show-PreviewWindow in -TestKit mode (returns handles
# instead of blocking on ShowDialog), then drives every feature we can
# exercise without real OS input and asserts results.
#
# Everything runs on the WPF dispatcher thread. The window is hidden
# off-screen; no visible UI.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptUnderTest = Join-Path $PSScriptRoot 'SnipIT.ps1'
if (-not (Test-Path -LiteralPath $scriptUnderTest -PathType Leaf)) {
    throw "SnipIT.ps1 not found next to the test script: $scriptUnderTest"
}

$env:SNIPIT_TEST_MODE = '1'

# STA required by WPF. If we got launched from bash MTA, relaunch self.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoProfile -Sta -File $PSCommandPath
    exit $LASTEXITCODE
}

# Dot-source SnipIT.ps1 to get Show-PreviewWindow and helpers. The test-mode
# guards inside SnipIT.ps1 short-circuit side-effect sections.
. $scriptUnderTest

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
if (-not ('SnipTestMouseButtonEventArgs' -as [type])) {
    $positionedMouseReferences = @(
        [System.Windows.Input.MouseButtonEventArgs].Assembly.Location,
        [System.Windows.Point].Assembly.Location,
        [object].Assembly.Location) | Sort-Object -Unique
    Add-Type -ReferencedAssemblies $positionedMouseReferences -TypeDefinition @'
using System.Windows;
using System.Windows.Input;

public sealed class SnipTestMouseButtonEventArgs : MouseButtonEventArgs
{
    private readonly Point position;

    public SnipTestMouseButtonEventArgs(
        MouseDevice mouseDevice,
        int timestamp,
        MouseButton changedButton,
        Point position) : base(mouseDevice, timestamp, changedButton)
    {
        this.position = position;
    }

    public new Point GetPosition(IInputElement relativeTo)
    {
        return position;
    }
}

public sealed class SnipTestMouseEventArgs : MouseEventArgs
{
    private readonly Point position;

    public SnipTestMouseEventArgs(
        MouseDevice mouseDevice,
        int timestamp,
        Point position) : base(mouseDevice, timestamp)
    {
        this.position = position;
    }

    public new Point GetPosition(IInputElement relativeTo)
    {
        return position;
    }
}
'@
}

# ---- Test framework ----
$script:Results = [System.Collections.ArrayList]::new()
$script:CurrentGroup = '<root>'
function Describe { param([string]$Name, [scriptblock]$Body)
    if (-not [string]::IsNullOrWhiteSpace($env:SNIPIT_TEST_GROUP) -and
        $Name -notlike $env:SNIPIT_TEST_GROUP) { return }
    $script:CurrentGroup = $Name
    Write-Host "`n$Name" -ForegroundColor Cyan
    & $Body
}
function It { param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        [void]$script:Results.Add([pscustomobject]@{ Group=$script:CurrentGroup; Name=$Name; Pass=$true; Err=$null })
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        [void]$script:Results.Add([pscustomobject]@{ Group=$script:CurrentGroup; Name=$Name; Pass=$false; Err=$_.Exception.Message })
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            Write-Host "        $($_.ScriptStackTrace -replace "`n","`n        ")" `
                -ForegroundColor DarkRed
        }
    }
}
function Should-Be { param($Actual, $Expected, [double]$Tol=0)
    if ($Tol -gt 0) {
        if ([math]::Abs([double]$Actual - [double]$Expected) -gt $Tol) {
            throw "Expected ~$Expected (tol $Tol) but got $Actual"
        }
    } else {
        if ($Actual -ne $Expected) { throw "Expected <$Expected> but got <$Actual>" }
    }
}
function Should-BeTrue  { param($Actual) if (-not $Actual) { throw "Expected truthy, got <$Actual>" } }
function Should-BeFalse { param($Actual) if     ($Actual)  { throw "Expected falsy, got <$Actual>" } }

function Get-SnipTestPresentationSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.IInputElement]$Target,
        [int]$TimeoutMilliseconds = 2000
    )

    if ($Target -isnot [System.Windows.Media.Visual]) {
        throw "Cannot create a routed key event for non-visual $($Target.GetType().Name)"
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $source = [System.Windows.PresentationSource]::FromVisual($Target)
        if ($null -ne $source) { return $source }
        if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw "Timed out waiting for $($Target.GetType().Name)'s actual WPF PresentationSource after $TimeoutMilliseconds ms"
        }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function New-RoutedKeyEvent {
    param(
        [Parameter(Mandatory)] [System.Windows.IInputElement]$Target,
        [Parameter(Mandatory)] [System.Windows.Input.Key]$Key,
        [System.Windows.Input.Key]$SystemKey = [System.Windows.Input.Key]::None,
        [System.Windows.RoutedEvent]$RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
    )
    $source = Get-SnipTestPresentationSource -Target $Target
    $eventKey = if ($SystemKey -ne [System.Windows.Input.Key]::None) {
        [System.Windows.Input.Key]::System
    } else { $Key }
    $eventArgs = [System.Windows.Input.KeyEventArgs]::new(
        [System.Windows.Input.Keyboard]::PrimaryDevice, $source,
        [Environment]::TickCount, $eventKey)
    if ($SystemKey -ne [System.Windows.Input.Key]::None) {
        $realKeyField = [System.Windows.Input.KeyEventArgs].GetField(
            '_realKey', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $realKeyField.SetValue($eventArgs, $SystemKey)
    }
    $eventArgs.RoutedEvent = $RoutedEvent
    $eventArgs
}

function New-RoutedMouseDoubleClick {
    param([Parameter(Mandatory)] [System.Windows.IInputElement]$Target)
    $eventArgs = [System.Windows.Input.MouseButtonEventArgs]::new(
        [System.Windows.Input.Mouse]::PrimaryDevice,
        [Environment]::TickCount,
        [System.Windows.Input.MouseButton]::Left)
    $eventArgs.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
    $countField = [System.Windows.Input.MouseButtonEventArgs].GetField(
        '_count', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $countField.SetValue($eventArgs, 2)
    $eventArgs
}
function New-RoutedMouseRightClick {
    param(
        [Parameter(Mandatory)] [System.Windows.IInputElement]$Target,
        [System.Windows.Point]$Position = [System.Windows.Point]::new(40,40)
    )
    $eventArgs = [SnipTestMouseButtonEventArgs]::new(
        [System.Windows.Input.Mouse]::PrimaryDevice,
        [Environment]::TickCount,
        [System.Windows.Input.MouseButton]::Right,
        $Position)
    $eventArgs.RoutedEvent = [System.Windows.UIElement]::MouseRightButtonDownEvent
    $eventArgs
}
function New-RoutedMouseLeftEvent {
    param(
        [Parameter(Mandatory)] [System.Windows.IInputElement]$Target,
        [Parameter(Mandatory)] [System.Windows.Point]$Position,
        [Parameter(Mandatory)] [System.Windows.RoutedEvent]$RoutedEvent
    )
    $eventArgs = [SnipTestMouseButtonEventArgs]::new(
        [System.Windows.Input.Mouse]::PrimaryDevice,
        [Environment]::TickCount,
        [System.Windows.Input.MouseButton]::Left,
        $Position)
    $eventArgs.RoutedEvent = $RoutedEvent
    $eventArgs
}
function New-RoutedMouseMoveEvent {
    param(
        [Parameter(Mandatory)] [System.Windows.IInputElement]$Target,
        [Parameter(Mandatory)] [System.Windows.Point]$Position
    )
    $eventArgs = [SnipTestMouseEventArgs]::new(
        [System.Windows.Input.Mouse]::PrimaryDevice,
        [Environment]::TickCount,
        $Position)
    $eventArgs.RoutedEvent = [System.Windows.UIElement]::MouseMoveEvent
    $eventArgs
}
function Find-VisualDescendant {
    param(
        [Parameter(Mandatory)] [System.Windows.DependencyObject]$Root,
        [Parameter(Mandatory)] [type]$Type
    )
    if ($Root -is $Type) { return $Root }
    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
    for ($index = 0; $index -lt $count; $index++) {
        $match = Find-VisualDescendant `
            -Root ([System.Windows.Media.VisualTreeHelper]::GetChild($Root,$index)) `
            -Type $Type
        if ($null -ne $match) { return $match }
    }
    $null
}
function Should-BeGreaterThan { param($Actual, $Min)
    if ([double]$Actual -le [double]$Min) { throw "Expected > $Min, got $Actual" }
}

# SnipIT owns no styles. Initialize-SnipWindowTheme applies the stock WPF Fluent
# ThemeMode and then rewrites two families of values in that theme's own
# dictionaries: the surfaces go strictly neutral and the accents go to a fixed
# red. Every control, template and metric is still Microsoft's. The helpers below
# live at file scope so the nested TestAction closures can capture them.

# SnipIT's accent, as the palette derives it. Spelled out here rather than read
# from Get-SnipAccentPalette so a change of palette has to be a deliberate change
# of this list too.
$script:SnipRedAccent = '#FFE81123'
$script:SnipRedFamily = @(
    '#FF5D070E', '#FF8B0A15', '#FFBA0E1C', '#FFE81123',
    '#FFED414F', '#FFF1707B', '#FFF6A0A7')

# A bare window with nothing but ThemeMode applied: the theme SnipIT starts from,
# and the accent it must no longer be showing.
$script:NewStockFluentWindow = {
    param([ValidateSet('Light','Dark')] [string]$Mode)
    $window = [System.Windows.Window]::new()
    $window.ShowActivated = $false; $window.ShowInTaskbar = $false
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -10000; $window.Top = -10000
    $themeModeType = 'System.Windows.ThemeMode' -as [type]
    if ($null -ne $themeModeType) {
        $window.GetType().GetProperty('ThemeMode').SetValue(
            $window, [Activator]::CreateInstance($themeModeType, @($Mode)))
    }
    $window
}
$script:RetiredThemeKeys = @(
    'SnipAccentBrush','SnipMintBrush','SnipCanvasBrush','SnipPageBrush',
    'SnipPrimaryTextBrush','SnipSecondaryTextBrush','SnipMutedTextBrush',
    'SnipHairlineBrush','SnipInnerHighlightBrush','SnipGlassScrimBrush',
    'SnipGlassGradientBrush','SnipCoralBrush','SnipIslandShadow',
    'SnipButtonStyle','SnipPrimaryButtonStyle','SnipTextBoxStyle',
    'SnipComboBoxStyle','SnipCheckBoxStyle','SnipPalettePositiveBrush',
    'SnipPaletteDestructiveBrush','SnipPaletteNeutralBrush',
    'SnipIslandRadius','SnipControlRadius','SnipPopupAnimation')
$script:AssertSnipTheme = {
    param($Window, [string]$Mode)
    # The primary accent fill is the red base in both themes, and the ink on it
    # is pure white in both -- which is the point of anchoring the swap on
    # whichever family member Fluent was filling with.
    $accent = $Window.TryFindResource('AccentFillColorDefaultBrush')
    Should-BeTrue ($accent -is [System.Windows.Media.SolidColorBrush])
    Should-Be $accent.Color.ToString() $script:SnipRedAccent
    $ink = $Window.TryFindResource('TextOnAccentFillColorPrimaryBrush')
    Should-BeTrue ($ink -is [System.Windows.Media.SolidColorBrush])
    Should-Be $ink.Color.ToString() '#FFFFFFFF'
    # And it is genuinely independent of the machine: unless this host's Windows
    # accent happens to be the same red, stock Fluent resolves something else.
    $stock = & $script:NewStockFluentWindow -Mode $Mode
    try {
        $stockAccent = $stock.TryFindResource('AccentFillColorDefaultBrush')
        if ($null -ne $stockAccent -and
            $stockAccent.Color.ToString() -ne $script:SnipRedAccent) {
            Should-BeFalse ($accent.Color.ToString() -eq $stockAccent.Color.ToString())
        }
    } finally { $stock.Close() }
    foreach ($key in $script:RetiredThemeKeys) {
        if ($null -ne $Window.TryFindResource($key)) {
            throw "window still resolves a retired theme key '$key'"
        }
    }
}

# Every Color / SolidColorBrush / gradient stop reachable from a window that
# still equals a member of the Windows accent family. After the swap this must
# be empty: a leftover is a Fluent key the value-driven walk did not reach.
$script:GetSystemAccentLeftovers = {
    param($Window)
    $family = @{}
    foreach ($entry in (Get-SnipSystemAccentFamily).GetEnumerator()) {
        $family[(Get-SnipColorChannels -Color $entry.Value).Rgb] = $entry.Key
    }
    if ($family.Count -eq 0) { return @() }
    $leftovers = [System.Collections.ArrayList]::new()
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    $pending = [System.Collections.Generic.Queue[System.Windows.ResourceDictionary]]::new()
    $pending.Enqueue($Window.Resources)
    $application = [System.Windows.Application]::Current
    if ($null -ne $application -and $null -ne $application.Resources) {
        $pending.Enqueue($application.Resources)
    }
    while ($pending.Count -gt 0) {
        $dictionary = $pending.Dequeue()
        if ($null -eq $dictionary) { continue }
        $identity = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($dictionary)
        if (-not $visited.Add($identity)) { continue }
        foreach ($merged in @($dictionary.MergedDictionaries)) { $pending.Enqueue($merged) }
        foreach ($key in @($dictionary.Keys)) {
            $value = $null
            try { $value = $dictionary[$key] } catch { continue }
            $colors = if ($value -is [System.Windows.Media.Color]) {
                @($value)
            } elseif ($value -is [System.Windows.Media.SolidColorBrush]) {
                @($value.Color)
            } elseif ($value -is [System.Windows.Media.GradientBrush]) {
                @($value.GradientStops | ForEach-Object { $_.Color })
            } else { @() }
            foreach ($color in $colors) {
                $rgb = '#{0:X2}{1:X2}{2:X2}' -f $color.R, $color.G, $color.B
                if ($family.ContainsKey($rgb)) {
                    [void]$leftovers.Add("$key = $color ($($family[$rgb]))")
                }
            }
        }
    }
    $leftovers
}

# Renders one element and reports whether any sampled pixel is a member of the
# red family. Used to prove the swap reached the pixels, not just the keys.
$script:ContainsRedFamilyPixel = {
    param($Element, [int]$Tolerance = 6)
    $Element.UpdateLayout()
    $width = [int][math]::Ceiling($Element.ActualWidth)
    $height = [int][math]::Ceiling($Element.ActualHeight)
    if ($width -le 0 -or $height -le 0) { throw 'element has no size to render' }
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    # Rendering a child visual directly keeps its offset inside the window, so
    # the control can land outside the bitmap. Painting it through a VisualBrush
    # into a DrawingVisual normalises it to (0,0) whatever it is nested in.
    $surface = [System.Windows.Media.DrawingVisual]::new()
    $drawing = $surface.RenderOpen()
    try {
        $drawing.DrawRectangle([System.Windows.Media.VisualBrush]::new($Element), $null,
            [System.Windows.Rect]::new(0, 0, $width, $height))
    } finally { $drawing.Close() }
    $bitmap.Render($surface)
    $stride = $width * 4
    $pixels = [byte[]]::new($stride * $height)
    $bitmap.CopyPixels($pixels, $stride, 0)
    $targets = $script:SnipRedFamily | ForEach-Object { Get-SnipColorChannels -Color $_ }
    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x++) {
            $index = $y * $stride + $x * 4
            $blue = [int]$pixels[$index]
            $green = [int]$pixels[$index + 1]
            $red = [int]$pixels[$index + 2]
            foreach ($target in $targets) {
                if ([math]::Abs($red - $target.R) -le $Tolerance -and
                    [math]::Abs($green - $target.G) -le $Tolerance -and
                    [math]::Abs($blue - $target.B) -le $Tolerance) { return $true }
            }
        }
    }
    $false
}

# Every Fluent surface, bar, card, border and text key SnipIT neutralises,
# spelled out in full rather than derived from the prefix list in SnipIT.ps1 --
# a prefix quietly dropped over there has to fail over here.
$script:NeutralSurfaceKeys = @(
    'ApplicationBackgroundBrush', 'ApplicationBackgroundColor'
    'SolidBackgroundFillColorBase', 'SolidBackgroundFillColorBaseBrush'
    'SolidBackgroundFillColorBaseAlt', 'SolidBackgroundFillColorBaseAltBrush'
    'SolidBackgroundFillColorSecondary', 'SolidBackgroundFillColorSecondaryBrush'
    'SolidBackgroundFillColorTertiary', 'SolidBackgroundFillColorTertiaryBrush'
    'SolidBackgroundFillColorQuarternary', 'SolidBackgroundFillColorQuarternaryBrush'
    'LayerFillColorDefault', 'LayerFillColorDefaultBrush'
    'LayerFillColorAlt', 'LayerFillColorAltBrush'
    'LayerOnAcrylicFillColorDefault', 'LayerOnAcrylicFillColorDefaultBrush'
    'CardBackgroundFillColorDefault', 'CardBackgroundFillColorDefaultBrush'
    'CardBackgroundFillColorSecondary', 'CardBackgroundFillColorSecondaryBrush'
    'CardStrokeColorDefault', 'CardStrokeColorDefaultBrush'
    'CardStrokeColorDefaultSolid', 'CardStrokeColorDefaultSolidBrush'
    'ControlFillColorDefault', 'ControlFillColorDefaultBrush'
    'ControlFillColorSecondary', 'ControlFillColorSecondaryBrush'
    'ControlFillColorTertiary', 'ControlFillColorTertiaryBrush'
    'ControlFillColorDisabled', 'ControlFillColorDisabledBrush'
    'ControlFillColorInputActive', 'ControlFillColorInputActiveBrush'
    'ControlAltFillColorSecondary', 'ControlAltFillColorSecondaryBrush'
    'ControlAltFillColorTertiary', 'ControlAltFillColorTertiaryBrush'
    'ControlStrokeColorDefault', 'ControlStrokeColorDefaultBrush'
    'ControlStrokeColorSecondary', 'ControlStrokeColorSecondaryBrush'
    'ControlStrongFillColorDefault', 'ControlStrongFillColorDefaultBrush'
    'ControlStrongStrokeColorDefault', 'ControlStrongStrokeColorDefaultBrush'
    'DividerStrokeColorDefault', 'DividerStrokeColorDefaultBrush'
    'SubtleFillColorSecondary', 'SubtleFillColorSecondaryBrush'
    'SubtleFillColorTertiary', 'SubtleFillColorTertiaryBrush'
    'SurfaceStrokeColorDefault', 'SurfaceStrokeColorDefaultBrush'
    'TextFillColorPrimary', 'TextFillColorPrimaryBrush'
    'TextFillColorSecondary', 'TextFillColorSecondaryBrush'
    'TextFillColorTertiary', 'TextFillColorTertiaryBrush'
    'TextFillColorDisabled', 'TextFillColorDisabledBrush')

# Chrome is black, white and grey: nothing SnipIT paints may carry a hue.
# The key list arrives as an argument rather than through a $script: lookup in
# the body, because this helper is also invoked from inside GetNewClosure()
# TestActions, whose $script: scope is their own dynamic module.
$script:AssertNeutralSurfaces = {
    param($Window, [string[]]$Keys = $null)
    if ($null -eq $Keys -or $Keys.Count -eq 0) { throw 'no neutral surface keys to assert' }
    foreach ($key in $Keys) {
        $value = $Window.TryFindResource($key)
        if ($null -eq $value) { continue }
        $color = if ($value -is [System.Windows.Media.SolidColorBrush]) {
            $value.Color
        } elseif ($value -is [System.Windows.Media.Color]) {
            $value
        } else {
            throw "'$key' is a $($value.GetType().Name), not a colour"
        }
        if ($color.R -ne $color.G -or $color.G -ne $color.B) {
            throw "'$key' still carries a hue: $color"
        }
    }
}

# Renders a live window and returns every sampled pixel that carries a hue which
# is not one of the allowed families. A pixel belongs to a family when its chroma
# vector points the same way as the reference's: blending the accent with any
# neutral scales that vector but never turns it. Grid sampling, because the point
# is to catch a tinted surface, not a stray antialiased edge.
$script:GetTintedSamples = {
    param($Window, $Root, $Extra = @(), [int]$Step = 6, [int]$Tolerance = 2)
    $family = {
        param([int]$R, [int]$G, [int]$B, $Reference)
        $pixelFloor = [math]::Min($R, [math]::Min($G, $B))
        $pixelChroma = @(($R - $pixelFloor), ($G - $pixelFloor), ($B - $pixelFloor))
        $pixelPeak = ($pixelChroma | Measure-Object -Maximum).Maximum
        $referenceFloor = [math]::Min($Reference.R, [math]::Min($Reference.G, $Reference.B))
        $referenceChroma = @(
            ([int]$Reference.R - $referenceFloor)
            ([int]$Reference.G - $referenceFloor)
            ([int]$Reference.B - $referenceFloor))
        $referencePeak = ($referenceChroma | Measure-Object -Maximum).Maximum
        if ($pixelPeak -eq 0 -or $referencePeak -eq 0) { return $false }
        for ($channel = 0; $channel -lt 3; $channel++) {
            $delta = [math]::Abs(($pixelChroma[$channel] / $pixelPeak) -
                ($referenceChroma[$channel] / $referencePeak))
            if ($delta -gt 0.2) { return $false }
        }
        $true
    }
    $Window.UpdateLayout()
    $Window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
    if ($null -eq $Root) { $Root = $Window.Content }
    $width = [int][math]::Ceiling($Root.ActualWidth)
    $height = [int][math]::Ceiling($Root.ActualHeight)
    if ($width -le 0 -or $height -le 0) { throw 'render root has no size' }
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window)
    $stride = $width * 4
    $pixels = [byte[]]::new($stride * $height)
    $bitmap.CopyPixels($pixels, $stride, 0)

    # The accent and Fluent's semantic fills are the colour that is allowed to
    # exist; every other hue on a surface is a regression.
    $allowed = @($Extra)
    foreach ($key in 'AccentFillColorDefaultBrush', 'AccentFillColorSecondaryBrush',
        'AccentFillColorTertiaryBrush', 'AccentTextFillColorPrimaryBrush',
        'AccentTextFillColorSecondaryBrush', 'AccentTextFillColorTertiaryBrush',
        'SystemFillColorCriticalBrush', 'SystemFillColorCautionBrush',
        'SystemFillColorSuccessBrush', 'SystemFillColorAttentionBrush') {
        $brush = $Window.TryFindResource($key)
        if ($brush -is [System.Windows.Media.SolidColorBrush]) { $allowed += $brush.Color }
    }

    $offenders = [System.Collections.ArrayList]::new()
    for ($y = 0; $y -lt $height; $y += $Step) {
        for ($x = 0; $x -lt $width; $x += $Step) {
            $index = $y * $stride + $x * 4
            $blue = [int]$pixels[$index]
            $green = [int]$pixels[$index + 1]
            $red = [int]$pixels[$index + 2]
            if ([math]::Abs($red - $green) -le $Tolerance -and
                [math]::Abs($green - $blue) -le $Tolerance -and
                [math]::Abs($red - $blue) -le $Tolerance) { continue }
            $known = $false
            foreach ($reference in $allowed) {
                if (& $family $red $green $blue $reference) { $known = $true; break }
            }
            if (-not $known) {
                [void]$offenders.Add(
                    ('({0},{1}) #{2:X2}{3:X2}{4:X2}' -f $x, $y, $red, $green, $blue))
            }
        }
    }
    $offenders
}

Describe 'Fluent theme foundation' {
    It 'maps registry app-theme value to a mode' {
        Should-Be (Get-SnipSystemThemeMode -Reader { 1 }) 'Light'
        Should-Be (Get-SnipSystemThemeMode -Reader { 0 }) 'Dark'
        Should-Be (Get-SnipSystemThemeMode -Reader { $null }) 'Light'
    }
    It 'falls back to Light for a corrupted non-numeric registry value' {
        Should-Be (Get-SnipSystemThemeMode -Reader { 'garbage' }) 'Light'
    }
    It 'applies the stock Fluent ThemeMode and reports the mode' {
        foreach ($mode in 'Dark','Light') {
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                Should-Be (Initialize-SnipWindowTheme -Window $window -Mode $mode) $mode
                $modeProperty = $window.GetType().GetProperty('ThemeMode')
                if ($null -ne $modeProperty) {
                    Should-Be "$($modeProperty.GetValue($window))" $mode
                }
                & $script:AssertSnipTheme $window $mode
            } finally { $window.Close() }
        }
    }
    It 'edits Fluent in place and adds nothing to Window.Resources' {
        # The retired implementation wrote a whole parallel palette into every
        # merged dictionary. Both passes now rewrite the values of keys Fluent
        # already owns; nothing is ever added, least of all to the window's own
        # resource dictionary, which stays empty.
        $window = [System.Windows.Window]::new()
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -10000; $window.Top = -10000
        try {
            [void](Initialize-SnipWindowTheme -Window $window -Mode Dark)
            foreach ($key in @('AccentFillColorDefaultBrush','AccentButtonBackground',
                    'ProgressBarForeground','SliderTrackValueFill',
                    'ToggleButtonBackgroundChecked','SystemAccentColor')) {
                Should-BeFalse ($window.Resources.Keys -contains $key)
            }
            Should-Be $window.Resources.Count 0
            # The neutral pass still refuses to touch anything accent-named; the
            # red is the accent pass's job and only its job.
            $body = (Get-Command Set-SnipNeutralSurfaces -CommandType Function).
                ScriptBlock.ToString()
            Should-BeTrue ($body -match "\-like '\*Accent\*'")
            & $script:AssertSnipTheme $window 'Dark'
        } finally { $window.Close() }
    }
    It 'repaints every accent red in both themes' {
        foreach ($mode in 'Dark','Light') {
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                # The keys the chrome actually spends the accent on: the
                # Copy & close button, checked toggles, the checkbox check, the
                # slider thumb, the ComboBox / TextBox focus border.
                foreach ($key in 'AccentFillColorDefaultBrush', 'AccentFillColorSecondaryBrush',
                        'AccentFillColorTertiaryBrush', 'AccentButtonBackground',
                        'AccentButtonBackgroundPointerOver', 'AccentButtonBackgroundPressed',
                        'ToggleButtonBackgroundChecked', 'ToggleButtonBackgroundCheckedPointerOver',
                        'CheckBoxCheckBackgroundFillChecked', 'SliderThumbBackground',
                        'ComboBoxBorderBrushFocused', 'TextControlFocusedBorderBrush',
                        'ProgressBarForeground') {
                    $brush = $window.TryFindResource($key)
                    if ($null -eq $brush) { continue }
                    Should-Be $brush.Color.ToString() $script:SnipRedAccent
                }
                # Text keys sit on the ground rather than on the fill, so they
                # take a lighter or darker rung -- but still one of the seven.
                foreach ($key in 'AccentTextFillColorPrimaryBrush', 'HyperlinkForeground',
                        'HyperlinkButtonForeground', 'AccentFillColorSelectedTextBackgroundBrush',
                        'SystemFillColorAttentionBrush') {
                    $brush = $window.TryFindResource($key)
                    if ($null -eq $brush) { continue }
                    Should-BeTrue ($brush.Color.ToString() -in $script:SnipRedFamily)
                }
                # On-accent ink is white in both modes: red is dark at every rung
                # the chrome fills with, so Fluent's black-on-light-accent choice
                # would be unreadable here.
                foreach ($key in 'TextOnAccentFillColorPrimaryBrush',
                        'AccentButtonForeground', 'AccentButtonForegroundPointerOver') {
                    $brush = $window.TryFindResource($key)
                    if ($null -eq $brush) { continue }
                    Should-Be $brush.Color.R ([byte]255)
                    Should-Be $brush.Color.G ([byte]255)
                    Should-Be $brush.Color.B ([byte]255)
                }
                # The gradient-valued focus underline carries an accent stop.
                $focus = $window.TryFindResource('TextControlBorderBrushFocused')
                if ($focus -is [System.Windows.Media.GradientBrush]) {
                    Should-BeTrue ($focus.IsFrozen)
                    Should-BeTrue (@($focus.GradientStops | Where-Object {
                        $_.Color.ToString() -eq $script:SnipRedAccent }).Count -ge 1)
                }
            } finally { $window.Close() }
        }
    }
    It 'leaves no dictionary entry on the Windows accent, before or after Show()' {
        foreach ($mode in 'Dark','Light') {
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                $before = @(& $script:GetSystemAccentLeftovers $window)
                if ($before.Count) {
                    throw "system accent survived the swap in ${mode}: $(($before |
                        Select-Object -First 6) -join ' ')"
                }
                # Show() rebuilds the Fluent dictionaries and restores the purple;
                # the Loaded pass is what puts the red back.
                $window.Show(); $window.UpdateLayout()
                $window.Dispatcher.Invoke([Action] {},
                    [System.Windows.Threading.DispatcherPriority]::Loaded)
                $after = @(& $script:GetSystemAccentLeftovers $window)
                if ($after.Count) {
                    throw "system accent returned after Show() in ${mode}: $(($after |
                        Select-Object -First 6) -join ' ')"
                }
                & $script:AssertSnipTheme $window $mode
            } finally { $window.Close() }
        }
    }
    It 'replaces frozen brushes rather than mutating them' {
        # A Fluent brush handed out to a live control is frozen and shared;
        # mutating one would throw, so every swap has to be a new instance.
        $window = [System.Windows.Window]::new()
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -10000; $window.Top = -10000
        try {
            [void](Initialize-SnipWindowTheme -Window $window -Mode Dark)
            $accent = $window.TryFindResource('AccentFillColorDefaultBrush')
            Should-BeTrue $accent.IsFrozen
            # Running the pass again finds red, not purple, and changes nothing.
            $again = Set-SnipAccentColors -Window $window
            Should-Be $again 0
            Should-Be $window.TryFindResource(
                'AccentFillColorDefaultBrush').Color.ToString() $script:SnipRedAccent
        } finally { $window.Close() }
    }
    It 'renders a real accent button and a checked toggle in red' {
        foreach ($mode in 'Dark','Light') {
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            $panel = [System.Windows.Controls.StackPanel]::new()
            $button = [System.Windows.Controls.Button]::new()
            $button.Content = 'Copy & close'
            $button.Width = 140; $button.Height = 34
            $toggle = [System.Windows.Controls.Primitives.ToggleButton]::new()
            $toggle.Content = 'On'
            $toggle.Width = 140; $toggle.Height = 34
            $toggle.IsChecked = $true
            $check = [System.Windows.Controls.CheckBox]::new()
            $check.Content = 'Checked'
            $check.IsChecked = $true
            [void]$panel.Children.Add($button)
            [void]$panel.Children.Add($toggle)
            [void]$panel.Children.Add($check)
            $window.Content = $panel
            $window.Width = 200; $window.Height = 160
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                $window.Show(); $window.UpdateLayout()
                $window.Dispatcher.Invoke([Action] {},
                    [System.Windows.Threading.DispatcherPriority]::Loaded)
                $accentStyle = $window.TryFindResource('AccentButtonStyle')
                if ($null -ne $accentStyle) { $button.Style = $accentStyle }
                $window.UpdateLayout()
                $window.Dispatcher.Invoke([Action] {},
                    [System.Windows.Threading.DispatcherPriority]::Render)
                if ($null -ne $accentStyle) {
                    Should-BeTrue (& $script:ContainsRedFamilyPixel $button)
                }
                Should-BeTrue (& $script:ContainsRedFamilyPixel $toggle)
                Should-BeTrue (& $script:ContainsRedFamilyPixel $check)
            } finally { $window.Close() }
        }
    }
    It 'derives the accent family from the system rather than a hardcoded list' {
        # The swap recognises accent colours by value, so it needs the same
        # family Fluent built from -- read through the seam so the suite can pin
        # one, and empty on a host that cannot answer.
        $family = Get-SnipSystemAccentFamily -Reader {
            param([string]$Property)
            switch ($Property) {
                'AccentColor' { '#FF102030' }
                'AccentColorLight2' { '#FF405060' }
                default { $null }
            }
        }
        Should-Be $family.Count 2
        Should-Be $family['Base'] '#FF102030'
        Should-Be $family['Light2'] '#FF405060'
        Should-Be (Get-SnipSystemAccentFamily -Reader { throw 'no accent' }).Count 0
        # The live one is whole: seven rungs, every one a real colour.
        $live = Get-SnipSystemAccentFamily
        Should-Be $live.Count 7
        foreach ($entry in $live.GetEnumerator()) {
            Should-BeTrue ($entry.Value -match '^#[0-9A-F]{8}$')
        }
    }
    It 'stands the accent pass down when there is no family to replace' {
        $window = [System.Windows.Window]::new()
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -10000; $window.Top = -10000
        try {
            $themeModeType = 'System.Windows.ThemeMode' -as [type]
            if ($null -ne $themeModeType) {
                $window.GetType().GetProperty('ThemeMode').SetValue(
                    $window, [Activator]::CreateInstance($themeModeType, @('Dark')))
            }
            $stock = $window.TryFindResource('AccentFillColorDefaultBrush')
            Should-Be (Set-SnipAccentColors -Window $window -SystemAccent ([ordered]@{})) 0
            Should-Be $window.TryFindResource(
                'AccentFillColorDefaultBrush').Color.ToString() $stock.Color.ToString()
        } finally { $window.Close() }
    }
    It 'grounds the window on pure black in Dark and pure white in Light' {
        # ThemeMode leaves Background transparent for a DWM backdrop, and the
        # Fluent ToolBarTray / StatusBar fills are translucent, so an ungrounded
        # window composites its bars over the wallpaper behind it. The ground is
        # the pure value, not Fluent's near-black / near-white grey.
        foreach ($pair in @(@('Dark','#FF000000'), @('Light','#FFFFFFFF'))) {
            $mode, $expected = $pair
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                Should-BeTrue ($window.Background -is [System.Windows.Media.SolidColorBrush])
                Should-Be $window.Background.Color.ToString() $expected
                Should-BeTrue $window.Background.IsFrozen
                # The application ground key follows, so anything reading it --
                # the editor's canvas mat, for one -- lands on the same value.
                $ground = $window.TryFindResource('ApplicationBackgroundBrush')
                Should-Be $ground.Color.ToString() $expected
            } finally { $window.Close() }
        }
    }
    It 'neutralises every Fluent surface, border and text key in both modes' {
        foreach ($mode in 'Dark','Light') {
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                & $script:AssertNeutralSurfaces $window $script:NeutralSurfaceKeys
                # Text stays pure: white on black, black on white, with the
                # secondary and tertiary inks alpha greys of the same hue-free value.
                $primary = $window.TryFindResource('TextFillColorPrimaryBrush').Color
                if ($mode -eq 'Dark') {
                    Should-Be $primary.ToString() '#FFFFFFFF'
                } else {
                    Should-Be $primary.R ([byte]0)
                }
            } finally { $window.Close() }
        }
    }
    It 'survives the dictionary rebuild that Show() performs' {
        # Show() reinstalls the Fluent dictionaries, which is why the neutral
        # pass runs again on Loaded (PR #45 / #54 hit the same rebuild).
        foreach ($pair in @(@('Dark','#FF000000'), @('Light','#FFFFFFFF'))) {
            $mode, $expected = $pair
            $window = [System.Windows.Window]::new()
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                $window.Show(); $window.UpdateLayout()
                $window.Dispatcher.Invoke([Action] {},
                    [System.Windows.Threading.DispatcherPriority]::Loaded)
                Should-Be $window.Background.Color.ToString() $expected
                Should-Be $window.TryFindResource('ApplicationBackgroundBrush').Color.ToString() $expected
                & $script:AssertNeutralSurfaces $window $script:NeutralSurfaceKeys
            } finally { $window.Close() }
        }
    }
    It 'leaves a High Contrast palette exactly as Windows built it' {
        # High Contrast palettes are deliberately coloured and the user chose
        # them to be legible; flattening them to grey would be an accessibility
        # regression, so the neutral pass and the literal ground both stand down.
        Should-BeTrue (Test-SnipHighContrast -Reader { $true })
        Should-BeFalse (Test-SnipHighContrast -Reader { $false })
        Should-BeFalse (Test-SnipHighContrast -Reader { throw 'no SystemParameters' })
        $window = [System.Windows.Window]::new()
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -10000; $window.Top = -10000
        try {
            Should-Be (Initialize-SnipWindowTheme -Window $window -Mode Dark `
                -HighContrast $true) 'Dark'
            # Grounded by resource reference, not by a literal brush of ours.
            $local = $window.ReadLocalValue(
                [System.Windows.Controls.Control]::BackgroundProperty)
            Should-BeFalse ($local -is [System.Windows.Media.SolidColorBrush])
            Should-BeTrue ($local.GetType().Name -like '*ResourceReference*')
            # The red never lands either: High Contrast owns its own accent.
            $accent = $window.TryFindResource('AccentFillColorDefaultBrush')
            if ($null -ne $accent) {
                Should-BeFalse ($accent.Color.ToString() -eq $script:SnipRedAccent)
            }
        } finally { $window.Close() }
    }
    It 'turns the Mica backdrop off and paints the caption to match the ground' {
        # The caption bar is DWM's surface, not WPF's: ThemeMode opts every
        # window into Mica, which composites the wallpaper through the title bar
        # and puts a tinted band above a pure black or white client area.
        foreach ($mode in 'Dark','Light') {
            $window = [System.Windows.Window]::new()
            $window.Title = 'chrome probe'
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -10000; $window.Top = -10000
            try {
                [void](Initialize-SnipWindowTheme -Window $window -Mode $mode)
                $window.Show(); $window.UpdateLayout()
                $window.Dispatcher.Invoke([Action] {},
                    [System.Windows.Threading.DispatcherPriority]::Loaded)
                $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
                Should-BeFalse ($handle -eq [IntPtr]::Zero)
                if ([Environment]::OSVersion.Version.Build -lt 22000) { continue }
                # DWM answers reads for the two flag attributes; the three
                # COLORREF ones are set-only and come back E_INVALIDARG, so the
                # return value of the call is what stands for them.
                $backdrop = 0
                Should-Be ([Native]::DwmGetWindowAttribute(
                    $handle, [Native]::DWMWA_SYSTEMBACKDROP_TYPE, [ref]$backdrop, 4)) 0
                Should-Be $backdrop ([Native]::DWMSBT_NONE)
                $immersive = 0
                Should-Be ([Native]::DwmGetWindowAttribute(
                    $handle, [Native]::DWMWA_USE_IMMERSIVE_DARK_MODE, [ref]$immersive, 4)) 0
                Should-Be $immersive $(if ($mode -eq 'Dark') { 1 } else { 0 })
                Should-BeTrue (Set-SnipWindowChrome -Hwnd $handle -Mode $mode)
            } finally { $window.Close() }
        }
    }
    It 'stands the caption pass down off Windows 11 and without a handle' {
        Should-BeFalse (Set-SnipWindowChrome -Hwnd ([IntPtr]::Zero) -Mode Dark)
        Should-BeFalse (Set-SnipWindowChrome -Hwnd ([IntPtr]1) -Mode Dark `
            -OSVersion ([version]'10.0.19045.0'))
        Should-BeFalse (Set-SnipWindowChrome -Hwnd ([IntPtr]1) -Mode Dark `
            -OSVersion ([version]'6.1.7601.0'))
    }
    It 'opts WinForms into the system colour mode for the tray menu' {
        # The tray menu is the one surface WPF cannot reach. It stays a stock
        # ContextMenuStrip on the stock renderer; the opt-in is what makes that
        # renderer read the dark system colours instead of its light default.
        Should-BeTrue (Enable-SnipWinFormsColorMode)
        $applicationType = 'System.Windows.Forms.Application' -as [type]
        Should-BeFalse ($null -eq $applicationType)
        $darkModeProperty = $applicationType.GetProperty('IsDarkModeEnabled')
        if ($null -ne $darkModeProperty) {
            # Under -ColorMode System the answer has to agree with the shell.
            Should-Be ([bool]$darkModeProperty.GetValue($null)) `
                ((Get-SnipSystemThemeMode) -eq 'Dark')
        }
        # Explicit modes are accepted too, and the call is safely repeatable.
        Should-BeTrue (Enable-SnipWinFormsColorMode -ColorMode System)
    }
    It 'builds the tray menu on the stock renderer, with no colours of its own' {
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            SubmitRequest = { param($mode,$delay,$source,$monitorId) }
            GetDisplayTopology = { $null }
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
            ActiveShortcut = 'Ctrl+Shift+Q'
        }
        Should-BeTrue (Enable-SnipWinFormsColorMode)
        $menu = New-SnipTrayMenu -Context $context -ThemeMode Dark
        try {
            # Exactly the stock renderer and exactly the stock colour table --
            # not a subclass of either. Assigning a renderer instance is what
            # moves RenderMode to Custom; the renderer itself is still the one
            # WinForms ships.
            Should-Be $menu.Renderer.GetType().FullName `
                'System.Windows.Forms.ToolStripProfessionalRenderer'
            Should-Be $menu.Renderer.ColorTable.GetType().FullName `
                'System.Windows.Forms.ProfessionalColorTable'
            # ...and the opt-in is what makes that stock table answer in the
            # theme's colours. Before it, the menu came up white on a dark
            # desktop; the drop-down background now follows the system theme.
            $background = $menu.Renderer.ColorTable.ToolStripDropDownBackground
            $luma = 0.299 * $background.R + 0.587 * $background.G + 0.114 * $background.B
            if ((Get-SnipSystemThemeMode) -eq 'Dark') {
                Should-BeTrue ($luma -lt 128)
            } else {
                Should-BeTrue ($luma -gt 128)
            }
        } finally { $menu.Dispose() }
    }
    It 'renders the Settings window without a single tinted surface pixel' {
        $assertNeutral = $script:AssertNeutralSurfaces
        $neutralKeys = $script:NeutralSurfaceKeys
        $sampleTint = $script:GetTintedSamples
        $observed = [pscustomobject]@{ Offenders = $null; Ground = $null }
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-mono-' + [guid]::NewGuid())
        Show-SettingsWindow -Context ([pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
            RegisterWindow = { param($hwnd) }
            UnregisterWindow = { param($hwnd) }
        }) -TestAction {
            param($kit)
            & $assertNeutral $kit.Window $neutralKeys
            $observed.Ground = "$($kit.Window.Background)"
            $observed.Offenders = @(& $sampleTint $kit.Window $kit.Window.Content)
            & $kit.Close 'UserCancelled'
        }.GetNewClosure() | Out-Null
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Should-BeTrue ($observed.Ground -in @('#FF000000','#FFFFFFFF'))
        if ($observed.Offenders.Count) {
            throw "tinted pixels in Settings: $(($observed.Offenders | Select-Object -First 8) -join ' ')"
        }
    }
    It 'renders the editor chrome without a single tinted surface pixel' {
        # A greyscale capture keeps the picture out of the verdict: any hue in
        # the render is chrome, the accent, or an annotation swatch.
        $sampleTint = $script:GetTintedSamples
        $bitmap = [System.Drawing.Bitmap]::new(320, 240)
        for ($y = 0; $y -lt $bitmap.Height; $y++) {
            for ($x = 0; $x -lt $bitmap.Width; $x++) {
                $level = [int](($x * 255) / $bitmap.Width)
                $bitmap.SetPixel($x, $y,
                    [System.Drawing.Color]::FromArgb(255, $level, $level, $level))
            }
        }
        # The annotation palette is the user's ink, not chrome (see $palette in
        # the editor): its swatches are allowed to be as colourful as they like.
        $inks = @(
            [System.Windows.Media.Color]::FromRgb(255,222,0)
            [System.Windows.Media.Color]::FromRgb(70,210,110)
            [System.Windows.Media.Color]::FromRgb(255,90,180)
            [System.Windows.Media.Color]::FromRgb(80,170,255)
            [System.Windows.Media.Color]::FromRgb(255,150,40)
            [System.Windows.Media.Color]::FromRgb(255,60,60))
        $observed = [pscustomobject]@{ Offenders = $null; Ground = $null; Mat = $null }
        Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            $observed.Ground = "$($kit.Win.Background)"
            $observed.Mat = "$($kit.Win.FindName('Scroller').Background)"
            $observed.Offenders = @(& $sampleTint $kit.Win $kit.StudioRoot $inks)
        }.GetNewClosure() | Out-Null
        $bitmap.Dispose()
        Should-BeTrue ($observed.Ground -in @('#FF000000','#FFFFFFFF'))
        # The mat behind the capture is the pure ground, not a grey plate.
        Should-Be $observed.Mat $observed.Ground
        if ($observed.Offenders.Count) {
            throw "tinted pixels in the editor chrome: $(($observed.Offenders | Select-Object -First 8) -join ' ')"
        }
    }
    It 'defaults the mode from the system theme seam' {
        $window = [System.Windows.Window]::new()
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $applied = Initialize-SnipWindowTheme -Window $window
        Should-BeTrue ($applied -in @('Light','Dark'))
        $window.Close()
    }
    It 'leaves a transparent overlay window background untouched' {
        # The Smart overlay is the one chromeless surface; grounding it would
        # paint an opaque plate over the desktop snapshot it must reveal.
        $window = [System.Windows.Window]::new()
        $window.WindowStyle = 'None'
        $window.AllowsTransparency = $true
        $window.Background = [System.Windows.Media.Brushes]::Transparent
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -10000; $window.Top = -10000

        Should-Be (Initialize-SnipWindowTheme -Window $window -Mode Dark) 'Dark'
        Should-Be $window.Background.Color.ToString() '#00FFFFFF'
        # It still gets the Fluent dictionaries so its banner keys resolve.
        Should-BeTrue ($null -ne $window.TryFindResource('TextFillColorPrimaryBrush'))
        $window.Close()
    }
    It 'gives every utility window a real title bar and a title' {
        # Nothing is WindowStyle=None + AllowsTransparency any more, so the OS
        # owns the chrome, the caption text and the window controls.
        # GetNewClosure() captures locals only - a $script: read inside a closure
        # resolves against the closure's own dynamic module - so bind it here.
        $assertTheme = $script:AssertSnipTheme
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-theme-' + [guid]::NewGuid())
        $settingsContext = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
            RegisterWindow = { param($hwnd) }
            UnregisterWindow = { param($hwnd) }
        }
        Show-SettingsWindow -Context $settingsContext -TestAction {
            param($kit)
            Should-Be $kit.Window.Title 'SnipIT Settings'
            Should-BeFalse ($kit.Window.WindowStyle -eq [System.Windows.WindowStyle]::None)
            Should-BeFalse $kit.Window.AllowsTransparency
            & $assertTheme $kit.Window (Get-SnipSystemThemeMode)
            & $kit.Close 'UserCancelled'
        }.GetNewClosure() | Out-Null
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

        Show-AboutWindow -Context ([pscustomobject]@{
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            RegisterWindow = { param($hwnd) }
            UnregisterWindow = { param($hwnd) }
        }) -TestAction {
            param($kit)
            Should-Be $kit.Window.Title 'About SnipIT'
            Should-BeFalse ($kit.Window.WindowStyle -eq [System.Windows.WindowStyle]::None)
            Should-BeFalse $kit.Window.AllowsTransparency
            & $assertTheme $kit.Window (Get-SnipSystemThemeMode)
            & $kit.Close 'UserCancelled'
        }.GetNewClosure() | Out-Null

        $widgetSettings = Get-SnipDefaultSettings
        $widgetSettings.WidgetVisible = $true
        Show-FloatingWidget -Context ([pscustomobject]@{
            Settings = $widgetSettings
            SubmitRequest = { param($mode,$delay,$source) }
            OpenSettings = { }
            AnimationsEnabled = $false
            RegisterWindow = { param($hwnd) }
            UnregisterWindow = { param($hwnd) }
        }) -TestAction {
            param($kit)
            Should-Be $kit.Window.Title 'SnipIT capture widget'
            Should-Be $kit.Window.WindowStyle ([System.Windows.WindowStyle]::ToolWindow)
            Should-BeFalse $kit.Window.AllowsTransparency
            & $assertTheme $kit.Window (Get-SnipSystemThemeMode)
            $kit.Window.Close()
        }.GetNewClosure() | Out-Null
    }
    It 'themes the preview window with the fixed red accent and ThemeMode' {
        $bitmap = [System.Drawing.Bitmap]::new(16, 16)
        # Show-PreviewWindow stores a TestAction failure in $script:pwTestError from
        # inside a GetNewClosure() scriptblock, whose $script: scope is the closure's
        # own dynamic module - so throws raised in here never reach the harness.
        # Observe into an outer holder and assert after the call instead.
        $observed = [pscustomobject]@{
            Accent = $null; StockAccent = $null; ThemeMode = $null; Ink = $null
            Background = $null; Title = $null; Style = $null; Retired = $null
        }
        $newStockWindow = $script:NewStockFluentWindow
        $retiredKeys = $script:RetiredThemeKeys
        Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            $mode = Get-SnipSystemThemeMode
            $stock = & $newStockWindow -Mode $mode
            try {
                $stockBrush = $stock.TryFindResource('AccentFillColorDefaultBrush')
                $observed.StockAccent = if ($null -eq $stockBrush) {
                    '<null>'
                } else { $stockBrush.Color.ToString() }
            } finally { $stock.Close() }
            $brush = $kit.Win.TryFindResource('AccentFillColorDefaultBrush')
            $observed.Accent = if ($null -eq $brush) { '<null>' } else { $brush.Color.ToString() }
            $inkBrush = $kit.Win.TryFindResource('TextOnAccentFillColorPrimaryBrush')
            $observed.Ink = if ($null -eq $inkBrush) { '<null>' } else { $inkBrush.Color.ToString() }
            $modeProperty = $kit.Win.GetType().GetProperty('ThemeMode')
            $observed.ThemeMode = if ($null -eq $modeProperty) {
                '<absent>'
            } else { "$($modeProperty.GetValue($kit.Win))" }
            $observed.Background = "$($kit.Win.Background)"
            $observed.Title = [string]$kit.Win.Title
            $observed.Style = "$($kit.Win.WindowStyle)"
            $observed.Retired = @($retiredKeys | Where-Object {
                $null -ne $kit.Win.TryFindResource($_) }) -join ','
        }.GetNewClosure() | Out-Null
        # The editor's accent is SnipIT's red, and -- unless this host's Windows
        # accent happens to be the same red -- not what stock Fluent resolves.
        Should-Be $observed.Accent $script:SnipRedAccent
        if ($observed.StockAccent -ne $script:SnipRedAccent) {
            Should-BeFalse ($observed.Accent -eq $observed.StockAccent)
        }
        Should-Be $observed.Ink '#FFFFFFFF'
        Should-BeTrue ($observed.ThemeMode -in @('Light','Dark','<absent>'))
        # Never left ungrounded: ThemeMode leaves Background transparent.
        Should-BeTrue (-not [string]::IsNullOrWhiteSpace($observed.Background))
        Should-BeTrue ($observed.Title -like 'SnipIT Preview*')
        Should-BeFalse ($observed.Style -eq 'None')
        Should-Be $observed.Retired ''
    }
    It 'keeps the retired custom More popup inert in the stock preview' {
        $stockBitmap = [System.Drawing.Bitmap]::new(24, 24)
        $stockShell = $null
        try {
            $stockContext = New-SnipPreviewContext -Bitmap $stockBitmap `
                -SetWindowPosition { param($hwnd,$bounds) $true }
            $stockShell = New-SnipPreviewWindow -Context $stockContext
            Should-Be $stockContext.Shell.MoreButton.Visibility `
                ([System.Windows.Visibility]::Collapsed)
            Should-Be $stockContext.Shell.MoreMenu.IsOpen $false
        } finally {
            if ($null -ne $stockShell) { $stockShell.Window.Close() }
            $stockBitmap.Dispose()
        }
    }
}

Describe 'Settings persistence and diagnostics' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-' + [guid]::NewGuid())
    $settingsPath = Join-Path $root 'settings.json'
    $diagPath = Join-Path $root 'logs\snipit.log'
    $pictures = Join-Path $root 'Pictures'
    New-Item -ItemType Directory -Force -Path $root, $pictures | Out-Null

    It 'resolves the settings path below the supplied LocalAppData root' {
        Should-Be (Get-SnipSettingsPath -LocalAppData $root) (Join-Path $root 'SnipIT\settings.json')
    }

    It 'recovers defaults from malformed JSON' {
        Set-Content -LiteralPath $settingsPath -Value '{bad'
        $result = Read-SnipSettings -Path $settingsPath -PicturesDir $pictures
        Should-Be $result.Hotkey.VirtualKey 0x51
        Should-Be $result.Hotkey.Modifiers 0x4007
        Should-BeFalse $result.WidgetVisible
    }

    It 'normalizes every invalid loaded property against defaults' {
        @{
            Version = 'old'
            Hotkey = @{ Modifiers = 0; VirtualKey = 0x1B }
            SaveFolder = ''
            SaveFormat = 'Gif'
            LaunchAtSignIn = 'yes'
            WidgetVisible = $null
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath

        $result = Read-SnipSettings -Path $settingsPath -PicturesDir $pictures
        $defaults = Get-SnipDefaultSettings -PicturesDir $pictures
        Should-Be $result.Version $defaults.Version
        Should-Be $result.Hotkey.Modifiers $defaults.Hotkey.Modifiers
        Should-Be $result.Hotkey.VirtualKey $defaults.Hotkey.VirtualKey
        Should-Be $result.SaveFolder $defaults.SaveFolder
        Should-Be $result.SaveFormat $defaults.SaveFormat
        Should-Be $result.LaunchAtSignIn $defaults.LaunchAtSignIn
        Should-Be $result.WidgetVisible $defaults.WidgetVisible
    }

    It 'persists settings through a sibling temporary file' {
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        $settings.SaveFolder = Join-Path $pictures 'Custom'
        $settings.LaunchAtSignIn = $false
        Save-SnipSettings -Settings $settings -Path $settingsPath

        $loaded = Read-SnipSettings -Path $settingsPath -PicturesDir $pictures
        Should-Be $loaded.SaveFolder $settings.SaveFolder
        Should-BeFalse $loaded.LaunchAtSignIn
        Should-Be @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count 0
    }

    It 'leaves the file untouched when a save would rewrite identical content' {
        # The bootstrap calls Save-SnipSettings on every launch straight after
        # Read-SnipSettings. Rewriting an identical file only bumps the mtime.
        $idempotentPath = Join-Path $root 'idempotent.json'
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        Save-SnipSettings -Settings $settings -Path $idempotentPath
        $firstWrite = (Get-Item -LiteralPath $idempotentPath).LastWriteTimeUtc
        $firstBytes = [IO.File]::ReadAllBytes($idempotentPath)

        # Round-trip through Read-SnipSettings exactly like startup does.
        Start-Sleep -Milliseconds 40
        $reloaded = Read-SnipSettings -Path $idempotentPath -PicturesDir $pictures
        Save-SnipSettings -Settings $reloaded -Path $idempotentPath
        Should-Be (Get-Item -LiteralPath $idempotentPath).LastWriteTimeUtc $firstWrite
        Should-Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($idempotentPath))) `
            ([Convert]::ToBase64String($firstBytes))

        # A real change still goes through the temp-file + move write path.
        Start-Sleep -Milliseconds 40
        $reloaded.SaveFormat = 'Bmp'
        Save-SnipSettings -Settings $reloaded -Path $idempotentPath
        $changedWrite = (Get-Item -LiteralPath $idempotentPath).LastWriteTimeUtc
        Should-BeTrue ($changedWrite -gt $firstWrite)
        Should-Be (Read-SnipSettings -Path $idempotentPath -PicturesDir $pictures).SaveFormat 'Bmp'
        Should-Be @(Get-ChildItem -LiteralPath $root -Force -Filter '*.tmp').Count 0
    }

    It 'writes the first time even though the file does not exist yet' {
        $freshPath = Join-Path $root 'nested\fresh.json'
        Should-BeFalse (Test-Path -LiteralPath $freshPath)
        Save-SnipSettings -Settings (Get-SnipDefaultSettings -PicturesDir $pictures) -Path $freshPath
        Should-BeTrue (Test-Path -LiteralPath $freshPath -PathType Leaf)
    }

    It 'appends diagnostics to the durable log' {
        Write-SnipDiag -Message 'settings test diagnostic' -Path $diagPath
        Should-BeTrue (Test-Path -LiteralPath $diagPath)
        Should-BeTrue ((Get-Content -Raw -LiteralPath $diagPath).Contains('settings test diagnostic'))
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Hotkey registration and replacement' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-hotkey-' + [guid]::NewGuid())
    $settingsPath = Join-Path $root 'settings.json'
    $pictures = Join-Path $root 'Pictures'
    New-Item -ItemType Directory -Force -Path $root, $pictures | Out-Null

    It 'registers only hotkey ID 1 with the requested binding' {
        $calls = [System.Collections.ArrayList]::new()
        $register = {
            param($hwnd, $id, $mods, $vk)
            [void]$calls.Add([pscustomobject]@{ Id = $id; Modifiers = $mods; VirtualKey = $vk })
            $true
        }
        $binding = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        $result = Register-SnipHotkeyBinding -Hwnd ([IntPtr]::Zero) -Binding $binding -Register $register
        Should-BeTrue $result.Success
        Should-Be $calls.Count 1
        Should-Be $calls[0].Id 1
        Should-Be $calls[0].Modifiers 0x4007
        Should-Be $calls[0].VirtualKey 0x51
    }

    It 'persists a successful replacement only after registration' {
        Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $pictures
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        }
        $calls = [System.Collections.ArrayList]::new()
        $register = {
            param($hwnd, $id, $mods, $vk)
            Should-BeFalse (Test-Path -LiteralPath $settingsPath)
            [void]$calls.Add($vk)
            $true
        }
        $result = Set-SnipHotkeyBinding -Context $context -Candidate @{ Modifiers = 0x4007; VirtualKey = 0x52 } -Register $register -Unregister { $true }

        Should-BeTrue $result.Success
        Should-Be $result.ActiveBinding.VirtualKey 0x52
        Should-Be $context.Settings.Hotkey.VirtualKey 0x52
        Should-Be $context.RegisteredHotkey.VirtualKey 0x52
        Should-Be (Read-SnipSettings -Path $settingsPath -PicturesDir $pictures).Hotkey.VirtualKey 0x52
    }

    It 'rolls back when persistence fails under Continue error semantics' {
        $blockedParent = Join-Path $root 'blocked-parent'
        Remove-Item -LiteralPath $blockedParent -Recurse -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $blockedParent -Value 'this file cannot contain settings.json'
        $blockedSettingsPath = Join-Path $blockedParent 'settings.json'
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $pictures
            SettingsPath = $blockedSettingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        }
        $originalSettings = $context.Settings | ConvertTo-Json -Depth 4 -Compress
        $registerCalls = [System.Collections.ArrayList]::new()
        $unregisterCalls = [System.Collections.ArrayList]::new()
        $register = { param($hwnd, $id, $mods, $vk) [void]$registerCalls.Add($vk); $true }
        $unregister = { param($hwnd, $id) [void]$unregisterCalls.Add($id); $true }
        $priorErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $operationOutput = @(Set-SnipHotkeyBinding -Context $context `
                -Candidate @{ Modifiers = 0x4007; VirtualKey = 0x54 } `
                -Register $register -Unregister $unregister 2>&1)
        } finally {
            $ErrorActionPreference = $priorErrorActionPreference
        }
        $persistenceErrors = @($operationOutput | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
        $result = @($operationOutput | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })[-1]

        Should-BeFalse $result.Success
        Should-Be $result.ActiveBinding.VirtualKey 0x51
        Should-BeTrue (-not [string]::IsNullOrWhiteSpace($result.CandidateError))
        Should-Be $result.RollbackError $null
        Should-Be $registerCalls.Count 2
        Should-Be $registerCalls[0] 0x54
        Should-Be $registerCalls[1] 0x51
        Should-Be $unregisterCalls.Count 2
        Should-Be $unregisterCalls[0] 1
        Should-Be $unregisterCalls[1] 1
        Should-Be @($persistenceErrors).Count 0
        Should-Be ($context.Settings | ConvertTo-Json -Depth 4 -Compress) $originalSettings
        Should-Be $context.RegisteredHotkey.VirtualKey 0x51
        Should-BeFalse (Test-Path -LiteralPath $blockedSettingsPath)
    }

    It 'preserves an unsaved candidate when native cleanup cannot confirm it was removed' {
        $lockedSettingsPath = Join-Path $root 'locked-settings.json'
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        Save-SnipSettings -Settings $settings -Path $lockedSettingsPath
        $originalFile = Get-Content -Raw -LiteralPath $lockedSettingsPath
        $context = [pscustomobject]@{
            Settings = $settings
            SettingsPath = $lockedSettingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        }
        $state = @{ UnregisterCount = 0 }
        $unregister = {
            param($hwnd,$id)
            $state.UnregisterCount++
            return $state.UnregisterCount -eq 1
        }.GetNewClosure()
        $fileLock = [IO.File]::Open(
            $lockedSettingsPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $result = Set-SnipHotkeyBinding -Context $context `
                -Candidate @{ Modifiers = 0x4007; VirtualKey = 0x54 } `
                -Register { param($hwnd,$id,$mods,$vk) $true } -Unregister $unregister

            Should-BeFalse $result.Success
            Should-Be $result.ActiveBinding.VirtualKey 0x54
            Should-Be $context.RegisteredHotkey.VirtualKey 0x54
            Should-Be $context.Settings.Hotkey.VirtualKey 0x51
            Should-BeTrue $result.RollbackError.Contains('may remain active')
            Should-Be $state.UnregisterCount 2
            Should-Be (Get-Content -Raw -LiteralPath $lockedSettingsPath) $originalFile
            Should-Be @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count 0
        } finally {
            $fileLock.Dispose()
        }
    }

    It 'unregisters a preserved possibly-active candidate before a later replacement' {
        $followupSettingsPath = Join-Path $root 'followup-settings.json'
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        Save-SnipSettings -Settings $settings -Path $followupSettingsPath
        $context = [pscustomobject]@{
            Settings = $settings
            SettingsPath = $followupSettingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x54 }
        }
        $events = [System.Collections.ArrayList]::new()
        $unregister = {
            param($hwnd,$id)
            [void]$events.Add("Unregister:$id")
            $true
        }.GetNewClosure()
        $register = {
            param($hwnd,$id,$mods,$vk)
            [void]$events.Add("Register:$vk")
            $true
        }.GetNewClosure()

        $result = Set-SnipHotkeyBinding -Context $context `
            -Candidate @{ Modifiers = 0x4007; VirtualKey = 0x55 } `
            -Register $register -Unregister $unregister

        Should-BeTrue $result.Success
        Should-Be ($events -join ',') 'Unregister:1,Register:85'
        Should-Be $context.RegisteredHotkey.VirtualKey 0x55
        Should-Be $context.Settings.Hotkey.VirtualKey 0x55
        Should-Be (Read-SnipSettings -Path $followupSettingsPath -PicturesDir $pictures).Hotkey.VirtualKey 0x55
    }

    It 'restores the previous binding when the candidate is rejected' {
        Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $pictures
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        }
        $calls = [System.Collections.ArrayList]::new()
        $register = { param($hwnd, $id, $mods, $vk) [void]$calls.Add($vk); $vk -ne 0x53 }
        $result = Set-SnipHotkeyBinding -Context $context -Candidate @{ Modifiers = 0x4007; VirtualKey = 0x53 } -Register $register -Unregister { $true }

        Should-BeFalse $result.Success
        Should-Be $calls.Count 2
        Should-Be $calls[0] 0x53
        Should-Be $calls[1] 0x51
        Should-Be $result.ActiveBinding.VirtualKey 0x51
        Should-Be $context.Settings.Hotkey.VirtualKey 0x51
        Should-BeFalse (Test-Path -LiteralPath $settingsPath)
        Should-Be $result.RollbackError $null
    }

    It 'reports rollback failure without claiming an active binding' {
        Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $pictures
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        }
        $register = { param($hwnd, $id, $mods, $vk) $false }
        $result = Set-SnipHotkeyBinding -Context $context -Candidate @{ Modifiers = 0x4007; VirtualKey = 0x53 } -Register $register -Unregister { $true }

        Should-BeFalse $result.Success
        Should-Be $result.ActiveBinding $null
        Should-Be $context.RegisteredHotkey $null
        Should-BeTrue (-not [string]::IsNullOrWhiteSpace($result.CandidateError))
        Should-BeTrue (-not [string]::IsNullOrWhiteSpace($result.RollbackError))
        Should-Be $context.Settings.Hotkey.VirtualKey 0x51
        Should-BeFalse (Test-Path -LiteralPath $settingsPath)
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Startup shortcut synchronization' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-startup-' + [guid]::NewGuid())
    $desktop = Join-Path $root 'Desktop'
    $startup = Join-Path $root 'Startup'
    $pictures = Join-Path $root 'Pictures'
    New-Item -ItemType Directory -Force -Path $root, $desktop, $startup, $pictures | Out-Null
    $paths = Get-InstallPaths -LocalAppData $root -DesktopDir $desktop -StartupDir $startup
    New-Item -ItemType Directory -Force -Path $paths.AppDir | Out-Null
    Set-Content -LiteralPath $paths.ScriptPath -Value '# test launcher'

    It 'creates the Startup shortcut when LaunchAtSignIn is enabled' {
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        $priorTestMode = $env:SNIPIT_TEST_MODE
        try {
            Remove-Item Env:SNIPIT_TEST_MODE -ErrorAction SilentlyContinue
            Sync-SnipStartupShortcut -Settings $settings -Paths $paths
            Should-BeTrue (Test-Path -LiteralPath $paths.StartupShortcut)
        } finally {
            $env:SNIPIT_TEST_MODE = $priorTestMode
        }
    }

    It 'removes the Startup shortcut when LaunchAtSignIn is disabled' {
        Set-Content -LiteralPath $paths.StartupShortcut -Value 'legacy shortcut'
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        $settings.LaunchAtSignIn = $false
        $priorTestMode = $env:SNIPIT_TEST_MODE
        try {
            Remove-Item Env:SNIPIT_TEST_MODE -ErrorAction SilentlyContinue
            Sync-SnipStartupShortcut -Settings $settings -Paths $paths
            Should-BeFalse (Test-Path -LiteralPath $paths.StartupShortcut)
        } finally {
            $env:SNIPIT_TEST_MODE = $priorTestMode
        }
    }

    It 'makes no shortcut writes in SNIPIT_TEST_MODE' {
        Remove-Item -LiteralPath $paths.StartupShortcut -Force -ErrorAction SilentlyContinue
        $settings = Get-SnipDefaultSettings -PicturesDir $pictures
        Sync-SnipStartupShortcut -Settings $settings -Paths $paths
        Should-BeFalse (Test-Path -LiteralPath $paths.StartupShortcut)
    }

    It 'makes no installation writes in SNIPIT_TEST_MODE' {
        $installRoot = Join-Path $root 'guarded-install'
        $guardedPaths = Get-InstallPaths -LocalAppData $installRoot `
            -DesktopDir (Join-Path $installRoot 'Desktop') `
            -StartupDir (Join-Path $installRoot 'Startup')
        $result = Install-SnipIT -Paths $guardedPaths
        Should-BeFalse $result
        Should-BeFalse (Test-Path -LiteralPath $guardedPaths.AppDir)
        Should-BeFalse (Test-Path -LiteralPath $guardedPaths.DesktopShortcut)
        Should-BeFalse (Test-Path -LiteralPath $guardedPaths.StartupShortcut)
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Application icon (.ico container)' {
    # System.Drawing is Windows-only, so the ICO writer is exercised here
    # rather than in the portable Test-SnipIT.ps1 suite.
    $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-icon-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $icoPath = Join-Path $root 'SnipIT.ico'
    $sizes = @(16, 24, 32, 48)
    New-SnipITIcon -Path $icoPath -Sizes $sizes | Out-Null
    $bytes = [IO.File]::ReadAllBytes($icoPath)

    function Get-SnipTestIcoEntry {
        param([byte[]]$Bytes, [int]$Index)
        $o = 6 + (16 * $Index)
        [pscustomobject]@{
            Width    = [int]$Bytes[$o]
            Height   = [int]$Bytes[$o + 1]
            Colors   = [int]$Bytes[$o + 2]
            Reserved = [int]$Bytes[$o + 3]
            Planes   = [int][BitConverter]::ToUInt16($Bytes, $o + 4)
            BitCount = [int][BitConverter]::ToUInt16($Bytes, $o + 6)
            Length   = [int][BitConverter]::ToUInt32($Bytes, $o + 8)
            Offset   = [int][BitConverter]::ToUInt32($Bytes, $o + 12)
        }
    }

    It 'writes an ICONDIR with five entries' {
        Should-Be ([BitConverter]::ToUInt16($bytes, 0)) 0   # idReserved
        Should-Be ([BitConverter]::ToUInt16($bytes, 2)) 1   # idType = icon
        Should-Be ([BitConverter]::ToUInt16($bytes, 4)) 5   # 16/24/32/48 + 256
    }

    It 'declares the expected sizes in ascending order, 256 encoded as 0' {
        $declared = @(0..4 | ForEach-Object { (Get-SnipTestIcoEntry -Bytes $bytes -Index $_).Width })
        Should-Be ($declared -join ',') '16,24,32,48,0'
        $declaredHeights = @(0..4 | ForEach-Object { (Get-SnipTestIcoEntry -Bytes $bytes -Index $_).Height })
        Should-Be ($declaredHeights -join ',') '16,24,32,48,0'
    }

    It 'marks every entry 32-bpp truecolor with one plane' {
        foreach ($i in 0..4) {
            $entry = Get-SnipTestIcoEntry -Bytes $bytes -Index $i
            Should-Be $entry.Planes 1
            Should-Be $entry.BitCount 32
            Should-Be $entry.Colors 0
            Should-Be $entry.Reserved 0
        }
    }

    It 'lays out running offsets that start past the directory and tile exactly' {
        $expected = 6 + (16 * 5)
        foreach ($i in 0..4) {
            $entry = Get-SnipTestIcoEntry -Bytes $bytes -Index $i
            Should-Be $entry.Offset $expected
            Should-BeTrue ($entry.Length -gt 0)
            $expected += $entry.Length
        }
        Should-Be $expected $bytes.Length
    }

    It 'stores 16/24/32/48 as BITMAPINFOHEADER DIBs with doubled height' {
        foreach ($i in 0..3) {
            $entry = Get-SnipTestIcoEntry -Bytes $bytes -Index $i
            $size = $sizes[$i]
            Should-Be ([BitConverter]::ToUInt32($bytes, $entry.Offset)) 40          # biSize
            Should-Be ([BitConverter]::ToInt32($bytes, $entry.Offset + 4)) $size    # biWidth
            Should-Be ([BitConverter]::ToInt32($bytes, $entry.Offset + 8)) ($size * 2)
            Should-Be ([BitConverter]::ToUInt16($bytes, $entry.Offset + 14)) 32     # biBitCount
            Should-Be ([BitConverter]::ToUInt32($bytes, $entry.Offset + 16)) 0      # BI_RGB
            # 40-byte header + XOR bitmap + row-padded (all-zero) AND mask.
            $maskStride = [int]([math]::Floor(($size + 31) / 32) * 4)
            Should-Be $entry.Length (40 + ($size * $size * 4) + ($maskStride * $size))
        }
    }

    It 'stores the 256 master as a PNG entry' {
        $entry = Get-SnipTestIcoEntry -Bytes $bytes -Index 4
        Should-Be $bytes[$entry.Offset] 0x89
        Should-Be $bytes[$entry.Offset + 1] 0x50   # 'P'
        Should-Be $bytes[$entry.Offset + 2] 0x4E   # 'N'
        Should-Be $bytes[$entry.Offset + 3] 0x47   # 'G'
    }

    It 'resolves a 16x16 request to the real 16 px entry, not a squashed 256' {
        $icon = New-Object System.Drawing.Icon ($icoPath, [Drawing.Size]::new(16, 16))
        try {
            Should-Be $icon.Width 16
            Should-Be $icon.Height 16
        } finally { $icon.Dispose() }
    }

    It 'resolves 24, 32, and 48 requests to their own entries' {
        foreach ($size in @(24, 32, 48)) {
            $icon = New-Object System.Drawing.Icon ($icoPath, [Drawing.Size]::new($size, $size))
            try {
                Should-Be $icon.Width $size
                Should-Be $icon.Height $size
            } finally { $icon.Dispose() }
        }
    }

    It 'renders a distinct bitmap per size (a single-entry ICO would repeat)' {
        $rendered = @{}
        foreach ($size in @(16, 32)) {
            $icon = New-Object System.Drawing.Icon ($icoPath, [Drawing.Size]::new($size, $size))
            try {
                $bmp = $icon.ToBitmap()
                try { $rendered[$size] = $bmp.GetPixel([int]($size / 2), 2).ToArgb() }
                finally { $bmp.Dispose() }
            } finally { $icon.Dispose() }
        }
        # Top-centre is inside the rounded background on both entries; the
        # assertion that matters is that each entry decoded at its own size.
        Should-Be $rendered.Count 2
    }

    It 'ConvertTo-SnipIcoBytes honours a custom size list' {
        $master = Get-SnipITLogoBitmap
        try {
            Should-Be $master.Width 256
            Should-Be $master.Height 256
            $custom = ConvertTo-SnipIcoBytes -Bitmap $master -Sizes @(32, 16)
        } finally { $master.Dispose() }
        Should-Be ([BitConverter]::ToUInt16($custom, 4)) 3
        # -Sizes is sorted, so 16 precedes 32 regardless of the input order.
        Should-Be ((Get-SnipTestIcoEntry -Bytes $custom -Index 0).Width) 16
        Should-Be ((Get-SnipTestIcoEntry -Bytes $custom -Index 1).Width) 32
        Should-Be ((Get-SnipTestIcoEntry -Bytes $custom -Index 2).Width) 0
        Should-Be ((Get-SnipTestIcoEntry -Bytes $custom -Index 0).Offset) (6 + (16 * 3))
    }

    It 'writes a sha256 sidecar and skips the rewrite when content is unchanged' {
        Should-BeTrue (Test-Path -LiteralPath "$icoPath.sha256" -PathType Leaf)
        $recorded = (Get-Content -LiteralPath "$icoPath.sha256" -Raw).Trim()
        Should-Be $recorded ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)))

        $before = (Get-Item -LiteralPath $icoPath).LastWriteTimeUtc
        Start-Sleep -Milliseconds 40
        New-SnipITIcon -Path $icoPath -Sizes $sizes | Out-Null
        Should-Be (Get-Item -LiteralPath $icoPath).LastWriteTimeUtc $before
    }

    It 'rewrites when the recorded hash no longer matches' {
        Set-Content -LiteralPath "$icoPath.sha256" -Value 'stale' -NoNewline
        $before = (Get-Item -LiteralPath $icoPath).LastWriteTimeUtc
        Start-Sleep -Milliseconds 40
        New-SnipITIcon -Path $icoPath -Sizes $sizes | Out-Null
        Should-BeTrue ((Get-Item -LiteralPath $icoPath).LastWriteTimeUtc -ne $before)
        Should-Be (Get-Content -LiteralPath "$icoPath.sha256" -Raw).Trim() `
            ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($icoPath))))
    }

    It 'embeds both logo constants as decodable PNGs of the expected size' {
        foreach ($case in @(
                @{ Variant = 'Master'; Size = 256 },
                @{ Variant = 'Small';  Size = 32  })) {
            $png = Get-SnipLogoPngBytes -Variant $case.Variant
            Should-BeTrue ($null -ne $png)
            Should-BeTrue ($png.Length -gt 0)
            # PNG magic number.
            Should-Be $png[0] 0x89
            Should-Be $png[1] 0x50
            Should-Be $png[2] 0x4E
            Should-Be $png[3] 0x47
            $stream = New-Object System.IO.MemoryStream (, $png)
            try {
                $image = [System.Drawing.Image]::FromStream($stream)
                try {
                    Should-Be $image.Width $case.Size
                    Should-Be $image.Height $case.Size
                } finally { $image.Dispose() }
            } finally { $stream.Dispose() }
        }
    }

    It 'exposes the embedded master, its PNG bytes, and the small variant' {
        $source = Get-SnipITLogoSource
        try {
            Should-Be $source.Master.Width 256
            Should-Be $source.Master.Height 256
            Should-Be $source.Small.Width 32
            Should-Be $source.Small.Height 32
            Should-BeTrue ($null -ne $source.MasterPng)
        } finally {
            if ($null -ne $source.Small) { $source.Small.Dispose() }
            $source.Master.Dispose()
        }
    }

    It 'ships the 256 entry as the embedded master PNG byte-for-byte' {
        $entry = Get-SnipTestIcoEntry -Bytes $bytes -Index 4
        $embedded = Get-SnipLogoPngBytes -Variant Master
        Should-Be $entry.Length $embedded.Length
        $carried = New-Object byte[] $entry.Length
        [Array]::Copy($bytes, $entry.Offset, $carried, 0, $entry.Length)
        Should-Be ([Convert]::ToHexString($carried)) ([Convert]::ToHexString($embedded))
    }

    It 'derives 16/24/32 from the simplified variant and 48 from the master' {
        $source = Get-SnipITLogoSource
        try {
            foreach ($case in @(
                    @{ Size = 32; Bitmap = $source.Small },
                    @{ Size = 48; Bitmap = $source.Master })) {
                $expected = ConvertTo-SnipIconDibBytes -Bitmap $case.Bitmap -Size $case.Size
                $index = @(16, 24, 32, 48).IndexOf($case.Size)
                $entry = Get-SnipTestIcoEntry -Bytes $bytes -Index $index
                Should-Be $entry.Length $expected.Length
                $carried = New-Object byte[] $entry.Length
                [Array]::Copy($bytes, $entry.Offset, $carried, 0, $entry.Length)
                Should-Be ([Convert]::ToHexString($carried)) ([Convert]::ToHexString($expected))
            }
            # And the two sources really are different artwork, so the check above
            # is not passing by coincidence.
            $fromMaster = ConvertTo-SnipIconDibBytes -Bitmap $source.Master -Size 32
            $fromSmall = ConvertTo-SnipIconDibBytes -Bitmap $source.Small -Size 32
            Should-BeTrue (([Convert]::ToHexString($fromMaster)) -ne ([Convert]::ToHexString($fromSmall)))
        } finally {
            if ($null -ne $source.Small) { $source.Small.Dispose() }
            $source.Master.Dispose()
        }
    }

    It 'falls back to the procedural mark when the embedded master is unusable' {
        $priorMaster = $script:SnipLogoPng256
        try {
            $script:SnipLogoPng256 = 'bm90LWEtcG5n'   # valid base64, not a PNG
            $source = Get-SnipITLogoSource
            try {
                Should-Be $source.Master.Width 256
                Should-Be $source.Master.Height 256
                # No PNG bytes, so the writer re-encodes instead of pairing the
                # fallback bitmap with unrelated bytes.
                Should-Be $source.MasterPng $null
            } finally {
                if ($null -ne $source.Small) { $source.Small.Dispose() }
                $source.Master.Dispose()
            }
        } finally { $script:SnipLogoPng256 = $priorMaster }
    }

    It 'Get-SnipITIconPath regenerates once per process and no-ops afterwards' {
        $priorHome = $script:AppHomeDir
        $priorEnsured = $script:SnipIconEnsuredPath
        try {
            $script:AppHomeDir = $root
            $script:SnipIconEnsuredPath = $null
            Remove-Item -LiteralPath $icoPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$icoPath.sha256" -Force -ErrorAction SilentlyContinue

            $first = Get-SnipITIconPath
            Should-Be $first $icoPath
            Should-BeTrue (Test-Path -LiteralPath $icoPath -PathType Leaf)

            # Deleting the file proves the second call does no work at all.
            Remove-Item -LiteralPath $icoPath -Force
            $second = Get-SnipITIconPath
            Should-Be $second $icoPath
            Should-BeFalse (Test-Path -LiteralPath $icoPath)
        } finally {
            $script:AppHomeDir = $priorHome
            $script:SnipIconEnsuredPath = $priorEnsured
        }
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Desktop shortcut rewrite gating' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-lnk-' + [guid]::NewGuid())
    $appDir = Join-Path $root 'App'
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    $scriptTarget = Join-Path $appDir 'SnipIT.ps1'
    Set-Content -LiteralPath $scriptTarget -Value '# test launcher'
    $altTarget = Join-Path $appDir 'Other.ps1'
    Set-Content -LiteralPath $altTarget -Value '# other launcher'
    $iconPath = Join-Path $appDir 'SnipIT.ico'
    New-SnipITIcon -Path $iconPath | Out-Null
    $lnk = Join-Path $root 'SnipIT.lnk'

    It 'creates the shortcut when it is missing' {
        Should-BeTrue (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $scriptTarget -IconPath $iconPath)
        Should-BeTrue (Test-Path -LiteralPath $lnk -PathType Leaf)
    }

    It 'leaves an up-to-date shortcut completely untouched' {
        $before = (Get-Item -LiteralPath $lnk).LastWriteTimeUtc
        Start-Sleep -Milliseconds 40
        Should-BeFalse (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $scriptTarget -IconPath $iconPath)
        Should-Be (Get-Item -LiteralPath $lnk).LastWriteTimeUtc $before
    }

    It 'repairs the shortcut when its arguments drifted' {
        Should-BeTrue (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $altTarget -IconPath $iconPath)
        $shell = New-Object -ComObject WScript.Shell
        try {
            $lnkObject = $shell.CreateShortcut($lnk)
            Should-Be $lnkObject.Arguments (Get-ShortcutArguments -ScriptPath $altTarget)
            Should-Be $lnkObject.IconLocation "$iconPath,0"
            Should-Be $lnkObject.WorkingDirectory $appDir
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($lnkObject)
        } finally {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        Should-BeFalse (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $altTarget -IconPath $iconPath)
    }

    It 'never deletes the shortcut it is about to compare' {
        # A delete-then-recreate implementation would lose the marker below.
        $marker = (Get-Item -LiteralPath $lnk).CreationTimeUtc
        Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $altTarget -IconPath $iconPath | Out-Null
        Should-Be (Get-Item -LiteralPath $lnk).CreationTimeUtc $marker
    }

    It 'stamps the shortcut description with the icon content hash' {
        $shell = New-Object -ComObject WScript.Shell
        try {
            $lnkObject = $shell.CreateShortcut($lnk)
            Should-Be $lnkObject.Description `
                (Get-SnipShortcutDescription -IconStamp (Get-SnipIconStamp -IconPath $iconPath))
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($lnkObject)
        } finally {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    It 'rewrites the shortcut when only the icon artwork changed' {
        # Target, arguments, and the .ico path all stay put; the artwork inside
        # the .ico is what moved. Explorer caches the bitmap it already drew, so
        # this has to register as drift or the Desktop keeps the old icon.
        Should-BeFalse (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $altTarget -IconPath $iconPath)

        $newStamp = 'B' * 64
        Set-Content -LiteralPath "$iconPath.sha256" -Value $newStamp -Encoding ascii -NoNewline
        Should-BeTrue (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $altTarget -IconPath $iconPath)

        $shell = New-Object -ComObject WScript.Shell
        try {
            $lnkObject = $shell.CreateShortcut($lnk)
            Should-Be $lnkObject.Description (Get-SnipShortcutDescription -IconStamp $newStamp)
            Should-Be $lnkObject.IconLocation "$iconPath,0"
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($lnkObject)
        } finally {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }

        # And it settles again rather than rewriting on every launch.
        Should-BeFalse (Write-SnipITShortcut -Path $lnk -AppDir $appDir `
            -ScriptTarget $altTarget -IconPath $iconPath)
    }

    It 'Get-SnipIconStamp prefers the sidecar and falls back to the file hash' {
        Set-Content -LiteralPath "$iconPath.sha256" -Value 'C0FFEE' -Encoding ascii -NoNewline
        Should-Be (Get-SnipIconStamp -IconPath $iconPath) 'C0FFEE'

        Remove-Item -LiteralPath "$iconPath.sha256" -Force
        Should-Be (Get-SnipIconStamp -IconPath $iconPath) `
            (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash

        Should-Be (Get-SnipIconStamp -IconPath (Join-Path $appDir 'no-such.ico')) ''
        Should-Be (Get-SnipIconStamp -IconPath '') ''
    }

    It 'New-SnipITIcon reports whether it actually rewrote the file' {
        $probe = Join-Path $appDir 'Probe.ico'
        Remove-Item -LiteralPath $probe, "$probe.sha256" -Force -ErrorAction SilentlyContinue
        Should-BeTrue (New-SnipITIcon -Path $probe)
        Should-BeFalse (New-SnipITIcon -Path $probe)
    }

    It 'Update-SnipShellItem and the icon cache flush are safe to call' {
        # Both are best-effort shell notifications; the contract that matters is
        # that they never throw into the installer.
        Should-BeTrue (Update-SnipShellItem -Path $lnk)
        $priorFlush = $script:SnipShellIconCacheFlushed
        try {
            $script:SnipShellIconCacheFlushed = $false
            Should-BeTrue (Invoke-SnipShellIconCacheFlush)
            # Broadcast to every shell window, so it is sent at most once.
            Should-BeFalse (Invoke-SnipShellIconCacheFlush)
        } finally { $script:SnipShellIconCacheFlushed = $priorFlush }
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Diagnostics log routing under SNIPIT_TEST_MODE' {
    It 'defaults to a temp log instead of the installed app log' {
        $testLog = Join-Path ([IO.Path]::GetTempPath()) 'snipit-test-logs\snipit.log'
        Remove-Item -LiteralPath $testLog -Force -ErrorAction SilentlyContinue
        Should-BeTrue ([bool]$env:SNIPIT_TEST_MODE)

        $token = 'diag-routing-' + [guid]::NewGuid()
        Write-SnipDiag -Message $token
        Should-BeTrue (Test-Path -LiteralPath $testLog -PathType Leaf)
        Should-BeTrue ((Get-Content -LiteralPath $testLog -Raw) -like "*$token*")

        # And nothing landed in the production log path.
        $productionLog = Join-Path (Split-Path (Get-SnipSettingsPath) -Parent) 'logs\snipit.log'
        if (Test-Path -LiteralPath $productionLog -PathType Leaf) {
            Should-BeFalse ((Get-Content -LiteralPath $productionLog -Raw) -like "*$token*")
        }
        Remove-Item -LiteralPath $testLog -Force -ErrorAction SilentlyContinue
    }

    It 'still honours an explicit -Path' {
        $explicit = Join-Path ([IO.Path]::GetTempPath()) ("snipit-diag-" + [guid]::NewGuid() + '\snipit.log')
        $token = 'diag-explicit-' + [guid]::NewGuid()
        Write-SnipDiag -Message $token -Path $explicit
        Should-BeTrue ((Get-Content -LiteralPath $explicit -Raw) -like "*$token*")
        Remove-Item -LiteralPath (Split-Path $explicit -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-OwnershipProbe {
    param([string]$Id = ([guid]::NewGuid().ToString()))
    $probe = [pscustomobject]@{
        Id = $Id
        DisposeCount = 0
        Disposed = $false
        TouchCount = 0
    }
    $probe | Add-Member -MemberType ScriptMethod -Name Touch -Value {
        if ($this.Disposed) { throw [ObjectDisposedException]::new($this.Id) }
        $this.TouchCount++
    }
    $probe | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        if ($this.Disposed) { throw [InvalidOperationException]::new("Double dispose: $($this.Id)") }
        $this.Disposed = $true
        $this.DisposeCount++
    }
    $probe
}

Describe 'Screen bitmap construction ownership' {
    It 'disposes the allocated bitmap when Graphics creation fails' {
        $parameters = (Get-Command New-ScreenBitmap).Parameters
        Should-BeTrue $parameters.ContainsKey('BitmapFactory')
        Should-BeTrue $parameters.ContainsKey('GraphicsFactory')
        Should-BeTrue $parameters.ContainsKey('CopyPixels')
        $bitmap = New-OwnershipProbe -Id graphics-factory-bitmap
        $threw = $false
        $state = @{ GraphicsCalls = 0; CopyCalls = 0; ErrorMessage = $null }
        try {
            New-ScreenBitmap -X 0 -Y 0 -Width 8 -Height 8 `
                -BitmapFactory { param($width,$height,$pixelFormat) $bitmap }.GetNewClosure() `
                -GraphicsFactory {
                    param($ownedBitmap)
                    $state.GraphicsCalls++
                    throw 'graphics creation failed'
                }.GetNewClosure() `
                -CopyPixels {
                    param($graphics,$x,$y,$width,$height)
                    $state.CopyCalls++
                    throw 'copy should not run'
                }.GetNewClosure() |
                Out-Null
        } catch {
            $threw = $true
            $state.ErrorMessage = $_.Exception.Message
        }

        Should-BeTrue $threw
        Should-Be $state.GraphicsCalls 1
        Should-Be $state.CopyCalls 0
        Should-Be $state.ErrorMessage 'graphics creation failed'
        Should-Be $bitmap.DisposeCount 1
    }

    It 'disposes Graphics and the bitmap when screen copy fails' {
        $parameters = (Get-Command New-ScreenBitmap).Parameters
        Should-BeTrue $parameters.ContainsKey('BitmapFactory')
        Should-BeTrue $parameters.ContainsKey('GraphicsFactory')
        Should-BeTrue $parameters.ContainsKey('CopyPixels')
        $bitmap = New-OwnershipProbe -Id copy-failure-bitmap
        $graphics = New-OwnershipProbe -Id copy-failure-graphics
        $threw = $false
        try {
            New-ScreenBitmap -X 0 -Y 0 -Width 8 -Height 8 `
                -BitmapFactory { param($width,$height,$pixelFormat) $bitmap }.GetNewClosure() `
                -GraphicsFactory { param($ownedBitmap) $graphics }.GetNewClosure() `
                -CopyPixels { param($ownedGraphics,$x,$y,$width,$height) throw 'copy failed' } |
                Out-Null
        } catch {
            $threw = $true
        }

        Should-BeTrue $threw
        Should-Be $graphics.DisposeCount 1
        Should-Be $bitmap.DisposeCount 1
    }

    It 'returns the bitmap and disposes only Graphics after a successful copy' {
        $parameters = (Get-Command New-ScreenBitmap).Parameters
        Should-BeTrue $parameters.ContainsKey('BitmapFactory')
        Should-BeTrue $parameters.ContainsKey('GraphicsFactory')
        Should-BeTrue $parameters.ContainsKey('CopyPixels')
        $bitmap = New-OwnershipProbe -Id successful-screen-bitmap
        $graphics = New-OwnershipProbe -Id successful-screen-graphics
        $copyState = @{ Count = 0 }
        $result = New-ScreenBitmap -X -10 -Y 20 -Width 8 -Height 8 `
            -BitmapFactory { param($width,$height,$pixelFormat) $bitmap }.GetNewClosure() `
            -GraphicsFactory { param($ownedBitmap) $graphics }.GetNewClosure() `
            -CopyPixels {
                param($ownedGraphics,$x,$y,$width,$height)
                $copyState.Count++
                Should-Be $x -10
                Should-Be $y 20
                Should-Be $width 8
                Should-Be $height 8
            }.GetNewClosure()

        Should-BeTrue ([object]::ReferenceEquals($result, $bitmap))
        Should-Be $copyState.Count 1
        Should-Be $graphics.DisposeCount 1
        Should-Be $bitmap.DisposeCount 0
        $bitmap.Dispose()
    }
}

Describe 'Smart overlay snapshot ownership' {
    It 'restores hidden windows when snapshot allocation fails' {
        $state = @{ Hidden = 0; Restored = 0 }
        $result = Show-SmartOverlay `
            -HideWindows { $state.Hidden++; @('own-window') }.GetNewClosure() `
            -RestoreWindows { param($hidden) $state.Restored++; Should-Be @($hidden)[0] 'own-window' }.GetNewClosure() `
            -CaptureFactory { param($bounds) throw 'snapshot failed' }

        Should-Be $result.Result 'Failed'
        Should-Be $state.Hidden 1
        Should-Be $state.Restored 1
    }

    It 'disposes the virtual snapshot once when BitmapSource conversion fails' {
        $snapshot = New-OwnershipProbe -Id virtual-snapshot
        $result = Show-SmartOverlay `
            -HideWindows { @() } `
            -RestoreWindows { param($hidden) } `
            -CaptureFactory { param($bounds) $snapshot }.GetNewClosure() `
            -BitmapSourceFactory { param($bitmap) throw 'conversion failed' }

        Should-Be $result.Result 'Failed'
        Should-Be $snapshot.DisposeCount 1
    }

    It 'skips the modal overlay when surface readiness declines it' {
        $snapshot = New-OwnershipProbe -Id declined-smart-surface
        $state = @{ ReadyCount = 0 }
        $result = Show-SmartOverlay `
            -HideWindows { @() } `
            -RestoreWindows { param($hidden) } `
            -CaptureFactory { param($bounds) $snapshot }.GetNewClosure() `
            -BitmapSourceFactory { param($bitmap) $null } `
            -OnSurfaceReady {
                param($surface)
                $state.ReadyCount++
                $close = $surface.Close
                & $close 'Preempted'
                $false
            }.GetNewClosure()

        Should-Be $state.ReadyCount 1
        Should-Be $result.Result 'Preempted'
        Should-Be $snapshot.DisposeCount 1
    }
}

function New-SnipOverlayTestFixture {
    param([object[]]$MonitorDescriptors = @(
        [pscustomobject][ordered]@{
            Id = 'left-125'; X = -1600; Y = 0; Width = 1600; Height = 900
            DpiX = 120; DpiY = 120; IsPrimary = $false
        },
        [pscustomobject][ordered]@{
            Id = 'primary-100'; X = 0; Y = 0; Width = 1920; Height = 1080
            DpiX = 96; DpiY = 96; IsPrimary = $true
        }
    ))

    $snapshot = New-OwnershipProbe -Id overlay-snapshot
    $snapshotSource = [System.Windows.Media.Imaging.WriteableBitmap]::new(
        3520, 1080, 96, 96,
        [System.Windows.Media.PixelFormats]::Bgra32,
        $null)
    $snapshotSource.Freeze()
    $state = @{
        MonitorDescriptors = $MonitorDescriptors
        Snapshot = $snapshot
        SnapshotSource = $snapshotSource
        HideCount = 0
        RestoreCount = 0
        SnapshotCount = 0
        ConvertCount = 0
        RegisterHandles = [System.Collections.ArrayList]::new()
        UnregisterHandles = [System.Collections.ArrayList]::new()
        RenderingAdds = [System.Collections.ArrayList]::new()
        RenderingRemoves = [System.Collections.ArrayList]::new()
        CursorX = -500
        CursorY = 100
        CursorCount = 0
        WindowAtPointCount = 0
        WindowBoundsCount = 0
        HoverWidth = 400
        OwnRegistryHandles = @()
        OwnRegistryReads = 0
        PositionCalls = 0
        # Watchdog seams. Zero means "something other than an overlay owns the
        # foreground", which is half of what the watchdog needs; the other half
        # is an idle LastInputUtc, which the context starts at "now" so the
        # default 20 s timeout never trips in the other tests.
        ForegroundHwnd = [IntPtr]::Zero
        Diagnostics = [System.Collections.ArrayList]::new()
    }
    $services = [pscustomobject][ordered]@{
        GetMonitorDescriptors = {
            @($state.MonitorDescriptors)
        }.GetNewClosure()
        GetVirtualBounds = {
            [pscustomobject][ordered]@{ X=-1600; Y=0; Width=3520; Height=1080 }
        }
        HideWindows = {
            $state.HideCount++
            @('utility-window')
        }.GetNewClosure()
        RestoreWindows = {
            param($hidden)
            $state.RestoreCount++
            Should-Be @($hidden)[0] 'utility-window'
        }.GetNewClosure()
        CaptureSnapshot = {
            param($bounds)
            $state.SnapshotCount++
            Should-Be $bounds.X -1600
            Should-Be $bounds.Width 3520
            $state.Snapshot
        }.GetNewClosure()
        ConvertSnapshotSource = {
            param($bitmap)
            $state.ConvertCount++
            Should-BeTrue ([object]::ReferenceEquals($bitmap, $state.Snapshot))
            $state.SnapshotSource
        }.GetNewClosure()
        GetCursorPosition = {
            $state.CursorCount++
            [pscustomobject][ordered]@{ X=$state.CursorX; Y=$state.CursorY }
        }.GetNewClosure()
        GetWindowAtPoint = {
            param($point,$ownHandles)
            $state.WindowAtPointCount++
            [IntPtr]4242
        }.GetNewClosure()
        GetWindowBounds = {
            param($hwnd)
            $state.WindowBoundsCount++
            [pscustomobject][ordered]@{
                X=-200; Y=40; Width=$state.HoverWidth; Height=300
            }
        }.GetNewClosure()
        GetOwnWindowHandles = {
            $state.OwnRegistryReads++
            @($state.OwnRegistryHandles)
        }.GetNewClosure()
        GetForegroundWindow = {
            [IntPtr]$state.ForegroundHwnd
        }.GetNewClosure()
        WriteDiagnostic = {
            param($message)
            [void]$state.Diagnostics.Add([string]$message)
        }.GetNewClosure()
        PositionWindow = {
            param($hwnd,$layout)
            $state.PositionCalls++
            $true
        }.GetNewClosure()
        AddRenderingHandler = {
            param($handler)
            [void]$state.RenderingAdds.Add($handler)
        }.GetNewClosure()
        RemoveRenderingHandler = {
            param($handler)
            [void]$state.RenderingRemoves.Add($handler)
        }.GetNewClosure()
        RegisterWindow = {
            param($hwnd)
            [void]$state.RegisterHandles.Add([Int64]$hwnd)
        }.GetNewClosure()
        UnregisterWindow = {
            param($hwnd)
            [void]$state.UnregisterHandles.Add([Int64]$hwnd)
        }.GetNewClosure()
        HighContrast = $false
    }

    [pscustomobject][ordered]@{
        State = $state
        Services = $services
    }
}

Describe 'Per-monitor Smart overlay set' {
    It 'uses one accepted topology object for Smart overlays and the resulting crop' {
        $descriptors = @(
            [pscustomobject]@{ Id='left'; X=-1200; Y=-200; Width=1200; Height=1600; WorkX=-1200; WorkY=-160; WorkWidth=1200; WorkHeight=1560; DpiX=144; DpiY=144; IsPrimary=$false },
            [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $topology = New-SnipDisplayTopology -MonitorDescriptors $descriptors -RequestId smart-stable
        $state = @{ Reads=0; OverlayTopology=$null; CaptureBounds=$null }
        $services = New-SnipRuntimeCaptureServices `
            -GetTopology { $state.Reads++; $topology }.GetNewClosure() `
            -SmartOverlay {
                param($ready,$coordinator,$request,$transactionTopology)
                $state.OverlayTopology = $transactionTopology
                & $ready ([pscustomobject]@{ Close={ param($result) } }) | Out-Null
                [pscustomobject]@{
                    Result='Completed'
                    Selection=[pscustomobject]@{ X=-100; Y=25; Width=300; Height=450 }
                    Bitmap=$null
                    ErrorRecord=$null
                }
            }.GetNewClosure() `
            -HideWindows { @() } `
            -RestoreWindows { param($hidden) } `
            -CaptureRectangle {
                param($bounds)
                $state.CaptureBounds = $bounds
                New-OwnershipProbe -Id smart-topology-crop
            }.GetNewClosure()
        $request = New-SnipCaptureRequest -Mode Smart -Source StableTopology
        $coordinator = New-SnipCaptureCoordinator -Services $services
        $coordinator.ActiveRequest = $request
        $coordinator.Phase = 'CaptureStarting'

        $result = & $services.SmartCapture $coordinator $request

        Should-Be $state.Reads 2
        Should-BeTrue ([object]::ReferenceEquals($state.OverlayTopology, $topology))
        Should-Be $state.CaptureBounds.X -100
        Should-Be $state.CaptureBounds.Height 450
        $result.Dispose()
    }

    It 'retries one Smart topology drift then cancels visibly on a second drift' {
        $makeTopology = {
            param($id,$width,$dpi)
            New-SnipDisplayTopology -RequestId $id -MonitorDescriptors @(
                [pscustomobject]@{ Id='only'; X=0; Y=0; Width=$width; Height=900; WorkX=0; WorkY=0; WorkWidth=$width; WorkHeight=860; DpiX=$dpi; DpiY=$dpi; IsPrimary=$true }
            )
        }
        $topologies = @(
            & $makeTopology first-a 1400 96
            & $makeTopology first-b 1400 144
            & $makeTopology second-a 1600 144
            & $makeTopology second-b 1600 192
        )
        $state = @{ Reads=0; OverlayCalls=0; Notices=[System.Collections.ArrayList]::new() }
        $services = New-SnipRuntimeCaptureServices `
            -GetTopology {
                $value = $topologies[$state.Reads]
                $state.Reads++
                $value
            }.GetNewClosure() `
            -SmartOverlay { param($ready,$coordinator,$request,$topology) $state.OverlayCalls++ } `
            -NotifyFailure { param($message) [void]$state.Notices.Add($message) }.GetNewClosure()
        $request = New-SnipCaptureRequest -Mode Smart -Source DriftingTopology
        $coordinator = New-SnipCaptureCoordinator -Services $services
        $coordinator.ActiveRequest = $request
        $coordinator.Phase = 'CaptureStarting'

        $result = & $services.SmartCapture $coordinator $request

        Should-Be $result.Result 'Failed'
        Should-Be $state.Reads 4
        Should-Be $state.OverlayCalls 0
        Should-Be $state.Notices.Count 1
        Should-BeTrue ($state.Notices[0] -match 'display configuration changed')
    }

    It 'exposes the required overlay interfaces and test seams' {
        foreach ($name in 'Get-SnipMonitorLayouts','Get-SnipOverlayIntersections',
            'New-SnipOverlayContext','New-SnipOverlayWindow','Invoke-SnipOverlayRenderTick') {
            Should-BeTrue ($null -ne (Get-Command $name -ErrorAction SilentlyContinue))
        }
        $parameters = (Get-Command Show-SmartOverlay).Parameters
        Should-BeTrue $parameters.ContainsKey('Services')
        Should-BeTrue $parameters.ContainsKey('TestAction')
    }

    It 'creates one registered HWND per monitor around one shared frozen session' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Context=$null; Overlays=$null }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $observed.Context = $kit.Context
            $observed.Overlays = @($kit.Overlays)
            Should-Be $observed.Overlays.Count 2
            foreach ($overlay in $observed.Overlays) {
                Should-BeTrue ([object]::ReferenceEquals($overlay.Context, $kit.Context))
                Should-BeTrue $overlay.Lifecycle.Connected
            }
            & $kit.Cancel
        }.GetNewClosure()

        Should-Be $result.Result 'UserCancelled'
        Should-Be $result.Selection $null
        Should-Be $result.Bitmap $null
        Should-Be $fixture.State.SnapshotCount 1
        Should-Be $fixture.State.ConvertCount 1
        Should-Be $fixture.State.Snapshot.DisposeCount 1
        Should-Be $fixture.State.RegisterHandles.Count 2
        Should-Be $fixture.State.UnregisterHandles.Count 2
        Should-Be $fixture.State.RenderingAdds.Count 1
        Should-Be $fixture.State.RenderingRemoves.Count 1
        Should-BeFalse $observed.Context.RenderingAttached
    }

    It 'coalesces raw pointer events to one render tick and refreshes the hovered HWND bounds' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $observed = @{ Context=$null; Overlay=$null; FirstWidth=0; SecondWidth=0 }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $observed.Context = $kit.Context
            $observed.Overlay = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'primary-100' })[0]
            & $kit.QueuePointer $observed.Overlay
            & $kit.QueuePointer $observed.Overlay
            & $kit.QueuePointer $observed.Overlay
            Should-Be $kit.Context.RenderCount 0
            & $kit.RenderTick
            $observed.FirstWidth = $observed.Overlay.RenderedHover.PhysicalWidth
            & $kit.RenderTick
            Should-Be $kit.Context.RenderCount 1
            $fixture.State.HoverWidth = 650
            & $kit.QueuePointer $observed.Overlay
            & $kit.RenderTick
            $observed.SecondWidth = $observed.Overlay.RenderedHover.PhysicalWidth
            & $kit.Cancel
        }.GetNewClosure()

        Should-Be $result.Result 'UserCancelled'
        Should-Be $fixture.State.RenderingAdds.Count 1
        Should-Be $observed.Context.RenderCount 2
        # The hovered window starts on the 125% monitor, so this overlay owns
        # only the half-open primary-monitor intersection of each refreshed bound.
        Should-Be $observed.FirstWidth 200
        Should-Be $observed.SecondWidth 450
        Should-Be $fixture.State.WindowAtPointCount 2
        Should-Be $fixture.State.WindowBoundsCount 2
    }

    It 'unions the live own-window registry with overlay HWNDs on every hover resolution' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $fixture.State.CursorY = 100
        $fixture.State.ExternalHwnd = [IntPtr]4242
        $seenOwnSets = [System.Collections.ArrayList]::new()
        $fixture.Services.GetWindowAtPoint = {
            param($point,$ownHandles)
            $ownValues = @($ownHandles | ForEach-Object { ([IntPtr]$_).ToInt64() })
            [void]$seenOwnSets.Add(@($ownValues))
            foreach ($candidate in @(
                [IntPtr]$fixture.State.RegisterHandles[0],
                [IntPtr]$fixture.State.RegistryTopHwnd,
                [IntPtr]$fixture.State.ExternalHwnd
            )) {
                if ($candidate.ToInt64() -notin $ownValues) { return $candidate }
            }
            [IntPtr]::Zero
        }.GetNewClosure()
        $observed = @{ First=[IntPtr]::Zero; Second=[IntPtr]::Zero }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $primary = @($kit.Overlays | Where-Object {
                $_.Layout.Id -eq 'primary-100'
            })[0]
            $fixture.State.OwnRegistryHandles = @(
                [IntPtr]$fixture.State.RegisterHandles[0],
                [IntPtr]777,
                [IntPtr]777
            )
            $fixture.State.RegistryTopHwnd = [IntPtr]777
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            $observed.First = $kit.Context.HoverHwnd

            # A scalar replacement proves the registry is read live rather
            # than captured once, and remains one handle in the union.
            $fixture.State.OwnRegistryHandles = [IntPtr]888
            $fixture.State.RegistryTopHwnd = [IntPtr]888
            $fixture.State.ExternalHwnd = [IntPtr]5252
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            $observed.Second = $kit.Context.HoverHwnd
            & $kit.Cancel
        }.GetNewClosure()

        Should-Be $result.Result 'UserCancelled'
        Should-Be $observed.First ([IntPtr]4242)
        Should-Be $observed.Second ([IntPtr]5252)
        Should-Be $fixture.State.OwnRegistryReads 2
        Should-Be $seenOwnSets.Count 2
        Should-Be @($seenOwnSets[0] | Sort-Object -Unique).Count 3
        Should-BeTrue ($seenOwnSets[0] -contains 777)
        Should-BeFalse ($seenOwnSets[1] -contains 777)
        Should-BeTrue ($seenOwnSets[1] -contains 888)
        foreach ($registered in $fixture.State.RegisterHandles) {
            Should-BeTrue ($seenOwnSets[0] -contains $registered)
            Should-BeTrue ($seenOwnSets[1] -contains $registered)
        }
    }

    It 'commits the last refreshed hovered window on a physical click' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $fixture.State.CursorY = 100
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $primary = @($kit.Overlays | Where-Object {
                $_.Layout.Id -eq 'primary-100'
            })[0]
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            & $kit.BeginDrag $primary
            & $kit.CompleteDrag
        }.GetNewClosure()

        Should-Be $result.Result 'Completed'
        Should-Be $result.Selection.X -200
        Should-Be $result.Selection.Y 40
        Should-Be $result.Selection.Width 400
        Should-Be $result.Selection.Height 300
    }

    It 'flushes a queued hover change synchronously before a fast click commits' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $fixture.State.CursorY = 100
        $target = @{
            Hwnd = [IntPtr]4100
            Bounds = [pscustomobject]@{ X=-200; Y=40; Width=400; Height=300 }
        }
        $fixture.Services.GetWindowAtPoint = {
            param($point,$ownHandles)
            $target.Hwnd
        }.GetNewClosure()
        $fixture.Services.GetWindowBounds = {
            param($hwnd)
            $target.Bounds
        }.GetNewClosure()
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $primary = @($kit.Overlays | Where-Object {
                $_.Layout.Id -eq 'primary-100'
            })[0]
            & $kit.QueuePointer $primary
            & $kit.RenderTick

            $target.Hwnd = [IntPtr]4200
            $target.Bounds = [pscustomobject]@{
                X=40; Y=60; Width=640; Height=360
            }
            & $kit.QueuePointer $primary
            # Mouse-down/up happens before CompositionTarget.Rendering.
            & $kit.BeginDrag $primary
            & $kit.CompleteDrag
        }.GetNewClosure()

        Should-Be $result.Result 'Completed'
        Should-Be $result.Selection.X 40
        Should-Be $result.Selection.Y 60
        Should-Be $result.Selection.Width 640
        Should-Be $result.Selection.Height 360
    }

    It 'shares one physical drag across windows and uses cursor position while captured' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Parts=$null; Selection=$null }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $left = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'left-125' })[0]
            $primary = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'primary-100' })[0]
            $fixture.State.CursorX = -500
            $fixture.State.CursorY = 100
            & $kit.BeginDrag $left
            $fixture.State.CursorX = 500
            $fixture.State.CursorY = 600
            & $kit.QueuePointer $primary
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            $observed.Selection = $kit.Context.Selection
            $observed.Parts = @($kit.Overlays | ForEach-Object RenderedSelection |
                Where-Object { $null -ne $_ })
            & $kit.CompleteDrag
        }.GetNewClosure()

        Should-Be $result.Result 'Completed'
        Should-Be $result.Bitmap $null
        Should-Be $result.Selection.X -500
        Should-Be $result.Selection.Y 100
        Should-Be $result.Selection.Width 1000
        Should-Be $result.Selection.Height 500
        Should-Be $observed.Selection.Width 1000
        Should-Be $observed.Parts.Count 2
        Should-Be (($observed.Parts | Measure-Object PhysicalWidth -Sum).Sum) 1000
        Should-BeTrue ($fixture.State.CursorCount -ge 3)
    }

    It 'clamps the loupe inside every monitor at all four physical edges' {
        $fixture = New-SnipOverlayTestFixture
        $checks = [System.Collections.ArrayList]::new()
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            foreach ($overlay in $kit.Overlays) {
                $layout = $overlay.Layout
                foreach ($point in @(
                    @($layout.PhysicalX, $layout.PhysicalY),
                    @(($layout.PhysicalX + $layout.PhysicalWidth - 1), $layout.PhysicalY),
                    @($layout.PhysicalX, ($layout.PhysicalY + $layout.PhysicalHeight - 1)),
                    @(($layout.PhysicalX + $layout.PhysicalWidth - 1),
                        ($layout.PhysicalY + $layout.PhysicalHeight - 1))
                )) {
                    $fixture.State.CursorX = $point[0]
                    $fixture.State.CursorY = $point[1]
                    & $kit.QueuePointer $overlay
                    & $kit.RenderTick
                    $bounds = $overlay.LoupeBounds
                    [void]$checks.Add([pscustomobject]@{
                        LeftOk = $bounds.X -ge $layout.PhysicalX
                        TopOk = $bounds.Y -ge $layout.PhysicalY
                        RightOk = ($bounds.X + $bounds.Width) -le
                            ($layout.PhysicalX + $layout.PhysicalWidth)
                        BottomOk = ($bounds.Y + $bounds.Height) -le
                            ($layout.PhysicalY + $layout.PhysicalHeight)
                    })
                }
            }
            & $kit.Cancel
        }.GetNewClosure()

        Should-Be $result.Result 'UserCancelled'
        Should-Be $checks.Count 8
        foreach ($check in $checks) {
            Should-BeTrue $check.LeftOk
            Should-BeTrue $check.TopOk
            Should-BeTrue $check.RightOk
            Should-BeTrue $check.BottomOk
        }
    }

    It 'moves the loupe away from the active physical selection when space exists' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Selection=$null; Loupe=$null }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $primary = @($kit.Overlays | Where-Object {
                $_.Layout.Id -eq 'primary-100'
            })[0]
            $fixture.State.CursorX = 1000
            $fixture.State.CursorY = 800
            & $kit.BeginDrag $primary
            $fixture.State.CursorX = 500
            $fixture.State.CursorY = 500
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            $observed.Selection = $kit.Context.Selection
            $observed.Loupe = $primary.LoupeBounds
            & $kit.Cancel
        }.GetNewClosure()

        $overlapWidth = [math]::Min(
            $observed.Selection.X + $observed.Selection.Width,
            $observed.Loupe.X + $observed.Loupe.Width) - [math]::Max(
                $observed.Selection.X, $observed.Loupe.X)
        $overlapHeight = [math]::Min(
            $observed.Selection.Y + $observed.Selection.Height,
            $observed.Loupe.Y + $observed.Loupe.Height) - [math]::Max(
                $observed.Selection.Y, $observed.Loupe.Y)
        Should-Be $result.Result 'UserCancelled'
        Should-BeTrue ($overlapWidth -le 0 -or $overlapHeight -le 0)
    }

    It 'magnifies the loupe patch with crisp nearest-neighbour pixels' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Overlay=$null; Source=$null }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $primary = @($kit.Overlays | Where-Object {
                $_.Layout.Id -eq 'primary-100'
            })[0]
            $fixture.State.CursorX = 900
            $fixture.State.CursorY = 600
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            $observed.Overlay = $primary
            $observed.Source = $primary.LoupeImage.Source
            & $kit.Cancel
        }.GetNewClosure()

        Should-Be $result.Result 'UserCancelled'
        $image = $observed.Overlay.LoupeImage
        # Stretch="None" would centre the raw patch in the viewport at 1:1 —
        # a loupe that does not magnify. Fill + NearestNeighbor is the fix.
        Should-Be ([string]$image.Stretch) 'Fill'
        Should-Be ([string][System.Windows.Media.RenderOptions]::GetBitmapScalingMode($image)) 'NearestNeighbor'
        Should-BeTrue ($observed.Source -is [System.Windows.Media.Imaging.CroppedBitmap])
        $magnification = Get-LoupeMagnification
        Should-BeTrue $magnification.IsIntegral
        Should-BeTrue $magnification.IsCentred
        Should-Be ($observed.Source.PixelWidth % 2) 1
        Should-Be $observed.Source.PixelWidth $observed.Source.PixelHeight
        Should-Be $image.Width ($observed.Source.PixelWidth * $magnification.Factor)
        Should-Be $image.Height ($observed.Source.PixelHeight * $magnification.Factor)
        # The image must fit its clipping Border exactly, or the crosshair at
        # the Border's centre no longer marks the centre source pixel.
        $viewport = $image.Parent.Parent
        Should-Be ($viewport.Width - $viewport.BorderThickness.Left -
            $viewport.BorderThickness.Right) $image.Width
        # Crosshair and centre-cell marker are painted after the image.
        $grid = $image.Parent
        Should-Be $grid.Children.IndexOf($image) 0
        Should-Be $grid.Children.Count 4
    }

    It 'dims to forty percent and takes its marquee chrome from the Fluent accent' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Overlay=$null }
        Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $observed.Overlay = $kit.Overlays[0]
            & $kit.Cancel
        }.GetNewClosure() | Out-Null

        $overlay = $observed.Overlay
        Should-Be $overlay.Dimmer.Fill.Color.A 102
        # Both marquees resolve the stock Fluent accent, so they follow the
        # Windows accent colour instead of a hex this repo picked.
        $accent = $overlay.Window.TryFindResource('AccentFillColorDefaultBrush')
        if ($null -ne $accent) {
            foreach ($marquee in @($overlay.HoverRect, $overlay.DragRect)) {
                Should-BeTrue ($marquee.Stroke -is [System.Windows.Media.SolidColorBrush])
                Should-Be $marquee.Stroke.Color.ToString() $accent.Color.ToString()
            }
        }
        # Banner, size chip and loupe are plain Fluent Borders now: rounded,
        # themed surface, themed stroke, and no glass sublayers at all.
        foreach ($border in @($overlay.HintBorder, $overlay.LoupeBorder)) {
            Should-BeTrue ($border -is [System.Windows.Controls.Border])
            Should-BeTrue ($border.CornerRadius.TopLeft -gt 0)
            Should-BeTrue ($border.Background -is [System.Windows.Media.SolidColorBrush])
            Should-BeTrue ($border.BorderBrush -is [System.Windows.Media.Brush])
        }
        Should-BeTrue ($overlay.HintText -is [System.Windows.Controls.TextBlock])
        foreach ($retiredName in 'LoupeInnerHighlight','HintInnerHighlight',
                'SizeChipInnerHighlight') {
            Should-Be ($overlay.Window.FindName($retiredName)) $null
        }
        $body = (Get-Command New-SnipOverlayWindow).ScriptBlock.ToString()
        Should-BeFalse ($body -match '(?i)#(?:00)?78D4|cyan')
        Should-BeFalse ($body -match 'Snip[A-Za-z]*Brush')
    }

    # Show-SmartOverlaySet turns anything a TestAction throws into Result='Failed'
    # with the record attached, which would otherwise hide an assertion failure
    # behind an unhelpful 'expected UserCancelled'.
    function Assert-SnipOverlayCancelled {
        param($Result)

        if ($Result.Result -ne 'UserCancelled' -and $null -ne $Result.ErrorRecord) {
            throw $Result.ErrorRecord.Exception
        }
        Should-Be $Result.Result 'UserCancelled'
    }

    # Drives a drag from (-500,100) on the 125% left monitor to (200,400) on the
    # 100% primary, so the selection crosses the seam at x=0 and both overlays
    # own a piece of it. Returns the two overlays plus the kit for assertions.
    function Invoke-SnipSeamDrag {
        param($Fixture, [scriptblock]$Assert)

        $Fixture.State.CursorX = -500
        $Fixture.State.CursorY = 100
        $result = Show-SmartOverlay -Services $Fixture.Services -TestAction {
            param($kit)
            $left = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'left-125' })[0]
            $primary = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'primary-100' })[0]
            & $kit.QueuePointer $left
            & $kit.RenderTick
            & $kit.BeginDrag $left
            $Fixture.State.CursorX = 200
            $Fixture.State.CursorY = 400
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            & $Assert $kit $left $primary
            & $kit.Cancel
        }.GetNewClosure()
        Assert-SnipOverlayCancelled -Result $result
    }

    It 'shows the live size chip on the overlay under the pointer and nowhere else' {
        $fixture = New-SnipOverlayTestFixture
        Invoke-SnipSeamDrag -Fixture $fixture -Assert {
            param($kit, $left, $primary)
            # The drag rectangle straddles the seam, so both overlays draw a
            # piece of it...
            Should-Be $left.DragRect.Visibility 'Visible'
            Should-Be $primary.DragRect.Visibility 'Visible'
            # ...but only the overlay holding the corner the pointer is dragging
            # gets the readout, and it reports the whole selection rather than
            # the part on that monitor.
            Should-Be $primary.SizeChip.Visibility 'Visible'
            Should-Be $left.SizeChip.Visibility 'Collapsed'
            Should-Be $primary.SizeChipText.Text '700 × 300 px'
            Should-BeTrue ($null -ne $primary.RenderedChipPlacement)
            Should-Be $left.RenderedChipPlacement $null
            # The static instruction banner is gone for the duration of the drag.
            Should-Be $left.HintBorder.Visibility 'Collapsed'
            Should-Be $primary.HintBorder.Visibility 'Collapsed'
        }
    }

    It 'anchors the size chip to the drag rectangle inside the owning monitor' {
        $fixture = New-SnipOverlayTestFixture
        Invoke-SnipSeamDrag -Fixture $fixture -Assert {
            param($kit, $left, $primary)
            $part = $primary.RenderedSelection
            $placement = $primary.RenderedChipPlacement
            $chipWidth = $primary.SizeChip.DesiredSize.Width
            $chipHeight = $primary.SizeChip.DesiredSize.Height
            Should-BeTrue ($chipWidth -gt 0)
            # Right-aligned to the rectangle, just below it, and fully on-screen.
            Should-Be $placement.Edge 'Below'
            Should-Be ([math]::Round($placement.X, 3)) `
                ([math]::Round([math]::Max(0, $part.DipX + $part.DipWidth - $chipWidth), 3))
            Should-Be ([math]::Round($placement.Y, 3)) `
                ([math]::Round($part.DipY + $part.DipHeight + 8, 3))
            Should-BeTrue ($placement.X -ge 0)
            Should-BeTrue (($placement.X + $chipWidth) -le $primary.Layout.DipWidth)
            Should-BeTrue (($placement.Y + $chipHeight) -le $primary.Layout.DipHeight)
            Should-Be ([System.Windows.Controls.Canvas]::GetLeft($primary.SizeChip)) $placement.X
            Should-Be ([System.Windows.Controls.Canvas]::GetTop($primary.SizeChip)) $placement.Y
        }
    }

    It 'cuts the selection out of the dimmer on every overlay it crosses' {
        $fixture = New-SnipOverlayTestFixture
        Invoke-SnipSeamDrag -Fixture $fixture -Assert {
            param($kit, $left, $primary)
            foreach ($overlay in @($left, $primary)) {
                $clip = $overlay.Dimmer.Clip
                Should-BeTrue ($clip -is [System.Windows.Media.CombinedGeometry])
                Should-Be $clip.GeometryCombineMode 'Exclude'
                # Geometry1 is the whole monitor, Geometry2 the undimmed hole.
                Should-Be $clip.Geometry1.Rect.Width $overlay.Layout.DipWidth
                Should-Be $clip.Geometry1.Rect.Height $overlay.Layout.DipHeight
                $part = $overlay.RenderedSelection
                Should-BeTrue ($null -ne $part)
                Should-Be $clip.Geometry2.Rect.X $part.DipX
                Should-Be $clip.Geometry2.Rect.Y $part.DipY
                Should-Be $clip.Geometry2.Rect.Width $part.DipWidth
                Should-Be $clip.Geometry2.Rect.Height $part.DipHeight
            }
            # The seam is genuinely crossed: the left monitor's hole runs to its
            # right edge and the primary's starts at its left edge.
            Should-Be ($left.Dimmer.Clip.Geometry2.Rect.X +
                $left.Dimmer.Clip.Geometry2.Rect.Width) $left.Layout.DipWidth
            Should-Be $primary.Dimmer.Clip.Geometry2.Rect.X 0
            # And the monitor the pointer is on stays lighter than the others.
            Should-Be $primary.Dimmer.Fill.Color.A 102
            Should-Be $left.Dimmer.Fill.Color.A 128
        }
    }

    It 'clears the dimmer cut-out on an overlay the selection has left' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $fixture.State.CursorY = 100
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $left = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'left-125' })[0]
            $primary = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'primary-100' })[0]
            & $kit.BeginDrag $primary
            $fixture.State.CursorX = 600
            $fixture.State.CursorY = 500
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            Should-BeTrue ($primary.Dimmer.Clip -is [System.Windows.Media.CombinedGeometry])
            Should-Be $left.Dimmer.Clip $null
            Should-Be $left.SizeChip.Visibility 'Collapsed'
            Should-Be $primary.SizeChip.Visibility 'Visible'
            & $kit.Cancel
        }.GetNewClosure()

        Assert-SnipOverlayCancelled -Result $result
    }

    It 'keeps the instruction banner on the pointer monitor only before a drag' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $fixture.State.CursorY = 100
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $left = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'left-125' })[0]
            $primary = @($kit.Overlays | Where-Object { $_.Layout.Id -eq 'primary-100' })[0]
            & $kit.QueuePointer $primary
            & $kit.RenderTick
            Should-Be $primary.HintBorder.Visibility 'Visible'
            Should-Be $left.HintBorder.Visibility 'Collapsed'
            Should-Be $primary.SizeChip.Visibility 'Collapsed'

            $fixture.State.CursorX = -800
            & $kit.QueuePointer $left
            & $kit.RenderTick
            Should-Be $left.HintBorder.Visibility 'Visible'
            Should-Be $primary.HintBorder.Visibility 'Collapsed'
            & $kit.Cancel
        }.GetNewClosure()

        Assert-SnipOverlayCancelled -Result $result
    }

    It 'self-cancels an idle overlay set that has lost the foreground' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Context=$null }
        $result = Show-SmartOverlay -Services $fixture.Services `
            -IdleTimeout ([timespan]::FromMilliseconds(50)) -TestAction {
                param($kit)
                $observed.Context = $kit.Context
                # Nothing has touched the overlay for longer than the timeout,
                # and $state.ForegroundHwnd is zero, so no overlay owns focus.
                $kit.Context.LastInputUtc = [datetime]::UtcNow.AddSeconds(-5)
                & $kit.RenderTick
            }.GetNewClosure()

        Assert-SnipOverlayCancelled -Result $result
        Should-BeTrue $observed.Context.IdleCancelled
        Should-BeTrue $observed.Context.Closing
        Should-Be $fixture.State.Diagnostics.Count 1
        Should-BeTrue ($fixture.State.Diagnostics[0] -match 'self-cancelled')
        Should-Be $fixture.State.Snapshot.DisposeCount 1
        Should-Be $fixture.State.RenderingRemoves.Count 1
    }

    It 'leaves an idle overlay alone while one of its windows holds the foreground' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Context=$null }
        $result = Show-SmartOverlay -Services $fixture.Services `
            -IdleTimeout ([timespan]::FromMilliseconds(50)) -TestAction {
                param($kit)
                $observed.Context = $kit.Context
                $fixture.State.ForegroundHwnd = [IntPtr]$kit.Overlays[0].Lifecycle.Handle
                $kit.Context.LastInputUtc = [datetime]::UtcNow.AddSeconds(-5)
                & $kit.RenderTick
                Should-BeFalse $kit.Context.Closing
                & $kit.Cancel
            }.GetNewClosure()

        Assert-SnipOverlayCancelled -Result $result
        Should-BeFalse $observed.Context.IdleCancelled
        Should-Be $fixture.State.Diagnostics.Count 0
    }

    It 'does not abandon a drag that is under way but momentarily still' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.State.CursorX = 100
        $fixture.State.CursorY = 100
        $observed = @{ Context=$null }
        $result = Show-SmartOverlay -Services $fixture.Services `
            -IdleTimeout ([timespan]::FromMilliseconds(50)) -TestAction {
                param($kit)
                $observed.Context = $kit.Context
                $primary = @($kit.Overlays | Where-Object {
                    $_.Layout.Id -eq 'primary-100'
                })[0]
                & $kit.BeginDrag $primary
                $kit.Context.LastInputUtc = [datetime]::UtcNow.AddSeconds(-5)
                & $kit.RenderTick
                Should-BeFalse $kit.Context.Closing
                & $kit.Cancel
            }.GetNewClosure()

        Assert-SnipOverlayCancelled -Result $result
        Should-BeFalse $observed.Context.IdleCancelled
        Should-Be $fixture.State.Diagnostics.Count 0
    }

    It 'refreshes the idle clock on pointer and drag input' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Before=$null; After=$null }
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $primary = @($kit.Overlays | Where-Object {
                $_.Layout.Id -eq 'primary-100'
            })[0]
            $kit.Context.LastInputUtc = [datetime]::UtcNow.AddHours(-1)
            $observed.Before = $kit.Context.LastInputUtc
            & $kit.QueuePointer $primary
            $observed.After = $kit.Context.LastInputUtc
            & $kit.Cancel
        }.GetNewClosure()

        Assert-SnipOverlayCancelled -Result $result
        Should-BeTrue ($observed.After -gt $observed.Before)
    }

    It 'uses system overlay fills and no shadow in High Contrast' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.Services.HighContrast = $true
        $observed = @{ Overlay=$null }
        Show-SmartOverlay -Services $fixture.Services -TestAction {
            param($kit)
            $observed.Overlay = $kit.Overlays[0]
            & $kit.Cancel
        }.GetNewClosure() | Out-Null

        Should-BeTrue ([object]::ReferenceEquals(
            $observed.Overlay.Dimmer.Fill,
            [System.Windows.SystemColors]::WindowBrush))
        Should-BeTrue ([object]::ReferenceEquals(
            $observed.Overlay.DragRect.Fill,
            [System.Windows.SystemColors]::HighlightBrush))
        Should-Be $observed.Overlay.HintBorder.Effect $null
        Should-Be $observed.Overlay.LoupeBorder.Effect $null
    }

    It 'detaches rendering closes windows and disposes the snapshot for every surface result' {
        foreach ($surfaceResult in 'Completed','UserCancelled','Preempted','Failed','Shutdown') {
            $fixture = New-SnipOverlayTestFixture
            $observed = @{ Context=$null; Overlays=$null }
            $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
                param($kit)
                $observed.Context = $kit.Context
                $observed.Overlays = @($kit.Overlays)
                if ($surfaceResult -eq 'Completed') {
                    $kit.Context.Selection = [pscustomobject][ordered]@{
                        X=-20; Y=10; Width=40; Height=30
                    }
                }
                & $kit.Close $surfaceResult
            }.GetNewClosure()

            Should-Be $result.Result $surfaceResult
            Should-Be $fixture.State.RenderingAdds.Count 1
            Should-Be $fixture.State.RenderingRemoves.Count 1
            Should-Be $fixture.State.RegisterHandles.Count 2
            Should-Be $fixture.State.UnregisterHandles.Count 2
            Should-Be $fixture.State.Snapshot.DisposeCount 1
            Should-BeFalse $observed.Context.RenderingAttached
            foreach ($overlay in $observed.Overlays) {
                Should-BeFalse $overlay.Window.IsVisible
                Should-BeFalse $overlay.EventsAttached
                Should-BeFalse $overlay.Lifecycle.Connected
            }
        }
    }

    It 'closes and detaches a readiness-declined overlay set before any HWND is shown' {
        $fixture = New-SnipOverlayTestFixture
        $observed = @{ Context=$null; Overlays=$null }
        $result = Show-SmartOverlay -Services $fixture.Services -OnSurfaceReady {
            param($surface)
            $observed.Context = $surface.Context
            $observed.Overlays = @($surface.Context.Overlays)
            & $surface.Close 'Preempted'
            $false
        }.GetNewClosure()

        Should-Be $result.Result 'Preempted'
        Should-Be $fixture.State.RenderingAdds.Count 0
        Should-Be $fixture.State.RenderingRemoves.Count 0
        Should-Be $fixture.State.RegisterHandles.Count 0
        Should-Be $fixture.State.UnregisterHandles.Count 0
        Should-Be $fixture.State.Snapshot.DisposeCount 1
        foreach ($overlay in $observed.Overlays) {
            Should-BeTrue $overlay.Closed
            Should-BeFalse $overlay.EventsAttached
            Should-BeFalse $overlay.Lifecycle.Connected
        }
    }

    It 'detaches a partially attached render delegate when subscription reports failure' {
        $fixture = New-SnipOverlayTestFixture
        $fixture.Services.AddRenderingHandler = {
            param($handler)
            [void]$fixture.State.RenderingAdds.Add($handler)
            throw 'render subscription failed after attach'
        }.GetNewClosure()
        $result = Show-SmartOverlay -Services $fixture.Services -TestAction {
            throw 'test action must not run'
        }

        Should-Be $result.Result 'Failed'
        Should-Be $fixture.State.RenderingAdds.Count 1
        Should-Be $fixture.State.RenderingRemoves.Count 1
        Should-Be $fixture.State.Snapshot.DisposeCount 1
    }

    It 'fails and cleans the complete overlay set when physical HWND positioning fails' {
        foreach ($failureMode in 'False','Throw') {
            $fixture = New-SnipOverlayTestFixture
            $fixture.State.TestActionRuns = 0
            $observed = @{ Context=$null; Overlays=$null }
            $fixture.Services.PositionWindow = {
                param($hwnd,$layout)
                $fixture.State.PositionCalls++
                if ($failureMode -eq 'Throw') { throw 'native position exploded' }
                $false
            }.GetNewClosure()
            $result = Show-SmartOverlay -Services $fixture.Services `
                -OnSurfaceReady {
                    param($surface)
                    $observed.Context = $surface.Context
                    $observed.Overlays = @($surface.Context.Overlays)
                    $true
                }.GetNewClosure() `
                -TestAction {
                    param($kit)
                    $fixture.State.TestActionRuns++
                    & $kit.Cancel
                }.GetNewClosure()

            Should-Be $result.Result 'Failed'
            Should-Be $fixture.State.PositionCalls 1
            Should-Be $fixture.State.TestActionRuns 0
            Should-BeTrue ($result.ErrorRecord.Exception.Message -match
                'SetWindowPos.*left-125')
            Should-Be $fixture.State.RenderingAdds.Count 1
            Should-Be $fixture.State.RenderingRemoves.Count 1
            Should-Be $fixture.State.Snapshot.DisposeCount 1
            Should-BeGreaterThan $fixture.State.RegisterHandles.Count 0
            Should-Be $fixture.State.UnregisterHandles.Count `
                $fixture.State.RegisterHandles.Count
            foreach ($overlay in $observed.Overlays) {
                Should-BeTrue $overlay.Closed
                Should-BeFalse $overlay.EventsAttached
                Should-BeFalse $overlay.Lifecycle.Connected
            }
        }
    }

    It 'lets the runtime coordinator create the Smart crop from returned geometry' {
        $selection = [pscustomobject][ordered]@{ X=-500; Y=100; Width=1000; Height=500 }
        $state = @{ Seen=$null; Hide=0; Restore=0; Crop=$null }
        $overlay = {
            param($ready,$coordinator,$request)
            & $ready ([pscustomobject]@{ Close={ param($result) } }) | Out-Null
            [pscustomobject][ordered]@{
                Result='Completed'; Selection=$selection; Bitmap=$null; ErrorRecord=$null
            }
        }.GetNewClosure()
        $services = New-SnipRuntimeCaptureServices -SmartOverlay $overlay `
            -HideWindows { $state.Hide++; @() }.GetNewClosure() `
            -RestoreWindows { param($hidden) $state.Restore++ }.GetNewClosure() `
            -CaptureRectangle {
                param($bounds)
                $state.Seen = $bounds
                $state.Crop = New-OwnershipProbe -Id smart-crop
                $state.Crop
            }.GetNewClosure()
        $request = New-SnipCaptureRequest -Mode Smart -Source GeometryOnly
        $coordinator = New-SnipCaptureCoordinator -Services $services
        $coordinator.ActiveRequest = $request
        $coordinator.Phase = 'CaptureStarting'

        $result = & $services.SmartCapture $coordinator $request

        Should-BeTrue ([object]::ReferenceEquals($result, $state.Crop))
        Should-Be $state.Seen.X -500
        Should-Be $state.Seen.Y 100
        Should-Be $state.Seen.Width 1000
        Should-Be $state.Seen.Height 500
        Should-Be $state.Hide 1
        Should-Be $state.Restore 1
        $state.Crop.Dispose()
    }

    It 'rejects malformed or zero-area Smart geometry without creating a crop' {
        foreach ($selection in @(
            [pscustomobject]@{ X=0; Y=0; Width=0; Height=20 },
            [pscustomobject]@{ X=0; Y=0; Width=20 }
        )) {
            $state = @{ Crop=0 }
            $overlay = {
                param($ready,$coordinator,$request)
                & $ready ([pscustomobject]@{ Close={ param($result) } }) | Out-Null
                [pscustomobject]@{ Result='Completed'; Selection=$selection; Bitmap=$null }
            }.GetNewClosure()
            $services = New-SnipRuntimeCaptureServices -SmartOverlay $overlay `
                -CaptureRectangle { param($bounds) $state.Crop++; throw 'must not crop' }.GetNewClosure()
            $request = New-SnipCaptureRequest -Mode Smart -Source InvalidGeometry
            $coordinator = New-SnipCaptureCoordinator -Services $services
            $coordinator.ActiveRequest = $request
            $coordinator.Phase = 'CaptureStarting'

            $result = & $services.SmartCapture $coordinator $request

            Should-Be $result.Result 'UserCancelled'
            Should-Be $state.Crop 0
        }
    }
}

Describe 'Preview ownership transfer' {
    It 'transfers only after Preview accepts and leaves disposal to Preview' {
        $capture = New-OwnershipProbe -Id accepted
        $result = Invoke-SnipPreviewTransfer -Bitmap $capture -Preview {
            param($bitmap,$accept)
            $bitmap.Touch()
            & $accept
            $bitmap.Touch()
            'Completed'
        }

        Should-BeTrue $result.OwnershipTransferred
        Should-Be $result.Result 'Completed'
        Should-Be $capture.DisposeCount 0
        Should-Be $capture.TouchCount 2
    }

    It 'disposes once when Preview fails before acceptance' {
        $capture = New-OwnershipProbe -Id before-accept
        $result = Invoke-SnipPreviewTransfer -Bitmap $capture -Preview {
            param($bitmap,$accept)
            $bitmap.Touch()
            throw 'construction failed'
        }

        Should-BeFalse $result.OwnershipTransferred
        Should-Be $result.Result 'Failed'
        Should-Be $capture.DisposeCount 1
    }

    It 'does not coordinator-dispose when Preview fails after acceptance' {
        $capture = New-OwnershipProbe -Id after-accept
        $result = Invoke-SnipPreviewTransfer -Bitmap $capture -Preview {
            param($bitmap,$accept)
            & $accept
            try {
                $bitmap.Touch()
                throw 'opening failed'
            } finally {
                $bitmap.Dispose()
            }
        }

        Should-BeTrue $result.OwnershipTransferred
        Should-Be $result.Result 'Failed'
        Should-Be $capture.DisposeCount 1
        Should-Be $capture.TouchCount 1
    }

    It 'disposes every unaccepted taxonomy result exactly once' {
        foreach ($surfaceResult in 'Completed','UserCancelled','Preempted','Failed','Shutdown') {
            $capture = New-OwnershipProbe -Id $surfaceResult
            $result = Invoke-SnipPreviewTransfer -Bitmap $capture -Preview {
                param($bitmap,$accept)
                $bitmap.Touch()
                $surfaceResult
            }.GetNewClosure()
            Should-Be $result.Result $surfaceResult
            Should-BeFalse $result.OwnershipTransferred
            Should-Be $capture.DisposeCount 1
        }
    }

    It 'survives 100 accepted real bitmaps and strict probes without reuse or double disposal' {
        $realBitmaps = [System.Collections.ArrayList]::new()
        $probes = [System.Collections.ArrayList]::new()
        for ($iteration = 1; $iteration -le 100; $iteration++) {
            $bitmap = [System.Drawing.Bitmap]::new(8, 8)
            foreach ($prior in $realBitmaps) {
                Should-BeFalse ([object]::ReferenceEquals($bitmap, $prior))
            }
            [void]$realBitmaps.Add($bitmap)
            $realResult = Invoke-SnipPreviewTransfer -Bitmap $bitmap -Preview {
                param($owned,$accept)
                & $accept
                try {
                    $owned.SetPixel(0, 0, [System.Drawing.Color]::FromArgb(255, 1, 2, 3))
                    $pixel = $owned.GetPixel(0, 0)
                    Should-Be $pixel.R 1
                } finally {
                    $owned.Dispose()
                }
                'UserCancelled'
            }
            Should-BeTrue $realResult.OwnershipTransferred
            Should-Be $realResult.Result 'UserCancelled'

            $probe = New-OwnershipProbe -Id "iteration-$iteration"
            [void]$probes.Add($probe)
            $probeResult = Invoke-SnipPreviewTransfer -Bitmap $probe -Preview {
                param($owned,$accept)
                & $accept
                try { $owned.Touch() } finally { $owned.Dispose() }
                'Completed'
            }
            Should-BeTrue $probeResult.OwnershipTransferred
            Should-Be $probe.DisposeCount 1
        }
        Should-Be $realBitmaps.Count 100
        Should-Be $probes.Count 100
        Should-Be (@($probes | Where-Object DisposeCount -ne 1).Count) 0
    }

    It 'calls ownership acceptance only after Preview installs Closed cleanup' {
        $bitmap = [System.Drawing.Bitmap]::new(16, 16)
        $acceptance = @{ Accepted = $false }
        $result = Show-PreviewWindow -Bitmap $bitmap -OnOwnershipAccepted {
            param($ownershipState)
            Should-BeTrue $ownershipState.CleanupInstalled
            $acceptance.Accepted = $true
        }.GetNewClosure() -TestAction {
            param($kit)
            Should-BeTrue $acceptance.Accepted
        }.GetNewClosure()

        Should-BeTrue $acceptance.Accepted
        Should-Be $result 'UserCancelled'
    }
}

Describe 'Injected coordinator surface integration' {
    It 'relinquishes coordinator ownership before Stop can race accepted Preview cleanup' {
        $state = @{
            Capture = $null
            TouchAfterStop = $false
            Error = $null
            OwnedAfterAccept = $null
        }
        $services = [pscustomobject]@{
            FullCapture = {
                param($coordinator,$request)
                $state.Capture = New-OwnershipProbe -Id shutdown-race
                $state.Capture
            }.GetNewClosure()
            Preview = {
                param($bitmap,$accept,$coordinator,$request)
                & $accept
                $state.OwnedAfterAccept = $coordinator.OwnedBitmap
                Stop-SnipCaptureCoordinator -Coordinator $coordinator
                try {
                    $bitmap.Touch()
                    $state.TouchAfterStop = $true
                } catch {
                    $state.Error = $_
                } finally {
                    if (-not $bitmap.Disposed) { $bitmap.Dispose() }
                }
                'Shutdown'
            }.GetNewClosure()
        }
        $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

        Request-SnipCapture -Coordinator $coordinator -Mode Full -Source ShutdownRace | Out-Null

        if (-not $state.TouchAfterStop) {
            throw "Touch after Stop failed; ownedAfterAcceptNull=$($null -eq $state.OwnedAfterAccept); dispose=$($state.Capture.DisposeCount); error=$($state.Error.Exception.Message); phase=$($coordinator.Phase); ownedNull=$($null -eq $coordinator.OwnedBitmap)"
        }
        Should-Be $state.Error $null
        Should-Be $state.OwnedAfterAccept $null
        Should-Be $state.Capture.DisposeCount 1
        Should-Be $coordinator.OwnedBitmap $null
        Should-Be $coordinator.Phase 'ShuttingDown'
    }

    It 'runs 100 captures through coordinator acceptance and real Preview Closed cleanup' {
        $state = @{
            Captures = [System.Collections.ArrayList]::new()
            PreviewCount = 0
        }
        $services = [pscustomobject]@{
            FullCapture = {
                param($coordinator,$request)
                $capture = [System.Drawing.Bitmap]::new(8, 8)
                foreach ($prior in $state.Captures) {
                    Should-BeFalse ([object]::ReferenceEquals($capture, $prior))
                }
                [void]$state.Captures.Add($capture)
                $capture
            }.GetNewClosure()
            Preview = {
                param($bitmap,$accept,$coordinator,$request)
                $previewContext = [pscustomobject]@{
                    Bitmap = $bitmap
                    State = $state
                }
                $testAction = {
                    param($kit)
                    $previewContext.Bitmap.SetPixel(
                        0, 0, [System.Drawing.Color]::FromArgb(255, 7, 8, 9))
                    $pixel = $previewContext.Bitmap.GetPixel(0, 0)
                    Should-Be $pixel.R 7
                    $previewContext.State.PreviewCount++
                }.GetNewClosure()
                Show-PreviewWindow -Bitmap $bitmap -OnOwnershipAccepted $accept `
                    -TestAction $testAction
            }.GetNewClosure()
        }
        $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

        for ($iteration = 1; $iteration -le 100; $iteration++) {
            Request-SnipCapture -Coordinator $coordinator -Mode Full `
                -Source "coordinator-$iteration" | Out-Null
        }

        Should-Be $state.Captures.Count 100
        Should-Be $state.PreviewCount 100
        foreach ($capture in $state.Captures) {
            $disposed = $false
            try { $capture.GetPixel(0, 0) | Out-Null } catch { $disposed = $true }
            Should-BeTrue $disposed
        }
        Should-Be $coordinator.OwnedBitmap $null
        Should-Be $coordinator.MaxPumpDepth 1
        Should-Be $coordinator.Phase 'Idle'
    }

    It 'keeps CaptureStarting until the Smart service publishes a closable surface' {
        $observed = @{ CaptureStarting = $false; Installed = $false }
        $services = [pscustomobject]@{
            SmartCapture = {
                param($coordinator,$request)
                $observed.CaptureStarting = ($coordinator.Phase -eq 'CaptureStarting')
                $coordinator.ActiveSurface = [pscustomobject]@{ Close = { param($result) } }
                $coordinator.Phase = 'Selecting'
                $observed.Installed = ($null -ne $coordinator.ActiveSurface)
                [pscustomobject]@{ Result = 'UserCancelled'; Bitmap = $null }
            }.GetNewClosure()
        }
        $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

        Request-SnipCapture -Coordinator $coordinator -Mode Smart -Source Hotkey | Out-Null
        Should-BeTrue $observed.CaptureStarting
        Should-BeTrue $observed.Installed
        Should-Be $coordinator.Phase 'Idle'
    }

    It 'publishes the normal Smart surface through the production readiness callback' {
        $state = @{
            PhaseBefore = $null
            PhaseAfter = $null
            Accepted = $null
            Installed = $false
            Surface = [pscustomobject]@{
                Id = [guid]::NewGuid()
                Close = { param($result) }
            }
        }
        $overlay = {
            param($ready,$coordinator,$request)
            $state.PhaseBefore = $coordinator.Phase
            $state.Accepted = & $ready $state.Surface
            $state.Installed = ($coordinator.ActiveSurface.Id -eq $state.Surface.Id)
            $state.PhaseAfter = $coordinator.Phase
            [pscustomobject]@{ Result = 'UserCancelled'; Bitmap = $null }
        }.GetNewClosure()
        $services = New-SnipRuntimeCaptureServices -SmartOverlay $overlay
        $coordinator = New-SnipCaptureCoordinator -Services $services `
            -Post { param($work) & $work }

        Request-SnipCapture -Coordinator $coordinator -Mode Smart -Source NormalReady | Out-Null

        Should-Be $state.PhaseBefore 'CaptureStarting'
        Should-BeTrue $state.Accepted
        Should-BeTrue $state.Installed
        Should-Be $state.PhaseAfter 'Selecting'
        Should-Be $coordinator.Phase 'Idle'
    }

    It 'preempts Smart overlays reentrantly at hide, snapshot, and readiness boundaries' {
        Should-BeTrue (Get-Command New-SnipRuntimeCaptureServices).Parameters.ContainsKey('SmartOverlay')

        foreach ($boundary in 'Hide','Snapshot','Readiness') {
            $state = @{
                Boundary = $boundary
                ObservedPhases = [System.Collections.ArrayList]::new()
                PhaseAfterReadiness = $null
                OverlayResult = $null
                Snapshot = New-OwnershipProbe -Id "preempt-$boundary"
                FullCount = 0
                PreviewCount = 0
            }
            $overlay = {
                param($ready,$coordinator,$request)
                $context = [pscustomobject]@{
                    Ready = $ready
                    Coordinator = $coordinator
                    State = $state
                }
                $hide = {
                    if ($context.State.Boundary -eq 'Hide') {
                        [void]$context.State.ObservedPhases.Add($context.Coordinator.Phase)
                        Request-SnipCapture -Coordinator $context.Coordinator `
                            -Mode Full -Source "pending-$($context.State.Boundary)" | Out-Null
                    }
                    @()
                }.GetNewClosure()
                $capture = {
                    param($bounds)
                    if ($context.State.Boundary -eq 'Snapshot') {
                        [void]$context.State.ObservedPhases.Add($context.Coordinator.Phase)
                        Request-SnipCapture -Coordinator $context.Coordinator `
                            -Mode Full -Source "pending-$($context.State.Boundary)" | Out-Null
                    }
                    $context.State.Snapshot
                }.GetNewClosure()
                $readiness = {
                    param($surface)
                    if ($context.State.Boundary -eq 'Readiness') {
                        [void]$context.State.ObservedPhases.Add($context.Coordinator.Phase)
                        Request-SnipCapture -Coordinator $context.Coordinator `
                            -Mode Full -Source "pending-$($context.State.Boundary)" | Out-Null
                    }
                    $accepted = & ([scriptblock]$context.Ready) $surface
                    $context.State.PhaseAfterReadiness = $context.Coordinator.Phase
                    $accepted
                }.GetNewClosure()
                $overlayResult = Show-SmartOverlay -OnSurfaceReady $readiness `
                    -HideWindows $hide -RestoreWindows { param($hidden) } `
                    -CaptureFactory $capture -BitmapSourceFactory { param($bitmap) $null }
                $context.State.OverlayResult = $overlayResult.Result
                $overlayResult
            }.GetNewClosure()
            $services = New-SnipRuntimeCaptureServices -SmartOverlay $overlay
            $services.FullCapture = {
                param($coordinator,$request)
                $state.FullCount++
                New-OwnershipProbe -Id "full-$boundary"
            }.GetNewClosure()
            $services.Preview = {
                param($bitmap,$accept,$coordinator,$request)
                & $accept
                try { $state.PreviewCount++ } finally { $bitmap.Dispose() }
                'UserCancelled'
            }.GetNewClosure()
            $coordinator = New-SnipCaptureCoordinator -Services $services `
                -Post { param($work) & $work }

            Request-SnipCapture -Coordinator $coordinator -Mode Smart `
                -Source "smart-$boundary" | Out-Null

            Should-Be @($state.ObservedPhases).Count 1
            Should-Be @($state.ObservedPhases)[0] 'CaptureStarting'
            Should-Be $state.PhaseAfterReadiness 'CaptureStarting'
            Should-Be $state.OverlayResult 'Preempted'
            Should-Be $state.Snapshot.DisposeCount 1
            Should-Be $state.FullCount 1
            Should-Be $state.PreviewCount 1
            Should-Be $coordinator.Phase 'Idle'
        }
    }

    It 'shuts down Smart overlays reentrantly at hide, snapshot, and readiness boundaries' {
        Should-BeTrue (Get-Command New-SnipRuntimeCaptureServices).Parameters.ContainsKey('SmartOverlay')

        foreach ($boundary in 'Hide','Snapshot','Readiness') {
            $state = @{
                Boundary = $boundary
                ObservedPhases = [System.Collections.ArrayList]::new()
                OverlayResult = $null
                Snapshot = New-OwnershipProbe -Id "shutdown-$boundary"
            }
            $overlay = {
                param($ready,$coordinator,$request)
                $context = [pscustomobject]@{
                    Ready = $ready
                    Coordinator = $coordinator
                    State = $state
                }
                $stop = {
                    [void]$context.State.ObservedPhases.Add($context.Coordinator.Phase)
                    Stop-SnipCaptureCoordinator -Coordinator $context.Coordinator
                }.GetNewClosure()
                $hide = {
                    if ($context.State.Boundary -eq 'Hide') { & $stop }
                    @()
                }.GetNewClosure()
                $capture = {
                    param($bounds)
                    if ($context.State.Boundary -eq 'Snapshot') { & $stop }
                    $context.State.Snapshot
                }.GetNewClosure()
                $readiness = {
                    param($surface)
                    if ($context.State.Boundary -eq 'Readiness') { & $stop }
                    & ([scriptblock]$context.Ready) $surface
                }.GetNewClosure()
                $overlayResult = Show-SmartOverlay -OnSurfaceReady $readiness `
                    -HideWindows $hide -RestoreWindows { param($hidden) } `
                    -CaptureFactory $capture -BitmapSourceFactory { param($bitmap) $null }
                $context.State.OverlayResult = $overlayResult.Result
                $overlayResult
            }.GetNewClosure()
            $services = New-SnipRuntimeCaptureServices -SmartOverlay $overlay
            $coordinator = New-SnipCaptureCoordinator -Services $services `
                -Post { param($work) & $work }

            Request-SnipCapture -Coordinator $coordinator -Mode Smart `
                -Source "smart-$boundary" | Out-Null

            Should-Be @($state.ObservedPhases).Count 1
            Should-Be @($state.ObservedPhases)[0] 'CaptureStarting'
            Should-Be $state.OverlayResult 'Shutdown'
            Should-Be $state.Snapshot.DisposeCount 1
            Should-BeTrue $coordinator.ShutdownRequested
            Should-Be $coordinator.Phase 'ShuttingDown'
            Should-Be $coordinator.ActiveSurface $null
        }
    }

    It 'maps every Preview surface result deterministically' {
        foreach ($surfaceResult in 'Completed','UserCancelled','Preempted','Failed','Shutdown') {
            $state = @{ Capture = $null }
            $services = [pscustomobject]@{
                FullCapture = {
                    param($coordinator,$request)
                    $state.Capture = New-OwnershipProbe -Id $surfaceResult
                    $state.Capture
                }.GetNewClosure()
                Preview = {
                    param($bitmap,$accept,$coordinator,$request)
                    & $accept
                    try { $bitmap.Touch() } finally { $bitmap.Dispose() }
                    $surfaceResult
                }.GetNewClosure()
            }
            $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }
            Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Tray | Out-Null

            Should-Be $coordinator.LastResult $surfaceResult
            Should-Be $state.Capture.DisposeCount 1
            if ($surfaceResult -eq 'Shutdown') {
                Should-Be $coordinator.Phase 'ShuttingDown'
            } else {
                Should-Be $coordinator.Phase 'Idle'
            }
        }
    }
}

Describe 'Runtime Window capture services' {
    It 'uses transaction topology for Full and exact Display physical bounds' {
        $descriptors = @(
            [pscustomobject]@{ Id='portrait-left'; X=-1200; Y=-300; Width=1200; Height=1920; WorkX=-1200; WorkY=-260; WorkWidth=1200; WorkHeight=1880; DpiX=144; DpiY=192; IsPrimary=$false },
            [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $topology = New-SnipDisplayTopology -MonitorDescriptors $descriptors -RequestId runtime-targets
        $state = @{ Reads=0; Seen=[System.Collections.ArrayList]::new() }
        $services = New-SnipRuntimeCaptureServices `
            -GetTopology { $state.Reads++; $topology }.GetNewClosure() `
            -GetVirtualBounds { throw 'separate virtual-bounds seam must not run' } `
            -HideWindows { @() } `
            -RestoreWindows { param($hidden) } `
            -CaptureRectangle {
                param($bounds)
                [void]$state.Seen.Add("$($bounds.X),$($bounds.Y),$($bounds.Width),$($bounds.Height)")
                [System.Drawing.Bitmap]::new(2, 2)
            }.GetNewClosure()

        $full = & $services.FullCapture $null `
            (New-SnipCaptureRequest -Mode Full -Source FullTopology)
        $display = & $services.DisplayCapture $null `
            (New-SnipCaptureRequest -Mode Display -MonitorId portrait-left -Source DisplayTopology)

        Should-Be $state.Reads 2
        Should-Be ($state.Seen -join ';') '-1200,-300,3120,1920;-1200,-300,1200,1920'
        Should-BeTrue ([object]::ReferenceEquals($full.Tag.DisplayTopology, $topology))
        Should-BeTrue ([object]::ReferenceEquals($display.Tag.DisplayTopology, $topology))
        Should-Be $display.Tag.X -1200
        Should-Be $display.Tag.Height 1920
        $full.Dispose()
        $display.Dispose()
    }

    It 'resolves fresh HWND bounds for every Window transaction' {
        $parameters = (Get-Command New-SnipRuntimeCaptureServices).Parameters
        foreach ($name in 'GetTopology','ResolveWindow','HideWindows','RestoreWindows','CaptureRectangle') {
            Should-BeTrue $parameters.ContainsKey($name)
        }
        $topology = New-SnipDisplayTopology -RequestId fresh-window -MonitorDescriptors @(
            [pscustomobject]@{ Id='only'; X=-1000; Y=-200; Width=3000; Height=1400; WorkX=-1000; WorkY=-160; WorkWidth=3000; WorkHeight=1360; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $state = @{
            ResolveCount = 0
            HideCount = 0
            RestoreCount = 0
            Seen = [System.Collections.ArrayList]::new()
            Descriptors = @(
                [pscustomobject]@{ Hwnd=[IntPtr]11; X=-500; Y=20; Width=300; Height=200 },
                [pscustomobject]@{ Hwnd=[IntPtr]22; X=100; Y=-40; Width=800; Height=600 }
            )
        }
        $services = New-SnipRuntimeCaptureServices `
            -GetTopology { $topology }.GetNewClosure() `
            -GetVirtualBounds { throw 'full fallback must not run' } `
            -ResolveWindow {
                $descriptor = $state.Descriptors[$state.ResolveCount]
                $state.ResolveCount++
                $descriptor
            }.GetNewClosure() `
            -HideWindows {
                $state.HideCount++
                [pscustomobject]@{ Token = $state.HideCount }
            }.GetNewClosure() `
            -RestoreWindows {
                param($hidden)
                $state.RestoreCount++
            }.GetNewClosure() `
            -CaptureRectangle {
                param($bounds)
                [void]$state.Seen.Add(
                    "$($bounds.Hwnd):$($bounds.X),$($bounds.Y),$($bounds.Width),$($bounds.Height)")
                New-OwnershipProbe -Id "window-$($bounds.Hwnd)"
            }.GetNewClosure()

        $first = & $services.WindowCapture $null `
            (New-SnipCaptureRequest -Mode Window -Source First)
        $second = & $services.WindowCapture $null `
            (New-SnipCaptureRequest -Mode Window -Source Second)

        Should-Be $state.ResolveCount 2
        Should-Be ($state.Seen -join ';') '11:-500,20,300,200;22:100,-40,800,600'
        Should-Be $state.HideCount 2
        Should-Be $state.RestoreCount 2
        $first.Dispose()
        $second.Dispose()
    }

    It 'fails visibly for invalid Window targets and never invokes Full capture' {
        $parameters = (Get-Command New-SnipRuntimeCaptureServices).Parameters
        foreach ($name in 'GetVirtualBounds','ResolveWindow','HideWindows','RestoreWindows','CaptureRectangle') {
            Should-BeTrue $parameters.ContainsKey($name)
        }
        $state = @{
            ResolveCount = 0
            TopologyCount = 0
            Seen = 0
            Notices = [System.Collections.ArrayList]::new()
        }
        $services = New-SnipRuntimeCaptureServices `
            -ResolveWindow {
                $state.ResolveCount++
                if ($state.ResolveCount -eq 1) { return $null }
                if ($state.ResolveCount -eq 2) {
                    return [pscustomobject]@{ Hwnd=[IntPtr]33; X=1; Y=2; Width=0; Height=20 }
                }
                [pscustomobject]@{ Hwnd=[IntPtr]44; X='invalid'; Y=2; Width=20; Height=20 }
            }.GetNewClosure() `
            -GetTopology {
                $state.TopologyCount++
                New-SnipDisplayTopology -RequestId "invalid-$($state.TopologyCount)" -MonitorDescriptors @(
                    [pscustomobject]@{ Id='only'; X=-1920; Y=-100; Width=3840; Height=1200; WorkX=-1920; WorkY=-100; WorkWidth=3840; WorkHeight=1160; DpiX=96; DpiY=96; IsPrimary=$true }
                )
            }.GetNewClosure() `
            -GetVirtualBounds { throw 'Full fallback must not run' } `
            -HideWindows { @() } `
            -RestoreWindows { param($hidden) } `
            -CaptureRectangle {
                param($bounds)
                $state.Seen++
                throw 'capture must not run'
            }.GetNewClosure() `
            -NotifyFailure {
                param($message)
                [void]$state.Notices.Add($message)
            }.GetNewClosure()

        $first = & $services.WindowCapture $null `
            (New-SnipCaptureRequest -Mode Window -Source NullTarget)
        $second = & $services.WindowCapture $null `
            (New-SnipCaptureRequest -Mode Window -Source InvalidTarget)
        $third = & $services.WindowCapture $null `
            (New-SnipCaptureRequest -Mode Window -Source MalformedTarget)

        Should-Be $state.ResolveCount 3
        Should-Be $state.TopologyCount 3
        Should-Be $state.Seen 0
        Should-Be $state.Notices.Count 3
        Should-Be $first.Result 'Failed'
        Should-Be $second.Result 'Failed'
        Should-Be $third.Result 'Failed'
        foreach ($message in $state.Notices) {
            Should-Be $message 'No capturable active window'
        }
    }

    It 'fails Display when its stable monitor ID disappears without capturing another monitor' {
        $topology = New-SnipDisplayTopology -RequestId display-missing -MonitorDescriptors @(
            [pscustomobject]@{ Id='remaining'; X=0; Y=0; Width=1600; Height=900; WorkX=0; WorkY=0; WorkWidth=1600; WorkHeight=860; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $state = @{ Captures=0; Notices=[System.Collections.ArrayList]::new() }
        $services = New-SnipRuntimeCaptureServices `
            -GetTopology { $topology }.GetNewClosure() `
            -CaptureRectangle { param($bounds) $state.Captures++; throw 'must not capture' }.GetNewClosure() `
            -NotifyFailure { param($message) [void]$state.Notices.Add($message) }.GetNewClosure()

        $result = & $services.DisplayCapture $null `
            (New-SnipCaptureRequest -Mode Display -MonitorId removed -Source DelayedDisplay)

        Should-Be $result.Result 'Failed'
        Should-Be $state.Captures 0
        Should-Be $state.Notices.Count 1
        Should-BeTrue ($state.Notices[0] -match "Display 'removed' is no longer available")
    }
}

Describe 'Utility window capture-exclusion lifecycle' {
    It 'registers a real HWND on SourceInitialized and unregisters it on Closed' {
        $registered = [System.Collections.ArrayList]::new()
        $unregistered = [System.Collections.ArrayList]::new()
        $window = [System.Windows.Window]::new()
        $window.ShowActivated = $false
        $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -10000
        $window.Top = -10000

        $lifecycle = Connect-SnipWindowLifecycle -Window $window `
            -Register { param($hwnd) [void]$registered.Add($hwnd) }.GetNewClosure() `
            -Unregister { param($hwnd) [void]$unregistered.Add($hwnd) }.GetNewClosure()
        $window.Show()
        $window.Close()

        Should-Be $registered.Count 1
        Should-BeTrue ($registered[0] -ne [IntPtr]::Zero)
        Should-Be $unregistered.Count 1
        Should-Be $unregistered[0] $registered[0]
        Should-BeFalse $lifecycle.Connected
    }

    It 'registers and unregisters the real Settings HWND exactly once' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-lifecycle-' + [guid]::NewGuid())
        $registered = [System.Collections.ArrayList]::new()
        $unregistered = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
            RegisterWindow = { param($hwnd) [void]$registered.Add($hwnd) }.GetNewClosure()
            UnregisterWindow = { param($hwnd) [void]$unregistered.Add($hwnd) }.GetNewClosure()
        }

        Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            & $kit.Close 'UserCancelled'
        } | Out-Null

        Should-Be $registered.Count 1
        Should-BeTrue ($registered[0] -ne [IntPtr]::Zero)
        Should-Be $unregistered.Count 1
        Should-Be $unregistered[0] $registered[0]
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'registers and unregisters the real About HWND exactly once' {
        $registered = [System.Collections.ArrayList]::new()
        $unregistered = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            RegisterWindow = { param($hwnd) [void]$registered.Add($hwnd) }.GetNewClosure()
            UnregisterWindow = { param($hwnd) [void]$unregistered.Add($hwnd) }.GetNewClosure()
        }

        Show-AboutWindow -Context $context -TestAction {
            param($kit)
            & $kit.Close 'UserCancelled'
        } | Out-Null

        Should-Be $registered.Count 1
        Should-BeTrue ($registered[0] -ne [IntPtr]::Zero)
        Should-Be $unregistered.Count 1
        Should-Be $unregistered[0] $registered[0]
    }

    It 'closes the real widget lifecycle without residual window state' {
        $registered = [System.Collections.ArrayList]::new()
        $unregistered = [System.Collections.ArrayList]::new()
        $settings = Get-SnipDefaultSettings
        $settings.WidgetVisible = $true
        $observed = @{ State = $null; Lifecycle = $null }
        $context = [pscustomobject]@{
            Settings = $settings
            SubmitRequest = { param($mode,$delay,$source) }
            OpenSettings = { }
            AnimationsEnabled = $false
            RegisterWindow = { param($hwnd) [void]$registered.Add($hwnd) }.GetNewClosure()
            UnregisterWindow = { param($hwnd) [void]$unregistered.Add($hwnd) }.GetNewClosure()
        }

        Show-FloatingWidget -Context $context -TestAction {
            param($kit)
            $observed.State = $kit.State
            $observed.Lifecycle = $kit.Lifecycle
            $kit.Window.Close()
        }.GetNewClosure() | Out-Null

        Should-Be $registered.Count 1
        Should-BeTrue ($registered[0] -ne [IntPtr]::Zero)
        Should-Be $unregistered.Count 1
        Should-Be $unregistered[0] $registered[0]
        Should-BeTrue $observed.State.Closed
        Should-BeFalse $observed.Lifecycle.Connected
        Should-Be $script:WidgetWindow $null
    }
}

Describe 'Auxiliary surface coordinator identity' {
    It 'rejects a racing utility window without completing an unrelated active surface' {
        $closedAs = [System.Collections.ArrayList]::new()
        $unrelated = [pscustomobject]@{ Name = 'Preview'; Close = { param($result) } }
        $candidate = [pscustomobject]@{
            Name = 'Settings'
            Close = { param($result) [void]$closedAs.Add($result) }.GetNewClosure()
        }
        $coordinator = New-SnipCaptureCoordinator
        $coordinator.Phase = 'Previewing'
        $coordinator.ActiveSurface = $unrelated

        Should-BeFalse (Set-SnipAuxiliarySurface -Coordinator $coordinator -Surface $candidate)
        Should-Be ($closedAs -join ',') 'Preempted'
        Should-BeFalse (Complete-SnipAuxiliarySurface -Coordinator $coordinator `
            -Surface $candidate -Result Preempted)
        Should-Be $coordinator.Phase 'Previewing'
        Should-BeTrue ([object]::ReferenceEquals($coordinator.ActiveSurface, $unrelated))
    }
}

Describe 'Settings utility surface' {
    It 'records one allowed key chord and displays its canonical active shortcut' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-ui-' + [guid]::NewGuid())
        $settingsPath = Join-Path $root 'settings.json'
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
        }

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $result = & $kit.RecordShortcut 0x4007 0x52
            Should-BeTrue $result.Success
            Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+R'
            Should-Be $kit.ErrorText.Text ''
            Should-BeFalse ([string]::IsNullOrWhiteSpace([string]$kit.ShortcutRecorder.ToolTip))
            Should-BeFalse ([string]::IsNullOrWhiteSpace([string]$kit.Window.FindName('SaveBtn').ToolTip))
            # Stock chrome: no glass shell, and the recorder is a plain Button
            # with no local Style or brushes of its own.
            foreach ($retired in 'GlassOuter','GlassSurface','HeaderCloseBtn','DragHeader') {
                Should-Be ($kit.Window.FindName($retired)) $null
            }
            Should-BeTrue ($kit.ShortcutRecorder -is [System.Windows.Controls.Button])
            Should-Be ($kit.ShortcutRecorder.ReadLocalValue(
                [System.Windows.FrameworkElement]::StyleProperty)) `
                ([System.Windows.DependencyProperty]::UnsetValue)
            Should-Be ($kit.ShortcutRecorder.ReadLocalValue(
                [System.Windows.Controls.Control]::BackgroundProperty)) `
                ([System.Windows.DependencyProperty]::UnsetValue)
            # Save changes is the one accent action on the window.
            $accentStyle = $kit.Window.TryFindResource('AccentButtonStyle')
            if ($null -ne $accentStyle) {
                Should-BeTrue ([object]::ReferenceEquals(
                    $kit.Window.FindName('SaveBtn').Style, $accentStyle))
                Should-BeFalse ([object]::ReferenceEquals(
                    $kit.Window.FindName('CancelBtn').Style, $accentStyle))
            }
        }

        Should-Be $context.RegisteredHotkey.VirtualKey 0x52
        Should-Be (Read-SnipSettings -Path $settingsPath -PicturesDir $root).Hotkey.VirtualKey 0x52
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ignores modifier-only input resolves Alt system keys and owns Escape while recording' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-keyboard-' + [guid]::NewGuid())
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
        }
        $allModifiers = [System.Windows.Input.ModifierKeys]::Control -bor
            [System.Windows.Input.ModifierKeys]::Alt -bor
            [System.Windows.Input.ModifierKeys]::Shift
        $windowsModifiers = [System.Windows.Input.ModifierKeys]::Control -bor
            [System.Windows.Input.ModifierKeys]::Alt -bor
            [System.Windows.Input.ModifierKeys]::Windows

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $tab = & $kit.RecordKey ([System.Windows.Input.Key]::Tab) `
                ([System.Windows.Input.Key]::None) ([System.Windows.Input.ModifierKeys]::None)
            Should-Be $null $tab
            Should-BeFalse $kit.RecorderState.LastHandled
            Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+Q'

            $shiftTab = & $kit.RecordKey ([System.Windows.Input.Key]::Tab) `
                ([System.Windows.Input.Key]::None) ([System.Windows.Input.ModifierKeys]::Shift)
            Should-Be $null $shiftTab
            Should-BeFalse $kit.RecorderState.LastHandled

            $modifierOnly = & $kit.RecordKey ([System.Windows.Input.Key]::LeftCtrl) `
                ([System.Windows.Input.Key]::None) ([System.Windows.Input.ModifierKeys]::Control)
            Should-Be $null $modifierOnly
            Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+Q'
            Should-BeTrue $kit.RecorderState.LastHandled

            $escape = & $kit.RecordKey ([System.Windows.Input.Key]::Escape) `
                ([System.Windows.Input.Key]::None) ([System.Windows.Input.ModifierKeys]::None)
            Should-BeFalse $escape.Success
            Should-BeTrue $kit.Window.IsVisible
            Should-BeTrue $kit.RecorderState.LastHandled

            $windowsResult = & $kit.RecordKey ([System.Windows.Input.Key]::R) `
                ([System.Windows.Input.Key]::None) $windowsModifiers
            Should-BeFalse $windowsResult.Success
            Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+Q'
            Should-BeTrue $kit.ErrorText.Text.Contains('not supported')

            $result = & $kit.RecordKey ([System.Windows.Input.Key]::System) `
                ([System.Windows.Input.Key]::R) $allModifiers
            Should-BeTrue $result.Success
            Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+R'
            Should-BeTrue $kit.RecorderState.LastHandled
        }

        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps the previous shortcut active and presents the candidate error inline' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-error-' + [guid]::NewGuid())
        $calls = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = {
                param($hwnd,$id,$mods,$vk)
                [void]$calls.Add($vk)
                return $vk -eq 0x51
            }.GetNewClosure()
            UnregisterHotkey = { param($hwnd,$id) $true }
        }

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $result = & $kit.RecordShortcut 0x4007 0x52
            Should-BeFalse $result.Success
            Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+Q'
            Should-BeTrue $kit.ErrorText.Text.Contains('RegisterHotKey rejected Ctrl+Alt+Shift+R')
            Should-BeTrue $kit.ErrorText.Text.Contains('previous shortcut remains active')
        }

        Should-Be ($calls -join ',') '82,81'
        Should-Be $context.RegisteredHotkey.VirtualKey 0x51
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports candidate and rollback failures without claiming a shortcut is active' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-rollback-' + [guid]::NewGuid())
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $false }
            UnregisterHotkey = { param($hwnd,$id) $true }
        }

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $result = & $kit.RecordShortcut 0x4007 0x52
            Should-BeFalse $result.Success
            Should-Be $kit.ShortcutText.Text 'Unavailable'
            Should-BeTrue $kit.ErrorText.Text.Contains('Could not restore the previous hotkey')
            Should-BeTrue $kit.ErrorText.Text.Contains('capture remains available from the tray')
        }

        Should-Be $null $context.RegisteredHotkey
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'warns that an unsaved candidate may remain active when native cleanup fails' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-uncertain-hotkey-' + [guid]::NewGuid())
        $settingsPath = Join-Path $root 'settings.json'
        $settings = Get-SnipDefaultSettings -PicturesDir $root
        Save-SnipSettings -Settings $settings -Path $settingsPath
        $state = @{ UnregisterCount = 0 }
        $context = [pscustomobject]@{
            Settings = $settings
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = {
                param($hwnd,$id)
                $state.UnregisterCount++
                return $state.UnregisterCount -eq 1
            }.GetNewClosure()
        }
        $fileLock = [IO.File]::Open(
            $settingsPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Show-SettingsWindow -Context $context -TestAction {
                param($kit)
                $result = & $kit.RecordShortcut 0x4007 0x52
                Should-BeFalse $result.Success
                Should-Be $kit.ShortcutText.Text 'Ctrl+Alt+Shift+R'
                Should-BeTrue $kit.ErrorText.Text.Contains('may remain active')
                Should-BeFalse $kit.ErrorText.Text.Contains('No global shortcut is active')
            } | Out-Null
        } finally {
            $fileLock.Dispose()
        }
        Should-Be $context.RegisteredHotkey.VirtualKey 0x52
        Should-Be $context.Settings.Hotkey.VirtualKey 0x51
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'persists save folder launch-at-sign-in and widget visibility together' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-fields-' + [guid]::NewGuid())
        $settingsPath = Join-Path $root 'settings.json'
        $syncCalls = [System.Collections.ArrayList]::new()
        $widgetCalls = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
            SyncStartup = { param($settings) [void]$syncCalls.Add($settings.LaunchAtSignIn) }.GetNewClosure()
            SetWidgetVisible = { param($visible) [void]$widgetCalls.Add($visible) }.GetNewClosure()
        }
        $customFolder = Join-Path $root 'Bench captures'

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $kit.SaveFolderBox.Text = $customFolder
            $kit.LaunchCheck.IsChecked = $false
            $kit.WidgetCheck.IsChecked = $true
            Should-BeTrue (& $kit.SaveChanges)
            Should-Be $kit.ErrorText.Text 'Settings saved.'
        }

        $saved = Read-SnipSettings -Path $settingsPath -PicturesDir $root
        Should-Be $saved.SaveFolder $customFolder
        Should-BeFalse $saved.LaunchAtSignIn
        Should-BeTrue $saved.WidgetVisible
        Should-Be ($syncCalls -join ',') 'False'
        Should-Be ($widgetCalls -join ',') 'True'
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'round-trips the default save format through save and reload' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-format-' + [guid]::NewGuid())
        $settingsPath = Join-Path $root 'settings.json'
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
        }

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            Should-Be $kit.SaveFormatBox.SelectedIndex 0
            Should-Be (& $kit.ReadSaveFormat) 'Png'
            Should-Be $kit.SaveFormatBox.Items.Count 3
            $formatTags = @($kit.SaveFormatBox.Items | ForEach-Object { [string]$_.Tag })
            Should-Be ($formatTags -join ',') 'Png,Jpeg,Bmp'
            $formatLabels = @($kit.SaveFormatBox.Items | ForEach-Object { [string]$_.Content })
            Should-Be ($formatLabels -join ',') 'PNG,JPEG,BMP'
            $kit.SaveFormatBox.SelectedIndex = 1
            Should-BeTrue (& $kit.SaveChanges)
            Should-Be $kit.ErrorText.Text 'Settings saved.'
        }

        Should-Be $context.Settings.SaveFormat 'Jpeg'
        $saved = Read-SnipSettings -Path $settingsPath -PicturesDir $root
        Should-Be $saved.SaveFormat 'Jpeg'
        $dialogDefaults = Get-SnipSaveDialogDefaults -Settings $saved -Now ([datetime]'2026-04-15T02:46:12')
        Should-Be $dialogDefaults.FileName 'snip-20260415-024612.jpg'
        Should-Be $dialogDefaults.FilterIndex 2

        $reloadedContext = [pscustomobject]@{
            Settings = $saved
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
        }
        $null = Show-SettingsWindow -Context $reloadedContext -TestAction {
            param($kit)
            Should-Be $kit.SaveFormatBox.SelectedIndex 1
            Should-Be (& $kit.ReadSaveFormat) 'Jpeg'
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'restores persisted and in-memory settings when a runtime side effect fails' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-settings-rollback-fields-' + [guid]::NewGuid())
        $settingsPath = Join-Path $root 'settings.json'
        $settings = Get-SnipDefaultSettings -PicturesDir $root
        Save-SnipSettings -Settings $settings -Path $settingsPath
        $context = [pscustomobject]@{
            Settings = $settings
            SettingsPath = $settingsPath
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
            SyncStartup = {
                param($candidate)
                if (-not $candidate.LaunchAtSignIn) { throw 'startup shortcut denied' }
            }
            SetWidgetVisible = { param($visible) }
        }
        $originalFolder = $settings.SaveFolder

        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $kit.SaveFolderBox.Text = (Join-Path $root 'Changed')
            $kit.SaveFormatBox.SelectedIndex = 2
            $kit.LaunchCheck.IsChecked = $false
            $kit.WidgetCheck.IsChecked = $true
            Should-BeFalse (& $kit.SaveChanges)
            Should-BeTrue $kit.ErrorText.Text.Contains('Previous settings were restored')
        }

        $saved = Read-SnipSettings -Path $settingsPath -PicturesDir $root
        Should-Be $context.Settings.SaveFolder $originalFolder
        Should-Be $context.Settings.SaveFormat 'Png'
        Should-BeTrue $context.Settings.LaunchAtSignIn
        Should-BeFalse $context.Settings.WidgetVisible
        Should-Be $saved.SaveFolder $originalFolder
        Should-Be $saved.SaveFormat 'Png'
        Should-BeTrue $saved.LaunchAtSignIn
        Should-BeFalse $saved.WidgetVisible
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Utility window UI Automation exposure' {
    # The utility surfaces are ordinary stock windows now, but the subtree is
    # still easy to break for assistive tech: an IsHitTestVisible=False root, a
    # peer-swallowing Border, or a capture-exclusion style would leave
    # AutomationElement.FromHandle returning a root with an empty subtree while
    # the window still looks correct on screen. Pin the whole control set.
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    function Get-SnipUiaDescendantMap {
        param([Parameter(Mandatory)] $Window, [Parameter(Mandatory)] [string]$ExpectedName)
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { throw 'window has no HWND yet' }
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        if ($null -eq $element) { throw "AutomationElement.FromHandle returned null for $hwnd" }
        Should-Be $element.Current.Name $ExpectedName
        $descendants = $element.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        if ($descendants.Count -eq 0) {
            throw "glass window '$ExpectedName' exposed no UI Automation subtree"
        }
        $map = @{}
        foreach ($descendant in $descendants) {
            $automationId = [string]$descendant.Current.AutomationId
            if (-not [string]::IsNullOrEmpty($automationId)) { $map[$automationId] = $descendant }
        }
        $map
    }

    It 'publishes every Settings control through AutomationElement.FromHandle' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('snipit-uia-settings-' + [guid]::NewGuid())
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings -PicturesDir $root
            SettingsPath = (Join-Path $root 'settings.json')
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
            Hwnd = [IntPtr]123
            RegisterHotkey = { param($hwnd,$id,$mods,$vk) $true }
            UnregisterHotkey = { param($hwnd,$id) $true }
            RegisterWindow = { param($hwnd) }
            UnregisterWindow = { param($hwnd) }
        }
        $null = Show-SettingsWindow -Context $context -TestAction {
            param($kit)
            $map = Get-SnipUiaDescendantMap -Window $kit.Window -ExpectedName 'SnipIT Settings'
            $expected = [ordered]@{
                ShortcutRecorder = 'ControlType.Button'
                SaveFolderBox    = 'ControlType.Edit'
                SaveFormatBox    = 'ControlType.ComboBox'
                LaunchCheck      = 'ControlType.CheckBox'
                WidgetCheck      = 'ControlType.CheckBox'
                SaveBtn          = 'ControlType.Button'
                CancelBtn        = 'ControlType.Button'
            }
            foreach ($entry in $expected.GetEnumerator()) {
                if (-not $map.ContainsKey($entry.Key)) {
                    throw "Settings UIA subtree is missing '$($entry.Key)'"
                }
                $found = $map[$entry.Key]
                Should-Be $found.Current.ControlType.ProgrammaticName $entry.Value
                # Screen readers announce Current.Name, so it must never be blank.
                Should-BeTrue (-not [string]::IsNullOrWhiteSpace($found.Current.Name))
            }
            & $kit.Close 'UserCancelled'
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'publishes the floating widget capture buttons through UI Automation' {
        $settings = Get-SnipDefaultSettings
        $settings.WidgetVisible = $true
        $context = [pscustomobject]@{
            Settings = $settings
            SubmitRequest = { param($mode,$delay,$source) }
            OpenSettings = { }
            RegisterWindow = { param($hwnd) }
            UnregisterWindow = { param($hwnd) }
        }
        $null = Show-FloatingWidget -Context $context -TestAction {
            param($kit)
            $map = Get-SnipUiaDescendantMap -Window $kit.Window -ExpectedName 'SnipIT capture widget'
            foreach ($name in 'Smart capture','Full desktop capture','Active window capture',
                'Open SnipIT Settings') {
                $matched = @($map.Values | Where-Object { $_.Current.Name -eq $name })
                if ($matched.Count -eq 0) {
                    throw "widget UIA subtree is missing '$name'"
                }
            }
            if ($kit.Window.IsVisible) { $kit.Window.Close() }
        }
    }
}

Describe 'Save destination settings threading' {
    It 'accepts settings on the save dialog preview and context seams' {
        $saveParameters = (Get-Command Save-CaptureToFile -CommandType Function).Parameters
        Should-BeTrue $saveParameters.ContainsKey('Settings')
        $previewParameters = (Get-Command Show-PreviewWindow -CommandType Function).Parameters
        Should-BeTrue $previewParameters.ContainsKey('Settings')
        $contextParameters = (Get-Command New-SnipPreviewContext -CommandType Function).Parameters
        Should-BeTrue $contextParameters.ContainsKey('Settings')
    }

    It 'stores the supplied settings on the preview context and its save closure' {
        $bitmap = [System.Drawing.Bitmap]::new(32, 32)
        try {
            $settings = Get-SnipDefaultSettings -PicturesDir 'C:\SnipITTestPictures'
            $settings.SaveFormat = 'Bmp'
            $context = New-SnipPreviewContext -Bitmap $bitmap -Settings $settings
            Should-Be $context.Settings.SaveFormat 'Bmp'
            Should-Be $context.Settings.SaveFolder $settings.SaveFolder
            Should-BeTrue ($context.SaveBitmap -is [scriptblock])
            $captured = $context.SaveBitmap.Module.SessionState.PSVariable.GetValue('Settings')
            Should-Be $captured.SaveFormat 'Bmp'
            Should-Be $captured.SaveFolder $settings.SaveFolder
            $dialogDefaults = Get-SnipSaveDialogDefaults -Settings $captured `
                -Now ([datetime]'2026-04-15T02:46:12')
            Should-Be $dialogDefaults.InitialDirectory (Join-Path 'C:\SnipITTestPictures' 'Snips')
            Should-Be $dialogDefaults.FileName 'snip-20260415-024612.bmp'
            Should-Be $dialogDefaults.FilterIndex 3
        } finally { $bitmap.Dispose() }
    }
}

Describe 'About utility surface' {
    It 'exposes product version runtimes repository MIT license and active shortcut' {
        $parameters = (Get-Command Show-AboutWindow -CommandType Function).Parameters
        Should-BeTrue $parameters.ContainsKey('Context')
        Should-BeTrue $parameters.ContainsKey('TestAction')
        $context = [pscustomobject]@{
            AppVersion = '0.2.0'
            Repository = 'https://github.com/RandomCodeSpace/snipIT'
            License = 'MIT License'
            RegisteredHotkey = [pscustomobject]@{ Modifiers = 0x4007; VirtualKey = 0x51 }
        }

        $null = Show-AboutWindow -Context $context -TestAction {
            param($kit)
            Should-Be $kit.Metadata.Version '0.2.0'
            Should-Be $kit.Metadata.PowerShell $PSVersionTable.PSVersion.ToString()
            Should-Be $kit.Metadata.DotNet ([Environment]::Version.ToString())
            Should-Be $kit.Metadata.Repository 'https://github.com/RandomCodeSpace/snipIT'
            Should-Be $kit.Metadata.License 'MIT License'
            Should-Be $kit.Metadata.ActiveShortcut 'Ctrl+Alt+Shift+Q'
            Should-Be $kit.Window.Title 'About SnipIT'
            Should-BeFalse ([string]::IsNullOrWhiteSpace([string]$kit.Window.FindName('CloseBtn').ToolTip))
            foreach ($retired in 'GlassOuter','GlassSurface','HeaderCloseBtn','DragHeader') {
                Should-Be ($kit.Window.FindName($retired)) $null
            }
            # Close is the single primary action, so it carries the accent style.
            $accentStyle = $kit.Window.TryFindResource('AccentButtonStyle')
            if ($null -ne $accentStyle) {
                Should-BeTrue ([object]::ReferenceEquals(
                    $kit.Window.FindName('CloseBtn').Style, $accentStyle))
            }
            # The repository row is a live Hyperlink over the metadata URL.
            $link = $kit.Window.FindName('RepositoryLink')
            Should-BeTrue ($link -is [System.Windows.Documents.Hyperlink])
            Should-Be "$($link.NavigateUri)" $kit.Metadata.Repository
            Should-Be $kit.Window.FindName('RepositoryText').Text $kit.Metadata.Repository
        }
    }
}

Describe 'Optional floating capture widget' {
    It 'does not create a window while WidgetVisible is false' {
        $parameters = (Get-Command Show-FloatingWidget -CommandType Function).Parameters
        Should-BeTrue $parameters.ContainsKey('Context')
        Should-BeTrue $parameters.ContainsKey('TestAction')
        $testActionRan = $false
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            SubmitRequest = { param($mode) }
            OpenSettings = { }
        }

        $result = Show-FloatingWidget -Context $context -TestAction {
            param($kit)
            $testActionRan = $true
        }.GetNewClosure()

        Should-Be $null $result
        Should-BeFalse $testActionRan
        Should-Be $null $script:WidgetWindow
    }

    It 'orders Smart Full Window Settings and routes only through supplied services' {
        $parameters = (Get-Command Show-FloatingWidget -CommandType Function).Parameters
        Should-BeTrue $parameters.ContainsKey('Context')
        Should-BeTrue $parameters.ContainsKey('TestAction')
        $requests = [System.Collections.ArrayList]::new()
        $settingsOpens = [System.Collections.ArrayList]::new()
        $settings = Get-SnipDefaultSettings
        $settings.WidgetVisible = $true
        $context = [pscustomobject]@{
            Settings = $settings
            SubmitRequest = { param($mode) [void]$requests.Add($mode) }.GetNewClosure()
            OpenSettings = { [void]$settingsOpens.Add('Settings') }.GetNewClosure()
            AnimationsEnabled = $false
        }

        Show-FloatingWidget -Context $context -TestAction {
            param($kit)
            Should-Be ($kit.Order -join ',') 'Smart,Full,Window,Settings'
            # A small stock tool window, not a glass slab.
            Should-Be $kit.Window.WindowStyle ([System.Windows.WindowStyle]::ToolWindow)
            Should-BeFalse $kit.Window.AllowsTransparency
            foreach ($retired in 'GlassOuter','GlassSurface','WidgetInnerHighlight') {
                Should-Be ($kit.Window.FindName($retired)) $null
            }
            # Smart is the primary capture, so it is the one accent button.
            $accentStyle = $kit.Window.TryFindResource('AccentButtonStyle')
            if ($null -ne $accentStyle) {
                Should-BeTrue ([object]::ReferenceEquals(
                    $kit.Buttons['SmartBtn'].Style, $accentStyle))
                foreach ($secondary in 'FullBtn','WindowBtn','SettingsBtn') {
                    Should-BeFalse ([object]::ReferenceEquals(
                        $kit.Buttons[$secondary].Style, $accentStyle))
                }
            }
            foreach ($button in $kit.Buttons.Values) {
                Should-BeFalse ([string]::IsNullOrWhiteSpace([string]$button.ToolTip))
                Should-BeFalse ([string]::IsNullOrWhiteSpace(
                    [System.Windows.Automation.AutomationProperties]::GetName($button)))
            }
            & $kit.Click 'SmartBtn'
            & $kit.Click 'FullBtn'
            & $kit.Click 'WindowBtn'
            & $kit.Click 'SettingsBtn'
        }

        Should-Be ($requests -join ',') 'Smart,Full,Window'
        Should-Be $settingsOpens.Count 1
    }

    It 'places the widget on the current pointer monitor and keeps the gap fallback in runtime state' {
        $settings = Get-SnipDefaultSettings
        $settings.WidgetVisible = $true
        $topology = New-SnipDisplayTopology -RequestId widget-placement -MonitorDescriptors @(
            [pscustomobject]@{ Id='Left portrait'; X=-1200; Y=-300; Width=1200; Height=1600; WorkX=-1200; WorkY=-260; WorkWidth=1200; WorkHeight=1520; DpiX=144; DpiY=144; IsPrimary=$false },
            [pscustomobject]@{ Id='Primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $pointer = [pscustomobject]@{ X=-600; Y=100 }
        $positionCalls = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = $settings
            SubmitRequest = { param($mode,$delay,$source,$monitorId) }
            OpenSettings = { }
            AnimationsEnabled = $false
            GetDisplayTopology = { $topology }.GetNewClosure()
            GetPointerPhysicalPosition = { $pointer }.GetNewClosure()
            SetWidgetPosition = {
                param($hwnd,$bounds)
                [void]$positionCalls.Add([pscustomobject]@{ Hwnd=$hwnd; Bounds=$bounds })
                $true
            }.GetNewClosure()
        }

        Show-FloatingWidget -Context $context -TestAction {
            param($kit)
            Should-Be $kit.State.Placement.MonitorId 'Left portrait'
            Should-Be $kit.State.LastValidMonitorId 'Left portrait'
            # 452 x 112 DIP at 150%: 678 px wide, centred in a 1200 px work area.
            Should-Be $kit.State.ShownPhysicalBounds.X -939
            Should-Be $kit.State.ShownPhysicalBounds.Y -245
            # Concealed sits a whole widget height above the shown strip, leaving
            # a ~1 px peek. Both tops round independently, so allow one pixel.
            Should-Be $kit.State.HiddenPhysicalBounds.Y `
                ($kit.State.ShownPhysicalBounds.Y - $kit.State.PhysicalBounds.Height - 2) 1

            $pointer.X = -100
            $pointer.Y = -280
            & $kit.Reveal
            Should-Be $kit.State.Placement.MonitorId 'Left portrait'
            Should-Be $kit.State.LastValidMonitorId 'Left portrait'
        }.GetNewClosure() | Out-Null

        Should-BeTrue ($positionCalls.Count -ge 1)
        Should-BeTrue ($positionCalls[0].Hwnd -ne [IntPtr]::Zero)
    }

    It 'keeps native physical placement authoritative through creation timer reveal and conceal' {
        $settings = Get-SnipDefaultSettings
        $settings.WidgetVisible = $true
        $topology = New-SnipDisplayTopology -RequestId widget-native-authority -MonitorDescriptors @(
            [pscustomobject]@{ Id='Scaled left'; X=-2560; Y=-200; Width=2560; Height=1600; WorkX=-2560; WorkY=-160; WorkWidth=2560; WorkHeight=1520; DpiX=192; DpiY=192; IsPrimary=$false },
            [pscustomobject]@{ Id='Primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $pointer = [pscustomobject]@{ X=-1700; Y=300 }
        $positionCalls = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = $settings
            SubmitRequest = { param($mode,$delay,$source,$monitorId) }
            OpenSettings = { }
            AnimationsEnabled = $true
            GetDisplayTopology = { $topology }.GetNewClosure()
            GetPointerPhysicalPosition = { $pointer }.GetNewClosure()
            SetWidgetPosition = {
                param($hwnd,$bounds)
                [void]$positionCalls.Add([pscustomobject]@{
                    Hwnd=$hwnd; X=$bounds.X; Y=$bounds.Y; Width=$bounds.Width; Height=$bounds.Height
                })
                $true
            }.GetNewClosure()
        }

        Show-FloatingWidget -Context $context -TestAction {
            param($kit)
            $initialLeft = $kit.Window.Left
            $initialTop = $kit.Window.Top
            # 452 x 112 DIP at 200%: 904 x 224 px, centred in a 2560 px work area.
            Should-Be $kit.State.CurrentPhysicalBounds.X -1732
            Should-Be $kit.State.CurrentPhysicalBounds.Y -366

            & $kit.Reveal
            Should-Be $kit.Window.Left $initialLeft
            Should-Be $kit.Window.Top $initialTop
            Should-BeFalse $kit.Window.HasAnimatedProperties
            Should-Be $kit.State.CurrentPhysicalBounds.Y -140

            $pointer.Y = -160
            & $kit.TimerTick
            Should-Be $kit.Window.Left $initialLeft
            Should-Be $kit.Window.Top $initialTop
            Should-BeFalse $kit.Window.HasAnimatedProperties
            Should-Be $kit.State.CurrentPhysicalBounds.Y -140

            $pointer.Y = 500
            & $kit.TimerTick
            Should-Be $kit.Window.Left $initialLeft
            Should-Be $kit.Window.Top $initialTop
            Should-BeFalse $kit.Window.HasAnimatedProperties
            Should-Be $kit.State.CurrentPhysicalBounds.Y -366

            & $kit.Conceal
            Should-Be $kit.Window.Left $initialLeft
            Should-Be $kit.Window.Top $initialTop
            Should-BeFalse $kit.Window.HasAnimatedProperties
            Should-Be $kit.State.CurrentPhysicalBounds.Y -366
        }.GetNewClosure() | Out-Null

        Should-BeTrue ($positionCalls.Count -ge 5)
        Should-Be $positionCalls[0].X -1732
        Should-Be $positionCalls[0].Y -366
    }
}

Describe 'Stock tray menu presentation' {
    It 'rebuilds Display from one current topology snapshot and submits its stable monitor ID' {
        $requests = [System.Collections.ArrayList]::new()
        $topologyCalls = @{ Count = 0 }
        $topology = New-SnipDisplayTopology -RequestId tray-first -MonitorDescriptors @(
            [pscustomobject]@{ Id='Left display'; X=-1200; Y=0; Width=1200; Height=1600; WorkX=-1200; WorkY=0; WorkWidth=1200; WorkHeight=1560; DpiX=144; DpiY=144; IsPrimary=$false },
            [pscustomobject]@{ Id='Primary display'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $nextTopology = New-SnipDisplayTopology -RequestId tray-second -MonitorDescriptors @(
            [pscustomobject]@{ Id='Above display'; X=0; Y=-1200; Width=1600; Height=1200; WorkX=0; WorkY=-1200; WorkWidth=1600; WorkHeight=1160; DpiX=192; DpiY=192; IsPrimary=$false }
        )
        $topologyState = [pscustomobject]@{ Value=$topology }
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = {
                param($mode,$delay,$source,$monitorId)
                [void]$requests.Add([pscustomobject]@{ Mode=$mode; Delay=$delay; Source=$source; MonitorId=$monitorId })
            }.GetNewClosure()
            GetDisplayTopology = {
                $topologyCalls.Count++
                $topologyState.Value
            }.GetNewClosure()
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
        }
        $menu = New-SnipTrayMenu -Context $context
        try {
            # One snapshot is taken to seed the submenu at construction, and one
            # more per open to pick up hot-plugged monitors.
            Should-Be $topologyCalls.Count 1
            $menu.Show([System.Drawing.Point]::new(-10000, -10000))
            [System.Windows.Forms.Application]::DoEvents()
            $menu.Tag.DisplayOpeningHandler.Invoke(
                $menu.Tag.Items.Display, [EventArgs]::Empty)
            Should-Be $topologyCalls.Count 2
            Should-Be ($menu.Tag.Items.Display.DropDownItems.Count) 2
            $primary = $menu.Tag.Items.Display.DropDownItems[1]
            Should-Be $primary.Text 'Primary display - 1920 x 1080 (Primary)'
            Should-Be $primary.Tag.MonitorId 'Primary display'
            $primary.PerformClick()
            Should-Be $requests.Count 1
            Should-Be $requests[0].Mode 'Display'
            Should-Be $requests[0].MonitorId 'Primary display'
            Should-Be $requests[0].Source 'Tray'

            $topologyState.Value = $nextTopology
            $menu.Close()
            $menu.Show([System.Drawing.Point]::new(-10000, -10000))
            [System.Windows.Forms.Application]::DoEvents()
            $menu.Tag.DisplayOpeningHandler.Invoke(
                $menu.Tag.Items.Display, [EventArgs]::Empty)
            Should-Be $topologyCalls.Count 3
            Should-Be $menu.Tag.Items.Display.DropDownItems.Count 1
            Should-Be $menu.Tag.Items.Display.DropDownItems[0].Tag.MonitorId 'Above display'
        } finally {
            $menu.Dispose()
        }
    }

    It 'seeds the Display submenu at construction so WinForms will open it' {
        # Regression: Display used to be added with an empty DropDownItems
        # collection and filled only from DropDownOpening. WinForms gates both
        # the submenu arrow and the open path on HasDropDownItems, so the event
        # never fired and the submenu could never be opened.
        $topologyCalls = @{ Count = 0 }
        $topology = New-SnipDisplayTopology -RequestId tray-seed -MonitorDescriptors @(
            [pscustomobject]@{ Id='left'; X=-1200; Y=0; Width=1200; Height=1600; WorkX=-1200; WorkY=0; WorkWidth=1200; WorkHeight=1560; DpiX=144; DpiY=144; IsPrimary=$false; DisplayName='DELL U2412M' },
            [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true; DisplayName='Display 1' }
        )
        $requests = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = {
                param($mode,$delay,$source,$monitorId)
                [void]$requests.Add([pscustomobject]@{ Mode=$mode; Source=$source; MonitorId=$monitorId })
            }.GetNewClosure()
            GetDisplayTopology = { $topologyCalls.Count++; $topology }.GetNewClosure()
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
        }
        $menu = New-SnipTrayMenu -Context $context
        try {
            $display = $menu.Tag.Items.Display
            Should-BeTrue $display.HasDropDownItems
            Should-Be $topologyCalls.Count 1
            Should-Be $display.DropDownItems.Count (@($topology.Descriptors).Count)
            $expected = @($topology.Descriptors | ForEach-Object {
                '{0} - {1} x {2}{3}' -f $_.DisplayName, [int]$_.Width, [int]$_.Height,
                    $(if ([bool]$_.IsPrimary) { ' (Primary)' } else { '' })
            })
            Should-Be ((@($display.DropDownItems) | ForEach-Object Text) -join '|') ($expected -join '|')
            Should-Be ((@($display.DropDownItems) | ForEach-Object { $_.Tag.MonitorId }) -join ',') 'left,primary'
            foreach ($child in $display.DropDownItems) {
                Should-BeTrue $child.Enabled
                Should-BeTrue ($child.Tag.ClickHandler -is [EventHandler])
                Should-BeFalse $child.Tag.IsPlaceholder
            }

            # The seeded items are wired exactly like the rebuilt ones.
            $display.DropDownItems[1].PerformClick()
            Should-Be $requests.Count 1
            Should-Be $requests[0].Mode 'Display'
            Should-Be $requests[0].Source 'Tray'
            Should-Be $requests[0].MonitorId 'primary'
        } finally {
            $menu.Dispose()
        }
    }

    It 'rebuilds the seeded Display submenu on DropDownOpening without duplicating items' {
        $topologyState = [pscustomobject]@{ Value = $null }
        $topologyState.Value = New-SnipDisplayTopology -RequestId tray-rebuild-first -MonitorDescriptors @(
            [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true; DisplayName='Display 1' }
        )
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = { param($mode,$delay,$source,$monitorId) }
            GetDisplayTopology = { $topologyState.Value }.GetNewClosure()
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
        }
        # DropDownOpening has no protected raiser of its own; ToolStripDropDownItem
        # raises it from OnDropDownShow, which is what ShowDropDown and the mouse
        # both end up calling.
        $onDropDownShow = [System.Windows.Forms.ToolStripDropDownItem].GetMethod(
            'OnDropDownShow', [System.Reflection.BindingFlags]'NonPublic,Instance')
        Should-BeTrue ($null -ne $onDropDownShow)
        $menu = New-SnipTrayMenu -Context $context
        try {
            $display = $menu.Tag.Items.Display
            Should-Be $display.DropDownItems.Count 1

            $onDropDownShow.Invoke($display, @([EventArgs]::Empty))
            Should-Be $display.DropDownItems.Count 1
            Should-Be $display.DropDownItems[0].Tag.MonitorId 'primary'

            $onDropDownShow.Invoke($display, @([EventArgs]::Empty))
            Should-Be $display.DropDownItems.Count 1
            Should-Be $menu.Tag.DisplayChildHandlers.Count 1

            # A hot-plugged monitor appears on the next open.
            $topologyState.Value = New-SnipDisplayTopology -RequestId tray-rebuild-second -MonitorDescriptors @(
                [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true; DisplayName='Display 1' },
                [pscustomobject]@{ Id='hotplug'; X=1920; Y=0; Width=2560; Height=1440; WorkX=1920; WorkY=0; WorkWidth=2560; WorkHeight=1400; DpiX=96; DpiY=96; IsPrimary=$false; DisplayName='LG ULTRAWIDE' }
            )
            $onDropDownShow.Invoke($display, @([EventArgs]::Empty))
            Should-Be $display.DropDownItems.Count 2
            Should-BeTrue $display.HasDropDownItems
            $ids = @($display.DropDownItems | ForEach-Object { $_.Tag.MonitorId })
            Should-Be ($ids -join ',') 'primary,hotplug'
            Should-Be $ids.Count (@($ids | Sort-Object -Unique).Count)
            $names = @($display.DropDownItems | ForEach-Object Name)
            Should-Be $names.Count (@($names | Sort-Object -Unique).Count)
        } finally {
            $menu.Dispose()
        }
    }

    It 'seeds one disabled placeholder when no display is enumerated' {
        $onDropDownShow = [System.Windows.Forms.ToolStripDropDownItem].GetMethod(
            'OnDropDownShow', [System.Reflection.BindingFlags]'NonPublic,Instance')
        $emptyTopology = [pscustomobject]@{ Descriptors = @() }
        $providers = [ordered]@{
            'empty topology' = { $emptyTopology }.GetNewClosure()
            'failing enumeration' = { throw 'monitor enumeration failed' }
        }
        foreach ($entry in $providers.GetEnumerator()) {
            $context = [pscustomobject]@{
                Settings = Get-SnipDefaultSettings
                ActiveShortcut = 'Ctrl+Alt+Shift+Q'
                SubmitRequest = { param($mode,$delay,$source,$monitorId) throw 'a placeholder must not submit a capture' }
                GetDisplayTopology = $entry.Value
                OpenSettings = { }
                OpenAbout = { }
                Exit = { }
            }
            $menu = New-SnipTrayMenu -Context $context
            try {
                $display = $menu.Tag.Items.Display
                # HasDropDownItems is the whole point: without a row WinForms
                # shows no arrow and never raises DropDownOpening.
                Should-BeTrue $display.HasDropDownItems
                Should-Be $display.DropDownItems.Count 1
                $placeholder = $display.DropDownItems[0]
                Should-Be $placeholder.Text 'No displays detected'
                Should-Be $placeholder.Name 'Display_None'
                Should-BeFalse $placeholder.Enabled
                Should-BeTrue $placeholder.Tag.IsPlaceholder
                Should-Be $placeholder.Tag.ClickHandler $null
                Should-Be $menu.Tag.DisplayChildHandlers.Count 0

                $onDropDownShow.Invoke($display, @([EventArgs]::Empty))
                Should-Be $display.DropDownItems.Count 1
                Should-Be $display.DropDownItems[0].Text 'No displays detected'
            } finally {
                $menu.Dispose()
            }
        }
    }

    It 'uses the stock professional renderer and the exact primary action order' {
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = { param($mode,$delay) }
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
        }
        $menu = New-SnipTrayMenu -Context $context -ThemeMode Light
        try {
            Should-BeTrue ($menu -is [System.Windows.Forms.ContextMenuStrip])
            # The tray is the one surface WPF's Fluent theme cannot reach, so it
            # uses the system renderer and the system menu colours rather than a
            # palette of ours. Owner drawing is retired outright.
            Should-BeTrue ($menu.Renderer -is [System.Windows.Forms.ToolStripProfessionalRenderer])
            Should-BeFalse $menu.Tag.OwnerDrawn
            Should-Be ($menu.Tag.PSObject.Properties['Palette']) $null
            Should-Be ($menu.Tag.PSObject.Properties['CheckPalette']) $null
            Should-Be ($menu.Tag.PSObject.Properties['RenderHandlers']) $null
            Should-Be $menu.Tag.ThemeMode 'Light'
            Should-Be ($menu.Tag.PrimaryOrder -join ',') 'Smart,Full,Window,Display,Settings,About,Exit'
            Should-Be ($menu.Tag.Order -join ',') 'Smart,Full,Window,Display,Separator1,Delay,Settings,Widget,OpenFolder,Separator2,About,Uninstall,Exit'
        } finally {
            $menu.Dispose()
        }
    }

    It 'reads the theme mode from the system seam without recolouring the menu' {
        $settings = Get-SnipDefaultSettings
        $settings.WidgetVisible = $true
        $newContext = {
            [pscustomobject]@{
                Settings = $settings
                ActiveShortcut = 'Ctrl+Alt+Shift+Q'
                SubmitRequest = { param($mode,$delay) }
                OpenSettings = { }
                OpenAbout = { }
                Exit = { }
            }
        }.GetNewClosure()

        # Both modes build the identical stock menu: the shell owns the colours,
        # so there is nothing mode-dependent left for SnipIT to get wrong.
        $reference = [System.Windows.Forms.ContextMenuStrip]::new()
        try {
            foreach ($mode in 'Dark','Light') {
                $menu = New-SnipTrayMenu -Context (& $newContext) -ThemeMode $mode
                try {
                    Should-Be $menu.Tag.ThemeMode $mode
                    Should-Be $menu.BackColor.ToArgb() $reference.BackColor.ToArgb()
                    Should-Be $menu.ForeColor.ToArgb() $reference.ForeColor.ToArgb()
                    Should-BeTrue ($menu.Renderer -is `
                        [System.Windows.Forms.ToolStripProfessionalRenderer])
                    foreach ($lifecycle in $menu.Tag.DropDownLifecycles) {
                        Should-Be $lifecycle.DropDown.BackColor.ToArgb() $menu.BackColor.ToArgb()
                        Should-Be $lifecycle.DropDown.ForeColor.ToArgb() $menu.ForeColor.ToArgb()
                    }
                } finally { $menu.Dispose() }
            }
        } finally { $reference.Dispose() }

        # No -ThemeMode: the menu is rebuilt per construction from the live seam.
        $defaulted = New-SnipTrayMenu -Context (& $newContext)
        try {
            Should-Be $defaulted.Tag.ThemeMode (Get-SnipSystemThemeMode)
        } finally {
            $defaulted.Dispose()
        }
    }

    It 'installs no custom render handler on the tray renderer' {
        # The retired implementation owner-drew the background, border, item
        # fill, text, separators and the check glyph. None of that may return.
        $body = (Get-Command New-SnipTrayMenu -CommandType Function).ScriptBlock.ToString()
        foreach ($retired in 'add_RenderToolStripBackground','add_RenderToolStripBorder',
                'add_RenderMenuItemBackground','add_RenderItemText',
                'add_RenderSeparator','add_RenderItemCheck') {
            Should-BeFalse ($body -match [regex]::Escape($retired))
        }
        Should-BeFalse ($body -match 'ColorTranslator')
        Should-BeFalse ($body -match 'Get-SnipThemeTokens|Get-SnipFluentPalette')
    }

    It 'applies the root visual policy to every nested tray dropdown' {
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = { param($mode,$delay) }
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
        }
        $menu = New-SnipTrayMenu -Context $context
        try {
            Should-Be $menu.Tag.DropDownLifecycles.Count 3
            foreach ($lifecycle in $menu.Tag.DropDownLifecycles) {
                $dropDown = $lifecycle.DropDown
                Should-BeTrue ([object]::ReferenceEquals($dropDown.Renderer, $menu.Renderer))
                Should-Be $dropDown.BackColor.ToArgb() $menu.BackColor.ToArgb()
                Should-Be $dropDown.ForeColor.ToArgb() $menu.ForeColor.ToArgb()
                Should-Be $dropDown.Font.Name $menu.Font.Name
                Should-Be $dropDown.Font.Size $menu.Font.Size
                Should-Be $dropDown.Font.Style $menu.Font.Style
                Should-Be $dropDown.Margin $menu.Margin
                Should-Be $dropDown.Padding $menu.Padding
                if ($dropDown -is [System.Windows.Forms.ToolStripDropDownMenu]) {
                    Should-Be $dropDown.ShowImageMargin $menu.ShowImageMargin
                    Should-Be $dropDown.ShowCheckMargin $menu.ShowCheckMargin
                }
            }
        } finally {
            $menu.Dispose()
        }
    }


    It 'routes capture settings about and exit actions to the supplied services' {
        $requests = [System.Collections.ArrayList]::new()
        $actions = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = { param($mode,$delay) [void]$requests.Add($mode) }.GetNewClosure()
            OpenSettings = { [void]$actions.Add('Settings') }.GetNewClosure()
            OpenAbout = { [void]$actions.Add('About') }.GetNewClosure()
            Exit = { [void]$actions.Add('Exit') }.GetNewClosure()
        }
        $menu = New-SnipTrayMenu -Context $context
        try {
            foreach ($name in 'Smart','Full','Window','Settings','About','Exit') {
                $menu.Tag.Items[$name].PerformClick()
            }
            Should-Be ($requests -join ',') 'Smart,Full,Window'
            Should-Be ($actions -join ',') 'Settings,About,Exit'
        } finally {
            $menu.Dispose()
        }
    }

    It 'registers every open tray dropdown HWND and unregisters each exactly once on close' {
        $registered = [System.Collections.ArrayList]::new()
        $unregistered = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = { param($mode,$delay) }
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
            RegisterWindow = { param($hwnd) [void]$registered.Add($hwnd) }.GetNewClosure()
            UnregisterWindow = { param($hwnd) [void]$unregistered.Add($hwnd) }.GetNewClosure()
        }
        $menu = New-SnipTrayMenu -Context $context
        try {
            $menu.Show([System.Drawing.Point]::new(-10000, -10000))
            [System.Windows.Forms.Application]::DoEvents()
            $menu.Tag.Items.Delay.ShowDropDown()
            [System.Windows.Forms.Application]::DoEvents()
            $menu.Tag.Items.Display.ShowDropDown()
            [System.Windows.Forms.Application]::DoEvents()
            Should-Be $registered.Count 3
            Should-BeTrue ($registered[0] -ne [IntPtr]::Zero)
            Should-BeTrue ($registered[1] -ne [IntPtr]::Zero)
            Should-BeTrue ($registered[2] -ne [IntPtr]::Zero)
            Should-Be $registered.Count (@($registered | Sort-Object -Unique).Count)
            $menu.Close()
            [System.Windows.Forms.Application]::DoEvents()
            Should-Be $unregistered.Count 3
            Should-Be (@($unregistered | Sort-Object) -join ',') `
                (@($registered | Sort-Object) -join ',')
        } finally {
            $menu.Dispose()
        }
        Should-Be $unregistered.Count 3
    }

    It 'uses disposal fallback for every still-open tray dropdown without double unregistering' {
        $registered = [System.Collections.ArrayList]::new()
        $unregistered = [System.Collections.ArrayList]::new()
        $context = [pscustomobject]@{
            Settings = Get-SnipDefaultSettings
            ActiveShortcut = 'Ctrl+Alt+Shift+Q'
            SubmitRequest = { param($mode,$delay) }
            OpenSettings = { }
            OpenAbout = { }
            Exit = { }
            RegisterWindow = { param($hwnd) [void]$registered.Add($hwnd) }.GetNewClosure()
            UnregisterWindow = { param($hwnd) [void]$unregistered.Add($hwnd) }.GetNewClosure()
        }
        $menu = New-SnipTrayMenu -Context $context
        $menu.Show([System.Drawing.Point]::new(-10000, -10000))
        [System.Windows.Forms.Application]::DoEvents()
        $menu.Tag.Items.Delay.ShowDropDown()
        [System.Windows.Forms.Application]::DoEvents()
        $menu.Tag.Items.Display.ShowDropDown()
        [System.Windows.Forms.Application]::DoEvents()
        Should-Be $registered.Count 3

        $menu.Dispose()
        [System.Windows.Forms.Application]::DoEvents()

        Should-Be $unregistered.Count 3
        Should-Be (@($unregistered | Sort-Object) -join ',') `
            (@($registered | Sort-Object) -join ',')
    }

    It 'keeps utility surfaces free of direct capture calls' {
        $forbidden = @(
            'Invoke-SmartCapture','Invoke-FullScreenCapture','Invoke-WindowCapture',
            'Show-SmartOverlay','Show-PreviewWindow','New-ScreenBitmap','Request-SnipCapture'
        )
        foreach ($functionName in 'Show-SettingsWindow','Show-AboutWindow','Show-FloatingWidget','New-SnipTrayMenu') {
            $ast = (Get-Command $functionName -CommandType Function).ScriptBlock.Ast
            $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() })
            foreach ($commandName in $forbidden) {
                Should-BeFalse ($commands -contains $commandName)
            }
        }
    }
}

Describe 'Floating Studio monitor placement review fixes' {
    It 'uses supplied capture topology in Preview without monitor re-enumeration' {
        $topology = New-SnipDisplayTopology -RequestId preview-supplied -MonitorDescriptors @(
            [pscustomobject]@{ Id='above-200'; X=200; Y=-1800; Width=1200; Height=1800; WorkX=200; WorkY=-1760; WorkWidth=1200; WorkHeight=1760; DpiX=192; DpiY=192; IsPrimary=$false },
            [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        $originalEnumerator = (Get-Command Get-SnipMonitorDescriptors -CommandType Function).ScriptBlock
        Set-Item Function:\Get-SnipMonitorDescriptors -Value { throw 'monitor enumeration must not run' }
        $bitmap = [System.Drawing.Bitmap]::new(20, 20)
        $bitmap.Tag = [pscustomobject]@{
            X=300; Y=-1700; Width=600; Height=900; DisplayTopology=$topology
        }
        try {
            $result = Show-PreviewWindow -Bitmap $bitmap -DisplayTopology $topology -TestAction {
                param($kit)
                Should-Be $kit.Context.PresentationState.DisplayTopology.Fingerprint `
                    $topology.Fingerprint
                Should-Be $kit.Context.CaptureMonitor.Id 'above-200'
            }.GetNewClosure()
            Should-Be $result 'UserCancelled'
        } finally {
            Set-Item Function:\Get-SnipMonitorDescriptors -Value $originalEnumerator
            if ($null -ne $bitmap) {
                try { $bitmap.Dispose() } catch {}
            }
        }
    }

    It 'publishes each monitor physical working area' {
        $descriptors = @(Get-SnipMonitorDescriptors)
        Should-BeTrue ($descriptors.Count -gt 0)
        foreach ($descriptor in $descriptors) {
            foreach ($propertyName in 'WorkX','WorkY','WorkWidth','WorkHeight') {
                Should-BeTrue ($null -ne $descriptor.PSObject.Properties[$propertyName])
            }
            Should-BeTrue ($descriptor.WorkWidth -gt 0)
            Should-BeTrue ($descriptor.WorkHeight -gt 0)
            Should-BeTrue ($descriptor.WorkX -ge $descriptor.X)
            Should-BeTrue ($descriptor.WorkY -ge $descriptor.Y)
            Should-BeTrue (($descriptor.WorkX + $descriptor.WorkWidth) -le
                ($descriptor.X + $descriptor.Width))
            Should-BeTrue (($descriptor.WorkY + $descriptor.WorkHeight) -le
                ($descriptor.Y + $descriptor.Height))
        }
    }

    It 'chooses the largest cross-monitor capture intersection' {
        $bitmap = [System.Drawing.Bitmap]::new(32, 32)
        try {
            $monitors = @(
                [pscustomobject]@{ Id='Left'; X=-1000; Y=0; Width=1000; Height=1000; WorkX=-1000; WorkY=0; WorkWidth=1000; WorkHeight=960; DpiX=96; DpiY=96; IsPrimary=$true },
                [pscustomobject]@{ Id='Right'; X=0; Y=650; Width=1000; Height=100; WorkX=0; WorkY=650; WorkWidth=1000; WorkHeight=100; DpiX=96; DpiY=96; IsPrimary=$false }
            )
            # The capture center is on Right, but Left owns twice the captured area.
            $context = New-SnipPreviewContext -Bitmap $bitmap `
                -CaptureBounds ([pscustomobject]@{ X=-200; Y=500; Width=600; Height=400 }) `
                -MonitorDescriptors $monitors
            Should-Be $context.CaptureMonitor.Id 'Left'
        } finally { $bitmap.Dispose() }
    }

    It 'converts 150-percent negative-origin placement and applies exact physical work-area bounds' {
        $bitmap = [System.Drawing.Bitmap]::new(32, 32)
        $calls = [System.Collections.ArrayList]::new()
        $setWindowPosition = {
            param($hwnd,$bounds)
            $calls.Add([pscustomobject]@{ Hwnd=$hwnd; Bounds=$bounds }) | Out-Null
            $true
        }.GetNewClosure()
        $context = $null
        $shell = $null
        try {
            $monitor = [pscustomobject]@{
                Id='ScaledLeft'; X=-2560; Y=-200; Width=2560; Height=1600
                WorkX=-2560; WorkY=-160; WorkWidth=2560; WorkHeight=1520
                DpiX=144; DpiY=144; IsPrimary=$false
            }
            $context = New-SnipPreviewContext -Bitmap $bitmap `
                -CaptureBounds ([pscustomobject]@{ X=-2400; Y=-100; Width=800; Height=600 }) `
                -MonitorDescriptors @($monitor) -SetWindowPosition $setWindowPosition
            Should-Be $context.PlacementState.Effect.Name 'ApplyPlacement'
            Should-Be $context.PresentationState.DisplayTopology.Descriptors[0].Id 'ScaledLeft'
            Should-Be $context.InitialBounds.Width 1180
            Should-Be $context.InitialBounds.Height 760
            Should-Be $context.InitialPhysicalBounds.X -2560
            Should-Be $context.InitialPhysicalBounds.Y -160
            Should-Be $context.InitialPhysicalBounds.Width 1770
            Should-Be $context.InitialPhysicalBounds.Height 1140

            $shell = New-SnipPreviewWindow -Context $context
            $shell.Window.Show()
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            Should-Be $calls.Count 1
            Should-BeTrue ($calls[0].Hwnd -ne [IntPtr]::Zero)
            Should-Be $calls[0].Bounds.X -2560
            Should-Be $calls[0].Bounds.Y -160
            Should-Be $calls[0].Bounds.Width 1770
            Should-Be $calls[0].Bounds.Height 1140
            Should-BeTrue $context.PlacementState.HandlersAttached
            $shell.Window.Close()
            Should-BeFalse $context.PlacementState.HandlersAttached
            foreach ($split in $context.SplitControls.Values) {
                Should-BeFalse $split.State.HandlersAttached
            }
        } finally {
            if ($null -ne $shell -and $shell.Window.IsVisible) { $shell.Window.Close() }
            $bitmap.Dispose()
        }
    }
}

Describe 'Floating Studio routed chrome review fixes' {
    It 'routes actual Alt Space through the single command router' {
        $bitmap = [System.Drawing.Bitmap]::new(16,16)
        $systemMenuCalls = @{ Count=0; ResolveCount=0 }
        $result = Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            $originalResolver = $kit.CommandRouter.Resolve
            $kit.CommandRouter.Resolve = {
                param($focusedRole,$editorState,$key,$modifiers)
                $systemMenuCalls.ResolveCount++
                & $originalResolver $focusedRole $editorState $key $modifiers
            }.GetNewClosure()
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::Alt
            }
            $kit.CommandRouter.SystemMenuAction = {
                $systemMenuCalls.Count++
            }.GetNewClosure()
            Should-BeFalse ($kit.CommandRouter.PSObject.Properties.Name -contains
                'RouteWindowChord')
            $eventArgs = New-RoutedKeyEvent -Target $kit.Win -Key Space -SystemKey Space
            $kit.Win.RaiseEvent($eventArgs)
            Should-BeTrue $eventArgs.Handled
            Should-Be $systemMenuCalls.Count 1
            Should-Be $systemMenuCalls.ResolveCount 1
            Should-Be $kit.CommandRouter.LastCommand 'ShowSystemMenu'
        }.GetNewClosure()
        Should-Be $result 'UserCancelled'
    }

    It 'routes actual Alt F4 unconditionally while an editor and popup claim focus' {
        $bitmap = [System.Drawing.Bitmap]::new(16,16)
        $closedByRoute = @{
            Context=$null; Event=$null; Key=$null; SystemKey=$null
        }
        $result = Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            $kit.State.EditingText = $true
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::Alt
            }
            Should-BeFalse ($kit.CommandRouter.PSObject.Properties.Name -contains
                'RouteWindowChord')
            # WPF's Window class handler consumes a synthetic F4 raised through
            # RaiseEvent before instance handlers run. Drive the exact published
            # PreviewKeyDown handler with a real SystemKey-shaped KeyEventArgs.
            $eventArgs = New-RoutedKeyEvent -Target $kit.Win -Key F4 -SystemKey F4
            $closedByRoute.Event = $eventArgs
            $closedByRoute.Context = $kit.Context
            $closedByRoute.Key = $eventArgs.Key
            $closedByRoute.SystemKey = $eventArgs.SystemKey
            $kit.HandlePreviewKeyDown.Invoke($eventArgs) | Out-Null
        }.GetNewClosure()
        Should-Be $closedByRoute.Key ([System.Windows.Input.Key]::System)
        Should-Be $closedByRoute.SystemKey ([System.Windows.Input.Key]::F4)
        Should-Be $closedByRoute.Context.CommandRouter.ResolveCount 1
        Should-Be $closedByRoute.Context.CommandRouter.LastCommand 'ClosePreview'
        Should-BeTrue $closedByRoute.Event.Handled
        Should-Be $result 'UserCancelled'
    }
}

Describe 'Floating Studio copy completion contract' {
    It 'retries a busy clipboard after 50 100 and 200 milliseconds then closes on success' {
        $bitmap = [System.Drawing.Bitmap]::new(16, 16)
        $events = [System.Collections.ArrayList]::new()
        $delays = [System.Collections.ArrayList]::new()
        $attempts = @{ Count = 0 }
        $clipboardSetter = {
            param($image)
            $attempts.Count++
            if ($attempts.Count -lt 4) { throw 'clipboard busy' }
        }.GetNewClosure()
        $retryDelay = {
            param($milliseconds)
            $delays.Add($milliseconds) | Out-Null
        }.GetNewClosure()
        $result = Show-PreviewWindow -Bitmap $bitmap `
            -OnOutputStarting { param($kind) $events.Add("start:$kind") | Out-Null }.GetNewClosure() `
            -OnOutputCompleted { param($kind,$success) $events.Add("done:${kind}:$success") | Out-Null }.GetNewClosure() `
            -TestAction {
                param($kit)
                $kit.Context.ClipboardSetter = $clipboardSetter
                $kit.Context.RetryDelay = $retryDelay
                $kit.SplitControls.Copy.PrimaryButton.RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }.GetNewClosure()
        Should-Be $result 'Completed'
        Should-Be $attempts.Count 4
        Should-Be (($delays) -join ',') '50,100,200'
        Should-Be (($events) -join ',') 'start:CopyAndClose,done:CopyAndClose:True'
        $disposed = $false
        try { $bitmap.GetPixel(0,0) | Out-Null } catch { $disposed = $true }
        Should-BeTrue $disposed
    }

    It 'copies and keeps Preview open from the split option' {
        $bitmap = [System.Drawing.Bitmap]::new(16, 16)
        $events = [System.Collections.ArrayList]::new()
        $wasOpenAfterCopy = @{ Value = $false }
        $result = Show-PreviewWindow -Bitmap $bitmap `
            -OnOutputStarting { param($kind) $events.Add("start:$kind") | Out-Null }.GetNewClosure() `
            -OnOutputCompleted { param($kind,$success) $events.Add("done:${kind}:$success") | Out-Null }.GetNewClosure() `
            -TestAction {
                param($kit)
                $kit.Context.ClipboardSetter = { param($image) }.GetNewClosure()
                $kit.Context.RetryDelay = { param($milliseconds) }.GetNewClosure()
                $kit.SplitControls.Copy.MenuItems.CopyKeepOpen.RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.MenuItem]::ClickEvent))
                $wasOpenAfterCopy.Value = $kit.Win.IsVisible
            }.GetNewClosure()
        Should-BeTrue $wasOpenAfterCopy.Value
        Should-Be $result 'UserCancelled'
        Should-Be (($events) -join ',') 'start:CopyKeepOpen,done:CopyKeepOpen:True'
    }

    It 'keeps Preview open with recoverable status after clipboard retries are exhausted' {
        $bitmap = [System.Drawing.Bitmap]::new(16, 16)
        $events = [System.Collections.ArrayList]::new()
        $delays = [System.Collections.ArrayList]::new()
        $attempts = @{ Count = 0 }
        $wasOpen = @{ Value=$false; Status=$null }
        $clipboardSetter = {
            param($image)
            $attempts.Count++
            throw 'clipboard remains busy'
        }.GetNewClosure()
        $retryDelay = {
            param($milliseconds)
            $delays.Add($milliseconds) | Out-Null
        }.GetNewClosure()
        $result = Show-PreviewWindow -Bitmap $bitmap `
            -OnOutputStarting { param($kind) $events.Add("start:$kind") | Out-Null }.GetNewClosure() `
            -OnOutputCompleted { param($kind,$success) $events.Add("done:${kind}:$success") | Out-Null }.GetNewClosure() `
            -TestAction {
                param($kit)
                $kit.Context.ClipboardSetter = $clipboardSetter
                $kit.Context.RetryDelay = $retryDelay
                $kit.SplitControls.Copy.PrimaryButton.RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                $wasOpen.Value = $kit.Win.IsVisible
                $wasOpen.Status = $kit.Win.FindName('StatusText').Text
            }.GetNewClosure()
        Should-Be $result 'UserCancelled'
        Should-BeTrue $wasOpen.Value
        Should-Be $attempts.Count 4
        Should-Be (($delays) -join ',') '50,100,200'
        Should-Be $wasOpen.Status 'Clipboard is unavailable'
        Should-Be (($events) -join ',') 'start:CopyAndClose,done:CopyAndClose:False'
    }
}

Describe 'Floating Studio popup policy edge cases' {
    It 'keeps the stock Close button and retires the custom More popup path' {
        $bitmap = [System.Drawing.Bitmap]::new(24,24)
        $shell = $null
        try {
            $context = New-SnipPreviewContext -Bitmap $bitmap `
                -SetWindowPosition { param($hwnd,$bounds) $true }
            $shell = New-SnipPreviewWindow -Context $context
            $close = $shell.Window.FindName('CloseBtn')
            Should-BeTrue ($close -is [System.Windows.Controls.Button])
            Should-Be $close.ReadLocalValue(
                [System.Windows.FrameworkElement]::StyleProperty) `
                ([System.Windows.DependencyProperty]::UnsetValue)
            Should-Be $context.Shell.MoreButton.Visibility `
                ([System.Windows.Visibility]::Collapsed)
            Should-BeFalse $context.Shell.MoreMenu.IsOpen
        } finally {
            if ($null -ne $shell) { $shell.Window.Close() }
            $bitmap.Dispose()
        }
    }
}
Describe 'Task 7 routed Preview close and crop ownership' {
    It 'the final real Escape closes Preview through the single resolver level' {
        $bitmap = [System.Drawing.Bitmap]::new(32,24)
        $observed = @{ Command=$null; Handled=$false; Closed=$false }
        $result = Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::None
            }
            $kit.HighlightLayer.Focus() | Out-Null
            $escape = New-RoutedKeyEvent -Target $kit.HighlightLayer -Key Escape
            $kit.HighlightLayer.RaiseEvent($escape)
            $observed.Command = $kit.CommandRouter.LastCommand
            $observed.Handled = $escape.Handled
            $observed.Closed = -not $kit.Win.IsVisible
        }.GetNewClosure()
        Should-Be $result 'UserCancelled'
        Should-Be $observed.Command 'ClosePreview'
        Should-BeTrue $observed.Handled
        Should-BeTrue $observed.Closed
    }

    It 'real crop UI preserves sources and Preview close disposes the Bitmap exactly once' {
        $bitmap = [System.Drawing.Bitmap]::new(64,48)
        $bitmap.SetPixel(0,0,[System.Drawing.Color]::Fuchsia)
        $observed = @{ Ownership=$null; Source=$null; Pixel=$null }
        $result = Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            $kit.Context.ToolControls.Crop.RaiseEvent(
                [System.Windows.RoutedEventArgs]::new(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $start=[System.Windows.Point]::new(5,5)
            $finish=[System.Windows.Point]::new(50,35)
            $kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
                -Target $kit.HighlightLayer -Position $start `
                -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonDownEvent)))
            $kit.HighlightLayer.RaiseEvent((New-RoutedMouseMoveEvent `
                -Target $kit.HighlightLayer -Position $finish))
            $kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
                -Target $kit.HighlightLayer -Position $finish `
                -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonUpEvent)))
            $applyElement=$kit.Context.PropertyControls.Apply.Element
            $applyEvent=if($applyElement -is [System.Windows.Controls.MenuItem]){
                [System.Windows.Controls.MenuItem]::ClickEvent
            }else{[System.Windows.Controls.Primitives.ButtonBase]::ClickEvent}
            $applyElement.RaiseEvent([System.Windows.RoutedEventArgs]::new($applyEvent))
            Should-BeTrue ([object]::ReferenceEquals($kit.Context.Bitmap,$bitmap))
            Should-BeTrue ([object]::ReferenceEquals(
                $kit.Context.BitmapSource,$kit.PreviewImage.Source))
            Should-BeTrue $kit.Context.BitmapSource.IsFrozen
            Should-Be $kit.Context.Bitmap.GetPixel(0,0).ToArgb() `
                ([System.Drawing.Color]::Fuchsia.ToArgb())
            $observed.Ownership=$kit.OwnershipState
            $observed.Source=$kit.Context.BitmapSource
            $observed.Pixel=$kit.Context.Bitmap.GetPixel(0,0).ToArgb()
        }.GetNewClosure()
        Should-Be $result 'UserCancelled'
        Should-BeTrue ($null -ne $observed.Ownership)
        Should-BeTrue ($null -ne $observed.Ownership.PSObject.Properties['BitmapDisposed'])
        Should-BeTrue $observed.Ownership.BitmapDisposed
        Should-BeTrue $observed.Source.IsFrozen
        Should-Be $observed.Pixel ([System.Drawing.Color]::Fuchsia.ToArgb())
        $disposed=$false
        try { $bitmap.GetPixel(0,0) | Out-Null } catch { $disposed=$true }
        Should-BeTrue $disposed
        Should-BeTrue $observed.Ownership.BitmapDisposed
    }
}

Describe 'Task 7 authoritative annotation draft close cleanup' {
    It 'window close clears one live annotation draft exactly once' {
        $bitmap = [System.Drawing.Bitmap]::new(64,48)
        $observed = @{ Before=$null; After=$null; Context=$null }
        $result = Show-PreviewWindow -Bitmap $bitmap -TestAction {
            param($kit)
            & $kit.BeginDraw 'rect' ([System.Windows.Point]::new(4,5))
            & $kit.UpdateDraw ([System.Windows.Point]::new(30,28))
            Should-BeTrue ($null -ne $kit.Context.Draft)
            $observed.Before = $kit.Context.AnnotationDraftClearCount
            $observed.Context = $kit.Context
            $kit.Win.Close()
            $observed.After = $kit.Context.AnnotationDraftClearCount
        }.GetNewClosure()
        Should-Be $result 'UserCancelled'
        Should-Be $observed.After ($observed.Before + 1)
        Should-Be $observed.Context.Draft $null
        Should-Be $observed.Context.Interaction $null
        Should-BeFalse $observed.Context.EditorState.Drawing
    }
}

# Popup/ContextMenu tests need a fresh top-level Preview. Native WPF popups own
# separate HWND, focus, and dispatcher state that is not fully reset while a
# long-lived Preview fixture remains open.
function Wait-SnipTestDispatcherCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$Condition,
        [Parameter(Mandatory)] [string]$Description,
        [int]$TimeoutMilliseconds = 2000,
        [System.Windows.Threading.DispatcherPriority]$Priority =
            [System.Windows.Threading.DispatcherPriority]::Background
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{}, $Priority)
        if (& $Condition) { return }
        if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw "Timed out waiting for $Description after $TimeoutMilliseconds ms"
        }
    }
}

function New-SnipPreviewTestDrivers {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Kit)

    $raiseClick = {
        param([System.Windows.Controls.Primitives.ButtonBase]$Button)
        $Button.RaiseEvent([System.Windows.RoutedEventArgs]::new(
            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }.GetNewClosure()
    $raiseMenuClick = {
        param([System.Windows.Controls.MenuItem]$Item)
        $Item.RaiseEvent([System.Windows.RoutedEventArgs]::new(
            [System.Windows.Controls.MenuItem]::ClickEvent))
    }.GetNewClosure()
    $raiseCanvasDown = {
        param([System.Windows.Point]$Point)
        $Kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
            -Target $Kit.HighlightLayer -Position $Point `
            -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonDownEvent)))
    }.GetNewClosure()
    $raiseCanvasMove = {
        param([System.Windows.Point]$Point)
        $Kit.HighlightLayer.RaiseEvent((New-RoutedMouseMoveEvent `
            -Target $Kit.HighlightLayer -Position $Point))
    }.GetNewClosure()
    $raiseCanvasUp = {
        param([System.Windows.Point]$Point)
        $Kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
            -Target $Kit.HighlightLayer -Position $Point `
            -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonUpEvent)))
    }.GetNewClosure()
    $raiseCanvasClick = {
        param([System.Windows.Point]$Point)
        & $raiseCanvasDown $Point
        & $raiseCanvasUp $Point
    }.GetNewClosure()
    $raiseCanvasDrag = {
        param(
            [System.Windows.Point]$Start,
            [System.Windows.Point[]]$Moves,
            [System.Windows.Point]$End
        )
        & $raiseCanvasDown $Start
        foreach ($point in @($Moves)) { & $raiseCanvasMove $point }
        & $raiseCanvasUp $End
    }.GetNewClosure()
    $raiseCanvasKey = {
        param([System.Windows.Input.Key]$Key)
        $Kit.HighlightLayer.Focus() | Out-Null
        $eventArgs = New-RoutedKeyEvent -Target $Kit.HighlightLayer -Key $Key
        $Kit.HighlightLayer.RaiseEvent($eventArgs)
        $eventArgs
    }.GetNewClosure()
    $raiseControlKey = {
        param(
            [System.Windows.IInputElement]$Target,
            [System.Windows.Input.Key]$Key
        )
        $preview = New-RoutedKeyEvent -Target $Target -Key $Key
        $Target.RaiseEvent($preview)
        if ($preview.Handled) { return $preview }
        $bubble = New-RoutedKeyEvent -Target $Target -Key $Key `
            -RoutedEvent ([System.Windows.Input.Keyboard]::KeyDownEvent)
        $Target.RaiseEvent($bubble)
        $bubble
    }.GetNewClosure()
    $invokeAutomation = {
        param([System.Windows.UIElement]$Element)
        $peer = if ($Element -is [System.Windows.Controls.MenuItem]) {
            [System.Windows.Automation.Peers.MenuItemAutomationPeer]::new($Element)
        } else {
            [System.Windows.Automation.Peers.ButtonAutomationPeer]::new($Element)
        }
        $provider = $peer.GetPattern(
            [System.Windows.Automation.Peers.PatternInterface]::Invoke)
        if ($provider -isnot [System.Windows.Automation.Provider.IInvokeProvider]) {
            throw "$($Element.GetType().Name) does not expose InvokeProvider"
        }
        ([System.Windows.Automation.Provider.IInvokeProvider]$provider).Invoke()
    }.GetNewClosure()
    $expandMenuItem = {
        param([System.Windows.Controls.MenuItem]$Item)
        $peer = [System.Windows.Automation.Peers.MenuItemAutomationPeer]::new($Item)
        $provider = $peer.GetPattern(
            [System.Windows.Automation.Peers.PatternInterface]::ExpandCollapse)
        if ($provider -isnot [System.Windows.Automation.Provider.IExpandCollapseProvider]) {
            throw 'MenuItem does not expose ExpandCollapseProvider'
        }
        ([System.Windows.Automation.Provider.IExpandCollapseProvider]$provider).Expand()
    }.GetNewClosure()
    $activateTool = {
        param([string]$Tool)
        switch ($Tool) {
            'RectangleEllipse' {
                & $raiseClick $Kit.SplitControls.RectangleEllipse.PrimaryButton
            }
            'ArrowLine' {
                & $raiseClick $Kit.SplitControls.ArrowLine.PrimaryButton
            }
            default {
                $control = $Kit.Context.ToolControls[$Tool]
                if ($control -is [System.Windows.Controls.Primitives.ToggleButton]) {
                    $peer = [System.Windows.Automation.Peers.ToggleButtonAutomationPeer]::new(
                        $control)
                    $provider = $peer.GetPattern(
                        [System.Windows.Automation.Peers.PatternInterface]::Toggle)
                    ([System.Windows.Automation.Provider.IToggleProvider]$provider).Toggle()
                } else {
                    & $raiseClick $control
                }
            }
        }
    }.GetNewClosure()
    $drawRectangle = {
        param([System.Windows.Point]$Start,[System.Windows.Point]$End)
        & $activateTool 'RectangleEllipse'
        & $raiseCanvasDrag $Start @($End) $End
    }.GetNewClosure()
    $clearCanvasContent = {
        & $Kit.SetZoom 1.0
        $Kit.Scroller.ScrollToHorizontalOffset(0)
        $Kit.Scroller.ScrollToVerticalOffset(0)
        if ($Kit.State.Annotations.Count -gt 0) {
            & $raiseClick ($Kit.Win.FindName('ClearBtn'))
        }
        & $activateTool 'Select'
        & $raiseCanvasClick ([System.Windows.Point]::new(1100,740))
    }.GetNewClosure()
    $invokePropertyEntry = {
        param($Entry)
        if ($Entry.Element -is [System.Windows.Controls.MenuItem]) {
            & $raiseMenuClick $Entry.Element
        } else {
            & $raiseClick $Entry.Element
        }
    }.GetNewClosure()
    $selectAspect = {
        param([System.Windows.Controls.MenuItem]$Item,[string]$Description)
        $controller = $Kit.Context.CropAspectMenuControl
        & $raiseClick $Kit.Context.PropertyControls.Aspect.Button
        Wait-SnipTestDispatcherCondition -Description "$Description opening" `
            -Condition {
                $controller.State.IsExpanded -and
                $controller.State.IsMenuWindowRegistered -and
                $null -ne [System.Windows.PresentationSource]::FromVisual($Item)
            }.GetNewClosure()
        & $raiseMenuClick $Item
        Wait-SnipTestDispatcherCondition -Description "$Description closure" `
            -Condition {
                -not $controller.State.IsExpanded -and
                -not $controller.State.IsMenuWindowRegistered
            }.GetNewClosure()
    }.GetNewClosure()
    [pscustomobject]@{
        RaiseClick = $raiseClick
        RaiseMenuClick = $raiseMenuClick
        RaiseCanvasDown = $raiseCanvasDown
        RaiseCanvasMove = $raiseCanvasMove
        RaiseCanvasUp = $raiseCanvasUp
        RaiseCanvasClick = $raiseCanvasClick
        RaiseCanvasDrag = $raiseCanvasDrag
        RaiseCanvasKey = $raiseCanvasKey
        RaiseControlKey = $raiseControlKey
        InvokeAutomation = $invokeAutomation
        ExpandMenuItem = $expandMenuItem
        ActivateTool = $activateTool
        DrawRectangle = $drawRectangle
        ClearCanvasContent = $clearCanvasContent
        InvokePropertyEntry = $invokePropertyEntry
        SelectAspect = $selectAspect
    }
}

function Invoke-SnipFreshPreviewFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock]$TestAction)

    $bitmap = [System.Drawing.Bitmap]::new(1200,800)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::SlateBlue)
        $graphics.FillRectangle([System.Drawing.Brushes]::Orange,100,100,400,300)
        $graphics.FillRectangle([System.Drawing.Brushes]::Lime,700,500,300,200)
    } finally {
        $graphics.Dispose()
    }

    $invoked = @{ Value=$false }
    $ownershipAccepted = @{ Value=$false }
    try {
        $result = Show-PreviewWindow -Bitmap $bitmap -OnOwnershipAccepted {
            $ownershipAccepted.Value = $true
        }.GetNewClosure() -TestAction {
            param($kit)
            $invoked.Value = $true
            $drivers = New-SnipPreviewTestDrivers -Kit $kit
            & $TestAction $kit $drivers
        }.GetNewClosure()
    } finally {
        if (-not $ownershipAccepted.Value) { $bitmap.Dispose() }
    }

    Should-BeTrue $invoked.Value
    Should-BeTrue $ownershipAccepted.Value
    Should-Be $result 'UserCancelled'
}

Describe 'Floating Studio isolated popup fixtures' {
    It 'routes Alt Down from each native split region and restores the actual opener focus' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            $split = $kit.SplitControls.Copy
            Should-BeTrue ($split.PrimaryButton -is [System.Windows.Controls.Button])
            Should-BeTrue ($split.OptionsButton -is [System.Windows.Controls.Button])
            Should-BeFalse ($split.PrimaryButton -eq $split.OptionsButton)
            Should-BeTrue $split.PrimaryButton.IsTabStop
            Should-BeTrue $split.OptionsButton.IsTabStop
            Should-Be ([System.Windows.Automation.AutomationProperties]::GetName(
                $split.PrimaryButton)) 'Copy and close'
            Should-Be ([System.Windows.Automation.AutomationProperties]::GetName(
                $split.OptionsButton)) 'Copy options'
            Should-BeTrue $split.State.HandlersAttached

            foreach ($opener in @($split.PrimaryButton,$split.OptionsButton)) {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::Alt
                }
                $opener.Focus() | Out-Null
                $openEvent = New-RoutedKeyEvent -Target $opener -Key Down
                $opener.RaiseEvent($openEvent)
                Wait-SnipTestDispatcherCondition -Description 'split menu expansion' `
                    -Condition { $split.State.IsExpanded }.GetNewClosure()
                Should-BeTrue $openEvent.Handled
                Should-BeTrue ([object]::ReferenceEquals(
                    $split.State.LastOpener,$opener))
                Should-Be ([System.Windows.Automation.AutomationProperties]::GetItemStatus(
                    $split.OptionsButton)) 'Expanded'

                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $closeEvent = New-RoutedKeyEvent -Target $opener -Key Escape
                $opener.RaiseEvent($closeEvent)
                Wait-SnipTestDispatcherCondition -Description 'split menu closure and focus restoration' `
                    -Condition {
                        -not $split.State.IsExpanded -and $opener.IsKeyboardFocused
                    }.GetNewClosure()
                Should-BeTrue $closeEvent.Handled
                Should-Be ([System.Windows.Automation.AutomationProperties]::GetItemStatus(
                    $split.OptionsButton)) 'Collapsed'
            }
        }
    }

    It 'registers split menu HWNDs and closes transient menus before capture' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            $split = $kit.SplitControls.Copy
            & $split.OpenOptions
            Wait-SnipTestDispatcherCondition -Description 'split menu HWND registration' `
                -Condition {
                    $split.State.IsExpanded -and
                    $split.State.MenuHandle -ne [IntPtr]::Zero -and
                    $split.State.IsMenuWindowRegistered
                }.GetNewClosure()
            & $kit.CommandRouter.CloseTransientMenus
            Wait-SnipTestDispatcherCondition -Description 'split menu HWND unregistration' `
                -Condition {
                    -not $split.State.IsExpanded -and
                    -not $split.State.IsMenuWindowRegistered
                }.GetNewClosure()
        }
    }

    It 'routes Escape from an open More popup and restores the More opener focus' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
                Type='Bounds'; X=80; Y=60; Width=120; Height=90
            }) -Color Red -StrokeWidth 3 -Opacity 1 -Properties ([ordered]@{}) -Z 1
            $kit.Context.Annotations.Add($annotation) | Out-Null
            & $kit.Render
            & $kit.SetSelectedAnnotation $annotation.Id
            $selectedId = $kit.Context.SelectedAnnotationId
            $moreButton = $kit.Context.Shell.MoreButton
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::Alt
            }
            $moreButton.Focus() | Out-Null
            $openEvent = New-RoutedKeyEvent -Target $moreButton -Key Down
            $moreButton.RaiseEvent($openEvent)
            $menuItem = $kit.Context.Shell.MoreMenuItems.Highlight
            Wait-SnipTestDispatcherCondition -Description 'More popup source before Escape' `
                -Condition {
                    $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    $kit.Context.Shell.MoreMenuState.IsMenuWindowRegistered -and
                    $null -ne [System.Windows.PresentationSource]::FromVisual($menuItem)
                }.GetNewClosure()
            try {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $menuItem.Focus() | Out-Null
                $resolveBefore = $kit.Context.CommandRouter.ResolveCount
                $escape = New-RoutedKeyEvent -Target $menuItem -Key Escape
                $menuItem.RaiseEvent($escape)
                Wait-SnipTestDispatcherCondition `
                    -Description 'More popup closure and focus restoration after Escape' `
                    -Condition {
                        -not $kit.Context.Shell.MoreMenuState.IsExpanded -and
                        $moreButton.IsKeyboardFocused
                    }.GetNewClosure()
                Should-Be $kit.Context.CommandRouter.ResolveCount ($resolveBefore + 1)
                Should-Be $kit.Context.CommandRouter.LastCommand 'ClosePopup'
                Should-BeTrue $escape.Handled
                Should-Be $kit.Context.SelectedAnnotationId $selectedId
            } finally {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $kit.CommandRouter.CloseTransientMenus
            }
        }
    }

    It 'keeps Delete from an open More popup out of the selected canvas record' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
                Type='Bounds'; X=80; Y=60; Width=120; Height=90
            }) -Color Blue -StrokeWidth 3 -Opacity 1 -Properties ([ordered]@{}) -Z 1
            $kit.Context.Annotations.Add($annotation) | Out-Null
            & $kit.Render
            & $kit.SetSelectedAnnotation $annotation.Id
            $moreButton = $kit.Context.Shell.MoreButton
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::Alt
            }
            $moreButton.Focus() | Out-Null
            $openEvent = New-RoutedKeyEvent -Target $moreButton -Key Down
            $moreButton.RaiseEvent($openEvent)
            $menuItem = $kit.Context.Shell.MoreMenuItems.Highlight
            Wait-SnipTestDispatcherCondition -Description 'More popup source before Delete' `
                -Condition {
                    $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    $kit.Context.Shell.MoreMenuState.IsMenuWindowRegistered -and
                    $null -ne [System.Windows.PresentationSource]::FromVisual($menuItem)
                }.GetNewClosure()
            try {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $menuItem.Focus() | Out-Null
                $delete = New-RoutedKeyEvent -Target $menuItem -Key Delete
                $menuItem.RaiseEvent($delete)
                Should-BeFalse $delete.Handled
                Should-Be (@($kit.Context.Annotations | Where-Object Id -eq $annotation.Id)).Count 1
                Should-Be $kit.Context.SelectedAnnotationId $annotation.Id
            } finally {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $kit.CommandRouter.CloseTransientMenus
            }
        }
    }

    It 'uses native root and nested More popups' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $moreMenu = $kit.Context.Shell.MoreMenu
            Should-Be $moreMenu.ReadLocalValue(
                [System.Windows.FrameworkElement]::StyleProperty) `
                ([System.Windows.DependencyProperty]::UnsetValue)
            foreach ($item in @($moreMenu.Items)) {
                Should-Be $item.ReadLocalValue(
                    [System.Windows.FrameworkElement]::StyleProperty) `
                    ([System.Windows.DependencyProperty]::UnsetValue)
            }

            $colorParent = $kit.Context.Shell.MoreMenuItems.Color
            foreach ($colorItem in @($colorParent.Items)) {
                Should-Be $colorItem.ReadLocalValue(
                    [System.Windows.FrameworkElement]::StyleProperty) `
                    ([System.Windows.DependencyProperty]::UnsetValue)
            }
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::Alt
            }
            $moreButton = $kit.Context.Shell.MoreButton
            $moreButton.Focus() | Out-Null
            $moreButton.RaiseEvent((New-RoutedKeyEvent -Target $moreButton -Key Down))
            Wait-SnipTestDispatcherCondition -Description 'More menu expansion' `
                -Condition { $kit.Context.Shell.MoreMenuState.IsExpanded }.GetNewClosure()
            try {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $drivers.ExpandMenuItem $colorParent
                Wait-SnipTestDispatcherCondition -Description 'More Color submenu visual' `
                    -Priority Render -Condition {
                        $popup = $colorParent.Template.FindName('PART_Popup',$colorParent)
                        $colorParent.IsSubmenuOpen -and $null -ne $popup -and
                        $null -ne $popup.Child
                    }.GetNewClosure()
                $popup = $colorParent.Template.FindName('PART_Popup',$colorParent)
                Should-BeTrue $colorParent.IsSubmenuOpen
                Should-BeTrue ($null -ne $popup.Child)
                Should-Be $popup.Child.Child.VerticalScrollBarVisibility `
                    ([System.Windows.Controls.ScrollBarVisibility]::Auto)
                Should-Be $popup.Child.Child.HorizontalScrollBarVisibility `
                    ([System.Windows.Controls.ScrollBarVisibility]::Hidden)
            } finally {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $kit.CommandRouter.CloseTransientMenus
            }
        }
    }

    It 'registers actual nested popup HWNDs and recursively closes them before capture' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $moreButton = $kit.Context.Shell.MoreButton
            & $drivers.InvokeAutomation $moreButton
            Wait-SnipTestDispatcherCondition -Description 'More menu HWND registration' `
                -Condition {
                    $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    $kit.Context.Shell.MoreMenuState.IsMenuWindowRegistered
                }.GetNewClosure()
            $colorParent = $kit.Context.Shell.MoreMenuItems.Color
            & $drivers.ExpandMenuItem $colorParent
            Wait-SnipTestDispatcherCondition -Description 'nested Color popup HWND registration' `
                -Priority Render -Condition {
                    $popup = $colorParent.Template.FindName('PART_Popup',$colorParent)
                    if ($null -eq $popup -or $null -eq $popup.Child) { return $false }
                    $source = [System.Windows.PresentationSource]::FromVisual($popup.Child)
                    $source -is [System.Windows.Interop.HwndSource] -and
                    $popup.Tag.IsRegistered
                }.GetNewClosure()
            $popup = $colorParent.Template.FindName('PART_Popup',$colorParent)
            $nestedSource = [System.Windows.PresentationSource]::FromVisual($popup.Child)
            $nestedHandle = $nestedSource.Handle
            $rootHandle = $kit.Context.Shell.MoreMenuState.MenuHandle
            Should-BeTrue ($rootHandle -ne [IntPtr]::Zero)
            Should-BeTrue ($nestedHandle -ne [IntPtr]::Zero)
            Should-BeTrue $script:SelfWindowHandles.Contains($rootHandle)
            Should-BeTrue $script:SelfWindowHandles.Contains($nestedHandle)

            $hidden = Hide-OwnSnipITWindowsForCapture
            try {
                Wait-SnipTestDispatcherCondition -Description 'recursive popup HWND cleanup' `
                    -Condition {
                        -not $colorParent.IsSubmenuOpen -and
                        -not $kit.Context.Shell.MoreMenuState.IsExpanded -and
                        -not $popup.Tag.IsRegistered -and
                        -not $script:SelfWindowHandles.Contains($rootHandle) -and
                        -not $script:SelfWindowHandles.Contains($nestedHandle)
                    }.GetNewClosure()
                & $kit.CommandRouter.CloseTransientMenus
                Should-BeFalse $colorParent.IsSubmenuOpen
                Should-BeFalse $popup.Tag.IsRegistered
            } finally {
                Show-OwnSnipITWindowsForCapture -Handles $hidden
            }
        }
    }

    It 'uses a native edge-constrained scrollbar and exposes checked disabled menu state' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $menu = $kit.Context.Shell.MoreMenu
            $highlightItem = $kit.Context.Shell.MoreMenuItems.Highlight
            $redItem = $kit.Context.Shell.MoreColorMenuItems.Red
            $savedMaxHeight = $menu.MaxHeight
            try {
                $highlightItem.IsCheckable = $true
                $highlightItem.IsChecked = $true
                $redItem.IsEnabled = $false
                $menu.MaxHeight = 72
                & $drivers.InvokeAutomation $kit.Context.Shell.MoreButton
                Wait-SnipTestDispatcherCondition -Description 'constrained More menu scrollbar' `
                    -Priority Render -Condition {
                        if (-not $menu.IsOpen) { return $false }
                        $source = [System.Windows.PresentationSource]::FromVisual($menu)
                        $null -ne $source -and $null -ne (Find-VisualDescendant `
                            -Root $source.RootVisual `
                            -Type ([System.Windows.Controls.Primitives.ScrollBar]))
                    }.GetNewClosure()

                $source = [System.Windows.PresentationSource]::FromVisual($menu)
                $scrollBar = Find-VisualDescendant -Root $source.RootVisual `
                    -Type ([System.Windows.Controls.Primitives.ScrollBar])
                Should-BeTrue ($null -ne $scrollBar)
                Should-Be $scrollBar.ReadLocalValue(
                    [System.Windows.FrameworkElement]::StyleProperty) `
                    ([System.Windows.DependencyProperty]::UnsetValue)

                $checkedPeer = [System.Windows.Automation.Peers.MenuItemAutomationPeer]::new(
                    $highlightItem)
                $toggle = $checkedPeer.GetPattern(
                    [System.Windows.Automation.Peers.PatternInterface]::Toggle)
                if ($toggle -isnot [System.Windows.Automation.Provider.IToggleProvider]) {
                    throw 'Checked MenuItem does not expose ToggleProvider'
                }
                Should-Be $toggle.ToggleState ([System.Windows.Automation.ToggleState]::On)

                $colorParent = $kit.Context.Shell.MoreMenuItems.Color
                & $drivers.ExpandMenuItem $colorParent
                Wait-SnipTestDispatcherCondition -Description 'disabled Color menu item rendering' `
                    -Priority Render -Condition { $colorParent.IsSubmenuOpen }.GetNewClosure()
                Should-BeFalse ($redItem.Focus())
                $disabledPeer = [System.Windows.Automation.Peers.MenuItemAutomationPeer]::new(
                    $redItem)
                Should-BeFalse $disabledPeer.IsEnabled()
                Should-Be $disabledPeer.GetName() 'Red'
            } finally {
                $highlightItem.IsChecked = $false
                $highlightItem.IsCheckable = $false
                $redItem.IsEnabled = $true
                $menu.MaxHeight = $savedMaxHeight
                & $kit.CommandRouter.CloseTransientMenus
            }
        }
    }

    It 'keeps every Narrow secondary tool reachable through a native More menu' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $moreButton = $kit.Context.Shell.MoreButton
            $moreMenu = $kit.Context.Shell.MoreMenu
            Should-BeTrue ($moreMenu -is [System.Windows.Controls.ContextMenu])
            $visibleHeaders = @($moreMenu.Items | Where-Object Visibility -eq Visible |
                ForEach-Object Header)
            Should-Be ($visibleHeaders -join ',') `
                'Highlight,Arrow/Line,Rectangle/Ellipse,Steps,Color'
            & $drivers.InvokeAutomation $moreButton
            Wait-SnipTestDispatcherCondition -Description 'Narrow More menu registration' `
                -Condition {
                    $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    $kit.Context.Shell.MoreMenuState.IsMenuWindowRegistered
                }.GetNewClosure()
            Should-Be ([System.Windows.Automation.AutomationProperties]::GetItemStatus(
                $moreButton)) 'Expanded'
            & $kit.CommandRouter.CloseTransientMenus
            Wait-SnipTestDispatcherCondition -Description 'Narrow More menu cleanup' `
                -Condition {
                    -not $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    -not $kit.Context.Shell.MoreMenuState.IsMenuWindowRegistered
                }.GetNewClosure()
            Should-Be ([System.Windows.Automation.AutomationProperties]::GetItemStatus(
                $moreButton)) 'Collapsed'
        }
    }

    It 'keeps all annotation colors reachable from the Color tool' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            $colorButton = $kit.Context.ToolControls.Color
            $menu = $colorButton.ContextMenu
            Should-BeTrue ($menu -is [System.Windows.Controls.ContextMenu])
            Should-Be (($menu.Items | ForEach-Object Header) -join ',') `
                'Yellow,Green,Pink,Blue,Orange,Red'
            & $drivers.InvokeAutomation $colorButton
            Wait-SnipTestDispatcherCondition -Description 'Color tool menu opening' `
                -Condition { $menu.IsOpen }.GetNewClosure()
            & $drivers.InvokeAutomation $menu.Items[-1]
            Wait-SnipTestDispatcherCondition -Description 'Color menu selection and closure' `
                -Condition { $kit.State.ActiveColor -eq 'Red' -and -not $menu.IsOpen }.GetNewClosure()
        }
    }

    It 'tracks and capture-closes the actual annotation right-click popup idempotently' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            $hidden = $null
            try {
                $kit.State.Annotations.Clear()
                $kit.State.Annotations.Add((New-SnipAnnotation -Kind Highlight `
                    -Geometry ([pscustomobject]@{
                        Type='Bounds'; X=0; Y=0
                        Width=$kit.Bitmap.Width; Height=$kit.Bitmap.Height
                    }) -Color Yellow -StrokeWidth 4 -Opacity 0.45 `
                    -Properties ([ordered]@{}) -Z 0)) | Out-Null
                & $kit.Render
                $rightClick = New-RoutedMouseRightClick -Target $kit.HighlightLayer `
                    -Position ([System.Windows.Point]::new(40,40))
                $kit.HighlightLayer.RaiseEvent($rightClick)
                Wait-SnipTestDispatcherCondition -Description 'annotation right-click popup registration' `
                    -Condition {
                        if ($null -eq $kit.Context.PSObject.Properties[
                            'AnnotationMenuControl']) { return $false }
                        $control = $kit.Context.AnnotationMenuControl
                        $null -ne $control -and $control.Menu.IsOpen -and
                        $kit.Context.TransientMenus.Contains($control) -and
                        $control.State.MenuHandle -ne [IntPtr]::Zero -and
                        $script:SelfWindowHandles.Contains($control.State.MenuHandle)
                    }.GetNewClosure()
                Should-BeTrue $rightClick.Handled
                $control = $kit.Context.AnnotationMenuControl
                $annotationHandle = $control.State.MenuHandle
                $hidden = Hide-OwnSnipITWindowsForCapture
                Wait-SnipTestDispatcherCondition -Description 'annotation popup capture cleanup' `
                    -Condition {
                        -not $control.Menu.IsOpen -and
                        -not $control.State.IsMenuWindowRegistered -and
                        -not $script:SelfWindowHandles.Contains($annotationHandle)
                    }.GetNewClosure()
                & $kit.CommandRouter.CloseTransientMenus
                Should-BeFalse $control.Menu.IsOpen
                Should-BeFalse $control.State.IsMenuWindowRegistered
            } finally {
                if ($null -ne $hidden) {
                    Show-OwnSnipITWindowsForCapture -Handles $hidden
                }
                $kit.State.Annotations.Clear()
                & $kit.Render
            }
        }
    }

    It 'opens Narrow More Color by keyboard and returns focus after choosing a color' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 760 540
            $moreButton = $kit.Context.Shell.MoreButton
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::Alt
            }
            $moreButton.Focus() | Out-Null
            $openMore = New-RoutedKeyEvent -Target $moreButton -Key Down
            $moreButton.RaiseEvent($openMore)
            Wait-SnipTestDispatcherCondition -Description 'keyboard-opened Narrow More menu' `
                -Condition {
                    $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    [System.Windows.Input.Keyboard]::FocusedElement -is
                        [System.Windows.Controls.MenuItem]
                }.GetNewClosure()
            Should-BeTrue $openMore.Handled

            $colorParent = $kit.Context.Shell.MoreMenuItems.Color
            Should-Be $colorParent.Items.Count 6
            Should-Be (($colorParent.Items | ForEach-Object Header) -join ',') `
                'Yellow,Green,Pink,Blue,Orange,Red'
            $kit.Context.GetKeyboardModifiers = {
                [System.Windows.Input.ModifierKeys]::None
            }
            $rootOrigin = [System.Windows.Input.Keyboard]::FocusedElement
            $resolveBeforeEnd = $kit.Context.CommandRouter.ResolveCount
            $endRoot = & $drivers.RaiseControlKey $rootOrigin `
                ([System.Windows.Input.Key]::End)
            Wait-SnipTestDispatcherCondition -Description 'native focus on More Color item' `
                -Condition {
                    [object]::ReferenceEquals(
                        [System.Windows.Input.Keyboard]::FocusedElement,$colorParent)
                }.GetNewClosure()
            Should-Be $kit.Context.CommandRouter.ResolveCount ($resolveBeforeEnd + 1)
            Should-Be $kit.Context.CommandRouter.LastCommand 'PopupNavigation'
            Should-BeFalse $endRoot.Handled

            $resolveBeforeColors = $kit.Context.CommandRouter.ResolveCount
            $openColors = & $drivers.RaiseControlKey $colorParent `
                ([System.Windows.Input.Key]::Right)
            Wait-SnipTestDispatcherCondition -Description 'native More Color submenu navigation' `
                -Priority Render -Condition {
                    $colorParent.IsSubmenuOpen -and
                    [System.Windows.Input.Keyboard]::FocusedElement -is
                        [System.Windows.Controls.MenuItem] -and
                    $colorParent.Items.Contains(
                        [System.Windows.Input.Keyboard]::FocusedElement)
                }.GetNewClosure()
            Should-Be $kit.Context.CommandRouter.ResolveCount ($resolveBeforeColors + 1)
            Should-Be $kit.Context.CommandRouter.LastCommand 'PopupNavigation'
            Should-BeFalse $openColors.Handled

            $redItem = $colorParent.Items[-1]
            $submenuOrigin = [System.Windows.Input.Keyboard]::FocusedElement
            $resolveBeforeRedFocus = $kit.Context.CommandRouter.ResolveCount
            $endColors = & $drivers.RaiseControlKey $submenuOrigin `
                ([System.Windows.Input.Key]::End)
            Wait-SnipTestDispatcherCondition -Description 'native focus on Red menu item' `
                -Condition {
                    [object]::ReferenceEquals(
                        [System.Windows.Input.Keyboard]::FocusedElement,$redItem)
                }.GetNewClosure()
            Should-Be $kit.Context.CommandRouter.ResolveCount ($resolveBeforeRedFocus + 1)
            Should-BeFalse $endColors.Handled

            $resolveBeforeRed = $kit.Context.CommandRouter.ResolveCount
            $chooseRed = & $drivers.RaiseControlKey $redItem `
                ([System.Windows.Input.Key]::Enter)
            Wait-SnipTestDispatcherCondition -Description 'Red selection closure and opener focus' `
                -Condition {
                    $kit.State.ActiveColor -eq 'Red' -and
                    -not $kit.Context.Shell.MoreMenuState.IsExpanded -and
                    $moreButton.IsKeyboardFocused
                }.GetNewClosure()
            Should-Be $kit.Context.CommandRouter.ResolveCount ($resolveBeforeRed + 1)
            Should-Be $kit.Context.CommandRouter.LastCommand 'PopupNavigation'
            Should-BeFalse $chooseRed.Handled
        }
    }

    It 'renders property values with real editors instead of bare captions' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 1200 700
            & $kit.SetPropertyIsland 'RectangleEllipse'
            $controls = $kit.Context.PropertyControls
            # Every historical key still resolves, so existing routes keep working.
            foreach ($name in @('StrokeColor','Fill','Width','Opacity')) {
                Should-BeTrue $controls.Contains($name)
                Should-BeTrue ($null -ne $controls[$name].Element)
            }
            # Colour is a swatch button, not a word.
            Should-BeTrue ($controls.StrokeColor.Element -is
                [System.Windows.Controls.Button])
            Should-BeTrue ($controls.StrokeColor.Swatch -is
                [System.Windows.Controls.Border])
            Should-Be $controls.StrokeColor.Swatch.Background.Color.ToString() `
                ([string]$kit.Context.ActiveColorHex)
            # Width is a numeric editor with a stepper beside it.
            Should-BeTrue ($controls.Width.Element -is [System.Windows.Controls.TextBox])
            Should-Be $controls.Width.Element.Text `
                ('{0:0.##}' -f [double]$kit.Context.ToolProperties.RectangleEllipse.Width)
            $steppers = @($controls.Width.Element.Parent.Children |
                Where-Object { $_ -is [System.Windows.Controls.StackPanel] })
            Should-Be $steppers.Count 1
            Should-Be @($steppers[0].Children |
                Where-Object { $_ -is
                    [System.Windows.Controls.Primitives.RepeatButton] }).Count 2
            # Opacity is a slider that shows its own percentage.
            Should-BeTrue ($controls.Opacity.Element -is [System.Windows.Controls.Slider])
            Should-Be $controls.Opacity.Element.Minimum 0.0
            Should-Be $controls.Opacity.Element.Maximum 100.0
            Should-Be $controls.Opacity.Element.Value 100.0
            $percent = @($controls.Opacity.Element.Parent.Children |
                Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and
                    $_.Text -match '%$' })
            Should-Be $percent.Count 1
            Should-Be $percent[0].Text '100%'
            # Fill states which way it is set.
            Should-BeTrue ($controls.Fill.Element -is
                [System.Windows.Controls.Primitives.ToggleButton])
            Should-Be $controls.Fill.Element.Content 'Fill  Off'
            # The row names its subject.
            $badge = $kit.Context.Shell.PropertyPanel.Children[0]
            Should-BeTrue ($badge -is [System.Windows.Controls.TextBlock])
            Should-Be $badge.Text 'Rectangle/Ellipse'
        }
    }

    It 'round-trips property-row edits through the tool property state' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            $raiseClick = $drivers.RaiseClick
            & $kit.SetResponsiveMode 1200 700
            & $kit.SetPropertyIsland 'ArrowLine'
            $state = $kit.Context.ToolProperties.ArrowLine
            Should-Be $state.Width 4.0

            $stepper = @($kit.Context.PropertyControls.Width.Element.Parent.Children |
                Where-Object { $_ -is [System.Windows.Controls.StackPanel] })[0]
            & $raiseClick $stepper.Children[0]
            Should-Be $state.Width 5.0
            Should-Be $kit.Context.PropertyControls.Width.Element.Text '5'
            & $raiseClick $stepper.Children[1]
            Should-Be $state.Width 4.0

            $kit.Context.PropertyControls.Opacity.Element.Value = 60
            Should-Be ([math]::Round($state.Opacity, 2)) 0.6

            # The value survives a row rebuild.
            & $kit.SetPropertyIsland 'Highlight'
            & $kit.SetPropertyIsland 'ArrowLine'
            Should-Be $kit.Context.PropertyControls.Opacity.Element.Value 60.0
        }
    }

    It 'repaints the property swatch when the active colour changes' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetResponsiveMode 1200 700
            & $kit.SetPropertyIsland 'Highlight'
            & $kit.PickColor 'Red'
            Should-Be $kit.Context.ActiveColor 'Red'
            Should-Be $kit.Context.PropertyControls.Color.Swatch.Background.Color.ToString() `
                '#FFFF3C3C'
        }
    }

    It 'preserves ordered Arrow and Line properties through More Properties overflow' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            & $kit.SetPropertyIsland 'ArrowLine'
            & $kit.SetResponsiveMode 1200 700
            Should-Be (($kit.PropertyState.Visible) -join ',') `
                'Color,Width,Opacity,StartStyle,EndStyle'
            Should-Be (($kit.PropertyState.Overflow) -join ',') ''
            & $kit.SetResponsiveMode 760 540
            Should-Be (($kit.PropertyState.Visible) -join ',') 'Color,Width,MoreProperties'
            Should-Be (($kit.PropertyState.Overflow) -join ',') 'Opacity,StartStyle,EndStyle'
            Should-Be $kit.PropertyState.HorizontalScrollBarVisibility `
                ([System.Windows.Controls.ScrollBarVisibility]::Disabled)
            $moreProperties = @($kit.Context.Shell.PropertyPanel.Children |
                Where-Object Content -eq 'More properties')[0]
            Should-BeTrue ($moreProperties.ContextMenu -is
                [System.Windows.Controls.ContextMenu])
            Should-Be (($moreProperties.ContextMenu.Items |
                ForEach-Object Header) -join ',') 'Opacity,Start,End'
        }
    }

    It 'disconnects replaced property menus across repeated responsive rebuilds' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit,$drivers)
            $replaced = [System.Collections.ArrayList]::new()
            $failures = [System.Collections.ArrayList]::new()
            try {
                & $kit.SetResponsiveMode 1200 700
                & $kit.SetPropertyIsland 'Select'
                $baselineCount = $kit.Context.TransientMenus.Count

                foreach ($case in @(
                    [pscustomobject]@{ Width=760;  Height=540; Tool='ArrowLine' },
                    [pscustomobject]@{ Width=900;  Height=600; Tool='RectangleEllipse' },
                    [pscustomobject]@{ Width=1200; Height=700; Tool='Steps' },
                    [pscustomobject]@{ Width=760;  Height=540; Tool='BlurPixelate' },
                    [pscustomobject]@{ Width=900;  Height=600; Tool='Text' },
                    [pscustomobject]@{ Width=1200; Height=700; Tool='Highlight' })) {
                    $beforeResponsive = $kit.Context.PropertyMenuControl
                    & $kit.SetResponsiveMode $case.Width $case.Height
                    if ($null -ne $beforeResponsive) {
                        $replaced.Add($beforeResponsive) | Out-Null
                    }
                    $expectedCount = $baselineCount +
                        [int]($null -ne $kit.Context.PropertyMenuControl)
                    Should-Be $kit.Context.TransientMenus.Count $expectedCount

                    $beforeProperty = $kit.Context.PropertyMenuControl
                    & $kit.SetPropertyIsland $case.Tool
                    if ($null -ne $beforeProperty) {
                        $replaced.Add($beforeProperty) | Out-Null
                    }
                    $expectedCount = $baselineCount +
                        [int]($null -ne $kit.Context.PropertyMenuControl)
                    Should-Be $kit.Context.TransientMenus.Count $expectedCount
                    Should-Be @($kit.Context.TransientMenus |
                        Where-Object Name -eq 'MoreProperties').Count `
                        ([int]($null -ne $kit.Context.PropertyMenuControl))
                }

                Should-BeTrue ($replaced.Count -ge 6)
                for ($index = 0; $index -lt $replaced.Count; $index++) {
                    $old = $replaced[$index]
                    if ($old.State.HandlersAttached) {
                        $failures.Add(
                            "replacement $index retained controller handlers") | Out-Null
                    }
                    if ($null -ne $old.Menu.Tag -and $old.Menu.Tag.HandlersAttached) {
                        $failures.Add(
                            "replacement $index retained menu lifecycle handlers") | Out-Null
                    }

                    $old.Button.RaiseEvent([System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                    Wait-SnipTestDispatcherCondition `
                        -Description "detached replacement $index button route" `
                        -Condition { -not $old.Menu.IsOpen }.GetNewClosure()
                    if ($old.Menu.IsOpen) {
                        $failures.Add(
                            "replacement $index retained its button Click handler") | Out-Null
                    }
                    & $old.CloseOptions

                    & $old.OpenOptions
                    Wait-SnipTestDispatcherCondition `
                        -Description "detached replacement $index open route" `
                        -Condition { -not $old.State.IsExpanded }.GetNewClosure()
                    if ($old.State.IsExpanded) {
                        $failures.Add(
                            "replacement $index retained its menu Opened handler") | Out-Null
                    }
                    & $old.CloseOptions
                }

                Should-Be $kit.Context.TransientMenus.Count $baselineCount
                if ($failures.Count -gt 0) {
                    throw ($failures -join [Environment]::NewLine)
                }
            } finally {
                foreach ($old in $replaced) {
                    try { & $old.CloseOptions } catch {}
                }
                & $kit.SetResponsiveMode 1200 700
                & $kit.SetPropertyIsland 'Select'
            }
        }

    It 'every static popup tree routes its actual MenuItem origin once without overriding native navigation' {
            Invoke-SnipFreshPreviewFixture -TestAction {
                param($kit,$drivers)
                $moreControl = @($kit.Context.TransientMenus | Where-Object Name -eq 'More')[0]
                $cases = @(
                    [pscustomobject]@{ Name='Copy'; Control=$kit.SplitControls.Copy; Opener=$kit.SplitControls.Copy.OptionsButton },
                    [pscustomobject]@{ Name='ArrowLine'; Control=$kit.SplitControls.ArrowLine; Opener=$kit.SplitControls.ArrowLine.OptionsButton },
                    [pscustomobject]@{ Name='RectangleEllipse'; Control=$kit.SplitControls.RectangleEllipse; Opener=$kit.SplitControls.RectangleEllipse.OptionsButton },
                    [pscustomobject]@{ Name='BlurPixelate'; Control=$kit.SplitControls.BlurPixelate; Opener=$kit.SplitControls.BlurPixelate.OptionsButton },
                    [pscustomobject]@{ Name='Color'; Control=$kit.Context.Shell.ColorMenuControl; Opener=$kit.Context.ToolControls.Color },
                    [pscustomobject]@{ Name='More'; Control=$moreControl; Opener=$kit.Context.Shell.MoreButton }
                )
                try {
                    $kit.Win.Width = 1240
                    $kit.Win.Height = 760
                    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                        [Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                    & $kit.SetResponsiveMode 1240 760
                    foreach ($case in $cases) {
                        if ($case.Name -eq 'More') {
                            $kit.Win.Width = 1000
                            $kit.Win.Height = 650
                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                                [Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                            & $kit.SetResponsiveMode 1000 650
                        }
                        & $case.Control.OpenOptions $case.Opener
                        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                        $menu = $case.Control.Menu
                        if (-not $case.Control.State.IsExpanded) {
                            throw "$($case.Name) popup did not open (IsOpen=$($menu.IsOpen); attached=$($case.Control.State.HandlersAttached); openerVisible=$($case.Opener.IsVisible); mode=$($kit.Context.ModeState.Value))"
                        }
                        $lifecycle = $menu.Tag
                        Should-Be $lifecycle.Kind 'SnipPreviewMenuLifecycle'
                        Should-BeTrue $lifecycle.PopupKeyRouteAttached
                        Should-Be $lifecycle.PopupKeyRouteAttachCount 1
                        Should-BeTrue ($null -ne $lifecycle.PopupKeyRouteHandler)
                        $handler = $lifecycle.PopupKeyRouteHandler
                        Set-SnipPreviewMenuStyle -Menu $menu -Context $kit.Context | Out-Null
                        Should-BeTrue ([object]::ReferenceEquals(
                            $handler,$menu.Tag.PopupKeyRouteHandler))
                        Should-Be $menu.Tag.PopupKeyRouteAttachCount 1

                        $item = @($menu.Items | Where-Object {
                            $_ -is [System.Windows.Controls.MenuItem] -and $_.Visibility -eq 'Visible'
                        })[0]
                        $item.Focus() | Out-Null
                        if (-not [object]::ReferenceEquals(
                            [System.Windows.Input.Keyboard]::FocusedElement,$item)) {
                            throw "$($case.Name) popup item did not receive focus"
                        }
                        $resolveBefore = $kit.Context.CommandRouter.ResolveCount
                        $routeBefore = $lifecycle.PopupKeyRouteInvocationCount
                        $down = New-RoutedKeyEvent -Target $item -Key Down
                        $item.RaiseEvent($down)
                        Should-Be $kit.Context.CommandRouter.ResolveCount ($resolveBefore + 1)
                        Should-Be $lifecycle.PopupKeyRouteInvocationCount ($routeBefore + 1)
                        if ($kit.Context.CommandRouter.LastCommand -ne 'PopupNavigation') {
                            throw "$($case.Name) popup resolved '$($kit.Context.CommandRouter.LastCommand)'"
                        }
                        Should-BeTrue ([object]::ReferenceEquals(
                            $lifecycle.LastPopupKeyOrigin,$item))
                        Should-BeFalse $lifecycle.LastPopupRouteHandled
                        & $case.Control.CloseOptions
                        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                    }
                } finally {
                    & $kit.CommandRouter.CloseTransientMenus
                    $kit.Win.Width = 1180
                    $kit.Win.Height = 760
                    & $kit.SetResponsiveMode 1200 700
                }
            }
        }

    It 'Wide Compact and Narrow keep Crop Aspect Reset and Apply on actual property routes' {
            Invoke-SnipFreshPreviewFixture -TestAction {
                param($kit,$drivers)
                $raiseClick = {
                    param([System.Windows.Controls.Primitives.ButtonBase]$Button)
                    $Button.RaiseEvent([System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                }.GetNewClosure()
                $raiseMenuClick = {
                    param([System.Windows.Controls.MenuItem]$Item)
                    $Item.RaiseEvent([System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.MenuItem]::ClickEvent))
                }.GetNewClosure()
                $raiseCanvasDrag = {
                    param(
                        [System.Windows.Point]$Start,
                        [System.Windows.Point[]]$Moves,
                        [System.Windows.Point]$End
                    )
                    $kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
                        -Target $kit.HighlightLayer -Position $Start `
                        -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonDownEvent)))
                    foreach ($point in @($Moves)) {
                        $kit.HighlightLayer.RaiseEvent((New-RoutedMouseMoveEvent `
                            -Target $kit.HighlightLayer -Position $point))
                    }
                    $kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
                        -Target $kit.HighlightLayer -Position $End `
                        -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonUpEvent)))
                }.GetNewClosure()
                $activateTool = {
                    param([string]$Tool)
                    $control = $kit.Context.ToolControls[$Tool]
                    if ($control -is [System.Windows.Controls.Primitives.ToggleButton]) {
                        $peer = [System.Windows.Automation.Peers.ToggleButtonAutomationPeer]::new(
                            $control)
                        $provider = $peer.GetPattern(
                            [System.Windows.Automation.Peers.PatternInterface]::Toggle)
                        ([System.Windows.Automation.Provider.IToggleProvider]$provider).Toggle()
                    } else {
                        & $raiseClick $control
                    }
                }.GetNewClosure()
                $invokePropertyEntry = {
                    param($Entry)
                    if ($Entry.Element -is [System.Windows.Controls.MenuItem]) {
                        & $raiseMenuClick $Entry.Element
                    } else {
                        & $raiseClick $Entry.Element
                    }
                }.GetNewClosure()
                try {
                    foreach ($case in @(
                        [pscustomobject]@{ Width=1200; Height=700; Mode='Wide'; Overflow=$false },
                        [pscustomobject]@{ Width=900; Height=600; Mode='Compact'; Overflow=$true },
                        [pscustomobject]@{ Width=760; Height=540; Mode='Narrow'; Overflow=$true })) {
                        $kit.Win.Width=$case.Width; $kit.Win.Height=$case.Height
                        $kit.Win.UpdateLayout()
                        & $activateTool 'Select'
                        Should-Be $kit.Context.ActiveTool 'Select'
                        Should-BeTrue (@($kit.Context.ToolOrder) -contains 'Select')
                        Should-BeTrue (@($kit.Context.ToolOrder) -contains 'Crop')
                        & $activateTool 'Crop'
                        & $kit.SetResponsiveMode $case.Width $case.Height
                        Should-Be $kit.ResponsiveMode.Value $case.Mode
                        Should-Be $kit.Context.ActiveTool 'Crop'
                        Should-BeTrue ($null -ne $kit.Context.PropertyControls.Aspect)
                        Should-BeTrue ($null -ne $kit.Context.PropertyControls.Reset)
                        Should-BeTrue ($null -ne $kit.Context.PropertyControls.Apply)
                        $oldAspectController = $kit.Context.PropertyControls.Aspect.Controller
                        & $raiseClick $kit.Context.PropertyControls.Aspect.Button
                        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                        Should-BeTrue $oldAspectController.State.IsExpanded
                        Should-BeTrue $oldAspectController.State.IsMenuWindowRegistered
                        & $raiseMenuClick $kit.Context.PropertyControls.Aspect.MenuItems.Free
                        Should-BeFalse $oldAspectController.State.IsExpanded
                        Should-BeFalse $oldAspectController.State.IsMenuWindowRegistered
                        Should-BeTrue $kit.Context.PropertyControls.Aspect.Button.IsKeyboardFocused

                        & $raiseCanvasDrag ([System.Windows.Point]::new(120,100)) `
                            @([System.Windows.Point]::new(220,180)) `
                            ([System.Windows.Point]::new(320,260))
                        if ($case.Overflow) {
                            & $raiseClick $kit.Context.PropertyControls.MoreProperties.Element
                            $moreProperties = $kit.Context.PropertyControls.MoreProperties.Controller
                            Wait-SnipTestDispatcherCondition `
                                -Description 'crop overflow property popup expansion' `
                                -Condition {
                                    $moreProperties.State.IsExpanded -and
                                    $moreProperties.State.IsMenuWindowRegistered
                                }.GetNewClosure()
                            Should-BeTrue $moreProperties.State.IsExpanded
                            Should-BeTrue ($kit.Context.PropertyControls.Apply.Element -is
                                [System.Windows.Controls.MenuItem])
                            Should-BeTrue $moreProperties.State.IsMenuWindowRegistered
                            & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                            Should-BeFalse $kit.Context.PropertyControls.MoreProperties.Controller.State.IsExpanded
                        } else {
                            Should-BeTrue ($kit.Context.PropertyControls.Apply.Element -is
                                [System.Windows.Controls.Button])
                            & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                        }
                        Should-BeTrue ($null -ne $kit.Context.CropRectangle)
                        & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                        Should-Be $kit.Context.CropRectangle $null

                        Set-SnipPropertyIsland -Context $kit.Context -Tool Crop | Out-Null
                        Should-BeFalse $oldAspectController.State.HandlersAttached
                        Should-BeFalse $kit.Context.TransientMenus.Contains($oldAspectController)
                    }
                } finally {
                    & $kit.SetResponsiveMode 1200 700
                    & $kit.CommandRouter.CloseTransientMenus
                }
            }
        }
    }

    foreach ($duplicateMode in @(
            [pscustomobject]@{ Name = 'Compact'; Width = 1000; Height = 650 },
            [pscustomobject]@{ Name = 'Narrow'; Width = 760; Height = 540 }
        )) {
        It "$($duplicateMode.Name) overflow Duplicate automation clamps, edits, and deletes the new record" {
            Invoke-SnipFreshPreviewFixture -TestAction {
                param($kit, $drivers)
                $raiseClick = $drivers.RaiseClick
                $raiseMenuClick = $drivers.RaiseMenuClick
                $raiseCanvasDown = $drivers.RaiseCanvasDown
                $raiseCanvasMove = $drivers.RaiseCanvasMove
                $raiseCanvasUp = $drivers.RaiseCanvasUp
                $raiseCanvasClick = $drivers.RaiseCanvasClick
                $raiseCanvasDrag = $drivers.RaiseCanvasDrag
                $raiseCanvasKey = $drivers.RaiseCanvasKey
                $raiseControlKey = $drivers.RaiseControlKey
                $invokeAutomation = $drivers.InvokeAutomation
                $activateTool = $drivers.ActivateTool
                $drawRectangle = $drivers.DrawRectangle
                $clearCanvasContent = $drivers.ClearCanvasContent
                $invokePropertyEntry = $drivers.InvokePropertyEntry

                try {
                    & $clearCanvasContent
                    $kit.Win.Width = $duplicateMode.Width
                    $kit.Win.Height = $duplicateMode.Height
                    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                        [Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
                    & $kit.SetResponsiveMode $duplicateMode.Width $duplicateMode.Height
                    & $drawRectangle ([System.Windows.Point]::new(1120, 730)) `
                    ([System.Windows.Point]::new(1195, 795))
                    & $activateTool 'Select'
                    & $raiseCanvasClick ([System.Windows.Point]::new(1150, 760))
                    & $kit.SetResponsiveMode $duplicateMode.Width $duplicateMode.Height
                    $source = @($kit.Context.Annotations)[0]
                    $sourceBefore = $source | ConvertTo-Json -Depth 20 -Compress
                    $kit.Context.RedoStack.Push((New-SnipEditorSnapshot `
                                -Annotations $kit.Context.Annotations `
                                -CropRectangle $kit.Context.CropRectangle))
                    $historyBefore = $kit.Context.UndoStack.Count
                    $propertyMenu = $kit.Context.PropertyMenuControl
                    $oldLifecycle = $propertyMenu.Menu.Tag

                    & $invokeAutomation $kit.Context.PropertyControls.MoreProperties.Element
                    Wait-SnipTestDispatcherCondition `
                        -Description "$($duplicateMode.Name) property popup opening" `
                        -Condition {
                        $propertyMenu.State.IsExpanded -and
                        $propertyMenu.State.IsMenuWindowRegistered -and
                        $null -ne [System.Windows.PresentationSource]::FromVisual(
                            $kit.Context.PropertyControls.Duplicate.Element)
                    }.GetNewClosure()
                    Should-BeTrue $propertyMenu.State.IsExpanded
                    $duplicateItem = $kit.Context.PropertyControls.Duplicate.Element
                    Should-BeTrue ($duplicateItem -is [System.Windows.Controls.MenuItem])
                    & $invokeAutomation $duplicateItem
                    Wait-SnipTestDispatcherCondition `
                        -Description "$($duplicateMode.Name) duplicate popup closure" `
                        -Condition {
                        -not $oldLifecycle.PopupKeyRouteAttached -and
                        $kit.Context.Annotations.Count -eq 2
                    }.GetNewClosure()

                    Should-BeFalse $oldLifecycle.PopupKeyRouteAttached
                    Should-Be $kit.Context.Annotations.Count 2
                    Should-Be $kit.Context.UndoStack.Count ($historyBefore + 1)
                    Should-Be $kit.Context.RedoStack.Count 0
                    Should-BeTrue ([object]::ReferenceEquals(
                            $source, $kit.Context.Annotations[0]))
                    Should-Be ($source | ConvertTo-Json -Depth 20 -Compress) $sourceBefore
                    $duplicate = $kit.Context.Annotations[1]
                    $duplicateId = $duplicate.Id
                    Should-BeFalse ($duplicateId -eq $source.Id)
                    Should-Be $kit.Context.SelectedAnnotationId $duplicateId
                    $expected = Move-SnipAnnotation -Annotation $source `
                        -DeltaX 12 -DeltaY 12 -SourceWidth $kit.Bitmap.Width `
                        -SourceHeight $kit.Bitmap.Height
                    Should-Be ($duplicate.Geometry | ConvertTo-Json -Depth 20 -Compress) `
                    ($expected.Geometry | ConvertTo-Json -Depth 20 -Compress)
                    Should-Be $duplicate.Z ([double]$source.Z + 1.0)

                    $position = $kit.Context.PropertyControls.Position.Element
                    $position.Text = '100, 110'
                    $positionEnter = New-RoutedKeyEvent -Target $position -Key Enter `
                        -RoutedEvent ([System.Windows.Input.Keyboard]::KeyDownEvent)
                    $position.RaiseEvent($positionEnter)
                    Should-BeTrue $positionEnter.Handled
                    $positioned = @($kit.Context.Annotations |
                            Where-Object Id -EQ $duplicateId)[0]
                    Should-Be $positioned.Geometry.X 100
                    Should-Be $positioned.Geometry.Y 110

                    $size = $kit.Context.PropertyControls.Size.Element
                    $size.Text = '90 × 70'
                    $sizeEnter = New-RoutedKeyEvent -Target $size -Key Enter `
                        -RoutedEvent ([System.Windows.Input.Keyboard]::KeyDownEvent)
                    $size.RaiseEvent($sizeEnter)
                    Should-BeTrue $sizeEnter.Handled
                    $sized = @($kit.Context.Annotations |
                            Where-Object Id -EQ $duplicateId)[0]
                    Should-Be $sized.Geometry.Width 90
                    Should-Be $sized.Geometry.Height 70

                    & $invokeAutomation $kit.Context.PropertyControls.MoreProperties.Element
                    $deleteMenu =
                    $kit.Context.PropertyControls.MoreProperties.Controller
                    $deleteItem = $kit.Context.PropertyControls.Delete.Element
                    Wait-SnipTestDispatcherCondition `
                        -Description "$($duplicateMode.Name) delete popup opening" `
                        -Condition {
                        $deleteMenu.State.IsExpanded -and
                        $deleteMenu.State.IsMenuWindowRegistered -and
                        $null -ne [System.Windows.PresentationSource]::FromVisual(
                            $deleteItem)
                    }.GetNewClosure()
                    Should-BeTrue ($deleteItem -is [System.Windows.Controls.MenuItem])
                    & $invokeAutomation $deleteItem
                    Wait-SnipTestDispatcherCondition `
                        -Description "$($duplicateMode.Name) delete popup closure" `
                        -Condition {
                        -not $deleteMenu.State.IsExpanded -and
                        -not $deleteMenu.State.IsMenuWindowRegistered
                    }.GetNewClosure()
                    Should-Be (@($kit.Context.Annotations |
                                Where-Object Id -EQ $duplicateId)).Count 0
                    Should-Be (@($kit.Context.Annotations |
                                Where-Object Id -EQ $source.Id)).Count 1
                }
                finally {
                    & $kit.CommandRouter.CloseTransientMenus
                    $kit.Win.Width = 1180; $kit.Win.Height = 760
                    & $kit.SetResponsiveMode 1200 700
                    & $clearCanvasContent
                }
            }
        }
    }

    It 'annotation popup actions resolve their stable target when list membership changes' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit, $drivers)
            $raiseClick = $drivers.RaiseClick
            $raiseMenuClick = $drivers.RaiseMenuClick
            $raiseCanvasDown = $drivers.RaiseCanvasDown
            $raiseCanvasMove = $drivers.RaiseCanvasMove
            $raiseCanvasUp = $drivers.RaiseCanvasUp
            $raiseCanvasClick = $drivers.RaiseCanvasClick
            $raiseCanvasDrag = $drivers.RaiseCanvasDrag
            $raiseCanvasKey = $drivers.RaiseCanvasKey
            $raiseControlKey = $drivers.RaiseControlKey
            $invokeAutomation = $drivers.InvokeAutomation
            $activateTool = $drivers.ActivateTool
            $drawRectangle = $drivers.DrawRectangle
            $clearCanvasContent = $drivers.ClearCanvasContent
            $invokePropertyEntry = $drivers.InvokePropertyEntry

            try {
                & $clearCanvasContent
                & $raiseMenuClick $kit.Context.Shell.ColorMenuItems.Blue
                Should-Be $kit.State.ActiveColor 'Blue'
                & $drawRectangle ([System.Windows.Point]::new(40, 40)) `
                ([System.Windows.Point]::new(160, 130))
                & $drawRectangle ([System.Windows.Point]::new(300, 40)) `
                ([System.Windows.Point]::new(420, 130))
                $targetId = $kit.Context.Annotations[1].Id
                $rightClick = New-RoutedMouseRightClick -Target $kit.HighlightLayer `
                    -Position ([System.Windows.Point]::new(350, 80))
                $kit.HighlightLayer.RaiseEvent($rightClick)
                Wait-SnipTestDispatcherCondition `
                    -Description 'stable-target annotation popup opening' `
                    -Condition {
                    $null -ne $kit.Context.AnnotationMenuControl -and
                    $kit.Context.AnnotationMenuControl.Menu.IsOpen -and
                    $kit.Context.AnnotationMenuControl.State.IsMenuWindowRegistered
                }.GetNewClosure()
                Should-BeTrue $rightClick.Handled
                $capturedRedAction = @($kit.Context.AnnotationMenuControl.Menu.Items |
                        Where-Object {
                            $_ -is [System.Windows.Controls.MenuItem] -and $_.Header -eq 'Red'
                        })[0]
                Wait-SnipTestDispatcherCondition `
                    -Description 'stable-target annotation popup item source' `
                    -Condition {
                    $null -ne [System.Windows.PresentationSource]::FromVisual(
                        $capturedRedAction)
                }.GetNewClosure()
                $annotationMenu = $kit.Context.AnnotationMenuControl
                & $kit.Context.AnnotationMenuControl.CloseOptions
                Wait-SnipTestDispatcherCondition `
                    -Description 'stable-target annotation popup closure' `
                    -Condition {
                    -not $annotationMenu.Menu.IsOpen -and
                    -not $annotationMenu.State.IsMenuWindowRegistered
                }.GetNewClosure()

                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(80, 80))
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $raiseCanvasKey ([System.Windows.Input.Key]::Delete) | Out-Null
                Should-Be $kit.Context.Annotations.Count 1
                Should-Be $kit.Context.Annotations[0].Id $targetId
                $historyAfterShift = $kit.Context.UndoStack.Count
                & $raiseMenuClick $capturedRedAction
                Should-Be $kit.Context.Annotations.Count 1
                Should-Be $kit.Context.Annotations[0].Id $targetId
                Should-Be $kit.Context.Annotations[0].Color 'Red'
                Should-Be $kit.Context.UndoStack.Count ($historyAfterShift + 1)
            }
            finally {
                if ($null -ne $kit.Context.AnnotationMenuControl) {
                    try { & $kit.Context.AnnotationMenuControl.CloseOptions } catch {}
                }
                & $raiseMenuClick $kit.Context.Shell.ColorMenuItems.Yellow
                & $clearCanvasContent
            }
        }
    }

    It 'rebuilt property and annotation popup trees detach the old route and attach one fresh route' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit, $drivers)
            $raiseClick = $drivers.RaiseClick
            $raiseMenuClick = $drivers.RaiseMenuClick
            $raiseCanvasDown = $drivers.RaiseCanvasDown
            $raiseCanvasMove = $drivers.RaiseCanvasMove
            $raiseCanvasUp = $drivers.RaiseCanvasUp
            $raiseCanvasClick = $drivers.RaiseCanvasClick
            $raiseCanvasDrag = $drivers.RaiseCanvasDrag
            $raiseCanvasKey = $drivers.RaiseCanvasKey
            $raiseControlKey = $drivers.RaiseControlKey
            $invokeAutomation = $drivers.InvokeAutomation
            $activateTool = $drivers.ActivateTool
            $drawRectangle = $drivers.DrawRectangle
            $clearCanvasContent = $drivers.ClearCanvasContent
            $invokePropertyEntry = $drivers.InvokePropertyEntry

            $newPopupKeyEvent = {
                param(
                    [System.Windows.IInputElement]$Target,
                    [System.Windows.Input.Key]$Key
                )
                New-RoutedKeyEvent -Target $Target -Key $Key
            }.GetNewClosure()
            $assertNativePopupRoute = {
                param($Control, $Context, $KeyEventFactory)
                & $Control.OpenOptions
                $menu = $Control.Menu
                $lifecycle = $menu.Tag
                Wait-SnipTestDispatcherCondition `
                    -Description 'rebuilt native popup opening and route source' `
                    -Condition {
                    $item = @($menu.Items | Where-Object {
                            $_ -is [System.Windows.Controls.MenuItem]
                        })[0]
                    $Control.State.IsExpanded -and
                    $Control.State.IsMenuWindowRegistered -and
                    $null -ne [System.Windows.PresentationSource]::FromVisual($item)
                }.GetNewClosure()
                Should-BeTrue $lifecycle.PopupKeyRouteAttached
                Should-Be $lifecycle.PopupKeyRouteAttachCount 1
                $item = @($menu.Items | Where-Object {
                        $_ -is [System.Windows.Controls.MenuItem]
                    })[0]
                $item.Focus() | Out-Null
                $before = $Context.CommandRouter.ResolveCount
                $down = & $KeyEventFactory $item Down
                $item.RaiseEvent($down)
                Should-Be $Context.CommandRouter.ResolveCount ($before + 1)
                Should-Be $Context.CommandRouter.LastCommand 'PopupNavigation'
                Should-BeFalse $lifecycle.LastPopupRouteHandled
                & $Control.CloseOptions
                Wait-SnipTestDispatcherCondition `
                    -Description 'rebuilt native popup closure' `
                    -Condition {
                    -not $Control.State.IsExpanded -and
                    -not $Control.State.IsMenuWindowRegistered
                }.GetNewClosure()
                $lifecycle
            }.GetNewClosure()
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100, 100)) `
                ([System.Windows.Point]::new(220, 180))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(150, 140))
                & $kit.SetResponsiveMode 1000 650
                $firstProperty = $kit.Context.PropertyMenuControl
                $firstPropertyLifecycle = & $assertNativePopupRoute $firstProperty `
                    $kit.Context $newPopupKeyEvent
                & $kit.SetPropertyIsland 'Select'
                Should-BeFalse $firstPropertyLifecycle.PopupKeyRouteAttached
                $secondProperty = $kit.Context.PropertyMenuControl
                Should-BeFalse ([object]::ReferenceEquals($firstProperty, $secondProperty))
                $secondPropertyLifecycle = & $assertNativePopupRoute $secondProperty `
                    $kit.Context $newPopupKeyEvent
                Should-BeFalse ([object]::ReferenceEquals(
                        $firstPropertyLifecycle.PopupKeyRouteHandler,
                        $secondPropertyLifecycle.PopupKeyRouteHandler))

                & $activateTool 'Crop'
                $aspectControl = $kit.Context.CropAspectMenuControl
                $aspectLifecycle = & $assertNativePopupRoute $aspectControl `
                    $kit.Context $newPopupKeyEvent
                & $activateTool 'Select'
                Should-BeFalse $aspectLifecycle.PopupKeyRouteAttached

                & $raiseCanvasClick ([System.Windows.Point]::new(150, 140))
                $rightClick = New-RoutedMouseRightClick -Target $kit.HighlightLayer `
                    -Position ([System.Windows.Point]::new(150, 140))
                $kit.HighlightLayer.RaiseEvent($rightClick)
                Wait-SnipTestDispatcherCondition `
                    -Description 'first rebuilt annotation popup opening' `
                    -Condition {
                    $null -ne $kit.Context.AnnotationMenuControl -and
                    $kit.Context.AnnotationMenuControl.Menu.IsOpen -and
                    $kit.Context.AnnotationMenuControl.State.IsMenuWindowRegistered
                }.GetNewClosure()
                $firstAnnotation = $kit.Context.AnnotationMenuControl
                $firstAnnotationLifecycle = & $assertNativePopupRoute $firstAnnotation `
                    $kit.Context $newPopupKeyEvent

                $kit.HighlightLayer.RaiseEvent((New-RoutedMouseRightClick `
                            -Target $kit.HighlightLayer `
                            -Position ([System.Windows.Point]::new(150, 140))))
                Wait-SnipTestDispatcherCondition `
                    -Description 'second rebuilt annotation popup replacement' `
                    -Condition {
                    -not $firstAnnotationLifecycle.PopupKeyRouteAttached -and
                    $null -ne $kit.Context.AnnotationMenuControl -and
                    -not [object]::ReferenceEquals(
                        $firstAnnotation, $kit.Context.AnnotationMenuControl)
                }.GetNewClosure()
                Should-BeFalse $firstAnnotationLifecycle.PopupKeyRouteAttached
                $secondAnnotation = $kit.Context.AnnotationMenuControl
                $secondAnnotationLifecycle = & $assertNativePopupRoute $secondAnnotation `
                    $kit.Context $newPopupKeyEvent
                Should-BeFalse ([object]::ReferenceEquals(
                        $firstAnnotationLifecycle.PopupKeyRouteHandler,
                        $secondAnnotationLifecycle.PopupKeyRouteHandler))
            }
            finally {
                if ($null -ne $kit.Context.AnnotationMenuControl) {
                    try { & $kit.Context.AnnotationMenuControl.CloseOptions } catch {}
                }
                & $kit.CommandRouter.CloseTransientMenus
                & $kit.SetResponsiveMode 1200 700
                & $clearCanvasContent
            }
        }
    }

    It 'real Aspect menu applies every preset only through the Apply control' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit, $drivers)
            $raiseClick = $drivers.RaiseClick
            $raiseMenuClick = $drivers.RaiseMenuClick
            $raiseCanvasDown = $drivers.RaiseCanvasDown
            $raiseCanvasMove = $drivers.RaiseCanvasMove
            $raiseCanvasUp = $drivers.RaiseCanvasUp
            $raiseCanvasClick = $drivers.RaiseCanvasClick
            $raiseCanvasDrag = $drivers.RaiseCanvasDrag
            $raiseCanvasKey = $drivers.RaiseCanvasKey
            $raiseControlKey = $drivers.RaiseControlKey
            $invokeAutomation = $drivers.InvokeAutomation
            $activateTool = $drivers.ActivateTool
            $drawRectangle = $drivers.DrawRectangle
            $clearCanvasContent = $drivers.ClearCanvasContent
            $invokePropertyEntry = $drivers.InvokePropertyEntry

            $selectAspect = $drivers.SelectAspect
            try {
                & $clearCanvasContent
                foreach ($case in @(
                        [pscustomobject]@{ Name = 'Free'; X = 100; Y = 80; Width = 400; Height = 220 },
                        [pscustomobject]@{ Name = 'Original'; X = 135; Y = 80; Width = 330; Height = 220 },
                        [pscustomobject]@{ Name = '1:1'; X = 190; Y = 80; Width = 220; Height = 220 },
                        [pscustomobject]@{ Name = '4:3'; X = 154; Y = 80; Width = 293; Height = 220 },
                        [pscustomobject]@{ Name = '16:9'; X = 105; Y = 80; Width = 391; Height = 220 })) {
                    & $activateTool 'Crop'
                    & $raiseCanvasDrag ([System.Windows.Point]::new(100, 80)) `
                    @([System.Windows.Point]::new(300, 190)) `
                    ([System.Windows.Point]::new(500, 300))
                    $committedBefore = $kit.Context.CropRectangle
                    $historyBefore = $kit.Context.UndoStack.Count

                    & $selectAspect `
                        $kit.Context.PropertyControls.Aspect.MenuItems[$case.Name] `
                        "landscape $($case.Name) Aspect popup"
                    Should-Be $kit.Context.CropRectangle $committedBefore
                    Should-Be $kit.Context.UndoStack.Count $historyBefore
                    & $invokePropertyEntry $kit.Context.PropertyControls.Apply

                    $crop = $kit.Context.CropRectangle
                    Should-BeTrue ($null -ne $crop)
                    Should-Be $kit.Context.UndoStack.Count ($historyBefore + 1)
                    Should-Be $crop.X $case.X
                    Should-Be $crop.Y $case.Y
                    Should-Be $crop.Width $case.Width
                    Should-Be $crop.Height $case.Height
                    $historyAfterApply = $kit.Context.UndoStack.Count
                    & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                    Should-Be $kit.Context.UndoStack.Count $historyAfterApply
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                    Should-Be $kit.Context.CropRectangle $null
                    $historyAfterReset = $kit.Context.UndoStack.Count
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                    Should-Be $kit.Context.UndoStack.Count $historyAfterReset
                }

                foreach ($portraitCase in @(
                        [pscustomobject]@{ Name = '4:3'; X = 5; Y = 30; Width = 90; Height = 120 },
                        [pscustomobject]@{ Name = '16:9'; X = 5; Y = 10; Width = 90; Height = 160 })) {
                    & $activateTool 'Crop'
                    & $raiseCanvasDrag ([System.Windows.Point]::new(5, 10)) `
                    @([System.Windows.Point]::new(50, 90)) `
                    ([System.Windows.Point]::new(95, 170))
                    & $selectAspect `
                        $kit.Context.PropertyControls.Aspect.MenuItems[$portraitCase.Name] `
                        "portrait $($portraitCase.Name) Aspect popup"
                    & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                    Should-Be $kit.Context.CropRectangle.X $portraitCase.X
                    Should-Be $kit.Context.CropRectangle.Y $portraitCase.Y
                    Should-Be $kit.Context.CropRectangle.Width $portraitCase.Width
                    Should-Be $kit.Context.CropRectangle.Height $portraitCase.Height
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
            }
            finally {
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }
    }

    It 'a new routed crop edit clears redo and semantic snapshots deep-copy crop points and properties' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit, $drivers)
            $raiseClick = $drivers.RaiseClick
            $raiseMenuClick = $drivers.RaiseMenuClick
            $raiseCanvasDown = $drivers.RaiseCanvasDown
            $raiseCanvasMove = $drivers.RaiseCanvasMove
            $raiseCanvasUp = $drivers.RaiseCanvasUp
            $raiseCanvasClick = $drivers.RaiseCanvasClick
            $raiseCanvasDrag = $drivers.RaiseCanvasDrag
            $raiseCanvasKey = $drivers.RaiseCanvasKey
            $raiseControlKey = $drivers.RaiseControlKey
            $invokeAutomation = $drivers.InvokeAutomation
            $activateTool = $drivers.ActivateTool
            $drawRectangle = $drivers.DrawRectangle
            $clearCanvasContent = $drivers.ClearCanvasContent
            $invokePropertyEntry = $drivers.InvokePropertyEntry

            try {
                & $clearCanvasContent
                $pointRecord = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
                        Type='Points'; Points=@(
                            [pscustomobject]@{ X = 10; Y = 10 },
                            [pscustomobject]@{ X = 40; Y = 50 })
                    }) -Color Green -StrokeWidth 4 -Opacity 0.8 `
                    -Properties ([ordered]@{
                        Style  =[pscustomobject]@{ Smoothing = 0.5 }
                        Labels =[System.Collections.ArrayList]@('one', 'two')
                    }) -Z 4
                $kit.Context.Annotations.Add($pointRecord) | Out-Null
                & $kit.Render
                & $activateTool 'Crop'
                & $drivers.SelectAspect `
                    $kit.Context.PropertyControls.Aspect.MenuItems.Free `
                    'semantic snapshot Aspect popup'
                & $raiseCanvasDrag ([System.Windows.Point]::new(100, 100)) `
                @([System.Windows.Point]::new(200, 180)) `
                ([System.Windows.Point]::new(300, 260))
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                $appliedReference = $kit.Context.CropRectangle
                & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                $snapshot = $kit.Context.UndoStack.Peek()
                Should-BeTrue ($null -ne $snapshot.CropRectangle)
                Should-BeFalse ([object]::ReferenceEquals(
                        $snapshot.Annotations, $kit.Context.Annotations))
                Should-BeFalse ([object]::ReferenceEquals(
                        $snapshot.Annotations[0], $kit.Context.Annotations[0]))
                Should-BeFalse ([object]::ReferenceEquals(
                        $snapshot.Annotations[0].Geometry, $kit.Context.Annotations[0].Geometry))
                Should-BeFalse ([object]::ReferenceEquals(
                        $snapshot.Annotations[0].Geometry.Points,
                        $kit.Context.Annotations[0].Geometry.Points))
                Should-BeFalse ([object]::ReferenceEquals(
                        $snapshot.Annotations[0].Properties, $kit.Context.Annotations[0].Properties))
                Should-BeFalse ([object]::ReferenceEquals(
                        $snapshot.CropRectangle, $appliedReference))

                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be $kit.Context.RedoStack.Count 1
                Should-Be $kit.Context.ActiveTool 'Crop'
                Should-Be $kit.Context.CropRectangle.X 100
                Should-Be $kit.Context.CropRectangle.Y 100
                Should-Be $kit.Context.CropRectangle.Width 200
                Should-Be $kit.Context.CropRectangle.Height 160
                & $raiseCanvasDown ([System.Windows.Point]::new(220, 180))
                Should-Be $kit.Context.Draft.Kind 'Crop'
                Should-Be ($null -eq
                    $kit.Context.Draft.PSObject.Properties['ResizeHandle']) $true
                & $raiseCanvasMove ([System.Windows.Point]::new(320, 260))
                & $raiseCanvasUp ([System.Windows.Point]::new(420, 340))
                Should-Be $kit.Context.Draft.Candidate.X 220
                Should-Be $kit.Context.Draft.Candidate.Y 180
                Should-Be $kit.Context.Draft.Candidate.Width 200
                Should-Be $kit.Context.Draft.Candidate.Height 160
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                Should-Be $kit.Context.RedoStack.Count 0
            }
            finally {
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }
    }

    It 'crop overlay maps in source space under zoom and pan with constant-DIP handles' {
        Invoke-SnipFreshPreviewFixture -TestAction {
            param($kit, $drivers)
            $raiseClick = $drivers.RaiseClick
            $raiseMenuClick = $drivers.RaiseMenuClick
            $raiseCanvasDown = $drivers.RaiseCanvasDown
            $raiseCanvasMove = $drivers.RaiseCanvasMove
            $raiseCanvasUp = $drivers.RaiseCanvasUp
            $raiseCanvasClick = $drivers.RaiseCanvasClick
            $raiseCanvasDrag = $drivers.RaiseCanvasDrag
            $raiseCanvasKey = $drivers.RaiseCanvasKey
            $raiseControlKey = $drivers.RaiseControlKey
            $invokeAutomation = $drivers.InvokeAutomation
            $activateTool = $drivers.ActivateTool
            $drawRectangle = $drivers.DrawRectangle
            $clearCanvasContent = $drivers.ClearCanvasContent
            $invokePropertyEntry = $drivers.InvokePropertyEntry

            try {
                & $clearCanvasContent
                & $activateTool 'Crop'
                & $drivers.SelectAspect `
                    $kit.Context.PropertyControls.Aspect.MenuItems.Free `
                    'crop overlay Aspect popup'
                & $raiseCanvasDrag ([System.Windows.Point]::new(100, 120)) `
                @([System.Windows.Point]::new(250, 220)) `
                ([System.Windows.Point]::new(400, 320))
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                foreach ($zoom in @(0.5, 1.0, 2.0)) {
                    & $kit.SetZoom $zoom
                    $kit.Scroller.ScrollToHorizontalOffset(80)
                    $kit.Scroller.ScrollToVerticalOffset(60)
                    $kit.Win.UpdateLayout()

                    $overlay = @($kit.InteractionLayer.Children | Where-Object {
                            $null -ne $_.Tag -and $_.Tag.Role -eq 'CropOverlay'
                        }) | Select-Object -First 1
                    Should-BeTrue ($null -ne $overlay)
                    Should-Be ([System.Windows.Controls.Canvas]::GetLeft($overlay)) 100
                    Should-Be ([System.Windows.Controls.Canvas]::GetTop($overlay)) 120
                    Should-Be $overlay.Width 300
                    Should-Be $overlay.Height 200
                    Should-Be ($overlay.Width * $zoom) (300 * $zoom) 0.01
                    $viewportOrigin = $overlay.TranslatePoint(
                        [System.Windows.Point]::new(0, 0), $kit.Scroller)
                    Should-Be $viewportOrigin.X `
                    (100 * $zoom - $kit.Scroller.HorizontalOffset) 1.0
                    Should-Be $viewportOrigin.Y `
                    (120 * $zoom - $kit.Scroller.VerticalOffset) 1.0
                    $handles = @($kit.InteractionLayer.Children | Where-Object {
                            $null -ne $_.Tag -and $_.Tag.Role -eq 'CropHandle'
                        })
                    Should-Be $handles.Count 8
                    foreach ($handle in $handles) {
                        Should-Be ($handle.Width * $zoom) 10 0.01
                    }
                }

                & $kit.SetZoom 2.0
                Should-Be $kit.Context.Draft $null
                Should-Be $kit.Context.CropRectangle.X 100
                Should-Be $kit.Context.CropRectangle.Y 120
                Should-Be $kit.Context.CropRectangle.Width 300
                Should-Be $kit.Context.CropRectangle.Height 200
                $bottomRight = @($kit.InteractionLayer.Children | Where-Object {
                        $null -ne $_.Tag -and $_.Tag.Role -eq 'CropHandle' -and
                        $_.Tag.Handle -eq 'BottomRight'
                    })[0]
                Should-Be ([System.Windows.Controls.Canvas]::GetLeft($bottomRight)) 397.5 0.01
                Should-Be ([System.Windows.Controls.Canvas]::GetTop($bottomRight)) 317.5 0.01
                $handleCenterX = [System.Windows.Controls.Canvas]::GetLeft($bottomRight) +
                ($bottomRight.Width / 2.0)
                $handleCenterY = [System.Windows.Controls.Canvas]::GetTop($bottomRight) +
                ($bottomRight.Height / 2.0)
                $handleStart = [System.Windows.Point]::new($handleCenterX, $handleCenterY)
                Should-Be $handleStart.X 400 0.01
                Should-Be $handleStart.Y 320 0.01
                Should-Be (& $kit.GetCropHandleAt $handleStart) 'BottomRight'
                & $raiseCanvasDown $handleStart
                Should-Be $kit.Context.Draft.Anchor.X 400 0.01
                Should-Be $kit.Context.Draft.Anchor.Y 320 0.01
                Should-Be $kit.Context.Draft.ResizeHandle 'BottomRight'
                & $raiseCanvasMove ([System.Windows.Point]::new(450, 360))
                & $raiseCanvasUp ([System.Windows.Point]::new(450, 360))
                Should-Be $kit.Context.CropRectangle.Width 300
                Should-Be $kit.Context.CropRectangle.Height 200
                Should-Be $kit.Context.Draft.Candidate.Width 350
                Should-Be $kit.Context.Draft.Candidate.Height 240
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                Should-Be $kit.Context.CropRectangle.Width 350
                Should-Be $kit.Context.CropRectangle.Height 240
            }
            finally {
                & $kit.SetZoom 1.0
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }
    }
}

# ---- Build synthetic bitmap ----
$bmp = New-Object System.Drawing.Bitmap 1200, 800
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::SlateBlue)
$g.FillRectangle([System.Drawing.Brushes]::Orange, 100, 100, 400, 300)
$g.FillRectangle([System.Drawing.Brushes]::Lime,   700, 500, 300, 200)
$g.Dispose()

# --- Kick off tests via -TestAction ----
# The test body runs inside Show-PreviewWindow's scope (during Loaded,
# while ShowDialog is blocking) so the event handlers can find all the
# function-local variables they reference.
$null = Show-PreviewWindow -Bitmap $bmp -TestAction {
    param($kit)

    $raiseClick = {
        param([System.Windows.Controls.Primitives.ButtonBase]$Button)
        $Button.RaiseEvent([System.Windows.RoutedEventArgs]::new(
            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }.GetNewClosure()
    $raiseMenuClick = {
        param([System.Windows.Controls.MenuItem]$Item)
        $Item.RaiseEvent([System.Windows.RoutedEventArgs]::new(
            [System.Windows.Controls.MenuItem]::ClickEvent))
    }.GetNewClosure()
    $raiseCanvasDown = {
        param([System.Windows.Point]$Point)
        $kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
            -Target $kit.HighlightLayer -Position $Point `
            -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonDownEvent)))
    }.GetNewClosure()
    $raiseCanvasMove = {
        param([System.Windows.Point]$Point)
        $kit.HighlightLayer.RaiseEvent((New-RoutedMouseMoveEvent `
            -Target $kit.HighlightLayer -Position $Point))
    }.GetNewClosure()
    $raiseCanvasUp = {
        param([System.Windows.Point]$Point)
        $kit.HighlightLayer.RaiseEvent((New-RoutedMouseLeftEvent `
            -Target $kit.HighlightLayer -Position $Point `
            -RoutedEvent ([System.Windows.UIElement]::MouseLeftButtonUpEvent)))
    }.GetNewClosure()
    $raiseCanvasClick = {
        param([System.Windows.Point]$Point)
        & $raiseCanvasDown $Point
        & $raiseCanvasUp $Point
    }.GetNewClosure()
    $raiseCanvasDrag = {
        param(
            [System.Windows.Point]$Start,
            [System.Windows.Point[]]$Moves,
            [System.Windows.Point]$End
        )
        & $raiseCanvasDown $Start
        foreach ($point in @($Moves)) { & $raiseCanvasMove $point }
        & $raiseCanvasUp $End
    }.GetNewClosure()
    $raiseCanvasKey = {
        param([System.Windows.Input.Key]$Key)
        $kit.HighlightLayer.Focus() | Out-Null
        $eventArgs = New-RoutedKeyEvent -Target $kit.HighlightLayer -Key $Key
        $kit.HighlightLayer.RaiseEvent($eventArgs)
        $eventArgs
    }.GetNewClosure()
    $raiseControlKey = {
        param(
            [System.Windows.IInputElement]$Target,
            [System.Windows.Input.Key]$Key
        )
        $preview = New-RoutedKeyEvent -Target $Target -Key $Key
        $Target.RaiseEvent($preview)
        if ($preview.Handled) { return $preview }
        $bubble = New-RoutedKeyEvent -Target $Target -Key $Key `
            -RoutedEvent ([System.Windows.Input.Keyboard]::KeyDownEvent)
        $Target.RaiseEvent($bubble)
        $bubble
    }.GetNewClosure()
    $activateTool = {
        param([string]$Tool)
        switch ($Tool) {
            'RectangleEllipse' { & $raiseClick $kit.SplitControls.RectangleEllipse.PrimaryButton }
            'ArrowLine' { & $raiseClick $kit.SplitControls.ArrowLine.PrimaryButton }
            default {
                $control = $kit.Context.ToolControls[$Tool]
                if ($control -is [System.Windows.Controls.Primitives.ToggleButton]) {
                    $peer = [System.Windows.Automation.Peers.ToggleButtonAutomationPeer]::new(
                        $control)
                    $provider = $peer.GetPattern(
                        [System.Windows.Automation.Peers.PatternInterface]::Toggle)
                    ([System.Windows.Automation.Provider.IToggleProvider]$provider).Toggle()
                } else {
                    & $raiseClick $control
                }
            }
        }
    }.GetNewClosure()
    $drawRectangle = {
        param([System.Windows.Point]$Start,[System.Windows.Point]$End)
        & $activateTool 'RectangleEllipse'
        & $raiseCanvasDrag $Start @($End) $End
    }.GetNewClosure()
    $clearCanvasContent = {
        & $kit.SetZoom 1.0
        $kit.Scroller.ScrollToHorizontalOffset(0)
        $kit.Scroller.ScrollToVerticalOffset(0)
        if ($kit.State.Annotations.Count -gt 0) {
            & $raiseClick ($kit.Win.FindName('ClearBtn'))
        }
        & $activateTool 'Select'
        & $raiseCanvasClick ([System.Windows.Point]::new(1100,740))
    }.GetNewClosure()
    $invokePropertyEntry = {
        param($Entry)
        if ($Entry.Element -is [System.Windows.Controls.MenuItem]) {
            & $raiseMenuClick $Entry.Element
        } else {
            & $raiseClick $Entry.Element
        }
    }.GetNewClosure()
    $invokeAutomation = {
        param([System.Windows.UIElement]$Element)
        $peer = if ($Element -is [System.Windows.Controls.MenuItem]) {
            [System.Windows.Automation.Peers.MenuItemAutomationPeer]::new($Element)
        } else {
            [System.Windows.Automation.Peers.ButtonAutomationPeer]::new($Element)
        }
        $provider = $peer.GetPattern(
            [System.Windows.Automation.Peers.PatternInterface]::Invoke)
        if ($provider -isnot [System.Windows.Automation.Provider.IInvokeProvider]) {
            throw "$(($Element.GetType()).Name) does not expose InvokeProvider"
        }
        ([System.Windows.Automation.Provider.IInvokeProvider]$provider).Invoke()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }.GetNewClosure()

    $assertFloatingStudioLayout = {
        param(
            [double]$Width,
            [double]$Height,
            [string]$ExpectedMode,
            [string[]]$ExpectedTools
        )

        & $kit.SetResponsiveMode $Width $Height
        Should-Be $kit.ResponsiveMode.Value $ExpectedMode
        Should-Be (($kit.ToolOrder) -join ',') ($ExpectedTools -join ',')

        $bounds = & $kit.GetIslandBounds $Width $Height
        $islandNames = @('Brand','Actions','Property','ToolDock','Viewport','Status')
        foreach ($name in $islandNames) {
            Should-BeTrue $bounds.ContainsKey($name)
            if ($name -ne 'Property' -or
                $kit.PropertyIsland.Visibility -eq [System.Windows.Visibility]::Visible) {
                Should-BeTrue ($bounds[$name].Width -gt 0)
                Should-BeTrue ($bounds[$name].Height -gt 0)
            }
        }
        for ($leftIndex = 0; $leftIndex -lt $islandNames.Count; $leftIndex++) {
            for ($rightIndex = $leftIndex + 1; $rightIndex -lt $islandNames.Count; $rightIndex++) {
                $left = $bounds[$islandNames[$leftIndex]]
                $right = $bounds[$islandNames[$rightIndex]]
                $intersection = [System.Windows.Rect]::Intersect($left, $right)
                if (-not $intersection.IsEmpty -and
                    $intersection.Width -gt 0 -and $intersection.Height -gt 0) {
                    throw ("Floating Studio islands overlap at ${Width}x${Height}: " +
                        "$($islandNames[$leftIndex]) $left and " +
                        "$($islandNames[$rightIndex]) $right")
                }
            }
        }
    }.GetNewClosure()

    Describe 'Native WPF preview layout' {
        $getAncestor = {
            param(
                [System.Windows.DependencyObject]$Element,
                [type]$AncestorType
            )
            $current = $Element
            while ($null -ne $current) {
                if ($AncestorType.IsInstanceOfType($current)) { return $current }
                $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
            }
            $null
        }.GetNewClosure()
        $getBounds = {
            param(
                [System.Windows.FrameworkElement]$Element,
                [System.Windows.FrameworkElement]$RelativeTo
            )
            $origin = $Element.TranslatePoint(
                [System.Windows.Point]::new(0,0), $RelativeTo)
            [System.Windows.Rect]::new(
                $origin.X, $origin.Y, $Element.ActualWidth, $Element.ActualHeight)
        }.GetNewClosure()

        It 'uses native window chrome without a custom WindowChrome attachment' {
            Should-BeFalse ($kit.Win.WindowStyle -eq [System.Windows.WindowStyle]::None)
            Should-Be ([System.Windows.Shell.WindowChrome]::GetWindowChrome($kit.Win)) $null
            Should-Be $kit.Win.ResizeMode ([System.Windows.ResizeMode]::CanResize)
            Should-BeFalse $kit.Win.AllowsTransparency
        }

        It 'uses a ToolBarTray and ToolBar for preview commands' {
            $tray = $kit.Win.FindName('PreviewToolBarTray')
            Should-BeTrue ($tray -is [System.Windows.Controls.ToolBarTray])
            Should-Be $tray.ToolBars.Count 2
            Should-BeTrue ($kit.Win.FindName('PreviewActionToolBar') -is `
                [System.Windows.Controls.ToolBar])
            Should-BeTrue ($kit.Win.FindName('PreviewEditorToolBar') -is `
                [System.Windows.Controls.ToolBar])
        }

        It 'places retained actions and tools directly in native toolbars' {
            $actionBar = $kit.Win.FindName('PreviewActionToolBar')
            $toolBar = $kit.Win.FindName('PreviewEditorToolBar')
            Should-BeTrue ($actionBar -is [System.Windows.Controls.ToolBar])
            Should-BeTrue ($toolBar -is [System.Windows.Controls.ToolBar])
            # Separators are unnamed; the split hosts carry the tool toggles.
            Should-Be (($actionBar.Items | ForEach-Object Name |
                Where-Object { $_ }) -join ',') `
                'CopyBtn,SaveBtn,PinBtn,CloseBtn,NewBtn,DuplicateBtn,DeleteBtn,DimText'
            Should-Be (($toolBar.Items | ForEach-Object Name |
                Where-Object { $_ }) -join ',') `
                ('SelectToolBtn,HighlightBtn,RectangleSplit,ArrowSplit,TextBtn,' +
                 'PenToolBtn,StepsToolBtn,BlurSplit,CropToolBtn,UndoBtn,RedoBtn')
            foreach ($splitName in @('RectangleSplit','ArrowSplit','BlurSplit')) {
                $split = $kit.Win.FindName($splitName)
                Should-BeTrue ($split -is [System.Windows.Controls.StackPanel])
                Should-Be $split.Children.Count 2
            }
            foreach ($pair in @(
                [pscustomobject]@{ Split='RectangleSplit'; Primary='RectangleToolBtn' },
                [pscustomobject]@{ Split='ArrowSplit'; Primary='ArrowToolBtn' },
                [pscustomobject]@{ Split='BlurSplit'; Primary='BlurPixelateToolBtn' })) {
                Should-BeTrue ([object]::ReferenceEquals(
                    $kit.Win.FindName($pair.Split).Children[0],
                    $kit.Win.FindName($pair.Primary)))
            }
            foreach ($name in @('NewBtn','DuplicateBtn','DeleteBtn')) {
                Should-Be ([System.Windows.Controls.ToolBar]::GetOverflowMode(
                    $kit.Win.FindName($name))) `
                    ([System.Windows.Controls.OverflowMode]::Always)
            }
        }

        It 'shows every wired tool and keeps only routing shims out of the band' {
            # Line and Ellipse are entries on their split's menu, not buttons of
            # their own, so they must not exist as separate controls.
            foreach ($name in @(
                'CropToolBtn','PenToolBtn','StepsToolBtn','BlurPixelateToolBtn')) {
                $control = $kit.Win.FindName($name)
                Should-BeTrue ($null -ne $control)
                Should-Be $control.Visibility ([System.Windows.Visibility]::Visible)
            }
            foreach ($name in @('LineToolBtn','EllipseToolBtn','PixelateToolBtn')) {
                Should-Be ($kit.Win.FindName($name)) $null
            }
            foreach ($name in @('ColorToolBtn','MoreBtn')) {
                Should-Be $kit.Win.FindName($name).Visibility `
                    ([System.Windows.Visibility]::Collapsed)
            }
        }

        It 'keeps the ScrollViewer canvas and layer order intact' {
            Should-BeTrue ($kit.Scroller -is [System.Windows.Controls.ScrollViewer])
            Should-Be $kit.Scroller.Content $kit.ImageHost
            Should-Be $kit.PreviewImage.Parent $kit.ImageHost
            Should-Be $kit.Win.FindName('AnnotationLayer').Parent $kit.ImageHost
            Should-Be $kit.Win.FindName('InteractionLayer').Parent $kit.ImageHost
            Should-Be $kit.Win.FindName('SelectionLayer').Parent $kit.ImageHost
            Should-Be $kit.HighlightLayer.Parent $kit.ImageHost
            Should-Be ($kit.ImageHost.Children.IndexOf($kit.PreviewImage)) 0
            Should-Be ($kit.ImageHost.Children.IndexOf($kit.Win.FindName('AnnotationLayer'))) 1
            Should-Be ($kit.ImageHost.Children.IndexOf($kit.Win.FindName('InteractionLayer'))) 2
            Should-Be ($kit.ImageHost.Children.IndexOf($kit.Win.FindName('SelectionLayer'))) 3
            Should-Be ($kit.ImageHost.Children.IndexOf($kit.HighlightLayer)) 4
        }

        It 'uses a standard non-floating contextual property row' {
            $propertyBar = $kit.Win.FindName('PreviewPropertyBar')
            Should-BeTrue ($propertyBar -is [System.Windows.Controls.Panel])
            Should-BeTrue ($null -ne (& $getAncestor $kit.Context.Shell.PropertyPanel `
                ([System.Windows.Controls.Panel])))
            Should-BeTrue ($null -eq $propertyBar.Effect)
        }

        It 'names every interactive element in the editor for assistive tech' {
            # A screen reader announces AutomationProperties.Name, falling back
            # to the content. A glyph-only button whose content is a private-use
            # codepoint therefore announces as garbage unless it is named here.
            $unnamed = [System.Collections.Generic.List[string]]::new()
            $pending = [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
            $pending.Enqueue($kit.StudioRoot)
            while ($pending.Count -gt 0) {
                $node = $pending.Dequeue()
                $element = $node -as [System.Windows.FrameworkElement]
                # IsVisible, not Visibility: the retired compatibility controls
                # live under a Collapsed grid but are themselves Visible.
                if ($null -ne $element -and $element.IsVisible) {
                    $isInteractive =
                        $element -is [System.Windows.Controls.Primitives.ButtonBase] -or
                        $element -is [System.Windows.Controls.TextBox] -or
                        $element -is [System.Windows.Controls.ComboBox] -or
                        $element -is [System.Windows.Controls.Slider]
                    if ($isInteractive) {
                        $name = [System.Windows.Automation.AutomationProperties]::GetName($element)
                        if ([string]::IsNullOrWhiteSpace($name)) {
                            $describe = if ([string]::IsNullOrEmpty($element.Name)) {
                                $element.GetType().Name
                            } else { $element.Name }
                            $unnamed.Add($describe)
                        }
                        # Every actionable control also states its shortcut or
                        # purpose on hover.
                        if ([string]::IsNullOrWhiteSpace([string]$element.ToolTip) -and
                            $element -isnot [System.Windows.Controls.Primitives.RepeatButton]) {
                            $unnamed.Add("$($element.Name) (no tooltip)")
                        }
                    }
                }
                $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                for ($index = 0; $index -lt $childCount; $index++) {
                    $pending.Enqueue(
                        [System.Windows.Media.VisualTreeHelper]::GetChild($node, $index))
                }
            }
            if ($unnamed.Count -gt 0) {
                throw "editor controls without an accessible name or tooltip: $($unnamed -join ', ')"
            }
        }

        It 'uses a StatusBar for status and viewport controls' {
            $statusBar = $kit.Win.FindName('PreviewStatusBar')
            Should-BeTrue ($statusBar -is [System.Windows.Controls.Primitives.StatusBar])
            foreach ($elementName in @(
                'StatusIndicator','StatusText','CoordinateText',
                'ZoomOutBtn','ZoomText','ZoomInBtn','FitBtn')) {
                $element = $kit.Win.FindName($elementName)
                Should-BeTrue ($null -ne $element)
                Should-BeTrue ([object]::ReferenceEquals(
                    (& $getAncestor $element ([System.Windows.Controls.Primitives.StatusBar])),
                    $statusBar))
            }
        }

        It 'has no preview-local island style, custom shell template, or material effect' {
            Should-BeFalse $kit.Win.Resources.Contains('StudioIslandStyle')
            Should-BeFalse $kit.Win.Resources.Contains('StudioToolButtonStyle')
            Should-BeFalse $kit.Win.Resources.Contains('StudioToolToggleStyle')
            Should-Be $kit.StudioRoot.Effect $null
            Should-Be $kit.StudioRoot.Clip $null
            foreach ($name in @(
                'PropertyIsland','ViewportIsland','StatusIsland')) {
                $element = $kit.Win.FindName($name)
                Should-BeTrue ($null -ne $element)
                Should-Be $element.Effect $null
            }
        }

        It 'lays out all native regions at the 760 by 540 minimum without overlap' {
            $kit.Win.Width = 760
            $kit.Win.Height = 540
            & $kit.SetResponsiveMode 760 540 | Out-Null
            $kit.Win.UpdateLayout()

            $tray = $kit.Win.FindName('PreviewToolBarTray')
            $propertyBar = $kit.Win.FindName('PreviewPropertyBar')
            $statusBar = $kit.Win.FindName('PreviewStatusBar')
            $regions = [ordered]@{
                Toolbar = & $getBounds $tray $kit.StudioRoot
                Property = & $getBounds $propertyBar $kit.StudioRoot
                Scroller = & $getBounds $kit.Scroller $kit.StudioRoot
                Status = & $getBounds $statusBar $kit.StudioRoot
            }
            foreach ($entry in $regions.GetEnumerator()) {
                Should-Be $entry.Value.IsEmpty $false
                Should-BeTrue ($entry.Value.Width -gt 0)
                Should-BeTrue ($entry.Value.Height -gt 0)
            }

            $orderedNames = @('Toolbar','Property','Scroller','Status')
            for ($index = 1; $index -lt $orderedNames.Count; $index++) {
                $previous = $regions[$orderedNames[$index - 1]]
                $current = $regions[$orderedNames[$index]]
                Should-BeTrue ($previous.Bottom -le ($current.Top + 0.5))
            }
        }
    }

    Describe 'Floating Studio preview shell' {
        It 'keeps the normal stock window and authoritative editor layer hosts' {
            Should-Be $kit.Win.WindowStyle ([System.Windows.WindowStyle]::SingleBorderWindow)
            Should-Be $kit.Win.ResizeMode ([System.Windows.ResizeMode]::CanResize)
            Should-BeFalse $kit.Win.AllowsTransparency
            Should-Be ([System.Windows.Shell.WindowChrome]::GetWindowChrome($kit.Win)) $null
            Should-Be (($kit.ImageHost.Children | ForEach-Object Name) -join ',') `
                'PreviewImage,AnnotationLayer,InteractionLayer,SelectionLayer,HighlightLayer'
        }

        It 'keeps retained actions in direct native order with access keys' {
            Should-Be (($kit.ActionOrder) -join ',') 'CopyAndClose,Save,Pin,Close'
            $actionBar = $kit.Win.FindName('PreviewActionToolBar')
            Should-Be (($actionBar.Items | ForEach-Object Name |
                Where-Object { $_ }) -join ',') `
                'CopyBtn,SaveBtn,PinBtn,CloseBtn,NewBtn,DuplicateBtn,DeleteBtn,DimText'
            # Glyph + AccessText, never a bare string: a string content would render
            # the mnemonic underscore literally under AccentButtonStyle.
            foreach ($case in @(
                [pscustomobject]@{ Name='CopyBtn'; Label='_Copy & close'; Glyph=0xE8C8 },
                [pscustomobject]@{ Name='SaveBtn'; Label='_Save'; Glyph=0xE74E },
                [pscustomobject]@{ Name='PinBtn'; Label='_Pin'; Glyph=0xE718 },
                [pscustomobject]@{ Name='CloseBtn'; Label='C_lose'; Glyph=0xE711 },
                [pscustomobject]@{ Name='NewBtn'; Label='_New snip'; Glyph=0xE710 },
                [pscustomobject]@{ Name='DuplicateBtn'; Label='_Duplicate'; Glyph=0xE7C4 },
                [pscustomobject]@{ Name='DeleteBtn'; Label='De_lete'; Glyph=0xE74D })) {
                $content = $kit.Win.FindName($case.Name).Content
                Should-BeTrue ($content -is [System.Windows.Controls.StackPanel])
                $glyph = $content.Children[0]
                Should-BeTrue ($glyph -is [System.Windows.Controls.TextBlock])
                Should-Be $glyph.FontFamily.Source 'Segoe Fluent Icons'
                Should-Be $glyph.Text ([string][char]$case.Glyph)
                $label = $content.Children[1]
                Should-BeTrue ($label -is [System.Windows.Controls.AccessText])
                Should-Be $label.Text $case.Label
            }
        }

        It 'gives Copy and close the accent button style' {
            $expected = $kit.Win.TryFindResource('AccentButtonStyle')
            if ($null -ne $expected) {
                Should-BeTrue ([object]::ReferenceEquals(
                    $kit.Win.FindName('CopyBtn').Style, $expected))
            }
        }

        It 'reports the capture size in a right-aligned read-only action-band readout' {
            $readout = $kit.Win.FindName('DimText')
            Should-BeTrue ($readout -is [System.Windows.Controls.TextBlock])
            Should-Be $readout.Text `
                "$($kit.Bitmap.Width) $([char]0x00D7) $($kit.Bitmap.Height) px"
            Should-BeFalse $readout.IsHitTestVisible
            $actionBar = $kit.Win.FindName('PreviewActionToolBar')
            Should-BeTrue ([object]::ReferenceEquals(
                $actionBar.Items[$actionBar.Items.Count - 1], $readout))
            # ToolBar has no right-alignment, so the leading margin is computed.
            $kit.Win.UpdateLayout()
            Should-BeTrue ($readout.Margin.Left -ge 12)
            # HiddenLegacyControls no longer parks it as a dead element.
            $legacy = $kit.Win.FindName('HiddenLegacyControls')
            Should-Be ($legacy.Children.Contains($readout)) $false
            Should-Be ($kit.Win.FindName('DragHeader').Children.Contains($readout)) $false
        }

        It 'projects the approved tool order into the native tool band' {
            $toolBar = $kit.Win.FindName('PreviewEditorToolBar')
            Should-Be (($toolBar.Items | ForEach-Object Name |
                Where-Object { $_ }) -join ',') `
                ('SelectToolBtn,HighlightBtn,RectangleSplit,ArrowSplit,TextBtn,' +
                 'PenToolBtn,StepsToolBtn,BlurSplit,CropToolBtn,UndoBtn,RedoBtn')
            Should-Be (($kit.ToolOrder) -join ',') `
                ('Select,Highlight,RectangleEllipse,ArrowLine,Text,Pen,Steps,' +
                 'BlurPixelate,Crop,Undo,Redo')
            Should-Be $kit.ResponsiveMode.Value 'Native'
            foreach ($case in @(
                [pscustomobject]@{ Name='SelectToolBtn'; Label='_Select'; Glyph=0xE8B3 },
                [pscustomobject]@{ Name='HighlightBtn'; Label='_Highlight'; Glyph=0xE7E6 },
                [pscustomobject]@{ Name='RectangleToolBtn'; Label='_Rectangle'; Glyph=0xE739 },
                [pscustomobject]@{ Name='ArrowToolBtn'; Label='_Arrow'; Glyph=0xE72A },
                [pscustomobject]@{ Name='TextBtn'; Label='_Text'; Glyph=0xE8D2 },
                [pscustomobject]@{ Name='PenToolBtn'; Label='P_en'; Glyph=0xE70F },
                [pscustomobject]@{ Name='StepsToolBtn'; Label='_Steps'; Glyph=0xE8FD },
                [pscustomobject]@{ Name='BlurPixelateToolBtn'; Label='_Blur'; Glyph=0xEB42 },
                [pscustomobject]@{ Name='CropToolBtn'; Label='C_rop'; Glyph=0xE7A8 },
                [pscustomobject]@{ Name='UndoBtn'; Label='_Undo'; Glyph=0xE7A7 },
                [pscustomobject]@{ Name='RedoBtn'; Label='_Redo'; Glyph=0xE7A6 })) {
                $content = $kit.Win.FindName($case.Name).Content
                Should-BeTrue ($content -is [System.Windows.Controls.StackPanel])
                Should-Be $content.Children[0].Text ([string][char]$case.Glyph)
                Should-Be $content.Children[0].FontFamily.Source 'Segoe Fluent Icons'
                Should-Be $content.Children[1].Text $case.Label
            }
        }

        It 're-applies the ToolBar style keys to split-button primaries' {
            # ToolBar only pushes its style keys onto direct children, so a primary
            # nested in a split StackPanel would otherwise stop matching its row.
            $expected = $kit.Win.TryFindResource(
                [System.Windows.Controls.ToolBar]::ToggleButtonStyleKey)
            if ($null -ne $expected) {
                foreach ($name in @('RectangleToolBtn','ArrowToolBtn')) {
                    Should-BeTrue ([object]::ReferenceEquals(
                        $kit.Win.FindName($name).Style, $expected))
                }
            }
        }

        It 'shows the keyboard hint right-aligned in the trailing status bar item' {
            $hintItem = $kit.Win.FindName('StatusHintItem')
            $hintText = $kit.Win.FindName('StatusHintText')
            Should-BeTrue ($hintItem -is [System.Windows.Controls.Primitives.StatusBarItem])
            Should-Be $hintItem.HorizontalContentAlignment `
                ([System.Windows.HorizontalAlignment]::Right)
            Should-Be $hintText.Text `
                "Ctrl+Enter copy $([char]0x00B7) Ctrl+S save $([char]0x00B7) Esc close"
            $statusBar = $kit.Win.FindName('PreviewStatusBar')
            Should-BeTrue ([object]::ReferenceEquals(
                $statusBar.Items[$statusBar.Items.Count - 1], $hintItem))
        }

        It 'paints the status indicator with the Fluent success fill' {
            # SystemColors.ControlTextBrush is near-black, so the dot vanished
            # against the Dark status bar once the preview started following the
            # system theme. Fluent's own semantic success fill reads in both.
            $indicator = $kit.Win.FindName('StatusIndicator')
            Should-BeTrue ($indicator.Fill -is [System.Windows.Media.SolidColorBrush])
            $expected = $kit.Win.TryFindResource('SystemFillColorSuccessBrush')
            if ($null -ne $expected) {
                Should-Be $indicator.Fill.Color.ToString() $expected.Color.ToString()
            }
        }

        It 'keeps New Duplicate and Delete reachable through native overflow' {
            foreach ($name in @('NewBtn','DuplicateBtn','DeleteBtn')) {
                $control = $kit.Win.FindName($name)
                Should-Be ([System.Windows.Controls.ToolBar]::GetOverflowMode($control)) `
                    ([System.Windows.Controls.OverflowMode]::Always)
            }
            Should-BeTrue $kit.Win.FindName('NewBtn').IsEnabled
            Should-BeFalse $kit.Win.FindName('DuplicateBtn').IsEnabled
            Should-BeFalse $kit.Win.FindName('DeleteBtn').IsEnabled
        }

        It 'gives every split an enabled chevron over a live alternate menu' {
            foreach ($case in @(
                [pscustomobject]@{ Split='RectangleSplit'
                    Name='RectangleEllipse'; Options='Rectangle,Ellipse' },
                [pscustomobject]@{ Split='ArrowSplit'
                    Name='ArrowLine'; Options='Arrow,Line' },
                [pscustomobject]@{ Split='BlurSplit'
                    Name='BlurPixelate'; Options='Blur,Pixelate' })) {
                $chevron = $kit.Win.FindName($case.Split).Children[1]
                Should-BeTrue ($chevron -is [System.Windows.Controls.Button])
                Should-BeTrue $chevron.IsEnabled
                Should-Be $chevron.Content.Text ([string][char]0xE70D)
                $split = $kit.Context.SplitControls[$case.Name]
                Should-BeTrue ([object]::ReferenceEquals($split.OptionsButton,$chevron))
                Should-BeTrue ($split.Menu -is [System.Windows.Controls.ContextMenu])
                Should-Be (($split.MenuItems.Keys) -join ',') $case.Options
                Should-BeTrue ($null -ne $split.OpenOptions)
            }
            Should-BeTrue ($null -ne $kit.Context.ToolProperties.Crop)
            Should-BeTrue ($null -ne $kit.Context.SplitControls.BlurPixelate)
        }

        It 'preserves retained shortcuts and routes direct tools into the editor engine' {
            Should-Be $kit.Win.FindName('CopyBtn').ToolTip 'Copy and close (Ctrl+Enter)'
            Should-Be $kit.Win.FindName('SaveBtn').ToolTip 'Save (Ctrl+S)'
            Should-Be $kit.Win.FindName('CloseBtn').ToolTip 'Close preview (Alt+F4)'
            Should-Be $kit.Win.FindName('UndoBtn').ToolTip 'Undo (Ctrl+Z)'
            Should-Be $kit.Win.FindName('RedoBtn').ToolTip 'Redo (Ctrl+Shift+Z)'
            & $activateTool 'ArrowLine'
            Should-Be $kit.State.ActiveStudioTool 'ArrowLine'
            & $activateTool 'RectangleEllipse'
            Should-Be $kit.State.ActiveStudioTool 'RectangleEllipse'
            & $activateTool 'Select'
        }

        It 'keeps stock bars collision-free at all approved window sizes' {
            foreach ($size in @(
                [pscustomobject]@{ Width=760; Height=540 },
                [pscustomobject]@{ Width=900; Height=600 },
                [pscustomobject]@{ Width=1200; Height=700 })) {
                $kit.Win.Width = $size.Width
                $kit.Win.Height = $size.Height
                & $kit.SetResponsiveMode $size.Width $size.Height
                $kit.Win.UpdateLayout()
                Should-Be $kit.ResponsiveMode.Value 'Native'
                $toolbar = $kit.Win.FindName('PreviewToolBarTray')
                $property = $kit.Win.FindName('PreviewPropertyBar')
                $status = $kit.Win.FindName('PreviewStatusBar')
                Should-BeTrue ($toolbar.ActualHeight -gt 0)
                Should-BeTrue ($property.ActualHeight -gt 0)
                Should-BeTrue ($kit.Scroller.ActualHeight -gt 0)
                Should-BeTrue ($status.ActualHeight -gt 0)
            }
        }

        It 'keeps Preview placement inside the selected monitor work area' {
            Should-BeTrue ($kit.Context.InitialPhysicalBounds.Width -gt 0)
            Should-BeTrue ($kit.Context.InitialPhysicalBounds.Height -gt 0)
            Should-BeTrue ($kit.Context.PlacementState.Effect.Name -eq 'ApplyPlacement')
        }

    }
    Describe 'Task 7 routed Select contract' {
        It 'publishes authoritative context aliases and the complete ordered layer stack' {
            Should-BeTrue ([object]::ReferenceEquals(
                $kit.Context.Annotations,$kit.State.Annotations))
            Should-BeTrue ([object]::ReferenceEquals(
                $kit.Context.UndoStack,$kit.State.UndoStack))
            Should-BeTrue ([object]::ReferenceEquals(
                $kit.Context.RedoStack,$kit.State.RedoStack))
            Should-BeTrue ([object]::ReferenceEquals(
                $kit.Context.BitmapSource,$kit.PreviewImage.Source))
            Should-BeTrue $kit.Context.BitmapSource.IsFrozen
            Should-Be (($kit.ImageHost.Children | ForEach-Object Name) -join ',') `
                'PreviewImage,AnnotationLayer,InteractionLayer,SelectionLayer,HighlightLayer'
            & $activateTool 'Crop'
            Should-Be $kit.Context.ActiveTool 'Crop'
            Should-Be $kit.State.ActiveStudioTool 'Crop'
            & $activateTool 'Select'
            Should-Be $kit.Context.ActiveTool 'Select'
            Should-Be $kit.State.ActiveStudioTool 'Select'
        }

        It 'render and zoom preserve canonical record identity while legacy normalization runs once' {
            try {
                & $clearCanvasContent
                $record = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
                    Type='Bounds'; X=75; Y=60; Width=125; Height=90
                }) -Color Blue -StrokeWidth 3 -Opacity 0.75 `
                    -Properties ([ordered]@{ Fill=$false }) -Z 7
                $kit.Context.Annotations.Add($record) | Out-Null
                $semanticBefore = $record | ConvertTo-Json -Depth 20 -Compress

                & $kit.Render
                Should-BeTrue ([object]::ReferenceEquals(
                    $record,$kit.Context.Annotations[0]))
                & $kit.SetZoom 1.25
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                    [Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                Should-BeTrue ([object]::ReferenceEquals(
                    $record,$kit.Context.Annotations[0]))
                Should-Be ($kit.Context.Annotations[0] |
                    ConvertTo-Json -Depth 20 -Compress) $semanticBefore

                $kit.Context.Annotations.Clear()
                $legacyRecord = [pscustomobject]@{
                    Type='highlight'; Color='Yellow'; X=4; Y=6; W=30; H=20
                    Text=$null; FontSize=0
                }
                $kit.Context.Annotations.Add($legacyRecord) | Out-Null
                & $kit.Render
                $normalized = $kit.Context.Annotations[0]
                Should-BeFalse ([string]::IsNullOrWhiteSpace([string]$normalized.Id))
                Should-BeFalse ([object]::ReferenceEquals($legacyRecord,$normalized))
                & $kit.Render
                Should-BeTrue ([object]::ReferenceEquals(
                    $normalized,$kit.Context.Annotations[0]))
                Should-Be $kit.Context.Annotations[0].Id $normalized.Id
            } finally {
                & $clearCanvasContent
            }
        }

        It 'actual selection and render routes honor Z ahead of conflicting list order' {
            try {
                & $clearCanvasContent
                $high = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
                    Type='Bounds'; X=80; Y=80; Width=140; Height=100
                }) -Color Red -StrokeWidth 3 -Opacity 1 -Properties ([ordered]@{}) -Z 9
                $low = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
                    Type='Bounds'; X=80; Y=80; Width=140; Height=100
                }) -Color Blue -StrokeWidth 3 -Opacity 1 -Properties ([ordered]@{}) -Z 1
                $kit.Context.Annotations.Add($high) | Out-Null
                $kit.Context.Annotations.Add($low) | Out-Null
                & $kit.Render
                $renderedIds = @($kit.AnnotationLayer.Children | ForEach-Object Tag |
                    Where-Object Role -eq 'Annotation' | ForEach-Object Id)
                Should-Be ($renderedIds -join ',') "$($low.Id),$($high.Id)"

                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(120,120))
                Should-Be $kit.Context.SelectedAnnotationId $high.Id
                Should-Be $kit.Context.LastHitRoute 'Find-SnipAnnotation'
            } finally {
                & $clearCanvasContent
            }
        }

        It 'draws an arrow as a shortened shaft plus a filled triangular head' {
            try {
                & $clearCanvasContent
                $arrow = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
                    Type='Line'
                    Start=[pscustomobject]@{ X=100.0; Y=100.0 }
                    End=[pscustomobject]@{ X=300.0; Y=100.0 }
                }) -Color Red -StrokeWidth 6 -Opacity 1 -Properties ([ordered]@{}) -Z 1
                $kit.Context.Annotations.Add($arrow) | Out-Null
                & $kit.Render

                $head = @($kit.AnnotationLayer.Children |
                    Where-Object { $_ -is [System.Windows.Shapes.Polygon] -and
                        $_.Tag.Role -eq 'ArrowHead' -and $_.Tag.Id -eq $arrow.Id })
                Should-Be $head.Count 1
                Should-Be $head[0].Points.Count 3
                Should-BeTrue ($null -ne $head[0].Fill)
                # length 4 x width, half-width 2 x width, minimum 10px.
                Should-Be $head[0].Points[0].X 300.0
                Should-Be $head[0].Points[1].X 276.0
                Should-Be ([math]::Abs($head[0].Points[1].Y - $head[0].Points[2].Y)) 24.0

                # The shaft stops short of the tip so the stroke never pokes through.
                $shaft = @($kit.AnnotationLayer.Children |
                    Where-Object { $_ -is [System.Windows.Shapes.Line] -and
                        $_.Tag.Id -eq $arrow.Id })
                Should-Be $shaft.Count 1
                Should-Be $shaft[0].X2 282.0
                Should-Be $shaft[0].StrokeEndLineCap `
                    ([System.Windows.Media.PenLineCap]::Round)

                # Only one visual per record carries Role='Annotation'.
                Should-Be @($kit.AnnotationLayer.Children | ForEach-Object Tag |
                    Where-Object Role -eq 'Annotation').Count 1

                # Hit-testing still finds the arrow along its shaft.
                Should-BeTrue ((& $kit.FindAt 200.0 100.0) -ge 0)

                # The exported bitmap paints the same filled head.
                $flat = & $kit.Flatten
                try {
                    $inside = $flat.GetPixel(292, 100)
                    Should-BeTrue ($inside.R -gt 200 -and $inside.G -lt 110 -and
                        $inside.B -lt 110)
                } finally {
                    if (-not [object]::ReferenceEquals($flat,$kit.Bitmap)) {
                        $flat.Dispose()
                    }
                }
            } finally {
                & $clearCanvasContent
            }
        }

        It 'gives the arrow draft the same head it commits' {
            try {
                & $clearCanvasContent
                & $activateTool 'ArrowLine'
                & $kit.BeginDraw 'arrow' ([System.Windows.Point]::new(120.0,400.0))
                & $kit.UpdateDraw ([System.Windows.Point]::new(320.0,400.0))
                $draftHeads = @($kit.InteractionLayer.Children |
                    Where-Object { $_ -is [System.Windows.Shapes.Polygon] })
                Should-Be $draftHeads.Count 1
                Should-Be $draftHeads[0].Points.Count 3
                Should-Be $draftHeads[0].Points[0].X 320.0
                & $kit.FinishDraw
                Should-Be @($kit.InteractionLayer.Children |
                    Where-Object { $_ -is [System.Windows.Shapes.Polygon] }).Count 0
            } finally {
                & $clearCanvasContent
            }
        }

        It 'WPF and flattened output share ascending Z projection without mutating sources or records' {
            $flat = $null
            try {
                & $clearCanvasContent
                $high = New-SnipAnnotation -Kind Highlight -Geometry ([pscustomobject]@{
                    Type='Bounds'; X=90; Y=90; Width=150; Height=120
                }) -Color Blue -StrokeWidth 1.5 -Opacity 1 `
                    -Properties ([ordered]@{}) -Z 20
                $low = New-SnipAnnotation -Kind Highlight -Geometry ([pscustomobject]@{
                    Type='Bounds'; X=90; Y=90; Width=150; Height=120
                }) -Color Red -StrokeWidth 1.5 -Opacity 1 `
                    -Properties ([ordered]@{}) -Z 2
                $kit.Context.Annotations.Add($high) | Out-Null
                $kit.Context.Annotations.Add($low) | Out-Null
                $highBefore = $high | ConvertTo-Json -Depth 20 -Compress
                $lowBefore = $low | ConvertTo-Json -Depth 20 -Compress
                $sourcePixel = $kit.Bitmap.GetPixel(150,150).ToArgb()

                & $kit.Render
                $wpfIds = @($kit.AnnotationLayer.Children | ForEach-Object Tag |
                    Where-Object Role -eq 'Annotation' | ForEach-Object Id)
                Should-Be ($wpfIds -join ',') "$($low.Id),$($high.Id)"

                $flat = & $kit.Flatten
                Should-BeFalse ([object]::ReferenceEquals($flat,$kit.Bitmap))
                $flattenedPixel = $flat.GetPixel(150,150)
                Should-Be $flattenedPixel.ToArgb() `
                    ([System.Drawing.Color]::FromArgb(255,80,170,255).ToArgb())
                Should-Be $kit.Bitmap.GetPixel(150,150).ToArgb() $sourcePixel
                Should-BeTrue ([object]::ReferenceEquals(
                    $high,$kit.Context.Annotations[0]))
                Should-BeTrue ([object]::ReferenceEquals(
                    $low,$kit.Context.Annotations[1]))
                Should-Be ($high | ConvertTo-Json -Depth 20 -Compress) $highBefore
                Should-Be ($low | ConvertTo-Json -Depth 20 -Compress) $lowBefore
            } finally {
                if ($null -ne $flat -and
                    -not [object]::ReferenceEquals($flat,$kit.Bitmap)) {
                    $flat.Dispose()
                    $disposed = $false
                    try { $flat.GetPixel(0,0) | Out-Null } catch { $disposed = $true }
                    Should-BeTrue $disposed
                }
                & $clearCanvasContent
            }
        }

        It 'native overflow Duplicate creates one selected top copy and preserves undo redo identity' {
            try {
                & $clearCanvasContent
                $kit.Win.Width=1240; $kit.Win.Height=760
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                    [Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                & $kit.SetResponsiveMode 1240 760
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(220,180))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))
                $source = @($kit.Context.Annotations)[0]
                $sourceBefore = $source | ConvertTo-Json -Depth 20 -Compress
                $kit.Context.RedoStack.Push((New-SnipEditorSnapshot `
                    -Annotations $kit.Context.Annotations `
                    -CropRectangle $kit.Context.CropRectangle))
                $historyBefore = $kit.Context.UndoStack.Count

                $duplicateButton = $kit.Win.FindName('DuplicateBtn')
                Should-BeTrue ($duplicateButton -is [System.Windows.Controls.Button])
                & $invokeAutomation $duplicateButton

                Should-Be $kit.Context.Annotations.Count 2
                Should-Be $kit.Context.UndoStack.Count ($historyBefore + 1)
                Should-Be $kit.Context.RedoStack.Count 0
                Should-BeTrue ([object]::ReferenceEquals(
                    $source,$kit.Context.Annotations[0]))
                Should-Be ($source | ConvertTo-Json -Depth 20 -Compress) $sourceBefore
                $duplicate = $kit.Context.Annotations[1]
                Should-BeFalse ($duplicate.Id -eq $source.Id)
                Should-Be $kit.Context.SelectedAnnotationId $duplicate.Id
                Should-Be $duplicate.Kind $source.Kind
                Should-Be $duplicate.Color $source.Color
                Should-Be $duplicate.StrokeWidth $source.StrokeWidth
                Should-Be $duplicate.Opacity $source.Opacity
                Should-Be ($duplicate.Properties | ConvertTo-Json -Depth 20 -Compress) `
                    ($source.Properties | ConvertTo-Json -Depth 20 -Compress)
                $expected = Move-SnipAnnotation -Annotation $source `
                    -DeltaX 12 -DeltaY 12 -SourceWidth $kit.Bitmap.Width `
                    -SourceHeight $kit.Bitmap.Height
                Should-Be ($duplicate.Geometry | ConvertTo-Json -Depth 20 -Compress) `
                    ($expected.Geometry | ConvertTo-Json -Depth 20 -Compress)
                Should-Be $duplicate.Z ([double]$source.Z + 1.0)
                $renderedIds = @($kit.AnnotationLayer.Children | ForEach-Object Tag |
                    Where-Object Role -eq 'Annotation' | ForEach-Object Id)
                Should-Be $renderedIds[-1] $duplicate.Id

                $duplicateId = $duplicate.Id
                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be (@($kit.Context.Annotations | Where-Object Id -eq $duplicateId)).Count 0
                Should-Be (@($kit.Context.Annotations | Where-Object Id -eq $source.Id)).Count 1
                & $raiseClick ($kit.Win.FindName('RedoBtn'))
                Should-Be (@($kit.Context.Annotations | Where-Object Id -eq $duplicateId)).Count 1
                Should-Be (@($kit.Context.Annotations | Where-Object Id -eq $source.Id)).Count 1
            } finally {
                $kit.Win.Width=1180; $kit.Win.Height=760
                & $kit.SetResponsiveMode 1200 700
                & $clearCanvasContent
            }
        }


        It 'actual canvas click selects the topmost overlapping record and empty click clears without history' {
            try {
                & $clearCanvasContent
                & $kit.SetZoom 1.0
                & $drawRectangle ([System.Windows.Point]::new(40,40)) `
                    ([System.Windows.Point]::new(180,150))
                & $drawRectangle ([System.Windows.Point]::new(70,70)) `
                    ([System.Windows.Point]::new(210,175))
                Should-Be $kit.State.Annotations.Count 2

                & $activateTool 'Select'
                $historyBeforeSelection = $kit.State.UndoStack.Count
                & $raiseCanvasClick ([System.Windows.Point]::new(100,100))

                $expectedTopId = $kit.State.Annotations[1].Id
                Should-Be $kit.Context.SelectedAnnotationId $expectedTopId
                Should-Be $kit.State.SelectionId $expectedTopId
                Should-Be $kit.State.UndoStack.Count $historyBeforeSelection
                Should-Be $kit.PropertyIsland.Visibility ([System.Windows.Visibility]::Visible)

                & $raiseCanvasClick ([System.Windows.Point]::new(500,400))
                Should-Be $kit.Context.SelectedAnnotationId $null
                Should-Be $kit.State.SelectionId $null
                Should-Be $kit.State.UndoStack.Count $historyBeforeSelection
            } finally {
                & $clearCanvasContent
            }
        }

        It 'mint selection handles render above content at a constant DIP size across zoom' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(220,180))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))

                Should-BeTrue ($kit.AnnotationLayer -is [System.Windows.Controls.Canvas])
                Should-BeTrue ($kit.InteractionLayer -is [System.Windows.Controls.Canvas])
                Should-BeTrue ($kit.SelectionLayer -is [System.Windows.Controls.Canvas])
                Should-BeTrue ($kit.ImageHost.Children.IndexOf($kit.SelectionLayer) -gt
                    $kit.ImageHost.Children.IndexOf($kit.AnnotationLayer))
                Should-BeTrue $kit.HighlightLayer.Focusable

                # Selection chrome takes the Windows accent off the stock Fluent
                # key rather than a brush this repo owns.
                $accent = $kit.Win.TryFindResource('AccentFillColorDefaultBrush')
                foreach ($zoom in @(0.5,1.0,2.0)) {
                    & $kit.SetZoom $zoom
                    $handles = @($kit.SelectionLayer.Children | Where-Object {
                        $null -ne $_.Tag -and $_.Tag.Role -eq 'SelectionHandle'
                    })
                    Should-Be $handles.Count 8
                    foreach ($handle in $handles) {
                        Should-Be ($handle.Width * $zoom) 10 0.01
                        Should-Be ($handle.Height * $zoom) 10 0.01
                        if ($null -ne $accent) {
                            Should-Be $handle.Fill.Color.ToString() $accent.Color.ToString()
                        }
                    }
                    $outline = @($kit.SelectionLayer.Children | Where-Object {
                        $null -ne $_.Tag -and $_.Tag.Role -eq 'SelectionOutline'
                    }) | Select-Object -First 1
                    Should-BeTrue ($null -ne $outline)
                    Should-Be ($outline.StrokeThickness * $zoom) 2 0.01
                    if ($null -ne $accent) {
                        Should-Be $outline.Stroke.Color.ToString() $accent.Color.ToString()
                    }
                }
            } finally {
                & $kit.SetZoom 1.0
                & $clearCanvasContent
            }
        }

        It 'routed move commits exactly one semantic history entry on release' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(220,180))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))
                $selectedId = $kit.Context.SelectedAnnotationId
                $original = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                $originalX = $original.Geometry.X
                $originalY = $original.Geometry.Y
                $historyBefore = $kit.Context.UndoStack.Count

                & $raiseCanvasDown ([System.Windows.Point]::new(150,140))
                & $raiseCanvasMove ([System.Windows.Point]::new(160,150))
                & $raiseCanvasMove ([System.Windows.Point]::new(180,160))
                $stillCommitted = @($kit.Context.Annotations |
                    Where-Object Id -eq $selectedId)[0]
                Should-Be $stillCommitted.Geometry.X $originalX
                Should-Be $stillCommitted.Geometry.Y $originalY
                Should-Be $kit.Context.Interaction.Candidate.Geometry.X ($originalX + 30)
                Should-Be $kit.Context.Interaction.Candidate.Geometry.Y ($originalY + 20)
                Should-Be $kit.Context.UndoStack.Count $historyBefore
                & $raiseCanvasUp ([System.Windows.Point]::new(180,160))

                $moved = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-Be $moved.Id $original.Id
                Should-Be $moved.Geometry.X ($originalX + 30)
                Should-Be $moved.Geometry.Y ($originalY + 20)
                Should-Be $kit.Context.UndoStack.Count ($historyBefore + 1)
                Should-Be $kit.Context.Interaction $null
            } finally {
                & $clearCanvasContent
            }
        }

        It 'routed resize crosses an edge safely and commits one history entry' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $selectedId = $kit.Context.SelectedAnnotationId
                $historyBefore = $kit.Context.UndoStack.Count
                $topLeftHandle = @($kit.SelectionLayer.Children | Where-Object {
                    $null -ne $_.Tag -and $_.Tag.Role -eq 'SelectionHandle' -and
                    $_.Tag.Handle -eq 'TopLeft'
                })[0]
                $handleStart = [System.Windows.Point]::new(
                    [System.Windows.Controls.Canvas]::GetLeft($topLeftHandle) +
                        $topLeftHandle.Width/2,
                    [System.Windows.Controls.Canvas]::GetTop($topLeftHandle) +
                        $topLeftHandle.Height/2)
                $original = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                $originalRight = $original.Geometry.X + $original.Geometry.Width
                $originalBottom = $original.Geometry.Y + $original.Geometry.Height
                $crossedEnd = [System.Windows.Point]::new(
                    $originalRight + 30,$originalBottom + 30)

                & $raiseCanvasDown $handleStart
                & $raiseCanvasMove ([System.Windows.Point]::new(
                    $originalRight + 10,$originalBottom + 10))
                & $raiseCanvasMove $crossedEnd
                $stillCommitted = @($kit.Context.Annotations |
                    Where-Object Id -eq $selectedId)[0]
                Should-Be $stillCommitted.Geometry.X $original.Geometry.X
                Should-Be $stillCommitted.Geometry.Y $original.Geometry.Y
                Should-Be $kit.Context.UndoStack.Count $historyBefore
                & $raiseCanvasUp $crossedEnd

                $resized = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-Be $resized.Id $selectedId
                Should-Be $resized.Geometry.X $originalRight
                Should-Be $resized.Geometry.Y $originalBottom
                Should-Be $resized.Geometry.Width 30
                Should-Be $resized.Geometry.Height 30
                Should-Be $kit.Context.UndoStack.Count ($historyBefore + 1)
            } finally {
                & $clearCanvasContent
            }
        }

        It 'a routed line-endpoint collapse is rejected as a no-op without history' {
            try {
                & $clearCanvasContent
                $line = New-SnipAnnotation -Kind Line -Geometry ([pscustomobject]@{
                    Type='Line'
                    Start=[pscustomobject]@{ X=100; Y=100 }
                    End=[pscustomobject]@{ X=220; Y=100 }
                }) -Color Green -StrokeWidth 4 -Opacity 1 `
                    -Properties ([ordered]@{}) -Z 2
                $kit.Context.Annotations.Add($line) | Out-Null
                & $kit.Render
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(160,100))
                $historyBefore = $kit.Context.UndoStack.Count

                & $raiseCanvasDown ([System.Windows.Point]::new(220,100))
                Should-Be $kit.Context.Interaction.Handle 'End'
                & $raiseCanvasMove ([System.Windows.Point]::new(100,100))
                Should-Be $kit.Context.Interaction.Candidate.Geometry.End.X 220
                Should-Be $kit.Context.Interaction.Candidate.Geometry.End.Y 100
                & $raiseCanvasUp ([System.Windows.Point]::new(100,100))

                Should-Be $kit.Context.UndoStack.Count $historyBefore
                Should-Be $kit.Context.Annotations[0].Geometry.End.X 220
                Should-Be $kit.Context.Annotations[0].Geometry.End.Y 100
            } finally {
                & $clearCanvasContent
            }
        }

        It 'no-op and Escape-cancelled gestures create no history or committed mutation' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(220,180))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))
                $selectedId = $kit.Context.SelectedAnnotationId
                $original = Copy-SnipAnnotation -Annotation `
                    (@($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0])
                $historyBefore = $kit.Context.UndoStack.Count

                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))
                Should-Be $kit.Context.UndoStack.Count $historyBefore

                & $raiseCanvasDown ([System.Windows.Point]::new(150,140))
                & $raiseCanvasMove ([System.Windows.Point]::new(190,175))
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $escape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                Should-BeTrue $escape.Handled
                $after = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-Be $after.Geometry.X $original.Geometry.X
                Should-Be $after.Geometry.Y $original.Geometry.Y
                Should-Be $kit.Context.UndoStack.Count $historyBefore
                Should-Be $kit.Context.Interaction $null
            } finally {
                & $clearCanvasContent
            }
        }

        It 'tool switch and real capture loss cancel drafts and a replacement edit clears redo' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(220,180))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))
                $selectedId = $kit.Context.SelectedAnnotationId
                $historyBefore = $kit.Context.UndoStack.Count
                $originalX = $kit.Context.Annotations[0].Geometry.X

                & $raiseCanvasDown ([System.Windows.Point]::new(150,140))
                & $raiseCanvasMove ([System.Windows.Point]::new(190,170))
                & $activateTool 'Crop'
                Should-Be $kit.Context.Interaction $null
                Should-Be $kit.Context.Annotations[0].Geometry.X $originalX
                Should-Be $kit.Context.UndoStack.Count $historyBefore

                & $activateTool 'Select'
                & $raiseCanvasDown ([System.Windows.Point]::new(150,140))
                & $raiseCanvasMove ([System.Windows.Point]::new(180,160))
                $lostCapture = [SnipTestMouseEventArgs]::new(
                    [System.Windows.Input.Mouse]::PrimaryDevice,
                    [Environment]::TickCount,
                    [System.Windows.Point]::new(180,160))
                $lostCapture.RoutedEvent = [System.Windows.Input.Mouse]::LostMouseCaptureEvent
                $kit.HighlightLayer.RaiseEvent($lostCapture)
                Should-Be $kit.Context.Interaction $null
                Should-Be $kit.Context.Annotations[0].Geometry.X $originalX
                Should-Be $kit.Context.UndoStack.Count $historyBefore

                & $raiseCanvasDown ([System.Windows.Point]::new(150,140))
                & $raiseCanvasMove ([System.Windows.Point]::new(180,160))
                & $raiseCanvasUp ([System.Windows.Point]::new(180,160))
                Should-Be $kit.Context.Annotations[0].Id $selectedId
                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be $kit.Context.RedoStack.Count 1
                & $raiseCanvasClick ([System.Windows.Point]::new(150,140))
                & $raiseCanvasDown ([System.Windows.Point]::new(150,140))
                & $raiseCanvasMove ([System.Windows.Point]::new(165,150))
                & $raiseCanvasUp ([System.Windows.Point]::new(165,150))
                Should-Be $kit.Context.RedoStack.Count 0
            } finally {
                & $kit.SetZoom 1.0
                $kit.Scroller.ScrollToHorizontalOffset(0)
                $kit.Scroller.ScrollToVerticalOffset(0)
                & $clearCanvasContent
            }
        }

        It 'zoomed and panned routed move clamps at source edges and inward handle drag stays normalized' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(10,10)) `
                    ([System.Windows.Point]::new(100,80))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(50,40))
                $selectedId = $kit.Context.SelectedAnnotationId
                & $kit.SetZoom 2.0
                $kit.Scroller.ScrollToHorizontalOffset(70)
                $kit.Scroller.ScrollToVerticalOffset(50)
                $kit.Win.UpdateLayout()

                & $raiseCanvasDown ([System.Windows.Point]::new(50,40))
                & $raiseCanvasMove ([System.Windows.Point]::new(-500,-500))
                $candidate = $kit.Context.Interaction.Candidate
                Should-Be $kit.Context.Annotations[0].Geometry.X 10
                Should-Be $kit.Context.Annotations[0].Geometry.Y 10
                Should-Be $candidate.Geometry.X 0
                Should-Be $candidate.Geometry.Y 0
                & $raiseCanvasUp ([System.Windows.Point]::new(-500,-500))
                $clamped = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-Be $clamped.Geometry.X 0
                Should-Be $clamped.Geometry.Y 0

                $rightHandle = @($kit.SelectionLayer.Children | Where-Object {
                    $null -ne $_.Tag -and $_.Tag.Role -eq 'SelectionHandle' -and
                    $_.Tag.Handle -eq 'Right'
                })[0]
                $rightStart = [System.Windows.Point]::new(
                    [System.Windows.Controls.Canvas]::GetLeft($rightHandle)+$rightHandle.Width/2,
                    [System.Windows.Controls.Canvas]::GetTop($rightHandle)+$rightHandle.Height/2)
                & $raiseCanvasDown $rightStart
                & $raiseCanvasMove ([System.Windows.Point]::new(-30,$rightStart.Y))
                & $raiseCanvasUp ([System.Windows.Point]::new(-30,$rightStart.Y))
                $inward = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-BeTrue ($inward.Geometry.X -ge 0)
                Should-BeTrue ($inward.Geometry.Width -ge 1)
                Should-BeTrue (($inward.Geometry.X+$inward.Geometry.Width) -le $kit.Bitmap.Width)
            } finally {
                & $kit.SetZoom 1.0
                $kit.Scroller.ScrollToHorizontalOffset(0)
                $kit.Scroller.ScrollToVerticalOffset(0)
                & $clearCanvasContent
            }
        }

    }

    Describe 'Task 7 authoritative annotation draft contract' {
        foreach ($case in @(
            @{ Tool='RectangleEllipse'; SemanticTool='rect' },
            @{ Tool='Highlight'; SemanticTool='highlight' },
            @{ Tool='ArrowLine'; SemanticTool='arrow' }
        )) {
            It "publishes and cancels the $($case.Tool) draft before changing tools" {
                try {
                    & $clearCanvasContent
                    & $activateTool $case.Tool
                    $annotationCount = $kit.Context.Annotations.Count
                    $historyCount = $kit.Context.UndoStack.Count

                    & $raiseCanvasDown ([System.Windows.Point]::new(140,120))
                    & $raiseCanvasMove ([System.Windows.Point]::new(260,210))

                    Should-BeTrue ($null -ne $kit.Context.Draft)
                    Should-Be $kit.Context.Draft.Kind 'Annotation'
                    Should-Be $kit.Context.Draft.Tool $case.SemanticTool
                    Should-BeTrue ([object]::ReferenceEquals(
                        $kit.Context.Draft,$kit.State.Draft))
                    Should-BeTrue ($null -ne $kit.Context.Interaction)
                    Should-Be $kit.Context.Interaction.Kind 'Annotation'
                    Should-Be $kit.Context.Interaction.Mode 'Create'
                    Should-BeTrue ([object]::ReferenceEquals(
                        $kit.Context.Draft,$kit.Context.Interaction.Draft))
                    Should-BeTrue $kit.State.Drawing
                    Should-BeTrue ([object]::ReferenceEquals(
                        $kit.Context.Draft.Visual,$kit.State.DraftRect))

                    $firstEscape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                    Should-BeTrue $firstEscape.Handled
                    Should-Be $kit.Context.CommandRouter.LastCommand 'CancelDraft'
                    Should-Be $kit.Context.Draft $null
                    Should-Be $kit.Context.Interaction $null
                    Should-Be $kit.State.Draft $null
                    Should-BeFalse $kit.State.Drawing
                    Should-Be $kit.State.DraftRect $null
                    Should-Be $kit.Context.Annotations.Count $annotationCount
                    Should-Be $kit.Context.UndoStack.Count $historyCount
                    Should-Be $kit.Context.ActiveTool $case.Tool

                    $secondEscape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                    Should-BeTrue $secondEscape.Handled
                    Should-Be $kit.Context.CommandRouter.LastCommand 'ActivateSelect'
                    Should-Be $kit.Context.ActiveTool 'Select'
                    Should-Be $kit.Context.Annotations.Count $annotationCount
                    Should-Be $kit.Context.UndoStack.Count $historyCount
                } finally {
                    try { & $kit.Context.CancelDraft } catch {}
                    & $activateTool 'Select'
                    & $clearCanvasContent
                }
            }
        }

        It 'tool switch and capture loss each clear one annotation draft exactly once' {
            try {
                & $clearCanvasContent
                & $activateTool 'RectangleEllipse'
                & $raiseCanvasDown ([System.Windows.Point]::new(140,120))
                & $raiseCanvasMove ([System.Windows.Point]::new(260,210))
                $beforeSwitch = $kit.Context.AnnotationDraftClearCount
                & $activateTool 'Crop'
                Should-Be $kit.Context.AnnotationDraftClearCount ($beforeSwitch + 1)
                Should-Be $kit.Context.Draft $null
                Should-Be $kit.Context.Interaction $null
                & $activateTool 'Select'
                Should-Be $kit.Context.AnnotationDraftClearCount ($beforeSwitch + 1)

                & $activateTool 'Highlight'
                & $raiseCanvasDown ([System.Windows.Point]::new(180,150))
                & $raiseCanvasMove ([System.Windows.Point]::new(280,230))
                $beforeLoss = $kit.Context.AnnotationDraftClearCount
                $lostCapture = [SnipTestMouseEventArgs]::new(
                    [System.Windows.Input.Mouse]::PrimaryDevice,
                    [Environment]::TickCount,
                    [System.Windows.Point]::new(280,230))
                $lostCapture.RoutedEvent =
                    [System.Windows.Input.Mouse]::LostMouseCaptureEvent
                $kit.HighlightLayer.RaiseEvent($lostCapture)
                Should-Be $kit.Context.AnnotationDraftClearCount ($beforeLoss + 1)
                Should-Be $kit.Context.Draft $null
                Should-Be $kit.Context.Interaction $null
                $kit.HighlightLayer.RaiseEvent($lostCapture)
                Should-Be $kit.Context.AnnotationDraftClearCount ($beforeLoss + 1)
            } finally {
                try { & $kit.Context.CancelDraft } catch {}
                & $activateTool 'Select'
                & $clearCanvasContent
            }
        }
    }

    Describe 'Task 7 routed keyboard and stable history contract' {
        $newPopupKeyEvent = {
            param(
                [System.Windows.IInputElement]$Target,
                [System.Windows.Input.Key]$Key
            )
            New-RoutedKeyEvent -Target $Target -Key $Key
        }

        It 'each real key traverses the single resolver once and focused Button keeps native input' {
            $originalResolver = $kit.Context.CommandRouter.Resolve
            $calls = [System.Collections.ArrayList]::new()
            $kit.Context.CommandRouter.Resolve = {
                param($focusedRole,$editorState,$key,$modifiers)
                $calls.Add([pscustomobject]@{
                    Role=$focusedRole; Key=$key; Modifiers=@($modifiers)
                }) | Out-Null
                & $originalResolver $focusedRole $editorState $key $modifiers
            }.GetNewClosure()
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $before = $calls.Count
                & $raiseCanvasKey ([System.Windows.Input.Key]::Right) | Out-Null
                Should-Be $calls.Count ($before + 1)
                Should-Be $calls[-1].Role 'Canvas'
                Should-Be $kit.Context.CommandRouter.LastCommand 'MoveSelectionRight1'

                $button = $kit.Context.ToolControls.Select
                $button.Focus() | Out-Null
                $space = New-RoutedKeyEvent -Target $button -Key Space
                $before = $calls.Count
                $button.RaiseEvent($space)
                Should-Be $calls.Count ($before + 1)
                Should-Be $calls[-1].Role 'Button'
                Should-Be $kit.Context.CommandRouter.LastCommand 'ActivateFocusedButton'
                Should-BeFalse $space.Handled
            } finally {
                $kit.Context.CommandRouter.Resolve = $originalResolver
                & $clearCanvasContent
            }
        }

        It 'canvas Space starts temporary pan through the resolver and key-up or capture loss ends it' {
            $originalResolver = $kit.Context.CommandRouter.Resolve
            $calls = @{ Count=0 }
            $kit.Context.CommandRouter.Resolve = {
                param($focusedRole,$editorState,$key,$modifiers)
                $calls.Count++
                & $originalResolver $focusedRole $editorState $key $modifiers
            }.GetNewClosure()
            try {
                & $clearCanvasContent
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $kit.HighlightLayer.Focus() | Out-Null

                $spaceDown = New-RoutedKeyEvent -Target $kit.HighlightLayer -Key Space
                $kit.HighlightLayer.RaiseEvent($spaceDown)
                Should-BeTrue $spaceDown.Handled
                Should-Be $calls.Count 1
                Should-Be $kit.Context.CommandRouter.LastCommand 'TemporaryPan'
                Should-BeTrue $kit.State.Panning
                Should-BeTrue $kit.State.TemporaryPan

                $spaceUp = New-RoutedKeyEvent -Target $kit.HighlightLayer -Key Space `
                    -RoutedEvent ([System.Windows.Input.Keyboard]::PreviewKeyUpEvent)
                $kit.HighlightLayer.RaiseEvent($spaceUp)
                Should-BeTrue $spaceUp.Handled
                Should-BeFalse $kit.State.Panning
                Should-BeFalse $kit.State.TemporaryPan
                Should-Be $calls.Count 1

                $kit.HighlightLayer.RaiseEvent((New-RoutedKeyEvent `
                    -Target $kit.HighlightLayer -Key Space))
                Should-BeTrue $kit.State.Panning
                $lostCapture = [System.Windows.Input.MouseEventArgs]::new(
                    [System.Windows.Input.Mouse]::PrimaryDevice,
                    [Environment]::TickCount)
                $lostCapture.RoutedEvent = [System.Windows.Input.Mouse]::LostMouseCaptureEvent
                $kit.HighlightLayer.RaiseEvent($lostCapture)
                Should-BeFalse $kit.State.Panning
                Should-BeFalse $kit.State.TemporaryPan
            } finally {
                if ($kit.State.Panning -or $kit.State.TemporaryPan) {
                    & $kit.EndPan
                }
                $kit.Context.CommandRouter.Resolve = $originalResolver
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $clearCanvasContent
            }
        }

        It 'real Escape unwinds editor crop draft selection and active tool one level per press' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $selectedId = $kit.Context.SelectedAnnotationId

                & $activateTool 'Text'
                & $raiseCanvasClick ([System.Windows.Point]::new(300,260))
                $editor = @($kit.HighlightLayer.Children |
                    Where-Object { $_ -is [System.Windows.Controls.TextBox] }) |
                    Select-Object -Last 1
                $editor.Text='draft text'
                $editor.Focus() | Out-Null
                $editorEscape = & $raiseControlKey $editor `
                    ([System.Windows.Input.Key]::Escape)
                Should-Be $kit.Context.CommandRouter.LastCommand 'CancelTextEdit'
                Should-BeFalse $kit.State.EditingText
                Should-Be $kit.Context.SelectedAnnotationId $selectedId

                & $activateTool 'Crop'
                & $raiseCanvasDrag ([System.Windows.Point]::new(220,180)) `
                    @([System.Windows.Point]::new(360,280)) `
                    ([System.Windows.Point]::new(500,380))
                $draftEscape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                Should-BeTrue $draftEscape.Handled
                Should-Be $kit.Context.CommandRouter.LastCommand 'CancelDraft'
                Should-Be $kit.Context.Draft $null
                Should-Be $kit.Context.SelectedAnnotationId $selectedId

                & $activateTool 'Select'
                $selectionEscape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                Should-BeTrue $selectionEscape.Handled
                Should-Be $kit.Context.CommandRouter.LastCommand 'ClearSelection'
                Should-Be $kit.Context.SelectedAnnotationId $null
                Should-Be $kit.Context.ActiveTool 'Select'

                & $activateTool 'Crop'
                $toolEscape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                Should-BeTrue $toolEscape.Handled
                Should-Be $kit.Context.CommandRouter.LastCommand 'ActivateSelect'
                Should-Be $kit.Context.ActiveTool 'Select'
            } finally {
                & $kit.CommandRouter.CloseTransientMenus
                & $kit.SetResponsiveMode 1200 700
                & $clearCanvasContent
            }
        }


        It 'Undo of a selected creation clears the ID and Redo restores identity without selection' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                $createdId = $kit.Context.Annotations[0].Id
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                Should-Be $kit.Context.SelectedAnnotationId $createdId

                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be $kit.Context.Annotations.Count 0
                Should-Be $kit.Context.SelectedAnnotationId $null
                & $raiseClick ($kit.Win.FindName('RedoBtn'))
                Should-Be $kit.Context.Annotations.Count 1
                Should-Be $kit.Context.Annotations[0].Id $createdId
                Should-Be $kit.Context.SelectedAnnotationId $null
            } finally {
                & $clearCanvasContent
            }
        }

        It 'canvas Arrow and Shift Arrow move one and ten pixels while real controls retain keys' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $selectedId = $kit.Context.SelectedAnnotationId

                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $right = & $raiseCanvasKey ([System.Windows.Input.Key]::Right)
                Should-BeTrue $right.Handled
                $afterOne = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-Be $afterOne.Geometry.X 101

                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::Shift
                }
                $down = & $raiseCanvasKey ([System.Windows.Input.Key]::Down)
                Should-BeTrue $down.Handled
                $afterTen = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                Should-Be $afterTen.Geometry.Y 110

                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $save = $kit.Win.FindName('SaveBtn')
                $save.Focus() | Out-Null
                $buttonDelete = New-RoutedKeyEvent -Target $save -Key Delete
                $save.RaiseEvent($buttonDelete)
                Should-BeFalse $buttonDelete.Handled
                Should-Be (@($kit.Context.Annotations | Where-Object Id -eq $selectedId)).Count 1

            } finally {
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                & $kit.SetResponsiveMode 1200 700
                & $clearCanvasContent
            }
        }

        It 'canvas Delete Undo and Redo preserve the stable record identity without stale selection' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $selectedId = $kit.Context.SelectedAnnotationId
                $historyBefore = $kit.Context.UndoStack.Count
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }

                $delete = & $raiseCanvasKey ([System.Windows.Input.Key]::Delete)
                Should-BeTrue $delete.Handled
                Should-Be $kit.Context.Annotations.Count 0
                Should-Be $kit.Context.SelectedAnnotationId $null
                Should-Be $kit.Context.UndoStack.Count ($historyBefore + 1)

                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be $kit.Context.Annotations.Count 1
                Should-Be $kit.Context.Annotations[0].Id $selectedId
                Should-Be $kit.Context.SelectedAnnotationId $null

                & $raiseClick ($kit.Win.FindName('RedoBtn'))
                Should-Be $kit.Context.Annotations.Count 0
                Should-Be $kit.Context.SelectedAnnotationId $null
            } finally {
                & $clearCanvasContent
            }
        }

        It 'a real inline editor retains arrows and Delete ahead of the selected canvas record' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $selectedId = $kit.Context.SelectedAnnotationId
                $selected = @($kit.Context.Annotations | Where-Object Id -eq $selectedId)[0]
                $originalX = $selected.Geometry.X
                $originalY = $selected.Geometry.Y

                & $activateTool 'Text'
                & $raiseCanvasClick ([System.Windows.Point]::new(300,260))
                $editor = @($kit.HighlightLayer.Children |
                    Where-Object { $_ -is [System.Windows.Controls.TextBox] }) |
                    Select-Object -Last 1
                Should-BeTrue ($null -ne $editor)
                $editor.Text = 'editing'
                $editor.CaretIndex = $editor.Text.Length
                $editor.Focus() | Out-Null
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                foreach ($key in @([System.Windows.Input.Key]::Left,[System.Windows.Input.Key]::Delete)) {
                    & $raiseControlKey $editor $key | Out-Null
                }
                $unchanged = @($kit.Context.Annotations |
                    Where-Object Id -eq $selectedId)[0]
                Should-Be $unchanged.Geometry.X $originalX
                Should-Be $unchanged.Geometry.Y $originalY
                Should-Be $kit.Context.Annotations.Count 1

                $escape = & $raiseControlKey $editor ([System.Windows.Input.Key]::Escape)
                Should-BeTrue $escape.Handled
            } finally {
                & $clearCanvasContent
            }
        }

        It 'a real editable Select property retains arrows Delete and Escape ahead of canvas commands' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(100,100)) `
                    ([System.Windows.Point]::new(180,160))
                & $activateTool 'Select'
                & $raiseCanvasClick ([System.Windows.Point]::new(140,130))
                $selectedId=$kit.Context.SelectedAnnotationId
                $positionEditor=$kit.Context.PropertyControls.Position.Element
                Should-BeTrue ($positionEditor -is [System.Windows.Controls.TextBox])
                $originalText=$positionEditor.Text
                [System.Windows.Input.Keyboard]::Focus($positionEditor) | Out-Null
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                    [Action]{}, [System.Windows.Threading.DispatcherPriority]::Input)
                if (-not $kit.Context.EditingProperty) {
                    # The off-screen modal window cannot always acquire OS
                    # keyboard activation. Route the equivalent WPF focus event
                    # through the real editor when native Focus() is denied.
                    $focusEvent = [System.Windows.Input.KeyboardFocusChangedEventArgs]::new(
                        [System.Windows.Input.Keyboard]::PrimaryDevice,
                        [Environment]::TickCount,
                        [System.Windows.Input.Keyboard]::FocusedElement,
                        $positionEditor)
                    $focusEvent.RoutedEvent =
                        [System.Windows.Input.Keyboard]::GotKeyboardFocusEvent
                    $positionEditor.RaiseEvent($focusEvent)
                }
                Should-BeTrue $kit.Context.EditingProperty
                foreach($key in @([System.Windows.Input.Key]::Left,
                    [System.Windows.Input.Key]::Delete)){
                    $eventArgs=& $raiseControlKey $positionEditor $key
                    Should-Be $kit.Context.CommandRouter.LastCommand 'PropertyInput'
                    Should-Be $kit.Context.SelectedAnnotationId $selectedId
                    Should-Be $kit.Context.Annotations.Count 1
                }
                $escape=& $raiseControlKey $positionEditor `
                    ([System.Windows.Input.Key]::Escape)
                Should-Be $kit.Context.CommandRouter.LastCommand 'CancelPropertyEdit'
                Should-BeTrue $escape.Handled
                Should-Be $positionEditor.Text $originalText
                Should-BeFalse $kit.Context.EditingProperty
                Should-Be $kit.Context.SelectedAnnotationId $selectedId
            }finally{
                & $clearCanvasContent
            }
        }
    }

    Describe 'Task 7 real Crop routes' {

        It 'Apply Escape Reset Undo and Redo use deep non-destructive snapshots' {
            try {
                & $clearCanvasContent
                & $drawRectangle ([System.Windows.Point]::new(60,60)) `
                    ([System.Windows.Point]::new(140,120))
                $annotationId = $kit.Context.Annotations[0].Id
                & $activateTool 'Crop'
                & $raiseCanvasDrag ([System.Windows.Point]::new(100,100)) `
                    @([System.Windows.Point]::new(250,200)) `
                    ([System.Windows.Point]::new(400,300))
                if (-not $kit.Context.PropertyControls.Contains('Apply')) {
                    throw "Crop properties missing Apply: active=$($kit.Context.ActiveTool), property=$($kit.Context.ActivePropertyTool), controls=$($kit.Context.PropertyControls.Keys -join ',')"
                }
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                $applied = $kit.Context.CropRectangle
                $historyAfterApply = $kit.Context.UndoStack.Count
                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be $kit.Context.CropRectangle $null
                & $raiseClick ($kit.Win.FindName('RedoBtn'))
                Should-Be $kit.Context.CropRectangle.X $applied.X
                Should-Be $kit.Context.CropRectangle.Y $applied.Y
                Should-Be $kit.Context.CropRectangle.Width $applied.Width
                Should-Be $kit.Context.CropRectangle.Height $applied.Height
                Should-Be $kit.Context.Annotations[0].Id $annotationId

                & $raiseCanvasDrag ([System.Windows.Point]::new(200,160)) `
                    @([System.Windows.Point]::new(300,240)) `
                    ([System.Windows.Point]::new(500,360))
                $kit.Context.GetKeyboardModifiers = {
                    [System.Windows.Input.ModifierKeys]::None
                }
                $escape = & $raiseCanvasKey ([System.Windows.Input.Key]::Escape)
                Should-BeTrue $escape.Handled
                Should-Be $kit.Context.CropRectangle.X $applied.X
                Should-Be $kit.Context.CropRectangle.Y $applied.Y
                Should-Be $kit.Context.CropRectangle.Width $applied.Width
                Should-Be $kit.Context.CropRectangle.Height $applied.Height
                Should-Be $kit.Context.UndoStack.Count $historyAfterApply
                Should-Be $kit.Context.Draft $null

                & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                Should-Be $kit.Context.CropRectangle $null
                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                Should-Be $kit.Context.CropRectangle.X $applied.X
                Should-Be $kit.Context.Annotations[0].Id $annotationId
                & $raiseClick ($kit.Win.FindName('RedoBtn'))
                Should-Be $kit.Context.CropRectangle $null
                Should-Be $kit.Context.Annotations[0].Id $annotationId
            } finally {
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }



        It 'crop routes export the crop size and preserve the frozen source' {
            $originalClipboardSetter = $kit.Context.ClipboardSetter
            $originalSaveBitmap = $kit.Context.SaveBitmap
            try {
                & $clearCanvasContent
                $bitmapReference = $kit.Context.Bitmap
                $sourceReference = $kit.Context.BitmapSource
                $sentinel = $kit.Context.Bitmap.GetPixel(0,0).ToArgb()
                & $activateTool 'Crop'
                & $raiseCanvasDrag ([System.Windows.Point]::new(120,90)) `
                    @([System.Windows.Point]::new(300,220)) `
                    ([System.Windows.Point]::new(520,360))
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                $applied = $kit.Context.CropRectangle
                Should-BeTrue ($null -ne $applied)
                Should-Be $applied.X 120
                Should-Be $applied.Y 90
                Should-Be $applied.Width 400
                Should-Be $applied.Height 270
                $outputs = [System.Collections.ArrayList]::new()
                $kit.Context.ClipboardSetter = {
                    param($image)
                    $outputs.Add([pscustomobject]@{
                        Kind='Copy'; Width=$image.PixelWidth; Height=$image.PixelHeight
                    }) | Out-Null
                }.GetNewClosure()
                $kit.Context.SaveBitmap = {
                    param($image)
                    $outputs.Add([pscustomobject]@{
                        Kind='Save'; Width=$image.Width; Height=$image.Height
                    }) | Out-Null
                    'synthetic-export.png'
                }.GetNewClosure()
                & $raiseMenuClick $kit.SplitControls.Copy.MenuItems.CopyKeepOpen
                Should-BeTrue ($kit.Context.StatusState.Text -match
                    ('^Copied {0} . {1} px$' -f $applied.Width, $applied.Height))
                & $raiseClick ($kit.Win.FindName('SaveBtn'))
                Should-BeTrue ($kit.Context.StatusState.Text -match
                    ('^Saved {0} . {1} px$' -f $applied.Width, $applied.Height))
                Should-Be $outputs.Count 2
                Should-Be $outputs[0].Kind 'Copy'
                Should-Be $outputs[0].Width $applied.Width
                Should-Be $outputs[0].Height $applied.Height
                Should-Be $outputs[1].Kind 'Save'
                Should-Be $outputs[1].Width $applied.Width
                Should-Be $outputs[1].Height $applied.Height
                & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                $outputs.Clear()
                & $raiseMenuClick $kit.SplitControls.Copy.MenuItems.CopyKeepOpen
                Should-Be $kit.Context.StatusState.Text 'Copied to clipboard'
                & $raiseClick ($kit.Win.FindName('SaveBtn'))
                Should-Be $outputs.Count 2
                Should-Be $outputs[0].Width 1200
                Should-Be $outputs[0].Height 800
                Should-Be $outputs[1].Width 1200
                Should-Be $outputs[1].Height 800
                & $raiseClick ($kit.Win.FindName('UndoBtn'))
                & $raiseClick ($kit.Win.FindName('RedoBtn'))

                Should-BeTrue ([object]::ReferenceEquals($kit.Context.Bitmap,$bitmapReference))
                Should-BeTrue ([object]::ReferenceEquals($kit.Context.BitmapSource,$sourceReference))
                Should-BeTrue $kit.Context.BitmapSource.IsFrozen
                Should-Be $kit.Context.Bitmap.Width 1200
                Should-Be $kit.Context.Bitmap.Height 800
                Should-Be $kit.Context.Bitmap.GetPixel(0,0).ToArgb() $sentinel
            } finally {
                $kit.Context.ClipboardSetter = $originalClipboardSetter
                $kit.Context.SaveBitmap = $originalSaveBitmap
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }
    }

    Describe 'Zoom' {
        It 'starts at fit-to-viewport scale (<=1)' {
            Should-BeTrue ($kit.LayoutScale.ScaleX -le 1.0)
            Should-BeTrue ($kit.LayoutScale.ScaleX -gt 0)
        }
        It 'SetZoom to 1.0 works' {
            & $kit.SetZoom 1.0
            Should-Be $kit.LayoutScale.ScaleX 1.0
            Should-Be $kit.LayoutScale.ScaleY 1.0
        }
        It 'ZoomBy 1.25 advances correctly' {
            & $kit.SetZoom 1.0
            & $kit.ZoomBy 1.25
            Should-Be $kit.LayoutScale.ScaleX 1.25 -Tol 1e-9
        }
        It 'ZoomBy compounds' {
            & $kit.SetZoom 1.0
            & $kit.ZoomBy 1.25
            & $kit.ZoomBy 1.25
            Should-Be $kit.LayoutScale.ScaleX 1.5625 -Tol 1e-9
        }
        It 'ZoomBy zoom-out reverses' {
            & $kit.SetZoom 2.0
            & $kit.ZoomBy (1/1.25)
            Should-Be $kit.LayoutScale.ScaleX 1.6 -Tol 1e-9
        }
        It 'SetZoom clamps to 10 (upper)' {
            & $kit.SetZoom 100.0
            Should-Be $kit.LayoutScale.ScaleX 10.0
        }
        It 'SetZoom clamps to 0.05 (lower)' {
            & $kit.SetZoom 0.001
            Should-Be $kit.LayoutScale.ScaleX 0.05
        }
        It 'ZoomText updates on SetZoom' {
            & $kit.SetZoom 1.5
            Should-Be $kit.ZoomText.Text '150%'
        }
        It 'FitToViewport recomputes' {
            & $kit.SetZoom 5.0
            & $kit.FitToViewport
            Should-BeTrue ($kit.LayoutScale.ScaleX -le 1.0)
        }
    }

    Describe 'Pan (Hand) mode' {
        It 'is default: no tool checked on startup' {
            Should-BeFalse $kit.HighlightBtn.IsChecked
            Should-BeFalse $kit.RectBtn.IsChecked
            Should-BeFalse $kit.ArrowBtn.IsChecked
            Should-BeFalse $kit.TextBtn.IsChecked
        }
        It 'cursor is Hand when no tool is active' {
            Should-Be $kit.HighlightLayer.Cursor ([System.Windows.Input.Cursors]::Hand)
        }
        It 'zoomed-in drag updates Scroller offsets by mouse delta' {
            $kit.State.Panning = $false
            & $kit.SetZoom 3.0
            $kit.ImageHost.UpdateLayout()
            $kit.Scroller.UpdateLayout()
            $kit.Scroller.ScrollToHorizontalOffset(200)
            $kit.Scroller.ScrollToVerticalOffset(200)
            $kit.Scroller.UpdateLayout()
            $origX = [double]$kit.Scroller.HorizontalOffset
            $origY = [double]$kit.Scroller.VerticalOffset

            & $kit.BeginPan ([System.Windows.Point]::new(500, 400))
            Should-BeTrue $kit.State.Panning
            & $kit.UpdatePan ([System.Windows.Point]::new(450, 380))   # drag 50 right, 20 down
            $kit.Scroller.UpdateLayout()
            Should-Be $kit.Scroller.HorizontalOffset ($origX + 50) -Tol 1.0
            Should-Be $kit.Scroller.VerticalOffset   ($origY + 20) -Tol 1.0
            & $kit.EndPan
            Should-BeFalse $kit.State.Panning
        }
        It 'EndPan restores Hand cursor' {
            Should-Be $kit.HighlightLayer.Cursor ([System.Windows.Input.Cursors]::Hand)
        }
        It 'UpdatePan is a no-op when Panning is false' {
            $kit.Scroller.ScrollToHorizontalOffset(100)
            $kit.Scroller.UpdateLayout()
            $orig = $kit.Scroller.HorizontalOffset
            & $kit.UpdatePan ([System.Windows.Point]::new(0, 0))
            Should-Be $kit.Scroller.HorizontalOffset $orig -Tol 0.5
        }
    }

    Describe 'Tool selection + cursor' {
        It 'checking Highlight switches cursor to Cross' {
            $kit.HighlightBtn.IsChecked = $true
            Should-Be $kit.HighlightLayer.Cursor ([System.Windows.Input.Cursors]::Cross)
        }
        It 'checking Rect unchecks Highlight (interlock)' {
            $kit.HighlightBtn.IsChecked = $true
            $kit.RectBtn.IsChecked      = $true
            Should-BeFalse $kit.HighlightBtn.IsChecked
            Should-BeTrue  $kit.RectBtn.IsChecked
        }
        It 'checking Text unchecks others' {
            $kit.RectBtn.IsChecked = $true
            $kit.TextBtn.IsChecked = $true
            Should-BeFalse $kit.RectBtn.IsChecked
            Should-BeTrue  $kit.TextBtn.IsChecked
            Should-Be $kit.HighlightLayer.Cursor ([System.Windows.Input.Cursors]::Cross)
            $kit.TextBtn.IsChecked = $false
        }
        It 'unchecking the only active tool returns cursor to Hand' {
            $kit.RectBtn.IsChecked = $true
            $kit.RectBtn.IsChecked = $false
            Should-Be $kit.HighlightLayer.Cursor ([System.Windows.Input.Cursors]::Hand)
        }
    }

    Describe 'Drawing: highlight' {
        It 'produces an annotation with correct image-pixel coords at 1x zoom' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
            $kit.HighlightBtn.IsChecked = $true
            $kit.State.ActiveColor = 'Yellow'

            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(100, 150))
            & $kit.UpdateDraw              ([System.Windows.Point]::new(300, 350))
            & $kit.FinishDraw

            Should-Be $kit.State.Annotations.Count 1
            $a = $kit.State.Annotations[0]
            Should-Be $a.Kind  'Highlight'
            Should-Be $a.Color 'Yellow'
            Should-Be $a.Geometry.X 100
            Should-Be $a.Geometry.Y 150
            Should-Be $a.Geometry.Width 200
            Should-Be $a.Geometry.Height 200
            $kit.HighlightBtn.IsChecked = $false
        }
    }

    Describe 'Drawing: rect' {
        It 'produces a rect annotation' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
            $kit.RectBtn.IsChecked = $true
            $kit.State.ActiveColor = 'Red'

            & $kit.BeginDraw 'rect' ([System.Windows.Point]::new(50, 60))
            & $kit.UpdateDraw         ([System.Windows.Point]::new(200, 260))
            & $kit.FinishDraw

            Should-Be $kit.State.Annotations.Count 1
            $a = $kit.State.Annotations[0]
            Should-Be $a.Kind 'Rectangle'
            Should-Be $a.Color 'Red'
            Should-Be $a.Geometry.Width 150
            Should-Be $a.Geometry.Height 200
            $kit.RectBtn.IsChecked = $false
        }
    }

    Describe 'Drawing: arrow' {
        It 'produces an arrow annotation with start+delta' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
            $kit.ArrowBtn.IsChecked = $true
            $kit.State.ActiveColor = 'Blue'

            & $kit.BeginDraw 'arrow' ([System.Windows.Point]::new(100, 100))
            & $kit.UpdateDraw          ([System.Windows.Point]::new(400, 300))
            & $kit.FinishDraw

            Should-Be $kit.State.Annotations.Count 1
            $a = $kit.State.Annotations[0]
            Should-Be $a.Kind 'Arrow'
            Should-Be $a.Geometry.Start.X 100; Should-Be $a.Geometry.Start.Y 100
            Should-Be $a.Geometry.End.X 400; Should-Be $a.Geometry.End.Y 300
            $kit.ArrowBtn.IsChecked = $false
        }
        It 'discards arrows shorter than 6 canvas units' {
            $kit.State.Annotations.Clear()
            $kit.ArrowBtn.IsChecked = $true
            & $kit.BeginDraw 'arrow' ([System.Windows.Point]::new(100, 100))
            & $kit.UpdateDraw          ([System.Windows.Point]::new(102, 101))
            & $kit.FinishDraw
            Should-Be $kit.State.Annotations.Count 0
            $kit.ArrowBtn.IsChecked = $false
        }
    }

    Describe 'Drawing at zoom != 1 maps to image-pixel coords' {
        It 'at 2x zoom, canvas-pixel drag 100px=> 100 image pixels (Canvas is in natural coords)' {
            # The HighlightLayer is in image-pixel coords regardless of zoom
            # (LayoutTransform only affects rendering). So BeginDraw/UpdateDraw
            # positions in canvas space equal image pixels 1:1.
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 2.0
            $kit.HighlightBtn.IsChecked = $true
            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(10, 20))
            & $kit.UpdateDraw              ([System.Windows.Point]::new(110, 120))
            & $kit.FinishDraw
            $a = $kit.State.Annotations[0]
            Should-Be $a.Geometry.X 10
            Should-Be $a.Geometry.Y 20
            Should-Be $a.Geometry.Width 100
            Should-Be $a.Geometry.Height 100
            $kit.HighlightBtn.IsChecked = $false
        }
    }

    Describe 'Color palette' {
        It 'State.ActiveColor switching affects new annotations' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
            $kit.RectBtn.IsChecked = $true
            foreach ($c in 'Yellow','Green','Pink','Blue','Orange','Red') {
                $kit.State.ActiveColor = $c
                & $kit.BeginDraw 'rect' ([System.Windows.Point]::new(10, 10))
                & $kit.UpdateDraw         ([System.Windows.Point]::new(100, 100))
                & $kit.FinishDraw
            }
            Should-Be $kit.State.Annotations.Count 6
            $colors = $kit.State.Annotations | ForEach-Object { $_.Color }
            $expected = @('Yellow','Green','Pink','Blue','Orange','Red')
            for ($i=0;$i -lt 6;$i++) { Should-Be $colors[$i] $expected[$i] }
            $kit.RectBtn.IsChecked = $false
        }
    }

    Describe 'Undo/Redo' {
        It 'undo removes most recent annotation' {
            $kit.State.Annotations.Clear()
            $kit.State.UndoStack.Clear()
            $kit.State.RedoStack.Clear()
            & $kit.SetZoom 1.0
            $kit.HighlightBtn.IsChecked = $true
            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(10, 10))
            & $kit.UpdateDraw              ([System.Windows.Point]::new(100, 100))
            & $kit.FinishDraw
            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(200, 200))
            & $kit.UpdateDraw              ([System.Windows.Point]::new(300, 300))
            & $kit.FinishDraw
            Should-Be $kit.State.Annotations.Count 2
            & $kit.Undo
            Should-Be $kit.State.Annotations.Count 1
            & $kit.Undo
            Should-Be $kit.State.Annotations.Count 0
            $kit.HighlightBtn.IsChecked = $false
        }
        It 'redo restores undone annotation' {
            & $kit.Redo
            Should-Be $kit.State.Annotations.Count 1
            & $kit.Redo
            Should-Be $kit.State.Annotations.Count 2
        }
    }

    Describe 'Extended annotation tools' {
        $resetTools = {
            $kit.State.Annotations.Clear()
            $kit.Context.UndoStack.Clear()
            $kit.Context.RedoStack.Clear()
            & $kit.SetSelectedAnnotation $null | Out-Null
            & $kit.SetZoom 1.0
            & $activateTool 'Select'
        }

        It 'the Rectangle split menu swaps the primary to Ellipse and draws one' {
            & $resetTools
            & $raiseMenuClick $kit.SplitControls.RectangleEllipse.MenuItems['Ellipse']
            Should-Be $kit.SplitControls.RectangleEllipse.DefaultCommand 'Ellipse'
            Should-Be $kit.Context.ActiveTool 'RectangleEllipse'
            # The band reports the choice: glyph, mnemonic label and check state.
            Should-Be $kit.SplitControls.RectangleEllipse.Label.Text '_Ellipse'
            Should-Be $kit.SplitControls.RectangleEllipse.Glyph.Text ([string][char]0xEA3A)
            Should-BeTrue $kit.SplitControls.RectangleEllipse.MenuItems['Ellipse'].IsChecked
            Should-BeFalse $kit.SplitControls.RectangleEllipse.MenuItems['Rectangle'].IsChecked

            & $kit.HandleMouseDown ([System.Windows.Point]::new(120,130)) `
                ([System.Windows.Point]::new(120,130))
            Should-Be $kit.State.DrawingTool 'ellipse'
            & $kit.UpdateDraw ([System.Windows.Point]::new(260,240))
            & $kit.FinishDraw
            Should-Be $kit.State.Annotations.Count 1
            $record = $kit.State.Annotations[0]
            Should-Be $record.Kind 'Ellipse'
            Should-Be $record.Geometry.Type 'Bounds'
            Should-Be $record.Geometry.X 120
            Should-Be $record.Geometry.Y 130
            Should-Be $record.Geometry.Width 140
            Should-Be $record.Geometry.Height 110
            # The ellipse reaches the canvas as an Ellipse, not a Rectangle.
            Should-Be (@($kit.AnnotationLayer.Children |
                Where-Object { $_ -is [System.Windows.Shapes.Ellipse] }).Count) 1

            & $raiseMenuClick $kit.SplitControls.RectangleEllipse.MenuItems['Rectangle']
            Should-Be $kit.SplitControls.RectangleEllipse.DefaultCommand 'Rectangle'
            Should-Be $kit.SplitControls.RectangleEllipse.Label.Text '_Rectangle'
            & $resetTools
        }

        It 'the Arrow split menu swaps the primary to Line and draws a headless one' {
            & $resetTools
            & $raiseMenuClick $kit.SplitControls.ArrowLine.MenuItems['Line']
            Should-Be $kit.SplitControls.ArrowLine.DefaultCommand 'Line'
            Should-Be $kit.SplitControls.ArrowLine.Label.Text '_Line'
            Should-Be $kit.SplitControls.ArrowLine.Glyph.Text ([string][char]0xE738)

            & $kit.HandleMouseDown ([System.Windows.Point]::new(300,300)) `
                ([System.Windows.Point]::new(300,300))
            Should-Be $kit.State.DrawingTool 'line'
            & $kit.UpdateDraw ([System.Windows.Point]::new(500,420))
            & $kit.FinishDraw
            Should-Be $kit.State.Annotations.Count 1
            $record = $kit.State.Annotations[0]
            Should-Be $record.Kind 'Line'
            Should-Be $record.Geometry.Type 'Line'
            Should-Be $record.Geometry.Start.X 300
            Should-Be $record.Geometry.End.Y 420
            # No arrowhead visual: only Arrow gets the Role='ArrowHead' polygon.
            Should-Be (@($kit.AnnotationLayer.Children | Where-Object {
                $null -ne $_.Tag -and $_.Tag.Role -eq 'ArrowHead' }).Count) 0

            & $raiseMenuClick $kit.SplitControls.ArrowLine.MenuItems['Arrow']
            Should-Be $kit.SplitControls.ArrowLine.DefaultCommand 'Arrow'
            & $resetTools
        }

        It 'Pen collects a min-distance-filtered path and moves as a whole' {
            & $resetTools
            & $activateTool 'Pen'
            Should-Be $kit.Context.ActiveTool 'Pen'
            & $kit.HandleMouseDown ([System.Windows.Point]::new(200,200)) `
                ([System.Windows.Point]::new(200,200))
            Should-Be $kit.State.DrawingTool 'pen'
            # The middle sample is one pixel from the previous one, so the
            # min-distance filter must drop it.
            foreach ($sample in @(@(210,200), @(210,201), @(230,220), @(250,200))) {
                & $kit.UpdateDraw ([System.Windows.Point]::new($sample[0],$sample[1]))
            }
            & $kit.FinishDraw
            Should-Be $kit.State.Annotations.Count 1
            $record = $kit.State.Annotations[0]
            Should-Be $record.Kind 'Pen'
            Should-Be $record.Geometry.Type 'Points'
            Should-Be (@($record.Geometry.Points).Count) 4
            Should-Be (($record.Geometry.Points | ForEach-Object { "$($_.X),$($_.Y)" }) -join ' ') `
                '200,200 210,200 230,220 250,200'
            Should-Be (@($kit.AnnotationLayer.Children |
                Where-Object { $_ -is [System.Windows.Shapes.Polyline] }).Count) 1
            # Hit-testing runs against the segments, so a point on the stroke
            # between vertices still selects it.
            Should-Be (& $kit.FindAt 220 210) 0

            & $activateTool 'Select'
            & $kit.BeginSelectGesture ([System.Windows.Point]::new(220,210))
            & $kit.UpdateSelectGesture ([System.Windows.Point]::new(250,230))
            & $kit.CompleteSelectGesture
            $moved = $kit.State.Annotations[0]
            Should-Be (($moved.Geometry.Points | ForEach-Object { "$($_.X),$($_.Y)" }) -join ' ') `
                '230,220 240,220 260,240 280,220'
            & $resetTools
        }

        It 'Steps places auto-numbered badges and renumbers after delete and undo' {
            & $resetTools
            & $activateTool 'Steps'
            Should-Be $kit.Context.ActiveTool 'Steps'
            & $kit.HandleMouseDown ([System.Windows.Point]::new(200,200)) `
                ([System.Windows.Point]::new(200,200))
            Should-BeFalse $kit.State.Drawing
            Should-Be $kit.State.Annotations.Count 1
            $first = $kit.State.Annotations[0]
            Should-Be $first.Kind 'Step'
            Should-Be $first.Geometry.Type 'StepBounds'
            # Default stroke width 3 lands on the 28 px floor, centred on the click.
            Should-Be $first.Geometry.Width 28
            Should-Be $first.Geometry.Height 28
            Should-Be $first.Geometry.X 186
            Should-Be $first.Geometry.Y 186

            & $kit.PlaceStep ([System.Windows.Point]::new(300,200)) | Out-Null
            & $kit.PlaceStep ([System.Windows.Point]::new(400,200)) | Out-Null
            Should-Be $kit.State.Annotations.Count 3
            $numbers = { (@(Get-SnipStepNumbering -Annotations $kit.State.Annotations) |
                ForEach-Object Number) -join ',' }
            Should-Be (& $numbers) '1,2,3'
            $badges = @($kit.AnnotationLayer.Children |
                Where-Object { $_ -is [System.Windows.Controls.Border] })
            Should-Be $badges.Count 3
            Should-Be (($badges | ForEach-Object { $_.Child.Text }) -join ',') '1,2,3'

            $secondId = [string]$kit.State.Annotations[1].Id
            & $kit.SetSelectedAnnotation $secondId | Out-Null
            & $kit.Context.DeleteSelection
            Should-Be $kit.State.Annotations.Count 2
            # The survivor that used to be 3 becomes 2 without being rewritten.
            Should-Be (& $numbers) '1,2'
            Should-Be (($kit.AnnotationLayer.Children |
                Where-Object { $_ -is [System.Windows.Controls.Border] } |
                ForEach-Object { $_.Child.Text }) -join ',') '1,2'

            & $kit.Undo
            Should-Be $kit.State.Annotations.Count 3
            Should-Be (& $numbers) '1,2,3'
            Should-Be (($kit.AnnotationLayer.Children |
                Where-Object { $_ -is [System.Windows.Controls.Border] } |
                ForEach-Object { $_.Child.Text }) -join ',') '1,2,3'

            # A badge moves like any other bounded annotation.
            & $activateTool 'Select'
            & $kit.SetSelectedAnnotation ([string]$kit.State.Annotations[0].Id) | Out-Null
            & $kit.BeginSelectGesture ([System.Windows.Point]::new(200,200))
            & $kit.UpdateSelectGesture ([System.Windows.Point]::new(240,230))
            & $kit.CompleteSelectGesture
            Should-Be $kit.State.Annotations[0].Geometry.X 226
            Should-Be $kit.State.Annotations[0].Geometry.Y 216
            & $resetTools
        }

        It 'Blur and Pixelate obscure the source pixels they cover on export' {
            foreach ($case in @(
                [pscustomobject]@{ Option='Blur'; Tool='blur'; Kind='Blur' },
                [pscustomobject]@{ Option='Pixelate'; Tool='pixelate'; Kind='Pixelate' })) {
                & $resetTools
                & $raiseMenuClick $kit.SplitControls.BlurPixelate.MenuItems[$case.Option]
                Should-Be $kit.SplitControls.BlurPixelate.DefaultCommand $case.Option
                Should-Be $kit.Context.ActiveTool 'BlurPixelate'

                # The region straddles the orange/slate edge at x=500, so any
                # honest obscuring changes pixels near it.
                & $kit.HandleMouseDown ([System.Windows.Point]::new(460,150)) `
                    ([System.Windows.Point]::new(460,150))
                Should-Be $kit.State.DrawingTool $case.Tool
                & $kit.UpdateDraw ([System.Windows.Point]::new(560,250))
                & $kit.FinishDraw
                Should-Be $kit.State.Annotations.Count 1
                $record = $kit.State.Annotations[0]
                Should-Be $record.Kind $case.Kind
                Should-Be $record.Geometry.Type 'Bounds'
                Should-Be $record.Geometry.X 460
                Should-Be $record.Geometry.Width 100

                # The preview shows the capture's own pixels, effect applied.
                $visual = @($kit.AnnotationLayer.Children | Where-Object {
                    $null -ne $_.Tag -and $_.Tag.Id -eq $record.Id })[0]
                Should-BeTrue ($visual -is [System.Windows.Controls.Canvas])
                Should-BeTrue $visual.ClipToBounds
                $image = $visual.Children[0]
                Should-BeTrue ($image -is [System.Windows.Controls.Image])
                # Both modes reduce then re-enlarge the cropped source; only
                # the scaling mode on the way back up differs.
                Should-BeTrue ($image.Source -is
                    [System.Windows.Media.Imaging.TransformedBitmap])
                Should-BeTrue ($image.Source.Source -is
                    [System.Windows.Media.Imaging.CroppedBitmap])
                Should-Be ([System.Windows.Media.RenderOptions]::GetBitmapScalingMode($image)) `
                    $(if ($case.Kind -eq 'Pixelate') {
                        [System.Windows.Media.BitmapScalingMode]::NearestNeighbor
                    } else {
                        [System.Windows.Media.BitmapScalingMode]::Fant
                    })
                # No Effect: RenderTargetBitmap ignores those, and a blur effect
                # would smear outside the region it is meant to cover.
                Should-Be $image.Effect $null

                $flat = & $kit.Flatten
                try {
                    # Both modes must rewrite the pixels straddling the edge.
                    # Pixelate only disturbs the block the edge falls in, so the
                    # assertion counts a run rather than naming exact pixels.
                    $changed = 0
                    for ($x = 460; $x -lt 560; $x++) {
                        if ($flat.GetPixel($x,200).ToArgb() -ne
                            $kit.Bitmap.GetPixel($x,200).ToArgb()) { $changed++ }
                    }
                    Should-BeTrue ($changed -ge 5)
                    Should-BeTrue ($flat.GetPixel(499,200).ToArgb() -ne
                        $kit.Bitmap.GetPixel(499,200).ToArgb())
                    # Nothing outside the region may move.
                    foreach ($probe in @(@(300,200), @(700,600), @(459,149))) {
                        Should-Be ($flat.GetPixel($probe[0],$probe[1]).ToArgb()) `
                            ($kit.Bitmap.GetPixel($probe[0],$probe[1]).ToArgb())
                    }
                } finally {
                    if ($flat -ne $kit.Bitmap) { $flat.Dispose() }
                }
            }
            & $raiseMenuClick $kit.SplitControls.BlurPixelate.MenuItems['Blur']
            & $resetTools
        }

        It 'Crop is reachable from the band and lists Aspect, Apply and Reset' {
            & $resetTools
            & $activateTool 'Crop'
            Should-Be $kit.Context.ActiveTool 'Crop'
            Should-Be (($kit.PropertyState.Visible) -join ',') 'Aspect,Apply,Reset'
            Should-Be $kit.PropertyState.Tool 'Crop'
            foreach ($name in @('Aspect','Apply','Reset')) {
                Should-BeTrue ($null -ne $kit.Context.PropertyControls[$name])
            }
            Should-BeTrue ($kit.Context.PropertyControls.Aspect.Menu -is
                [System.Windows.Controls.ContextMenu])
            Should-Be (($kit.Context.PropertyControls.Aspect.MenuItems.Keys) -join ',') `
                'Free,Original,1:1,4:3,16:9'
            # The band's Crop button drives the same draft mode the editor already had.
            & $kit.BeginCropDraft ([System.Windows.Point]::new(120,120))
            & $kit.UpdateCropDraft ([System.Windows.Point]::new(400,320))
            & $kit.ApplyCropDraft
            Should-BeTrue ($null -ne $kit.Context.CropRectangle)
            & $kit.ResetCrop
            Should-Be $kit.Context.CropRectangle $null
            & $resetTools
        }

        It 'the property row, not a constant, sets a new annotation width and opacity' {
            & $resetTools
            $toolState = $kit.Context.ToolProperties.RectangleEllipse
            $originalWidth = $toolState.Width
            $originalOpacity = $toolState.Opacity
            $originalFill = $toolState.Fill
            try {
                $toolState.Width = 9.0
                $toolState.Opacity = 0.5
                $toolState.Fill = $true
                & $activateTool 'RectangleEllipse'
                & $kit.HandleMouseDown ([System.Windows.Point]::new(600,120)) `
                    ([System.Windows.Point]::new(600,120))
                & $kit.UpdateDraw ([System.Windows.Point]::new(700,220))
                & $kit.FinishDraw
                $record = $kit.State.Annotations[0]
                Should-Be $record.StrokeWidth 9.0
                Should-Be $record.Opacity 0.5
                Should-BeTrue ([bool]$record.Properties.Fill)
                $shape = @($kit.AnnotationLayer.Children | Where-Object {
                    $null -ne $_.Tag -and $_.Tag.Id -eq $record.Id })[0]
                Should-Be $shape.StrokeThickness 9.0
                Should-BeTrue ($null -ne $shape.Fill)
            } finally {
                $toolState.Width = $originalWidth
                $toolState.Opacity = $originalOpacity
                $toolState.Fill = $originalFill
            }
            # Restored defaults still produce the historical highlight record.
            & $resetTools
            $kit.HighlightBtn.IsChecked = $true
            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(20,20))
            & $kit.UpdateDraw ([System.Windows.Point]::new(120,120))
            & $kit.FinishDraw
            $highlight = $kit.State.Annotations[0]
            Should-Be $highlight.StrokeWidth 1.5
            Should-Be ([int][math]::Round(255.0 * $highlight.Opacity)) 110
            $kit.HighlightBtn.IsChecked = $false
            & $resetTools
        }
    }

    Describe 'Find-AnnotationAt hit test' {
        It 'returns the topmost annotation under a canvas point' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
            # Draw two rects: one at (10,10)-(100,100), one at (200,200)-(300,300).
            $kit.RectBtn.IsChecked = $true
            & $kit.BeginDraw 'rect' ([System.Windows.Point]::new(10,10))
            & $kit.UpdateDraw         ([System.Windows.Point]::new(100,100))
            & $kit.FinishDraw
            & $kit.BeginDraw 'rect' ([System.Windows.Point]::new(200,200))
            & $kit.UpdateDraw         ([System.Windows.Point]::new(300,300))
            & $kit.FinishDraw
            $kit.RectBtn.IsChecked = $false

            # Coords in canvas space == image space at 1x zoom
            $idx = & $kit.FindAt 50 50
            Should-Be $idx 0
            $idx = & $kit.FindAt 250 250
            Should-Be $idx 1
            $idx = & $kit.FindAt 500 500
            Should-Be $idx -1
        }
    }

    Describe 'Get-FlattenedBitmap' {
        It 'returns a System.Drawing.Bitmap of the full source size with no crop' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
            Should-Be $kit.Context.CropRectangle $null
            $kit.HighlightBtn.IsChecked = $true
            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(10,10))
            & $kit.UpdateDraw              ([System.Windows.Point]::new(100,100))
            & $kit.FinishDraw
            $kit.HighlightBtn.IsChecked = $false

            $flat = & $kit.Flatten
            Should-BeTrue ($flat -is [System.Drawing.Bitmap])
            Should-Be $flat.Width  1200
            Should-Be $flat.Height 800
            if ($flat -ne $kit.Bitmap) { $flat.Dispose() }
        }
        It 'returns the crop size with a crop applied and the full size after Reset' {
            $flat = $null
            try {
                & $clearCanvasContent
                & $activateTool 'Crop'
                & $raiseCanvasDrag ([System.Windows.Point]::new(200,150)) `
                    @([System.Windows.Point]::new(500,400)) `
                    ([System.Windows.Point]::new(840,630))
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                $applied = $kit.Context.CropRectangle
                Should-Be $applied.Width 640
                Should-Be $applied.Height 480

                # No annotations plus a crop must still allocate a fresh bitmap,
                # never hand back the shared source.
                Should-Be $kit.Context.Annotations.Count 0
                $flat = & $kit.Flatten
                Should-BeFalse ([object]::ReferenceEquals($flat,$kit.Bitmap))
                Should-Be $flat.Width 640
                Should-Be $flat.Height 480
                # (200,150) in source coords is inside the orange rectangle at
                # (100,100,400,300); it lands at the crop-local origin.
                Should-Be $flat.GetPixel(0,0).ToArgb() `
                    $kit.Bitmap.GetPixel(200,150).ToArgb()
                Should-Be $flat.GetPixel(639,479).ToArgb() `
                    $kit.Bitmap.GetPixel(839,629).ToArgb()
                $flat.Dispose(); $flat = $null

                & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                Should-Be $kit.Context.CropRectangle $null
                $flat = & $kit.Flatten
                Should-BeTrue ([object]::ReferenceEquals($flat,$kit.Bitmap))
                Should-Be $flat.Width 1200
                Should-Be $flat.Height 800
            } finally {
                if ($null -ne $flat -and
                    -not [object]::ReferenceEquals($flat,$kit.Bitmap)) {
                    $flat.Dispose()
                }
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }
        It 'rebases an annotation drawn inside the crop to the crop-local offset' {
            $full = $null
            $cropped = $null
            try {
                & $clearCanvasContent
                $kit.HighlightBtn.IsChecked = $true
                & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(300,250))
                & $kit.UpdateDraw ([System.Windows.Point]::new(400,350))
                & $kit.FinishDraw
                $kit.HighlightBtn.IsChecked = $false
                Should-Be $kit.Context.Annotations.Count 1

                # Uncropped reference: the annotation is painted at (350,300)
                # in source coordinates and differs from the raw capture there.
                $full = & $kit.Flatten
                Should-Be $full.Width 1200
                $paintedArgb = $full.GetPixel(350,300).ToArgb()
                $backgroundArgb = $full.GetPixel(290,240).ToArgb()
                Should-BeFalse ($paintedArgb -eq
                    $kit.Bitmap.GetPixel(350,300).ToArgb())

                & $activateTool 'Crop'
                & $raiseCanvasDrag ([System.Windows.Point]::new(200,150)) `
                    @([System.Windows.Point]::new(500,400)) `
                    ([System.Windows.Point]::new(840,630))
                & $invokePropertyEntry $kit.Context.PropertyControls.Apply
                Should-Be $kit.Context.CropRectangle.X 200
                Should-Be $kit.Context.CropRectangle.Y 150

                $cropped = & $kit.Flatten
                Should-Be $cropped.Width 640
                Should-Be $cropped.Height 480
                # Source (350,300) is crop-local (150,150); the annotation
                # pixel must survive the crop unchanged at that offset.
                Should-Be $cropped.GetPixel(150,150).ToArgb() $paintedArgb
                # Just outside the annotation, source (290,240) -> local (90,90).
                Should-Be $cropped.GetPixel(90,90).ToArgb() $backgroundArgb
            } finally {
                foreach ($bitmap in @($full,$cropped)) {
                    if ($null -ne $bitmap -and
                        -not [object]::ReferenceEquals($bitmap,$kit.Bitmap)) {
                        $bitmap.Dispose()
                    }
                }
                if ($null -ne $kit.Context.CropRectangle) {
                    & $invokePropertyEntry $kit.Context.PropertyControls.Reset
                }
                & $clearCanvasContent
            }
        }
    }

    Describe 'Tool interlock after drawing' {
        It 'drawing with highlight then switching to rect preserves existing annotation' {
            $kit.State.Annotations.Clear()
            $kit.HighlightBtn.IsChecked = $true
            & $kit.BeginDraw 'highlight' ([System.Windows.Point]::new(10,10))
            & $kit.UpdateDraw              ([System.Windows.Point]::new(60,60))
            & $kit.FinishDraw
            $kit.RectBtn.IsChecked = $true
            Should-Be $kit.State.Annotations.Count 1
            Should-Be $kit.State.Annotations[0].Kind 'Highlight'
            $kit.RectBtn.IsChecked = $false
        }
    }

    Describe 'Text tool' {
        It 'OpenText creates a TextBox and adds it to HighlightLayer' {
            $kit.State.Annotations.Clear()
            $kit.TextBtn.IsChecked = $true
            & $kit.SetZoom 1.0
            $before = $kit.HighlightLayer.Children.Count
            $tb = & $kit.OpenText ([System.Windows.Point]::new(150, 200))
            Should-BeTrue ($tb -is [System.Windows.Controls.TextBox])
            Should-Be $kit.HighlightLayer.Children.Count ($before + 1)
            Should-BeTrue $kit.State.EditingText
        }
        It 'committing empty text removes the box without adding an annotation' {
            $tb = $kit.HighlightLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] } | Select-Object -First 1
            Should-BeTrue ($tb -ne $null)
            $tb.Text = ''
            & $tb.Tag
            Should-BeFalse $kit.State.EditingText
            Should-Be $kit.State.Annotations.Count 0
        }
        It 'committing typed text appends a text annotation at image-pixel coords' {
            $kit.State.Annotations.Clear()
            $kit.TextBtn.IsChecked = $true
            & $kit.SetZoom 1.0
            $tb = & $kit.OpenText ([System.Windows.Point]::new(120, 340))
            $tb.Text = 'hello'
            & $tb.Tag
            Should-BeFalse $kit.State.EditingText
            Should-Be $kit.State.Annotations.Count 1
            $a = $kit.State.Annotations[0]
            Should-Be $a.Kind 'Text'
            Should-Be $a.Properties.Text 'hello'
            Should-Be $a.Geometry.X 120
            Should-Be $a.Geometry.Y 340
            Should-Be $a.Properties.FontSize 18
            $kit.TextBtn.IsChecked = $false
        }
        It 'PickColor while editing text updates TextBox foreground live and commit uses new color' {
            $kit.State.Annotations.Clear()
            & $kit.PickColor 'Yellow'
            $kit.TextBtn.IsChecked = $true
            & $kit.SetZoom 1.0
            $tb = & $kit.OpenText ([System.Windows.Point]::new(200, 200))
            # Now simulate user picking Red from the palette mid-typing
            & $kit.PickColor 'Red'
            $expectedRed = $kit.Palette['Red']
            $actual = $tb.Foreground.Color
            if ($actual.R -ne $expectedRed.R -or $actual.G -ne $expectedRed.G -or $actual.B -ne $expectedRed.B) {
                throw "TextBox foreground after PickColor Red: RGB($($actual.R),$($actual.G),$($actual.B))"
            }
            # State ActiveColor should be Red
            Should-Be $kit.State.ActiveColor 'Red'
            # Commit with typed text; annotation should be Red
            $tb.Text = 'live-color'
            & $tb.Tag
            Should-Be $kit.State.Annotations[0].Color 'Red'
            $kit.TextBtn.IsChecked = $false
        }
        It 'Render-Annotations applies annotation.Color to the TextBlock foreground (right-click color change)' {
            $kit.State.Annotations.Clear()
            $kit.State.ActiveColor = 'Yellow'
            $kit.TextBtn.IsChecked = $true
            & $kit.SetZoom 1.0
            $tb = & $kit.OpenText ([System.Windows.Point]::new(100, 100))
            $tb.Text = 'initial'
            & $tb.Tag
            Should-Be $kit.State.Annotations.Count 1
            # Simulate right-click → pick Red from context menu → mutate + re-render
            $kit.State.Annotations[0].Color = 'Red'
            & $kit.Render
            $rendered = $kit.AnnotationLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] } | Select-Object -First 1
            Should-BeTrue ($rendered -ne $null)
            $expected = $kit.Palette['Red']
            $actual = $rendered.Foreground.Color
            if ($actual.R -ne $expected.R -or $actual.G -ne $expected.G -or $actual.B -ne $expected.B) {
                throw "Rendered text foreground RGB($($actual.R),$($actual.G),$($actual.B)) != expected RGB($($expected.R),$($expected.G),$($expected.B))"
            }
            $kit.TextBtn.IsChecked = $false
        }
        It 'uses the current ActiveColor at click time (not a frozen default)' {
            foreach ($c in 'Yellow','Green','Pink','Blue','Orange','Red') {
                $kit.State.Annotations.Clear()
                $kit.State.EditingText = $false
                $kit.State.ActiveColor = $c
                $kit.TextBtn.IsChecked = $true
                & $kit.SetZoom 1.0
                $tb = & $kit.OpenText ([System.Windows.Point]::new(50, 50))
                # Verify TextBox foreground matches palette color
                $expected = $kit.Palette[$c]
                $actual = $tb.Foreground.Color
                if ($actual.R -ne $expected.R -or $actual.G -ne $expected.G -or $actual.B -ne $expected.B) {
                    throw "TextBox Foreground for $c expected RGB($($expected.R),$($expected.G),$($expected.B)) got RGB($($actual.R),$($actual.G),$($actual.B))"
                }
                $tb.Text = "text-$c"
                & $tb.Tag
                Should-Be $kit.State.Annotations[0].Color $c
                Should-Be $kit.State.Annotations[0].Properties.Text "text-$c"
            }
            $kit.TextBtn.IsChecked = $false
        }
        It 'text annotation at 2x zoom maps to image pixel coords correctly' {
            $kit.State.Annotations.Clear()
            $kit.TextBtn.IsChecked = $true
            & $kit.SetZoom 2.0
            $tb = & $kit.OpenText ([System.Windows.Point]::new(50, 100))
            $tb.Text = 'zoomed'
            & $tb.Tag
            $a = $kit.State.Annotations[0]
            # Canvas coords == image pixels (LayoutTransform only affects render).
            # Bounds.Scale is always 1.0 in this design, so FontSize stays 18.
            Should-Be $a.Geometry.X 50
            Should-Be $a.Geometry.Y 100
            Should-Be $a.Properties.FontSize 18
            $kit.TextBtn.IsChecked = $false
        }
    }

    Describe 'Full click dispatch via HandleMouseDown' {
        It 'click with no tool active starts pan' {
            $kit.State.Panning = $false
            & $activateTool 'Highlight'
            $peer = [System.Windows.Automation.Peers.ToggleButtonAutomationPeer]::new(
                $kit.HighlightBtn)
            $provider = $peer.GetPattern(
                [System.Windows.Automation.Peers.PatternInterface]::Toggle)
            ([System.Windows.Automation.Provider.IToggleProvider]$provider).Toggle()
            Should-Be $kit.Context.ActiveTool $null
            $sv = [System.Windows.Point]::new(100, 100)
            $hl = [System.Windows.Point]::new(100, 100)
            & $kit.HandleMouseDown $hl $sv
            Should-BeTrue $kit.State.Panning
            & $kit.EndPan
        }
        It 'click with Highlight active begins a draft rectangle' {
            $kit.State.Annotations.Clear()
            $kit.HighlightBtn.IsChecked = $true
            $countBefore = $kit.HighlightLayer.Children.Count
            & $kit.HandleMouseDown ([System.Windows.Point]::new(100, 100)) ([System.Windows.Point]::new(100, 100))
            Should-BeTrue $kit.State.Drawing
            Should-Be $kit.State.DrawingTool 'highlight'
            & $kit.FinishDraw
            $kit.HighlightBtn.IsChecked = $false
        }
        It 'click with Text active opens a TextBox (real dispatch path)' {
            $kit.State.Annotations.Clear()
            $kit.State.EditingText = $false
            $kit.TextBtn.IsChecked = $true
            $countBefore = @($kit.HighlightLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] }).Count
            & $kit.HandleMouseDown ([System.Windows.Point]::new(300, 300)) ([System.Windows.Point]::new(300, 300))
            Should-BeTrue $kit.State.EditingText
            $countAfter = @($kit.HighlightLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] }).Count
            Should-Be $countAfter ($countBefore + 1)
            # Commit the new text box so state is clean
            $tb = $kit.HighlightLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] } | Select-Object -Last 1
            $tb.Text = 'click-text'
            & $tb.Tag
            Should-Be $kit.State.Annotations.Count 1
            Should-Be $kit.State.Annotations[0].Kind 'Text'
            Should-Be $kit.State.Annotations[0].Properties.Text 'click-text'
            $kit.TextBtn.IsChecked = $false
        }
        It 'click outside image bounds is ignored' {
            $kit.State.Annotations.Clear()
            $kit.HighlightBtn.IsChecked = $true
            # Bitmap is 1200x800, so (-50,-50) is out of bounds
            & $kit.HandleMouseDown ([System.Windows.Point]::new(-50, -50)) ([System.Windows.Point]::new(-50, -50))
            Should-BeFalse $kit.State.Drawing
            $kit.HighlightBtn.IsChecked = $false
        }
        It 'click while EditingText is ignored (no tool dispatch)' {
            $kit.State.EditingText = $true
            $kit.HighlightBtn.IsChecked = $true
            & $kit.HandleMouseDown ([System.Windows.Point]::new(10, 10)) ([System.Windows.Point]::new(10, 10))
            Should-BeFalse $kit.State.Drawing
            $kit.State.EditingText = $false
            $kit.HighlightBtn.IsChecked = $false
        }
    }

    Describe 'Pan does not fire when a tool is active (integration logic)' {
        It 'BeginDraw while tool active, no pan state set' {
            $kit.State.Annotations.Clear()
            $kit.RectBtn.IsChecked = $true
            Should-BeFalse $kit.State.Panning
            & $kit.BeginDraw 'rect' ([System.Windows.Point]::new(10,10))
            & $kit.UpdateDraw         ([System.Windows.Point]::new(50,50))
            & $kit.FinishDraw
            Should-BeFalse $kit.State.Panning
            Should-Be $kit.State.Annotations.Count 1
            $kit.RectBtn.IsChecked = $false
        }
    }

}

# Summary
$pass = @($script:Results | Where-Object Pass).Count
$fail = @($script:Results | Where-Object { -not $_.Pass }).Count
Write-Host ''
$color = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "Total: $($script:Results.Count)  |  Pass: $pass  |  Fail: $fail" -ForegroundColor $color

if ($fail -gt 0) { exit 1 } else { exit 0 }
