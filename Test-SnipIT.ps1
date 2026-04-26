# Cross-platform tests for SnipIT pure logic. No Pester dependency.
# Run: pwsh -NoProfile -File ./Test-SnipIT.ps1
$ErrorActionPreference = 'Stop'

# Dot-source SnipIT.ps1 in CoreOnly mode: loads pure functions, then early-returns
# before any Windows-only Bootstrap / PInvoke / UI code runs.
. (Join-Path $PSScriptRoot 'SnipIT.ps1') -CoreOnly

$script:Pass = 0; $script:Fail = 0; $script:Failures = @()

function Describe { param($Name) Write-Host "`n$Name" -ForegroundColor Cyan }
function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:Fail++
        $script:Failures += "$Name :: $($_.Exception.Message)"
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}
function ShouldBe { param($Actual, $Expected)
    if ($Actual -ne $Expected) { throw "Expected '$Expected' but got '$Actual'" }
}
function ShouldBeTrue  { param($Value) if (-not $Value) { throw 'Expected $true' } }
function ShouldBeFalse { param($Value) if ($Value)      { throw 'Expected $false' } }

Describe 'Get-DragRectangle'
It 'normalizes when current is bottom-right of anchor' {
    $r = Get-DragRectangle -AnchorX 10 -AnchorY 20 -CurrentX 100 -CurrentY 200
    ShouldBe $r.X 10; ShouldBe $r.Y 20
    ShouldBe $r.Width 90; ShouldBe $r.Height 180
}
It 'normalizes when current is top-left of anchor' {
    $r = Get-DragRectangle -AnchorX 100 -AnchorY 200 -CurrentX 10 -CurrentY 20
    ShouldBe $r.X 10; ShouldBe $r.Y 20
    ShouldBe $r.Width 90; ShouldBe $r.Height 180
}
It 'normalizes when current is top-right of anchor' {
    $r = Get-DragRectangle -AnchorX 10 -AnchorY 200 -CurrentX 100 -CurrentY 20
    ShouldBe $r.X 10; ShouldBe $r.Y 20
    ShouldBe $r.Width 90; ShouldBe $r.Height 180
}
It 'returns zero size when anchor equals current' {
    $r = Get-DragRectangle -AnchorX 50 -AnchorY 50 -CurrentX 50 -CurrentY 50
    ShouldBe $r.Width 0; ShouldBe $r.Height 0
}
It 'handles negative coordinates from a left-side secondary monitor' {
    $r = Get-DragRectangle -AnchorX -100 -AnchorY 50 -CurrentX -300 -CurrentY 250
    ShouldBe $r.X -300; ShouldBe $r.Y 50
    ShouldBe $r.Width 200; ShouldBe $r.Height 200
}

Describe 'Test-IsClickVsDrag'
It 'reports click when both deltas under default threshold' {
    ShouldBe (Test-IsClickVsDrag -AnchorX 100 -AnchorY 100 -CurrentX 102 -CurrentY 101) 'click'
}
It 'reports click on exact anchor' {
    ShouldBe (Test-IsClickVsDrag -AnchorX 100 -AnchorY 100 -CurrentX 100 -CurrentY 100) 'click'
}
It 'reports drag when x exceeds threshold' {
    ShouldBe (Test-IsClickVsDrag -AnchorX 100 -AnchorY 100 -CurrentX 110 -CurrentY 101) 'drag'
}
It 'reports drag when y exceeds threshold' {
    ShouldBe (Test-IsClickVsDrag -AnchorX 100 -AnchorY 100 -CurrentX 102 -CurrentY 120) 'drag'
}
It 'respects custom threshold (10)' {
    ShouldBe (Test-IsClickVsDrag -AnchorX 0 -AnchorY 0 -CurrentX 5 -CurrentY 5 -Threshold 10) 'click'
    ShouldBe (Test-IsClickVsDrag -AnchorX 0 -AnchorY 0 -CurrentX 11 -CurrentY 0 -Threshold 10) 'drag'
}
It 'reports drag for negative delta exceeding threshold' {
    ShouldBe (Test-IsClickVsDrag -AnchorX 100 -AnchorY 100 -CurrentX 80 -CurrentY 100) 'drag'
}

Describe 'Get-LoupeSourceRect'
It 'centers source on cursor in middle of screen' {
    $r = Get-LoupeSourceRect -MouseX 1000 -MouseY 500 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 -Size 18
    ShouldBe $r.X 991; ShouldBe $r.Y 491
}
It 'clamps to left edge when cursor at x=0' {
    $r = Get-LoupeSourceRect -MouseX 0 -MouseY 500 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080
    ShouldBe $r.X 0
}
It 'clamps to top edge when cursor at y=0' {
    $r = Get-LoupeSourceRect -MouseX 500 -MouseY 0 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080
    ShouldBe $r.Y 0
}
It 'clamps to right edge when cursor near max x' {
    $r = Get-LoupeSourceRect -MouseX 1920 -MouseY 500 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 -Size 18
    ShouldBe $r.X (1920 - 18)
}
It 'clamps to bottom edge when cursor near max y' {
    $r = Get-LoupeSourceRect -MouseX 500 -MouseY 1080 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 -Size 18
    ShouldBe $r.Y (1080 - 18)
}
It 'handles negative virtual-screen origin (left monitor)' {
    $r = Get-LoupeSourceRect -MouseX -500 -MouseY 200 -VsX -1920 -VsY 0 -VsWidth 3840 -VsHeight 1080 -Size 18
    ShouldBe $r.X 1411
}

Describe 'Get-LoupePosition'
It 'places loupe to bottom-right when room available' {
    $p = Get-LoupePosition -MouseX 100 -MouseY 100 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080
    ShouldBe $p.X 124; ShouldBe $p.Y 124
}
It 'flips loupe to left when near right edge' {
    $p = Get-LoupePosition -MouseX 1900 -MouseY 100 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 -LoupeWidth 170
    ShouldBeTrue ($p.X -lt 1900)
}
It 'flips loupe upward when near bottom edge' {
    $p = Get-LoupePosition -MouseX 100 -MouseY 1070 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 -LoupeHeight 190
    ShouldBeTrue ($p.Y -lt 1070)
}

Describe 'Get-DefaultSnipFilename'
It 'formats timestamp as snip-yyyyMMdd-HHmmss.png' {
    $t = [datetime]'2026-04-15T02:46:12'
    ShouldBe (Get-DefaultSnipFilename -Timestamp $t) 'snip-20260415-024612.png'
}
It 'pads single-digit values with zeros' {
    $t = [datetime]'2026-01-05T03:04:05'
    ShouldBe (Get-DefaultSnipFilename -Timestamp $t) 'snip-20260105-030405.png'
}

Describe 'Get-ImageFormatNameFromPath'
It 'returns Png for .png'  { ShouldBe (Get-ImageFormatNameFromPath 'a.png')  'Png' }
It 'returns Jpeg for .jpg' { ShouldBe (Get-ImageFormatNameFromPath 'a.jpg')  'Jpeg' }
It 'returns Jpeg for .jpeg'{ ShouldBe (Get-ImageFormatNameFromPath 'a.jpeg') 'Jpeg' }
It 'is case-insensitive'   { ShouldBe (Get-ImageFormatNameFromPath 'A.JPEG') 'Jpeg' }
It 'returns Bmp for .bmp'  { ShouldBe (Get-ImageFormatNameFromPath 'a.bmp')  'Bmp' }
It 'defaults to Png for unknown extensions' { ShouldBe (Get-ImageFormatNameFromPath 'a.gif') 'Png' }
It 'defaults to Png when no extension'      { ShouldBe (Get-ImageFormatNameFromPath 'a')     'Png' }
It 'handles full Windows path' { ShouldBe (Get-ImageFormatNameFromPath 'C:/users/x/snip.jpg') 'Jpeg' }

Describe 'Test-CaptureRectValid'
It 'accepts a 2x2 rect' { ShouldBeTrue  (Test-CaptureRectValid -Width 2 -Height 2) }
It 'rejects 1x1'        { ShouldBeFalse (Test-CaptureRectValid -Width 1 -Height 1) }
It 'rejects 0 width'    { ShouldBeFalse (Test-CaptureRectValid -Width 0 -Height 100) }
It 'rejects 0 height'   { ShouldBeFalse (Test-CaptureRectValid -Width 100 -Height 0) }
It 'accepts large rect' { ShouldBeTrue  (Test-CaptureRectValid -Width 3840 -Height 2160) }
It 'respects custom MinSize' { ShouldBeFalse (Test-CaptureRectValid -Width 5 -Height 5 -MinSize 10) }

Describe 'Get-CropBounds'
It 'translates positive screen coords' {
    $b = Get-CropBounds -RectX 100 -RectY 200 -RectW 300 -RectH 400 -VsX 0 -VsY 0
    ShouldBe $b.X 100; ShouldBe $b.Y 200
    ShouldBe $b.Width 300; ShouldBe $b.Height 400
}
It 'translates with negative virtual-screen origin' {
    $b = Get-CropBounds -RectX 100 -RectY 200 -RectW 300 -RectH 400 -VsX -1920 -VsY 0
    ShouldBe $b.X 2020; ShouldBe $b.Y 200
}

Describe 'Get-InstallPaths'
It 'computes AppDir under LocalAppData and shortcut paths' {
    $p = Get-InstallPaths -LocalAppData '/tmp/lad' -DesktopDir '/tmp/d' -StartupDir '/tmp/s'
    ShouldBe $p.AppDir          (Join-Path '/tmp/lad' 'SnipIT')
    ShouldBe $p.ScriptPath      (Join-Path (Join-Path '/tmp/lad' 'SnipIT') 'SnipIT.ps1')
    ShouldBe $p.Marker          (Join-Path (Join-Path '/tmp/lad' 'SnipIT') '.installed')
    ShouldBe $p.DesktopShortcut (Join-Path '/tmp/d' 'SnipIT.lnk')
    ShouldBe $p.StartupShortcut (Join-Path '/tmp/s' 'SnipIT.lnk')
}

Describe 'Get-ShortcutArguments'
It 'builds the launcher arg string with the script path quoted' {
    $a = Get-ShortcutArguments -ScriptPath 'C:\Users\x\AppData\Local\SnipIT\SnipIT.ps1'
    ShouldBeTrue ($a -match '-NoProfile')
    ShouldBeTrue ($a -match '-WindowStyle Hidden')
    ShouldBeTrue ($a -match '-Sta')
    ShouldBeTrue ($a -match '-File "C:\\Users\\x\\AppData\\Local\\SnipIT\\SnipIT.ps1"')
}

Describe 'Resolve-SaveImagePath'
It 'keeps a valid PNG path unchanged' {
    ShouldBe (Resolve-SaveImagePath -Path '/tmp/a.png' -FilterFormat 'Png') '/tmp/a.png'
}
It 'keeps a valid JPG path unchanged even when filter is PNG' {
    # User explicitly typed .jpg — respect their extension.
    ShouldBe (Resolve-SaveImagePath -Path '/tmp/a.jpg' -FilterFormat 'Png') '/tmp/a.jpg'
}
It 'keeps a .jpeg extension (both supported jpeg forms)' {
    ShouldBe (Resolve-SaveImagePath -Path '/tmp/a.jpeg' -FilterFormat 'Jpeg') '/tmp/a.jpeg'
}
It 'forces a non-image extension to match the PNG filter' {
    $p = Resolve-SaveImagePath -Path '/tmp/a.txt' -FilterFormat 'Png'
    ShouldBeTrue ($p.EndsWith('a.png'))
}
It 'forces a non-image extension to match the JPEG filter' {
    $p = Resolve-SaveImagePath -Path '/tmp/a.txt' -FilterFormat 'Jpeg'
    ShouldBeTrue ($p.EndsWith('a.jpg'))
}
It 'forces a non-image extension to match the BMP filter' {
    $p = Resolve-SaveImagePath -Path '/tmp/a.txt' -FilterFormat 'Bmp'
    ShouldBeTrue ($p.EndsWith('a.bmp'))
}
It 'appends the filter extension when path has no extension' {
    $p = Resolve-SaveImagePath -Path '/tmp/a' -FilterFormat 'Png'
    ShouldBeTrue ($p.EndsWith('a.png'))
}
It 'preserves the directory component when correcting extension' {
    $p = Resolve-SaveImagePath -Path '/tmp/sub/foo.txt' -FilterFormat 'Bmp'
    ShouldBeTrue ($p.EndsWith('foo.bmp'))
    ShouldBeTrue ($p -like '*sub*foo.bmp')
}
It 'is case-insensitive for extension recognition' {
    ShouldBe (Resolve-SaveImagePath -Path '/tmp/a.PNG' -FilterFormat 'Jpeg') '/tmp/a.PNG'
}

Describe 'Get-ZoomCenteredOffset'
It 'keeps the same content point under the cursor at center of viewport' {
    # Cursor at (400, 300) in viewport. Old offset 0, old scale 1, new scale 2.
    # Content point under cursor before zoom: (400, 300). After 2x it's at (800, 600).
    # New offset must shift so content (800, 600) maps back to viewport (400, 300).
    $o = Get-ZoomCenteredOffset -CursorX 400 -CursorY 300 `
        -OldScrollX 0 -OldScrollY 0 -OldScale 1 -NewScale 2 `
        -ContentWidth 1920 -ContentHeight 1080 `
        -ViewportWidth 800 -ViewportHeight 600
    ShouldBe $o.X 400; ShouldBe $o.Y 300
}
It 'zooming in near the right edge clamps to the content boundary' {
    # Cursor near right edge; after 2x zoom, the computed offset would exceed content-viewport.
    $o = Get-ZoomCenteredOffset -CursorX 790 -CursorY 590 `
        -OldScrollX 1000 -OldScrollY 400 -OldScale 1 -NewScale 2 `
        -ContentWidth 2000 -ContentHeight 800 `
        -ViewportWidth 800 -ViewportHeight 600
    ShouldBe $o.X 1200   # max = ContentW - ViewportW = 2000 - 800
    ShouldBe $o.Y 200    # max = ContentH - ViewportH = 800 - 600
}
It 'zooming out past the content fit clamps to zero' {
    # Zoom from 2x down to 0.5x in a small image — no room to scroll.
    $o = Get-ZoomCenteredOffset -CursorX 100 -CursorY 100 `
        -OldScrollX 50 -OldScrollY 50 -OldScale 2 -NewScale 0.5 `
        -ContentWidth 200 -ContentHeight 200 `
        -ViewportWidth 400 -ViewportHeight 400
    ShouldBe $o.X 0; ShouldBe $o.Y 0
}
It 'handles a zero OldScale gracefully (treats it as 1)' {
    # Degenerate input; earlier zoom was a no-op. Should not divide by zero.
    $o = Get-ZoomCenteredOffset -CursorX 50 -CursorY 50 `
        -OldScrollX 0 -OldScrollY 0 -OldScale 0 -NewScale 2 `
        -ContentWidth 1000 -ContentHeight 1000 `
        -ViewportWidth 400 -ViewportHeight 400
    ShouldBe $o.X 50; ShouldBe $o.Y 50
}
It 'a no-op scale change leaves the offset untouched' {
    $o = Get-ZoomCenteredOffset -CursorX 123 -CursorY 456 `
        -OldScrollX 77 -OldScrollY 88 -OldScale 1.5 -NewScale 1.5 `
        -ContentWidth 2000 -ContentHeight 1500 `
        -ViewportWidth 800 -ViewportHeight 600
    ShouldBe $o.X 77; ShouldBe $o.Y 88
}
It 'matrix: 0.5x / 1x / 2x / 5x at viewport center produces sensible offsets' {
    $row = 300; $col = 400
    foreach ($s in 0.5, 1.0, 2.0, 5.0) {
        $o = Get-ZoomCenteredOffset -CursorX $col -CursorY $row `
            -OldScrollX 0 -OldScrollY 0 -OldScale 1 -NewScale $s `
            -ContentWidth (4000) -ContentHeight (3000) `
            -ViewportWidth 800 -ViewportHeight 600
        # Expected: cursor*(s-1); clamped to [0, 4000-800] and [0, 3000-600]
        $expectedX = [math]::Max(0.0, [math]::Min(3200.0, $col * ($s - 1)))
        $expectedY = [math]::Max(0.0, [math]::Min(2400.0, $row * ($s - 1)))
        ShouldBe $o.X $expectedX
        ShouldBe $o.Y $expectedY
    }
}

Describe 'Copy-AnnotationList'
It 'returns an empty ArrayList for null input' {
    $r = Copy-AnnotationList $null
    ShouldBe $r.Count 0
}
It 'returns an empty ArrayList for an empty input' {
    $r = Copy-AnnotationList @()
    ShouldBe $r.Count 0
}
It 'deep-copies a single highlight annotation' {
    $src = @([pscustomobject]@{ Type='highlight'; Color='yellow'; X=10; Y=20; W=100; H=50; Text=$null; FontSize=0 })
    $r = Copy-AnnotationList $src
    ShouldBe $r.Count 1
    ShouldBe $r[0].Type 'highlight'
    ShouldBe $r[0].X 10
}
It 'mutations on the copy do not affect the original' {
    $orig = @([pscustomobject]@{ Type='rect'; Color='red'; X=5; Y=5; W=50; H=50; Text=$null; FontSize=0 })
    $copy = Copy-AnnotationList $orig
    $copy[0].X = 999
    ShouldBe $orig[0].X 5    # original untouched
    ShouldBe $copy[0].X 999
}
It 'preserves mixed annotation types (highlight + rect + arrow + text)' {
    $src = @(
        [pscustomobject]@{ Type='highlight'; Color='yellow'; X=0;  Y=0;  W=10; H=10; Text=$null;   FontSize=0 }
        [pscustomobject]@{ Type='rect';      Color='blue';   X=10; Y=10; W=20; H=20; Text=$null;   FontSize=0 }
        [pscustomobject]@{ Type='arrow';     Color='red';    X=20; Y=20; W=30; H=30; Text=$null;   FontSize=0 }
        [pscustomobject]@{ Type='text';      Color='green';  X=30; Y=30; W=40; H=40; Text='hello'; FontSize=24 }
    )
    $r = Copy-AnnotationList $src
    ShouldBe $r.Count 4
    ShouldBe $r[0].Type 'highlight'
    ShouldBe $r[1].Type 'rect'
    ShouldBe $r[2].Type 'arrow'
    ShouldBe $r[3].Type 'text'
    ShouldBe $r[3].Text 'hello'
    ShouldBe $r[3].FontSize 24
}
It 'undo-then-redo round trip: a sequence of copies yields identical content' {
    $original = @(
        [pscustomobject]@{ Type='highlight'; Color='yellow'; X=1; Y=2; W=3; H=4; Text=$null; FontSize=0 }
        [pscustomobject]@{ Type='text';      Color='red';    X=5; Y=6; W=7; H=8; Text='hi';  FontSize=16 }
    )
    $snap1 = Copy-AnnotationList $original      # undo entry
    $snap2 = Copy-AnnotationList $snap1         # redo entry after "undo"
    $snap3 = Copy-AnnotationList $snap2         # restored after "redo"
    ShouldBe $snap3.Count 2
    ShouldBe $snap3[0].X 1
    ShouldBe $snap3[1].Text 'hi'
    # And the original is untouched throughout
    ShouldBe $original[0].X 1
}

Describe 'Get-ClampedAnnotationRect'
It 'passes through a rect that is fully inside' {
    $r = Get-ClampedAnnotationRect -X 10 -Y 20 -Width 100 -Height 50 `
        -BitmapWidth 1920 -BitmapHeight 1080
    ShouldBe $r.X 10; ShouldBe $r.Y 20
    ShouldBe $r.Width 100; ShouldBe $r.Height 50
}
It 'clamps negative origin to (0, 0)' {
    $r = Get-ClampedAnnotationRect -X -5 -Y -10 -Width 100 -Height 80 `
        -BitmapWidth 1920 -BitmapHeight 1080
    ShouldBe $r.X 0; ShouldBe $r.Y 0
}
It 'clamps origin to the bitmap edge minus one when drawn past the right' {
    $r = Get-ClampedAnnotationRect -X 2500 -Y 10 -Width 50 -Height 50 `
        -BitmapWidth 1920 -BitmapHeight 1080
    ShouldBe $r.X 1919
}
It 'shrinks an oversized width so it fits inside the bitmap' {
    $r = Get-ClampedAnnotationRect -X 100 -Y 100 -Width 5000 -Height 50 `
        -BitmapWidth 1920 -BitmapHeight 1080
    ShouldBe $r.Width (1920 - 100)
}
It 'shrinks an oversized height so it fits inside the bitmap' {
    $r = Get-ClampedAnnotationRect -X 100 -Y 100 -Width 50 -Height 5000 `
        -BitmapWidth 1920 -BitmapHeight 1080
    ShouldBe $r.Height (1080 - 100)
}
It 'guarantees a minimum 1x1 size when the origin is pinned to the far corner' {
    $r = Get-ClampedAnnotationRect -X 2000 -Y 2000 -Width 10 -Height 10 `
        -BitmapWidth 1920 -BitmapHeight 1080
    ShouldBe $r.X 1919; ShouldBe $r.Y 1079
    ShouldBe $r.Width 1; ShouldBe $r.Height 1
}
It 'handles a tiny 1x1 bitmap (degenerate but shouldn''t throw)' {
    $r = Get-ClampedAnnotationRect -X 0 -Y 0 -Width 10 -Height 10 `
        -BitmapWidth 1 -BitmapHeight 1
    ShouldBe $r.X 0; ShouldBe $r.Y 0
    ShouldBe $r.Width 1; ShouldBe $r.Height 1
}

Describe 'Get-TrimmedRecent'
It 'returns the input unchanged when under the cap' {
    $r = Get-TrimmedRecent -Items @('c','b','a') -MaxDepth 10
    ShouldBe $r.Count 3
    ShouldBe $r[0] 'c'
}
It 'trims to the top N most recent when over cap' {
    # Stack.ToArray() returns most-recent-first. Use a fixture that lets us
    # assert the invariant (newest kept, oldest dropped) without coupling
    # to the exact index positions of the kept items.
    $newestFirst = @('newest','middle2','middle1','oldest')
    $r = Get-TrimmedRecent -Items $newestFirst -MaxDepth 2
    ShouldBe $r.Count 2
    ShouldBeTrue  ($r -contains 'newest')
    ShouldBeFalse ($r -contains 'oldest')
}
It 'returns empty array for null input' {
    $r = Get-TrimmedRecent -Items $null
    ShouldBe $r.Count 0
}
It 'handles empty array' {
    $r = Get-TrimmedRecent -Items @() -MaxDepth 5
    ShouldBe $r.Count 0
}
It 'exactly-at-cap returns the whole set' {
    $r = Get-TrimmedRecent -Items (1..100) -MaxDepth 100
    ShouldBe $r.Count 100
}

Describe 'Get-LoupePosition flip margins'
It 'uses custom FlipMarginX when near right edge' {
    $p = Get-LoupePosition -MouseX 1900 -MouseY 100 `
        -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 `
        -LoupeWidth 170 -LoupeHeight 190 -FlipMarginX 20
    # After flip: X = MouseX - LoupeWidth - FlipMarginX = 1900 - 170 - 20 = 1710
    ShouldBe $p.X 1710
}
It 'uses custom FlipMarginY when near bottom edge' {
    $p = Get-LoupePosition -MouseX 100 -MouseY 1070 `
        -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080 `
        -LoupeWidth 170 -LoupeHeight 190 -FlipMarginY 25
    # After flip: Y = MouseY - LoupeHeight - FlipMarginY = 1070 - 190 - 25 = 855
    ShouldBe $p.Y 855
}
It 'does not flip when loupe fits comfortably' {
    $p = Get-LoupePosition -MouseX 500 -MouseY 500 `
        -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080
    ShouldBe $p.X 524
    ShouldBe $p.Y 524
}

Describe 'Get-ImageFormatNameFromPath extra'
It 'recognises uppercase .BMP' { ShouldBe (Get-ImageFormatNameFromPath 'x.BMP') 'Bmp' }
It 'defaults .tiff to Png (unsupported)' { ShouldBe (Get-ImageFormatNameFromPath 'x.tiff') 'Png' }
It 'handles dot-prefixed hidden filenames' { ShouldBe (Get-ImageFormatNameFromPath '.hidden.jpg') 'Jpeg' }

Describe 'Test-CaptureRectValid edge'
It 'accepts the exact MinSize boundary' {
    ShouldBeTrue (Test-CaptureRectValid -Width 2 -Height 2 -MinSize 2)
}
It 'rejects width just below MinSize' {
    ShouldBeFalse (Test-CaptureRectValid -Width 1 -Height 2 -MinSize 2)
}
It 'rejects negative dimensions' {
    ShouldBeFalse (Test-CaptureRectValid -Width -5 -Height 10)
}

Describe 'Get-CropBounds DPI scenarios'
It 'maps a non-zero-origin viewport (laptop + 4K right monitor)' {
    # Virtual screen: X=0, Y=0 across both; user clicks on right monitor at (2500, 800)
    $b = Get-CropBounds -RectX 2500 -RectY 800 -RectW 400 -RectH 300 -VsX 0 -VsY 0
    ShouldBe $b.X 2500; ShouldBe $b.Y 800
    ShouldBe $b.Width 400; ShouldBe $b.Height 300
}
It 'maps when virtual screen starts below zero (top monitor above primary)' {
    $b = Get-CropBounds -RectX 100 -RectY -200 -RectW 50 -RectH 50 -VsX 0 -VsY -1080
    ShouldBe $b.X 100; ShouldBe $b.Y 880
}

Describe 'Test-IsSelfWindowHandle (RAN-15 regression)'
It 'returns false for [IntPtr]::Zero regardless of self set' {
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::Zero) -SelfWindowHandles @([IntPtr]::new(5)))
}
It 'returns false for null hwnd' {
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd $null -SelfWindowHandles @([IntPtr]::new(5)))
}
It 'returns false when self set is null' {
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::new(42)) -SelfWindowHandles $null)
}
It 'returns false when self set is empty' {
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::new(42)) -SelfWindowHandles @())
}
It 'returns true when the hwnd matches a single self entry' {
    ShouldBeTrue  (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::new(42)) -SelfWindowHandles @([IntPtr]::new(42)))
}
It 'returns true when the hwnd matches one of several self entries' {
    $selves = @([IntPtr]::new(1), [IntPtr]::new(2), [IntPtr]::new(3))
    ShouldBeTrue  (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::new(2)) -SelfWindowHandles $selves)
}
It 'returns false when no self entry matches' {
    $selves = @([IntPtr]::new(1), [IntPtr]::new(2), [IntPtr]::new(3))
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::new(99)) -SelfWindowHandles $selves)
}
It 'ignores null / zero entries in the self set' {
    $selves = @($null, [IntPtr]::Zero, [IntPtr]::new(7))
    ShouldBeTrue  (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::new(7)) -SelfWindowHandles $selves)
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::Zero) -SelfWindowHandles $selves)
}

Describe 'Resolve-WindowCaptureTarget (RAN-15 regression)'
It 'returns null when no foreground window (zero hwnd)' {
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd ([IntPtr]::Zero) -SelfWindowHandles @([IntPtr]::new(5))
    ShouldBeTrue ($null -eq $r)
}
It 'returns null when foreground is a SnipIT window' {
    $self = [IntPtr]::new(111)
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd $self -SelfWindowHandles @($self)
    ShouldBeTrue ($null -eq $r)
}
It 'returns null when foreground matches any entry in the self set' {
    $selves = @([IntPtr]::new(10), [IntPtr]::new(20), [IntPtr]::new(30))
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd ([IntPtr]::new(20)) -SelfWindowHandles $selves
    ShouldBeTrue ($null -eq $r)
}
It 'returns the hwnd when foreground is a non-SnipIT window' {
    $target = [IntPtr]::new(777)
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd $target -SelfWindowHandles @([IntPtr]::new(111))
    ShouldBe $r $target
}
It 'returns the hwnd when self set is empty' {
    $target = [IntPtr]::new(777)
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd $target -SelfWindowHandles @()
    ShouldBe $r $target
}
It 'returns the hwnd when self set is null (nothing registered yet)' {
    $target = [IntPtr]::new(777)
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd $target -SelfWindowHandles $null
    ShouldBe $r $target
}

Describe 'Invoke-CaptureLoop (RAN-14 regression)'
# Counters live in a hashtable because scriptblocks invoked via `&` get a fresh
# scope, so a plain `$var++` inside the scriptblock would leak nothing back out.
It 'runs zero iterations when the factory returns null immediately' {
    $state = @{ factory = 0; preview = 0 }
    $iters = Invoke-CaptureLoop `
        -CaptureFactory { $state.factory++; $null }.GetNewClosure() `
        -PreviewHandler { $state.preview++; $false }.GetNewClosure()
    ShouldBe $iters 0
    ShouldBe $state.factory 1
    ShouldBe $state.preview 0
}
It 'runs exactly one iteration when preview returns $false' {
    $state = @{ factory = 0; preview = 0 }
    $iters = Invoke-CaptureLoop `
        -CaptureFactory { $state.factory++; [pscustomobject]@{ Id = $state.factory } }.GetNewClosure() `
        -PreviewHandler { $state.preview++; $false }.GetNewClosure()
    ShouldBe $iters 1
    ShouldBe $state.factory 1
    ShouldBe $state.preview 1
}
It 'calls the capture factory once per iteration (no bitmap reuse across New-snip)' {
    # The preview window disposes the capture it receives, so every loop
    # iteration must produce a fresh capture. This asserts the RAN-14 invariant.
    $state = @{ factory = 0; preview = 0 }
    $iters = Invoke-CaptureLoop `
        -CaptureFactory { $state.factory++; [pscustomobject]@{ Id = $state.factory } }.GetNewClosure() `
        -PreviewHandler { $state.preview++; $state.preview -lt 3 }.GetNewClosure()
    ShouldBe $iters 3
    ShouldBe $state.factory 3
    ShouldBe $state.preview 3
}
It 'never hands the same capture instance to the preview twice' {
    $state = @{
        factory = 0
        preview = 0
        seen    = (New-Object System.Collections.Generic.List[object])
    }
    $null = Invoke-CaptureLoop `
        -CaptureFactory { $state.factory++; [pscustomobject]@{ Id = $state.factory } }.GetNewClosure() `
        -PreviewHandler {
            param($cap)
            foreach ($prev in $state.seen) {
                if ([object]::ReferenceEquals($prev, $cap)) {
                    throw "Preview received a reused capture instance (Id=$($cap.Id)) on iteration $($state.preview)"
                }
            }
            $state.seen.Add($cap) | Out-Null
            $state.preview++
            $state.preview -lt 4
        }.GetNewClosure()
    ShouldBe $state.seen.Count 4
}
It 'exits immediately when factory returns null mid-loop' {
    $state = @{ factory = 0; preview = 0 }
    $iters = Invoke-CaptureLoop `
        -CaptureFactory {
            $state.factory++
            if ($state.factory -eq 2) { return $null }
            [pscustomobject]@{ Id = $state.factory }
        }.GetNewClosure() `
        -PreviewHandler { $state.preview++; $true }.GetNewClosure()   # always request another snip
    ShouldBe $iters 1
    ShouldBe $state.factory 2
    ShouldBe $state.preview 1
}
It 'honours MaxIterations safeguard against a preview that always requests more' {
    $state = @{ factory = 0; preview = 0 }
    $iters = Invoke-CaptureLoop -MaxIterations 5 `
        -CaptureFactory { $state.factory++; [pscustomobject]@{ Id = $state.factory } }.GetNewClosure() `
        -PreviewHandler { $state.preview++; $true }.GetNewClosure()
    ShouldBe $iters 5
    ShouldBe $state.factory 5
    ShouldBe $state.preview 5
}
It 'passes the capture from the current iteration into the preview handler' {
    $state = @{
        factory  = 0
        received = (New-Object System.Collections.Generic.List[int])
    }
    $null = Invoke-CaptureLoop `
        -CaptureFactory { $state.factory++; [pscustomobject]@{ Id = $state.factory } }.GetNewClosure() `
        -PreviewHandler {
            param($cap)
            $state.received.Add($cap.Id) | Out-Null
            $state.received.Count -lt 3
        }.GetNewClosure()
    ShouldBe $state.received.Count 3
    ShouldBe $state.received[0] 1
    ShouldBe $state.received[1] 2
    ShouldBe $state.received[2] 3
}

Describe 'Full-screen and window capture New-snip paths (RAN-14 regression)'
# Structural guard: the pure Invoke-CaptureLoop tests above cover the contract,
# but the actual bug was at the call sites (Invoke-FullScreenCapture and
# Invoke-WindowCapture grabbed one bitmap outside the loop and passed that same
# disposed reference back into Show-PreviewWindow on iteration 2+). Inspect the
# source directly so this pattern cannot silently return.
$script:SnipITSource  = Get-Content -Raw (Join-Path $PSScriptRoot 'SnipIT.ps1')
function Get-FunctionBody {
    param([string]$Name)
    $pattern = "(?ms)^function\s+$([regex]::Escape($Name))\s*\{(.*?)^\}"
    $m = [regex]::Match($script:SnipITSource, $pattern)
    if (-not $m.Success) { throw "Function '$Name' not found in SnipIT.ps1" }
    return $m.Groups[1].Value
}
foreach ($fn in 'Invoke-FullScreenCapture', 'Invoke-WindowCapture') {
    It "$fn routes New-snip through Invoke-CaptureLoop" {
        $body = Get-FunctionBody -Name $fn
        ShouldBeTrue ($body -match '\bInvoke-CaptureLoop\b')
    }
    It "$fn does not grab a bitmap outside the preview loop" {
        # The RAN-14 bug pattern: `$bmp = New-ScreenBitmap ...` at the top of
        # the function, followed by a do/while that reuses `$bmp` across
        # iterations. The fix moves the New-ScreenBitmap call inside a
        # per-iteration factory scriptblock, so the only New-ScreenBitmap
        # occurrence in the body must sit inside a `{ ... }` block.
        $body = Get-FunctionBody -Name $fn
        # Iteratively strip innermost braces until none are left so nested
        # scriptblocks (try/finally inside $factory = { ... }) collapse.
        do {
            $prev = $body
            $body = [regex]::Replace($body, '(?s)\{[^{}]*\}', '')
        } while ($body -ne $prev)
        ShouldBeFalse ($body -match 'New-ScreenBitmap')
    }
    It ('{0} does not reuse $bmp across a do/while iteration' -f $fn) {
        $body = Get-FunctionBody -Name $fn
        ShouldBeFalse ($body -match '(?ms)\}\s*while\s*\(\s*\$again\s*\)')
    }
}

Write-Host ""
$total = $script:Pass + $script:Fail
$color = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "Total: $total  |  Pass: $script:Pass  |  Fail: $script:Fail" -ForegroundColor $color
if ($script:Fail) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkRed }
    exit 1
}
