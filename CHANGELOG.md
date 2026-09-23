# Changelog

All notable changes to this workstation toolkit are documented here.

## Unreleased

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
