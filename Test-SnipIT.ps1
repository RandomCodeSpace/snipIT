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
