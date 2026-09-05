# Changelog

All notable changes to **snipIT** are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

snipIT ships as a single PowerShell script (`SnipIT.ps1`); there are no compiled binaries and no package-manager artifacts. Version numbers below correspond to git tags on `main`. Until the first tag lands, all merged work is collected under `[Unreleased]`. When a release is cut, the heading is replaced with the tag and date and a fresh `[Unreleased]` section opens at the top.

Each release MUST list any non-trivial security fixes under a dedicated **Security** subsection so downstream consumers can decide whether to upgrade. The disclosure / triage policy lives in [`SECURITY.md`](SECURITY.md).

---

## [Unreleased]

_No changes yet._

---

## [v0.2.0] - 2026-09-05

A complete redesign of the editor experience: every annotation tool is wired up and works end to end, the whole UI has been rebuilt on stock Windows Fluent in strict black-and-white with a single fixed red accent, capture is more reliable across multiple monitors and DPI settings, Copy/Save honour your crop, there's a new app logo, and development is back to a single file.

### Breaking
- The custom "Optical Bench" brand palette and hand-built theme have been removed. snipIT no longer paints its own colours: every window now follows the Windows Light or Dark app theme, with one fixed red accent (`#E81123`) used everywhere instead of your Windows accent colour.

### Added
**UI**
- Editor toolbars use Fluent glyph + label buttons, each with a working keyboard mnemonic.
- The action band shows a live capture size readout (`W × H px`), and the status bar shows a keyboard-shortcut hint (`Ctrl+Enter copy · Ctrl+S save · Esc close`).
- Every interactive control across the app now exposes a name and control type to assistive technology, verified with real UI Automation coverage.

**Editor tools**
- The full annotation tool band works end to end: Select, Highlight, Rectangle/Ellipse, Arrow/Line, Text, Pen, Steps, Blur/Pixelate, Crop, Undo and Redo.
- Split-button chevrons open real menus for the paired tools (Ellipse, Line, Pixelate); the same choice is also available from the property row.
- **Pen** draws a smooth freehand stroke.
- **Steps** places auto-incrementing numbered badges that renumber automatically when one is deleted or undone.
- **Blur** and **Pixelate** obscure a dragged region of the actual capture (not a solid box), matching exactly between the on-screen preview and the exported file.
- **Crop** is a full tool with Free / Original / 1:1 / 4:3 / 16:9 aspect presets, Apply and Reset.
- The property row shows live values instead of bare captions — a colour swatch, a width stepper, an opacity slider with a percentage readout, and a fill toggle — remembered per tool.

**Capture & multi-monitor**
- Smart capture shows the real pixels of the window or region you're about to capture, on every monitor it spans, instead of a dimmed approximation.
- The live selection-size chip is back, tracking your drag and repositioning itself so a monitor edge never clips it.
- The tray's **Display** submenu lists monitors by their real names instead of raw device paths, ordered primary-first, then left-to-right, top-to-bottom.
- A Smart capture overlay that receives no input for 20 seconds and has lost focus now cancels itself instead of leaving an unreachable overlay on screen.

**Installation & icon**
- A new snipIT logo (scissors in selection corners) ships embedded in the app and is used to build the taskbar/tray icon.

**Saving**
- Settings gained a **Default save format** picker (PNG / JPEG / BMP).

### Changed
**UI**
- Every window (Settings, About, the capture widget) now has a real Windows title bar — drag, snap, minimise and close it like any other app window — instead of a custom borderless header.
- Settings is a single scrolling column with clearly labelled Shortcut / Saving / Startup sections and a sticky footer for Save/Cancel.
- About is a compact info card: version, PowerShell/.NET runtime, your active shortcut, repository link and licence.
- The capture widget is a small standard tool window with **Smart** as the highlighted action.
- The tray menu and the Smart overlay's banner, size chip and loupe now use the same stock Windows look as the rest of the app.
- General editor polish: every tool has a hover tooltip, the toolbar can no longer be dragged apart, zoom controls use clearer +/- icons, and the coordinate readout no longer jitters.

**Development**
- Development is back to a single file. `SnipIT.ps1` is the only source of truth again — no build step, no generated `src/`/`xaml/` tree.

### Fixed
**Capture & multi-monitor**
- Per-monitor DPI awareness is now requested correctly at startup, fixing incorrect overlay scaling and positioning on displays running above 100% scaling.
- A capture spanning most of two or more monitors now opens its editor on the monitor under your pointer instead of always the largest display, and the editor window is properly centred instead of hugging the left edge of the screen.
- The tray's **Display** submenu opens again (a prior change had stopped it from populating).
- Smart capture's magnifier loupe actually magnifies now, instead of showing a 1:1 crop.

**Editor tools**
- Copy and Save honour your applied crop — previously the crop was preview-only and the full, uncropped image was exported.
- Arrow annotations draw a real, visible arrowhead consistently on screen and in exports.

**Saving**
- The Save dialog opens with your configured save folder and format instead of always defaulting to Pictures\Snips and PNG.
- `settings.json` is no longer rewritten on every launch when nothing has changed.

**Installation & icon**
- The app icon is a proper multi-resolution `.ico`, so the tray and taskbar show a crisp icon instead of a blurry downscale.
- Desktop and Start Menu shortcuts are no longer recreated on every launch, and the desktop icon updates immediately after an artwork change instead of showing a stale cached icon.
- A crash during startup or preview no longer leaves a ghost tray icon behind.

**UI**
- The preview window follows the Windows Light/Dark theme instead of always using light colours.

---

## [v0.1.1] - 2026-04-26

Capture-flow correctness release. No schema, workflow, or security changes from v0.1.0.

### Fixed
- Capture flow — exclude SnipIT's own widget / preview / tray windows from the capture target so they aren't baked into the frame. _The v0.1.0 release notes listed this fix prematurely; the change actually ships in v0.1.1._
- Full-screen and window capture — route `Invoke-FullScreenCapture` and `Invoke-WindowCapture` through `Invoke-CaptureLoop` with a per-iteration capture factory, so the preview owns / disposes each bitmap and the chrome-hide runs every snapshot. Fixes the use-after-dispose blank/crash on iteration 2+ of the same capture session.

### Security
- _No security-relevant fixes in v0.1.1._

---

## [v0.1.0] - 2026-04-26

First tagged release. Establishes the OpenSSF Best Practices `passing` baseline + supporting documentation surface for snipIT.

### Added
- OpenSSF Best Practices `passing` baseline ([PR #1](https://github.com/RandomCodeSpace/snipIT/pull/1)):
  - `.github/workflows/scorecard.yml` — `ossf/scorecard-action` on push to `main` + Mondays 06:00 UTC, SARIF → Security tab.
  - `.github/workflows/security.yml` — OSS-CLI security stack: Trivy filesystem scan, Semgrep (`p/security-audit` + `p/owasp-top-ten`), **PSScriptAnalyzer** (PowerShell language gate), Gitleaks full-history secret scan, jscpd duplication check, and SPDX + CycloneDX SBOM generation.
  - `.github/dependabot.yml` — weekly grouped GitHub Actions updates.
  - `SECURITY.md` — private vulnerability disclosure policy, supported versions, and scope.
  - `.bestpractices.json` — OpenSSF Best Practices self-assessment (project [12647](https://www.bestpractices.dev/en/projects/12647)).
  - Contributor brief covering build, test, run, conventions, and the OpenSSF Scorecard baseline + target.
  - PowerShell engineering standards — quality gates, code style, and CVE policy.
  - `scripts/setup-git-signed.sh` — one-shot signed-commit setup (SSH / OpenPGP / x509).
  - Branch protection on `main` — required signed commits, linear history, force-push and deletion blocked, eight required CI status checks.
  - Repo-level Dependabot security updates enabled.
- Canonical-schema rewrite of `.bestpractices.json` so the bestpractices.dev autofill robot can pre-fill the criteria page on board flip ([PR #3](https://github.com/RandomCodeSpace/snipIT/pull/3)).
- `CHANGELOG.md` (this file) — addresses the `release_notes` and `documentation_basics` gaps surfaced by the bestpractices.dev autofill audit ([PR #4](https://github.com/RandomCodeSpace/snipIT/pull/4) / [#5](https://github.com/RandomCodeSpace/snipIT/pull/5)).
- `CONTRIBUTING.md` at repo root — conventional contribution-process entry point: §Reporting (Issues + SECURITY.md), §Development workflow, §What every PR must pass (8-row CI gate matrix with local commands), §Coding standards ([PR #7](https://github.com/RandomCodeSpace/snipIT/pull/7)).

### Changed
- `.github/workflows/test.yml` — every action SHA-pinned (Scorecard `Pinned-Dependencies`); top-level `permissions: read-all`; PSScriptAnalyzer moved out into `security.yml` so the SAST/lint signals are co-located with the rest of the security stack.
- `README.md` — OpenSSF Best Practices, OpenSSF Scorecard, and Security workflow badges added at the top of the badge row; `Project files` table linked to `docs/`, `CHANGELOG.md`, `SECURITY.md`.
- `.bestpractices.json` — 5 SUGGESTED criteria flipped from `?` to `Met` with concrete in-repo evidence (`version_semver`, `version_tags`, `test_most`, `dynamic_analysis`, `dynamic_analysis_enable_assertions`) ([PR #6](https://github.com/RandomCodeSpace/snipIT/pull/6)); 4 `_url` fields retargeted to conventional paths (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`) so the bestpractices.dev autofill bot detects them ([PR #7](https://github.com/RandomCodeSpace/snipIT/pull/7)).

### Fixed
- Color-bar interaction — update the active swatch in-place instead of rebuilding the bar; close `$pickColor` over the swatch handler so the closure resolves correctly at click time.

> **Correction (2026-04-26):** the original v0.1.0 release notes also listed a `Capture flow — exclude SnipIT's own widget / preview / tray windows ...` line for the capture-target exclusion fix. That fix was not actually in the v0.1.0 tree (the commit was never pushed before the tag was cut); it ships in [v0.1.1](#v011---2026-04-26) instead. The v0.1.0 git tag annotation and GitHub Release body are immutable per OSPS evidence policy and have not been edited; this CHANGELOG entry is the authoritative record.

### Security
- _No security-relevant fixes shipped under v0.1.0._ The OSS-CLI security stack landed in `.github/workflows/security.yml` is the gating channel for all future fixes; advisories will appear in this section under each release where they apply, alongside a GHSA link.

---

[Unreleased]: https://github.com/RandomCodeSpace/snipIT/compare/v0.2.0...HEAD
[v0.2.0]: https://github.com/RandomCodeSpace/snipIT/releases/tag/v0.2.0
[v0.1.1]: https://github.com/RandomCodeSpace/snipIT/releases/tag/v0.1.1
[v0.1.0]: https://github.com/RandomCodeSpace/snipIT/releases/tag/v0.1.0
