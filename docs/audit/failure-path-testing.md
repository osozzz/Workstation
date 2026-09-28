# Failure-path and provider-isolation testing

Sprint 7 exercises deliberate failure paths through the real audit orchestrator so failures remain explicit, reviewable, and isolated.

## Controlled failure matrix

`tests/pester/failure-paths/Audit.FailurePaths.Tests.ps1` builds a temporary provider directory containing synthetic providers for:

- a missing command/tool that normalizes to a `missing` component while the provider remains successful;
- a command that deliberately exits with code `7`, producing explicit partial/error evidence without leaking that exit code into the audit session;
- malformed provider evidence, a malformed component record, and a dictionary where an array is required, each rejected and converted into a failed-provider result;
- an offline remote/version source represented as `unavailable`;
- a provider that throws during execution;
- an unrelated provider that runs after the controlled failures and verifies prior normalized statuses;
- invalid provider descriptions (a missing `order`, and an uppercase `providerId` in a file whose name contains a separator run) that fail discovery;
- a missing `AdditionalProviderPath` recorded as a report-level error.

The suite asserts that JSON and Markdown reports are still written after every rejection, and that each outcome is counted in the summary.

A second, isolated run contains only a healthy provider and a throwing provider. It has no report-level errors, which proves that provider failures alone keep the aggregate report `failed`. Controlled failures are never allowed to become silent success.

## Runtime provider-result validation

Before the orchestrator accepts a provider result, `Assert-AuditProviderResult` in `scripts/Core/Audit.Core.psm1` validates it against `schemas/provider-result.schema.json`:

- every record has exactly the schema's properties, with no missing or unexpected fields;
- enums and patterns are case-sensitive, matching JSON Schema semantics;
- collections must be arrays, not strings, dictionaries, or `$null`;
- components are validated in full, including version records, installations, command resolutions, version intelligence, and `present`/`missing` versus `installed` consistency;
- evidence types, integer exit codes, captured-text limits, boolean `redacted`, and object `attributes` are enforced;
- warning/error codes, severities, messages, and `evidenceIds` arrays are enforced;
- `observedAt` and `checkedAt` must be RFC 3339 date-time strings.

It also enforces contract invariants that JSON Schema cannot express: the result `providerId`/`category` match the registration, `componentId` and `evidenceId` values are unique within the result, and every `evidenceIds` reference is unique and resolves inside the same result.

A provider that violates these boundaries is normalized to `failed` with `PROVIDER_EXECUTION_FAILED`, and orchestration continues.

`tests/pester/core/Audit.Core.Tests.ps1` covers every rule with a one-mutation-per-case matrix against a complete schema-valid result. It also guards the validator's enums, patterns, and limits against the schema and against the `New-AuditEvidence`/`New-AuditIssue` parameter validation, so the three cannot drift apart silently.

## Isolation guarantee

Provider failures do not terminate the provider loop. Later providers receive `PreviousProviderResults` containing already-normalized earlier outcomes, including failures.

Discovery failures are likewise materialized as failed-provider results while also producing report-level discovery findings. Fallback provider IDs derived from file names collapse separator runs so the fallback ID and its failure evidence ID always satisfy the identifier pattern.

`Invoke-AuditCommand` keeps a child process exit code in its normalized result and restores the caller's `$LASTEXITCODE`, so a provider command cannot change the exit code of the host running the audit.

## Safety

All providers, reports, and missing paths used by this suite live under Pester's temporary workspace. The tests do not install, upgrade, remove, repair, or reconfigure workstation software; mutate PATH/environment state; access real remote version sources; or modify Git repositories.
