# Cross-PC Comparison Contract

Sprint 6 compares two normalized Workstation audit reports without falling back to legacy raw command output.

The machine-readable comparison result contract is:

- `schemas/comparison-result.schema.json`

The comparison runtime is:

- `scripts/Core/Comparison.Core.psm1`

## Design boundaries

Comparison is read-only and directional. A caller supplies a **reference** report and a **target** report. The direction is recorded as `reference-to-target`, but the reference is not automatically treated as correct, preferred, newer, or healthier.

The comparison contract must not:

- install, upgrade, remove, repair, migrate, or reconfigure software;
- modify PATH, environment variables, Git state, projects, or workstation settings;
- use raw command output as the comparison identity;
- convert update availability into an automatic remediation recommendation;
- commit real machine-specific reports or comparison output.

## Audit schema compatibility

The audit report schema and the comparison result schema are versioned independently.

Sprint 6 initially supports audit schema major `1`. Both input reports must:

- declare a semantic `schemaVersion`;
- use supported audit schema major `1`;
- declare `audit.mode: read-only`;
- contain normalized `providers`;
- contain normalized host identity.

Minor or patch audit-schema differences within major `1` may be consumed when the fields required by the comparison runtime remain available. Unsupported audit-schema majors are rejected explicitly rather than guessed.

## Stable identity

Providers are matched only by `providerId`.

Components are matched only by `componentId` within the owning provider.

Display names, raw command strings, terminal formatting, and observed output text are not comparison keys.

Duplicate provider IDs or duplicate component IDs are invalid comparison input and are rejected.

## Difference record

The comparison output is a deterministic envelope containing normalized difference records.

Each difference records:

- `category`: provider, component, version, path, environment, application, project, or git;
- `kind`: a stable machine-readable difference kind;
- `providerId`, `componentId`, or `subjectId` where relevant;
- `relation`;
- reference/target state;
- optional scalar reference/target values.

The specialized Sprint 6 issues add differences through this shared record rather than inventing independent output envelopes.

## Relations

The initial relations are:

| Relation | Meaning |
| --- | --- |
| `reference-only` | The normalized subject exists only in the reference report. |
| `target-only` | The normalized subject exists only in the target report. |
| `different` | Both subjects exist and their compared normalized values differ. |
| `unavailable` | At least one compared state is explicitly unavailable. |
| `unknown` | At least one compared state is explicitly unknown. |
| `not-applicable` | At least one compared state is explicitly not applicable. |

Equal values are not emitted as difference records.

Component state such as `missing` is preserved in `referenceState` or `targetState`; it is not rewritten as `unavailable` or `unknown`.

## Initial Sprint 6 core coverage

Issue #95 establishes only the common comparison mechanics:

- audit-schema compatibility;
- stable provider/component identity;
- provider presence/status differences;
- component presence/state differences;
- deterministic ordering;
- directional endpoint descriptors;
- shared difference records.

The following are intentionally deferred:

- active/default/discovered version comparison: #96;
- PATH and safe environment comparison: #97;
- WinGet/application comparison: #98;
- project/runtime-constraint comparison: #99;
- Git-health comparison: #100;
- human-readable/local report rendering: #101;
- complete Sprint 6 integration gate: #102.

This separation keeps the comparison contract stable while specialized comparators remain independently testable.

## Safety and committed fixtures

Committed tests must use synthetic identities and synthetic normalized reports.

Real workstation reports and generated cross-PC comparisons remain local and must stay excluded from version control.

The comparison runtime consumes normalized report data only; it does not execute provider discovery, remote version lookups, package-manager mutation, filesystem cleanup, or Git mutation.
