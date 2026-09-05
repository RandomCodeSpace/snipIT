# Cross-platform tests for SnipIT pure logic. No Pester dependency.
# Run: pwsh -NoProfile -File ./Test-SnipIT.ps1
$ErrorActionPreference = 'Stop'

$scriptUnderTest = Join-Path $PSScriptRoot 'SnipIT.ps1'
if (-not (Test-Path -LiteralPath $scriptUnderTest -PathType Leaf)) {
    throw "SnipIT.ps1 not found next to the test script: $scriptUnderTest"
}

# Dot-source SnipIT.ps1 in CoreOnly mode: loads pure functions, then early-returns
# before any Windows-only Bootstrap / PInvoke / UI code runs.
. $scriptUnderTest -CoreOnly

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
It 'samples an odd-sized patch by default so one pixel is dead centre' {
    $r = Get-LoupeSourceRect -MouseX 1000 -MouseY 500 -VsX 0 -VsY 0 -VsWidth 1920 -VsHeight 1080
    ShouldBe ($r.Size % 2) 1
    $half = [math]::Floor($r.Size / 2)
    ShouldBe ($r.X + $half) 1000
    ShouldBe ($r.Y + $half) 500
}

Describe 'Get-LoupeMagnification'
It 'magnifies the shipped loupe by a whole-number factor of 8' {
    $m = Get-LoupeMagnification
    ShouldBe $m.Factor 8
    ShouldBeTrue $m.IsIntegral
    ShouldBeTrue $m.IsCentred
}
It 'reports a fractional viewport-to-source ratio as not integral' {
    $m = Get-LoupeMagnification -ViewportSize 136 -SourceSize 16
    ShouldBeFalse $m.IsIntegral
    ShouldBeFalse $m.IsCentred
}
It 'throws when the source size is not positive' {
    $threw = $false
    try { Get-LoupeMagnification -ViewportSize 136 -SourceSize 0 } catch { $threw = $true }
    ShouldBeTrue $threw
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
It 'uses .jpg for the Jpeg format' {
    $t = [datetime]'2026-04-15T02:46:12'
    ShouldBe (Get-DefaultSnipFilename -Timestamp $t -Format 'Jpeg') 'snip-20260415-024612.jpg'
}
It 'uses .bmp for the Bmp format' {
    $t = [datetime]'2026-04-15T02:46:12'
    ShouldBe (Get-DefaultSnipFilename -Timestamp $t -Format 'Bmp') 'snip-20260415-024612.bmp'
}
It 'uses .png for the explicit Png format' {
    $t = [datetime]'2026-04-15T02:46:12'
    ShouldBe (Get-DefaultSnipFilename -Timestamp $t -Format 'Png') 'snip-20260415-024612.png'
}
It 'rejects a format outside the supported set' {
    $threw = $false
    try { Get-DefaultSnipFilename -Format 'Gif' } catch { $threw = $true }
    ShouldBeTrue $threw
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

Describe 'Test-SnipShortcutCurrent'
$script:DesiredShortcut = [pscustomobject]@{
    TargetPath   = 'C:\Program Files\PowerShell\7\pwsh.exe'
    Arguments    = '-NoProfile -WindowStyle Hidden -Sta -File "C:\App\SnipIT.ps1"'
    IconLocation = 'C:\App\SnipIT.ico,0'
}
It 'reports not-current when no shortcut exists yet' {
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $null -Desired $script:DesiredShortcut)
}
It 'reports current when every managed field already matches' {
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
    }
    ShouldBeTrue (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'reports not-current when the target executable moved' {
    $existing = [pscustomobject]@{
        TargetPath   = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
    }
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'reports not-current when the script argument points elsewhere' {
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = '-NoProfile -WindowStyle Hidden -Sta -File "C:\Old\SnipIT.ps1"'
        IconLocation = $script:DesiredShortcut.IconLocation
    }
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'reports not-current when the icon location drifted' {
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = 'C:\App\Old.ico,0'
    }
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'ignores case and surrounding whitespace when comparing' {
    $existing = [pscustomobject]@{
        TargetPath   = '  c:\program files\powershell\7\PWSH.EXE  '
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = 'c:\app\snipit.ico,0'
    }
    ShouldBeTrue (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'treats an empty desired field as unmanaged and does not force a rewrite' {
    $desired = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = ''
    }
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = ',0'
    }
    ShouldBeTrue (Test-SnipShortcutCurrent -Existing $existing -Desired $desired)
}
It 'reports not-current when the existing shortcut lacks a managed field' {
    $existing = [pscustomobject]@{
        TargetPath = $script:DesiredShortcut.TargetPath
        Arguments  = $script:DesiredShortcut.Arguments
    }
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'accepts a hashtable snapshot as well as a property bag' {
    $existing = @{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
    }
    ShouldBeTrue (Test-SnipShortcutCurrent -Existing $existing -Desired $script:DesiredShortcut)
}
It 'reports not-current when only the icon artwork stamp drifted' {
    # Same target, same arguments, same .ico path — only the artwork inside the
    # .ico changed. Without this the Desktop keeps Explorer's cached bitmap.
    $desired = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
        Description  = Get-SnipShortcutDescription -IconStamp ('a' * 64)
    }
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
        Description  = Get-SnipShortcutDescription -IconStamp ('b' * 64)
    }
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $existing -Desired $desired)
}
It 'reports current when the icon artwork stamp still matches' {
    $description = Get-SnipShortcutDescription -IconStamp ('a' * 64)
    $desired = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
        Description  = $description
    }
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
        Description  = $description
    }
    ShouldBeTrue (Test-SnipShortcutCurrent -Existing $existing -Desired $desired)
}
It 'reports not-current when an older shortcut carries no stamp at all' {
    $desired = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
        Description  = Get-SnipShortcutDescription -IconStamp ('a' * 64)
    }
    $existing = [pscustomobject]@{
        TargetPath   = $script:DesiredShortcut.TargetPath
        Arguments    = $script:DesiredShortcut.Arguments
        IconLocation = $script:DesiredShortcut.IconLocation
        Description  = 'SnipIT - professional snipping tool'
    }
    ShouldBeFalse (Test-SnipShortcutCurrent -Existing $existing -Desired $desired)
}

Describe 'Get-SnipShortcutDescription'
It 'returns the plain description when there is no icon stamp' {
    ShouldBe (Get-SnipShortcutDescription -IconStamp '') 'SnipIT - professional snipping tool'
    ShouldBe (Get-SnipShortcutDescription -IconStamp '   ') 'SnipIT - professional snipping tool'
    ShouldBe (Get-SnipShortcutDescription) 'SnipIT - professional snipping tool'
}
It 'folds the icon hash in, lowercased and truncated to 16 characters' {
    $text = Get-SnipShortcutDescription -IconStamp '037CB62B5A3D6E7F0A4F160498DEFDE78D13D1764CE67E49CDA73239A0CE0161'
    ShouldBe $text 'SnipIT - professional snipping tool (icon 037cb62b5a3d6e7f)'
}
It 'gives different artwork different descriptions' {
    $a = Get-SnipShortcutDescription -IconStamp ('a' * 64)
    $b = Get-SnipShortcutDescription -IconStamp ('b' * 64)
    ShouldBeTrue ($a -ne $b)
}
It 'ignores surrounding whitespace on the stamp' {
    ShouldBe (Get-SnipShortcutDescription -IconStamp "  abcdef0123456789  ") `
        'SnipIT - professional snipping tool (icon abcdef0123456789)'
}
It 'keeps a stamp shorter than the truncation window intact' {
    ShouldBe (Get-SnipShortcutDescription -IconStamp 'abc123') `
        'SnipIT - professional snipping tool (icon abc123)'
}

Describe 'Get-SnipShortcutField'
It 'normalizes null, missing, and whitespace values to empty string' {
    ShouldBe (Get-SnipShortcutField -Source $null -Name 'TargetPath') ''
    ShouldBe (Get-SnipShortcutField -Source ([pscustomobject]@{ A = 1 }) -Name 'TargetPath') ''
    ShouldBe (Get-SnipShortcutField -Source ([pscustomobject]@{ TargetPath = $null }) -Name 'TargetPath') ''
    ShouldBe (Get-SnipShortcutField -Source ([pscustomobject]@{ TargetPath = "  `t " }) -Name 'TargetPath') ''
}
It 'trims a present value' {
    ShouldBe (Get-SnipShortcutField -Source ([pscustomobject]@{ Arguments = '  -Sta  ' }) -Name 'Arguments') '-Sta'
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

Describe 'Get-SnipSaveDialogDefaults'
$saveDialogStamp = [datetime]'2026-04-15T02:46:12'
It 'opens in the configured folder with a PNG name and the PNG filter' {
    $settings = [pscustomobject]@{ SaveFolder = '/tmp/bench'; SaveFormat = 'Png' }
    $d = Get-SnipSaveDialogDefaults -Settings $settings -Now $saveDialogStamp
    ShouldBe $d.InitialDirectory '/tmp/bench'
    ShouldBe $d.FileName 'snip-20260415-024612.png'
    ShouldBe $d.FilterIndex 1
}
It 'selects the JPEG filter and extension for the Jpeg setting' {
    $settings = [pscustomobject]@{ SaveFolder = '/tmp/bench'; SaveFormat = 'Jpeg' }
    $d = Get-SnipSaveDialogDefaults -Settings $settings -Now $saveDialogStamp
    ShouldBe $d.FileName 'snip-20260415-024612.jpg'
    ShouldBe $d.FilterIndex 2
}
It 'selects the BMP filter and extension for the Bmp setting' {
    $settings = [pscustomobject]@{ SaveFolder = '/tmp/bench'; SaveFormat = 'Bmp' }
    $d = Get-SnipSaveDialogDefaults -Settings $settings -Now $saveDialogStamp
    ShouldBe $d.FileName 'snip-20260415-024612.bmp'
    ShouldBe $d.FilterIndex 3
}
It 'falls back to PNG for an unknown persisted format' {
    $settings = [pscustomobject]@{ SaveFolder = '/tmp/bench'; SaveFormat = 'Tiff' }
    $d = Get-SnipSaveDialogDefaults -Settings $settings -Now $saveDialogStamp
    ShouldBe $d.FileName 'snip-20260415-024612.png'
    ShouldBe $d.FilterIndex 1
}
It 'falls back to the Pictures Snips folder when the save folder is empty' {
    $settings = [pscustomobject]@{ SaveFolder = '   '; SaveFormat = 'Png' }
    $d = Get-SnipSaveDialogDefaults -Settings $settings -Now $saveDialogStamp -PicturesDir '/tmp/pics'
    ShouldBe $d.InitialDirectory (Join-Path '/tmp/pics' 'Snips')
}
It 'falls back to the Pictures Snips folder when settings are missing entirely' {
    $d = Get-SnipSaveDialogDefaults -Settings $null -Now $saveDialogStamp -PicturesDir '/tmp/pics'
    ShouldBe $d.InitialDirectory (Join-Path '/tmp/pics' 'Snips')
    ShouldBe $d.FileName 'snip-20260415-024612.png'
    ShouldBe $d.FilterIndex 1
}
It 'tolerates a settings object without the save properties' {
    $d = Get-SnipSaveDialogDefaults -Settings ([pscustomobject]@{ Version = 1 }) `
        -Now $saveDialogStamp -PicturesDir '/tmp/pics'
    ShouldBe $d.InitialDirectory (Join-Path '/tmp/pics' 'Snips')
    ShouldBe $d.FilterIndex 1
}
It 'defaults the folder to Snips when no pictures folder is known' {
    $d = Get-SnipSaveDialogDefaults -Settings $null -Now $saveDialogStamp -PicturesDir ''
    ShouldBe $d.InitialDirectory 'Snips'
}
It 'matches the format the resolver would keep for the generated name' {
    $settings = [pscustomobject]@{ SaveFolder = '/tmp/bench'; SaveFormat = 'Jpeg' }
    $d = Get-SnipSaveDialogDefaults -Settings $settings -Now $saveDialogStamp
    $path = Join-Path $d.InitialDirectory $d.FileName
    ShouldBe (Resolve-SaveImagePath -Path $path -FilterFormat 'Jpeg') $path
    ShouldBe (Get-ImageFormatNameFromPath $path) 'Jpeg'
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
    ShouldBe $r[0].Kind 'Highlight'
    ShouldBe $r[0].Geometry.Type 'Bounds'
    ShouldBe $r[0].Geometry.X 10
}
It 'mutations on the copy do not affect the original' {
    $orig = @([pscustomobject]@{ Type='rect'; Color='red'; X=5; Y=5; W=50; H=50; Text=$null; FontSize=0 })
    $copy = Copy-AnnotationList $orig
    $copy[0].Geometry.X = 999
    ShouldBe $orig[0].X 5    # original untouched
    ShouldBe $copy[0].Geometry.X 999
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
    ShouldBe $r[0].Kind 'Highlight'
    ShouldBe $r[1].Kind 'Rectangle'
    ShouldBe $r[2].Kind 'Arrow'
    ShouldBe $r[3].Kind 'Text'
    ShouldBe $r[2].Geometry.Type 'Line'
    ShouldBe $r[2].Geometry.End.X 50
    ShouldBe $r[3].Properties.Text 'hello'
    ShouldBe $r[3].Properties.FontSize 24
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
    ShouldBe $snap3[0].Geometry.X 1
    ShouldBe $snap3[1].Properties.Text 'hi'
    ShouldBe $snap3[0].Id $snap1[0].Id
    ShouldBe $snap3[1].Id $snap1[1].Id
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

# Was 'Get-CropBounds DPI scenarios', which named a function that took no DPI
# and applied no scale — two translation tests wearing a DPI label. These
# exercise the transform that really does carry the scale.
Describe 'Mixed-DPI viewport scenarios'
It 'maps a point on a 150% 4K monitor right of a 100% laptop panel' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{ Id='laptop'; X=0; Y=0; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$true },
        [pscustomobject]@{ Id='uhd'; X=1920; Y=0; Width=3840; Height=2160
            DpiX=144; DpiY=144; IsPrimary=$false }))
    ShouldBe $layouts[1].ScaleX 1.5
    ShouldBe $layouts[1].DipWidth 2560
    $dip = ConvertTo-SnipDipPoint -PhysicalX 2520 -PhysicalY 900 `
        -MonitorPhysicalX $layouts[1].PhysicalX -MonitorPhysicalY $layouts[1].PhysicalY `
        -ScaleX $layouts[1].ScaleX -ScaleY $layouts[1].ScaleY
    ShouldBe $dip.X 400
    ShouldBe $dip.Y 600
}
It 'maps a point on a monitor mounted above a negative-origin primary' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{ Id='above'; X=0; Y=-1080; Width=1920; Height=1080
            DpiX=120; DpiY=120; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$true }))
    $dip = ConvertTo-SnipDipPoint -PhysicalX 100 -PhysicalY -200 `
        -MonitorPhysicalX $layouts[0].PhysicalX -MonitorPhysicalY $layouts[0].PhysicalY `
        -ScaleX $layouts[0].ScaleX -ScaleY $layouts[0].ScaleY
    ShouldBe $dip.X 80
    ShouldBe $dip.Y 704
    $physical = ConvertTo-SnipPhysicalPoint -DipX $dip.X -DipY $dip.Y `
        -MonitorPhysicalX $layouts[0].PhysicalX -MonitorPhysicalY $layouts[0].PhysicalY `
        -ScaleX $layouts[0].ScaleX -ScaleY $layouts[0].ScaleY
    ShouldBe $physical.X 100
    ShouldBe $physical.Y -200
}

Describe 'Test-IsSelfWindowHandle (capture-exclusion regression)'
It 'returns false for [IntPtr]::Zero regardless of self set' {
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd ([IntPtr]::Zero) -SelfWindowHandles @([IntPtr]::new(5)))
}
It 'returns false for an untyped numeric zero regardless of self set' {
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd 0 -SelfWindowHandles @(5))
}
It 'ignores an untyped numeric zero entry in the self set' {
    ShouldBeTrue (Test-IsSelfWindowHandle -Hwnd 7 -SelfWindowHandles @(0, 7))
    ShouldBeFalse (Test-IsSelfWindowHandle -Hwnd 0 -SelfWindowHandles @(0))
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

Describe 'Resolve-WindowCaptureTarget (capture-exclusion regression)'
It 'returns null when no foreground window (zero hwnd)' {
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd ([IntPtr]::Zero) -SelfWindowHandles @([IntPtr]::new(5))
    ShouldBeTrue ($null -eq $r)
}
It 'returns null when an untyped numeric zero is the foreground hwnd' {
    $r = Resolve-WindowCaptureTarget -ForegroundHwnd 0 -SelfWindowHandles @(5)
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

Describe 'Invoke-CaptureLoop (capture-ownership regression)'
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
    # iteration must produce a fresh capture. This asserts the capture-ownership invariant.
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

Describe 'Capture entry points serialize through the coordinator'
# Structural guard: Task 3 replaces the nested Invoke-CaptureLoop call sites
# with one coordinator.  Keep the old pure loop tests above as the capture-ownership
# regression proof, but require every compatibility entry point to submit a
# request instead of opening a capture or Preview surface itself.
$script:SnipITSource  = Get-Content -Raw (Join-Path $PSScriptRoot 'SnipIT.ps1')
$script:SnipITTokens = $null
$script:SnipITParseErrors = $null
$script:SnipITAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $script:SnipITSource,
    [ref]$script:SnipITTokens,
    [ref]$script:SnipITParseErrors)
function Get-FunctionBody {
    param([string]$Name)
    $pattern = "(?ms)^function\s+$([regex]::Escape($Name))\s*\{(.*?)^\}"
    $m = [regex]::Match($script:SnipITSource, $pattern)
    if (-not $m.Success) { throw "Function '$Name' not found in SnipIT.ps1" }
    return $m.Groups[1].Value
}
function Get-SnipFunctionAst {
    param([string]$Name)
    $matches = @($script:SnipITAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }.GetNewClosure(), $true))
    if ($matches.Count -ne 1) {
        throw "Expected one function AST for '$Name', found $($matches.Count)"
    }
    $matches[0]
}
function Get-SnipCommandAsts {
    param(
        [string]$FunctionName,
        [string]$CommandName
    )
    $scope = if ([string]::IsNullOrWhiteSpace($FunctionName)) {
        $script:SnipITAst
    } else {
        (Get-SnipFunctionAst -Name $FunctionName).Body
    }
    @($scope.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq $CommandName
    }.GetNewClosure(), $true))
}
function Get-SnipCommandParameterValue {
    param(
        [System.Management.Automation.Language.CommandAst]$Command,
        [string]$Name
    )
    $elements = $Command.CommandElements
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or
            $element.ParameterName -ne $Name) {
            continue
        }
        $valueAst = $element.Argument
        if ($null -eq $valueAst -and $index + 1 -lt $elements.Count -and
            $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $valueAst = $elements[$index + 1]
        }
        if ($valueAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $valueAst.Value
        }
        if ($null -ne $valueAst) { return $valueAst.Extent.Text }
        return $null
    }
    return $null
}
function Test-SnipCommandParameter {
    param(
        [System.Management.Automation.Language.CommandAst]$Command,
        [string]$Name
    )
    foreach ($element in $Command.CommandElements) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName -eq $Name) {
            return $true
        }
    }
    $false
}
function Get-SnipContainingFunctionName {
    param([System.Management.Automation.Language.Ast]$Ast)
    $current = $Ast.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }
        $current = $current.Parent
    }
    return $null
}
foreach ($fn in 'Invoke-SmartCapture', 'Invoke-FullScreenCapture', 'Invoke-WindowCapture') {
    It "$fn submits through Request-SnipCapture" {
        $body = Get-FunctionBody -Name $fn
        ShouldBeTrue ($body -match '\bRequest-SnipCapture\b')
    }
    It "$fn cannot invoke capture or Preview surfaces directly" {
        $body = Get-FunctionBody -Name $fn
        ShouldBeFalse ($body -match '\b(?:Invoke-CaptureLoop|Show-SmartOverlay|Show-PreviewWindow|New-ScreenBitmap|Invoke-PendingCapture)\b')
    }
}

function ShouldThrowType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$Body,
        [Parameter(Mandatory)] [type]$ExceptionType
    )

    $caught = $null
    try {
        & $Body
    } catch {
        $caught = $_.Exception
    }
    if ($null -eq $caught) {
        throw "Expected exception '$($ExceptionType.FullName)' but no exception was thrown"
    }

    $current = $caught
    while ($null -ne $current -and -not ($current -is $ExceptionType)) {
        $current = $current.InnerException
    }
    if ($null -eq $current) {
        throw "Expected exception '$($ExceptionType.FullName)' but got '$($caught.GetType().FullName)'"
    }
}

Describe 'Approved theme and settings contracts'
It 'owns no styles: the theme layer is ThemeMode plus value passes' {
    # The UI runs on the stock WPF Fluent dictionaries and edits their values in
    # place. Any reintroduced style / template / resource-map factory is a
    # regression. Asserted against the source text because the theme layer is
    # not loaded in CoreOnly.
    foreach ($retired in 'Get-SnipThemeTokens','Get-SnipFluentPalette',
            'New-SnipThemeResources','Add-SnipThemeResources') {
        ShouldBeFalse ($script:SnipITSource -match "function\s+$retired\b")
        ShouldBe (Get-Command $retired -ErrorAction SilentlyContinue) $null
    }
    ShouldBeFalse ($script:SnipITSource -match "ThemeResources = @'")
    $body = Get-FunctionBody 'Initialize-SnipWindowTheme'
    ShouldBeTrue ($body -match 'ThemeMode')
    ShouldBeFalse ($body -match 'ResourceMap')
    # The one brush the theme layer builds is the opaque ground -- pure black in
    # Dark, pure white in Light. Everything else it does is rewrite Fluent's own
    # keys in place: surfaces neutral, accents red, caption bar to match.
    ShouldBeTrue ($body -match 'Set-SnipNeutralSurfaces')
    ShouldBeTrue ($body -match 'Set-SnipAccentColors')
    ShouldBeTrue ($body -match 'Set-SnipWindowChrome')
    ShouldBeTrue ($body -match 'FromRgb\(0, 0, 0\)')
    ShouldBeTrue ($body -match 'FromRgb\(255, 255, 255\)')
    # High Contrast keeps the palette Windows built, ground included.
    ShouldBeTrue ($body -match 'if \(\$HighContrast\)')
    ShouldBeTrue ($body -match 'SetResourceReference')
    # No colour literal lives here: the red comes from Get-SnipAccentPalette and
    # the ground from the two pure FromRgb calls above.
    $code = (($body -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    ShouldBeFalse ($code -match '#[0-9A-Fa-f]{6}')
}
It 'declares the fixed accent exactly once, as a base to derive from' {
    # One hex in the whole script's accent story. The six tints are computed
    # from it, so a change of accent is a change of one literal.
    $literals = [regex]::Matches($script:SnipITSource, "'#E81123'")
    ShouldBe $literals.Count 1
    ShouldBeTrue ($script:SnipITSource -match
        '\$script:SnipAccentBaseHex = ''#E81123''')
}
It 'reaches the WinForms colour mode through reflection, not a custom renderer' {
    # The tray menu stays a stock ContextMenuStrip on the stock renderer; the
    # only change is the vanilla opt-in, and it has to be reachable on a runtime
    # where the API does not exist at all.
    $body = Get-FunctionBody 'Enable-SnipWinFormsColorMode'
    ShouldBeTrue ($body -match "'System\.Windows\.Forms\.SystemColorMode' -as \[type\]")
    ShouldBeTrue ($body -match "GetMethod\('SetColorMode'")
    # Still the stock renderer, still no colour table of ours: the opt-in is the
    # whole change, and owner drawing would take High Contrast down with it.
    ShouldBeTrue ($script:SnipITSource -match
        '\[System\.Windows\.Forms\.ToolStripProfessionalRenderer\]::new\(\)')
    ShouldBeFalse ($script:SnipITSource -match 'ProfessionalColorTable')
    ShouldBeFalse ($script:SnipITSource -match 'ColorTable\s*=')
    ShouldBeFalse ($script:SnipITSource -match 'ToolStripRenderMode\]::Custom')
    # The opt-in must precede the first WinForms object or WinForms has already
    # latched its palette.
    $optIn = $script:SnipITSource.IndexOf('[void](Enable-SnipWinFormsColorMode)')
    $firstForm = $script:SnipITSource.IndexOf('New-Object System.Windows.Forms.Form')
    ShouldBeTrue ($optIn -gt 0)
    ShouldBeTrue ($optIn -lt $firstForm)
}
It 'no longer carries the dead Mica helper' {
    # Set-MicaBackdrop had no callers and asked DWM for the very backdrop the
    # caption pass now turns off.
    ShouldBeFalse ($script:SnipITSource -match 'Set-MicaBackdrop')
    ShouldBeFalse ($script:SnipITSource -match 'DWMSBT_MAINWINDOW')
    ShouldBeTrue ($script:SnipITSource -match 'DWMSBT_NONE')
}
It 'keeps the accent out of the neutralising step' {
    # The neutral pass paints surfaces, never signals: Copy & close, checked
    # toggles, the slider thumb, the checkbox check and hyperlinks are
    # Set-SnipAccentColors' business and stay red.
    $body = Get-FunctionBody 'Set-SnipNeutralSurfaces'
    ShouldBeTrue ($body -match "\-like '\*Accent\*'")
    if ($script:SnipITSource -notmatch
            '(?s)\$script:SnipNeutralSurfaceKeyPrefixes = @\((?<list>.*?)\r?\n\)') {
        throw 'the neutral surface prefix list is gone'
    }
    $prefixList = $Matches['list']
    ShouldBeFalse ($prefixList -match 'Accent')
    foreach ($expected in "'ApplicationBackground'", "'SolidBackgroundFillColor'",
            "'LayerFillColor'", "'CardBackgroundFillColor'", "'ControlFillColor'",
            "'ControlStrokeColor'", "'DividerStrokeColor'", "'SubtleFillColor'",
            "'TextFillColor'") {
        ShouldBeTrue ($prefixList -match [regex]::Escape($expected))
    }
}
It 'ships no custom theme resource key anywhere in the script' {
    foreach ($pattern in 'Snip[A-Za-z]*Brush', '(?:Dynamic|Static)Resource\s+Snip',
            "Resources\['Snip") {
        if ($script:SnipITSource -match $pattern) {
            throw "SnipIT.ps1 still references a custom theme key: $($Matches[0])"
        }
    }
}
It 'rejects malformed contrast colors' {
    ShouldThrowType -Body {
        Get-SnipContrastRatio -Foreground '#FFF' -Background '#000000' | Out-Null
    } -ExceptionType ([ArgumentException])
}

Describe 'Get-SnipNeutralColor'
It 'returns a grey with the three channels equal' {
    $neutral = Get-SnipNeutralColor -Color '#FF8E3AA7'
    ShouldBe $neutral.R $neutral.G
    ShouldBe $neutral.G $neutral.B
}
It 'preserves alpha exactly' {
    foreach ($alpha in '00', '0F', '4C', 'B3', 'FF') {
        ShouldBe (Get-SnipNeutralColor -Color "#${alpha}3A2B1C").A ([Convert]::ToInt32($alpha, 16))
    }
}
It 'preserves Rec.601 luminance within one level' {
    foreach ($hex in '#B38E3AA7', '#4C433519', '#801E90FF', '#40FCE100') {
        $source = $hex.TrimStart('#')
        $red = [Convert]::ToInt32($source.Substring(2, 2), 16)
        $green = [Convert]::ToInt32($source.Substring(4, 2), 16)
        $blue = [Convert]::ToInt32($source.Substring(6, 2), 16)
        $expected = 0.299 * $red + 0.587 * $green + 0.114 * $blue
        $neutral = Get-SnipNeutralColor -Color $hex
        if ([math]::Abs($neutral.Level - $expected) -gt 1) {
            throw "luminance drifted: $hex -> $($neutral.Level), expected ~$expected"
        }
    }
}
It 'leaves an already neutral colour untouched' {
    foreach ($hex in '#FF202020', '#4C3A3A3A', '#C5FFFFFF', '#15FFFFFF', '#19000000') {
        ShouldBe (Get-SnipNeutralColor -Color $hex).Hex $hex
    }
}
It 'snaps an opaque near-black surface onto pure black' {
    foreach ($hex in '#FF000000', '#FF0A0A0A', '#FF080604') {
        ShouldBe (Get-SnipNeutralColor -Color $hex).Hex '#FF000000'
    }
    # One level above the snap window keeps its weight.
    ShouldBe (Get-SnipNeutralColor -Color '#FF0B0B0B').Hex '#FF0B0B0B'
}
It 'snaps an opaque near-white surface onto pure white' {
    foreach ($hex in '#FFFFFFFF', '#FFFAFAFA', '#FFF9F9F9', '#FFF5F5F5') {
        ShouldBe (Get-SnipNeutralColor -Color $hex).Hex '#FFFFFFFF'
    }
    ShouldBe (Get-SnipNeutralColor -Color '#FFF3F3F3').Hex '#FFF3F3F3'
}
It 'never snaps a translucent fill, whatever its weight' {
    # Translucent fills composite over the ground; snapping would change the
    # stack's weight, which is what keeps the Fluent layering readable.
    ShouldBe (Get-SnipNeutralColor -Color '#0A050505').Hex '#0A050505'
    ShouldBe (Get-SnipNeutralColor -Color '#B3FEFEFE').Hex '#B3FEFEFE'
}
It 'accepts #RRGGBB as fully opaque' {
    ShouldBe (Get-SnipNeutralColor -Color '#202020').Hex '#FF202020'
}
It 'accepts any object exposing A/R/G/B bytes' {
    $neutral = Get-SnipNeutralColor -Color ([pscustomobject]@{ A = 128; R = 219; G = 158; B = 229 })
    ShouldBe $neutral.A 128
    ShouldBe $neutral.Hex '#80B8B8B8'
}
It 'honours a widened snap window' {
    ShouldBe (Get-SnipNeutralColor -Color '#FF202020' -BlackSnap 40).Hex '#FF000000'
    ShouldBe (Get-SnipNeutralColor -Color '#FFF3F3F3' -WhiteSnap 240).Hex '#FFFFFFFF'
}
It 'rejects a malformed colour' {
    ShouldThrowType -Body { Get-SnipNeutralColor -Color '#FFF' | Out-Null } `
        -ExceptionType ([ArgumentException])
    ShouldThrowType -Body { Get-SnipNeutralColor -Color 42 | Out-Null } `
        -ExceptionType ([ArgumentException])
}

Describe 'Get-SnipColorChannels'
It 'splits both spellings into the same four channels' {
    $long = Get-SnipColorChannels -Color '#80E81123'
    ShouldBe $long.A 128; ShouldBe $long.R 232; ShouldBe $long.G 17; ShouldBe $long.B 35
    ShouldBe $long.Hex '#80E81123'
    ShouldBe $long.Rgb '#E81123'
    # #RRGGBB is fully opaque, and .Rgb drops alpha so two colours that differ
    # only in transparency compare equal as family members.
    ShouldBe (Get-SnipColorChannels -Color '#E81123').A 255
    ShouldBe (Get-SnipColorChannels -Color '#E81123').Rgb $long.Rgb
}
It 'accepts any object exposing A/R/G/B and rejects anything else' {
    $object = Get-SnipColorChannels -Color ([pscustomobject]@{ A = 1; R = 2; G = 3; B = 4 })
    ShouldBe $object.Hex '#01020304'
    ShouldThrowType -Body { Get-SnipColorChannels -Color '#FFF' | Out-Null } `
        -ExceptionType ([ArgumentException])
    ShouldThrowType -Body { Get-SnipColorChannels -Color 42 | Out-Null } `
        -ExceptionType ([ArgumentException])
    ShouldThrowType -Body { Get-SnipColorChannels -Color '#FF00GG00' | Out-Null } `
        -ExceptionType ([FormatException])
}

Describe 'Get-SnipAccentTint'
It 'mixes toward white and black by the fraction asked for' {
    # 232,17,35 mixed 20 % toward white: 232 + 0.2 * (255 - 232) = 236.6 -> 237.
    ShouldBe (Get-SnipAccentTint -Color '#E81123' -Toward White -Amount 0.2).Hex '#FFED414F'
    # ...and 20 % toward black: 232 * 0.8 = 185.6 -> 186.
    ShouldBe (Get-SnipAccentTint -Color '#E81123' -Toward Black -Amount 0.2).Hex '#FFBA0E1C'
}
It 'is the identity at 0 and the pure ceiling at 1' {
    ShouldBe (Get-SnipAccentTint -Color '#E81123' -Toward White -Amount 0).Hex '#FFE81123'
    ShouldBe (Get-SnipAccentTint -Color '#E81123' -Toward Black -Amount 0).Hex '#FFE81123'
    ShouldBe (Get-SnipAccentTint -Color '#E81123' -Toward White -Amount 1).Hex '#FFFFFFFF'
    ShouldBe (Get-SnipAccentTint -Color '#E81123' -Toward Black -Amount 1).Hex '#FF000000'
}
It 'rounds away from zero so the ladder stays symmetric' {
    # 0.5 cases: banker's rounding would send 128.5 down to 128 and 127.5 down
    # to 128 as well, collapsing two rungs onto one value.
    ShouldBe (Get-SnipAccentTint -Color '#FF010101' -Toward White -Amount 0.5).Hex '#FF808080'
    ShouldBe (Get-SnipAccentTint -Color '#FF010101' -Toward Black -Amount 0.5).Hex '#FF010101'
    ShouldBe (Get-SnipAccentTint -Color '#FF030303' -Toward Black -Amount 0.5).Hex '#FF020202'
}
It 'carries alpha through untouched' {
    ShouldBe (Get-SnipAccentTint -Color '#40E81123' -Toward White -Amount 0.4).A 64
}
It 'rejects a mix fraction outside 0..1' {
    ShouldThrowType -Body {
        Get-SnipAccentTint -Color '#E81123' -Toward White -Amount 1.5 | Out-Null
    } -ExceptionType ([System.Management.Automation.ParameterBindingException])
}

Describe 'Get-SnipAccentPalette'
It 'derives the six tints from the base by 20 / 40 / 60 per cent mixes' {
    $palette = Get-SnipAccentPalette
    ShouldBe $palette.Base.Hex '#FFE81123'
    ShouldBe $palette.Light1.Hex '#FFED414F'
    ShouldBe $palette.Light2.Hex '#FFF1707B'
    ShouldBe $palette.Light3.Hex '#FFF6A0A7'
    ShouldBe $palette.Dark1.Hex '#FFBA0E1C'
    ShouldBe $palette.Dark2.Hex '#FF8B0A15'
    ShouldBe $palette.Dark3.Hex '#FF5D070E'
}
It 'agrees with the mixer it is built from' {
    $palette = Get-SnipAccentPalette
    foreach ($step in 1, 2, 3) {
        ShouldBe $palette."Light$step".Hex `
            (Get-SnipAccentTint -Color '#E81123' -Toward White -Amount ($step * 0.2)).Hex
        ShouldBe $palette."Dark$step".Hex `
            (Get-SnipAccentTint -Color '#E81123' -Toward Black -Amount ($step * 0.2)).Hex
    }
}
It 'climbs monotonically from Dark3 to Light3' {
    # The ladder is what the shift in Get-SnipAccentMap slides along, so the
    # rungs have to stay in order and distinct.
    $palette = Get-SnipAccentPalette
    $ladder = 'Dark3','Dark2','Dark1','Base','Light1','Light2','Light3' |
        ForEach-Object { $palette.$_ }
    for ($index = 1; $index -lt $ladder.Count; $index++) {
        $previous = $ladder[$index - 1]
        $current = $ladder[$index]
        foreach ($channel in 'R','G','B') {
            if ($current.$channel -le $previous.$channel) {
                throw "channel $channel did not climb at rung $index"
            }
        }
    }
}
It 'pins the ink on the accent to pure white in both themes' {
    ShouldBe (Get-SnipAccentPalette).OnAccent.Hex '#FFFFFFFF'
}
It 'derives from whatever base it is handed' {
    $blue = Get-SnipAccentPalette -Base '#0078D4'
    ShouldBe $blue.Base.Hex '#FF0078D4'
    ShouldBe $blue.Dark1.Hex (Get-SnipAccentTint -Color '#0078D4' -Toward Black -Amount 0.2).Hex
}

Describe 'Get-SnipAccentMap and Get-SnipAccentReplacement'
# A stand-in for the Fluent dictionaries: the Windows accent family on one side,
# a synthetic set of resource entries on the other. Values are the purple accent
# this machine's Windows shipped when the swap was written, so the assertions
# read as 'purple in, red out'.
$script:PurpleFamily = [ordered]@{
    Dark3 = '#FF400E59'; Dark2 = '#FF692782'; Dark1 = '#FF8E3AA7'
    Base = '#FFA94DC1'
    Light1 = '#FFB763CB'; Light2 = '#FFDB9EE5'; Light3 = '#FFF0C0F4'
}
It 'maps a synthetic dictionary: accent and Light2 go red, grey is untouched' {
    $map = Get-SnipAccentMap -Source $script:PurpleFamily
    $dictionary = [ordered]@{
        AccentFillColorDefaultBrush = '#FFA94DC1'
        AccentTextFillColorTertiaryBrush = '#FFDB9EE5'
        ControlFillColorDefaultBrush = '#FF2D2D2D'
    }
    $swapped = [ordered]@{}
    foreach ($entry in $dictionary.GetEnumerator()) {
        $swapped[$entry.Key] = Get-SnipAccentReplacement $entry.Key $entry.Value -Map $map
    }
    ShouldBe $swapped['AccentFillColorDefaultBrush'] '#FFE81123'
    ShouldBe $swapped['AccentTextFillColorTertiaryBrush'] '#FFF1707B'
    # An unrelated grey is not a family member, so it has no replacement and the
    # caller leaves the entry exactly as Fluent wrote it.
    ShouldBe $swapped['ControlFillColorDefaultBrush'] $null
}
It 'keeps every family member distinct after the swap' {
    $map = Get-SnipAccentMap -Source $script:PurpleFamily
    $seen = @{}
    foreach ($entry in $script:PurpleFamily.GetEnumerator()) {
        $swapped = Get-SnipAccentReplacement 'AccentFillColorDefaultBrush' $entry.Value -Map $map
        ShouldBeFalse $seen.ContainsKey($swapped)
        $seen[$swapped] = $entry.Key
    }
    ShouldBe $seen.Count 7
}
It 'shifts the whole ladder so the anchor lands on the red base' {
    # Light mode Fluent fills with Dark1 and Dark mode with Light2, so that the
    # ink Windows chose reads against it. Anchoring on the variant in use is what
    # makes the accent button the same red in both themes.
    $light = Get-SnipAccentMap -Source $script:PurpleFamily -Anchor 'Dark1'
    ShouldBe (Get-SnipAccentReplacement 'x' '#FF8E3AA7' -Map $light) '#FFE81123'
    ShouldBe $light.Shift 1
    $dark = Get-SnipAccentMap -Source $script:PurpleFamily -Anchor 'Light2'
    ShouldBe (Get-SnipAccentReplacement 'x' '#FFDB9EE5' -Map $dark) '#FFE81123'
    ShouldBe $dark.Shift -2
}
It 'clamps at the ends of the ladder rather than running off it' {
    $dark = Get-SnipAccentMap -Source $script:PurpleFamily -Anchor 'Light2'
    # Dark3 shifted two rungs down has nowhere to go, so it stays on Dark3.
    ShouldBe (Get-SnipAccentReplacement 'x' '#FF400E59' -Map $dark) '#FF5D070E'
    $light = Get-SnipAccentMap -Source $script:PurpleFamily -Anchor 'Dark1'
    ShouldBe (Get-SnipAccentReplacement 'x' '#FFF0C0F4' -Map $light) '#FFF6A0A7'
}
It 'falls back to no shift when the anchor is not a family member' {
    $map = Get-SnipAccentMap -Source $script:PurpleFamily -Anchor 'NotAVariant'
    ShouldBe $map.Anchor 'Base'
    ShouldBe $map.Shift 0
}
It 'preserves alpha so a tinted accent wash stays a wash' {
    $map = Get-SnipAccentMap -Source $script:PurpleFamily
    ShouldBe (Get-SnipAccentReplacement 'x' '#33A94DC1' -Map $map) '#33E81123'
    ShouldBe (Get-SnipAccentReplacement 'x' '#00DB9EE5' -Map $map) '#00F1707B'
}
It 'forces the ink on an accent to white by key name, not by value' {
    # These keys hold the black or white Windows picked to read against its own
    # accent, so there is no family colour to recognise -- only the name.
    $map = Get-SnipAccentMap -Source $script:PurpleFamily
    ShouldBe (Get-SnipAccentReplacement 'TextOnAccentFillColorPrimaryBrush' '#FF000000' `
        -Map $map) '#FFFFFFFF'
    ShouldBe (Get-SnipAccentReplacement 'AccentButtonForegroundPressed' '#80000000' `
        -Map $map) '#80FFFFFF'
    # Already white: nothing to do, so nothing is written.
    ShouldBe (Get-SnipAccentReplacement 'TextOnAccentFillColorPrimaryBrush' '#FFFFFFFF' `
        -Map $map) $null
    # A fill key of the same family is not ink and keeps taking the family map.
    ShouldBe (Get-SnipAccentReplacement 'AccentFillColorDefaultBrush' '#FFA94DC1' `
        -Map $map) '#FFE81123'
}
It 'is idempotent: red in, nothing out' {
    # Set-SnipAccentColors runs twice per window -- once at theme time and once
    # after Show() rebuilds the dictionaries -- so a second pass over an already
    # red dictionary must find nothing to change.
    $map = Get-SnipAccentMap -Source $script:PurpleFamily
    foreach ($red in '#FFE81123','#FFED414F','#FFF1707B','#FFF6A0A7',
            '#FFBA0E1C','#FF8B0A15','#FF5D070E') {
        ShouldBe (Get-SnipAccentReplacement 'AccentFillColorDefaultBrush' $red -Map $map) $null
    }
}
It 'ignores a family the host could not read' {
    # Get-SnipSystemAccentFamily yields an empty family on a host with no accent
    # to report; the map is then empty and every colour survives.
    $map = Get-SnipAccentMap -Source ([ordered]@{})
    ShouldBe $map.Colors.Count 0
    ShouldBe (Get-SnipAccentReplacement 'AccentFillColorDefaultBrush' '#FFA94DC1' `
        -Map $map) $null
}
It 'accepts a partial family and maps only what it was given' {
    $map = Get-SnipAccentMap -Source ([ordered]@{ Base = '#FFA94DC1' })
    ShouldBe (Get-SnipAccentReplacement 'x' '#FFA94DC1' -Map $map) '#FFE81123'
    ShouldBe (Get-SnipAccentReplacement 'x' '#FFDB9EE5' -Map $map) $null
}
Describe 'Approved theme and settings contracts (continued)'
It 'defaults to one Smart capture binding on Q' {
    $pictures = Join-Path ([IO.Path]::GetTempPath()) 'Pictures'
    $settings = Get-SnipDefaultSettings -PicturesDir $pictures
    ShouldBe $settings.Version 1
    ShouldBe $settings.Hotkey.Modifiers 0x4007
    ShouldBe $settings.Hotkey.VirtualKey 0x51
    ShouldBe (Format-SnipHotkey -Modifiers $settings.Hotkey.Modifiers -VirtualKey $settings.Hotkey.VirtualKey) 'Ctrl+Alt+Shift+Q'
    ShouldBe $settings.SaveFolder (Join-Path $pictures 'Snips')
    ShouldBe $settings.SaveFormat 'Png'
    ShouldBe $settings.LaunchAtSignIn $true
    ShouldBe $settings.WidgetVisible $false
}

Describe 'Preview dispatcher crash handler (unset-variable regression)'
# The handler that writes %LOCALAPPDATA%\SnipIT\last-error.txt interpolates
# $logFile from outside the try that computes it. If that try throws, an unset
# $logFile makes the handler fail under Set-StrictMode and the crash report is
# lost. Pin the seed assignment so it can never drift back inside the try.
It 'seeds every variable it reports with before the try that computes it' {
    $previewAst = Get-SnipFunctionAst -Name 'Show-PreviewWindow'
    $invocations = @($previewAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($node.Member.Value)" -eq 'add_UnhandledException'
    }, $true))
    ShouldBe $invocations.Count 1
    $handler = $invocations[0].Arguments[0].ScriptBlock
    ShouldBeTrue ($handler.Extent.Text -match 'last-error\.txt')

    $tryStatements = @($handler.FindAll({
        param($node) $node -is [System.Management.Automation.Language.TryStatementAst]
    }, $true))
    ShouldBeTrue ($tryStatements.Count -ge 1)

    $mentions = @($handler.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -eq 'logFile'
    }, $true) | Sort-Object { $_.Extent.StartOffset })
    # Assigned once unconditionally, once inside the try, and read in the report.
    ShouldBeTrue ($mentions.Count -ge 3)

    $first = $mentions[0]
    $insideTry = @($tryStatements | Where-Object {
        $_.Extent.StartOffset -le $first.Extent.StartOffset -and
            $_.Extent.EndOffset -ge $first.Extent.EndOffset
    })
    ShouldBe $insideTry.Count 0

    $seeds = @($handler.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'logFile'
    }, $true) | Where-Object { $_.Extent.StartOffset -le $first.Extent.StartOffset })
    ShouldBe @($seeds).Count 1
}

Describe 'Test-SnipSettingsUnchanged (startup write-skip decision)'
It 'reports unchanged for byte-identical content' {
    $json = '{"Version":1,"SaveFormat":"Png"}'
    ShouldBeTrue (Test-SnipSettingsUnchanged -Existing $json -Candidate $json)
}
It 'ignores the trailing terminator Set-Content appends' {
    $candidate = "{`r`n  `"Version`": 1`r`n}"
    ShouldBeTrue (Test-SnipSettingsUnchanged -Existing ($candidate + "`r`n") -Candidate $candidate)
    ShouldBeTrue (Test-SnipSettingsUnchanged -Existing ($candidate + "`n") -Candidate $candidate)
}
It 'reports changed when any value differs' {
    ShouldBeFalse (Test-SnipSettingsUnchanged `
        -Existing '{"SaveFormat":"Png"}' -Candidate '{"SaveFormat":"Bmp"}')
}
It 'is ordinal, so casing counts as a change' {
    ShouldBeFalse (Test-SnipSettingsUnchanged `
        -Existing '{"SaveFormat":"Png"}' -Candidate '{"saveformat":"Png"}')
}
It 'treats a missing file as changed so the first write always lands' {
    ShouldBeFalse (Test-SnipSettingsUnchanged -Existing $null -Candidate '{"Version":1}')
}
It 'treats an empty file as changed' {
    ShouldBeFalse (Test-SnipSettingsUnchanged -Existing '' -Candidate '{"Version":1}')
}
It 'does not claim equality when there is nothing to compare against' {
    ShouldBeFalse (Test-SnipSettingsUnchanged -Existing '{"Version":1}' -Candidate $null)
}

Describe 'Smart capture hotkey contract'
$validHotkeys = @(
    @{ Name = 'Space'; Modifiers = 0x4003; VirtualKey = 0x20; Display = 'Ctrl+Alt+Space' }
    @{ Name = 'digit zero'; Modifiers = 0x4006; VirtualKey = 0x30; Display = 'Ctrl+Shift+0' }
    @{ Name = 'digit nine'; Modifiers = 0x4005; VirtualKey = 0x39; Display = 'Alt+Shift+9' }
    @{ Name = 'letter A'; Modifiers = 0x4003; VirtualKey = 0x41; Display = 'Ctrl+Alt+A' }
    @{ Name = 'letter Z'; Modifiers = 0x4007; VirtualKey = 0x5A; Display = 'Ctrl+Alt+Shift+Z' }
    @{ Name = 'F1'; Modifiers = 0x4005; VirtualKey = 0x70; Display = 'Alt+Shift+F1' }
    @{ Name = 'F24'; Modifiers = 0x4006; VirtualKey = 0x87; Display = 'Ctrl+Shift+F24' }
)
foreach ($hotkeyCase in $validHotkeys) {
    It "accepts and formats $($hotkeyCase.Name)" {
        ShouldBeTrue (Test-SnipHotkeyDefinition -Modifiers $hotkeyCase.Modifiers -VirtualKey $hotkeyCase.VirtualKey)
        ShouldBe (Format-SnipHotkey -Modifiers $hotkeyCase.Modifiers -VirtualKey $hotkeyCase.VirtualKey) $hotkeyCase.Display
    }
}
$invalidHotkeys = @(
    @{ Name = 'unknown modifier bits'; Modifiers = 0x400B; VirtualKey = 0x51 }
    @{ Name = 'missing NoRepeat'; Modifiers = 0x0003; VirtualKey = 0x51 }
    @{ Name = 'only one chord modifier'; Modifiers = 0x4002; VirtualKey = 0x51 }
    @{ Name = 'bare Shift'; Modifiers = 0x4003; VirtualKey = 0x10 }
    @{ Name = 'Windows key'; Modifiers = 0x4003; VirtualKey = 0x5B }
    @{ Name = 'Escape'; Modifiers = 0x4003; VirtualKey = 0x1B }
    @{ Name = 'Tab'; Modifiers = 0x4003; VirtualKey = 0x09 }
    @{ Name = 'Enter'; Modifiers = 0x4003; VirtualKey = 0x0D }
    @{ Name = 'unlisted Delete'; Modifiers = 0x4003; VirtualKey = 0x2E }
)
foreach ($hotkeyCase in $invalidHotkeys) {
    It "rejects $($hotkeyCase.Name)" {
        ShouldBeFalse (Test-SnipHotkeyDefinition -Modifiers $hotkeyCase.Modifiers -VirtualKey $hotkeyCase.VirtualKey)
    }
}
It 'refuses to format an invalid binding' {
    ShouldThrowType -Body {
        Format-SnipHotkey -Modifiers 0x4002 -VirtualKey 0x51 | Out-Null
    } -ExceptionType ([ArgumentException])
}

Describe 'Preview responsive contract'
It 'selects all exact boundary modes' {
    ShouldBe (Get-PreviewResponsiveMode 1200 700) 'Wide'
    ShouldBe (Get-PreviewResponsiveMode 1199 700) 'Compact'
    ShouldBe (Get-PreviewResponsiveMode 1200 699) 'Compact'
    ShouldBe (Get-PreviewResponsiveMode 900 600) 'Compact'
    ShouldBe (Get-PreviewResponsiveMode 899 700) 'Narrow'
    ShouldBe (Get-PreviewResponsiveMode 1200 599) 'Narrow'
}

Describe 'Mixed-DPI point conversion contract'
It 'round-trips physical pixels through monitor-local DIPs' {
    $dip = ConvertTo-SnipDipPoint `
        -PhysicalX -1295 -PhysicalY 450 `
        -MonitorPhysicalX -1920 -MonitorPhysicalY -90 `
        -ScaleX 1.25 -ScaleY 1.5
    ShouldBe $dip.X 500.0
    ShouldBe $dip.Y 360.0
    ShouldBe ($dip.X.GetType().FullName) 'System.Double'
    ShouldBe ($dip.Y.GetType().FullName) 'System.Double'

    $physical = ConvertTo-SnipPhysicalPoint `
        -DipX $dip.X -DipY $dip.Y `
        -MonitorPhysicalX -1920 -MonitorPhysicalY -90 `
        -ScaleX 1.25 -ScaleY 1.5
    ShouldBe $physical.X -1295
    ShouldBe $physical.Y 450
    ShouldBe ($physical.X.GetType().FullName) 'System.Int32'
    ShouldBe ($physical.Y.GetType().FullName) 'System.Int32'
}
It 'rounds physical midpoint pixels away from zero' {
    $physical = ConvertTo-SnipPhysicalPoint `
        -DipX -0.25 -DipY 0.25 `
        -MonitorPhysicalX 0 -MonitorPhysicalY 0 `
        -ScaleX 2 -ScaleY 2
    ShouldBe $physical.X -1
    ShouldBe $physical.Y 1
}
It 'rejects non-positive monitor scales' {
    ShouldThrowType -Body {
        ConvertTo-SnipDipPoint -PhysicalX 1 -PhysicalY 1 -MonitorPhysicalX 0 -MonitorPhysicalY 0 -ScaleX 0 -ScaleY 1 | Out-Null
    } -ExceptionType ([ArgumentOutOfRangeException])
    ShouldThrowType -Body {
        ConvertTo-SnipDipPoint -PhysicalX 1 -PhysicalY 1 -MonitorPhysicalX 0 -MonitorPhysicalY 0 -ScaleX 1 -ScaleY -1 | Out-Null
    } -ExceptionType ([ArgumentOutOfRangeException])
    ShouldThrowType -Body {
        ConvertTo-SnipPhysicalPoint -DipX 1 -DipY 1 -MonitorPhysicalX 0 -MonitorPhysicalY 0 -ScaleX 0 -ScaleY 1 | Out-Null
    } -ExceptionType ([ArgumentOutOfRangeException])
    ShouldThrowType -Body {
        ConvertTo-SnipPhysicalPoint -DipX 1 -DipY 1 -MonitorPhysicalX 0 -MonitorPhysicalY 0 -ScaleX 1 -ScaleY -1 | Out-Null
    } -ExceptionType ([ArgumentOutOfRangeException])
}

Describe 'Export rectangle contract'
It 'covers the whole source when no crop is applied' {
    $result = Get-SnipExportRectangle -Width 1200 -Height 800 -CropRectangle $null
    ShouldBe $result.X 0
    ShouldBe $result.Y 0
    ShouldBe $result.Width 1200
    ShouldBe $result.Height 800
}
It 'returns a fully contained crop unchanged' {
    $result = Get-SnipExportRectangle -Width 1200 -Height 800 `
        -CropRectangle ([pscustomobject]@{ X = 120; Y = 90; Width = 640; Height = 480 })
    ShouldBe $result.X 120
    ShouldBe $result.Y 90
    ShouldBe $result.Width 640
    ShouldBe $result.Height 480
}
It 'clamps a crop that overhangs the source bounds' {
    $result = Get-SnipExportRectangle -Width 1200 -Height 800 `
        -CropRectangle ([pscustomobject]@{
            X = -50; Y = -20; Width = 400; Height = 300 })
    ShouldBe $result.X 0
    ShouldBe $result.Y 0
    ShouldBe $result.Width 350
    ShouldBe $result.Height 280
    $bottomRight = Get-SnipExportRectangle -Width 1200 -Height 800 `
        -CropRectangle ([pscustomobject]@{
            X = 1100; Y = 700; Width = 400; Height = 300 })
    ShouldBe $bottomRight.X 1100
    ShouldBe $bottomRight.Y 700
    ShouldBe $bottomRight.Width 100
    ShouldBe $bottomRight.Height 100
}
It 'falls back to the full source for a degenerate or off-source crop' {
    $zeroSize = Get-SnipExportRectangle -Width 1200 -Height 800 `
        -CropRectangle ([pscustomobject]@{ X = 10; Y = 10; Width = 0; Height = 50 })
    ShouldBe $zeroSize.Width 1200
    ShouldBe $zeroSize.Height 800
    $offSource = Get-SnipExportRectangle -Width 1200 -Height 800 `
        -CropRectangle ([pscustomobject]@{
            X = 2000; Y = 2000; Width = 50; Height = 50 })
    ShouldBe $offSource.X 0
    ShouldBe $offSource.Y 0
    ShouldBe $offSource.Width 1200
    ShouldBe $offSource.Height 800
}
It 'rejects non-positive source dimensions' {
    ShouldThrowType -Body {
        Get-SnipExportRectangle -Width 0 -Height 800 -CropRectangle $null | Out-Null
    } -ExceptionType ([ArgumentOutOfRangeException])
    ShouldThrowType -Body {
        Get-SnipExportRectangle -Width 1200 -Height -1 -CropRectangle $null | Out-Null
    } -ExceptionType ([ArgumentOutOfRangeException])
}
It 'returns only rectangle properties and never mutates the crop it was given' {
    $crop = [pscustomobject]@{ X = -50; Y = 10; Width = 400; Height = 300 }
    $result = Get-SnipExportRectangle -Width 1200 -Height 800 -CropRectangle $crop
    ShouldBe (@($result.PSObject.Properties.Name) -join ',') 'X,Y,Width,Height'
    ShouldBe $crop.X -50
    ShouldBe $crop.Y 10
    ShouldBe $crop.Width 400
    ShouldBe $crop.Height 300
}

Describe 'Crop-local rectangle contract'
It 'clips a rectangle across the crop top-left and translates it locally' {
    $rect = [pscustomobject]@{ X = 90; Y = 90; Width = 40; Height = 40 }
    $crop = [pscustomobject]@{ X = 100; Y = 100; Width = 100; Height = 100 }
    $result = ConvertTo-SnipCropLocalRect -Rectangle $rect -Crop $crop
    ShouldBe $result.X 0
    ShouldBe $result.Y 0
    ShouldBe $result.Width 30
    ShouldBe $result.Height 30
}
It 'translates a fully contained rectangle without clipping' {
    $result = ConvertTo-SnipCropLocalRect `
        -Rectangle ([pscustomobject]@{ X = 125; Y = 130; Width = 20; Height = 10 }) `
        -Crop ([pscustomobject]@{ X = 100; Y = 100; Width = 100; Height = 100 })
    ShouldBe $result.X 25
    ShouldBe $result.Y 30
    ShouldBe $result.Width 20
    ShouldBe $result.Height 10
}
It 'clips a rectangle across the crop bottom-right' {
    $result = ConvertTo-SnipCropLocalRect `
        -Rectangle ([pscustomobject]@{ X = 180; Y = 190; Width = 30; Height = 20 }) `
        -Crop ([pscustomobject]@{ X = 100; Y = 100; Width = 100; Height = 100 })
    ShouldBe $result.X 80
    ShouldBe $result.Y 90
    ShouldBe $result.Width 20
    ShouldBe $result.Height 10
}
It 'returns null for separated or merely touching half-open bounds' {
    $crop = [pscustomobject]@{ X = 100; Y = 100; Width = 100; Height = 100 }
    ShouldBeTrue ($null -eq (ConvertTo-SnipCropLocalRect `
        -Rectangle ([pscustomobject]@{ X = 0; Y = 0; Width = 10; Height = 10 }) -Crop $crop))
    ShouldBeTrue ($null -eq (ConvertTo-SnipCropLocalRect `
        -Rectangle ([pscustomobject]@{ X = 200; Y = 100; Width = 10; Height = 10 }) -Crop $crop))
}
It 'returns null for non-positive rectangle or crop dimensions' {
    ShouldBeTrue ($null -eq (ConvertTo-SnipCropLocalRect `
        -Rectangle ([pscustomobject]@{ X = 100; Y = 100; Width = 0; Height = 10 }) `
        -Crop ([pscustomobject]@{ X = 100; Y = 100; Width = 100; Height = 100 })))
    ShouldBeTrue ($null -eq (ConvertTo-SnipCropLocalRect `
        -Rectangle ([pscustomobject]@{ X = 100; Y = 100; Width = 10; Height = 10 }) `
        -Crop ([pscustomobject]@{ X = 100; Y = 100; Width = -1; Height = 100 })))
}
It 'returns only local rectangle properties and never mutates its inputs' {
    $rect = [pscustomobject]@{ X = 90; Y = 90; Width = 40; Height = 40 }
    $crop = [pscustomobject]@{ X = 100; Y = 100; Width = 100; Height = 100 }
    $result = ConvertTo-SnipCropLocalRect -Rectangle $rect -Crop $crop
    ShouldBe (@($result.PSObject.Properties.Name) -join ',') 'X,Y,Width,Height'
    ShouldBe $rect.X 90
    ShouldBe $rect.Y 90
    ShouldBe $rect.Width 40
    ShouldBe $rect.Height 40
    ShouldBe $crop.X 100
    ShouldBe $crop.Y 100
    ShouldBe $crop.Width 100
    ShouldBe $crop.Height 100
}

Describe 'Preview key routing contract'
$baseEditorState = @{
    PopupOpen = $false; EditingText = $false; EditingProperty = $false
    Draft = $null; SelectionId = $null; ActiveTool = 'Select'
}
It 'gives Ctrl+Shift+C ownership before focused controls' {
    $state = $baseEditorState.Clone()
    $state.EditingText = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state -Key C -Modifiers @('cTrL', 'sHiFt')) 'CopyKeepOpen'
}
It 'routes Alt+F4 and Alt+Space before focused controls' {
    $state = $baseEditorState.Clone()
    $state.PopupOpen = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Popup -EditorState $state -Key F4 -Modifiers Alt) 'ClosePreview'
    $state.PopupOpen = $false
    $state.EditingText = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state -Key Space -Modifiers Alt) 'ShowSystemMenu'
}
It 'gives open popups navigation and one-level Escape ownership' {
    $state = $baseEditorState.Clone()
    $state.PopupOpen = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key Escape -Modifiers @()) 'ClosePopup'
    foreach ($keyName in 'Up', 'Down', 'Home', 'End', 'Enter') {
        ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key $keyName -Modifiers @()) 'PopupNavigation'
    }
    ShouldBeTrue ($null -eq (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key A -Modifiers @()))
}
It 'treats Popup focus as an open popup' {
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Popup -EditorState $baseEditorState -Key Escape -Modifiers @()) 'ClosePopup'
}
It 'gives text editors ownership before image commands' {
    $state = $baseEditorState.Clone()
    $state.EditingText = $true
    $state.ActiveTool = 'Text'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state -Key C -Modifiers Ctrl) 'TextCopy'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state -Key Enter -Modifiers Ctrl) 'CommitText'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state -Key Escape -Modifiers @()) 'CancelTextEdit'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state -Key A -Modifiers @()) 'TextInput'
}
It 'uses EditingText state even when focus role is not TextEditor' {
    $state = $baseEditorState.Clone()
    $state.EditingText = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key A -Modifiers @()) 'TextInput'
}
It 'gives editable properties ownership before image commands' {
    $state = $baseEditorState.Clone()
    $state.EditingProperty = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole PropertyEditor -EditorState $state -Key Escape -Modifiers @()) 'CancelPropertyEdit'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole PropertyEditor -EditorState $state -Key C -Modifiers Ctrl) 'PropertyInput'
}
It 'preserves focused button activation' {
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $baseEditorState -Key Space -Modifiers @()) 'ActivateFocusedButton'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $baseEditorState -Key Enter -Modifiers @()) 'ActivateFocusedButton'
}
It 'cancels a draft before selection and window Escape behavior' {
    $state = $baseEditorState.Clone()
    $state.Draft = [pscustomobject]@{ Kind = 'Rectangle' }
    $state.SelectionId = 'selection-1'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key Escape -Modifiers @()) 'CancelDraft'
}
It 'routes selected annotation Escape and Delete' {
    $state = $baseEditorState.Clone()
    $state.SelectionId = 'selection-1'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key Escape -Modifiers @()) 'ClearSelection'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key Delete -Modifiers @()) 'DeleteSelection'
}
foreach ($direction in 'Left', 'Right', 'Up', 'Down') {
    It "moves a selected annotation $direction by one or ten" {
        $state = $baseEditorState.Clone()
        $state.SelectionId = 'selection-1'
        ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key $direction -Modifiers @()) "MoveSelection${direction}1"
        ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key $direction -Modifiers SHIFT) "MoveSelection${direction}10"
    }
}
It 'deactivates a drawing tool on Escape before closing Preview' {
    $state = $baseEditorState.Clone()
    $state.ActiveTool = 'Pen'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state -Key Escape -Modifiers @()) 'ActivateSelect'
}
It 'routes canvas image completion commands' {
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key C -Modifiers Ctrl) 'CopyKeepOpen'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key Enter -Modifiers Ctrl) 'CopyAndClose'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key S -Modifiers Ctrl) 'Save'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key N -Modifiers Ctrl) 'NewSmartCapture'
}
It 'routes every zoom-key spelling' {
    foreach ($keyName in 'Plus', 'OemPlus', 'Add') {
        ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key $keyName -Modifiers Ctrl) 'ZoomIn'
    }
    foreach ($keyName in 'Minus', 'OemMinus', 'Subtract') {
        ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key $keyName -Modifiers Ctrl) 'ZoomOut'
    }
    foreach ($keyName in 'D0', 'NumPad0') {
        ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key $keyName -Modifiers Ctrl) 'ZoomFit'
    }
}
It 'routes canvas Space, final Escape, and unmatched keys' {
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key Space -Modifiers @()) 'TemporaryPan'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key Escape -Modifiers @()) 'ClosePreview'
    ShouldBeTrue ($null -eq (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $baseEditorState -Key A -Modifiers @()))
}

function Assert-SnipCoordinatorDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [string]$NextPhase,
        [bool]$QueueLatest = $false,
        [bool]$CloseSurface = $false,
        [bool]$Reject = $false
    )
    ShouldBe $Actual.Action $Action
    ShouldBe $Actual.NextPhase $NextPhase
    ShouldBe $Actual.QueueLatest $QueueLatest
    ShouldBe $Actual.CloseSurface $CloseSurface
    ShouldBe $Actual.Reject $Reject
    ShouldBe (@($Actual.PSObject.Properties.Name) -join ',') 'Action,NextPhase,QueueLatest,CloseSurface,Reject'
}

Describe 'Central coordinator decision contract'
$submitCases = @(
    @{ Phase = 'Idle'; Action = 'Start'; Next = 'CaptureStarting'; Queue = $false; Close = $false; Reject = $false }
    @{ Phase = 'DelayPending'; Action = 'CancelDelayAndStart'; Next = 'CaptureStarting'; Queue = $false; Close = $false; Reject = $false }
    @{ Phase = 'CaptureStarting'; Action = 'QueueLatest'; Next = 'CaptureStarting'; Queue = $true; Close = $false; Reject = $false }
    @{ Phase = 'Selecting'; Action = 'QueueLatestAndClose'; Next = 'Selecting'; Queue = $true; Close = $true; Reject = $false }
    @{ Phase = 'Previewing'; Action = 'QueueLatestAndClose'; Next = 'Previewing'; Queue = $true; Close = $true; Reject = $false }
    @{ Phase = 'Completing'; Action = 'QueueLatest'; Next = 'Completing'; Queue = $true; Close = $false; Reject = $false }
    @{ Phase = 'Recovering'; Action = 'QueueLatest'; Next = 'Recovering'; Queue = $true; Close = $false; Reject = $false }
    @{ Phase = 'Auxiliary'; Action = 'QueueLatestAndClose'; Next = 'Auxiliary'; Queue = $true; Close = $true; Reject = $false }
    @{ Phase = 'ShuttingDown'; Action = 'Reject'; Next = 'ShuttingDown'; Queue = $false; Close = $false; Reject = $true }
)
foreach ($decisionCase in $submitCases) {
    It "maps $($decisionCase.Phase) + Submit" {
        $actual = Get-SnipCoordinatorDecision -Phase $decisionCase.Phase -Event Submit -HasPending $false
        Assert-SnipCoordinatorDecision -Actual $actual `
            -Action $decisionCase.Action -NextPhase $decisionCase.Next `
            -QueueLatest $decisionCase.Queue -CloseSurface $decisionCase.Close -Reject $decisionCase.Reject
    }
}

$completionCases = @(
    @{ Phase = 'DelayPending'; Event = 'DelayElapsed'; WithoutAction = 'Start'; WithoutNext = 'CaptureStarting'; WithAction = 'Start'; WithNext = 'CaptureStarting' }
    @{ Phase = 'CaptureStarting'; Event = 'SmartReady'; WithoutAction = 'OpenSelector'; WithoutNext = 'Selecting'; WithAction = 'DiscardAndStartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'CaptureStarting'; Event = 'DirectReady'; WithoutAction = 'OpenPreview'; WithoutNext = 'Previewing'; WithAction = 'DiscardAndStartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Selecting'; Event = 'SelectionCompleted'; WithoutAction = 'OpenPreview'; WithoutNext = 'Previewing'; WithAction = 'DiscardAndStartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Completing'; Event = 'CopyClosed'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Completing'; Event = 'SaveCompleted'; WithoutAction = 'ReturnPreview'; WithoutNext = 'Previewing'; WithAction = 'ClosePreviewAndStartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Selecting'; Event = 'SurfaceClosed'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Previewing'; Event = 'SurfaceClosed'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Auxiliary'; Event = 'SurfaceClosed'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'DelayPending'; Event = 'UserCancelled'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'CaptureStarting'; Event = 'UserCancelled'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Selecting'; Event = 'UserCancelled'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Previewing'; Event = 'UserCancelled'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Auxiliary'; Event = 'UserCancelled'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'DelayPending'; Event = 'Preempted'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'CaptureStarting'; Event = 'Preempted'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Selecting'; Event = 'Preempted'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Previewing'; Event = 'Preempted'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Auxiliary'; Event = 'Preempted'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'Recovering'; Event = 'Recovered'; WithoutAction = 'ReturnIdle'; WithoutNext = 'Idle'; WithAction = 'StartPending'; WithNext = 'CaptureStarting' }
    @{ Phase = 'ShuttingDown'; Event = 'CleanupFinished'; WithoutAction = 'ShutdownComplete'; WithoutNext = 'ShuttingDown'; WithAction = 'ShutdownComplete'; WithNext = 'ShuttingDown' }
)
foreach ($decisionCase in $completionCases) {
    foreach ($hasPending in @($false, $true)) {
        $pendingLabel = if ($hasPending) { 'with pending' } else { 'without pending' }
        It "maps $($decisionCase.Phase) + $($decisionCase.Event) $pendingLabel" {
            $actual = Get-SnipCoordinatorDecision `
                -Phase $decisionCase.Phase -Event $decisionCase.Event -HasPending $hasPending
            $action = if ($hasPending) { $decisionCase.WithAction } else { $decisionCase.WithoutAction }
            $next = if ($hasPending) { $decisionCase.WithNext } else { $decisionCase.WithoutNext }
            Assert-SnipCoordinatorDecision -Actual $actual -Action $action -NextPhase $next
        }
    }
}

$coordinatorPhases = @(
    'Idle', 'DelayPending', 'CaptureStarting', 'Selecting', 'Previewing',
    'Completing', 'Recovering', 'Auxiliary', 'ShuttingDown'
)
foreach ($phaseName in $coordinatorPhases) {
    foreach ($hasPending in @($false, $true)) {
        $pendingLabel = if ($hasPending) { 'with pending' } else { 'without pending' }
        It "maps $phaseName + Failed $pendingLabel" {
            $actual = Get-SnipCoordinatorDecision -Phase $phaseName -Event Failed -HasPending $hasPending
            if ($phaseName -eq 'ShuttingDown') {
                Assert-SnipCoordinatorDecision -Actual $actual -Action Reject -NextPhase ShuttingDown -Reject $true
            } else {
                Assert-SnipCoordinatorDecision -Actual $actual -Action BeginRecovery -NextPhase Recovering
            }
        }
        It "maps $phaseName + ShutdownRequested $pendingLabel" {
            $actual = Get-SnipCoordinatorDecision -Phase $phaseName -Event ShutdownRequested -HasPending $hasPending
            Assert-SnipCoordinatorDecision -Actual $actual -Action BeginShutdown -NextPhase ShuttingDown
        }
    }
}
It 'rejects unsupported valid phase and event combinations' {
    ShouldThrowType -Body {
        Get-SnipCoordinatorDecision -Phase Idle -Event DelayElapsed -HasPending $false | Out-Null
    } -ExceptionType ([InvalidOperationException])
}
It 'rejects unknown phases and events as invalid arguments' {
    ShouldThrowType -Body {
        Get-SnipCoordinatorDecision -Phase Unknown -Event Submit -HasPending $false | Out-Null
    } -ExceptionType ([ArgumentException])
    ShouldThrowType -Body {
        Get-SnipCoordinatorDecision -Phase Idle -Event Unknown -HasPending $false | Out-Null
    } -ExceptionType ([ArgumentException])
}

function New-TestDisposeProbe {
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

function New-TestCloseSurface {
    param([hashtable]$State)
    [pscustomobject]@{
        Close = {
            param([string]$Result)
            $State.CloseCount++
            $State.LastResult = $Result
        }.GetNewClosure()
    }
}

Describe 'Serialized capture coordinator runtime contract'
It 'creates immutable-shape requests with identity, mode, delay, source, and submission time' {
    $request = New-SnipCaptureRequest -Mode Smart -Delay ([timespan]::FromSeconds(3)) -Source Hotkey
    ShouldBeTrue ($request.Id -is [guid])
    ShouldBe $request.Mode 'Smart'
    ShouldBe $request.Delay ([timespan]::FromSeconds(3))
    ShouldBe $request.Source 'Hotkey'
    ShouldBeTrue ($request.SubmittedAt -is [datetimeoffset])
    ShouldBe (@($request.PSObject.Properties.Name) -join ',') 'Id,Mode,MonitorId,Delay,Source,SubmittedAt'
}

It 'creates Display requests with one stable monitor ID and no native state' {
    $request = New-SnipCaptureRequest -Mode Display -MonitorId 'display-left-125' `
        -Delay ([timespan]::FromSeconds(3)) -Source Tray

    ShouldBe $request.Mode 'Display'
    ShouldBe $request.MonitorId 'display-left-125'
    ShouldBe (@($request.PSObject.Properties.Name) -join ',') `
        'Id,Mode,MonitorId,Delay,Source,SubmittedAt'
    ShouldBeFalse ($request.PSObject.Properties.Name -contains 'Handle')
    ShouldBeFalse ($request.PSObject.Properties.Name -contains 'Window')
}

It 'rejects missing Display monitor IDs and ignores monitor IDs for non-Display requests' {
    ShouldThrowType -ExceptionType ([ArgumentException]) -Body {
        New-SnipCaptureRequest -Mode Display -Source Tray
    }
    ShouldThrowType -ExceptionType ([ArgumentException]) -Body {
        New-SnipCaptureRequest -Mode Display -MonitorId ' ' -Source Tray
    }

    $request = New-SnipCaptureRequest -Mode Full -MonitorId 'display-left-125' -Source Tray
    ShouldBe $request.MonitorId $null
}

It 'routes Display requests through DisplayCapture with the existing callback arguments' {
    $state = @{ CaptureCalls = 0; PreviewedMonitorId = $null; Probe = $null }
    $services = [pscustomobject]@{
        DisplayCapture = {
            param($coordinator,$request)
            $state.CaptureCalls++
            $state.PreviewedMonitorId = $request.MonitorId
            $state.Probe = New-TestDisposeProbe -Id $request.MonitorId
            $state.Probe
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Dispose()
            'UserCancelled'
        }
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

    Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-left-125' -Source Tray | Out-Null

    ShouldBe $state.CaptureCalls 1
    ShouldBe $state.PreviewedMonitorId 'display-left-125'
    ShouldBe $state.Probe.DisposeCount 1
    ShouldBe $coordinator.Phase 'Idle'
}

It 'keeps only the latest pending Display request and preempts the active surface' {
    $surfaceState = @{ CloseCount = 0; LastResult = $null }
    $coordinator = New-SnipCaptureCoordinator -Post { param($work) $null }
    $coordinator.Phase = 'Previewing'
    $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Smart -Source Hotkey
    $coordinator.ActiveSurface = New-TestCloseSurface -State $surfaceState

    Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-left-125' -Source Tray | Out-Null
    Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-primary-100' -Source Tray | Out-Null

    ShouldBe $coordinator.PendingRequest.Mode 'Display'
    ShouldBe $coordinator.PendingRequest.MonitorId 'display-primary-100'
    ShouldBe $surfaceState.CloseCount 1
    ShouldBe $surfaceState.LastResult 'Preempted'
}

It 'delays Display requests and preserves their stable monitor ID through the callback' {
    $state = @{ Callback = $null; DelayedMonitorId = $null; CapturedMonitorId = $null; Probe = $null }
    $services = [pscustomobject]@{
        StartDelay = {
            param($delay,$callback,$request,$coordinator)
            $state.Callback = $callback
            $state.DelayedMonitorId = $request.MonitorId
            [pscustomobject]@{ Id = $request.Id }
        }.GetNewClosure()
        CancelDelay = { param($handle) $null }
        DisplayCapture = {
            param($coordinator,$request)
            $state.CapturedMonitorId = $request.MonitorId
            $state.Probe = New-TestDisposeProbe -Id $request.MonitorId
            $state.Probe
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Dispose()
            'UserCancelled'
        }
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

    Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-portrait-150' -Delay ([timespan]::FromSeconds(2)) -Source Delay | Out-Null
    & $state.Callback

    ShouldBe $state.DelayedMonitorId 'display-portrait-150'
    ShouldBe $state.CapturedMonitorId 'display-portrait-150'
    ShouldBe $state.Probe.DisposeCount 1
    ShouldBe $coordinator.Phase 'Idle'
}

It 'recovers Display requests after a transient post failure without losing the latest monitor ID' {
    $state = @{ PostCalls = 0; CapturedMonitorId = $null; Probe = $null }
    $services = [pscustomobject]@{
        DisplayCapture = {
            param($coordinator,$request)
            $state.CapturedMonitorId = $request.MonitorId
            $state.Probe = New-TestDisposeProbe -Id $request.MonitorId
            $state.Probe
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Dispose()
            'UserCancelled'
        }
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post {
        param($work)
        $state.PostCalls++
        if ($state.PostCalls -eq 1) { throw 'transient display post failure' }
        & $work
    }.GetNewClosure()

    Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-first' -Source Tray | Out-Null
    ShouldBe $coordinator.Phase 'Recovering'

    Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-latest' -Source Tray | Out-Null

    ShouldBe $state.CapturedMonitorId 'display-latest'
    ShouldBe $state.Probe.DisposeCount 1
    ShouldBe $coordinator.Phase 'Idle'
}

It 'applies shutdown parity to an active Display request and rejects later Display requests' {
    $state = @{ Cancels = 0; CloseCount = 0; LastResult = $null }
    $services = [pscustomobject]@{
        CancelDelay = { param($handle) $state.Cancels++ }.GetNewClosure()
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }
    $coordinator.Phase = 'Selecting'
    $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Display `
        -MonitorId 'display-left-125' -Source Tray
    $coordinator.DelayHandle = [pscustomobject]@{}
    $coordinator.ActiveSurface = New-TestCloseSurface -State $state

    Stop-SnipCaptureCoordinator -Coordinator $coordinator
    $rejected = Request-SnipCapture -Coordinator $coordinator -Mode Display `
        -MonitorId 'display-primary-100' -Source Tray

    ShouldBe $coordinator.Phase 'ShuttingDown'
    ShouldBeTrue $coordinator.ShutdownRequested
    ShouldBe $state.Cancels 1
    ShouldBe $state.CloseCount 1
    ShouldBe $state.LastResult 'Shutdown'
    ShouldBe $rejected $null
}

It 'keeps only the latest pending request and marks the active surface Preempted' {
    $posts = [System.Collections.ArrayList]::new()
    $surfaceState = @{ CloseCount = 0; LastResult = $null }
    $coordinator = New-SnipCaptureCoordinator -Post {
        param($work)
        [void]$posts.Add($work)
    }.GetNewClosure()
    Request-SnipCapture -Coordinator $coordinator -Mode Smart -Source Hotkey | Out-Null
    $coordinator.Phase = 'Previewing'
    $coordinator.ActiveSurface = New-TestCloseSurface -State $surfaceState

    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Tray | Out-Null
    Request-SnipCapture -Coordinator $coordinator -Mode Window -Source Widget | Out-Null

    ShouldBe $coordinator.PendingRequest.Mode 'Window'
    ShouldBe $coordinator.PendingRequest.Source 'Widget'
    ShouldBe $surfaceState.LastResult 'Preempted'
    ShouldBe $surfaceState.CloseCount 1
}

It 'owns a one-shot delay whose callback re-enters Request-SnipCapture' {
    $posts = [System.Collections.ArrayList]::new()
    $delayState = @{ Callback = $null; Starts = 0; Cancels = 0 }
    $services = [pscustomobject]@{
        StartDelay = {
            param($delay, $callback, $request, $coordinator)
            $delayState.Starts++
            $delayState.Callback = $callback
            [pscustomobject]@{ Id = $request.Id }
        }.GetNewClosure()
        CancelDelay = {
            param($handle)
            $delayState.Cancels++
        }.GetNewClosure()
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post {
        param($work)
        [void]$posts.Add($work)
    }.GetNewClosure()

    $request = Request-SnipCapture -Coordinator $coordinator -Mode Smart `
        -Delay ([timespan]::FromSeconds(5)) -Source TrayDelay
    ShouldBe $coordinator.Phase 'DelayPending'
    ShouldBe $coordinator.ActiveRequest.Id $request.Id
    ShouldBe $delayState.Starts 1
    ShouldBe $posts.Count 0

    & $delayState.Callback
    ShouldBe $delayState.Cancels 1
    ShouldBe $coordinator.Phase 'CaptureStarting'
    ShouldBe $coordinator.ActiveRequest.Id $request.Id
    ShouldBe $posts.Count 1
}

It 'cancels a delayed request before any capture factory runs' {
    $state = @{ Cancels = 0; Captures = 0 }
    $services = [pscustomobject]@{
        StartDelay = { param($delay,$callback,$request,$coordinator) [pscustomobject]@{} }
        CancelDelay = { param($handle) $state.Cancels++ }.GetNewClosure()
        SmartCapture = { param($coordinator,$request) $state.Captures++; $null }.GetNewClosure()
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }
    Request-SnipCapture -Coordinator $coordinator -Mode Smart `
        -Delay ([timespan]::FromSeconds(3)) -Source TrayDelay | Out-Null

    Close-SnipActiveSurface -Coordinator $coordinator -Result UserCancelled | Out-Null
    ShouldBe $state.Cancels 1
    ShouldBe $state.Captures 0
    ShouldBe $coordinator.Phase 'Idle'
    ShouldBe $coordinator.ActiveRequest $null
}

It 'queues during Completing without interrupting output, then preempts after Save completes' {
    $posts = [System.Collections.ArrayList]::new()
    $surfaceState = @{ CloseCount = 0; LastResult = $null }
    $coordinator = New-SnipCaptureCoordinator -Post {
        param($work)
        [void]$posts.Add($work)
    }.GetNewClosure()
    $coordinator.Phase = 'Completing'
    $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Smart -Source Hotkey
    $coordinator.ActiveSurface = New-TestCloseSurface -State $surfaceState

    Request-SnipCapture -Coordinator $coordinator -Mode Window -Source Tray | Out-Null
    ShouldBe $surfaceState.CloseCount 0
    ShouldBe $coordinator.PendingRequest.Mode 'Window'

    Complete-SnipSurface -Coordinator $coordinator -Result Completed -Operation Save | Out-Null
    ShouldBe $surfaceState.CloseCount 1
    ShouldBe $surfaceState.LastResult 'Preempted'
    ShouldBe $coordinator.Phase 'Previewing'
    ShouldBe $posts.Count 0
}

It 'returns a recoverable Copy failure to Previewing without losing edits' {
    $surfaceState = @{ CloseCount = 0; LastResult = $null }
    $coordinator = New-SnipCaptureCoordinator -Post { param($work) & $work }
    $coordinator.Phase = 'Completing'
    $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Smart -Source Hotkey
    $coordinator.ActiveSurface = New-TestCloseSurface -State $surfaceState

    Complete-SnipSurface -Coordinator $coordinator -Result Failed -Operation Copy | Out-Null
    ShouldBe $coordinator.Phase 'Previewing'
    ShouldBe $surfaceState.CloseCount 0
    ShouldBeTrue ($null -ne $coordinator.ActiveRequest)
}

It 'never recurses even when Post and a reentrant Preview request run synchronously' {
    $state = @{
        Captures = [System.Collections.ArrayList]::new()
        Probes = [System.Collections.ArrayList]::new()
    }
    $services = [pscustomobject]@{
        FullCapture = {
            param($coordinator,$request)
            [void]$state.Captures.Add($request.Source)
            $probe = New-TestDisposeProbe -Id $request.Source
            [void]$state.Probes.Add($probe)
            $probe
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Touch()
            if ($request.Source -eq 'First') {
                Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Second | Out-Null
            }
            $bitmap.Dispose()
            if ($request.Source -eq 'First') { 'Preempted' } else { 'UserCancelled' }
        }.GetNewClosure()
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source First | Out-Null

    ShouldBe $coordinator.MaxPumpDepth 1
    ShouldBe ($state.Captures -join ',') 'First,Second'
    ShouldBe $coordinator.Phase 'Idle'
    ShouldBe $state.Probes.Count 2
    foreach ($probe in $state.Probes) { ShouldBe $probe.DisposeCount 1 }
}

It 'recovers deterministically when Post throws before invoking the pump' {
    $coordinator = New-SnipCaptureCoordinator -Post {
        param($work)
        throw 'post failed'
    }
    $thrown = $null
    try {
        Request-SnipCapture -Coordinator $coordinator -Mode Full -Source ThrowingPost | Out-Null
    } catch {
        $thrown = $_
    }

    ShouldBeTrue ($null -eq $thrown)
    ShouldBeFalse $coordinator.PumpScheduled
    ShouldBeFalse $coordinator.PumpRescheduleRequested
    ShouldBe $coordinator.Phase 'Recovering'
    ShouldBeTrue ($null -ne $coordinator.LastError)
}

It 'recovers deterministically when Post explicitly declines the pump' {
    $coordinator = New-SnipCaptureCoordinator -Post {
        param($work)
        return $false
    }

    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source DeclinedPost | Out-Null

    ShouldBeFalse $coordinator.PumpScheduled
    ShouldBeFalse $coordinator.PumpRescheduleRequested
    ShouldBe $coordinator.Phase 'Recovering'
    ShouldBeTrue ($null -ne $coordinator.LastError)
}

It 'resumes after transient Post failure and runs only the latest pending request' {
    foreach ($failureKind in 'Throw','Decline') {
        $state = @{
            PostCalls = 0
            Queue = [System.Collections.ArrayList]::new()
            Captures = [System.Collections.ArrayList]::new()
            Probes = [System.Collections.ArrayList]::new()
        }
        $services = [pscustomobject]@{
            FullCapture = {
                param($coordinator,$request)
                [void]$state.Captures.Add($request.Source)
                $probe = New-TestDisposeProbe -Id "$failureKind-$($request.Source)"
                [void]$state.Probes.Add($probe)
                $probe
            }.GetNewClosure()
            Preview = {
                param($bitmap,$accept,$coordinator,$request)
                & $accept
                $bitmap.Dispose()
                'UserCancelled'
            }
        }
        $coordinator = New-SnipCaptureCoordinator -Services $services -Post {
            param($work)
            $state.PostCalls++
            if ($state.PostCalls -eq 1) {
                if ($failureKind -eq 'Throw') { throw 'transient post failure' }
                return $false
            }
            [void]$state.Queue.Add($work)
            return $true
        }.GetNewClosure()

        Request-SnipCapture -Coordinator $coordinator -Mode Full -Source First | Out-Null
        ShouldBe $coordinator.Phase 'Recovering'
        ShouldBeFalse $coordinator.PumpScheduled
        ShouldBeFalse $coordinator.PumpRescheduleRequested
        ShouldBe $state.Queue.Count 0

        Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Second | Out-Null
        Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Latest | Out-Null
        ShouldBe $coordinator.PendingRequest.Source 'Latest'
        ShouldBe $state.Queue.Count 1

        while ($state.Queue.Count -gt 0) {
            $work = $state.Queue[0]
            $state.Queue.RemoveAt(0)
            & $work
        }

        ShouldBe ($state.Captures -join ',') 'Latest'
        ShouldBe $state.Probes.Count 1
        ShouldBe $state.Probes[0].DisposeCount 1
        ShouldBe $state.PostCalls 3
        ShouldBe $coordinator.MaxPumpDepth 1
        ShouldBe $coordinator.PendingRequest $null
        ShouldBeFalse $coordinator.PumpScheduled
        ShouldBe $coordinator.Phase 'Idle'
    }
}

It 'retries persistent Post decline only once per new external request' {
    $state = @{ PostCalls = 0 }
    $coordinator = New-SnipCaptureCoordinator -Post {
        param($work)
        $state.PostCalls++
        return $false
    }.GetNewClosure()

    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source First | Out-Null
    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Second | Out-Null
    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Latest | Out-Null

    ShouldBe $state.PostCalls 3
    ShouldBe $coordinator.PendingRequest.Source 'Latest'
    ShouldBeFalse $coordinator.PumpScheduled
    ShouldBeFalse $coordinator.PumpRescheduleRequested
    ShouldBe $coordinator.Phase 'Recovering'
}

It 'does not mistake synchronous Post output for a decline after work ran' {
    $state = @{ Captures = 0 }
    $services = [pscustomobject]@{
        FullCapture = {
            param($coordinator,$request)
            $state.Captures++
            New-TestDisposeProbe -Id synchronous-post
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Dispose()
            'UserCancelled'
        }
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post {
        param($work)
        & $work
        $false
    }

    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source SynchronousPost | Out-Null

    ShouldBe $state.Captures 1
    ShouldBe $coordinator.Phase 'Idle'
    ShouldBeFalse $coordinator.PumpScheduled
    ShouldBe $coordinator.MaxPumpDepth 1
    ShouldBe $coordinator.LastError $null
}

It 'disposes a stale capture before a posted pending transaction begins' {
    $state = @{
        First = $null
        Second = $null
        SecondSawCleanup = $false
    }
    $services = [pscustomobject]@{
        FullCapture = {
            param($coordinator,$request)
            if ($request.Source -eq 'First') {
                $state.First = New-TestDisposeProbe -Id First
                Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Second | Out-Null
                return $state.First
            }
            $state.SecondSawCleanup = ($state.First.DisposeCount -eq 1)
            $state.Second = New-TestDisposeProbe -Id Second
            $state.Second
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Dispose()
            'UserCancelled'
        }
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

    Request-SnipCapture -Coordinator $coordinator -Mode Full -Source First | Out-Null
    ShouldBe $state.First.DisposeCount 1
    ShouldBeTrue $state.SecondSawCleanup
    ShouldBe $state.Second.DisposeCount 1
    ShouldBe $coordinator.MaxPumpDepth 1
}

It 're-resolves active-window capture data for every Window transaction' {
    $state = @{ ResolveCount = 0; Seen = [System.Collections.ArrayList]::new() }
    $services = [pscustomobject]@{
        WindowCapture = {
            param($coordinator,$request)
            $state.ResolveCount++
            $probe = New-TestDisposeProbe -Id ("window-$($state.ResolveCount)")
            $probe | Add-Member -NotePropertyName TargetVersion -NotePropertyValue $state.ResolveCount
            $probe
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            [void]$state.Seen.Add($bitmap.TargetVersion)
            $bitmap.Dispose()
            'UserCancelled'
        }.GetNewClosure()
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }

    Request-SnipCapture -Coordinator $coordinator -Mode Window -Source Tray | Out-Null
    Request-SnipCapture -Coordinator $coordinator -Mode Window -Source Widget | Out-Null
    ShouldBe $state.ResolveCount 2
    ShouldBe ($state.Seen -join ',') '1,2'
}

It 'preserves a pending request through failed recovery and cleans owned state first' {
    $state = @{ Stale = New-TestDisposeProbe -Id Stale; Captured = $false }
    $services = [pscustomobject]@{
        FullCapture = {
            param($coordinator,$request)
            ShouldBe $state.Stale.DisposeCount 1
            $state.Captured = $true
            New-TestDisposeProbe -Id Recovered
        }.GetNewClosure()
        Preview = {
            param($bitmap,$accept,$coordinator,$request)
            & $accept
            $bitmap.Dispose()
            'UserCancelled'
        }
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }
    $coordinator.Phase = 'Selecting'
    $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Smart -Source First
    $coordinator.PendingRequest = New-SnipCaptureRequest -Mode Full -Source Pending
    $coordinator.OwnedBitmap = $state.Stale

    Complete-SnipSurface -Coordinator $coordinator -Result Failed -Operation Selection | Out-Null
    ShouldBeTrue $state.Captured
    ShouldBe $state.Stale.DisposeCount 1
    ShouldBe $coordinator.Phase 'Idle'
    ShouldBe $coordinator.PendingRequest $null
}

It 'stops idempotently, cancels delay, closes surfaces, disposes ownership, and rejects later requests' {
    $state = @{ Cancels = 0; CloseCount = 0; LastResult = $null }
    $services = [pscustomobject]@{
        CancelDelay = { param($handle) $state.Cancels++ }.GetNewClosure()
    }
    $coordinator = New-SnipCaptureCoordinator -Services $services -Post { param($work) & $work }
    $coordinator.Phase = 'Selecting'
    $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Smart -Source Hotkey
    $coordinator.DelayHandle = [pscustomobject]@{}
    $coordinator.OwnedBitmap = New-TestDisposeProbe -Id Shutdown
    $coordinator.ActiveSurface = New-TestCloseSurface -State $state

    Stop-SnipCaptureCoordinator -Coordinator $coordinator
    Stop-SnipCaptureCoordinator -Coordinator $coordinator
    # A modal surface returns after the first shutdown signal.  The follow-up
    # stop must finish state cleanup without signalling or disposing twice.
    $coordinator.ActiveSurface = $null
    $coordinator.SurfaceCloseRequested = $false
    Stop-SnipCaptureCoordinator -Coordinator $coordinator
    $rejected = Request-SnipCapture -Coordinator $coordinator -Mode Full -Source Tray

    ShouldBe $coordinator.Phase 'ShuttingDown'
    ShouldBeTrue $coordinator.ShutdownRequested
    ShouldBe $state.Cancels 1
    ShouldBe $state.CloseCount 1
    ShouldBe $state.LastResult 'Shutdown'
    ShouldBe $coordinator.OwnedBitmap $null
    ShouldBe $coordinator.ActiveRequest $null
    ShouldBe $rejected $null
}

It 'ignores Failed and UserCancelled completions that arrive after shutdown' {
    foreach ($lateResult in 'Failed','UserCancelled') {
        $posts = [System.Collections.ArrayList]::new()
        $coordinator = New-SnipCaptureCoordinator -Post {
            param($work)
            [void]$posts.Add($work)
        }.GetNewClosure()
        $coordinator.Phase = 'Selecting'
        $coordinator.ActiveRequest = New-SnipCaptureRequest -Mode Smart -Source Shutdown

        Stop-SnipCaptureCoordinator -Coordinator $coordinator
        $postsBefore = $posts.Count
        Complete-SnipSurface -Coordinator $coordinator -Result $lateResult `
            -Operation Selection | Out-Null

        ShouldBeTrue $coordinator.ShutdownRequested
        ShouldBe $coordinator.Phase 'ShuttingDown'
        ShouldBe $posts.Count $postsBefore
        ShouldBeFalse $coordinator.PumpScheduled
        ShouldBe $coordinator.ActiveRequest $null
    }
}

It 'has no legacy recursive pending-capture state or direct delayed surface calls' {
    ShouldBeFalse ($script:SnipITSource -match '\$script:PendingCaptureType')
    ShouldBeFalse ($script:SnipITSource -match '\bInvoke-PendingCapture\b')
    $delayBody = Get-FunctionBody -Name Start-DelayedCapture
    ShouldBeTrue ($delayBody -match '\bRequest-SnipCapture\b')
    ShouldBeFalse ($delayBody -match '\b(?:Invoke-SmartCapture|Invoke-FullScreenCapture|Invoke-WindowCapture)\b')
}

It 'routes function-owned capture ingress through exact Request-SnipCapture ASTs' {
    ShouldBe $script:SnipITParseErrors.Count 0

    $widgetCalls = @(Get-SnipCommandAsts -FunctionName Show-FloatingWidget `
        -CommandName Request-SnipCapture)
    ShouldBe $widgetCalls.Count 0
    $widgetBody = Get-FunctionBody -Name Show-FloatingWidget
    ShouldBeFalse ($widgetBody -match '\b(?:Invoke-SmartCapture|Invoke-FullScreenCapture|Invoke-WindowCapture)\b')
    $widgetServiceCalls = [regex]::Matches(
        $widgetBody, "&\s*\`$submitRequest\s+'(Smart|Full|Window)'")
    ShouldBe $widgetServiceCalls.Count 3
    ShouldBe (($widgetServiceCalls | ForEach-Object {
        $_.Groups[1].Value
    } | Sort-Object) -join ',') 'Full,Smart,Window'

    $trayMenuCalls = @(Get-SnipCommandAsts -FunctionName New-SnipTrayMenu `
        -CommandName Request-SnipCapture)
    ShouldBe $trayMenuCalls.Count 0
    $trayMenuBody = Get-FunctionBody -Name New-SnipTrayMenu
    ShouldBeFalse ($trayMenuBody -match '\b(?:Invoke-SmartCapture|Invoke-FullScreenCapture|Invoke-WindowCapture)\b')

    $delayCalls = @(Get-SnipCommandAsts -FunctionName Start-DelayedCapture `
        -CommandName Request-SnipCapture)
    ShouldBe $delayCalls.Count 1
    ShouldBe (Get-SnipCommandParameterValue -Command $delayCalls[0] -Name Source) 'TrayDelay'
    ShouldBeTrue (Test-SnipCommandParameter -Command $delayCalls[0] -Name Delay)

    $previewCalls = @(Get-SnipCommandAsts -FunctionName New-SnipRuntimeCaptureServices `
        -CommandName Request-SnipCapture)
    $previewNewCalls = @($previewCalls | Where-Object {
        (Get-SnipCommandParameterValue -Command $_ -Name Source) -eq 'PreviewNew'
    })
    ShouldBe $previewNewCalls.Count 1
    ShouldBe (Get-SnipCommandParameterValue -Command $previewNewCalls[0] -Name Mode) 'Smart'

    $requestCalls = @(Get-SnipCommandAsts -FunctionName Request-SnipCapture `
        -CommandName Request-SnipCapture)
    $delayElapsedCalls = @($requestCalls | Where-Object {
        Test-SnipCommandParameter -Command $_ -Name DelayElapsed
    })
    ShouldBe $delayElapsedCalls.Count 1
}

It 'routes root hotkey and tray callbacks through exact Request-SnipCapture ASTs' {
    $rootCalls = @(Get-SnipCommandAsts -CommandName Request-SnipCapture | Where-Object {
        $null -eq (Get-SnipContainingFunctionName -Ast $_)
    })
    $hotkeyCalls = @($rootCalls | Where-Object {
        (Get-SnipCommandParameterValue -Command $_ -Name Source) -eq 'Hotkey'
    })
    ShouldBe $hotkeyCalls.Count 1
    ShouldBe (Get-SnipCommandParameterValue -Command $hotkeyCalls[0] -Name Mode) 'Smart'

    $trayCalls = @($rootCalls | Where-Object {
        (Get-SnipCommandParameterValue -Command $_ -Name Source) -eq 'Tray'
    })
    ShouldBe $trayCalls.Count 0

    $serviceAdapterCalls = @($rootCalls | Where-Object {
        (Get-SnipCommandParameterValue -Command $_ -Name Source) -eq '$Source'
    })
    ShouldBe $serviceAdapterCalls.Count 1
    ShouldBe (Get-SnipCommandParameterValue -Command $serviceAdapterCalls[0] -Name Mode) '$Mode'
    ShouldBeTrue (Test-SnipCommandParameter -Command $serviceAdapterCalls[0] -Name Delay)
}

$script:MixedDpiMonitorDescriptors = @(
    [pscustomobject][ordered]@{
        Id = 'left-125'; X = -1600; Y = 0; Width = 1600; Height = 900
        DpiX = 120; DpiY = 120; IsPrimary = $false
    },
    [pscustomobject][ordered]@{
        Id = 'primary-100'; X = 0; Y = 0; Width = 1920; Height = 1080
        DpiX = 96; DpiY = 96; IsPrimary = $true
    }
)

Describe 'Per-monitor Smart overlay geometry contract'
It 'normalizes mixed-DPI descriptors without changing monitor order' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $script:MixedDpiMonitorDescriptors)

    ShouldBe $layouts.Count 2
    ShouldBe (($layouts | ForEach-Object Id) -join ',') 'left-125,primary-100'
    ShouldBe $layouts[0].Index 0
    ShouldBe $layouts[0].PhysicalX -1600
    ShouldBe $layouts[0].PhysicalWidth 1600
    ShouldBe $layouts[0].ScaleX 1.25
    ShouldBe $layouts[0].ScaleY 1.25
    ShouldBe $layouts[0].DipWidth 1280
    ShouldBe $layouts[0].DipHeight 720
    ShouldBe $layouts[1].Index 1
    ShouldBe $layouts[1].ScaleX 1
    ShouldBe $layouts[1].DipWidth 1920
}

It 'round-trips monitor-local DIPs through each layout transform' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $script:MixedDpiMonitorDescriptors)
    foreach ($layout in $layouts) {
        $dip = ConvertTo-SnipDipPoint -PhysicalX ($layout.PhysicalX + 125) `
            -PhysicalY ($layout.PhysicalY + 250) `
            -MonitorPhysicalX $layout.PhysicalX -MonitorPhysicalY $layout.PhysicalY `
            -ScaleX $layout.ScaleX -ScaleY $layout.ScaleY
        $physical = ConvertTo-SnipPhysicalPoint -DipX $dip.X -DipY $dip.Y `
            -MonitorPhysicalX $layout.PhysicalX -MonitorPhysicalY $layout.PhysicalY `
            -ScaleX $layout.ScaleX -ScaleY $layout.ScaleY
        ShouldBe $physical.X ($layout.PhysicalX + 125)
        ShouldBe $physical.Y ($layout.PhysicalY + 250)
    }
}

It 'rejects a malformed monitor descriptor before any layout is emitted' {
    $threw = $false
    try {
        Get-SnipMonitorLayouts -MonitorDescriptors @(
            [pscustomobject]@{ Id='broken'; X=0; Y=0; Width=100; Height=100; DpiX=96 }
        ) | Out-Null
    } catch {
        $threw = $true
        ShouldBeTrue ($_.Exception.Message -match 'DpiY')
    }
    ShouldBeTrue $threw
}

It 'rejects zero-area and non-positive-DPI monitor descriptors' {
    foreach ($case in @(
        @{ Descriptor = [pscustomobject]@{ Id='zero'; X=0; Y=0; Width=0; Height=100; DpiX=96; DpiY=96 }; Pattern = 'Width' },
        @{ Descriptor = [pscustomobject]@{ Id='dpi'; X=0; Y=0; Width=100; Height=100; DpiX=0; DpiY=96 }; Pattern = 'DpiX' }
    )) {
        $threw = $false
        try { Get-SnipMonitorLayouts -MonitorDescriptors @($case.Descriptor) | Out-Null }
        catch {
            $threw = $true
            ShouldBeTrue ($_.Exception.Message -match $case.Pattern)
        }
        ShouldBeTrue $threw
    }
}

It 'maps a cross-monitor physical selection without a seam' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $script:MixedDpiMonitorDescriptors)
    $rect = Get-DragRectangle -AnchorX -500 -AnchorY 100 -CurrentX 500 -CurrentY 600
    $parts = @(Get-SnipOverlayIntersections -Rectangle $rect -MonitorLayouts $layouts)

    ShouldBe $parts.Count 2
    ShouldBe (($parts | Measure-Object PhysicalWidth -Sum).Sum) 1000
    ShouldBe $parts[0].MonitorId 'left-125'
    ShouldBe $parts[0].PhysicalX -500
    ShouldBe $parts[0].PhysicalWidth 500
    ShouldBe $parts[0].DipX 880
    ShouldBe $parts[0].DipWidth 400
    ShouldBe $parts[1].MonitorId 'primary-100'
    ShouldBe $parts[1].PhysicalX 0
    ShouldBe $parts[1].PhysicalWidth 500
    ShouldBe $parts[1].DipX 0
    ShouldBe $parts[1].DipWidth 500
}

It 'uses half-open bounds at the mixed-DPI monitor seam' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $script:MixedDpiMonitorDescriptors)
    $left = @(Get-SnipOverlayIntersections `
        -Rectangle ([pscustomobject]@{ X=-1; Y=10; Width=1; Height=20 }) `
        -MonitorLayouts $layouts)
    $right = @(Get-SnipOverlayIntersections `
        -Rectangle ([pscustomobject]@{ X=0; Y=10; Width=1; Height=20 }) `
        -MonitorLayouts $layouts)
    $both = @(Get-SnipOverlayIntersections `
        -Rectangle ([pscustomobject]@{ X=-1; Y=10; Width=2; Height=20 }) `
        -MonitorLayouts $layouts)

    ShouldBe $left.Count 1
    ShouldBe $left[0].MonitorId 'left-125'
    ShouldBe $right.Count 1
    ShouldBe $right[0].MonitorId 'primary-100'
    ShouldBe $both.Count 2
    ShouldBe (($both | Measure-Object PhysicalWidth -Sum).Sum) 2
}

It 'returns intersections in monitor-layout order' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        $script:MixedDpiMonitorDescriptors[1],
        $script:MixedDpiMonitorDescriptors[0]
    ))
    $parts = @(Get-SnipOverlayIntersections `
        -Rectangle ([pscustomobject]@{ X=-10; Y=10; Width=20; Height=20 }) `
        -MonitorLayouts $layouts)
    ShouldBe (($parts | ForEach-Object MonitorId) -join ',') 'primary-100,left-125'
}

It 'returns no intersections for zero-area selection geometry' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $script:MixedDpiMonitorDescriptors)
    foreach ($rectangle in @(
        [pscustomobject]@{ X=0; Y=0; Width=0; Height=10 },
        [pscustomobject]@{ X=0; Y=0; Width=10; Height=0 }
    )) {
        ShouldBe @(Get-SnipOverlayIntersections -Rectangle $rectangle `
            -MonitorLayouts $layouts).Count 0
    }
}

It 'rejects malformed selection geometry' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors $script:MixedDpiMonitorDescriptors)
    $threw = $false
    try {
        Get-SnipOverlayIntersections `
            -Rectangle ([pscustomobject]@{ X=0; Y=0; Width=10 }) `
            -MonitorLayouts $layouts | Out-Null
    } catch {
        $threw = $true
        ShouldBeTrue ($_.Exception.Message -match 'Height')
    }
    ShouldBeTrue $threw
}

It 'normalizes fractional physical bounds once with away-from-zero rounding' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{
            Id='fractional-left'; X=-1600.5; Y=-0.5
            Width=1600.5; Height=900.5; DpiX=120.0; DpiY=120.0
        },
        [pscustomobject]@{
            Id='fractional-primary'; X=0.0; Y=0.0
            Width=1919.5; Height=1079.5; DpiX=96.0; DpiY=96.0
        }
    ))

    ShouldBe $layouts[0].PhysicalX -1601
    ShouldBe $layouts[0].PhysicalY -1
    ShouldBe $layouts[0].PhysicalWidth 1601
    ShouldBe $layouts[0].PhysicalHeight 901
    ShouldBe $layouts[0].PhysicalRight 0
    ShouldBeTrue ($layouts[0].PhysicalX -is [int])
    ShouldBeTrue ($layouts[0].PhysicalWidth -is [int])
    ShouldBe $layouts[1].PhysicalX 0
    ShouldBe $layouts[1].PhysicalWidth 1920
    ShouldBe $layouts[1].DpiX 96.0

    $parts = @(Get-SnipOverlayIntersections `
        -Rectangle ([pscustomobject]@{ X=-1; Y=10; Width=2; Height=20 }) `
        -MonitorLayouts $layouts)
    ShouldBe $parts.Count 2
    ShouldBe (($parts | Measure-Object PhysicalWidth -Sum).Sum) 2
}

It 'rejects a positive fractional monitor size that normalizes to zero pixels' {
    $threw = $false
    try {
        Get-SnipMonitorLayouts -MonitorDescriptors @(
            [pscustomobject]@{
                Id='subpixel'; X=0; Y=0; Width=0.4; Height=100
                DpiX=96; DpiY=96
            }
        ) | Out-Null
    } catch {
        $threw = $true
        ShouldBeTrue ($_.Exception.Message -match 'Width')
    }
    ShouldBeTrue $threw
}

Describe 'Stable annotation record contract'
It 'freezes the canonical Core API parameter surfaces' {
    $expected = [ordered]@{
        'New-SnipAnnotation'    = @('Kind','Geometry','Color','StrokeWidth','Opacity','Properties','Z','Id')
        'Copy-SnipAnnotation'   = @('Annotation')
        'Find-SnipAnnotation'   = @('Annotations','ImageX','ImageY','Tolerance')
        'Select-SnipAnnotation' = @('Annotations','ImageX','ImageY','Tolerance')
        'Move-SnipAnnotation'   = @('Annotation','DeltaX','DeltaY','SourceWidth','SourceHeight')
        'Resize-SnipAnnotation' = @('Annotation','Handle','DeltaX','DeltaY','SourceWidth','SourceHeight')
        'Get-SnipCropRectangle' = @('Candidate','SourceWidth','SourceHeight','Preset')
        'Set-SnipCrop'          = @('Action','Candidate','SourceWidth','SourceHeight','Preset')
        'New-SnipEditorSnapshot'= @('Annotations','CropRectangle')
    }
    foreach ($entry in $expected.GetEnumerator()) {
        $command = Get-Command $entry.Key -CommandType Function -ErrorAction Stop
        foreach ($parameterName in $entry.Value) {
            ShouldBeTrue $command.Parameters.ContainsKey($parameterName)
        }
    }
}
It 'New-SnipAnnotation creates every canonical field and distinct nonempty IDs' {
    $geometry = [pscustomobject]@{ Type='Bounds'; X=10; Y=20; Width=30; Height=40 }
    $first = New-SnipAnnotation -Kind Rectangle -Geometry $geometry -Color '#FF8069' `
        -StrokeWidth 3 -Opacity 0.75 -Properties ([ordered]@{ Fill='#00000000' }) -Z 4
    $second = New-SnipAnnotation -Kind Rectangle -Geometry $geometry -Color '#FF8069' `
        -StrokeWidth 3 -Opacity 0.75 -Properties ([ordered]@{ Fill='#00000000' }) -Z 4

    ShouldBe (($first.PSObject.Properties.Name) -join ',') `
        'Id,Kind,Geometry,Color,StrokeWidth,Opacity,Properties,Z'
    ShouldBeTrue (-not [string]::IsNullOrWhiteSpace([string]$first.Id))
    ShouldBeFalse ($first.Id -eq $second.Id)
    $parsedId = [guid]::Empty
    ShouldBeTrue ([guid]::TryParse([string]$first.Id, [ref]$parsedId))
    ShouldBe $first.Kind 'Rectangle'
    ShouldBe $first.Geometry.Type 'Bounds'
    ShouldBe $first.Z 4
}
It 'New-SnipAnnotation preserves an explicit import ID without aliasing inputs' {
    $id = [guid]::NewGuid().ToString()
    $geometry = [pscustomobject]@{
        Type='Points'
        Points=@([pscustomobject]@{X=1;Y=2}, [pscustomobject]@{X=3;Y=4})
    }
    $properties = [ordered]@{ Metadata=[pscustomobject]@{ Tags=[Collections.ArrayList]@('a','b') } }
    $record = New-SnipAnnotation -Kind Pen -Geometry $geometry -Color '#A8EFD7' `
        -StrokeWidth 2 -Opacity 1 -Properties $properties -Z 2 -Id $id

    ShouldBe $record.Id $id
    $record.Geometry.Points[0].X = 99
    $record.Properties.Metadata.Tags[0] = 'changed'
    ShouldBe $geometry.Points[0].X 1
    ShouldBe $properties.Metadata.Tags[0] 'a'
}
It 'Copy-SnipAnnotation rejects a canonical record without a stable ID' {
    $canonicalWithoutId = [pscustomobject][ordered]@{
        Kind='Rectangle'
        Geometry=[pscustomobject]@{Type='Bounds';X=1;Y=2;Width=3;Height=4}
        Color='red'; StrokeWidth=1; Opacity=1; Properties=@{}; Z=0
    }
    $threw = $false
    try {
        Copy-SnipAnnotation -Annotation $canonicalWithoutId | Out-Null
    } catch {
        $threw = $_.Exception -is [ArgumentException]
    }
    ShouldBeTrue $threw
}
It 'Copy-SnipAnnotation preserves ID and deeply copies nested semantic values' {
    $id = [guid]::NewGuid().ToString()
    $source = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points'
        Points=[Collections.ArrayList]@(
            [pscustomobject]@{ X=4; Y=5 },
            [pscustomobject]@{ X=8; Y=9 }
        )
    }) -Color '#FFD36B' -StrokeWidth 5 -Opacity 0.4 -Properties ([ordered]@{
        Labels=[Collections.ArrayList]@('one', [pscustomobject]@{ Value=2 })
        Nested=@{ Values=@(3,4); Unrelated='preserved' }
    }) -Z 7 -Id $id

    $copy = Copy-SnipAnnotation -Annotation $source
    ShouldBe $copy.Id $id
    ShouldBeFalse ([object]::ReferenceEquals($source, $copy))
    ShouldBeFalse ([object]::ReferenceEquals($source.Geometry, $copy.Geometry))
    ShouldBeFalse ([object]::ReferenceEquals($source.Geometry.Points, $copy.Geometry.Points))
    ShouldBeFalse ([object]::ReferenceEquals($source.Properties, $copy.Properties))
    ShouldBeFalse ([object]::ReferenceEquals($source.Properties.Labels, $copy.Properties.Labels))
    ShouldBe $copy.Properties.Nested.Unrelated 'preserved'

    $copy.Geometry.Points[0].X = 40
    $copy.Properties.Labels[1].Value = 20
    $copy.Properties.Nested.Values[0] = 30
    ShouldBe $source.Geometry.Points[0].X 4
    ShouldBe $source.Properties.Labels[1].Value 2
    ShouldBe $source.Properties.Nested.Values[0] 3
}
It 'rejects disposable semantic properties without taking ownership' {
    $cache = [IO.MemoryStream]::new()
    try {
        $threw = $false
        try {
            New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
                Type='Bounds';X=1;Y=2;Width=3;Height=4
            }) -Color red -StrokeWidth 1 -Opacity 1 -Properties ([ordered]@{
                Metadata='preserved'; PrivacyCache=$cache
            }) -Z 0 | Out-Null
        } catch {
            $threw = $_.Exception -is [ArgumentException]
        }
        ShouldBeTrue $threw
        ShouldBeTrue $cache.CanWrite
    } finally {
        $cache.Dispose()
    }
}
It 'rejects unsupported mutable reference properties rather than aliasing them' {
    $builder = [Text.StringBuilder]::new('source')
    $source = [pscustomobject][ordered]@{
        Id=[guid]::NewGuid().ToString(); Kind='Rectangle'
        Geometry=[pscustomobject]@{Type='Bounds';X=1;Y=2;Width=3;Height=4}
        Color='red'; StrokeWidth=1; Opacity=1
        Properties=[ordered]@{Builder=$builder; Metadata='preserved'}; Z=0
    }
    $threw = $false
    try {
        Copy-SnipAnnotation -Annotation $source | Out-Null
    } catch {
        $threw = $_.Exception -is [ArgumentException]
    }
    ShouldBeTrue $threw
    ShouldBe $builder.ToString() 'source'
}
It 'canonical copies and editor snapshots isolate supported scalar-key nested maps' {
    $nested = [Collections.Specialized.OrderedDictionary]::new()
    $nested.Add('Labels', [Collections.ArrayList]@(
        'one', [pscustomobject]@{ Value=2; Enabled=$true }
    ))
    $nested.Add([int]7, [ordered]@{ Name='seven'; Values=@(3,4) })
    $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds';X=1;Y=2;Width=30;Height=40
    }) -Color red -StrokeWidth 1 -Opacity 1 -Properties ([ordered]@{
        Nested=$nested; FontSize=[int]14; Visible=$true; Weight=[decimal]1.5
    }) -Z 0

    $copy = Copy-SnipAnnotation -Annotation $annotation
    $snapshot = New-SnipEditorSnapshot -Annotations @($annotation)
    $annotationSeven = ($annotation.Properties.Nested.GetEnumerator() |
        Where-Object { $_.Key -eq [int]7 } | Select-Object -First 1).Value
    $snapshotSeven = ($snapshot.Annotations[0].Properties.Nested.GetEnumerator() |
        Where-Object { $_.Key -eq [int]7 } | Select-Object -First 1).Value
    ShouldBeFalse ([object]::ReferenceEquals($annotation.Properties.Nested, $copy.Properties.Nested))
    ShouldBeFalse ([object]::ReferenceEquals($annotation.Properties.Nested, $snapshot.Annotations[0].Properties.Nested))
    ShouldBeFalse ([object]::ReferenceEquals($annotation.Properties.Nested['Labels'], $copy.Properties.Nested['Labels']))
    ShouldBeFalse ([object]::ReferenceEquals($annotationSeven, $snapshotSeven))
    $copy.Properties.Nested['Labels'][1].Value = 20
    $snapshotSeven.Values[0] = 30
    ShouldBe $annotation.Properties.Nested['Labels'][1].Value 2
    ShouldBe $annotationSeven.Values[0] 3
    ShouldBe $annotation.Properties.FontSize 14
    ShouldBe $annotation.Properties.Visible $true
    ShouldBe $annotation.Properties.Weight ([decimal]1.5)
}
It 'rejects disposable and mutable dictionary keys without changing their source state' {
    $stream = [IO.MemoryStream]::new()
    $builder = [Text.StringBuilder]::new('source-key')
    try {
        $results = [Collections.ArrayList]::new()
        foreach ($key in @($stream, $builder)) {
            $payload = [pscustomobject]@{ Name='source-value' }
            $properties = [Collections.Specialized.OrderedDictionary]::new()
            $properties.Add($key, $payload)
            $source = [pscustomobject][ordered]@{
                Id=[guid]::NewGuid().ToString();Kind='Rectangle'
                Geometry=[pscustomobject]@{Type='Bounds';X=1;Y=2;Width=3;Height=4}
                Color='red';StrokeWidth=1;Opacity=1;Properties=$properties;Z=0
            }
            $threw = $false
            try {
                Copy-SnipAnnotation -Annotation $source | Out-Null
            } catch {
                $threw = $_.Exception -is [ArgumentException]
            }
            [void]$results.Add($threw)
            ShouldBe $properties.Count 1
            ShouldBeTrue ([object]::ReferenceEquals($properties[$key], $payload))
        }
        ShouldBeTrue $stream.CanWrite
        ShouldBe $builder.ToString() 'source-key'
        ShouldBe ($results -join ',') 'True,True'
    } finally {
        $stream.Dispose()
    }
}
It 'canonical copies reject a value type that carries a disposable reference without taking ownership' {
    $stream = [IO.MemoryStream]::new()
    try {
        $pair = [Collections.Generic.KeyValuePair[string,IO.MemoryStream]]::new('Cache', $stream)
        $source = [pscustomobject][ordered]@{
            Id=[guid]::NewGuid().ToString();Kind='Rectangle'
            Geometry=[pscustomobject]@{Type='Bounds';X=1;Y=2;Width=3;Height=4}
            Color='red';StrokeWidth=1;Opacity=1
            Properties=[ordered]@{ Pair=$pair; Metadata='source' };Z=0
        }
        $threw = $false
        try {
            Copy-SnipAnnotation -Annotation $source | Out-Null
        } catch {
            $threw = $_.Exception -is [ArgumentException]
        }
        ShouldBeTrue $stream.CanWrite
        ShouldBeTrue ([object]::ReferenceEquals($source.Properties.Pair.Value, $stream))
        ShouldBe $source.Properties.Metadata 'source'
        ShouldBeTrue $threw
    } finally {
        $stream.Dispose()
    }
}
It 'editor snapshots reject a value type that carries a reference without aliasing source state' {
    $builder = [Text.StringBuilder]::new('snapshot-source')
    $pair = [Collections.Generic.KeyValuePair[string,Text.StringBuilder]]::new('Builder', $builder)
    $source = [pscustomobject][ordered]@{
        Id=[guid]::NewGuid().ToString();Kind='Rectangle'
        Geometry=[pscustomobject]@{Type='Bounds';X=1;Y=2;Width=3;Height=4}
        Color='red';StrokeWidth=1;Opacity=1
        Properties=[ordered]@{ Pair=$pair; Metadata='source' };Z=0
    }
    $threw = $false
    try {
        New-SnipEditorSnapshot -Annotations @($source) | Out-Null
    } catch {
        $threw = $_.Exception -is [ArgumentException]
    }
    ShouldBe $builder.ToString() 'snapshot-source'
    ShouldBeTrue ([object]::ReferenceEquals($source.Properties.Pair.Value, $builder))
    ShouldBe $source.Properties.Metadata 'source'
    ShouldBeTrue $threw
}
It 'normalizes point geometry with a linear collection builder' {
    $command = Get-Command ConvertTo-SnipAnnotationGeometry -CommandType Function
    $plusEquals = @($command.ScriptBlock.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Operator -eq [Management.Automation.Language.TokenKind]::PlusEquals
    }, $true))
    ShouldBe $plusEquals.Count 0
}
It 'Copy-AnnotationList normalizes legacy records and retains ArrayList caller shape' {
    $legacyId = [guid]::NewGuid().ToString()
    $legacy = [pscustomobject]@{
        Id=$legacyId; Type='arrow'; Color='red'; X=2; Y=3; W=10; H=-2
        Text=$null; FontSize=0
    }
    $canonical = New-SnipAnnotation -Kind Text -Geometry ([pscustomobject]@{
        Type='TextBounds'; X=20; Y=30; Width=40; Height=10
    }) -Color='green' -StrokeWidth 1 -Opacity 1 -Properties ([ordered]@{
        Text='hello'; FontSize=14
    }) -Z 5
    $copy = Copy-AnnotationList -Annotations @($legacy, $canonical)

    ShouldBeTrue ($copy -is [Collections.ArrayList])
    ShouldBe $copy.Count 2
    ShouldBe $copy[0].Id $legacyId
    ShouldBe $copy[0].Kind 'Arrow'
    ShouldBe $copy[0].Geometry.Type 'Line'
    ShouldBe $copy[0].Geometry.Start.X 2
    ShouldBe $copy[0].Geometry.End.X 12
    ShouldBe $copy[0].Geometry.End.Y 1
    ShouldBe $copy[1].Id $canonical.Id
    ShouldBeFalse ([object]::ReferenceEquals($canonical.Properties, $copy[1].Properties))
}
It 'normalizes no-ID legacy records once with stable IDs and canonical defaults' {
    $legacy = @(
        [pscustomobject]@{Type='rect';Color='red';X=1;Y=2;W=10;H=12;Text=$null;FontSize=0}
        [pscustomobject]@{Type='arrow';Color='green';X=20;Y=22;W=5;H=6;Text=$null;FontSize=0}
    )
    $normalized = Copy-AnnotationList -Annotations $legacy
    $firstId = [guid]::Empty
    $secondId = [guid]::Empty
    ShouldBeTrue ([guid]::TryParse([string]$normalized[0].Id, [ref]$firstId))
    ShouldBeTrue ([guid]::TryParse([string]$normalized[1].Id, [ref]$secondId))
    ShouldBeFalse ($normalized[0].Id -eq $normalized[1].Id)
    ShouldBe $normalized[0].Kind 'Rectangle'
    ShouldBe $normalized[0].Geometry.Type 'Bounds'
    ShouldBe $normalized[1].Kind 'Arrow'
    ShouldBe $normalized[1].Geometry.Type 'Line'
    foreach ($annotation in $normalized) {
        ShouldBe $annotation.StrokeWidth 1
        ShouldBe $annotation.Opacity 1
        ShouldBeFalse ($null -eq $annotation.Properties)
        ShouldBe $annotation.Z 0
    }

    $again = Copy-AnnotationList -Annotations $normalized
    ShouldBe $again[0].Id $normalized[0].Id
    ShouldBe $again[1].Id $normalized[1].Id
    ShouldBe (Select-SnipAnnotation -Annotations $again -ImageX 5 -ImageY 5 -Tolerance 0) $again[0].Id
    ShouldBe (Find-SnipAnnotation -Annotations $again -ImageX 22 -ImageY 24 -Tolerance 1).Id $again[1].Id
}
It 'editor snapshots preserve IDs and isolate annotations and crop records' {
    $annotation = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points'; Points=@([pscustomobject]@{X=3;Y=4},[pscustomobject]@{X=20;Y=10})
    }) -Color red -StrokeWidth 2 -Opacity 1 -Properties ([ordered]@{
        Metadata=[pscustomobject]@{Tags=[Collections.ArrayList]@('one','two')}
    }) -Z 0
    $crop = [pscustomobject]@{ X=5; Y=6; Width=70; Height=50 }
    $snapshot = New-SnipEditorSnapshot -Annotations @($annotation) -CropRectangle $crop

    ShouldBe (($snapshot.PSObject.Properties.Name) -join ',') 'Version,Annotations,CropRectangle'
    ShouldBe $snapshot.Version 1
    ShouldBeTrue ($snapshot.Annotations -is [Collections.ArrayList])
    ShouldBe $snapshot.Annotations[0].Id $annotation.Id
    ShouldBeFalse ([object]::ReferenceEquals($snapshot.Annotations[0], $annotation))
    ShouldBeFalse ([object]::ReferenceEquals($snapshot.Annotations[0].Geometry.Points, $annotation.Geometry.Points))
    ShouldBeFalse ([object]::ReferenceEquals($snapshot.Annotations[0].Properties.Metadata, $annotation.Properties.Metadata))
    ShouldBeFalse ([object]::ReferenceEquals($snapshot.CropRectangle, $crop))
    $snapshot.Annotations[0].Geometry.Points[0].X = 99
    $snapshot.Annotations[0].Properties.Metadata.Tags[0] = 'changed'
    $snapshot.CropRectangle.X = 88
    ShouldBe $annotation.Geometry.Points[0].X 3
    ShouldBe $annotation.Properties.Metadata.Tags[0] 'one'
    ShouldBe $crop.X 5
}

Describe 'Annotation hit and selection contract'
It 'Find-SnipAnnotation chooses greatest Z and the later list member on a tie' {
    $low = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=0; Y=0; Width=40; Height=40
    }) -Color low -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 1
    $tieEarlier = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=5; Y=5; Width=30; Height=30
    }) -Color earlier -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 9
    $tieLater = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=10; Y=10; Width=20; Height=20
    }) -Color later -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 9

    $hit = Find-SnipAnnotation -Annotations @($low,$tieEarlier,$tieLater) `
        -ImageX 15 -ImageY 15 -Tolerance 0
    ShouldBe $hit.Id $tieLater.Id
    ShouldBe $hit.Color 'later'
}
It 'Find-SnipAnnotation copies semantic properties only for the selected winner' {
    $script:FindCopyProbeCount = 0
    try {
        $expensiveProperties = [pscustomobject]@{}
        $expensiveProperties | Add-Member -MemberType ScriptProperty -Name Probe -Value {
            $script:FindCopyProbeCount++
            'evaluated'
        }
        $loser = [pscustomobject][ordered]@{
            Id=[guid]::NewGuid().ToString(); Kind='Rectangle'
            Geometry=[pscustomobject]@{Type='Bounds';X=100;Y=100;Width=20;Height=20}
            Color='red'; StrokeWidth=1; Opacity=1; Properties=$expensiveProperties; Z=99
        }
        $winner = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
            Type='Bounds';X=0;Y=0;Width=20;Height=20
        }) -Color green -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 1

        $hit = Find-SnipAnnotation -Annotations @($loser,$winner) -ImageX 5 -ImageY 5 -Tolerance 0
        ShouldBe $hit.Id $winner.Id
        ShouldBe $script:FindCopyProbeCount 0
    } finally {
        Remove-Variable FindCopyProbeCount -Scope Script -ErrorAction SilentlyContinue
    }
}
It 'Find-SnipAnnotation hits bounds line points text and step geometry' {
    $cases = @(
        @{ Kind='Rectangle'; Geometry=[pscustomobject]@{Type='Bounds';X=2;Y=3;Width=10;Height=8}; X=5; Y=6 }
        @{ Kind='Arrow'; Geometry=[pscustomobject]@{Type='Line';Start=[pscustomobject]@{X=20;Y=10};End=[pscustomobject]@{X=30;Y=20}}; X=25; Y=15 }
        @{ Kind='Pen'; Geometry=[pscustomobject]@{Type='Points';Points=@([pscustomobject]@{X=40;Y=5},[pscustomobject]@{X=50;Y=5},[pscustomobject]@{X=55;Y=10})}; X=45; Y=6 }
        @{ Kind='Text'; Geometry=[pscustomobject]@{Type='TextBounds';X=5;Y=30;Width=20;Height=10}; X=12; Y=35 }
        @{ Kind='Steps'; Geometry=[pscustomobject]@{Type='StepBounds';X=35;Y=30;Width=12;Height=12}; X=40; Y=36 }
    )
    foreach ($case in $cases) {
        $annotation = New-SnipAnnotation -Kind $case.Kind -Geometry $case.Geometry `
            -Color white -StrokeWidth 2 -Opacity 1 -Properties @{} -Z 0
        $hit = Find-SnipAnnotation -Annotations @($annotation) `
            -ImageX $case.X -ImageY $case.Y -Tolerance 1
        ShouldBe $hit.Id $annotation.Id
    }
}
It 'Find-SnipAnnotation uses half-open bounds and segment tolerance' {
    $bounds = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=10; Y=10; Width=10; Height=10
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $line = New-SnipAnnotation -Kind Line -Geometry ([pscustomobject]@{
        Type='Line'; Start=[pscustomobject]@{X=30;Y=10}; End=[pscustomobject]@{X=40;Y=10}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 1

    ShouldBe (Find-SnipAnnotation -Annotations @($bounds) -ImageX 19 -ImageY 19 -Tolerance 0).Id $bounds.Id
    ShouldBe (Find-SnipAnnotation -Annotations @($bounds) -ImageX 20 -ImageY 15 -Tolerance 0) $null
    ShouldBe (Find-SnipAnnotation -Annotations @($line) -ImageX 35 -ImageY 12 -Tolerance 1) $null
    ShouldBe (Find-SnipAnnotation -Annotations @($line) -ImageX 35 -ImageY 12 -Tolerance 2).Id $line.Id
}
It 'Find-SnipAnnotation accepts current legacy highlight rect arrow and text records' {
    $legacy = @(
        [pscustomobject]@{Id='legacy-highlight';Type='highlight';Color='yellow';X=0;Y=0;W=10;H=10;Text=$null;FontSize=0;Z=0}
        [pscustomobject]@{Id='legacy-rect';Type='rect';Color='red';X=20;Y=0;W=10;H=10;Text=$null;FontSize=0;Z=0}
        [pscustomobject]@{Id='legacy-arrow';Type='arrow';Color='green';X=40;Y=0;W=10;H=10;Text=$null;FontSize=0;Z=0}
        [pscustomobject]@{Id='legacy-text';Type='text';Color='white';X=60;Y=0;W=20;H=10;Text='hello';FontSize=14;Z=0}
    )
    $probes = @(
        @{X=5;Y=5;Id='legacy-highlight';Kind='Highlight'}
        @{X=25;Y=5;Id='legacy-rect';Kind='Rectangle'}
        @{X=45;Y=5;Id='legacy-arrow';Kind='Arrow'}
        @{X=65;Y=5;Id='legacy-text';Kind='Text'}
    )
    foreach ($probe in $probes) {
        $hit = Find-SnipAnnotation -Annotations $legacy -ImageX $probe.X -ImageY $probe.Y -Tolerance 1
        ShouldBe $hit.Id $probe.Id
        ShouldBe $hit.Kind $probe.Kind
    }
}
It 'Find-SnipAnnotation safely misses unsupported degenerate and separated geometry' {
    $unsupported = New-SnipAnnotation -Kind Future -Geometry ([pscustomobject]@{
        Type='FutureGeometry'; Payload=@{X=1;Y=2}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 99
    $degenerate = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=5; Y=5; Width=0; Height=10
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 50
    $emptyPoints = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points'; Points=@()
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 40
    $zeroLine = New-SnipAnnotation -Kind Line -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=8;Y=8};End=[pscustomobject]@{X=8;Y=8}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 30
    $separated = New-SnipAnnotation -Kind Line -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=50;Y=50};End=[pscustomobject]@{X=60;Y=60}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0

    ShouldBe (Find-SnipAnnotation -Annotations @($unsupported,$degenerate,$emptyPoints,$zeroLine,$separated) `
        -ImageX 8 -ImageY 8 -Tolerance 0) $null
    ShouldBe (Find-SnipAnnotation -Annotations $null -ImageX 8 -ImageY 8 -Tolerance 0) $null
}
It 'Select-SnipAnnotation returns the topmost stable ID and null on a miss' {
    $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=5; Y=5; Width=10; Height=10
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    ShouldBe (Select-SnipAnnotation -Annotations @($annotation) -ImageX 7 -ImageY 7 -Tolerance 0) $annotation.Id
    ShouldBe (Select-SnipAnnotation -Annotations @($annotation) -ImageX 50 -ImageY 50 -Tolerance 0) $null
}

Describe 'Annotation movement and resize contract'
It 'Move-SnipAnnotation preserves ID while moving every geometry type' {
    $cases = @(
        @{Type='Bounds'; Geometry=[pscustomobject]@{Type='Bounds';X=10;Y=10;Width=20;Height=10}; X='X'; Before=10; After=11}
        @{Type='TextBounds'; Geometry=[pscustomobject]@{Type='TextBounds';X=10;Y=20;Width=20;Height=10}; X='X'; Before=10; After=11}
        @{Type='StepBounds'; Geometry=[pscustomobject]@{Type='StepBounds';X=20;Y=10;Width=10;Height=10}; X='X'; Before=20; After=21}
        @{Type='Line'; Geometry=[pscustomobject]@{Type='Line';Start=[pscustomobject]@{X=10;Y=10};End=[pscustomobject]@{X=20;Y=20}}; X='Start'; Before=10; After=11}
        @{Type='Points'; Geometry=[pscustomobject]@{Type='Points';Points=@([pscustomobject]@{X=10;Y=10},[pscustomobject]@{X=20;Y=20})}; X='Points'; Before=10; After=11}
    )
    foreach ($case in $cases) {
        $annotation = New-SnipAnnotation -Kind $case.Type -Geometry $case.Geometry `
            -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
        $moved = Move-SnipAnnotation -Annotation $annotation -DeltaX 1 -DeltaY 10 `
            -SourceWidth 100 -SourceHeight 100
        ShouldBe $moved.Id $annotation.Id
        ShouldBeFalse ([object]::ReferenceEquals($moved, $annotation))
        switch ($case.X) {
            'X' { ShouldBe $moved.Geometry.X $case.After; ShouldBe $annotation.Geometry.X $case.Before }
            'Start' { ShouldBe $moved.Geometry.Start.X $case.After; ShouldBe $moved.Geometry.Start.Y 20; ShouldBe $annotation.Geometry.Start.Y 10 }
            'Points' { ShouldBe $moved.Geometry.Points[0].X $case.After; ShouldBe $moved.Geometry.Points[0].Y 20; ShouldBe $annotation.Geometry.Points[0].Y 10 }
        }
    }
}
It 'Move-SnipAnnotation clamps a uniform translation without resizing geometry' {
    $bounds = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=80; Y=2; Width=20; Height=10
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $line = New-SnipAnnotation -Kind Line -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=2;Y=2};End=[pscustomobject]@{X=8;Y=8}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $points = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points';Points=@([pscustomobject]@{X=90;Y=90},[pscustomobject]@{X=99;Y=99})
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0

    $movedBounds = Move-SnipAnnotation -Annotation $bounds -DeltaX 10 -DeltaY -10 -SourceWidth 100 -SourceHeight 100
    ShouldBe $movedBounds.Geometry.X 80
    ShouldBe $movedBounds.Geometry.Y 0
    ShouldBe $movedBounds.Geometry.Width 20
    ShouldBe $movedBounds.Geometry.Height 10
    $movedLine = Move-SnipAnnotation -Annotation $line -DeltaX -10 -DeltaY -10 -SourceWidth 100 -SourceHeight 100
    ShouldBe $movedLine.Geometry.Start.X 0
    ShouldBe $movedLine.Geometry.Start.Y 0
    ShouldBe $movedLine.Geometry.End.X 6
    ShouldBe $movedLine.Geometry.End.Y 6
    $movedPoints = Move-SnipAnnotation -Annotation $points -DeltaX 10 -DeltaY 10 -SourceWidth 100 -SourceHeight 100
    ShouldBe $movedPoints.Geometry.Points[0].X 90
    ShouldBe $movedPoints.Geometry.Points[1].X 99
}
It 'Move-SnipAnnotation rejects geometry spans larger than the source without mutation' {
    $cases = @(
        (New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
            Type='Bounds';X=0;Y=0;Width=101;Height=10
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0),
        (New-SnipAnnotation -Kind Line -Geometry ([pscustomobject]@{
            Type='Line';Start=[pscustomobject]@{X=0;Y=0};End=[pscustomobject]@{X=100;Y=10}
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0),
        (New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
            Type='Points';Points=@([pscustomobject]@{X=0;Y=0},[pscustomobject]@{X=100;Y=10})
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0)
    )
    foreach ($annotation in $cases) {
        $before = Copy-SnipAnnotation -Annotation $annotation
        $threw = $false
        try {
            Move-SnipAnnotation -Annotation $annotation -DeltaX 0 -DeltaY 0 `
                -SourceWidth 100 -SourceHeight 100 | Out-Null
        } catch {
            $threw = $_.Exception -is [ArgumentException]
        }
        ShouldBeTrue $threw
        ShouldBe $annotation.Id $before.Id
        ShouldBe $annotation.Geometry.Type $before.Geometry.Type
    }
}
It 'Resize-SnipAnnotation normalizes crossed bound edges and enforces one-pixel minima' {
    $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=10; Y=10; Width=20; Height=20
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $crossed = Resize-SnipAnnotation -Annotation $annotation -Handle TopLeft `
        -DeltaX 25 -DeltaY 25 -SourceWidth 100 -SourceHeight 100
    ShouldBe $crossed.Id $annotation.Id
    ShouldBe $crossed.Geometry.X 30
    ShouldBe $crossed.Geometry.Y 30
    ShouldBe $crossed.Geometry.Width 5
    ShouldBe $crossed.Geometry.Height 5
    $minimum = Resize-SnipAnnotation -Annotation $annotation -Handle Left `
        -DeltaX 20 -DeltaY 0 -SourceWidth 100 -SourceHeight 100
    ShouldBe $minimum.Geometry.X 29
    ShouldBe $minimum.Geometry.Width 1
    ShouldBe $annotation.Geometry.X 10
    ShouldBe $annotation.Geometry.Width 20
}
It 'Resize-SnipAnnotation clamps every bounds handle to the half-open source' {
    $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds'; X=10; Y=10; Width=20; Height=15
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $cases = @(
        @{Handle='TopLeft';DX=-100;DY=-100;X=0;Y=0;W=30;H=25}
        @{Handle='Top';DX=0;DY=-100;X=10;Y=0;W=20;H=25}
        @{Handle='TopRight';DX=100;DY=-100;X=10;Y=0;W=40;H=25}
        @{Handle='Right';DX=100;DY=0;X=10;Y=10;W=40;H=15}
        @{Handle='BottomRight';DX=100;DY=100;X=10;Y=10;W=40;H=30}
        @{Handle='Bottom';DX=0;DY=100;X=10;Y=10;W=20;H=30}
        @{Handle='BottomLeft';DX=-100;DY=100;X=0;Y=10;W=30;H=30}
        @{Handle='Left';DX=-100;DY=0;X=0;Y=10;W=30;H=15}
    )
    foreach ($case in $cases) {
        $resized = Resize-SnipAnnotation -Annotation $annotation -Handle $case.Handle `
            -DeltaX $case.DX -DeltaY $case.DY -SourceWidth 50 -SourceHeight 40
        ShouldBe $resized.Geometry.X $case.X
        ShouldBe $resized.Geometry.Y $case.Y
        ShouldBe $resized.Geometry.Width $case.W
        ShouldBe $resized.Geometry.Height $case.H
        ShouldBeTrue (($resized.Geometry.X + $resized.Geometry.Width) -le 50)
        ShouldBeTrue (($resized.Geometry.Y + $resized.Geometry.Height) -le 40)
    }
}
It 'Resize-SnipAnnotation handles TextBounds and StepBounds as resizable bounds' {
    foreach ($type in 'TextBounds','StepBounds') {
        $annotation = New-SnipAnnotation -Kind $type -Geometry ([pscustomobject]@{
            Type=$type; X=10; Y=10; Width=20; Height=15
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
        $resized = Resize-SnipAnnotation -Annotation $annotation -Handle BottomRight `
            -DeltaX 5 -DeltaY 7 -SourceWidth 100 -SourceHeight 100
        ShouldBe $resized.Geometry.Type $type
        ShouldBe $resized.Geometry.Width 25
        ShouldBe $resized.Geometry.Height 22
        ShouldBe $resized.Id $annotation.Id
    }
}
It 'Resize-SnipAnnotation moves line endpoints independently and preserves ID' {
    $annotation = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=10;Y=10};End=[pscustomobject]@{X=20;Y=20}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $start = Resize-SnipAnnotation -Annotation $annotation -Handle Start `
        -DeltaX -99 -DeltaY 5 -SourceWidth 30 -SourceHeight 25
    ShouldBe $start.Id $annotation.Id
    ShouldBe $start.Geometry.Start.X 0
    ShouldBe $start.Geometry.Start.Y 15
    ShouldBe $start.Geometry.End.X 20
    ShouldBe $start.Geometry.End.Y 20
    $end = Resize-SnipAnnotation -Annotation $annotation -Handle End `
        -DeltaX 99 -DeltaY 99 -SourceWidth 30 -SourceHeight 25
    ShouldBe $end.Geometry.Start.X 10
    ShouldBe $end.Geometry.End.X 29
    ShouldBe $end.Geometry.End.Y 24
}
It 'Resize-SnipAnnotation scales point geometry from the opposite handle without aliasing' {
    $annotation = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points';Points=@(
            [pscustomobject]@{X=10;Y=10},
            [pscustomobject]@{X=15;Y=15},
            [pscustomobject]@{X=20;Y=20}
        )
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $resized = Resize-SnipAnnotation -Annotation $annotation -Handle BottomRight `
        -DeltaX 10 -DeltaY 20 -SourceWidth 100 -SourceHeight 100
    ShouldBe $resized.Id $annotation.Id
    ShouldBe $resized.Geometry.Points[0].X 10
    ShouldBe $resized.Geometry.Points[0].Y 10
    ShouldBe $resized.Geometry.Points[1].X 20
    ShouldBe $resized.Geometry.Points[1].Y 25
    ShouldBe $resized.Geometry.Points[2].X 30
    ShouldBe $resized.Geometry.Points[2].Y 40
    ShouldBe $annotation.Geometry.Points[1].X 15
    ShouldBeFalse ([object]::ReferenceEquals($resized.Geometry.Points, $annotation.Geometry.Points))
}
It 'Resize-SnipAnnotation rejects nonpositive and oversized bounds without mutation' {
    $cases = @(
        @{X=10;Y=10;W=0;H=10},
        @{X=10;Y=10;W=10;H=-1},
        @{X=10;Y=10;W=101;H=10},
        @{X=10;Y=10;W=10;H=81}
    )
    $results = [Collections.ArrayList]::new()
    foreach ($case in $cases) {
        $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
            Type='Bounds';X=$case.X;Y=$case.Y;Width=$case.W;Height=$case.H
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
        $threw = $false
        try {
            Resize-SnipAnnotation -Annotation $annotation -Handle Right -DeltaX 0 -DeltaY 0 `
                -SourceWidth 100 -SourceHeight 80 | Out-Null
        } catch {
            $threw = $_.Exception -is [ArgumentException]
        }
        [void]$results.Add($threw)
        ShouldBe $annotation.Geometry.X $case.X
        ShouldBe $annotation.Geometry.Y $case.Y
        ShouldBe $annotation.Geometry.Width $case.W
        ShouldBe $annotation.Geometry.Height $case.H
    }
    ShouldBe ($results -join ',') 'True,True,True,True'
}
It 'Resize-SnipAnnotation shifts stationary bounds axes inside source for every bounds kind' {
    $cases = @(
        @{Type='Bounds';X=-10;Y=10;W=20;H=15;Handle='Bottom';DX=0;DY=5;OutX=0;OutY=10;OutW=20;OutH=20},
        @{Type='TextBounds';X=95;Y=-5;W=20;H=15;Handle='Right';DX=-5;DY=0;OutX=80;OutY=0;OutW=15;OutH=15},
        @{Type='StepBounds';X=90;Y=75;W=20;H=10;Handle='Left';DX=-5;DY=0;OutX=75;OutY=70;OutW=25;OutH=10}
    )
    foreach ($case in $cases) {
        $annotation = New-SnipAnnotation -Kind $case.Type -Geometry ([pscustomobject]@{
            Type=$case.Type;X=$case.X;Y=$case.Y;Width=$case.W;Height=$case.H
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
        $resized = Resize-SnipAnnotation -Annotation $annotation -Handle $case.Handle `
            -DeltaX $case.DX -DeltaY $case.DY -SourceWidth 100 -SourceHeight 80
        ShouldBe $resized.Id $annotation.Id
        ShouldBe $resized.Geometry.X $case.OutX
        ShouldBe $resized.Geometry.Y $case.OutY
        ShouldBe $resized.Geometry.Width $case.OutW
        ShouldBe $resized.Geometry.Height $case.OutH
        ShouldBeTrue ($resized.Geometry.X -ge 0 -and $resized.Geometry.Y -ge 0)
        ShouldBeTrue (($resized.Geometry.X + $resized.Geometry.Width) -le 100)
        ShouldBeTrue (($resized.Geometry.Y + $resized.Geometry.Height) -le 80)
        ShouldBe $annotation.Geometry.X $case.X
        ShouldBe $annotation.Geometry.Y $case.Y
    }
}
It 'Resize-SnipAnnotation normalizes before a bounds handle crosses its opposite edge' {
    $annotation = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds';X=-10;Y=10;Width=20;Height=15
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $resized = Resize-SnipAnnotation -Annotation $annotation -Handle Left `
        -DeltaX 30 -DeltaY 0 -SourceWidth 100 -SourceHeight 80
    ShouldBe $resized.Id $annotation.Id
    ShouldBe $resized.Geometry.X 20
    ShouldBe $resized.Geometry.Y 10
    ShouldBe $resized.Geometry.Width 10
    ShouldBe $resized.Geometry.Height 15
    ShouldBe $annotation.Geometry.X -10
    ShouldBe $annotation.Geometry.Width 20
}
It 'Resize-SnipAnnotation shifts a whole line inside before moving one endpoint' {
    $annotation = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=90;Y=-10};End=[pscustomobject]@{X=120;Y=20}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $resized = Resize-SnipAnnotation -Annotation $annotation -Handle Start `
        -DeltaX -5 -DeltaY 5 -SourceWidth 100 -SourceHeight 50
    ShouldBe $resized.Id $annotation.Id
    ShouldBe $resized.Geometry.Start.X 64
    ShouldBe $resized.Geometry.Start.Y 5
    ShouldBe $resized.Geometry.End.X 99
    ShouldBe $resized.Geometry.End.Y 30
    ShouldBe $annotation.Geometry.Start.X 90
    ShouldBe $annotation.Geometry.End.X 120
}
It 'Resize-SnipAnnotation rejects degenerate and oversized line spans but permits a vertical line' {
    $invalid = @(
        @{Start=[pscustomobject]@{X=10;Y=10};End=[pscustomobject]@{X=10;Y=10}},
        @{Start=[pscustomobject]@{X=0;Y=10};End=[pscustomobject]@{X=100;Y=10}},
        @{Start=[pscustomobject]@{X=10;Y=0};End=[pscustomobject]@{X=10;Y=50}}
    )
    $results = [Collections.ArrayList]::new()
    foreach ($geometry in $invalid) {
        $annotation = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
            Type='Line';Start=$geometry.Start;End=$geometry.End
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
        $threw = $false
        try {
            Resize-SnipAnnotation -Annotation $annotation -Handle Start -DeltaX 0 -DeltaY 0 `
                -SourceWidth 100 -SourceHeight 50 | Out-Null
        } catch {
            $threw = $_.Exception -is [ArgumentException]
        }
        [void]$results.Add($threw)
        ShouldBe $annotation.Geometry.Start.X $geometry.Start.X
        ShouldBe $annotation.Geometry.Start.Y $geometry.Start.Y
        ShouldBe $annotation.Geometry.End.X $geometry.End.X
        ShouldBe $annotation.Geometry.End.Y $geometry.End.Y
    }
    ShouldBe ($results -join ',') 'True,True,True'

    $vertical = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=10;Y=-5};End=[pscustomobject]@{X=10;Y=20}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $resized = Resize-SnipAnnotation -Annotation $vertical -Handle End `
        -DeltaX 0 -DeltaY 5 -SourceWidth 100 -SourceHeight 50
    ShouldBe $resized.Geometry.Start.X 10
    ShouldBe $resized.Geometry.Start.Y 0
    ShouldBe $resized.Geometry.End.X 10
    ShouldBe $resized.Geometry.End.Y 30
}
It 'Resize-SnipAnnotation shifts untouched point axes before scaling from a handle' {
    $verticalOutside = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points';Points=@(
            [pscustomobject]@{X=10;Y=-5},[pscustomobject]@{X=15;Y=5},[pscustomobject]@{X=20;Y=15}
        )
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $horizontalResize = Resize-SnipAnnotation -Annotation $verticalOutside -Handle Right `
        -DeltaX 10 -DeltaY 0 -SourceWidth 50 -SourceHeight 30
    ShouldBe $horizontalResize.Id $verticalOutside.Id
    ShouldBe (($horizontalResize.Geometry.Points | ForEach-Object X) -join ',') '10,20,30'
    ShouldBe (($horizontalResize.Geometry.Points | ForEach-Object Y) -join ',') '0,10,20'
    ShouldBe (($verticalOutside.Geometry.Points | ForEach-Object Y) -join ',') '-5,5,15'

    $horizontalOutside = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points';Points=@(
            [pscustomobject]@{X=45;Y=5},[pscustomobject]@{X=55;Y=10},[pscustomobject]@{X=65;Y=15}
        )
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $verticalResize = Resize-SnipAnnotation -Annotation $horizontalOutside -Handle Bottom `
        -DeltaX 0 -DeltaY 5 -SourceWidth 50 -SourceHeight 30
    ShouldBe $verticalResize.Id $horizontalOutside.Id
    ShouldBe (($verticalResize.Geometry.Points | ForEach-Object X) -join ',') '29,39,49'
    ShouldBe (($verticalResize.Geometry.Points | ForEach-Object Y) -join ',') '5,13,20'
    ShouldBe (($horizontalOutside.Geometry.Points | ForEach-Object X) -join ',') '45,55,65'
}
It 'Resize-SnipAnnotation rejects empty degenerate and oversized point spans without mutation' {
    $cases = @(
        @(),
        @([pscustomobject]@{X=10;Y=10},[pscustomobject]@{X=10;Y=10}),
        @([pscustomobject]@{X=0;Y=10},[pscustomobject]@{X=50;Y=10}),
        @([pscustomobject]@{X=10;Y=0},[pscustomobject]@{X=10;Y=30})
    )
    $results = [Collections.ArrayList]::new()
    foreach ($points in $cases) {
        $annotation = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
            Type='Points';Points=$points
        }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
        $before = @(($annotation.Geometry.Points | ForEach-Object { "$($_.X),$($_.Y)" })) -join ';'
        $threw = $false
        try {
            Resize-SnipAnnotation -Annotation $annotation -Handle Right -DeltaX 1 -DeltaY 0 `
                -SourceWidth 50 -SourceHeight 30 | Out-Null
        } catch {
            $threw = $_.Exception -is [ArgumentException]
        }
        [void]$results.Add($threw)
        $after = @(($annotation.Geometry.Points | ForEach-Object { "$($_.X),$($_.Y)" })) -join ';'
        ShouldBe $after $before
    }
    ShouldBe ($results -join ',') 'True,True,True,True'
}
It 'Resize-SnipAnnotation rejects handle deltas that collapse line or point extent' {
    $line = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=10;Y=10};End=[pscustomobject]@{X=20;Y=20}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $lineThrew = $false
    try {
        Resize-SnipAnnotation -Annotation $line -Handle Start -DeltaX 10 -DeltaY 10 `
            -SourceWidth 100 -SourceHeight 100 | Out-Null
    } catch {
        $lineThrew = $_.Exception -is [ArgumentException]
    }
    ShouldBe $line.Geometry.Start.X 10
    ShouldBe $line.Geometry.Start.Y 10
    ShouldBe $line.Geometry.End.X 20
    ShouldBe $line.Geometry.End.Y 20

    $points = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points';Points=@([pscustomobject]@{X=10;Y=10},[pscustomobject]@{X=20;Y=20})
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $pointsThrew = $false
    try {
        Resize-SnipAnnotation -Annotation $points -Handle BottomRight -DeltaX -10 -DeltaY -10 `
            -SourceWidth 100 -SourceHeight 100 | Out-Null
    } catch {
        $pointsThrew = $_.Exception -is [ArgumentException]
    }
    ShouldBe (($points.Geometry.Points | ForEach-Object { "$($_.X),$($_.Y)" }) -join ';') '10,10;20,20'
    ShouldBe "$lineThrew,$pointsThrew" 'True,True'
}
It 'Resize-SnipAnnotation clamps extreme integer deltas for every geometry family' {
    $bounds = New-SnipAnnotation -Kind Rectangle -Geometry ([pscustomobject]@{
        Type='Bounds';X=10;Y=10;Width=20;Height=20
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $maximumBounds = Resize-SnipAnnotation -Annotation $bounds -Handle BottomRight `
        -DeltaX ([int]::MaxValue) -DeltaY ([int]::MaxValue) -SourceWidth 100 -SourceHeight 100
    ShouldBe "$($maximumBounds.Geometry.X),$($maximumBounds.Geometry.Y),$($maximumBounds.Geometry.Width),$($maximumBounds.Geometry.Height)" '10,10,90,90'
    $minimumBounds = Resize-SnipAnnotation -Annotation $bounds -Handle TopLeft `
        -DeltaX ([int]::MinValue) -DeltaY ([int]::MinValue) -SourceWidth 100 -SourceHeight 100
    ShouldBe "$($minimumBounds.Geometry.X),$($minimumBounds.Geometry.Y),$($minimumBounds.Geometry.Width),$($minimumBounds.Geometry.Height)" '0,0,30,30'

    $line = New-SnipAnnotation -Kind Arrow -Geometry ([pscustomobject]@{
        Type='Line';Start=[pscustomobject]@{X=10;Y=10};End=[pscustomobject]@{X=20;Y=20}
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $maximumLine = Resize-SnipAnnotation -Annotation $line -Handle End `
        -DeltaX ([int]::MaxValue) -DeltaY ([int]::MaxValue) -SourceWidth 100 -SourceHeight 100
    ShouldBe "$($maximumLine.Geometry.Start.X),$($maximumLine.Geometry.Start.Y)" '10,10'
    ShouldBe "$($maximumLine.Geometry.End.X),$($maximumLine.Geometry.End.Y)" '99,99'

    $points = New-SnipAnnotation -Kind Pen -Geometry ([pscustomobject]@{
        Type='Points';Points=@(
            [pscustomobject]@{X=10;Y=10},[pscustomobject]@{X=15;Y=15},[pscustomobject]@{X=20;Y=20}
        )
    }) -Color white -StrokeWidth 1 -Opacity 1 -Properties @{} -Z 0
    $maximumPoints = Resize-SnipAnnotation -Annotation $points -Handle Right `
        -DeltaX ([int]::MaxValue) -DeltaY 0 -SourceWidth 100 -SourceHeight 100
    ShouldBe (($maximumPoints.Geometry.Points | ForEach-Object X) -join ',') '10,55,99'
    ShouldBe (($maximumPoints.Geometry.Points | ForEach-Object Y) -join ',') '10,15,20'
    ShouldBe "$($bounds.Geometry.Width),$($line.Geometry.End.X),$($points.Geometry.Points[2].X)" '20,20,20'
}

Describe 'Non-destructive crop contract'
It 'Get-SnipCropRectangle normalizes and clamps a Free draft at every source edge' {
    $cases = @(
        @{Candidate=[pscustomobject]@{X=-10;Y=-20;Width=50;Height=60};X=0;Y=0;W=40;H=40}
        @{Candidate=[pscustomobject]@{X=90;Y=70;Width=30;Height=20};X=90;Y=70;W=10;H=10}
        @{Candidate=[pscustomobject]@{X=90;Y=70;Width=-100;Height=-90};X=0;Y=0;W=90;H=70}
    )
    foreach ($case in $cases) {
        $rect = Get-SnipCropRectangle -Candidate $case.Candidate -SourceWidth 100 -SourceHeight 80 -Preset Free
        ShouldBe $rect.X $case.X
        ShouldBe $rect.Y $case.Y
        ShouldBe $rect.Width $case.W
        ShouldBe $rect.Height $case.H
    }
    ShouldBe (Get-SnipCropRectangle -Candidate ([pscustomobject]@{X=110;Y=90;Width=5;Height=5}) `
        -SourceWidth 100 -SourceHeight 80 -Preset Free) $null
}
It 'Get-SnipCropRectangle uses the original source aspect in landscape and portrait' {
    $square = [pscustomobject]@{X=0;Y=0;Width=80;Height=80}
    $landscape = Get-SnipCropRectangle -Candidate $square -SourceWidth 160 -SourceHeight 90 -Preset Original
    ShouldBe $landscape.X 0; ShouldBe $landscape.Y 18
    ShouldBe $landscape.Width 80; ShouldBe $landscape.Height 45
    $portrait = Get-SnipCropRectangle -Candidate $square -SourceWidth 90 -SourceHeight 160 -Preset Original
    ShouldBe $portrait.X 18; ShouldBe $portrait.Y 0
    ShouldBe $portrait.Width 45; ShouldBe $portrait.Height 80
}
It 'Get-SnipCropRectangle keeps full-source Original exact in both orientations' {
    $landscape = Get-SnipCropRectangle -Candidate $null -SourceWidth 160 -SourceHeight 90 -Preset Original
    ShouldBe $landscape.X 0; ShouldBe $landscape.Y 0
    ShouldBe $landscape.Width 160; ShouldBe $landscape.Height 90
    $portrait = Get-SnipCropRectangle -Candidate $null -SourceWidth 90 -SourceHeight 160 -Preset Original
    ShouldBe $portrait.X 0; ShouldBe $portrait.Y 0
    ShouldBe $portrait.Width 90; ShouldBe $portrait.Height 160
}
It 'Get-SnipCropRectangle clamps before applying an aspect preset' {
    $candidate = [pscustomobject]@{X=-10;Y=10;Width=100;Height=60}
    $rect = Get-SnipCropRectangle -Candidate $candidate -SourceWidth 100 -SourceHeight 80 -Preset '16:9'
    ShouldBe $rect.X 0; ShouldBe $rect.Y 15
    ShouldBe $rect.Width 90; ShouldBe $rect.Height 51
    ShouldBe $candidate.X -10; ShouldBe $candidate.Width 100
}
It 'Get-SnipCropRectangle centers odd-sized presets with away-from-zero rounding' {
    $candidate = [pscustomobject]@{X=3;Y=5;Width=101;Height=77}
    $rect = Get-SnipCropRectangle -Candidate $candidate -SourceWidth 200 -SourceHeight 150 -Preset '4:3'
    ShouldBe $rect.X 3; ShouldBe $rect.Y 6
    ShouldBe $rect.Width 101; ShouldBe $rect.Height 76
}
It 'Get-SnipCropRectangle rounds fractional candidates once after normalization' {
    $candidate = [pscustomobject]@{X=10.5;Y=20.5;Width=80.5;Height=60.5}
    $rect = Get-SnipCropRectangle -Candidate $candidate -SourceWidth 200 -SourceHeight 150 -Preset Free
    ShouldBe $rect.X 11; ShouldBe $rect.Y 21
    ShouldBe $rect.Width 81; ShouldBe $rect.Height 61
    ShouldBe $candidate.X 10.5; ShouldBe $candidate.Width 80.5
}
It 'Get-SnipCropRectangle inscribes 1 to 1 4 to 3 and 16 to 9 inside a draft' {
    $draft = [pscustomobject]@{X=10;Y=20;Width=80;Height=60}
    $square = Get-SnipCropRectangle -Candidate $draft -SourceWidth 120 -SourceHeight 100 -Preset '1:1'
    ShouldBe $square.X 20; ShouldBe $square.Y 20; ShouldBe $square.Width 60; ShouldBe $square.Height 60
    $fourThree = Get-SnipCropRectangle -Candidate $draft -SourceWidth 120 -SourceHeight 100 -Preset '4:3'
    ShouldBe $fourThree.X 10; ShouldBe $fourThree.Y 20; ShouldBe $fourThree.Width 80; ShouldBe $fourThree.Height 60
    $wide = Get-SnipCropRectangle -Candidate $draft -SourceWidth 120 -SourceHeight 100 -Preset '16:9'
    ShouldBe $wide.X 10; ShouldBe $wide.Y 28; ShouldBe $wide.Width 80; ShouldBe $wide.Height 45
}
It 'Get-SnipCropRectangle follows portrait orientation for ratio presets' {
    $draft = [pscustomobject]@{X=5;Y=10;Width=90;Height=160}
    $fourThree = Get-SnipCropRectangle -Candidate $draft -SourceWidth 100 -SourceHeight 180 -Preset '4:3'
    ShouldBe $fourThree.X 5; ShouldBe $fourThree.Y 30
    ShouldBe $fourThree.Width 90; ShouldBe $fourThree.Height 120
    $sixteenNine = Get-SnipCropRectangle -Candidate $draft -SourceWidth 100 -SourceHeight 180 -Preset '16:9'
    ShouldBe $sixteenNine.X 5; ShouldBe $sixteenNine.Y 10
    ShouldBe $sixteenNine.Width 90; ShouldBe $sixteenNine.Height 160
    $fromSource = Get-SnipCropRectangle -Candidate $null -SourceWidth 90 -SourceHeight 160 -Preset '4:3'
    ShouldBe $fromSource.X 0; ShouldBe $fromSource.Y 20
    ShouldBe $fromSource.Width 90; ShouldBe $fromSource.Height 120
}
It 'Set-SnipCrop returns a fresh applied rectangle and null on Reset' {
    $candidate = [pscustomobject]@{X=10;Y=20;Width=80;Height=60}
    $applied = Set-SnipCrop -Action Apply -Candidate $candidate `
        -SourceWidth 120 -SourceHeight 100 -Preset Free
    ShouldBe (($applied.PSObject.Properties.Name) -join ',') 'X,Y,Width,Height'
    ShouldBeFalse ([object]::ReferenceEquals($applied, $candidate))
    ShouldBe $applied.X 10; ShouldBe $applied.Y 20
    ShouldBe $applied.Width 80; ShouldBe $applied.Height 60
    ShouldBe (Set-SnipCrop -Action Reset -Candidate $candidate `
        -SourceWidth 120 -SourceHeight 100 -Preset '16:9') $null
}
It 'crop math rejects malformed sources and degenerate candidates without mutation' {
    $candidate = [pscustomobject]@{X=10;Y=20;Width=0;Height=60}
    ShouldBe (Get-SnipCropRectangle -Candidate $candidate -SourceWidth 100 -SourceHeight 80 -Preset Free) $null
    ShouldBe $candidate.X 10; ShouldBe $candidate.Width 0

    $sourceThrew = $false
    try {
        Get-SnipCropRectangle -Candidate $null -SourceWidth 0 -SourceHeight 80 -Preset Free | Out-Null
    } catch {
        $sourceThrew = $_.Exception -is [ArgumentOutOfRangeException]
    }
    ShouldBeTrue $sourceThrew
    $shapeThrew = $false
    try {
        Get-SnipCropRectangle -Candidate ([pscustomobject]@{X=0;Y=0;Width=10}) `
            -SourceWidth 100 -SourceHeight 80 -Preset Free | Out-Null
    } catch {
        $shapeThrew = $_.Exception -is [ArgumentException]
    }
    ShouldBeTrue $shapeThrew
}

Describe 'Task 7 canvas-only selection key precedence'
It 'does not route selection movement or Delete outside canvas focus' {
    $state = @{
        PopupOpen=$false; EditingText=$false; EditingProperty=$false
        Draft=$null; SelectionId='selection-1'; ActiveTool='Select'
    }
    foreach ($role in 'Button','Chrome','Window') {
        foreach ($keyName in 'Left','Right','Up','Down','Delete') {
            ShouldBe (Resolve-PreviewKeyCommand -FocusedRole $role -EditorState $state `
                -Key $keyName -Modifiers @()) $null
        }
    }
}
It 'clears selection on Escape across non-editor focus roles before tool or window handling' {
    foreach ($activeTool in 'Select','Pen') {
        $state = @{
            PopupOpen=$false; EditingText=$false; EditingProperty=$false
            Draft=$null; SelectionId='selection-1'; ActiveTool=$activeTool
        }
        foreach ($role in 'Canvas','Button','Chrome','Window') {
            ShouldBe (Resolve-PreviewKeyCommand -FocusedRole $role -EditorState $state `
                -Key Escape -Modifiers @()) 'ClearSelection'
        }
    }
}
It 'keeps popup editor and draft Escape ownership ahead of selection clearing' {
    $state = @{
        PopupOpen=$true; EditingText=$false; EditingProperty=$false
        Draft=$null; SelectionId='selection-1'; ActiveTool='Pen'
    }
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Popup -EditorState $state `
        -Key Escape -Modifiers @()) 'ClosePopup'
    $state.PopupOpen = $false
    $state.EditingText = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state `
        -Key Escape -Modifiers @()) 'CancelTextEdit'
    $state.EditingText = $false
    $state.EditingProperty = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole PropertyEditor -EditorState $state `
        -Key Escape -Modifiers @()) 'CancelPropertyEdit'
    $state.EditingProperty = $false
    $state.Draft = [pscustomobject]@{ Kind='Crop' }
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Window -EditorState $state `
        -Key Escape -Modifiers @()) 'CancelDraft'
}
It 'activates focused buttons only for unmodified Space or Enter' {
    $state = @{
        PopupOpen=$false; EditingText=$false; EditingProperty=$false
        Draft=$null; SelectionId=$null; ActiveTool='Select'
    }
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $state `
        -Key Space -Modifiers @()) 'ActivateFocusedButton'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $state `
        -Key Enter -Modifiers @()) 'ActivateFocusedButton'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $state `
        -Key Enter -Modifiers Ctrl) 'CopyAndClose'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $state `
        -Key Space -Modifiers Shift) $null
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $state `
        -Key Enter -Modifiers Alt) $null
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Button -EditorState $state `
        -Key Space -Modifiers Ctrl) $null
}
It 'routes Undo and Redo only after editor and draft ownership' {
    $state = @{
        PopupOpen=$false; EditingText=$false; EditingProperty=$false
        Draft=$null; SelectionId=$null; ActiveTool='Select'
    }
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state `
        -Key Z -Modifiers Ctrl) 'Undo'
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state `
        -Key Z -Modifiers @('Ctrl','Shift')) 'Redo'
    $state.EditingText = $true
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole TextEditor -EditorState $state `
        -Key Z -Modifiers Ctrl) 'TextInput'
    $state.EditingText = $false
    $state.Draft = [pscustomobject]@{ Kind='Crop' }
    ShouldBe (Resolve-PreviewKeyCommand -FocusedRole Canvas -EditorState $state `
        -Key Z -Modifiers Ctrl) $null
}

Describe 'Get-SnipArrowGeometry'
It 'sizes the head from the stroke width with a 10 pixel floor' {
    $thin = Get-SnipArrowGeometry -StartX 0 -StartY 0 -EndX 200 -EndY 0 -StrokeWidth 1
    ShouldBe $thin.HeadLength 10.0
    ShouldBe $thin.HeadHalfWidth 5.0
    $thick = Get-SnipArrowGeometry -StartX 0 -StartY 0 -EndX 200 -EndY 0 -StrokeWidth 6
    ShouldBe $thick.HeadLength 24.0
    ShouldBe $thick.HeadHalfWidth 12.0
}
It 'places the tip at the end and the base square across the direction' {
    $g = Get-SnipArrowGeometry -StartX 100 -StartY 100 -EndX 300 -EndY 100 -StrokeWidth 6
    ShouldBe $g.TipX 300.0
    ShouldBe $g.TipY 100.0
    ShouldBe $g.LeftX 276.0
    ShouldBe $g.LeftY 112.0
    ShouldBe $g.RightX 276.0
    ShouldBe $g.RightY 88.0
    # The shaft stops inside the head so the stroke never pokes through the tip.
    ShouldBe $g.ShaftEndX 282.0
    ShouldBeTrue ($g.ShaftEndX -lt $g.TipX)
}
It 'keeps the head perpendicular on a diagonal arrow' {
    $g = Get-SnipArrowGeometry -StartX 0 -StartY 0 -EndX 300 -EndY 400 -StrokeWidth 5
    ShouldBe ([math]::Round($g.Length,6)) 500.0
    $spanX = $g.LeftX - $g.RightX
    $spanY = $g.LeftY - $g.RightY
    # Base span is perpendicular to the shaft and 2 x half-width long.
    ShouldBe ([math]::Round(($spanX * 0.6 + $spanY * 0.8), 6)) 0.0
    ShouldBe ([math]::Round([math]::Sqrt($spanX*$spanX + $spanY*$spanY),6)) `
        ([math]::Round(2 * $g.HeadHalfWidth, 6))
}
It 'clamps the head to the arrow length and degrades safely at zero length' {
    $short = Get-SnipArrowGeometry -StartX 0 -StartY 0 -EndX 6 -EndY 0 -StrokeWidth 8
    ShouldBe $short.HeadLength 6.0
    ShouldBeTrue ($short.ShaftEndX -ge 0)
    $zero = Get-SnipArrowGeometry -StartX 40 -StartY 40 -EndX 40 -EndY 40 -StrokeWidth 4
    ShouldBe $zero.Length 0.0
    ShouldBe $zero.TipX 40.0
    ShouldBe $zero.ShaftEndY 40.0
}

Describe 'Get-SnipStepBadgeGeometry'
It 'centres a square badge and holds the 28 px floor at the default width' {
    $badge = Get-SnipStepBadgeGeometry -CenterX 100 -CenterY 60 -StrokeWidth 3
    ShouldBe $badge.Diameter 28
    ShouldBe $badge.Width 28
    ShouldBe $badge.Height 28
    ShouldBe $badge.X 86
    ShouldBe $badge.Y 46
}
It 'grows the badge as 3x stroke width plus 18 once past the floor' {
    $badge = Get-SnipStepBadgeGeometry -CenterX 0 -CenterY 0 -StrokeWidth 10
    ShouldBe $badge.Diameter 48
    ShouldBe $badge.X (-24)
    ShouldBe $badge.Y (-24)
}
It 'keeps the digit legible by scaling the font with the badge' {
    ShouldBe (Get-SnipStepBadgeGeometry -CenterX 0 -CenterY 0 -StrokeWidth 3).FontSize 14
    ShouldBe (Get-SnipStepBadgeGeometry -CenterX 0 -CenterY 0 -StrokeWidth 10).FontSize 24
}

Describe 'Get-SnipStepNumbering'
It 'numbers Step records by creation order and ignores every other kind' {
    $records = @(
        [pscustomobject]@{ Id='a'; Kind='Rectangle' }
        [pscustomobject]@{ Id='b'; Kind='Step' }
        [pscustomobject]@{ Id='c'; Kind='Arrow' }
        [pscustomobject]@{ Id='d'; Kind='Step' }
        [pscustomobject]@{ Id='e'; Kind='Step' })
    $numbering = @(Get-SnipStepNumbering -Annotations $records)
    ShouldBe $numbering.Count 3
    ShouldBe (($numbering | ForEach-Object { "$($_.Id)=$($_.Number)" }) -join ',') 'b=1,d=2,e=3'
}
It 'renumbers the survivors when a middle Step is deleted' {
    $records = @(
        [pscustomobject]@{ Id='b'; Kind='Step' }
        [pscustomobject]@{ Id='d'; Kind='Step' }
        [pscustomobject]@{ Id='e'; Kind='Step' })
    $remaining = @($records | Where-Object Id -ne 'd')
    $numbering = @(Get-SnipStepNumbering -Annotations $remaining)
    ShouldBe (($numbering | ForEach-Object { "$($_.Id)=$($_.Number)" }) -join ',') 'b=1,e=2'
    # Restoring the record (the undo case) restores its number too.
    $restored = @(Get-SnipStepNumbering -Annotations $records)
    ShouldBe (($restored | ForEach-Object { "$($_.Id)=$($_.Number)" }) -join ',') 'b=1,d=2,e=3'
}
It 'returns an empty projection for no annotations' {
    ShouldBe (@(Get-SnipStepNumbering -Annotations $null)).Count 0
    ShouldBe (@(Get-SnipStepNumbering -Annotations @())).Count 0
}

Describe 'Add-SnipFreehandPoint'
It 'seeds an empty path with the first sample' {
    $path = @(Add-SnipFreehandPoint -Points @() -X 10.4 -Y 20.6)
    ShouldBe $path.Count 1
    ShouldBe $path[0].X 10
    ShouldBe $path[0].Y 21
}
It 'drops a sample that lands inside the minimum distance' {
    $path = @(Add-SnipFreehandPoint -Points @([pscustomobject]@{X=10;Y=10}) `
        -X 11 -Y 10 -MinimumDistance 2.0)
    ShouldBe $path.Count 1
}
It 'keeps a sample exactly on the minimum distance' {
    $path = @(Add-SnipFreehandPoint -Points @([pscustomobject]@{X=10;Y=10}) `
        -X 12 -Y 10 -MinimumDistance 2.0)
    ShouldBe $path.Count 2
    ShouldBe $path[1].X 12
}
It 'measures against the last point only, so a path can double back' {
    $path = @([pscustomobject]@{X=0;Y=0}, [pscustomobject]@{X=20;Y=0})
    $extended = @(Add-SnipFreehandPoint -Points $path -X 1 -Y 0 -MinimumDistance 2.0)
    ShouldBe $extended.Count 3
    ShouldBe $extended[2].X 1
}
It 'does not mutate the path it was handed' {
    $path = @([pscustomobject]@{X=0;Y=0})
    $null = Add-SnipFreehandPoint -Points $path -X 50 -Y 50
    ShouldBe $path.Count 1
}

Describe 'Get-SnipObscureMetrics'
It 'holds a 6 px mosaic floor and scales the block as 3x strength' {
    ShouldBe (Get-SnipObscureMetrics -Mode Pixelate -StrokeWidth 1).BlockSize 6
    ShouldBe (Get-SnipObscureMetrics -Mode Pixelate -StrokeWidth 3).BlockSize 9
    ShouldBe (Get-SnipObscureMetrics -Mode Pixelate -StrokeWidth 12).BlockSize 36
}
It 'scales the blur radius as 2x strength with a floor of 2' {
    ShouldBe (Get-SnipObscureMetrics -Mode Blur -StrokeWidth 0).BlurRadius 2
    ShouldBe (Get-SnipObscureMetrics -Mode Blur -StrokeWidth 3).BlurRadius 6
    ShouldBe (Get-SnipObscureMetrics -Mode Blur -StrokeWidth 8).BlurRadius 16
}
It 'reports the mode it was asked about' {
    ShouldBe (Get-SnipObscureMetrics -Mode Pixelate -StrokeWidth 3).Mode 'Pixelate'
    ShouldBe (Get-SnipObscureMetrics -StrokeWidth 3).Mode 'Blur'
}

Describe 'Get-SnipBlockAverage'
It 'averages the channels of the pixels one mosaic block covers' {
    $average = Get-SnipBlockAverage -Pixels @(
        [pscustomobject]@{ R=0; G=0; B=0 }
        [pscustomobject]@{ R=100; G=200; B=40 }
        [pscustomobject]@{ R=200; G=100; B=80 })
    ShouldBe $average.R 100
    ShouldBe $average.G 100
    ShouldBe $average.B 40
    ShouldBe $average.Count 3
}
It 'rounds away from zero rather than to even' {
    $average = Get-SnipBlockAverage -Pixels @(
        [pscustomobject]@{ R=1; G=1; B=1 }
        [pscustomobject]@{ R=2; G=2; B=2 })
    ShouldBe $average.R 2
}
It 'has no answer for an empty block' {
    ShouldBe (Get-SnipBlockAverage -Pixels @()) $null
}

Describe 'Process DPI awareness reporting'
It 'names each awareness level the enum can report' {
    ShouldBe (Get-SnipDpiAwarenessName -Value 0) 'Unaware'
    ShouldBe (Get-SnipDpiAwarenessName -Value 1) 'System'
    ShouldBe (Get-SnipDpiAwarenessName -Value 2) 'PerMonitor'
}
It 'refuses to guess at an unrecognised awareness value' {
    ShouldBe (Get-SnipDpiAwarenessName -Value 7) 'Unknown'
    ShouldBe (Get-SnipDpiAwarenessName -Value -1) 'Unknown'
}
It 'exposes the awareness it resolved at load as script state' {
    foreach ($name in 'SnipProcessDpiAwareness','SnipThreadDpiAwareness',
        'SnipDpiPerMonitorAware','SnipDpiAwarenessGranted') {
        ShouldBeTrue ($null -ne (Get-Variable -Name $name -Scope Script -ErrorAction Ignore))
    }
    # A -CoreOnly load never issues the request, so the fallback path is what a
    # portable run reports.
    ShouldBeFalse $script:SnipDpiPerMonitorAware
}

Describe 'Resolve-SnipMonitorDpi'
It 'keeps the true per-monitor DPI when the process is per-monitor aware' {
    $resolved = Resolve-SnipMonitorDpi -RawDpiX 144 -RawDpiY 144 -PerMonitorAware $true
    ShouldBe $resolved.DpiX 144
    ShouldBe $resolved.DpiY 144
    ShouldBeFalse $resolved.Normalized
}
It 'normalises to 96 when the process is not per-monitor aware' {
    $resolved = Resolve-SnipMonitorDpi -RawDpiX 144 -RawDpiY 168 -PerMonitorAware $false
    ShouldBe $resolved.DpiX 96
    ShouldBe $resolved.DpiY 96
    ShouldBeTrue $resolved.Normalized
}
It 'defaults to the non-aware fallback when awareness is not stated' {
    ShouldBe (Resolve-SnipMonitorDpi -RawDpiX 120 -RawDpiY 120).DpiX 96
}
It 'normalises a nonsensical DPI even when per-monitor aware' {
    ShouldBe (Resolve-SnipMonitorDpi -RawDpiX 0 -RawDpiY 96 -PerMonitorAware $true).DpiX 96
    ShouldBe (Resolve-SnipMonitorDpi -RawDpiX -96 -RawDpiY 96 -PerMonitorAware $true).DpiY 96
    ShouldBeTrue (Resolve-SnipMonitorDpi -RawDpiX ([double]::NaN) -RawDpiY 96 `
        -PerMonitorAware $true).Normalized
}

Describe 'System-aware monitor topology fallback'
# The regression this guards: under system awareness Screen.AllScreens reports
# bounds already scaled into the primary's DPI space, while GetDpiForMonitor
# keeps reporting each panel's true DPI. Pairing the two gave the 150% monitor a
# 1.5 scale on bounds that were never physical, so its DIP size came out at two
# thirds of the window WPF actually placed there.
$script:VirtualisedScreenBounds = @(
    # Primary 1920x1080 at 100%, plus a 3840x2160 panel running at 150% that
    # Windows hands back as 2560x1440 because the primary is the reference.
    [pscustomobject]@{ Id='\\.\DISPLAY1'; X=0; Y=0; Width=1920; Height=1080
        TrueDpi=96; IsPrimary=$true },
    [pscustomobject]@{ Id='\\.\DISPLAY2'; X=1920; Y=0; Width=2560; Height=1440
        TrueDpi=144; IsPrimary=$false }
)
function New-VirtualisedDescriptors {
    param([bool]$PerMonitorAware)
    foreach ($screen in $script:VirtualisedScreenBounds) {
        $resolved = Resolve-SnipMonitorDpi -RawDpiX $screen.TrueDpi -RawDpiY $screen.TrueDpi `
            -PerMonitorAware $PerMonitorAware
        [pscustomobject]@{
            Id = $screen.Id; X = $screen.X; Y = $screen.Y
            Width = $screen.Width; Height = $screen.Height
            DpiX = $resolved.DpiX; DpiY = $resolved.DpiY
            IsPrimary = $screen.IsPrimary
        }
    }
}
It 'reports 96 DPI for every monitor when the process is system-aware' {
    $descriptors = @(New-VirtualisedDescriptors -PerMonitorAware $false)
    ShouldBe $descriptors.Count 2
    foreach ($descriptor in $descriptors) {
        ShouldBe $descriptor.DpiX 96
        ShouldBe $descriptor.DpiY 96
    }
}
It 'produces identity-scaled layouts that match the virtualised bounds' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors `
        @(New-VirtualisedDescriptors -PerMonitorAware $false))
    ShouldBe $layouts[1].ScaleX 1
    ShouldBe $layouts[1].ScaleY 1
    # The overlay is sized in DIPs and positioned in physical pixels; under the
    # fallback those have to agree, or the overlay covers the wrong region.
    ShouldBe $layouts[1].DipWidth 2560
    ShouldBe $layouts[1].DipHeight 1440
    ShouldBe $layouts[1].DipX 1920
    ShouldBe ($layouts[1].DipX + $layouts[1].DipWidth) $layouts[1].PhysicalRight
}
It 'still mixes the spaces if the true DPI is paired with virtualised bounds' {
    # Documents exactly what the bug looked like, so a regression is obvious.
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors `
        @(New-VirtualisedDescriptors -PerMonitorAware $true))
    ShouldBe $layouts[1].ScaleX 1.5
    ShouldBe $layouts[1].DipWidth (2560 / 1.5)
    ShouldBeFalse ($layouts[1].DipX + $layouts[1].DipWidth -eq $layouts[1].PhysicalRight)
}
It 'keeps true DPI and real bounds together when per-monitor aware' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{ Id='\\.\DISPLAY1'; X=0; Y=0; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$true },
        [pscustomobject]@{ Id='\\.\DISPLAY2'; X=1920; Y=0; Width=3840; Height=2160
            DpiX=144; DpiY=144; IsPrimary=$false }))
    ShouldBe $layouts[1].ScaleX 1.5
    ShouldBe $layouts[1].DipWidth 2560
}

Describe 'Monitor layouts in awkward arrangements'
It 'handles a monitor mounted below the primary' {
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$true },
        [pscustomobject]@{ Id='below'; X=0; Y=1080; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$false }))
    ShouldBe $layouts[1].PhysicalY 1080
    ShouldBe $layouts[1].PhysicalBottom 2160
    ShouldBe $layouts[1].DipY 1080
}
It 'handles a primary at a negative origin' {
    # Windows puts the origin at the primary's top-left, but a topology captured
    # while a display is being reconfigured can arrive otherwise.
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{ Id='primary'; X=-1920; Y=-1080; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$true },
        [pscustomobject]@{ Id='right'; X=0; Y=-1080; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$false }))
    ShouldBe $layouts[0].PhysicalX -1920
    ShouldBe $layouts[0].PhysicalY -1080
    ShouldBe $layouts[0].DipX -1920
    ShouldBe $layouts[0].PhysicalRight 0
}
It 'keeps duplicate monitor ids apart by index' {
    # A cloned / mirrored setup can report the same device name twice. Index is
    # what the overlay set keys on, so duplicates must not collapse.
    $layouts = @(Get-SnipMonitorLayouts -MonitorDescriptors @(
        [pscustomobject]@{ Id='\\.\DISPLAY1'; X=0; Y=0; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$true },
        [pscustomobject]@{ Id='\\.\DISPLAY1'; X=1920; Y=0; Width=1920; Height=1080
            DpiX=96; DpiY=96; IsPrimary=$false }))
    ShouldBe $layouts.Count 2
    ShouldBe $layouts[0].Index 0
    ShouldBe $layouts[1].Index 1
    ShouldBe $layouts[0].Id $layouts[1].Id
    $parts = @(Get-SnipOverlayIntersections -MonitorLayouts $layouts -Rectangle (
        [pscustomobject]@{ X=1800; Y=100; Width=300; Height=200 }))
    ShouldBe $parts.Count 2
    ShouldBe $parts[0].MonitorIndex 0
    ShouldBe $parts[1].MonitorIndex 1
    ShouldBe $parts[0].PhysicalWidth 120
    ShouldBe $parts[1].PhysicalWidth 180
}

Describe 'Monitor display names and ordering'
It 'keeps an EDID friendly name as-is' {
    ShouldBe (Get-SnipMonitorDisplayName -FriendlyName 'DELL U2412M' -Index 2) 'DELL U2412M'
}
It 'strips the NUL padding EDID descriptor blocks carry' {
    ShouldBe (Get-SnipMonitorDisplayName -FriendlyName "LG ULTRAWIDE`0`0`0" -Index 0) 'LG ULTRAWIDE'
}
It 'falls back to a one-based positional name' {
    ShouldBe (Get-SnipMonitorDisplayName -FriendlyName '' -Index 0) 'Display 1'
    ShouldBe (Get-SnipMonitorDisplayName -FriendlyName $null -Index 2) 'Display 3'
    ShouldBe (Get-SnipMonitorDisplayName -FriendlyName '   ' -Index 1) 'Display 2'
}
It 'orders the primary first and then left to right' {
    $sorted = @(Sort-SnipMonitorDescriptors -Descriptors @(
        [pscustomobject]@{ Id='right'; X=1920; Y=0; Width=1920; Height=1080; IsPrimary=$false },
        [pscustomobject]@{ Id='far-left'; X=-3840; Y=0; Width=1920; Height=1080; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; IsPrimary=$true },
        [pscustomobject]@{ Id='left'; X=-1920; Y=0; Width=1920; Height=1080; IsPrimary=$false }))
    ShouldBe (($sorted | ForEach-Object Id) -join ',') 'primary,far-left,left,right'
}
It 'breaks a column tie top to bottom' {
    $sorted = @(Sort-SnipMonitorDescriptors -Descriptors @(
        [pscustomobject]@{ Id='lower'; X=1920; Y=1080; Width=1920; Height=1080; IsPrimary=$false },
        [pscustomobject]@{ Id='upper'; X=1920; Y=0; Width=1920; Height=1080; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; IsPrimary=$true }))
    ShouldBe (($sorted | ForEach-Object Id) -join ',') 'primary,upper,lower'
}
It 'numbers the positional fallback in menu order, not input order' {
    $sorted = @(Sort-SnipMonitorDescriptors -Descriptors @(
        [pscustomobject]@{ Id='right'; X=1920; Y=0; Width=1920; Height=1080; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080; IsPrimary=$true }))
    ShouldBe $sorted[0].DisplayName 'Display 1'
    ShouldBe $sorted[0].Id 'primary'
    ShouldBe $sorted[1].DisplayName 'Display 2'
}
It 'leaves a real name alone while numbering its neighbours' {
    $sorted = @(Sort-SnipMonitorDescriptors -Descriptors @(
        [pscustomobject]@{ Id='primary'; X=0; Y=0; Width=1920; Height=1080
            IsPrimary=$true; DisplayName='' },
        [pscustomobject]@{ Id='right'; X=1920; Y=0; Width=1920; Height=1080
            IsPrimary=$false; DisplayName='DELL U2412M' }))
    ShouldBe $sorted[0].DisplayName 'Display 1'
    ShouldBe $sorted[1].DisplayName 'DELL U2412M'
}

Describe 'Get-SnipDisplayMenuModel'
It 'builds one row per monitor with the friendly name, size and primary suffix' {
    $rows = @(Get-SnipDisplayMenuModel -Descriptors @(
        [pscustomobject]@{ Id='primary'; Width=1920; Height=1080
            IsPrimary=$true; DisplayName='DELL U2412M' },
        [pscustomobject]@{ Id='right'; Width=2560; Height=1440
            IsPrimary=$false; DisplayName='Display 2' }))
    ShouldBe $rows.Count 2
    ShouldBe $rows[0].Text 'DELL U2412M - 1920 x 1080 (Primary)'
    ShouldBe $rows[0].MonitorId 'primary'
    ShouldBeTrue $rows[0].Enabled
    ShouldBeFalse $rows[0].IsPlaceholder
    ShouldBe $rows[1].Text 'Display 2 - 2560 x 1440'
    ShouldBe $rows[1].MonitorId 'right'
}
It 'falls back to the monitor ID when no display name survives enumeration' {
    $rows = @(Get-SnipDisplayMenuModel -Descriptors @(
        [pscustomobject]@{ Id='\\.\DISPLAY1'; Width=1280; Height=720; IsPrimary=$false },
        [pscustomobject]@{ Id='\\.\DISPLAY2'; Width=1280; Height=720
            IsPrimary=$false; DisplayName='   ' }))
    ShouldBe $rows[0].Text '\\.\DISPLAY1 - 1280 x 720'
    ShouldBe $rows[1].Text '\\.\DISPLAY2 - 1280 x 720'
}
It 'names each row from a padding-free base64 of the stable monitor ID' {
    $rows = @(Get-SnipDisplayMenuModel -Descriptors @(
        [pscustomobject]@{ Id='primary'; Width=1920; Height=1080; IsPrimary=$true }))
    ShouldBe $rows[0].Name ('Display_' + [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes('primary')).TrimEnd('='))
    ShouldBeFalse ($rows[0].Name -match '=')
}
It 'yields one disabled placeholder when enumeration finds nothing' {
    # WinForms gates the submenu arrow and the whole open path on
    # HasDropDownItems, so the empty case must still produce a row.
    $empty = @(Get-SnipDisplayMenuModel -Descriptors @())
    $nulls = @(Get-SnipDisplayMenuModel -Descriptors @($null, $null))
    foreach ($rows in $empty, $nulls) {
        ShouldBe $rows.Count 1
        ShouldBe $rows[0].Text 'No displays detected'
        ShouldBe $rows[0].Name 'Display_None'
        ShouldBe $rows[0].MonitorId ''
        ShouldBeFalse $rows[0].Enabled
        ShouldBeTrue $rows[0].IsPlaceholder
    }
}

Describe 'Get-SnipMonitorInstanceKey'
It 'reduces a device-interface path to the instance path' {
    ShouldBe (Get-SnipMonitorInstanceKey `
        -Value '\\?\DISPLAY#DEL4091#5&1a2b&0&UID4353#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}') `
        'DISPLAY\DEL4091\5&1A2B&0&UID4353'
}
It 'reduces a WMI instance name to the same key' {
    ShouldBe (Get-SnipMonitorInstanceKey -Value 'DISPLAY\DEL4091\5&1a2b&0&UID4353_0') `
        'DISPLAY\DEL4091\5&1A2B&0&UID4353'
}
It 'returns empty for nothing usable' {
    ShouldBe (Get-SnipMonitorInstanceKey -Value $null) ''
    ShouldBe (Get-SnipMonitorInstanceKey -Value '   ') ''
}

Describe 'Get-SnipSizeChipPlacement'
It 'sits just below the drag rectangle and right-aligns to it' {
    $placement = Get-SnipSizeChipPlacement -RectX 100 -RectY 100 -RectWidth 400 -RectHeight 300 `
        -ChipWidth 90 -ChipHeight 26 -MonitorWidth 1920 -MonitorHeight 1080
    ShouldBe $placement.X 410
    ShouldBe $placement.Y 408
    ShouldBe $placement.Edge 'Below'
}
It 'flips above the rectangle at the bottom edge of the monitor' {
    $placement = Get-SnipSizeChipPlacement -RectX 100 -RectY 700 -RectWidth 400 -RectHeight 370 `
        -ChipWidth 90 -ChipHeight 26 -MonitorWidth 1920 -MonitorHeight 1080
    ShouldBe $placement.Edge 'Above'
    ShouldBe $placement.Y 666
}
It 'tucks inside a selection that fills the monitor' {
    $placement = Get-SnipSizeChipPlacement -RectX 0 -RectY 0 -RectWidth 1920 -RectHeight 1080 `
        -ChipWidth 90 -ChipHeight 26 -MonitorWidth 1920 -MonitorHeight 1080
    ShouldBe $placement.Edge 'Inside'
    ShouldBe $placement.Y 1046
    ShouldBe $placement.X 1830
}
It 'never lets the chip leave the monitor' {
    $placement = Get-SnipSizeChipPlacement -RectX -50 -RectY 0 -RectWidth 60 -RectHeight 40 `
        -ChipWidth 90 -ChipHeight 26 -MonitorWidth 1920 -MonitorHeight 1080
    ShouldBe $placement.X 0
    $placement = Get-SnipSizeChipPlacement -RectX 1900 -RectY 0 -RectWidth 200 -RectHeight 40 `
        -ChipWidth 90 -ChipHeight 26 -MonitorWidth 1920 -MonitorHeight 1080
    ShouldBe $placement.X 1830
}

Describe 'Test-SnipOverlayIdleTimeout'
It 'never cancels while an overlay holds the foreground' {
    $now = [datetime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
    ShouldBeFalse (Test-SnipOverlayIdleTimeout -LastInputUtc $now.AddMinutes(-10) `
        -NowUtc $now -Timeout ([timespan]::FromSeconds(20)) -OverlayIsForeground $true)
}
It 'cancels once the timeout elapses with the foreground lost' {
    $now = [datetime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
    ShouldBeTrue (Test-SnipOverlayIdleTimeout -LastInputUtc $now.AddSeconds(-20) `
        -NowUtc $now -Timeout ([timespan]::FromSeconds(20)) -OverlayIsForeground $false)
}
It 'waits for the full timeout' {
    $now = [datetime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
    ShouldBeFalse (Test-SnipOverlayIdleTimeout -LastInputUtc $now.AddSeconds(-19) `
        -NowUtc $now -Timeout ([timespan]::FromSeconds(20)) -OverlayIsForeground $false)
}
It 'treats a non-positive timeout as watchdog disabled' {
    $now = [datetime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
    ShouldBeFalse (Test-SnipOverlayIdleTimeout -LastInputUtc $now.AddDays(-1) `
        -NowUtc $now -Timeout ([timespan]::Zero) -OverlayIsForeground $false)
}

Describe 'Get-SnipPreviewPlacement across monitors'
$script:PlacementDescriptors = @(
    [pscustomobject]@{ Id='laptop'; X=0; Y=0; Width=1920; Height=1080
        WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true },
    [pscustomobject]@{ Id='uhd'; X=1920; Y=0; Width=3840; Height=2160
        WorkX=1920; WorkY=0; WorkWidth=3840; WorkHeight=2120; DpiX=96; DpiY=96; IsPrimary=$false }
)
function New-PlacementTopology {
    New-SnipDisplayTopology -MonitorDescriptors $script:PlacementDescriptors `
        -RequestId placement-fixture
}
It 'still follows the largest intersection for a single-monitor capture' {
    $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
        -CaptureBounds ([pscustomobject]@{ X=2100; Y=200; Width=600; Height=400 })
    ShouldBe $placement.CaptureMonitor.Id 'uhd'
    ShouldBe $placement.PlacementReason 'LargestIntersection'
    ShouldBeFalse $placement.SpansMultipleMonitors
    ShouldBe $placement.Anchor 'CaptureCentre'
}
It 'places a full-desktop capture on the monitor under the pointer' {
    # The old rule handed every full-desktop capture to the biggest panel; the
    # user pressing the hotkey on the laptop got the editor on the 4K screen.
    $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
        -CaptureBounds ([pscustomobject]@{ X=0; Y=0; Width=5760; Height=2160 }) `
        -PointerPhysicalPosition ([pscustomobject]@{ X=400; Y=500 })
    ShouldBeTrue $placement.SpansMultipleMonitors
    ShouldBe $placement.PlacementReason 'PointerMonitor'
    ShouldBe $placement.CaptureMonitor.Id 'laptop'
}
It 'follows the pointer onto the larger monitor too' {
    $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
        -CaptureBounds ([pscustomobject]@{ X=0; Y=0; Width=5760; Height=2160 }) `
        -PointerPhysicalPosition ([pscustomobject]@{ X=3000; Y=1200 })
    ShouldBe $placement.PlacementReason 'PointerMonitor'
    ShouldBe $placement.CaptureMonitor.Id 'uhd'
}
It 'falls back to the primary when the pointer is unknown or off-desktop' {
    foreach ($pointer in @($null, [pscustomobject]@{ X=99999; Y=99999 })) {
        $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
            -CaptureBounds ([pscustomobject]@{ X=0; Y=0; Width=5760; Height=2160 }) `
            -PointerPhysicalPosition $pointer
        ShouldBe $placement.PlacementReason 'PrimaryMonitor'
        ShouldBe $placement.CaptureMonitor.Id 'laptop'
    }
}
It 'does not treat a capture covering one monitor and a sliver of another as spanning' {
    $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
        -CaptureBounds ([pscustomobject]@{ X=0; Y=0; Width=2100; Height=1080 }) `
        -PointerPhysicalPosition ([pscustomobject]@{ X=3000; Y=1200 })
    ShouldBeFalse $placement.SpansMultipleMonitors
    ShouldBe $placement.CaptureMonitor.Id 'laptop'
}
It 'centres on the work area when the capture centre is on another monitor' {
    # Clamping used to pin the window against whichever edge was nearest, so a
    # desktop-spanning capture opened flush against the laptop's left edge.
    $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
        -CaptureBounds ([pscustomobject]@{ X=0; Y=0; Width=5760; Height=2160 }) `
        -PointerPhysicalPosition ([pscustomobject]@{ X=400; Y=500 })
    ShouldBe $placement.Anchor 'WorkAreaCentre'
    $bounds = $placement.InitialPhysicalBounds
    # Centred on the laptop's 1920-wide work area rather than pinned to x=0.
    ShouldBe ($bounds.X + $bounds.Width / 2) 960
    ShouldBeTrue ($bounds.X -gt 0)
}
It 'keeps capture-centred placement when the centre is on the chosen monitor' {
    $placement = Get-SnipPreviewPlacement -Topology (New-PlacementTopology) `
        -CaptureBounds ([pscustomobject]@{ X=3000; Y=800; Width=600; Height=400 })
    ShouldBe $placement.Anchor 'CaptureCentre'
    $bounds = $placement.InitialPhysicalBounds
    ShouldBe ($bounds.X + $bounds.Width / 2) 3300
    ShouldBe ($bounds.Y + $bounds.Height / 2) 1000
}
It 'reports DIP and physical bounds that describe the same rectangle' {
    $descriptors = @(
        [pscustomobject]@{ Id='hidpi'; X=0; Y=0; Width=3840; Height=2160
            WorkX=0; WorkY=0; WorkWidth=3840; WorkHeight=2120
            DpiX=144; DpiY=144; IsPrimary=$true })
    $topology = New-SnipDisplayTopology -MonitorDescriptors $descriptors -RequestId dip-check
    $placement = Get-SnipPreviewPlacement -Topology $topology `
        -CaptureBounds ([pscustomobject]@{ X=100; Y=100; Width=800; Height=600 })
    ShouldBe $placement.InitialPhysicalBounds.X ([int][math]::Round($placement.InitialBounds.X * 1.5))
    ShouldBe $placement.InitialPhysicalBounds.Y ([int][math]::Round($placement.InitialBounds.Y * 1.5))
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
