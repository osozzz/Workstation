# Developer Workstation Standard

A Windows developer-workstation toolkit for auditing, comparing, and standardizing development environments across multiple PCs.

## Current phase

**v0.3.0 — Audit Core**

The repository now has a normalized read-only audit contract, shared audit runtime, deterministic provider orchestration, transitional providers, and contract-level validation. The next phase expands ecosystem-specific runtime and SDK detection.

The first real workstation baseline will not be treated as authoritative until **v1.0.0 — Baseline Ready**.

## Repository model

This public repository stores reusable scripts, policies, configuration, schemas, validation assets, and documentation only.

Generated audits, inventories, comparisons, machine names, local paths, and other workstation-specific outputs remain local to each clone and are excluded from version control.

## Documentation

Canonical documentation lives in `/docs`.

Start with:

- `docs/README.md`
- `docs/governance/repository-governance.md`
- `docs/governance/issue-project-model.md`
- `docs/releases/versioning-and-releases.md`
- `docs/policies/audit-safety.md`
- `docs/architecture/audit-system-roadmap.md`

The GitHub Wiki, when used, is a navigation/help layer only and must not override canonical repository documentation.

## Current audit system

The current scripts form a modular read-only audit foundation and are **not yet the complete baseline system**.

Today the repository can inspect parts of:

- Windows and PowerShell
- Node / npm / pnpm / NVM
- Angular / TypeScript / Prisma
- Zoho tooling
- Flutter / Dart
- Python
- Java
- .NET
- Rust / Cargo
- Go
- Git / GitHub CLI
- Docker
- ADB
- WinGet
- PATH and selected environment variables

The detector system will expand the current modular provider architecture with deeper runtime/SDK coverage, version intelligence, local-project discovery, Git/worktree hygiene, and cross-PC comparison.

## Roadmap

- `v0.1.0` — Initial Audit Skeleton
- `v0.2.0` — Repository Foundation
- `v0.3.0` — Audit Core
- `v0.4.0` — Runtime & SDK Detection
- `v0.5.0` — PATH & Environment Intelligence
- `v0.6.0` — Project & Git Discovery
- `v0.7.0` — Version Intelligence
- `v0.8.0` — Cross-PC Comparison
- `v0.9.0` — Audit Hardening
- `v1.0.0` — Baseline Ready

Only after `v1.0.0` will workstation mutation/update automation become the primary focus.

## Clone

With GitHub CLI:

```powershell
gh repo clone osozzz/Workstation
cd Workstation
```

Or with Git:

```powershell
git clone https://github.com/osozzz/Workstation.git
cd Workstation
```

## Repository workflow

- `main` is the only permanent branch.
- Changes use short-lived branches.
- Normal changes go through Pull Requests.
- Squash merge is the default strategy.
- Generated workstation outputs are never committed.
- Issues are the source of truth for executable work.
- Project fields handle planning metadata such as Status, Priority, Area, and Risk.
- Native parent/sub-issue and blocking relationships are preferred over duplicated status labels.

See `CONTRIBUTING.md` for the full workflow.

## Safety

Audit functionality is read-only by default.

It must not silently:

- install or uninstall software;
- modify PATH or environment variables;
- delete branches or worktrees;
- upgrade dependencies;
- rewrite Git history;
- expose arbitrary environment variables or secrets.

See `SECURITY.md` and `docs/policies/audit-safety.md`.
