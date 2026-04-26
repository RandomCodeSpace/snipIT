# snipIT — Agent brief

Read this at session start. It is the standing context for any agent touching this repo.

## What it is

A **professional snipping tool** for Windows 11 written in **pure PowerShell 7.5+** on **.NET 9**. Smart hover-to-highlight capture, magnifier loupe, floating widget, system tray, chromeless WPF Fluent preview with a full annotation editor — **single script, zero external runtime dependencies, no admin elevation**.

The single-file shape (`SnipIT.ps1`) is a **headline product feature** — do not split it into modules without explicit board reversal.

## Repo layout

```
SnipIT.ps1                       113K   the whole app (regions: Core / Bootstrap / PInvoke / Capture / Preview / Tray / Main)
Test-SnipIT.ps1                   29K   40 pure-logic unit tests (Linux + Windows pwsh, no Pester)
Test-SnipIT-Interactive.ps1       26K   42 WPF integration tests against a real off-screen preview window (Windows only)
README.md                              install / hotkeys / usage / architecture (also: badges)
SECURITY.md                            disclosure policy + scope
LICENSE                                MIT — Amit Kumar
CLAUDE.md                              this file
.bestpractices.json                    OpenSSF Best Practices self-assessment (project_id 12647)
shared/runbooks/engineering-standards.md   PowerShell variant of the company runbook
scripts/setup-git-signed.sh            one-shot signed-commit setup for a fresh worktree
docs/                                  design notes + screenshots
.github/
├── workflows/
│   ├── test.yml                       headless tests (Linux + Windows) + Windows AST parse
│   ├── security.yml                   OSS-CLI stack: PSScriptAnalyzer · Trivy · Semgrep · Gitleaks · jscpd · SBOM
│   └── scorecard.yml                  OpenSSF Scorecard (push to main + Mondays 06:00 UTC)
└── dependabot.yml                     github-actions ecosystem, weekly, grouped
```

## Build / test / run

snipIT has no compile or package step — `SnipIT.ps1` *is* the deliverable.

| Action | Command |
|---|---|
| Run the app | `pwsh -Sta -File ./SnipIT.ps1` (Windows; double-click also works) |
| Headless unit tests (any platform) | `pwsh -NoProfile -File ./Test-SnipIT.ps1` |
| Interactive WPF tests (Windows only) | `pwsh -NoProfile -Sta -File ./Test-SnipIT-Interactive.ps1` |
| PSScriptAnalyzer (lint) | `pwsh -c "Invoke-ScriptAnalyzer -Path ./SnipIT.ps1 -Severity Error"` |
| Parse-only (Windows) | `pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./SnipIT.ps1), [ref]\$null, [ref]\$errors)"` |

CI runs the same matrix on every PR (see `.github/workflows/test.yml`).

## Conventions

- **PowerShell 7.5+ only.** No PS5.1 fallbacks, no `Add-Type` shims that only compile on Windows PowerShell.
- Functions: `Verb-Noun` PascalCase, [approved verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands), `[CmdletBinding()]` + `param()` for anything > 1 arg.
- The `Core` region exports 10 pure functions designed to run on Linux pwsh. Adding a new pure helper? Put it in `Core` so the test suite picks it up via `-CoreOnly`.
- Preview-window mouse handlers are **named closures** captured at window-creation time (see `Build-PreviewWindow` and the closures `$beginPan`, `$pickColor`, `$handleMouseDown`, …). The real WPF event handlers are one-line wrappers that call them. Tests drive every code path through these closures via the `-TestAction` hook on `Show-PreviewWindow`.
- `SNIPIT_TEST_MODE=1` short-circuits the single-instance mutex, tray, hotkeys, and main loop so a harness can dot-source `SnipIT.ps1` without side effects.
- All commits on `main` are **signed** (SSH key, registered as both auth + signing key on GitHub). Run `scripts/setup-git-signed.sh` once per worktree.

## Engineering standards

The repo follows `shared/runbooks/engineering-standards.md` (PowerShell variant of the company canonical at `/home/dev/.paperclip/instances/default/companies/31b9e445-1e14-45b6-9457-cfbb5cb17144/shared/runbooks/engineering-standards.md`). TL;DR:

- Quality gates that block merge: tests, AST parse, **PSScriptAnalyzer Error**, **Trivy HIGH/CRITICAL**, **Semgrep ERROR**, **Gitleaks**, **jscpd < 3%**, **signed commits**.
- Surfaces only (do not block merge): SBOM, OpenSSF Scorecard score, Dependabot PRs.
- **OSS-CLI only.** No Sonar, no CodeQL, no NVD-direct tools (no PowerShell pack for CodeQL today; Semgrep + PSScriptAnalyzer cover SAST + lint).

## OpenSSF Scorecard — baseline + target

| Aspect | Value |
|---|---|
| **Workflow** | `.github/workflows/scorecard.yml` (push to `main` + weekly Mondays 06:00 UTC + manual dispatch) |
| **Engine** | `ossf/scorecard-action@v2.4.3` (SHA-pinned to `4eaacf0543bb3f2c246792bd56e8cdeffafb205a`) |
| **Output** | SARIF → GitHub Security tab + public dashboard at <https://securityscorecards.dev/viewer/?uri=github.com/RandomCodeSpace/snipIT> |
| **Baseline (RAN-54 land)** | TBD — first scoreboard score will land on the first push to `main` after this PR merges. Recorded here in the next PR that touches CLAUDE.md. |
| **Target** | **Best-effort, do not regress.** Stretch ≥ 8.0 / 10. **Best Practices `passing` is the only OpenSSF gate that blocks merge** — Scorecard is observational. (Per `shared/runbooks/engineering-standards.md` §1 and the company runbook §9b.) |
| **Configured-for-pass checks (RAN-54 bootstrap)** | Branch-Protection (per §7), Code-Review (TechLead via Codex), Signed-Releases (`tag.gpgsign=true`), Dependency-Update-Tool (Dependabot, weekly, grouped), Pinned-Dependencies (every action SHA-pinned), CI-Tests (test.yml + security.yml required), CII-Best-Practices (`.bestpractices.json` + project 12647), Dangerous-Workflow (no `pull_request_target` + untrusted-checkout), License (MIT at root), Maintained (active commit cadence), Packaging (no public binary publish — script is the package), SAST (Semgrep + PSScriptAnalyzer), Security-Policy (`SECURITY.md`), Token-Permissions (`permissions: read-all` top-level), Vulnerabilities (Trivy gate), Webhooks (none configured). |
| **Known not-a-pass (and why)** | Packaging — snipIT does not publish a versioned binary artifact (the script is the deliverable; `git clone` + run is the install path). Scorecard's `Packaging` check looks for a published-via-CI release; absent here by design until a tagged-release flow is added. |

A **material** Scorecard regression on a PR files a follow-up chore (`type:chore`, `area:security`); it does **not** block the PR.

## OpenSSF Best Practices

- Project page: <https://www.bestpractices.dev/en/projects/12647>.
- In-repo self-assessment: `.bestpractices.json` (project_id 12647, target `passing`).
- **`passing` is the only OpenSSF gate that blocks merge.** Any PR that would fail a passing-level criterion is blocked at review.

## Live integrations

- GitHub repo: <https://github.com/RandomCodeSpace/snipIT> (public, MIT, secret-scanning + push-protection on).
- Paperclip Project: `snipIT` (id `e6a01833-e7df-4068-849c-6a7c5154b70c`).
- Paperclip parent issue: [RAN-50](/RAN/issues/RAN-50) — OpenSSF rollout across all 5 paperclip projects.

## Gotchas

- **Capture loop ownership.** `Invoke-CaptureLoop` (RAN-14 contract) takes ownership of each captured `System.Drawing.Bitmap` — the preview disposes it on close, the loop creates a fresh one for each iteration via the `CaptureFactory` closure. Do not dispose the bitmap inside the factory or pre-allocate one outside the loop.
- **SnipIT-window exclusion in capture.** The RAN-15 fix (shipped in v0.1.1) excludes the SnipIT widget / preview / tray windows from the capture targets. If you add a new top-level window, register it via `Hide-OwnSnipITWindowsForCapture` so it's not baked into the frame.
- **Per-monitor DPI.** Capture math is DPI-aware on virtual desktops with mixed scaling. Negative-origin layouts (monitor to the left of the primary) are handled in `Get-VirtualScreenBounds`; do not assume `(0,0)` is the top-left of the virtual desktop.
- **Single-instance mutex.** A second launch shows a friendly notification and exits — *unless* `SNIPIT_TEST_MODE=1` is set (test-harness escape hatch).
- **`actions/checkout@v4` vs SHA-pin.** Workflows in this repo MUST pin every action by commit SHA (Scorecard `Pinned-Dependencies`). Dependabot opens routine bumps; do not manually downgrade to a tag-ref.

## Issue tracker

Paperclip. Issue prefix `RAN` (e.g., RAN-54 — this OpenSSF land). Link tickets as `[RAN-XX](/RAN/issues/RAN-XX)` in PR descriptions and code comments.
