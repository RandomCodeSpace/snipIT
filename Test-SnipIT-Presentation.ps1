# Cross-platform tests for SnipIT presentation policy. No Pester dependency.
# Run: pwsh -NoProfile -File ./Test-SnipIT-Presentation.ps1
$ErrorActionPreference = 'Stop'

$scriptUnderTest = Join-Path $PSScriptRoot 'SnipIT.ps1'
if (-not (Test-Path -LiteralPath $scriptUnderTest -PathType Leaf)) {
    throw "SnipIT.ps1 not found next to the test script: $scriptUnderTest"
}

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
function Should-Be { param($Actual, $Expected)
    if ($Actual -ne $Expected) { throw "Expected '$Expected' but got '$Actual'" }
}
function Should-BeTrue  { param($Value) if (-not $Value) { throw 'Expected $true' } }
function Should-BeFalse { param($Value) if ($Value)      { throw 'Expected $false' } }

Describe 'Portable stock toolbar presentation'
It 'projects one stable implemented-tool order at 1200 by 700' {
    $state = New-SnipPresentationState -ActiveTool Select `
        -RecentTools @('Highlight','ArrowLine') -ViewportWidth 1200 -ViewportHeight 760
    $view = Get-SnipToolbarPresentation -State $state
    Should-Be $view.Mode 'Native'
    Should-Be ($view.Order -join ',') 'Select,Highlight,RectangleEllipse,ArrowLine,Text,Pen,Steps,BlurPixelate,Crop,Undo,Redo'
    Should-Be $view.CheckedTool 'Select'
    Should-BeFalse $view.MoreActive
}
It 'keeps the same implemented tools at 900 by 600' {
    $state = New-SnipPresentationState -ActiveTool RectangleEllipse `
        -RecentTools @('RectangleEllipse','Highlight') -ViewportWidth 900 -ViewportHeight 700
    $view = Get-SnipToolbarPresentation -State $state
    Should-Be $view.Mode 'Native'
    Should-Be ($view.Order -join ',') 'Select,Highlight,RectangleEllipse,ArrowLine,Text,Pen,Steps,BlurPixelate,Crop,Undo,Redo'
    Should-BeFalse $view.MoreActive
}
It 'keeps the same implemented tools at 760 by 540 without custom More state' {
    $state = New-SnipPresentationState -ActiveTool ArrowLine `
        -RecentTools @('ArrowLine','Highlight') -ViewportWidth 700 -ViewportHeight 700
    $view = Get-SnipToolbarPresentation -State $state
    Should-Be $view.Mode 'Native'
    Should-Be ($view.Order -join ',') 'Select,Highlight,RectangleEllipse,ArrowLine,Text,Pen,Steps,BlurPixelate,Crop,Undo,Redo'
    Should-BeFalse $view.MoreActive
    Should-Be $view.MoreTool $null
}

Describe 'Portable status presentation'
It 'projects the narrow idle indicator without WPF values' {
    $state = New-SnipPresentationState -ViewportWidth 700 -ViewportHeight 700
    $view = Get-SnipStatusPresentation -State $state -WindowWidth 700
    Should-Be $view.Text ([string][char]0x25CF)
    Should-Be $view.Width 42
    Should-Be $view.Trimming 'None'
    Should-BeFalse $view.IndicatorVisible
}
It 'projects compact truncation and complete accessible text' {
    $state = New-SnipPresentationState -ViewportWidth 900 -ViewportHeight 700 `
        -StatusKind Busy -StatusText 'Copying the edited capture'
    $view = Get-SnipStatusPresentation -State $state -WindowWidth 900
    Should-Be $view.Width 150
    Should-Be $view.Trimming 'CharacterEllipsis'
    Should-Be $view.ToolTip 'Copying the edited capture'
    Should-Be $view.HelpText 'Copying the edited capture'
}

Describe 'Portable capabilities and commands'
It 'exposes the full wired tool set as supported and visible' {
    $capabilities = Get-SnipPreviewCapabilities
    Should-Be ($capabilities.SupportedTools -join ',') `
        'Select,Highlight,RectangleEllipse,ArrowLine,Text,Pen,Steps,BlurPixelate,Crop'
    Should-Be ($capabilities.ExposedTools -join ',') `
        'Select,Highlight,RectangleEllipse,ArrowLine,Text,Pen,Steps,BlurPixelate,Crop'
}
It 'enables selection, crop, undo, and redo commands from plain state' {
    $state = New-SnipPresentationState -SelectionId 'record-1' -HasCrop $true `
        -CanUndo $true -CanRedo $false
    $commands = Get-SnipCommandPresentation -State $state
    Should-Be (@($commands | Where-Object Name -eq DeleteSelection)[0].Enabled) $true
    Should-Be (@($commands | Where-Object Name -eq ApplyCrop)[0].Enabled) $true
    Should-Be (@($commands | Where-Object Name -eq Undo)[0].Enabled) $true
    Should-Be (@($commands | Where-Object Name -eq Redo)[0].Enabled) $false
}
It 'maps a real key decision to a semantic command intent' {
    $intent = Resolve-SnipPresentationKeyIntent -State (New-SnipPresentationState) `
        -FocusedRole Canvas -EditorState @{ PopupOpen=$false; EditingText=$false; EditingProperty=$false; Draft=$null; SelectionId=$null; ActiveTool='Select' } `
        -Key C -Modifiers @('Ctrl','Shift')
    Should-Be $intent.Type 'InvokeCommand'
    Should-Be $intent.Command 'CopyKeepOpen'
}
It 'canonicalizes platform commands and preserves router-local commands' {
    $editor = @{ PopupOpen=$false; EditingText=$false; EditingProperty=$false; Draft=$null; SelectionId=$null; ActiveTool='Select' }
    $newIntent = Resolve-SnipPresentationKeyIntent -State (New-SnipPresentationState) `
        -FocusedRole Canvas -EditorState $editor -Key N -Modifiers @('Ctrl')
    Should-Be $newIntent.Type 'InvokeCommand'
    Should-Be $newIntent.Command 'NewSnip'
    Should-Be $newIntent.SourceCommand 'NewSmartCapture'
    $closeIntent = Resolve-SnipPresentationKeyIntent -State (New-SnipPresentationState) `
        -FocusedRole Canvas -EditorState $editor -Key Escape -Modifiers @()
    Should-Be $closeIntent.Type 'InvokeCommand'
    Should-Be $closeIntent.Command 'Close'
    Should-Be $closeIntent.SourceCommand 'ClosePreview'
    $localEditor = $editor.Clone(); $localEditor.Draft = [pscustomobject]@{ Kind='Rectangle' }
    $localIntent = Resolve-SnipPresentationKeyIntent -State (New-SnipPresentationState) `
        -FocusedRole Canvas -EditorState $localEditor -Key Escape -Modifiers @()
    Should-Be $localIntent.Type 'RouteCommand'
    Should-Be $localIntent.Command 'CancelDraft'
    Should-Be $localIntent.SourceCommand 'CancelDraft'
}
It 'emits a copy effect without performing clipboard work' {
    $result = Invoke-SnipPresentationIntent -State (New-SnipPresentationState) `
        -Intent ([pscustomobject]@{ Type='InvokeCommand'; Command='CopyAndClose' })
    Should-Be $result.Effects[0].Name 'Copy'
    Should-Be $result.Effects[0].CloseAfter $true
}

Describe 'Portable display topology and preview placement'
$topologyCases = @(
    [pscustomobject]@{
        Name = 'normalizes a single 1920x1080 monitor and copies its descriptor'
        Descriptors = @(
            [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; DpiX=96; DpiY=96; IsPrimary=$true }
        )
        Expected = [pscustomobject]@{ X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1080 }
    }
    [pscustomobject]@{
        Name = 'preserves a negative monitor origin in the physical union'
        Descriptors = @(
            [pscustomobject]@{ Id='left'; X=-1280; Y=0; Width=1280; Height=1024; DpiX=96; DpiY=96 },
            [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; DpiX=96; DpiY=96 }
        )
        Expected = [pscustomobject]@{ X=-1280; Y=0; Width=3200; Height=1080; WorkX=$null; WorkY=$null; WorkWidth=$null; WorkHeight=$null }
    }
    [pscustomobject]@{
        Name = 'keeps independent horizontal and vertical DPI scales'
        Descriptors = @(
            [pscustomobject]@{ Id='mixed'; X=0; Y=0; Width=1800; Height=1250; DpiX=144; DpiY=120 }
        )
        Expected = [pscustomobject]@{ X=0; Y=0; Width=1800; Height=1250; WorkX=$null; WorkY=$null; WorkWidth=$null; WorkHeight=$null }
    }
    [pscustomobject]@{
        Name = 'retains portrait physical dimensions'
        Descriptors = @(
            [pscustomobject]@{ Id='portrait'; X=0; Y=0; Width=1080; Height=1920; DpiX=96; DpiY=96 }
        )
        Expected = [pscustomobject]@{ X=0; Y=0; Width=1080; Height=1920; WorkX=$null; WorkY=$null; WorkWidth=$null; WorkHeight=$null }
    }
    [pscustomobject]@{
        Name = 'uses a physical union that includes an uncovered monitor gap'
        Descriptors = @(
            [pscustomobject]@{ Id='left'; X=0; Y=0; Width=1000; Height=800; DpiX=96; DpiY=96 },
            [pscustomobject]@{ Id='right'; X=2000; Y=0; Width=1000; Height=800; DpiX=96; DpiY=96 }
        )
        Expected = [pscustomobject]@{ X=0; Y=0; Width=3000; Height=800; WorkX=$null; WorkY=$null; WorkWidth=$null; WorkHeight=$null }
    }
)
foreach ($case in $topologyCases) {
    It $case.Name {
        $topology = New-SnipDisplayTopology -MonitorDescriptors $case.Descriptors
        Should-Be $topology.VirtualPhysicalBounds.X $case.Expected.X
        Should-Be $topology.VirtualPhysicalBounds.Y $case.Expected.Y
        Should-Be $topology.VirtualPhysicalBounds.Width $case.Expected.Width
        Should-Be $topology.VirtualPhysicalBounds.Height $case.Expected.Height
        Should-Be ($topology.Descriptors.Id -join ',') ($case.Descriptors.Id -join ',')
        Should-Be ($topology.Layouts.Id -join ',') ($case.Descriptors.Id -join ',')
        if ($null -ne $case.Expected.WorkX) {
            Should-Be $topology.Descriptors[0].WorkX $case.Expected.WorkX
            Should-Be $topology.Descriptors[0].WorkY $case.Expected.WorkY
            Should-Be $topology.Descriptors[0].WorkWidth $case.Expected.WorkWidth
            Should-Be $topology.Descriptors[0].WorkHeight $case.Expected.WorkHeight
        }
    }
}
It 'copies descriptor input instead of mutating caller records' {
    $descriptor = [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; DpiX=96; DpiY=96 }
    $topology = New-SnipDisplayTopology -MonitorDescriptors @($descriptor)
    $topology.Descriptors[0].X = 77
    Should-Be $descriptor.X 0
    Should-Be ($null -eq $descriptor.PSObject.Properties['WorkX']) $true
}
It 'records copied immutable topology metadata with a deterministic fingerprint' {
    $descriptors = @(
        [pscustomobject]@{ Id='left'; X=-1280; Y=0; Width=1280; Height=1024; WorkX=-1280; WorkY=0; WorkWidth=1280; WorkHeight=984; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=144; DpiY=120; IsPrimary=$true }
    )
    $capturedAt = [datetime]'2026-08-31T12:30:45Z'
    $topology = New-SnipDisplayTopology -MonitorDescriptors $descriptors `
        -RequestId 'display-request-7' -CapturedAtUtc $capturedAt
    $sameLayout = New-SnipDisplayTopology -MonitorDescriptors $descriptors `
        -RequestId 'display-request-8' -CapturedAtUtc ([datetime]'2026-08-31T12:30:46Z')
    $descriptors[0].WorkHeight = 800
    Should-Be $topology.RequestId 'display-request-7'
    Should-Be $topology.CapturedAtUtc '2026-08-31T12:30:45.0000000Z'
    Should-Be $topology.Descriptors[0].WorkHeight 984
    Should-Be $topology.Layouts[0].Descriptor.WorkHeight 984
    Should-Be $topology.Fingerprint $sameLayout.Fingerprint
    Should-BeTrue (-not [string]::IsNullOrWhiteSpace([string]$topology.Fingerprint))
}
It 'changes the topology fingerprint when ordered display geometry changes' {
    $before = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; DpiX=96; DpiY=96; IsPrimary=$true }
    )
    $after = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1040; DpiX=96; DpiY=96; IsPrimary=$true }
    )
    Should-BeTrue ($before.Fingerprint -ne $after.Fingerprint)
}
It 'uses independent DPI scales and clamps mixed-DPI spanning placement' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='left'; X=-1280; Y=0; Width=1280; Height=1024; WorkX=-1280; WorkY=0; WorkWidth=1280; WorkHeight=984; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=144; DpiY=120; IsPrimary=$true }
    )
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds ([pscustomobject]@{ X=-200; Y=100; Width=1200; Height=600 }) `
        -Topology $topology
    Should-Be $placement.CaptureMonitor.Id 'main'
    Should-Be $placement.InitialBounds.Width 1180
    Should-Be $placement.InitialBounds.Height 760
    Should-BeTrue ($placement.InitialPhysicalBounds.X -ge 0)
    Should-BeTrue (($placement.InitialPhysicalBounds.X + $placement.InitialPhysicalBounds.Width) -le 1920)
    Should-BeTrue ($placement.InitialPhysicalBounds.Y -ge 0)
    Should-BeTrue (($placement.InitialPhysicalBounds.Y + $placement.InitialPhysicalBounds.Height) -le 1040)
}
It 'centers and clamps a portrait preview within its work area' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='portrait'; X=0; Y=0; Width=1080; Height=1920; WorkX=0; WorkY=0; WorkWidth=1080; WorkHeight=1880; DpiX=96; DpiY=96 }
    )
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds ([pscustomobject]@{ X=900; Y=1600; Width=100; Height=100 }) `
        -Topology $topology
    Should-Be $placement.CaptureMonitor.Id 'portrait'
    Should-Be $placement.InitialPhysicalBounds.Width 1080
    Should-Be $placement.InitialPhysicalBounds.Height 760
    Should-Be $placement.InitialPhysicalBounds.X 0
    Should-Be $placement.InitialPhysicalBounds.Y 1120
}
It 'chooses the monitor with the largest physical capture intersection' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='left'; X=0; Y=0; Width=1000; Height=800; DpiX=96; DpiY=96 },
        [pscustomobject]@{ Id='right'; X=1000; Y=0; Width=1000; Height=800; DpiX=96; DpiY=96 }
    )
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds ([pscustomobject]@{ X=800; Y=100; Width=600; Height=400 }) `
        -Topology $topology
    Should-Be $placement.CaptureMonitor.Id 'right'
}
It 'uses capture-center containment before primary status for equal physical intersections' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='first'; X=0; Y=0; Width=1000; Height=800; DpiX=96; DpiY=96; IsPrimary=$true },
        [pscustomobject]@{ Id='second'; X=1000; Y=0; Width=1000; Height=800; DpiX=96; DpiY=96; IsPrimary=$false }
    )
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds ([pscustomobject]@{ X=800; Y=100; Width=400; Height=400 }) `
        -Topology $topology
    Should-Be $placement.CaptureMonitor.Id 'second'
}
It 'uses the primary monitor before descriptor order when an equal capture center is in a gap' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='first'; X=0; Y=0; Width=800; Height=800; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='second'; X=1600; Y=0; Width=800; Height=800; DpiX=96; DpiY=96; IsPrimary=$true }
    )
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds ([pscustomobject]@{ X=600; Y=100; Width=1200; Height=200 }) `
        -Topology $topology
    Should-Be $placement.CaptureMonitor.Id 'second'
}
It 'uses descriptor order as the final preview placement tie-breaker' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='first'; X=0; Y=0; Width=800; Height=800; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='second'; X=1600; Y=0; Width=800; Height=800; DpiX=96; DpiY=96; IsPrimary=$false }
    )
    $placement = Get-SnipPreviewPlacement `
        -CaptureBounds ([pscustomobject]@{ X=600; Y=100; Width=1200; Height=200 }) `
        -Topology $topology
    Should-Be $placement.CaptureMonitor.Id 'first'
}
It 'chooses a pointer-containing widget monitor and returns monitor-local DIP work bounds' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='upper-left'; X=-1200; Y=-900; Width=1200; Height=900; WorkX=-1200; WorkY=-860; WorkWidth=1200; WorkHeight=860; DpiX=120; DpiY=144; IsPrimary=$false },
        [pscustomobject]@{ Id='main'; X=0; Y=0; Width=1920; Height=1080; WorkX=0; WorkY=0; WorkWidth=1920; WorkHeight=1040; DpiX=96; DpiY=96; IsPrimary=$true }
    )
    $placement = Get-SnipWidgetPlacement -Topology $topology `
        -PointerPhysicalPosition ([pscustomobject]@{ X=-100; Y=-100 }) `
        -LastValidMonitorId 'main'
    Should-Be $placement.MonitorId 'upper-left'
    Should-Be $placement.WorkAreaPhysicalBounds.X -1200
    Should-Be $placement.WorkAreaPhysicalBounds.Y -860
    Should-Be $placement.MonitorLocalDipWorkArea.X 0
    Should-Be $placement.MonitorLocalDipWorkArea.Y (40 / 1.5)
    Should-Be $placement.MonitorLocalDipWorkArea.Width 960
}
It 'uses the last valid widget monitor only when the pointer is in a topology gap' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='left'; X=-1200; Y=0; Width=1200; Height=900; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=400; Y=0; Width=1600; Height=900; DpiX=144; DpiY=144; IsPrimary=$true }
    )
    $placement = Get-SnipWidgetPlacement -Topology $topology `
        -PointerPhysicalPosition ([pscustomobject]@{ X=100; Y=200 }) `
        -LastValidMonitorId 'left'
    Should-Be $placement.MonitorId 'left'
}
It 'falls back to primary when the widget pointer is outside topology bounds' {
    $topology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='left'; X=-1200; Y=0; Width=1200; Height=900; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=400; Y=0; Width=1600; Height=900; DpiX=144; DpiY=144; IsPrimary=$true }
    )
    $placement = Get-SnipWidgetPlacement -Topology $topology `
        -PointerPhysicalPosition ([pscustomobject]@{ X=2200; Y=200 }) `
        -LastValidMonitorId 'left'
    Should-Be $placement.MonitorId 'primary'
}
It 'falls back from an unavailable widget monitor to the primary then descriptor order' {
    $primaryTopology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='first'; X=0; Y=0; Width=800; Height=800; DpiX=96; DpiY=96; IsPrimary=$false },
        [pscustomobject]@{ Id='primary'; X=1600; Y=0; Width=800; Height=800; DpiX=96; DpiY=96; IsPrimary=$true }
    )
    $primaryPlacement = Get-SnipWidgetPlacement -Topology $primaryTopology `
        -PointerPhysicalPosition ([pscustomobject]@{ X=1000; Y=100 }) `
        -LastValidMonitorId 'removed-monitor'
    Should-Be $primaryPlacement.MonitorId 'primary'
    $singleTopology = New-SnipDisplayTopology -MonitorDescriptors @(
        [pscustomobject]@{ Id='only'; X=-800; Y=200; Width=800; Height=600; DpiX=96; DpiY=96; IsPrimary=$false }
    )
    $singlePlacement = Get-SnipWidgetPlacement -Topology $singleTopology `
        -PointerPhysicalPosition ([pscustomobject]@{ X=50; Y=50 })
    Should-Be $singlePlacement.MonitorId 'only'
}
It 'rejects an empty monitor descriptor list with the topology contract message' {
    $message = try {
        New-SnipDisplayTopology -MonitorDescriptors @() | Out-Null
        $null
    } catch {
        $_.Exception.Message
    }
    Should-BeTrue ($message.StartsWith('At least one monitor descriptor is required.'))
}

Describe 'Portable presentation reducers'
It 'copies nested state inputs instead of mutating caller values' {
    $captureBounds = [ordered]@{ X=10; Y=20; Size=[ordered]@{ Width=30; Height=40 } }
    $topology = @([pscustomobject]@{ Id='display-1'; Bounds=[ordered]@{ X=0; Y=0 } })
    $state = New-SnipPresentationState -CaptureBounds $captureBounds -DisplayTopology $topology
    $state.CaptureBounds.Size.Width = 99
    $state.DisplayTopology[0].Bounds.X = 77
    Should-Be $captureBounds.Size.Width 30
    Should-Be $topology[0].Bounds.X 0
}
It 'activates a tool on a copy and keeps two deduplicated recent tools' {
    $state = New-SnipPresentationState -ActiveTool Highlight `
        -RecentTools @('Highlight','ArrowLine')
    $result = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='ActivateTool'; Tool='RectangleEllipse' })
    Should-Be $state.ActiveTool 'Highlight'
    Should-Be ($state.RecentTools -join ',') 'Highlight,ArrowLine'
    Should-Be $result.State.ActiveTool 'RectangleEllipse'
    Should-Be ($result.State.RecentTools -join ',') 'RectangleEllipse,Highlight'
    Should-Be ($result.Effects.Name -join ',') 'CancelDraft,RefreshActiveChrome,RefreshPropertyIsland,RefreshResponsiveChrome'
}
It 'does not cancel a draft when the active tool is unchanged' {
    $state = New-SnipPresentationState -ActiveTool Highlight
    $result = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='ActivateTool'; Tool='Highlight' })
    Should-BeFalse (@($result.Effects.Name) -contains 'CancelDraft')
}
It 'resizes the viewport and emits presentation-only effects' {
    $state = New-SnipPresentationState
    $result = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='ResizeViewport'; Width=800; Height=500 })
    Should-Be $state.ViewportWidth 1200
    Should-Be $result.State.ViewportWidth 800
    Should-Be $result.State.ViewportHeight 500
    Should-Be ($result.Effects.Name -join ',') 'RefreshResponsiveChrome,RefreshStatus'
}
It 'sets and clears status on copied state' {
    $state = New-SnipPresentationState
    $setResult = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='SetStatus'; Kind='Busy'; Text='Saving' })
    Should-Be $setResult.State.StatusKind 'Busy'
    Should-Be $setResult.State.StatusText 'Saving'
    Should-Be $setResult.Effects[0].Name 'RefreshStatus'
    $clearResult = Invoke-SnipPresentationIntent -State $setResult.State `
        -Intent ([pscustomobject]@{ Type='ClearStatus' })
    Should-Be $clearResult.State.StatusKind 'Idle'
    Should-Be $clearResult.State.StatusText ''
    Should-Be $clearResult.Effects[0].Name 'RefreshStatus'
}
It 'synchronizes command state without emitting an effect' {
    $state = New-SnipPresentationState -SelectionId 'old' -CanUndo $false `
        -CanRedo $true -HasCrop $false
    $result = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='SyncCommandState'; SelectionId='new'; CanUndo=$true; CanRedo=$false; HasCrop=$true })
    Should-Be $state.SelectionId 'old'
    Should-Be $result.State.SelectionId 'new'
    Should-Be $result.State.CanUndo $true
    Should-Be $result.State.CanRedo $false
    Should-Be $result.State.HasCrop $true
    Should-Be @($result.Effects).Count 0
}
It 'does not emit a platform effect for a disabled command' {
    $state = New-SnipPresentationState -CanRedo $false
    $result = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='InvokeCommand'; Command='Redo' })
    Should-Be @($result.Effects).Count 0
}
It 'copies display topology and emits placement policy' {
    $state = New-SnipPresentationState
    $topology = @([pscustomobject]@{ Id='display-1'; Bounds=[ordered]@{ X=-100; Y=0 } })
    $result = Invoke-SnipPresentationIntent -State $state `
        -Intent ([pscustomobject]@{ Type='UpdateDisplayTopology'; DisplayTopology=$topology })
    $result.State.DisplayTopology[0].Bounds.X = 25
    Should-Be $topology[0].Bounds.X -100
    Should-Be $result.Effects[0].Name 'ApplyPlacement'
}
It 'rejects unknown intent types with the contract message' {
    $message = try {
        Invoke-SnipPresentationIntent -State (New-SnipPresentationState) `
            -Intent ([pscustomobject]@{ Type='LaunchMissiles' }) | Out-Null
        $null
    } catch {
        $_.Exception.Message
    }
    Should-Be $message "Unknown presentation intent 'LaunchMissiles'."
}

Write-Host "`n========================================"
Write-Host "Results: $script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'All portable presentation tests passed.' -ForegroundColor Green
