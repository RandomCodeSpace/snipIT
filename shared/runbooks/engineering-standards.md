# Engineering Standards — snipIT

PowerShell variant of the company runbook (`/home/dev/.paperclip/instances/default/companies/31b9e445-1e14-45b6-9457-cfbb5cb17144/shared/runbooks/engineering-standards.md`). Adapts the OSS-CLI tooling stack for a single-file PowerShell 7.5+ project on .NET 9; everything else is inherited from the canonical runbook.

- **Policy owner:** TechLead.
- **Producers:** anyone landing PRs on `main`.
- **Reviewers:** TechLead (Codex pass) + CI gates.

If a CI gate enforces it, the engineer fixes — do not lower the gate.

---

## 1. Quality gates (hard / non-negotiable)

| Gate | Threshold | Where it runs | Failure action |
|---|---|---|---|
| Headless tests (`Test-SnipIT.ps1`) | All pass on Linux + Windows runners | `.github/workflows/test.yml` | Block merge |
| Script parses cleanly (Windows AST) | 0 parser errors | `.github/workflows/test.yml` (`parse` job) | Block merge |
| **PSScriptAnalyzer (PowerShell lint)** | **Zero `Error`-severity findings on `SnipIT.ps1`** | `.github/workflows/security.yml` (`psscriptanalyzer` job) | Block merge |
| Trivy (filesystem scan) | Zero High/Critical findings (`severity: HIGH,CRITICAL`, `exit-code: 1`) | `.github/workflows/security.yml` | Block merge |
| Semgrep (SAST) | Zero ERROR-level findings on `p/security-audit` + `p/owasp-top-ten` | `.github/workflows/security.yml` | Block merge |
| Gitleaks (secret scan, full git history) | Zero findings | `.github/workflows/security.yml` | Block merge |
| jscpd (duplication) | < 3% on production code (`SnipIT.ps1`) | `.github/workflows/security.yml` | Block merge |
| SBOM (SPDX + CycloneDX) | Generated and uploaded as build artifact (`anchore/sbom-action`) | `.github/workflows/security.yml` | Surface as artifact; do **not** gate merge |
| Dependabot (GitHub Actions ecosystem) | Surfaces advisories on `.github/workflows/*` actions pinning | `.github/dependabot.yml` + repo Security tab | Surface; auto-PRs gated by separate review |
| OpenSSF Scorecard | Best-effort; no hard score floor; `Pinned-Dependencies` is a soft target | `.github/workflows/scorecard.yml` (push to `main` + weekly) | Surface in security tab; do **not** gate merge |
| Signed commits | Every commit on `main` must verify | Branch protection + `scripts/setup-git-signed.sh` | Block merge |

**Stack: OSS-CLI only.** Per the company runbook (path B): no Sonar, no CodeQL, no NVD-direct tools. The OSS-CLI stack covers the same ground without those issues; cost is $0 in GitHub Actions for public OSS.

**No SCA against a lockfile.** snipIT is a single `.ps1` script with **zero external runtime dependencies** — no npm / Maven / pip / NuGet manifest, so the OSV-Scanner job from the codeiq reference is intentionally **omitted**. Trivy filesystem scan covers any future deps; Dependabot covers the GitHub Actions ecosystem (the only versioned deps in the repo today).

## 2. Code style

- Pure PowerShell 7.5+ on .NET 9. No PowerShell 5.1 fallbacks; no `Add-Type` stubs that only work on Windows PowerShell.
- Functions follow `Verb-Noun` PascalCase per [PowerShell approved verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).
- Use `[CmdletBinding()]` + `param()` blocks for any function with > 1 parameter. Mandatory parameters declared explicitly.
- Strict mode: scripts that should run under `Set-StrictMode -Version Latest` declare it at top of scope.
- Single-file deliverable is a **headline feature** of snipIT — do not split `SnipIT.ps1` into modules without an explicit board reversal.

## 3. Branch, commit, PR rules

- See company runbook §7 (branch protection) and §8 (signed commits). All commits on `main` are signed; force-push and direct-push to `main` are disabled; squash-merge is the only allowed merge style.
- Run `scripts/setup-git-signed.sh` once per worktree to apply the local git config. The script honours your existing global signing setup (ssh / openpgp / x509).

## 4. Testing tiers

- **Headless** — `Test-SnipIT.ps1` runs pure-logic tests (no UI / WPF / hotkey registration). Gated in CI on Linux + Windows runners.
- **Interactive** — `Test-SnipIT-Interactive.ps1` exercises preview-window + capture flows. Run locally on Windows; not in CI.
- New behaviour ships with at least one headless test where the logic is testable without a desktop session. UI-only paths are documented in `README.md` under `Tests`.

## 5. Security

### 5.1 Tooling stack — OSS-CLI ONLY (PowerShell variant)

| Concern | Tool | Where |
|---|---|---|
| PowerShell lint | **PSScriptAnalyzer** (`Invoke-ScriptAnalyzer -Severity Error`) | `.github/workflows/security.yml` |
| Filesystem CVE scan | **Trivy** filesystem scan (HIGH / CRITICAL gating) | `.github/workflows/security.yml` |
| SAST | **Semgrep** (`p/security-audit`, `p/owasp-top-ten`) | `.github/workflows/security.yml` |
| Secret scan | **Gitleaks** (full git history) | `.github/workflows/security.yml` |
| Duplication | **jscpd** (PowerShell, threshold < 3%, `--min-tokens 100`) | `.github/workflows/security.yml` |
| SBOM | **`anchore/sbom-action`** (SPDX + CycloneDX) | `.github/workflows/security.yml` |
| Dependency updates | **Dependabot** (GitHub Actions ecosystem, weekly, grouped) | `.github/dependabot.yml` |
| Supply-chain score | **OpenSSF Scorecard** (`ossf/scorecard-action`, push + weekly) | `.github/workflows/scorecard.yml` |

**Not used (do not re-introduce without an explicit board reversal):** SonarCloud / SonarQube, CodeQL (no PowerShell pack today; Semgrep + PSScriptAnalyzer cover the SAST + lint surface), OSV-Scanner (no lockfile to scan), OWASP Dependency-Check (NVD-direct).

### 5.2 Code hygiene

- **P/Invoke surface** — every `Add-Type @"…"@` block that imports `user32.dll` / `gdi32.dll` / `kernel32.dll` is reviewed for input-handle validation; never pass user-controlled HWNDs without owner-check.
- **Path handling** — anything that takes a user-supplied save path (e.g. the file-save dialog handler) goes through `Resolve-Path` + canonical-form check before write.
- **Secrets** — never in code, config, or commit history. Gitleaks runs full-history.
- **CVE policy** — High/Critical → block; Medium → fix if a patched version exists, else document non-exploitability with TechLead sign-off; Low → tracked in the next dependency-bump cycle.
- **Vulnerability reporting** — see [`/SECURITY.md`](../../SECURITY.md). Private disclosure only.

## 6. Performance

- Capture path target: end-to-end snip (key-press → preview window painted) **< 250 ms** on a clean Windows 11 desktop. Measure with `Measure-Command` around `Invoke-FullScreenCapture` / `Invoke-WindowCapture`; do not regress.
- Preview window: zoom / pan / annotation hit-test ≤ **16 ms** per frame (60 fps target on a 4K monitor).
- No unbounded buffers: capture pipeline disposes `System.Drawing.Bitmap` instances on every iteration of `Invoke-CaptureLoop`; the preview takes ownership and disposes on close (RAN-14 contract).

## 7. Build & distribution

- snipIT is a single `.ps1` — there is no compile / package step. The deliverable is the script in the repo.
- Install flow generates a runtime install home next to the script (icon + cached copy + `last-error.txt`). Documented in `README.md` under `Install`. The install flow is the only on-disk side-effect outside the user's chosen save path.
- No public-CDN runtime fetches, no auto-update phone-home, no telemetry.
- GitHub Actions are pinned by commit SHA in every workflow. Rationale: OpenSSF Scorecard `Pinned-Dependencies` and supply-chain integrity.

## 8. Documentation

- `README.md` — install, hotkeys, usage, architecture overview, badges.
- `CLAUDE.md` — agent brief: architecture, build/test/run commands, conventions, gotchas, **OpenSSF Scorecard baseline + target**.
- `SECURITY.md` — disclosure policy, supported versions, scope.
- `docs/` — design notes, screenshots, mock-ups.
- `shared/runbooks/engineering-standards.md` — this file (the PowerShell variant of the company runbook).

## 9. References

- Company canonical runbook: `/home/dev/.paperclip/instances/default/companies/31b9e445-1e14-45b6-9457-cfbb5cb17144/shared/runbooks/engineering-standards.md`.
- `/CLAUDE.md` — architecture and conventions.
- `/SECURITY.md` — disclosure policy.
- `/home/dev/.claude/rules/*.md` — global engineering rules (parent SSoT).
- `.github/workflows/` — CI / security / supply-chain automations:
  - `test.yml` — headless tests + Windows AST parse.
  - `security.yml` — OSS-CLI security stack (PSScriptAnalyzer, Trivy, Semgrep, Gitleaks, jscpd, SBOM).
  - `scorecard.yml` — OpenSSF Scorecard (push + weekly cron, non-gating).
- `scripts/setup-git-signed.sh` — repo-local signed-commit setup.
- OpenSSF Best Practices: <https://www.bestpractices.dev/en/projects/12647>.
- OpenSSF Scorecard dashboard: <https://securityscorecards.dev/viewer/?uri=github.com/RandomCodeSpace/snipIT>.
