# Changelog

All notable changes to **snipIT** are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

snipIT ships as a single PowerShell script (`SnipIT.ps1`); there are no compiled binaries and no package-manager artifacts. Version numbers below correspond to git tags on `main`. Until the first tag lands, all merged work is collected under `[Unreleased]`. When a release is cut, the heading is replaced with the tag and date and a fresh `[Unreleased]` section opens at the top.

Each release MUST list any non-trivial security fixes under a dedicated **Security** subsection so downstream consumers can decide whether to upgrade. The disclosure / triage policy lives in [`SECURITY.md`](SECURITY.md).

---

## [Unreleased]

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
- `CHANGELOG.md` (this file) and `docs/README.md` index — addresses the `release_notes` and `documentation_basics` gaps surfaced by the bestpractices.dev autofill audit.

### Changed
- `.github/workflows/test.yml` — every action SHA-pinned (Scorecard `Pinned-Dependencies`); top-level `permissions: read-all`; PSScriptAnalyzer moved out into `security.yml` so the SAST/lint signals are co-located with the rest of the security stack.
- `README.md` — OpenSSF Best Practices, OpenSSF Scorecard, and Security workflow badges added at the top of the badge row.

### Fixed
- Capture flow — exclude SnipIT's own widget / preview / tray windows from the capture target so they aren't baked into the frame ([RAN-15](https://github.com/RandomCodeSpace/snipIT/issues)).
- Color-bar interaction — update the active swatch in-place instead of rebuilding the bar; close `$pickColor` over the swatch handler so the closure resolves correctly at click time.

### Security
- _No security-relevant fixes shipped yet under this release line._

---

[Unreleased]: https://github.com/RandomCodeSpace/snipIT/commits/main
