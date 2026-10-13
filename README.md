# Developer Workstation Standard

A Windows developer-workstation toolkit for auditing, comparing, and standardizing development environments across multiple PCs.

## Current phase

**v1.0.0 — Baseline Ready**

`v0.9.0 — Audit Hardening` is complete and published. The repository is now validating the complete read-only audit against real workstations so the first baseline can be treated as authoritative.

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

The read-only audit covers Windows and PowerShell, WinGet applications and updates, JavaScript/Java/Flutter/Android/Python/.NET/Rust/Go toolchains, developer CLIs, PATH and approved environment variables, command precedence, local projects, Git health and hygiene, latest-version intelligence, and cross-PC comparison. The full coverage statement and its limitations are in `docs/architecture/audit-system-roadmap.md`.

## Quick start

```powershell
.\Run-Audit.cmd                                   # audit this PC; reports go to .\reports (ignored by Git)
.\Run-Compare.cmd <reference.json> <target.json>  # compare two audit reports
```

Optional project and Git discovery needs `config\workstation.local.json`; see `config/README.md`. The step-by-step procedure for auditing PC #1 and comparing PC #2 is in `docs/audit/running-the-audit.md`.

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
