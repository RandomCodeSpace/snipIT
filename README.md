# SnipIT

[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/12647/badge)](https://www.bestpractices.dev/en/projects/12647)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/RandomCodeSpace/snipIT/badge)](https://securityscorecards.dev/viewer/?uri=github.com/RandomCodeSpace/snipIT)
[![Security (OSS-CLI)](https://img.shields.io/github/actions/workflow/status/RandomCodeSpace/snipIT/security.yml?branch=main&label=Security%20%28OSS-CLI%29&logo=github)](https://github.com/RandomCodeSpace/snipIT/actions/workflows/security.yml)
[![PowerShell 7.5+](https://img.shields.io/badge/PowerShell-7.5%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![.NET 9](https://img.shields.io/badge/.NET-9-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Windows 11](https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-82%2F82%20passing-brightgreen)](#tests)
[![No Admin](https://img.shields.io/badge/admin-not%20required-success)](#install)
[![Single File](https://img.shields.io/badge/single%20file-yes-informational)](SnipIT.ps1)

A **professional snipping tool** for Windows 11 written in **pure PowerShell 7.5+** on **.NET 9**. Hover-to-highlight smart capture, magnifier loupe, floating widget, system tray, chromeless Fluent preview with a full annotation editor — all in a single script with **zero external dependencies** and **no admin elevation**.

## Features

### Capture

- **Smart capture** — hover any window to highlight it and click to grab, or drag for a custom region. One overlay, two gestures, with a **pixel-perfect magnifier loupe** and live screen-coordinate readout.
- **Full virtual-desktop capture** spanning all monitors (handles negative-origin layouts).
- **Active window capture** — grabs the foreground window by its exact window rect.
- **Per-monitor DPI aware** — accurate capture at 100 % / 125 % / 150 % / 200 %.

### Preview window

- **Chromeless Fluent UI** — WPF Fluent theme, Segoe Fluent Icons, draggable header, pin-on-top, resizable, maximizable.
- **Zoom** — Zoom In / Zoom Out / Fit-to-viewport buttons, `Ctrl + +`, `Ctrl + -`, `Ctrl + 0`, and **Ctrl + mouse-wheel** all work. Range 5 % – 1000 %. Live zoom indicator in the header.
- **Pan (Hand) mode** — the default when no annotation tool is selected: click and drag anywhere on the image to scroll a zoomed-in view. Cursor auto-switches between Hand and Cross.

### Annotations

- **Four annotation tools**: Highlight, Rectangle, Arrow, Text
- **Six-color palette** (yellow / green / pink / blue / orange / red) with live in-place color updates — change color while typing a text annotation and the foreground swaps immediately
- **Undo / Redo** with full history (`Ctrl+Z` / `Ctrl+Shift+Z`)
- **Right-click any annotation** to change its color or delete it
- **Clear all** button to wipe the annotation layer
- Annotations are stored in **image-pixel coordinates** so they survive zoom and export cleanly

### Output

- **Copy to clipboard** — flattened with all annotations baked in (`Ctrl+C`)
- **Save as** — PNG / JPG / BMP, default path `~\Pictures\Snips\snip-yyyyMMdd-HHmmss.png` (`Ctrl+S`)
- **New snip** — close the preview and start a fresh capture (`Ctrl+N`)

### System integration

- **System tray** with full menu (capture modes, open snips folder, about, uninstall, exit)
- **Floating capture widget** — auto-hiding top-center pill with Smart/Full/Window buttons
- **Global hotkeys** registered via `RegisterHotKey` on a hidden message-only form
- **Single-instance** enforced by a per-session named mutex; a second launch shows a friendly message instead of stacking up
- **Self-installing**: first launch copies itself to `snipIT-Home/` next to the script, creates a Desktop shortcut, and adds an Auto-Start shortcut to `shell:startup`. **No admin. No registry writes outside HKCU. No UAC prompts.**

## Hotkeys

### Global

| Hotkey | Action |
|---|---|
| `Ctrl+Shift+S` | Smart capture (hover-window or drag-region) |
| `Ctrl+Shift+F` | Full virtual-desktop capture |
| `Ctrl+Shift+W` | Active window capture |
| `Esc` / right-click | Cancel an active capture |

### Preview window

| Hotkey | Action |
|---|---|
| `Ctrl+C` | Copy flattened image to clipboard |
| `Ctrl+S` | Save as PNG / JPG / BMP |
| `Ctrl+N` | New snip |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / Redo |
| `Ctrl + +` / `Ctrl + -` | Zoom in / out |
| `Ctrl + 0` | Reset zoom to 100 % |
| `Ctrl + mouse-wheel` | Zoom centered on cursor |
| `Esc` | Close preview |

## Install

1. Make sure you have **PowerShell 7.5+** and **Windows 11** (`pwsh --version`)
2. Download `SnipIT.ps1`
3. Double-click it (or run `pwsh -Sta -File .\SnipIT.ps1`)

On first run SnipIT silently:
- Copies itself to `snipIT-Home\SnipIT.ps1` next to the source script
- Creates a Desktop shortcut
- Creates an Auto-Start shortcut in `shell:startup` (so it launches at login)
- Generates a `SnipIT.ico` on the fly
- Shows a tray balloon: *"SnipIT installed. Press Ctrl+Shift+S to capture."*

To **uninstall**: right-click the tray icon → *Uninstall*. Removes both shortcuts and the `snipIT-Home` folder.

## Usage

After installation, SnipIT runs in the system tray. Press `Ctrl+Shift+S`, hover the window you want, click. The preview window opens with the captured image. From there:

- **Annotate** — click a tool, pick a color, drag on the image. Click the active tool again (or `Esc`) to return to pan mode.
- **Zoom in to detail** — `Ctrl + mouse-wheel` or the zoom buttons; then drag the image to pan around.
- **Change an existing annotation** — right-click it to pick a new color or delete it.
- **Type a text annotation** — click the Text tool, click on the image, type, click a different color mid-typing to re-color live, press Enter to commit (or click elsewhere). Escape discards.
- **Copy or save** — `Ctrl+C` / `Ctrl+S`, or the toolbar buttons.
- **New snip** — `Ctrl+N` or the toolbar button to close the preview and drop straight back into the capture overlay.

## Architecture

Single file, organized into regions:

```
SnipIT.ps1
├── #region Core              ← pure logic, no UI/Win32 (testable cross-platform)
├── if ($CoreOnly) { return } ← unit-test gate
├── #region Bootstrap         ← STA self-relaunch, DPI, console hide, single-instance
├── #region PInvoke           ← Win32 signatures (RegisterHotKey, DWM, etc.)
├── #region Icon generation   ← Runtime .ico synthesis
├── #region First-Run Install ← Desktop + Startup shortcuts via WScript.Shell
├── #region Capture Core      ← GDI+ bitmap capture / clipboard / save dialog
├── #region Smart Overlay     ← WPF transparent overlay + hover + magnifier
├── #region Preview Window    ← Fluent preview + annotation editor
├── #region Capture Orchestration
├── #region Floating Widget   ← Auto-hiding top-center capsule
├── #region Tray + Hotkeys    ← NotifyIcon, ContextMenuStrip, RegisterHotKey
└── #region Main loop         ← WinForms message pump + cleanup
```

The `Core` region exports 10 pure functions: `Get-DragRectangle`, `Test-IsClickVsDrag`, `Get-LoupeSourceRect`, `Get-LoupePosition`, `Get-DefaultSnipFilename`, `Get-ImageFormatNameFromPath`, `Test-CaptureRectValid`, `Get-CropBounds`, `Get-InstallPaths`, `Get-ShortcutArguments`. None of them touch WPF, Win32, or the file system, so they run on Linux/macOS pwsh too.

### Preview-window internals

The preview window's mouse interaction, zoom, text-editing and color-picking are all organized as **named closures** captured at window-creation time (`$beginPan`, `$updatePan`, `$endPan`, `$beginDraw`, `$updateDraw`, `$finishDraw`, `$openText`, `$pickColor`, `$handleMouseDown`, `$setZoom`, `$zoomBy`, `$fitToViewport`). The real WPF event handlers are one-line wrappers that compute mouse positions and delegate to these closures. This keeps the event handlers trivial and — more importantly — gives the test harness a way to drive every code path without synthesizing real `MouseButtonEventArgs`.

`Show-PreviewWindow` accepts an optional `-TestAction [scriptblock]` parameter that runs the callback during `Loaded` (while `ShowDialog` is blocking, so function-local variables stay alive) and then closes the window off-screen. The interactive harness uses this to run 42 end-to-end tests against a headless preview window.

Setting the environment variable `SNIPIT_TEST_MODE=1` before dot-sourcing `SnipIT.ps1` short-circuits the single-instance mutex, tray setup, hotkey registration and main loop, so a harness can load the functions without side effects.

## Tests

**82 tests total**, two suites, both zero-dependency (no Pester):

```powershell
# 40 pure-logic unit tests (runs on any platform with pwsh)
pwsh -NoProfile -File .\Test-SnipIT.ps1

# 42 interactive WPF tests against a real Show-PreviewWindow (Windows only)
pwsh -NoProfile -Sta -File .\Test-SnipIT-Interactive.ps1
```

### `Test-SnipIT.ps1` (40)

Covers rectangle math, click-vs-drag thresholding, loupe clamping for negative-origin multi-monitor setups, filename + image-format derivation, capture-rect validation, install-path computation, and shortcut argument formatting. Dot-sources `SnipIT.ps1 -CoreOnly` so only the pure functions load.

### `Test-SnipIT-Interactive.ps1` (42)

Drives a real off-screen preview window via `-TestAction`. Coverage:

- **Zoom** — `SetZoom`, `ZoomBy`, compounded zoom, clamps (0.05 / 10), `ZoomText` update, `FitToViewport`
- **Pan** — default Hand cursor, drag → `Scroller` offset, `EndPan` cursor restore, no-op when not panning
- **Tool selection** — Highlight / Rect / Text interlock, cursor switching
- **Drawing** — highlight / rect / arrow with coord mapping at 1× and 2× zoom, short-arrow auto-discard
- **Colors** — all six palette entries applied to new annotations via `ActiveColor` and via `PickColor`
- **Undo / Redo**
- **Hit test** — `Find-AnnotationAt` topmost wins, outside returns -1
- **Flattening** — `Get-FlattenedBitmap` dimensions and type
- **Full click dispatch** via `HandleMouseDown` — pan / draft / text / out-of-bounds / editing-text branches
- **Text tool** — `OpenText` creates a TextBox; empty commit discards; typed commit appends annotation; live `PickColor` foreground swap during editing; `Render-Annotations` applies `annotation.Color` to the rendered TextBlock

## Project files

| File | Purpose |
|---|---|
| `SnipIT.ps1` | The whole app |
| `Test-SnipIT.ps1` | 40 unit tests, no dependencies |
| `Test-SnipIT-Interactive.ps1` | 42 WPF integration tests, no dependencies |
| `LICENSE` | MIT |

## Roadmap

- Scrolling / long-page capture
- Blur / pixelate annotation
- OCR via `Windows.Media.Ocr` — copy text from a snip
- Persisted preferences (rebindable hotkeys, default save folder, widget position)
- Capture-history gallery
- Drag-and-drop the snip out to other apps (Slack, Teams, file explorer)

## License

MIT — see [LICENSE](LICENSE).
