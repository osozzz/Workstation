# Documentation

The `/docs` directory is the canonical documentation source for Workstation. The GitHub Wiki, when used, is a navigation and help layer only and must not override repository documentation.

## Documentation map

- `architecture/` — system boundaries, provider model, data flow, and normalized schemas.
  - `architecture/audit-system-roadmap.md` — authoritative v1.0.0 coverage by category, version-intelligence availability, safety guarantees, and limitations.
- `audit/` — audit capabilities, detection coverage, comparison behavior, and safety requirements.
  - `audit/running-the-audit.md` — operator runbook: configure, audit PC #1 and PC #2 with the same release, and compare them.
  - `audit/ci-coverage.md` — CI check names, what each covers, the required `validate` aggregator, and known coverage gaps.
  - `audit/powershell-static-analysis.md` — pinned PSScriptAnalyzer baseline, explicit exclusions, and CI gate behavior.
  - `audit/pester-testing.md` — direct core/provider contract testing conventions and deterministic CI behavior.
  - `audit/collection-safety.md` — StrictMode-safe collection idioms and the no-developer-tools audit regression.
  - `audit/schema-fixture-hardening.md` — normalized audit/comparison schema matrix, compatibility gates, fixture safety, and deterministic digests.
  - `audit/failure-path-testing.md` — controlled command, provider, discovery, malformed-result, and offline-source failure coverage, plus runtime provider-result validation.
  - `audit/privacy-testing.md` — report and comparison privacy boundaries, planted-canary checks, and committed-source secret scanning.
- `governance/` — repository workflow, issue/PR conventions, branch hygiene, and project management.
- `policies/` — workstation standards and version/update policies.
  - `policies/powershell-runtime.md` — supported PowerShell runtimes, how they are enforced, and handled runtime differences.
- `releases/` — versioning, milestones, release readiness, and changelog rules.
- `security/` — planned home for security-specific implementation guidance that complements `SECURITY.md`; not created yet, so `SECURITY.md` and `policies/audit-safety.md` are authoritative today.

## Current phase

The repository is in **v1.1.0 — Policy Evaluation**. `v1.0.1 — Baseline Ready` is complete and published.

Real workstation baselines are authoritative from v1.0.1 onward; changing a workstation remains outside the read-only audit.
