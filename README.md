<p align="center">
  <img src="docs/images/logo-128.png" alt="snipIT logo: a dashed selection frame with a pair of scissors" width="96">
</p>

<h1 align="center">snipIT — free screenshot and snipping tool for Windows 11</h1>

<p align="center"><strong>Capture. Annotate. Copy or save.</strong></p>

<p align="center">
  snipIT is a free, open source screenshot tool and snipping tool for Windows 11. Capture any window, region, or monitor, annotate with arrows, text, and numbered steps, blur sensitive information before you share it, then copy or save — one file, no installer, no telemetry.
</p>

<p align="center">
  <a href="https://github.com/RandomCodeSpace/snipIT/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/RandomCodeSpace/snipIT?display_name=tag&amp;label=release&amp;logo=github&amp;style=for-the-badge&amp;labelColor=000000&amp;color=4FD1E8&amp;logoColor=white"></a>
  <a href="https://github.com/RandomCodeSpace/snipIT/releases/latest"><img alt="Downloads" src="https://img.shields.io/github/downloads/RandomCodeSpace/snipIT/total?label=downloads&amp;logo=github&amp;style=for-the-badge&amp;labelColor=000000&amp;color=6F42C1&amp;logoColor=white"></a>
  <a href="https://github.com/RandomCodeSpace/snipIT/actions/workflows/test.yml"><img alt="Tests" src="https://img.shields.io/github/actions/workflow/status/RandomCodeSpace/snipIT/test.yml?branch=main&amp;label=tests&amp;logo=githubactions&amp;style=for-the-badge&amp;labelColor=000000&amp;logoColor=white"></a>
  <a href="https://github.com/RandomCodeSpace/snipIT/actions/workflows/security.yml"><img alt="Security" src="https://img.shields.io/github/actions/workflow/status/RandomCodeSpace/snipIT/security.yml?branch=main&amp;label=security&amp;logo=githubactions&amp;style=for-the-badge&amp;labelColor=000000&amp;logoColor=white"></a>
</p>

<p align="center">
  <a href="https://scorecard.dev/viewer/?uri=github.com/RandomCodeSpace/snipIT"><img alt="OpenSSF Scorecard" src="https://img.shields.io/ossf-scorecard/github.com/RandomCodeSpace/snipIT?label=scorecard&amp;logo=openssf&amp;style=for-the-badge&amp;labelColor=000000&amp;logoColor=white"></a>
  <a href="https://www.bestpractices.dev/projects/12647"><img alt="OpenSSF Best Practices" src="https://img.shields.io/cii/level/12647?label=OpenSSF&amp;logo=openssf&amp;style=for-the-badge&amp;labelColor=000000&amp;logoColor=white"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/RandomCodeSpace/snipIT?label=license&amp;logo=opensourceinitiative&amp;style=for-the-badge&amp;labelColor=000000&amp;color=2EA043&amp;logoColor=white"></a>
  <a href="#requirements"><img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D4?label=windows&amp;logo=windows11&amp;style=for-the-badge&amp;labelColor=000000&amp;color=0078D4&amp;logoColor=white"></a>
  <a href="#requirements"><img alt="PowerShell 7.5 or newer" src="https://img.shields.io/badge/PowerShell-7.5%2B-5391FE?label=powershell&amp;logo=powershell&amp;style=for-the-badge&amp;labelColor=000000&amp;color=5391FE&amp;logoColor=white"></a>
</p>

![The snipIT editor in its dark Darkroom look, annotating a sample analytics dashboard: top bar with Undo, Redo, Pin, Save and Copy and close, tool rail on the left, inspector on the right with the Rectangle tool selected](docs/images/snipit-preview.png)

<p align="center"><em>The snipIT editor on a made-up sample dashboard: a rectangle, an arrow, numbered steps, a blurred region and a text label, with the Rectangle tool's options in the inspector.</em></p>

## Why snipIT

- **Capture any way you like:** a window, a dragged region, the full desktop, the active window, a single monitor, or a delayed shot.
- **Annotate without touching the original:** highlight, draw rectangles, ellipses, arrows and lines, add text or numbered steps, sketch with a pen, blur or pixelate anything private — all non-destructive, all undoable.
- **Multi-monitor aware:** capture crosses displays cleanly and remembers which monitor you're working on.
- **Finish your way:** copy straight to the clipboard or save as PNG, JPEG, or BMP, to a default folder and format you choose.
- **One look, everywhere:** a fixed graphite-dark look with a cyan accent for the interface and coral for your annotations, the same on every PC whatever your Windows colour settings.
- **Remote-friendly:** inside a Remote Desktop or Citrix session, the capture overlay switches to a lighter mode so it stays responsive.
- **Private by design:** nothing leaves your PC, no admin rights, no installer, one file you can read end to end.

## Get started

1. Download `SnipIT.ps1` from the [latest release](https://github.com/RandomCodeSpace/snipIT/releases/latest).
2. Double-click the Desktop shortcut it creates the first time you run it (or just run the file once).
3. Press **Ctrl+Alt+Shift+Q** to capture.

snipIT quietly adds itself to the system tray and to sign-in startup so it's always a shortcut-press away. You can change the capture shortcut any time from the tray icon's **Settings**.

### Requirements

Windows 11 and [PowerShell 7.5 or newer](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows).

## Take a screenshot on Windows 11

Press `Ctrl+Alt+Shift+Q`, double-click the tray icon, or right-click it and choose a mode.

| Mode | What it does |
|---|---|
| Smart capture | Hover to grab a whole window, or drag to select a custom region |
| Full desktop | Grabs everything across all connected monitors |
| Active window | Captures whatever window is currently in front |
| Display | Pick one connected monitor by name from the tray menu |
| Delayed capture | Runs any of the above after a short delay, so you can set up the shot |

Press `Esc` any time to cancel.

<table>
  <tr>
    <td align="center"><img src="docs/images/tray-menu.png" alt="The snipIT tray menu in the dark theme, with an icon beside each item and the capture shortcut on the right"><br><em>Tray menu</em></td>
    <td align="center"><img src="docs/images/tray-display-submenu.png" alt="The snipIT tray menu with the Display submenu open, listing two connected monitors"><br><em>Display submenu</em></td>
  </tr>
</table>

The tray menu also opens **Settings** and **About**, toggles the optional top-edge capture widget (a small bar with Smart, Full and Window capture buttons and a Settings shortcut that appears when your pointer touches the top of the screen), and opens your snips folder.

Smart capture shows you exactly what you're about to grab: a cyan outline around the region or window, a size chip with the live dimensions, thin guide lines through the pointer, and a magnifier that shows the coordinates and hex colour of the pixel under the pointer. A hint at the bottom reminds you that you can drag a region, click a window, or press `Esc` to cancel. It works cleanly across every monitor you drag across.

<p align="center">
  <img src="docs/images/smart-capture-overlay.png" alt="The snipIT smart capture overlay dimming a sample dashboard, with a cyan selection outline, a size chip reading 460 x 270, guide lines and a magnifier showing the pixel coordinates and colour" width="760">
</p>

<p align="center"><em>Smart capture in progress on a made-up desktop — the size chip follows the region, and the magnifier zooms in on the exact pixel under the pointer.</em></p>

**Remote sessions.** When snipIT runs inside a Remote Desktop or Citrix session it detects that and switches the overlay to a lighter mode: the guide lines are off, the screen stays dimmed while you drag, and redraws are limited to what changed, so the overlay stays responsive over a slow connection. There is nothing to configure.

## Annotate a screenshot

Once you capture something, it opens straight into the editor.

![The snipIT editor with the Text tool selected: the inspector shows colour swatches, a size slider, Regular, Semibold and Bold weights, and a background plate option](docs/images/snipit-editor.png)

The editor has three parts around your capture:

- **Top bar:** the capture's name and size (and whether it has been saved), **Undo** and **Redo**, then **Pin**, **Save** and the highlighted **Copy and close** (`Ctrl+Enter`). The **…** menu at the far right holds Close, New snip, Duplicate and Delete.
- **Tool rail (left):** icon-only tools, each with its one-key shortcut letter in the corner. Hover a tool for its name.
- **Inspector (right):** the options for the active tool. Paired tools (Rectangle and Ellipse, Arrow and Line, Blur and Pixelate) get a shape choice at the top; the drawing tools have colour swatches (coral is the default mark colour), width or size, and opacity; Text adds size, weight (Regular, Semibold, Bold) and a background plate; Crop offers aspect presets with Apply and Reset; Steps shows the next number. Settings are remembered per tool.

The status bar at the bottom shows what the editor is doing, the pointer position over the image, and the zoom controls. The editor won't shrink below 1000 × 600.

| Tool | Key | What it does |
|---|---|---|
| Select | `V` | Pick an annotation to move, resize, duplicate, or delete it |
| Highlight | `H` | Mark up text or areas without hiding what's underneath |
| Rectangle | `R` | Draw a box around something |
| Ellipse | `E` | Draw an oval around something |
| Arrow | `A` | Point at something |
| Line | `L` | Connect two things |
| Text | `T` | Add a caption or label |
| Pen | `P` | Freehand drawing |
| Steps | `N` | Numbered badges that auto-increment, and renumber if you delete one |
| Blur | `B` | Hide anything sensitive before you share it |
| Pixelate | `X` | Hide anything sensitive with chunky pixels |
| Crop | `C` | Trim the capture down to just what matters |
| Undo / Redo | `Ctrl+Z` / `Ctrl+Shift+Z` | Step backward or forward through your edits (buttons in the top bar) |

Every annotation stays editable until you copy or save, so you can always change your mind.

### Blur sensitive information before sharing

Drag the Blur or Pixelate tool over a password field, an account number, a face, or anything else you don't want in the shared image. It obscures the actual pixels underneath — not a solid box — so the effect matches exactly between the on-screen preview and the file you copy or save.

## Save or copy a screenshot

- **Copy and close** (`Ctrl+Enter`) puts the finished image on your clipboard and closes the editor.
- **Copy and keep open** does the same but leaves the editor open (`Ctrl+C`, or right-click Copy and close and choose it).
- **Save** (`Ctrl+S`) opens a normal file dialog for PNG, JPEG, or BMP.
- **Pin** keeps the editor on top of other windows (`Alt+P`).
- The **…** menu at the right of the top bar has Close, New snip, Duplicate and Delete.
- If you applied a crop, both copy and save use the cropped result.
- Pick your default save folder and format once in **Settings**, and every save starts there.

Settings records your capture shortcut as keycaps (click the box and press the combination you want) and offers PNG, JPEG and BMP as a three-way switch.

<p align="center">
  <img src="docs/images/snipit-settings.png" alt="The snipIT Settings window: the capture shortcut shown as Ctrl, Alt, Shift and Q keycaps, a save folder field, a PNG, JPEG and BMP format switch with PNG selected, and startup options" width="484">
</p>

## Keyboard shortcuts for snipIT

| Shortcut | Action |
|---|---|
| `Ctrl+Alt+Shift+Q` | Smart capture (configurable in Settings) |
| `Esc` | Cancel capture, close an open menu, cancel a drag, deselect, switch back to Select, then close the editor |
| `Ctrl+Enter` | Copy and close |
| `Ctrl+C` / `Ctrl+Shift+C` | Copy and keep open |
| `Ctrl+S` | Save |
| `Ctrl+N` | Start a new Smart capture |
| `Alt+P` | Pin the editor on top |
| `V` `H` `R` `E` `A` `L` `T` `P` `N` `B` `X` `C` | Switch tool (see the tool table above) |
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |
| `Ctrl++` / `Ctrl+-` | Zoom in / out |
| `Ctrl+0` | Fit the image to the window |
| `Space` (held) | Pan around a zoomed-in image |
| `Delete` | Delete the selected annotation (with the canvas focused) |
| Arrow keys / `Shift`+Arrow keys | Nudge the selection by 1 / 10 pixels |

## Privacy

- snipIT has no telemetry, no analytics, and no cloud upload of any kind.
- Your screenshots go only to the clipboard or to a file you choose.
- It runs without administrator rights and doesn't install any background service.

## Good to know

- Only one snipIT can run per Windows sign-in at a time; opening it again just points you back to the running tray icon.
- It's a Windows-only app — there's no macOS or Linux build.

## Uninstall

Right-click the tray icon, choose **Uninstall**, and confirm. This removes the shortcuts and everything snipIT stored for itself, but never touches screenshots you've already saved elsewhere.

## FAQ

**Is snipIT free?** Yes — snipIT is free and open source under the MIT licence, with no ads, no paid tiers, and no account required.

**Does it need admin rights?** No — snipIT runs entirely in your user account and never asks for administrator privileges.

**Does it work with multiple monitors?** Yes — capture can span every connected display, and you can also target one specific monitor by name from the tray menu.

**Can it blur or pixelate parts of a screenshot?** Yes — the Blur and Pixelate tools obscure any dragged region, such as passwords or personal details, before you copy or save.

**Is it an alternative to the Windows Snipping Tool, ShareX, Greenshot, or Lightshot?** Yes — snipIT covers the same capture-annotate-share workflow in a single portable script, with no installer and no telemetry.

**Where do screenshots go?** Only where you send them — to the clipboard, or to a file in the folder and format you choose in Settings; snipIT never uploads anything anywhere.

## Support and contributing

Found a bug or have an idea? Open an [issue](https://github.com/RandomCodeSpace/snipIT/issues). Want to contribute code? Start with [CONTRIBUTING.md](CONTRIBUTING.md). Found a security problem? Please read [SECURITY.md](SECURITY.md) instead of filing a public issue. Curious what's changed release to release? Check the [CHANGELOG.md](CHANGELOG.md).

Licensed under [MIT](LICENSE).
