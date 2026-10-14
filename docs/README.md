# Documentation

The `/docs` directory is the canonical documentation source for Workstation. The GitHub Wiki, when used, is a navigation and help layer only and must not override repository documentation.

## Documentation map

- `architecture/` — system boundaries, provider model, data flow, and normalized schemas.
  - `architecture/policy-evaluation-contract.md` — normalized result of evaluating an audit report against the workstation policy.
  - `architecture/update-plan-contract.md` — normalized, read-only list of the updates one PC needs.
  - `architecture/audit-system-roadmap.md` — authoritative v1.0.0 coverage by category, version-intelligence availability, safety guarantees, and limitations.
- `audit/` — audit capabilities, detection coverage, comparison behavior, and safety requirements.
  - `audit/running-the-audit.md` — operator runbook: configure, audit a PC, evaluate it against the policy, and optionally compare it with another PC.
  - `audit/ci-coverage.md` — CI check names, what each covers, the required `validate` aggregator, and known coverage gaps.
  - `audit/powershell-static-analysis.md` — pinned PSScriptAnalyzer baseline, explicit exclusions, and CI gate behavior.
  - `audit/pester-testing.md` — direct core/provider contract testing conventions and deterministic CI behavior.
  - `audit/collection-safety.md` — StrictMode-safe collection idioms and the no-developer-tools audit regression.
  - `audit/schema-fixture-hardening.md` — normalized audit/comparison schema matrix, compatibility gates, fixture safety, and deterministic digests.
  - `audit/failure-path-testing.md` — controlled command, provider, discovery, malformed-result, and offline-source failure coverage, plus runtime provider-result validation.
  - `audit/privacy-testing.md` — report and comparison privacy boundaries, planted-canary checks, and committed-source secret scanning.
- `governance/` — repository workflow, issue/PR conventions, branch hygiene, and project management.
- `policies/` — workstation standards and version/update policies.
  - `policies/workstation-policy.md` — the declared workstation standard, its schema, and the meaning of every key.
  - `policies/update-execution-safety.md` — when and how the update executor may change a workstation (v2.0.0 onward).
  - `policies/powershell-runtime.md` — supported PowerShell runtimes, how they are enforced, and handled runtime differences.
- `releases/` — versioning, milestones, release readiness, and changelog rules.
- `security/` — planned home for security-specific implementation guidance that complements `SECURITY.md`; not created yet, so `SECURITY.md` and `policies/audit-safety.md` are authoritative today.

## Current phase

`v2.0.0 — Controlled Updates` is the current release: audit, evaluate, plan, and apply selected updates with confirmation (`policies/update-execution-safety.md`).

Real workstation baselines are authoritative from v1.0.1 onward; changing a workstation remains outside the read-only audit.
