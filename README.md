# SnipIT

[![PowerShell 7.5+](https://img.shields.io/badge/PowerShell-7.5%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![.NET 9](https://img.shields.io/badge/.NET-9-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Windows 11](https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-40%2F40%20passing-brightgreen)](Test-SnipIT.ps1)
[![No Admin](https://img.shields.io/badge/admin-not%20required-success)](#install)
[![Single File](https://img.shields.io/badge/single%20file-yes-informational)](SnipIT.ps1)

A **Snagit-style snipping tool** for Windows 11 written in **pure PowerShell 7.5+** on **.NET 9**. Hover-to-highlight smart capture, magnifier loupe, floating widget, system tray, native Fluent UI — all in a single script with **zero external dependencies** and **no admin elevation**.

## Features

- **Smart capture** — hover any window to highlight it and click to grab, or drag for a custom region. One overlay, two gestures.
- **Pixel-perfect magnifier loupe** with crosshair and live screen-coord readout
- **Full virtual-desktop capture** spanning all monitors
- **Floating capture widget** — auto-hiding top-center pill (Snagit-style)
- **System tray** with full menu (modes, snips folder, about, uninstall, exit)
- **Native Fluent UI** via .NET 9 WPF Fluent theme + Mica backdrop + Segoe Fluent Icons
- **Per-monitor DPI aware** — accurate capture at 100 % / 125 % / 150 % / 200 %
- **Self-installing**: first launch creates a Desktop shortcut and an Auto-Start entry under `shell:startup`. **No admin. No registry writes outside HKCU. No UAC prompts.**
- **One file** (`SnipIT.ps1`) with logic separated into a top-of-file `Core` region; **40 unit tests** in `Test-SnipIT.ps1`

## Hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl+Shift+S` | Smart capture (hover-window or drag-region) |
| `Ctrl+Shift+F` | Full virtual-desktop capture |
| `Esc` / right-click | Cancel an active capture |

## Install

1. Make sure you have **PowerShell 7.5+** and **Windows 11** (`pwsh --version`)
2. Download `SnipIT.ps1`
3. Double-click it (or run `pwsh -Sta -File .\SnipIT.ps1`)

On first run SnipIT silently:
- Copies itself to `%LOCALAPPDATA%\SnipIT\SnipIT.ps1`
- Creates a Desktop shortcut
- Creates an Auto-Start shortcut in `shell:startup` (so it launches at login)
- Shows a tray balloon: *"SnipIT installed. Press Ctrl+Shift+S to capture."*

To **uninstall**: right-click the tray icon → *Uninstall*. Removes both shortcuts and the AppData folder.

## Usage

After installation, SnipIT runs in the system tray. Press `Ctrl+Shift+S`, hover the window you want, click. The preview opens — **Copy** to clipboard, **Save** as PNG/JPG/BMP (defaults to `~\Pictures\Snips\snip-yyyyMMdd-HHmmss.png`), **New snip**, or **Close**.

## Architecture

Single file, organized into regions:

```
SnipIT.ps1
├── #region Core              ← pure logic, no UI/Win32 (testable cross-platform)
├── if ($CoreOnly) { return } ← test gate
├── #region Bootstrap         ← STA self-relaunch, DPI awareness, console hide
├── #region PInvoke           ← Win32 signatures (RegisterHotKey, DWM, etc.)
├── #region First-Run Install ← Desktop + Startup shortcuts via WScript.Shell
├── #region Capture Core      ← GDI+ bitmap capture / clipboard / save dialog
├── #region Smart Overlay     ← WPF transparent overlay + hover + magnifier
├── #region Preview Window    ← Fluent preview with toolbar
├── #region Floating Widget   ← Auto-hiding top-center capsule
└── #region Tray + Hotkeys    ← NotifyIcon, ContextMenuStrip, RegisterHotKey loop
```

The `Core` region exports 10 pure functions: `Get-DragRectangle`, `Test-IsClickVsDrag`, `Get-LoupeSourceRect`, `Get-LoupePosition`, `Get-DefaultSnipFilename`, `Get-ImageFormatNameFromPath`, `Test-CaptureRectValid`, `Get-CropBounds`, `Get-InstallPaths`, `Get-ShortcutArguments`. None of them touch WPF, Win32, or the file system — so they run on Linux pwsh too.

## Tests

40 unit tests covering rectangle math, click-vs-drag, loupe clamping for negative-origin multi-monitor setups, filename and image-format derivation, capture-rect validation, install path computation, and shortcut argument formatting.

```powershell
pwsh -NoProfile -File .\Test-SnipIT.ps1
```

The test script dot-sources `SnipIT.ps1 -CoreOnly`, which loads only the pure functions and returns before any Windows-only bootstrap code runs. **No Pester required.**

## Project files

| File | Purpose |
|---|---|
| `SnipIT.ps1` | The whole app |
| `Test-SnipIT.ps1` | 40 unit tests, no dependencies |
| `mockup.html` | Visual mockup of the three UI surfaces |
| `LICENSE` | MIT |

## Roadmap (v2)

- Annotation editor (arrow / box / text / blur)
- Scrolling capture
- OCR via `Windows.Media.Ocr`
- Persisted preferences (rebindable hotkeys, widget position)
- Capture-history gallery

## License

MIT — see [LICENSE](LICENSE).
