# Changelog

All notable changes to this workstation toolkit are documented here.

## Unreleased

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
