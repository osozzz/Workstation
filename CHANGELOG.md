# Changelog

All notable changes to this workstation toolkit are documented here.

## Unreleased

## 0.4.0 — 2026-09-21

### Runtime & SDK detection

- Added specialized read-only providers for Windows/PowerShell/WinGet, Node.js and JavaScript tooling, Java/JVM, Flutter/Dart/Android, Python, .NET, Rust/Go, and Git/Docker/developer CLIs.
- Added normalized detection for multiple installations, active/default versions, command-resolution precedence, manager/toolchain relationships, approved environment roots, and partial/unavailable states.
- Added safety guards that prevent audit-time installs, upgrades, authentication/session inspection, Docker daemon/context inspection, and other workstation mutation.
- Migrated specialized ownership out of the transitional command inventory; it now has zero remaining components.
- Expanded provider-specific synthetic fixtures and CI validation across all Sprint 2 ecosystems.
- Added the Sprint 2 integration gate with 42 committed fixtures across 8 ecosystem suites and a controlled Windows runner audit.
- Validated 11 built-in providers together with 47 uniquely owned components, no built-in provider failures, and no report-level errors.
- Fixed normalized array-shape handling for single discovered versions, synchronized approved .NET root variables with aggregate audit context, and corrected empty .NET runtime/workload states.
- Kept controlled real-machine JSON/Markdown reports ephemeral under runner temporary storage and removed them after validation.
- Preserved the project rule that authoritative workstation baselines remain deferred until v1.0.0.


## 0.3.0 — 2026-09-21

### Audit core

- Added normalized Draft 2020-12 schemas for complete audit reports and provider results.
- Documented the provider execution contract, status semantics, evidence rules, version-intelligence states, and schema-versioning behavior.
- Added a shared read-only audit core for safe command execution, command resolution, bounded evidence capture, structured diagnostics, provider status calculation, and explicit environment-variable allowlisting.
- Refactored `Audit-Workstation.ps1` into a deterministic provider orchestrator with isolated provider failure handling and normalized JSON/Markdown aggregation.
- Added transitional providers for host information, generic command inventory, environment/PATH baseline health, and WinGet diagnostics.
- Added synthetic provider/report fixtures and CI validation against the approved schemas, including negative contract cases and documented invariants.
- Preserved the required `validate` check while keeping generated workstation reports local-only and the audit read-only.

## 0.2.0 — 2026-09-21

### Repository foundation

- Added repository ownership and editor configuration.
- Added security policy and structured Issue Forms.
- Added canonical `/docs` information architecture.
- Documented repository governance, worktree hygiene, Issue/Project conventions, audit safety, and release policy.
- Aligned contribution and Pull Request conventions with the project workflow.

## 0.1.0 — 2026-09-17

- Added read-only workstation audit.
- Added cross-PC comparison script.
- Added workstation policy configuration.
- Added repository contribution and pull-request conventions.
- Added automated PowerShell and JSON validation.
- Excluded machine-specific diagnostic reports from version control.
