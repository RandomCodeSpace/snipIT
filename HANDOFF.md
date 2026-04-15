# SnipIT — Handoff notes

Snapshot of project state and the outstanding zoom bug, written so the next
person (or a future session with a real Windows dev machine) can pick it up
cold.

## Current state

- **Works**: capture (smart / full-screen / active window), global hotkeys,
  tray, floating widget, chromeless Fluent preview window, install to
  `snipIT-Home/`, Desktop + Startup shortcut with a generated SnipIT.ico,
  single-instance mutex, annotations (highlight / rect / arrow / text,
  6 colors, undo/redo, right-click context menu for color/delete), About
  dialog, 40 unit tests in `Test-SnipIT.ps1`.

- **Broken**: zoom in / zoom out / fit-to-viewport / Ctrl+wheel on the
  preview window's image. Preview opens correctly but zoom controls do
  nothing visible.

## Outstanding bug: zoom

### Symptom

- Zoom In / Zoom Out / Fit buttons click but the image doesn't resize.
- Ctrl+MouseWheel on the image does nothing.
- The header zoom percent indicator changes visually in some iterations
  and not others depending on how the zoom state is stored.

### What the trace logs revealed

Last useful log (via `$env:TEMP\snipit-trace.log`) showed:

```
setZoom s=1 scaleX=1 hostActualW=1466 extentW=1466 viewportW=1474
...
wheel factor=0.8 curr=       ← curr= EMPTY
setZoom s=0.05 scaleX=0.05 hostActualW=1465.9999...
```

Two things were clear:
1. When `setZoom` runs with a real value, `$layoutScale.ScaleX` **does**
   get written and `$imageHost.ActualWidth` **does** change in response
   (so the `LayoutTransform` + `Stretch="None"` layout actually works).
2. The zoom level tracking variable (`$script:PreviewZoom`) was reading as
   empty in every handler entry — so `$empty * 1.25` = `0`, clamped to
   `0.05`. The handlers WERE firing, they just couldn't read the current
   zoom.

### What was tried (all still broken as of last commit)

| Attempt | Storage for current zoom | Result |
|---|---|---|
| `$state.Zoom` on a pscustomobject captured via `.GetNewClosure()` | PSCustomObject field | reads back as $null in click handlers |
| `$script:PreviewZoom` | script scope | reads back as empty string |
| `$zoomBox = @{ Value = 1.0 }` via closure | hashtable by reference | `.Value` dot-notation seemed ambiguous |
| `$zoomBox = @{ Z = 1.0 }`, bracket access `$zoomBox['Z']` | hashtable explicit | not yet confirmed |
| `$Global:SnipITZoom` (**current on main**) | global scope | user reports still broken, no trace log captured yet |

### Layout approach that DID work

From MS docs and SO research: `LayoutTransform` on the Grid that wraps
both the Image and the overlay Canvas, with `Image Stretch="None"` and
no explicit Width/Height on the Image. ImageHost must be
`HorizontalAlignment="Left" VerticalAlignment="Top"` — centering
collapses the ScrollViewer extent measurement.

That layout piece is correct now. The remaining issue is the
PowerShell-side state holding the current zoom level.

### Hypotheses to verify on Windows

1. **Most likely — PS scope / closure interaction with WPF events**:
   scriptblocks attached via `Button.Add_Click` and `Window.Add_PreviewMouseWheel`
   might be invoked in a session state that does not match the
   enclosing function's script scope, so `$script:` reads return
   `$null`. `$Global:` SHOULD work but needs actual Windows verification.
   
2. **DP persistence**: `$layoutScale.ScaleX = 1.25` may not persist on
   a ScaleTransform that's already been assigned to a DP. Earlier traces
   showed `before=1 after=1` despite the write. Worth checking whether
   replacing the entire transform (`$imageHost.LayoutTransform = New ScaleTransform $s $s`)
   behaves differently from mutating ScaleX on a retained reference.
   This happened even for a transform we created in code, not via XAML.

3. **BitmapSource DPI** — full-screen capture may produce a BitmapSource
   with non-96 DPI, making the Image control measure at an unexpected
   DIP size. This doesn't block zoom but affects the fit calculation.

### Concrete next steps on Windows

1. Open pwsh 7.5 in an elevated-for-debug session with the script loaded
   via dot-sourcing. Put a breakpoint (or `Read-Host` pause) inside the
   ZoomIn click handler. Verify:
   - Is `$Global:SnipITZoom` actually 1.0 when the handler starts?
   - After `$setZoom ($Global:SnipITZoom * 1.25)` runs, is
     `$layoutScale.ScaleX` actually 1.25? And
     `$imageHost.LayoutTransform.ScaleX`? And
     `$imageHost.ActualWidth`?
2. If values read correctly but the image doesn't visibly grow, inspect
   the ScrollViewer / ImageHost / Image visual tree with Snoop or
   WPF Inspector to see the actual measured / arranged sizes and where
   the scale is getting swallowed.
3. If values don't persist between handler calls, the scope theory is
   right and the fix is: build a tiny wrapper class via `Add-Type`
   (one `public double Value;` field) and capture an instance. That's
   immune to PS scope rules.

### Relevant files / lines

- `SnipIT.ps1` — single script, ~1600 lines
- Zoom wiring lives in `Show-PreviewWindow` (search for
  `# Zoom controls`)
- XAML for the preview window is the `[xml]$xaml = @"..."@` block near
  the top of the function
- `Test-SnipIT.ps1` — pure-logic tests, runs on Linux/macOS pwsh too

### Debug logging

There's no active diagnostic logging in the current commit. If you want
to re-enable, the previously used pattern was:

```powershell
try {
    Add-Content -LiteralPath (Join-Path $env:TEMP 'snipit-trace.log') `
        -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $msg)
} catch {}
```

Put one line at every handler entry and inside `setZoom` to capture
`$layoutScale.ScaleX`, `$imageHost.ActualWidth`,
`$scroller.ExtentWidth`, and whatever variable is tracking the current
zoom.

### Commit history worth reviewing

- `a60fb1d` "fix: correct zoom architecture with LayoutTransform"
  — established the LayoutTransform-on-Grid approach
- `5c72912` "proper zoom via ScrollViewer + explicit ImageHost dimensions"
  — earlier attempt using explicit Width/Height (abandoned)
- `9e5e134` "fix: track zoom in Global scope; drop all diagnostic noise"
  — current state on main

## Architecture reminders

- `snipIT-Home/` sits next to the script. Holds `SnipIT.ps1`,
  `SnipIT.ico`, `.installed`, and `last-error.txt`. Install is
  idempotent — rewritten every launch.
- Single-instance mutex: `Local\SnipIT-SingleInstance-v1`
- Hotkeys: `Ctrl+Shift+S` smart, `Ctrl+Shift+F` full, `Ctrl+Shift+W`
  active window. Registered via `RegisterHotKey` on a hidden
  message-only Form.
- Annotations stored in image-pixel coordinates on `$state.Annotations`
  (ArrayList). Undo/redo via snapshot stacks. Canvas coordinates map
  1:1 to image pixels because the `LayoutTransform` only affects
  rendering, not local coord space.
