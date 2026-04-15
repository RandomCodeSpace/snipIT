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

$env:SNIPIT_TEST_MODE = '1'

# STA required by WPF. If we got launched from bash MTA, relaunch self.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoProfile -Sta -File $PSCommandPath
    exit $LASTEXITCODE
}

# Dot-source SnipIT.ps1 to get Show-PreviewWindow and helpers. The test-mode
# guards inside SnipIT.ps1 short-circuit side-effect sections.
. (Join-Path $PSScriptRoot 'SnipIT.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

# ---- Test framework ----
$script:Results = [System.Collections.ArrayList]::new()
$script:CurrentGroup = '<root>'
function Describe { param([string]$Name, [scriptblock]$Body)
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
function Should-BeGreaterThan { param($Actual, $Min)
    if ([double]$Actual -le [double]$Min) { throw "Expected > $Min, got $Actual" }
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
Show-PreviewWindow -Bitmap $bmp -TestAction {
    param($kit)

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
            Should-Be $a.Type  'highlight'
            Should-Be $a.Color 'Yellow'
            Should-Be $a.X 100
            Should-Be $a.Y 150
            Should-Be $a.W 200
            Should-Be $a.H 200
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
            Should-Be $a.Type 'rect'
            Should-Be $a.Color 'Red'
            Should-Be $a.W 150
            Should-Be $a.H 200
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
            Should-Be $a.Type 'arrow'
            Should-Be $a.X 100; Should-Be $a.Y 100
            Should-Be $a.W 300; Should-Be $a.H 200
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
            Should-Be $a.X 10
            Should-Be $a.Y 20
            Should-Be $a.W 100
            Should-Be $a.H 100
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
        It 'returns a System.Drawing.Bitmap of the right dimensions' {
            $kit.State.Annotations.Clear()
            & $kit.SetZoom 1.0
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
            Should-Be $kit.State.Annotations[0].Type 'highlight'
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
            Should-Be $a.Type 'text'
            Should-Be $a.Text 'hello'
            Should-Be $a.X 120
            Should-Be $a.Y 340
            Should-Be $a.FontSize 18
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
            $rendered = $kit.HighlightLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] } | Select-Object -First 1
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
                Should-Be $kit.State.Annotations[0].Text "text-$c"
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
            Should-Be $a.X 50
            Should-Be $a.Y 100
            Should-Be $a.FontSize 18
            $kit.TextBtn.IsChecked = $false
        }
    }

    Describe 'Full click dispatch via HandleMouseDown' {
        It 'click with no tool active starts pan' {
            $kit.State.Panning = $false
            foreach ($b in $kit.HighlightBtn, $kit.RectBtn, $kit.ArrowBtn, $kit.TextBtn) { $b.IsChecked = $false }
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
            Should-Be $kit.State.Annotations[0].Type 'text'
            Should-Be $kit.State.Annotations[0].Text 'click-text'
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
