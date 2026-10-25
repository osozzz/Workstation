# Changelog

All notable changes to this workstation toolkit are documented here.

## Unreleased

## 2.1.0 — 2026-10-24

### Added

- `Run-Update.cmd ... -Apply -ConfirmAll` updates everything at once. It shows the full validated list, asks you once to type the number of actions, and keeps going past failures, listing them at the end. Per-action confirmation stays the default.

### Changed

- The update plan upgrades tools shared with Chocolatey (Python, VS Build Tools, VC++ 2015+) through WinGet only, the policy's application manager; for Python this is decided per minor version. WinGet's `Microsoft.WSL` upgrade is dropped when `wsl --update` is planned.

### Fixed

- Executor actions no longer hang after the update finished. `flutter upgrade` timed out after 30 minutes because a child process kept the output pipe open. Commands now write their output to files, get an empty stdin, and on timeout are stopped with their partial output kept in the log.

## 2.0.0 — 2026-10-14

The toolkit can now apply updates. Auditing, evaluating, planning and comparing are still read-only. Only the new update executor changes a PC, under `docs/policies/update-execution-safety.md`.

### Added

- `Run-Update.cmd` / `scripts/Update-Workstation.ps1` applies selected update-plan actions. It previews by default. With `-Apply` it asks before every action, stops at the first failure, and writes a log to `reports/update-log/`.
- Only allow-listed commands run. Each one is rebuilt from validated plan fields (package equals the action subject, version equals the target) and never passed to a shell.
- Plans older than 24 hours, or built from a different policy, are refused.
- Manual and high-risk actions never run. Chocolatey actions run only from an elevated shell; the executor never elevates itself.
- A Sprint 11 release gate. The Sprint 7 no-mutation gate exempts only `scripts/Execution` and fails if anything other than `Update-Workstation.ps1` loads it.

### Changed

- **Breaking:** the toolkit is no longer read-only as a whole. Every workstation change goes through `Run-Update.cmd` with an explicit `-Apply` and a confirmation per action.

## 1.3.0 — 2026-10-14

### Added

- Chocolatey is audited (`chocolatey.baseline`): installed and outdated packages. The plan upgrades each unpinned package with `choco upgrade <id> -y`.
- WSL is audited (`wsl.baseline`): version, distributions (never started), and the latest release from GitHub. The plan runs `wsl --update` when WSL is behind.
- Microsoft Store apps known to WinGet are planned with `winget upgrade --id <id> --exact --source msstore`.
- pnpm and every global JavaScript CLI get their latest version from the npm registry. The plan uses `pnpm self-update`, or the manager that installed the CLI (`pnpm add -g` / `npm install -g`).
- pip and uv (PyPI, GitHub releases) and the Android SDK platform-tools and command-line tools (Google's SDK repository manifest) get latest versions and plan actions.
- Tools managed by more than one package manager (for example Python through Chocolatey, WinGet and the Python Install Manager) get a manual consolidation action.
- `python.windowsManager` is evaluated from the WinGet inventory. Manual runtime upgrades say whether WinGet manages the installation.
- The update plan schema moves to 1.1.0 with the new sources.

### Fixed

- ANSI color sequences are stripped from all command output. Angular CLI 21.2.24 was read as 2.24.
- A single Chocolatey output row is parsed correctly.
- The launcher test no longer leaves offline audit reports in the operator's `reports\` folder or overwrites launcher outputs.

## 1.2.0 — 2026-10-14

### Added

- A read-only update plan lists everything on a PC that can be updated. It runs through `Run-Plan.cmd` or `scripts/Plan-WorkstationUpdate.ps1` and writes `update-plan.json` and `update-plan.txt`. Policy deviations and every reliable WinGet upgrade become ordered actions, from low to high risk. Each action has the exact command that would run (or is marked manual), its risk, and whether it can be undone. Nothing is executed.
- The update plan has a normalized contract (`schemas/update-plan.schema.json`), with fixtures and invariant checks.
- A Sprint 10 release gate maps the phase-2 criteria of #159 to evidence.

### Changed

- The README and the runbook now center on keeping one PC up to date: audit, evaluate, plan. Comparing two PCs is an optional extra.

### Fixed

- Evaluation and plan JSON are byte-identical on Windows PowerShell 5.1 and PowerShell 7. Version 5.1 used to escape `<`, `>`, `&` and `'`.

## 1.1.0 — 2026-10-14

### Added

- A read-only policy evaluation compares an audit report with `config/workstation.policy.json`. It runs through `Run-Evaluate.cmd` or `scripts/Evaluate-Workstation.ps1` and writes `evaluation.json` and `evaluation.txt`. Each policy setting is reported as `compliant`, `deviation`, `unknown`, or `not-evaluable`, with references to the evidence behind it. Output is deterministic and privacy-safe, and it is byte-identical on Windows PowerShell 5.1 and PowerShell 7.
- The workstation policy has a JSON schema (`schemas/workstation-policy.schema.json`), validated in CI. Audit-safety switches are pinned to their safe values.
- The evaluation output has a normalized contract (`schemas/policy-evaluation.schema.json`), with fixtures and invariant checks.
- A Sprint 9 release gate maps the phase-1 criteria of #159 to evidence. The rule catalog is checked against the policy in both directions.

## 1.0.1 — 2026-10-13

### Fixed

- WinGet inventory and upgrades are parsed on Spanish (and other non-English) Windows. Native command output is decoded as UTF-8 in every execution path, Spanish table patterns now match on Windows PowerShell 5.1, and the full inventory is captured for parsing. Found by the first real baseline: 0 packages became 260 and 0 upgrades became 39.
- Node-based JavaScript CLIs such as Zoho Catalyst get 60 seconds for version detection.
- Production scripts are ASCII-only, enforced by the Windows PowerShell 5.1 compatibility gate.

## 1.0.0 — 2026-10-13

### Baseline Ready

- Declared the authoritative v1.0.0 coverage: every workstation category mapped to its provider and components, latest-version intelligence availability, safety guarantees, and limitations (`docs/architecture/audit-system-roadmap.md`).
- Added `Run-Compare.cmd` and the operator runbook (`docs/audit/running-the-audit.md`) for auditing PC #1, auditing PC #2 with the same release, and comparing them; added a README quick start.
- Fixed `Run-Audit.cmd` on Windows PowerShell 5.1: default output, configuration, and provider paths were empty under `powershell.exe -File`, so the launcher failed before auditing.
- Fixed UTF-8 decoding on Windows PowerShell 5.1: reports, local configuration, and project manifests without a BOM no longer corrupt non-ASCII text such as accented folder names.
- Gave developer CLI version probes 60 seconds so slow Node-based CLIs such as Heroku report consistently.
- Added the Sprint 8 Baseline Ready gate mapping all twelve acceptance criteria of #12 to evidence, and CI checks for the launchers, default-path audits on Windows PowerShell 5.1, and unencoded reads.
- Validated the release candidate end to end: the documented runbook on both PowerShell hosts with real development roots, schema-valid reports and comparison, and identical results across hosts.
- Updated the repository tool version to `1.0.0`. The first authoritative baselines (PC #1 and PC #2) are taken with this release (#148).

## 0.9.0 — 2026-10-13

### Audit Hardening

- Added a deterministic PSScriptAnalyzer gate, enforced `PSAvoidAssignmentToAutomaticVariable`, and removed assignments to automatic variables.
- Added Pester coverage for audit core, provider contracts, deliberate failure paths, collection safety, individual providers, and privacy boundaries, plus the normalized schema and hardening fixture matrix.
- Validated full provider results at runtime against `provider-result.schema.json` and contract invariants, so malformed provider output becomes an explicit failed provider instead of crashing the audit or producing schema-invalid reports.
- Kept provider command exit codes out of the audit session and made discovery fallback identifiers always valid.
- Fixed providers that failed on workstations without Rust, Go, or configured project roots, and replaced StrictMode-unsafe collection idioms across providers.
- Restored Windows PowerShell 5.1 support (the `Run-Audit.cmd` host) for comparison, online version intelligence, and project/Git discovery, and stopped comparison output from rewriting timestamps by time zone.
- Sized JavaScript version sources for real Node and npm responses, and stopped PowerShell 7 from reporting phantom JavaScript CLI installations; Prisma 8 JSON version output is parsed correctly.
- Declared the supported PowerShell runtime policy (Windows PowerShell 5.1 and PowerShell 7) and added a Windows PowerShell 5.1 compatibility gate plus 5.1 runtime checks in CI.
- Added privacy tests with planted canaries for audit and comparison output, committed-source secret scanning, and a documented local-report versus shareable-output boundary.
- Split CI into stable per-area checks behind the required `validate` aggregator, with resilient pinned-module installation.
- Added the Sprint 7 integration gate mapping all nine acceptance criteria of #11 to evidence and rejecting workstation-mutating invocations in scripts and tests.
- Updated the repository tool version to `0.9.0`.

## 0.8.0 — 2026-09-24

### Cross-PC Comparison

- Added a schema-aware normalized comparison contract with explicit `reference -> target` direction, stable provider/component identity, semantic provider/component states, and deterministic difference ordering.
- Added normalized component and version comparison for installed/missing state, active/default versions, discovered-version sets, installations, command resolutions, and version-intelligence channels without relying on raw terminal output.
- Added PATH and safe environment comparison for scope ordering, duplicate/missing/unresolved entries, approved environment-variable values, persistent cross-scope duplicates, and normalized command precedence.
- Added WinGet/application comparison using reliable package IDs, separate installed-version drift from upgrade availability, and explicit current, upgrade-available, source-unavailable, agreement-required, command-failed, and unknown states.
- Added project/runtime-constraint comparison using path-safe project identity, normalized project types, runtime constraints, package-manager pins, and provider-availability semantics without exposing machine-specific absolute paths.
- Added Git-health comparison for inspection state, branch/upstream configuration, ahead/behind divergence, working-tree state, branch hygiene, and worktree hygiene while excluding absolute repository/worktree paths, commit/object IDs, remote URLs, raw status output, and modified filenames from comparison output.
- Added deterministic machine-readable `comparison.json` output and human-readable `comparison.txt` rendering derived only from the normalized comparison result.
- Preserved unavailable, unknown, not-applicable, partial, reference-only, and target-only semantics in both structured and human-readable outputs.
- Kept machine-specific comparison reports local under the ignored `reports/` boundary; controlled CI outputs are written only to ephemeral storage and removed after validation.
- Added the complete Sprint 6 integration gate using one synthetic reference/target pair across all comparison categories, with 18 deterministic known differences.
- Validated supported audit-schema minor compatibility and explicit failure for unsupported schema majors.
- Validated that an unavailable provider on one machine does not block unrelated comparison categories.
- Kept the comparison runtime read-only: no install, update, remove, repair, environment mutation, provider rediscovery, Git fetch/pull/checkout/reset/clean, or synchronization behavior is performed.
- Updated the repository tool version to `0.8.0` for the Cross-PC Comparison release.


## 0.7.0 — 2026-09-23

### Version Intelligence

- Added a shared version-intelligence runtime for bounded HTTPS source lookups, explicit source identity, checked-at timestamps, deterministic transport injection, and safe normalization of offline, unreachable, HTTP-failure, malformed, and truncated source states.
- Added Node.js version intelligence that reports installed/default evidence alongside Latest LTS and Latest Current while keeping LTS as the configured default track and never treating Current as a mandatory replacement.
- Added npm and pnpm installed-versus-latest intelligence with explicit update availability while reusing existing global toolchain detection.
- Added Angular CLI latest-stable intelligence, TypeScript stable/prerelease channel separation, and Prisma stable/release-candidate channel separation with explicit opt-in/major-migration safeguards.
- Preserved project-local compatibility constraints and version pins separately from global latest-version information so global intelligence cannot overwrite project evidence.
- Added Flutter stable-channel intelligence without channel switching or SDK mutation.
- Added Java intelligence scoped to installed major, distribution/vendor, package type, architecture, and relevant release context; higher majors or different vendors are informative rather than naive direct replacements.
- Added WinGet installed-application and available-upgrade intelligence using non-interactive, review-only inspection with explicit current, upgrade-available, source-unavailable, agreement-required, command-failure, and unknown states.
- Kept WinGet intelligence free of agreement acceptance, bulk upgrade, install, uninstall, and repair behavior.
- Added deterministic Sprint 5 fixture suites for shared source behavior, JavaScript ecosystems, JVM/mobile ecosystems, and WinGet upgrade parsing.
- Added the Sprint 5 integration gate across all 20 built-in providers, including controlled early-provider failure isolation, offline-safe version intelligence, project-local Node/pnpm pin preservation, source/timestamp invariants, WinGet review-only evidence, and temporary report safety.
- Validated that remote/version-source failures do not block local detection or later providers.
- Updated the repository tool version to `0.7.0` so generated audit reports identify the Version Intelligence release correctly.
- Preserved the project rule that version intelligence informs decisions only; workstation mutation and automatic migrations remain outside the read-only audit milestone.


## 0.6.0 — 2026-09-23

### Project & Git Discovery

- Added machine-local development-root configuration through ignored `config/workstation.local.json`, with a committed empty template and bounded project-discovery depth.
- Added `projects.local` bounded discovery that normalizes configured roots, detects duplicates/missing/inaccessible roots, rejects filesystem-root traversal, skips reparse-point descendants, and never falls back to whole-disk or implicit user-profile scanning.
- Added JavaScript/web project detection for Node/package projects plus Angular, Next.js, and Prisma markers using canonical project files only.
- Added project-local Node/package-manager constraint reporting from `.nvmrc`, `.node-version`, `engines`, `packageManager`, lockfiles, and conflicting pin signals without inspecting `node_modules` or invoking package managers.
- Added non-JavaScript project detection for Flutter/Dart, Python, Rust, Go, .NET, Maven, and Gradle using canonical manifests, project files, wrapper metadata, and explicit local runtime/toolchain constraints.
- Preserved project-local runtime/package-manager evidence separately from global runtime/toolchain evidence and kept all Sprint 4 project-classification providers evidence-only with zero normalized component ownership.
- Added read-only Git repository health detection for clean/dirty state, staged/unstaged/untracked/conflicted changes, detached HEAD, missing upstream, locally known ahead/behind/diverged state, and unpushed commits.
- Added Git branch/worktree hygiene intelligence for locally merged cleanup candidates, gone-upstream branches, explicit stale-age evidence, documented branch-prefix deviations, linked/dirty worktrees, and Git-reported prunable worktrees.
- Added configurable `git.branchStaleDays` local policy with a 90-day default and documented advisory-only stale/cleanup semantics.
- Added `git --no-optional-locks` inspection and explicit safeguards preventing fetch, pull, push, checkout, reset, clean, stash, commit, branch deletion, worktree prune/remove, history rewrite, Git configuration mutation, remote-URL collection, or credential-helper inspection.
- Added dedicated synthetic fixtures across bounded project discovery, JavaScript/web classification, non-JavaScript classification, repository health, and branch/worktree hygiene.
- Added the Sprint 4 integration gate and machine-readable acceptance coverage matrix for parent issue #8, mapping all nine acceptance criteria 1:1 to committed validation evidence.
- Validated all 20 built-in providers together, including provider/path failure isolation, bounded ownership, project-path privacy, project-local pin preservation, and controlled Windows integration.
- Validated a single controlled report through Sprint 2, Sprint 3, and Sprint 4 release gates in sequence.
- Kept synthetic repositories, local configuration, and generated JSON/Markdown reports under runner temporary storage and deleted them after validation.
- Preserved the project rule that the first authoritative workstation baseline remains deferred until v1.0.0.


## 0.5.0 — 2026-09-22

### PATH & Environment Intelligence

- Added normalized Machine, User, and effective Process PATH modeling with deterministic scope ordering, duplicate detection, dead-entry detection, unresolved-reference handling, and persistent cross-scope comparison.
- Added a synchronized 16-variable approved environment allowlist covering JavaScript, JVM/mobile, Python, .NET, Rust, and Go tooling while explicitly prohibiting arbitrary environment-variable enumeration.
- Added derived command-to-PATH precedence analysis that preserves active and shadowed command-resolution evidence, maps only provable Process PATH origins, and leaves non-PATH or unmapped origins explicit instead of fabricating positions.
- Added JavaScript precedence intelligence for NVM/Node/npm/pnpm, including stale roots, NVM symlink bypass, command collisions, and evidence-backed PNPM_HOME mismatches.
- Added JVM/mobile precedence intelligence for JAVA_HOME, FLUTTER_ROOT, Flutter-bundled versus standalone Dart, ANDROID_HOME, ANDROID_SDK_ROOT, ADB/platform-tools, and approved PUB_CACHE evidence.
- Added Python/.NET/Rust/Go precedence intelligence for PYENV_ROOT, DOTNET_ROOT variants, CARGO_HOME, RUSTUP_HOME, GOROOT, and GOPATH while avoiding .NET architecture inference and preserving GOTOOLCHAIN=local safety.
- Added dedicated aligned/conflicting synthetic fixtures for all Sprint 3 ecosystem precedence providers; all derived precedence providers own zero components and reuse prior evidence instead of rediscovering runtimes.
- Added the Sprint 3 release integration gate and machine-readable acceptance coverage matrix for parent issue #7, covering PATH normalization, missing/duplicate/unresolved state, command precedence, ecosystem conflicts, approved environment inspection, and arbitrary-environment-dump prevention.
- Validated all 15 built-in providers together, including provider failure isolation, read-only behavior, synchronized environment evidence, non-fabricated PATH origins, and the controlled Windows real-machine audit.
- Kept controlled JSON/Markdown reports outside the repository workspace and deleted them after validation.
- Preserved the project rule that the first authoritative workstation baseline remains deferred until v1.0.0.

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
