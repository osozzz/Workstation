# Failure-path and provider-isolation testing

Sprint 7 exercises deliberate failure paths through the real audit orchestrator so failures remain explicit, reviewable, and isolated.

## Controlled failure matrix

`tests/pester/failure-paths/Audit.FailurePaths.Tests.ps1` builds a temporary provider directory containing synthetic providers for:

- a missing command/tool that normalizes to a `missing` component while the provider remains successful;
- a command that deliberately exits with code `7`, producing explicit partial/error evidence;
- malformed provider evidence that must be rejected and converted into a failed-provider result;
- an offline remote/version source represented as `unavailable`;
- a provider that throws during execution;
- an unrelated provider that runs after the controlled failures and verifies prior normalized statuses;
- an invalid provider description that fails discovery;
- a missing `AdditionalProviderPath` recorded as a report-level error.

The aggregate report must remain `failed` when explicit provider/report failures exist. Controlled failures are never allowed to become silent success.

## Runtime evidence validation

The orchestrator validates provider-result collection shape and evidence/issue invariants before accepting a provider result.

Evidence must declare the contract fields:

- `evidenceId`
- `type`
- `source`
- `exitCode`
- `captured`
- `redacted`
- `attributes`

Evidence IDs must be unique and syntactically valid. Warning/error records must use valid codes/severities and every `evidenceIds` reference must resolve inside the same provider result.

A provider that violates these boundaries is normalized to `failed` with `PROVIDER_EXECUTION_FAILED`, and orchestration continues.

## Isolation guarantee

Provider failures do not terminate the provider loop. Later providers receive `PreviousProviderResults` containing already-normalized earlier outcomes, including failures.

Discovery failures are likewise materialized as failed-provider results while also producing report-level discovery findings.

## Safety

All providers, reports, and missing paths used by this suite live under Pester's temporary workspace. The tests do not install, upgrade, remove, repair, or reconfigure workstation software; mutate PATH/environment state; access real remote version sources; or modify Git repositories.
