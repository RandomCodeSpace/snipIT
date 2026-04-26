# Contributing to snipIT

Thanks for considering a contribution. snipIT is a single-script PowerShell 7.5+ tool on .NET 9 — the deliverable is `SnipIT.ps1`. There is no compile step; `git clone` + `pwsh -Sta -File .\SnipIT.ps1` is the install path.

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
| Headless tests | `pwsh -NoProfile -File ./Test-SnipIT.ps1` (84/84 must pass) | `.github/workflows/test.yml` |
| Windows AST parse | `pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./SnipIT.ps1), [ref]\$null, [ref]\$errors)"` | `.github/workflows/test.yml` |
| **PSScriptAnalyzer** (PowerShell lint) | `pwsh -c "Invoke-ScriptAnalyzer -Path ./SnipIT.ps1 -Severity Error"` (0 errors) | `.github/workflows/security.yml` |
| Trivy filesystem scan | (CI only) | `.github/workflows/security.yml` |
| Semgrep SAST (`p/security-audit`, `p/owasp-top-ten`) | (CI only) | `.github/workflows/security.yml` |
| Gitleaks (full git history) | (CI only) | `.github/workflows/security.yml` |
| jscpd duplication < 3% (powershell, `--min-tokens 100`) | (CI only) | `.github/workflows/security.yml` |
| SBOM (SPDX + CycloneDX) | (CI only — surface only) | `.github/workflows/security.yml` |

## Coding standards (acceptable contributions)

The full quality bar — quality gates, code style, branch/commit/PR rules, security tooling, performance targets — is codified in [`shared/runbooks/engineering-standards.md`](shared/runbooks/engineering-standards.md), the PowerShell variant of the company-canonical runbook. Treat that file as the single source of truth for what is acceptable in this repo. The most load-bearing rules:

- **PowerShell 7.5+ only.** No PS5.1 fallbacks, no `Add-Type` shims that only compile on Windows PowerShell.
- **Functions: `Verb-Noun` PascalCase**, [approved verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands), `[CmdletBinding()]` + `param()` for any function with > 1 parameter.
- **Pure-logic functions go in the `Core` region** of `SnipIT.ps1` so the headless test suite picks them up via `-CoreOnly`.
- **Preview-window event handlers are one-line wrappers** around named closures captured at window-creation time (e.g. `$beginPan`, `$pickColor`, `$handleMouseDown`) — keeps the test harness able to drive every code path through the closures via `-TestAction`.
- **Tests are zero-dependency** (no Pester). Follow the assertion pattern in `Test-SnipIT.ps1`.
- **Single-file deliverable is a headline product feature.** Do not propose splitting `SnipIT.ps1` into modules without an explicit board reversal.

## What you'll need

- Windows 11 + PowerShell 7.5+ for full interactive testing (`Test-SnipIT-Interactive.ps1`).
- Any pwsh 7.5+ host (Linux / macOS work) for headless tests.
- A signed-commit setup. `scripts/setup-git-signed.sh` does the repo-local config; the script auto-detects ssh / openpgp / x509 from your global git config.

## Reviewing

A PR lands when:

1. All CI gates above are green (the protection rule on `main` enforces eight required check contexts).
2. Codex / TechLead review pass shows no HIGH-severity findings.
3. The squash commit is signed (GitHub web-flow signing handles this automatically on merge).

For larger changes (new region in `SnipIT.ps1`, new top-level function group, new workflow file), open a brief proposal as a GitHub Issue first so we can align on shape before you sink hours into the PR.

## Documentation

- Update [`CHANGELOG.md`](CHANGELOG.md) `[Unreleased]` section with an entry under **Added** / **Changed** / **Fixed** / **Security** as appropriate.
- If your PR changes how to build/test/run, conventions, gotchas, or introduces a new dependency, also update [`CLAUDE.md`](CLAUDE.md). It is the agent / contributor brief read at session start.
- Long-form docs go under [`docs/`](docs/README.md).

Thanks again — the project is small, the test suite is fast, and your PR will get a reply quickly.
