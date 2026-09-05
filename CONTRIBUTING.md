# Contributing to snipIT

Thanks for considering a contribution. snipIT is a Windows WPF application delivered as one PowerShell 7.5+ script on .NET 9. `SnipIT.ps1` is the only source file — edit it directly. There is no build step and no generated output.

## Running from source

```powershell
git clone https://github.com/RandomCodeSpace/snipIT.git
cd snipIT

# Run the app
pwsh -NoProfile -Sta -File ./SnipIT.ps1

# Cross-platform pure-logic tests
pwsh -NoProfile -File ./Test-SnipIT.ps1

# Cross-platform presentation and display-topology tests
pwsh -NoProfile -File ./Test-SnipIT-Presentation.ps1

# Windows STA integration suite
pwsh -NoProfile -Sta -File ./Test-SnipIT-Interactive.ps1
```

`SnipIT.ps1` is the single authoritative source — edit it directly. There is no build step, no code generation, and no companion source tree; every window's XAML is embedded in the script as a here-string. The first two test suites dot-source `SnipIT.ps1 -CoreOnly`, which loads the portable logic and returns before any Windows-only code loads.

## Reporting

- **Functional bugs and feature requests** — open a [GitHub Issue](https://github.com/RandomCodeSpace/snipIT/issues). Include your Windows + PowerShell + .NET versions and the shortest repro you can produce.
- **Security vulnerabilities** — do **not** open a public issue. Use the private channel documented in [`SECURITY.md`](SECURITY.md): a [GitHub private vulnerability report](https://github.com/RandomCodeSpace/snipIT/security/advisories/new) or `ak.nitrr13@gmail.com` with `[snipIT security]` in the subject. Disclosure SLA + scope are listed there.

## Development workflow

1. Fork and create a topic branch off `main` (e.g. `feat/window-shadow` or `fix/dpi-on-mixed-displays`).
2. Make focused, atomic commits in [Conventional Commits](https://www.conventionalcommits.org/) style (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, `test:`, `ci:`, `perf:`).
3. Sign every commit. Run `scripts/setup-git-signed.sh` once per worktree to apply repo-local signing config (SSH / OpenPGP / x509). Branch protection on `main` rejects unsigned commits.
4. Open a PR against `main`. Auto-merge fires when CI is green; no human merge button on the happy path.

`main` is the only protected branch. Direct pushes are blocked; squash-merge is the only allowed merge style; linear history is required.

## What every PR must pass

CI gates every PR on the following — please run them locally before requesting review. Each gate has zero tolerance:

| Gate | Local command | Where it lives |
|---|---|---|
| Every tracked script parses cleanly | `pwsh -c "[Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./SnipIT.ps1), [ref]$null, [ref]$null)"` | `.github/workflows/test.yml` |
| Portable core tests | `pwsh -NoProfile -File ./Test-SnipIT.ps1` | `.github/workflows/test.yml` |
| Presentation and topology tests | `pwsh -NoProfile -File ./Test-SnipIT-Presentation.ps1` | `.github/workflows/test.yml` |
| Complete Windows integration suite | `pwsh -NoProfile -Sta -File ./Test-SnipIT-Interactive.ps1` | `.github/workflows/test.yml` |
| **PSScriptAnalyzer** (PowerShell lint) | `pwsh -c "Invoke-ScriptAnalyzer -Path ./SnipIT.ps1 -Severity Error"` (0 errors) | `.github/workflows/security.yml` |
| Trivy filesystem scan | (CI only) | `.github/workflows/security.yml` |
| Semgrep SAST (`p/security-audit`, `p/owasp-top-ten`) | (CI only) | `.github/workflows/security.yml` |
| Gitleaks (full git history) | (CI only) | `.github/workflows/security.yml` |
| jscpd duplication < 3% (powershell, `--min-tokens 100`) | (CI only) | `.github/workflows/security.yml` |
| SBOM (SPDX + CycloneDX) | (CI only — surface only) | `.github/workflows/security.yml` |

## Coding standards (acceptable contributions)

The quality bar for this repo, in short: every commit on `main` is signed (run `scripts/setup-git-signed.sh` once per worktree) and follows [Conventional Commits](https://www.conventionalcommits.org/); code is PowerShell 7.5+ in `Verb-Noun` style with no PS5.1 fallbacks; new behaviour ships with at least one test where the logic is testable without a desktop session, and UI-only paths are called out in the PR; and the CI gates in the table above are hard gates with zero tolerance — a finding is fixed in the same PR or the merge is blocked. The most load-bearing rules:

- **PowerShell 7.5+ only.** No PS5.1 fallbacks, no `Add-Type` shims that only compile on Windows PowerShell.
- **Functions: `Verb-Noun` PascalCase**, [approved verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands), `[CmdletBinding()]` + `param()` for any function with > 1 parameter.
- **`SnipIT.ps1` is the single authoritative source.** Edit it directly — there is no generator, no build step, and no split sources to keep in sync. The XAML for every window lives inline in the script as here-strings.
- **Portable logic belongs above the `-CoreOnly` cut.** Pure algorithms live in the Core region and presentation / synthetic display-topology policy lives in the Presentation region; both sit ahead of the `if ($CoreOnly) { return }` guard. `-CoreOnly` must stay usable without loading WPF, Win32, or other Windows-only dependencies.
- **Preview-window event handlers are one-line wrappers** around named closures captured at window-creation time (e.g. `$beginPan`, `$pickColor`, `$handleMouseDown`) — keeps the test harness able to drive every code path through the closures via `-TestAction`.
- **Tests are zero-dependency** (no Pester). Follow the assertion pattern in `Test-SnipIT.ps1`.
- **The single-file distribution is a headline product feature.** `SnipIT.ps1` must stay portable: no runtime lookup of sibling files, repository paths, external modules, or network resources. A lone copy of `SnipIT.ps1` must run.

## Platform test boundaries

Linux with PowerShell 7.5.7 is the required portable development gate. Run the core suite and the presentation/topology suite shown above; both dot-source `SnipIT.ps1 -CoreOnly`, so a green run proves the portable region loads with no Windows runtime types. The Windows gate additionally AST-parses every tracked PowerShell script before running the suites.

The application runtime remains Windows-only. WPF and Win32 integration, the complete unfiltered interactive suite, and physical multi-display and mixed-DPI certification require Windows. A green Linux gate does not certify desktop integration or real monitor placement.

## What you'll need

- Linux + PowerShell 7.5.7 for the required portable development gate.
- Windows 11 + PowerShell 7.5.7 for full interactive testing (`Test-SnipIT-Interactive.ps1`) and physical display certification.
- A signed-commit setup. `scripts/setup-git-signed.sh` does the repo-local config; the script auto-detects ssh / openpgp / x509 from your global git config.

## Reviewing

A PR lands when:

1. All CI gates above are green (the protection rule on `main` enforces the required check contexts).
2. Codex / TechLead review pass shows no HIGH-severity findings.
3. The squash commit is signed (GitHub web-flow signing handles this automatically on merge).

For larger changes (new region in `SnipIT.ps1`, new top-level function group, new workflow file), open a brief proposal as a GitHub Issue first so we can align on shape before you sink hours into the PR.

## Documentation

- Update [`CHANGELOG.md`](CHANGELOG.md) `[Unreleased]` section with an entry under **Added** / **Changed** / **Fixed** / **Security** as appropriate.
- If your PR changes how to build/test/run, conventions, or introduces a new dependency, also update [`README.md`](README.md) — it is the documentation entry point.

## Release checklist

1. Bump the version referenced in the code and docs.
2. Cut the `[Unreleased]` section of [`CHANGELOG.md`](CHANGELOG.md) into a new dated `[vX.Y.Z]` section.
3. Tag `vX.Y.Z` on `main` to trigger the signed release workflow. Release titles follow `snipIT vX.Y.Z — <short benefit>`.
4. Refresh the README screenshots and the repo's About description if the UI or features changed.

Thanks again — the project is small, the test suite is fast, and your PR will get a reply quickly.
