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

The comparison output is a deterministic envelope containing normalized difference records. Comparison schema `1.1.0` extends the initial envelope with structured normalized values for component/version drift.

Each difference records:

- `category`: provider, component, version, path, environment, application, project, or git;
- `kind`: a stable machine-readable difference kind;
- `providerId`, `componentId`, or `subjectId` where relevant;
- `relation`;
- reference/target state;
- optional normalized reference/target values. These may be scalars, arrays, or structured objects when the source contract is structured.

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

## Component and version comparison

Comparison schema `1.1.0` adds normalized component/version drift on top of the `1.0.0` core contract.

Version records are reduced to a comparison-safe structured value:

- `value`: the normalized version when available, otherwise the source `raw` value;
- `valueSource`: `normalized` or `raw`, so raw fallback is never presented as normalized data;
- `channel`: the original ecosystem channel such as `stable`, `lts`, `current`, prerelease, or RC when present.

When `normalized` is available, `raw` is not retained in the comparison value and therefore cannot create drift solely because display/source text differs.

Component/version comparison covers:

- `activeVersion` independently from discovered versions;
- `discoveredVersions` as an order-independent normalized set;
- `installations` as an order-independent structured set containing path, normalized version value, active state, and source;
- `commandResolutions` as an order-independent structured set containing command, resolved path, command type, normalized version value, precedence, and active state;
- `versionIntelligence.status` with `known`, `unknown`, `unavailable`, and `not-applicable` preserved;
- `latestStable`, `latestLts`, and `latestCurrent` independently when both sides have known intelligence.

Version-intelligence `source`, `checkedAt`, and diagnostic `message` remain evidence metadata and are not treated as version drift by themselves. A different latest value remains informational comparison evidence only; it does not imply that an upgrade is mandatory or should be automated.

Set members receive deterministic hashed `subjectId` values derived from their normalized structured representation. This keeps ordering stable and avoids using raw terminal output as identity.

## PATH and environment comparison

Issue #97 compares only normalized evidence already emitted by the read-only audit providers.

PATH/environment comparison consumes:

- `environment.baseline` evidence for Machine/User/Process PATH health;
- `environment.baseline` evidence for persistent Machine/User cross-scope duplicates;
- `environment.baseline` evidence for approved environment variables;
- `path.precedence` derived command evidence for effective command-to-PATH resolution.

PATH scope comparison is split into independent difference kinds so callers can distinguish:

- scope health/count drift;
- effective PATH order drift;
- duplicate-entry drift;
- missing-entry drift;
- unresolved-reference drift;
- persistent Machine/User cross-scope duplicate drift.

Windows PATH identity uses the normalized case-insensitive `comparisonKey` emitted by the audit model. Original/raw formatting is not used as comparison identity.

Environment comparison is bounded by `environment.allowlist.boundary.approvedNames`. Variable values are compared only when the variable name is approved by both reports. Evidence outside that intersection is ignored by the specialized environment comparator.

The comparison value intentionally excludes raw/expanded environment-variable fields. It uses the normalized scope model: state, comparison key, existence, path items, missing/unresolved counts, approved unresolved-variable names, and configuration/validity flags.

A missing, failed, unavailable, or not-applicable specialized evidence provider does not cause the whole comparison to fail. Provider-level state remains visible through the shared provider comparison. Partial providers may still contribute the normalized evidence they successfully produced.

The comparison runtime does not enumerate environment variables, expand the allowlist, read secrets, or execute command discovery.

## WinGet and application comparison

Issue #98 compares only the normalized application evidence already produced by `winget.baseline`.

Application comparison consumes:

- `winget.inventory.normalized` for installed application identity and installed-version evidence;
- `winget.upgrades.normalized` for review-only upgrade state and available-version evidence.

Reliable `packageId` values are matched case-insensitively and form the application identity. Records whose `identityReliable` flag is false are not used to claim that an application exists only on one PC.

Installed-state comparison and upgrade intelligence remain separate:

- `presence` reports reliable package IDs installed only on the reference or target;
- `installed-version` compares installed versions only when both records declare `installedVersionReliable`;
- `upgrade-status` preserves `current`, `upgrades-available`, `source-unavailable`, `agreement-required`, `command-failed`, and `unknown` semantics;
- `upgrade-availability` compares the reliable package set with available upgrades only when both upgrade lookups are comparable;
- `available-version` compares available versions only when both records declare `availableVersionReliable`.

`checkedAt`, package display names, raw WinGet table formatting, and raw command evidence are not comparison identity and do not create drift by themselves.

When inventory or upgrade state is unavailable or unknown, the state difference is reported without treating absent package records as missing applications. A failed, unavailable, or not-applicable WinGet provider does not stop unrelated comparison categories.

The comparison runtime never invokes WinGet, accepts source/package agreements, installs or upgrades packages, or converts upgrade availability into automatic remediation.

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

- active/default/discovered version comparison, installation sets, command resolution/precedence, and version-intelligence channels: implemented by #96;
- PATH and safe environment comparison: implemented by #97;
- WinGet/application comparison: implemented by #98;
- project/runtime-constraint comparison: #99;
- Git-health comparison: #100;
- human-readable/local report rendering: #101;
- complete Sprint 6 integration gate: #102.

This separation keeps the comparison contract stable while specialized comparators remain independently testable.

## Safety and committed fixtures

Committed tests must use synthetic identities and synthetic normalized reports.

Real workstation reports and generated cross-PC comparisons remain local and must stay excluded from version control.

The comparison runtime consumes normalized report data only; it does not execute provider discovery, remote version lookups, package-manager mutation, filesystem cleanup, or Git mutation.
