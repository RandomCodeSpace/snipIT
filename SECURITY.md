# Security Policy

## Supported versions

snipIT ships as a single PowerShell script (`SnipIT.ps1`) — there is no library distribution and no published binary outside the GitHub repo. Security fixes land on `main` and are tagged as the next release. While snipIT is pre-1.0 only the **latest** released `0.MINOR.x` line receives backports; older minor lines are EOL the moment a new minor ships.

| Version line | Status |
|---|---|
| `main` (HEAD) | Supported (current) |
| Latest tagged `0.MINOR.x` | Supported |
| Older `0.MINOR.x` lines | Unsupported |

## Reporting a vulnerability

Please **do not open a public GitHub issue** for security problems.

Use one of:

- **GitHub private vulnerability report** — preferred. Open `https://github.com/RandomCodeSpace/snipIT/security/advisories/new` (you must be signed in to GitHub). The advisory channel is monitored by the maintainer.
- **Email** — `ak.nitrr13@gmail.com`. Put `[snipIT security]` in the subject so the report is triaged ahead of normal mail.

Please include:

- The snipIT commit SHA or release tag.
- The shortest reproducer you can produce — a PowerShell snippet, a sequence of UI actions, or a malicious input file is ideal.
- Your assessment of impact (e.g., LPE, info-disclosure, arbitrary file write, DoS).
- The Windows + PowerShell + .NET versions you observed it on.

## What you can expect

- **Acknowledgement** within 72 hours.
- **Initial triage** within 7 days, with a severity rating (CVSS v3.1) and an indicative remediation timeline.
- **Coordinated disclosure** — we will agree on a public-disclosure date with the reporter; default is 90 days from triage, sooner for low-impact / already-public issues.
- **Credit** in the GHSA advisory and release notes (unless the reporter requests anonymity).

We do not currently run a paid bug bounty.

## Scope

In-scope:

- `SnipIT.ps1` — the production script. Includes the capture pipeline (`Get-VirtualScreenBounds`, `New-ScreenBitmap`, the P/Invoke surface against `user32.dll` / `gdi32.dll`), the WPF Fluent preview window, the annotation editor, the system-tray widget, the global hotkey registration, and the install flow that copies the script into its install home.
- The install home generated next to the script at runtime (writes to `%LOCALAPPDATA%`-adjacent paths) — including arbitrary-file-write, path-traversal, and TOCTOU classes.
- Output handling — clipboard, file-save dialog, default save location.
- Hotkey registration — focus-stealing or input-injection abuse.

Out of scope:

- Vulnerabilities that require pre-existing local code execution on the user's machine (snipIT is a desktop tool — by definition you trust the script you launch).
- Misuse of screen-capture functionality on systems where the user already has the legitimate ability to view the captured content (capturing your own screen is the product).
- Findings in third-party services or runtimes we do not control (Windows itself, .NET runtime, the PowerShell host) — please report those upstream.
- Vulnerabilities that only manifest under PowerShell versions older than the documented minimum (`pwsh 7.5+`) or unsupported Windows builds.

## Hardening references

- [`shared/runbooks/engineering-standards.md`](shared/runbooks/engineering-standards.md) — CVE policy and quality gates.
- `.github/workflows/scorecard.yml` — OpenSSF Scorecard supply-chain checks.
- `.github/workflows/security.yml` — OSS-CLI security stack: Trivy (filesystem), Semgrep (SAST), PSScriptAnalyzer (PowerShell lint), Gitleaks (secrets), jscpd (duplication), `anchore/sbom-action` (SBOM).
- GitHub repo-level **secret scanning + push protection** — enabled under repo Settings → Code security.
- `.github/dependabot.yml` — automated GitHub Actions bumps; repo-level Dependabot security updates enabled separately.

## Changelog

This file is versioned as part of the repo. Material changes (e.g., raising the supported-versions table, changing the disclosure timeline) are announced via a Release note and a Paperclip board comment.
