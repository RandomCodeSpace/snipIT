# snipIT documentation

This folder collects long-form documentation that doesn't fit in the top-level [`README.md`](../README.md), the agent / contributor brief in [`CLAUDE.md`](../CLAUDE.md), or the disclosure policy in [`SECURITY.md`](../SECURITY.md).

snipIT is intentionally a **single-script** product (`SnipIT.ps1`); most of what you need to know lives in the regions inside that script. The files here capture material that is too large or too visual to live alongside the code.

## Index

| Path | What it is |
|---|---|
| [`mockups/preview-redesign.html`](mockups/preview-redesign.html) | Standalone HTML mock of the chromeless Fluent preview window — used as the design reference when iterating on the WPF preview chrome. Open it in any browser. |

## Documentation in other places

For convenience, here is where the rest of snipIT's docs live:

| Topic | Where to read it |
|---|---|
| Install, hotkeys, usage, architecture overview | [`/README.md`](../README.md) |
| Build, test, run; conventions; gotchas; OpenSSF Scorecard baseline | [`/CLAUDE.md`](../CLAUDE.md) |
| Vulnerability disclosure, supported versions, scope | [`/SECURITY.md`](../SECURITY.md) |
| Quality gates, security tooling, branch / commit / PR rules | [`/shared/runbooks/engineering-standards.md`](../shared/runbooks/engineering-standards.md) — the PowerShell variant of the company-canonical engineering-standards runbook |
| Per-merge change history | [`/CHANGELOG.md`](../CHANGELOG.md) |
| OpenSSF Best Practices self-assessment (machine-readable) | [`/.bestpractices.json`](../.bestpractices.json) — companion to project [12647](https://www.bestpractices.dev/en/projects/12647) |

## Contributing documentation

If you're adding a doc that explains design rationale, walks through a non-trivial subsystem, or captures a decision (ADR-style), add a sibling file under `docs/` and link it from the **Index** table above. Keep this README the single entry point so the table of contents stays discoverable.

For docs that belong with the code itself (region-level comments inside `SnipIT.ps1`, function-level help blocks), prefer inline comments per the convention in [`shared/runbooks/engineering-standards.md`](../shared/runbooks/engineering-standards.md) §2.
