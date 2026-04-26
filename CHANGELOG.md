# Changelog

All notable changes to **snipIT** are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

snipIT ships as a single PowerShell script (`SnipIT.ps1`); there are no compiled binaries and no package-manager artifacts. Version numbers below correspond to git tags on `main`. Until the first tag lands, all merged work is collected under `[Unreleased]`. When a release is cut, the heading is replaced with the tag and date and a fresh `[Unreleased]` section opens at the top.

Each release MUST list any non-trivial security fixes under a dedicated **Security** subsection so downstream consumers can decide whether to upgrade. The disclosure / triage policy lives in [`SECURITY.md`](SECURITY.md).

---

## [Unreleased]

_No changes yet._

---

## [v0.1.1] - 2026-04-26

Capture-flow correctness release. No schema, workflow, or security changes from v0.1.0.

### Fixed
- Capture flow — exclude SnipIT's own widget / preview / tray windows from the capture target so they aren't baked into the frame ([RAN-15](https://github.com/RandomCodeSpace/snipIT/issues)). _The v0.1.0 release notes listed this fix prematurely; the change actually ships in v0.1.1 (see [RAN-68](https://github.com/RandomCodeSpace/snipIT/issues))._
- Full-screen and window capture — route `Invoke-FullScreenCapture` and `Invoke-WindowCapture` through `Invoke-CaptureLoop` with a per-iteration capture factory, so the preview owns / disposes each bitmap and the chrome-hide runs every snapshot. Fixes the use-after-dispose blank/crash on iteration 2+ of the same capture session ([RAN-14](https://github.com/RandomCodeSpace/snipIT/issues)).

### Security
- _No security-relevant fixes in v0.1.1._

---

## [v0.1.0] - 2026-04-26

First tagged release. Establishes the OpenSSF Best Practices `passing` baseline + supporting documentation surface for snipIT.

### Added
- OpenSSF Best Practices `passing` baseline ([RAN-54](https://github.com/RandomCodeSpace/snipIT/pull/1)):
  - `.github/workflows/scorecard.yml` — `ossf/scorecard-action` on push to `main` + Mondays 06:00 UTC, SARIF → Security tab.
  - `.github/workflows/security.yml` — OSS-CLI security stack: Trivy filesystem scan, Semgrep (`p/security-audit` + `p/owasp-top-ten`), **PSScriptAnalyzer** (PowerShell language gate), Gitleaks full-history secret scan, jscpd duplication check, and SPDX + CycloneDX SBOM generation.
  - `.github/dependabot.yml` — weekly grouped GitHub Actions updates.
  - `SECURITY.md` — private vulnerability disclosure policy, supported versions, and scope.
  - `.bestpractices.json` — OpenSSF Best Practices self-assessment (project [12647](https://www.bestpractices.dev/en/projects/12647)).
  - `CLAUDE.md` — agent / contributor brief: build, test, run, conventions, OpenSSF Scorecard baseline + target.
  - `shared/runbooks/engineering-standards.md` — PowerShell variant of the company canonical engineering-standards runbook.
  - `scripts/setup-git-signed.sh` — one-shot signed-commit setup (SSH / OpenPGP / x509).
  - Branch protection on `main` — required signed commits, linear history, force-push and deletion blocked, eight required CI status checks.
  - Repo-level Dependabot security updates enabled.
- Canonical-schema rewrite of `.bestpractices.json` so the bestpractices.dev autofill robot can pre-fill the criteria page on board flip ([RAN-59](https://github.com/RandomCodeSpace/snipIT/pull/3)).
- `CHANGELOG.md` (this file) and `docs/README.md` index — addresses the `release_notes` and `documentation_basics` gaps surfaced by the bestpractices.dev autofill audit ([RAN-64](https://github.com/RandomCodeSpace/snipIT/pull/4) / [#5](https://github.com/RandomCodeSpace/snipIT/pull/5)).
- `CONTRIBUTING.md` at repo root — conventional contribution-process entry point: §Reporting (Issues + SECURITY.md), §Development workflow, §What every PR must pass (8-row CI gate matrix with local commands), §Coding standards delegating to `shared/runbooks/engineering-standards.md` ([PR #7](https://github.com/RandomCodeSpace/snipIT/pull/7)).

### Changed
- `.github/workflows/test.yml` — every action SHA-pinned (Scorecard `Pinned-Dependencies`); top-level `permissions: read-all`; PSScriptAnalyzer moved out into `security.yml` so the SAST/lint signals are co-located with the rest of the security stack.
- `README.md` — OpenSSF Best Practices, OpenSSF Scorecard, and Security workflow badges added at the top of the badge row; `Project files` table linked to `docs/`, `CHANGELOG.md`, `SECURITY.md`.
- `.bestpractices.json` — 5 SUGGESTED criteria flipped from `?` to `Met` with concrete in-repo evidence (`version_semver`, `version_tags`, `test_most`, `dynamic_analysis`, `dynamic_analysis_enable_assertions`) ([PR #6](https://github.com/RandomCodeSpace/snipIT/pull/6)); 4 `_url` fields retargeted to conventional paths (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`) so the bestpractices.dev autofill bot detects them ([PR #7](https://github.com/RandomCodeSpace/snipIT/pull/7)).

### Fixed
- Color-bar interaction — update the active swatch in-place instead of rebuilding the bar; close `$pickColor` over the swatch handler so the closure resolves correctly at click time.

> **Correction (2026-04-26):** the original v0.1.0 release notes also listed a `Capture flow — exclude SnipIT's own widget / preview / tray windows ...` line attributed to [RAN-15](https://github.com/RandomCodeSpace/snipIT/issues). That fix was not actually in the v0.1.0 tree (the commit was never pushed before the tag was cut); it ships in [v0.1.1](#v011---2026-04-26) instead. The v0.1.0 git tag annotation and GitHub Release body are immutable per OSPS evidence policy and have not been edited; this CHANGELOG entry is the authoritative record.

### Security
- _No security-relevant fixes shipped under v0.1.0._ The OSS-CLI security stack landed in `.github/workflows/security.yml` is the gating channel for all future fixes; advisories will appear in this section under each release where they apply, alongside a GHSA link.

---

[Unreleased]: https://github.com/RandomCodeSpace/snipIT/compare/v0.1.1...HEAD
[v0.1.1]: https://github.com/RandomCodeSpace/snipIT/releases/tag/v0.1.1
[v0.1.0]: https://github.com/RandomCodeSpace/snipIT/releases/tag/v0.1.0
