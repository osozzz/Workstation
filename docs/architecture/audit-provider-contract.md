# Audit Provider Contract

Workstation audit providers return normalized, read-only data through a stable contract. The contract separates provider-specific detection from orchestration, reporting, comparison, and later version intelligence.

This document defines the contract introduced for Sprint 1 / `v0.3.0`. The machine-readable source of truth is:

- `schemas/audit-report.schema.json`
- `schemas/provider-result.schema.json`

## Design goals

The contract must:

- remain neutral across ecosystems such as Node, Java, Flutter, Python, .NET, Rust, Go, Git, Docker, PATH, projects, and version sources;
- preserve useful detection evidence without coupling consumers to raw command output;
- represent missing tools and partial configurations without failing the complete audit;
- distinguish local detection from remote/latest-version intelligence;
- remain safe for read-only workstation auditing;
- support deterministic cross-PC comparison later in the roadmap;
- evolve through explicit schema versions rather than silent shape changes.

## Audit report envelope

A complete audit is represented by `audit-report.schema.json`.

The top-level fields are:

| Field | Purpose |
|---|---|
| `schemaVersion` | Version of the normalized report contract. |
| `generatedAt` | Timestamp when the report was generated. |
| `audit` | Audit mode and Workstation tool version. |
| `host` | Minimal host identity required to distinguish local reports. |
| `summary` | Provider outcome counts and aggregate audit status. |
| `providers` | Normalized provider results. |
| `warnings` | Report-level warnings not owned by one provider. |
| `errors` | Report-level errors not owned by one provider. |

The audit mode is fixed to `read-only` for this contract.

### Summary invariants

The orchestrator is responsible for keeping summary counts consistent with `providers`:

- `providerCount` equals the number of provider results;
- each provider contributes to exactly one provider-status count;
- aggregate `status` is derived from provider outcomes rather than independently invented.

These cross-field invariants are documented here because JSON Schema cannot express all of them cleanly without making the schema unnecessarily complex.

## Provider result envelope

Every provider returns the same envelope:

```json
{
  "providerId": "runtime.node",
  "category": "runtime",
  "status": "success",
  "observedAt": "2026-09-21T02:30:00-05:00",
  "components": [],
  "warnings": [],
  "errors": [],
  "evidence": []
}
```

### Provider identity

`providerId` is a stable machine-readable identifier. It should be namespaced where useful, for example:

- `host.windows`
- `runtime.node`
- `runtime.java`
- `environment.path`
- `projects.local`
- `git.hygiene`

`category` is a broader grouping such as `runtime`, `environment`, `projects`, or `git`.

Provider IDs must remain stable after release because comparison and downstream reporting may depend on them.

## Provider status

Provider status describes the provider execution outcome, not whether one particular tool is installed.

| Status | Meaning |
|---|---|
| `success` | Provider completed its intended inspection without material warnings. |
| `warning` | Provider completed, but produced one or more noteworthy conditions. |
| `partial` | Provider returned useful data but could not complete part of its intended inspection. |
| `failed` | Provider could not produce a reliable result for its intended scope. |
| `unavailable` | The provider depends on a source or capability that is currently unavailable. |
| `not-applicable` | The provider does not apply to this host or configured audit context. |

A missing optional tool does **not** automatically make the provider fail. For example, a runtime inventory provider can successfully report that a component is not installed.

## Components

A provider may expose zero or more normalized components.

Each component contains:

- `componentId`
- `name`
- `state`
- `installed`
- `activeVersion`
- `discoveredVersions`
- `installations`
- `commandResolutions`
- `versionIntelligence`

### Component state

| State | Meaning |
|---|---|
| `present` | Component is detected and usable enough to identify as installed. |
| `missing` | Component was inspected and is not installed/detected. |
| `partial` | Component exists, but inspection or configuration is incomplete. |
| `unavailable` | Component state cannot currently be inspected because a required source/capability is unavailable. |
| `not-applicable` | Component is not relevant in the current host/context. |
| `unknown` | Available evidence is insufficient to classify the component. |

For `present`, `installed` must be `true`. For `missing`, `installed` must be `false`. Other states may use `true`, `false`, or `null` when the installed state cannot be stated safely.

## Versions

Version values use a common object:

```json
{
  "raw": "v24.13.0",
  "normalized": "24.13.0",
  "channel": null
}
```

`raw` preserves the provider-observed representation. `normalized` is the comparable form when normalization is possible. `channel` may represent concepts such as `stable`, `lts`, `current`, `rc`, or another provider-defined channel.

Providers must not fabricate a normalized version when parsing is uncertain; `normalized` should be `null` instead.

## Installations and command resolution

`installations` represents discovered installation locations independently from command precedence.

`commandResolutions` represents how a command resolves on the current machine. Multiple entries are allowed so PATH/shim collisions can be represented without losing information.

`precedence` is zero-based: `0` is the first effective resolution for that command. `active` indicates the resolution currently selected by the shell/provider logic.

This separation is intentional: an installation can exist without being on PATH, and a command can resolve through a shim rather than directly to an installation directory.

## Version intelligence

Version intelligence is optional in capability, but its object is always present so consumers do not need shape-specific branching.

Its status is one of:

| Status | Meaning |
|---|---|
| `known` | Latest/channel information was successfully determined. |
| `unknown` | The provider did not determine a reliable latest version. |
| `unavailable` | The configured/latest-version source could not be reached or used. |
| `not-applicable` | Latest-version intelligence does not apply to the component. |

The contract currently exposes `latestStable`, `latestLts`, and `latestCurrent`. Providers may leave any of these as `null` when the ecosystem does not define that channel.

An offline or unreachable source must produce `unknown` or `unavailable` data, not terminate the complete workstation audit.

## Warnings and errors

Warnings and errors are structured records rather than free-standing strings.

Example:

```json
{
  "code": "COMMAND_EXIT_NONZERO",
  "message": "Command returned a non-zero exit code.",
  "severity": "warning",
  "componentId": "node",
  "evidenceIds": ["node.version"]
}
```

Codes use stable uppercase identifiers so reports can be filtered and compared without parsing human-readable messages.

Warning severity is `info` or `warning`. Errors use `error`.

## Evidence

Evidence explains how a provider reached a result while preserving the audit safety policy.

Supported evidence types are:

- `command`
- `path`
- `environment`
- `registry`
- `filesystem`
- `api`
- `configuration`
- `derived`

Example:

```json
{
  "evidenceId": "node.version",
  "type": "command",
  "source": "node --version",
  "exitCode": 0,
  "captured": "v24.13.0",
  "redacted": false,
  "attributes": {}
}
```

### Evidence safety rules

Evidence must never become a general-purpose dump mechanism.

Providers must:

- capture only values required to support the audit result;
- use the existing explicit environment-variable allowlist rather than enumerate arbitrary environment variables;
- redact credentials, tokens, secrets, connection strings, or other sensitive values before storing evidence;
- set `redacted` to `true` when the captured value was altered for safety;
- avoid committing real workstation evidence or machine-specific reports to the repository.

`attributes` is an extensibility escape hatch for small, provider-specific normalized facts. It must not be used to bypass the safety rules or recreate an unstructured raw-data dump.

## Contract invariants

Providers and the orchestrator must preserve these invariants:

1. `providerId` is unique within one audit report.
2. `componentId` is unique within one provider result.
3. `evidenceId` is unique within one provider result.
4. Every `evidenceIds` reference resolves to evidence in the same provider result unless a future schema version explicitly defines report-level evidence references.
5. `present` components have `installed: true`.
6. `missing` components have `installed: false`.
7. Provider failure never prevents the orchestrator from attempting later providers.
8. Remote/latest-version failure is represented as data rather than as a fatal audit failure.
9. Machine-specific output remains local and ignored by Git.
10. The audit contract never authorizes workstation mutation.

## Schema versioning

`schemaVersion` is independent from the Workstation repository/tool version.

The initial normalized report schema is `1.0.0`.

Versioning rules:

- patch: clarifications or constraints that do not change valid serialized shapes;
- minor: backward-compatible additions where existing consumers remain valid;
- major: breaking field, semantic, enum, required-property, or structural changes.

A released report must declare the schema version it was produced against. Consumers such as comparison tooling should reject unsupported major versions instead of silently guessing compatibility.

Changes to the schema must be reviewed together with the contract documentation.

## Provider execution protocol

Provider files live under `scripts/Providers` and use the `*.Provider.ps1` naming convention.

Each provider supports two invocation modes:

- `-Describe` returns stable metadata: `providerId`, `category`, and numeric `order`;
- `-Context <object>` performs the read-only inspection and returns one result matching `provider-result.schema.json`.

The orchestrator discovers provider files, reads their descriptions, and executes them in deterministic order by `order`, then `providerId`, then path.

Provider execution is isolated. If one provider throws, returns an invalid envelope, or cannot complete its work, the orchestrator converts that failure into a normalized failed-provider result and continues with the remaining providers.

The shared context currently includes the audit timestamp, Workstation tool version, approved environment-variable names, and compatibility options such as `IncludeWingetInventory`. Providers must not use the context as authority to mutate the workstation.

This protocol keeps provider discovery separate from provider result semantics: the description controls orchestration, while the provider-result schema controls audit data.

## Transition from the v0.2 audit skeleton

The `v0.2.0` audit script uses a monolithic report with sections such as `Tools`, `CommandCollisions`, `PathHealth`, `EnvironmentVariables`, and `PackageManagers`.

Sprint 1 does not require deep ecosystem-specific detection. Instead:

- the shared core runtime will implement normalized execution/evidence behavior;
- the orchestrator will aggregate provider results;
- transitional providers may preserve useful generic command/host information;
- deeper runtime/SDK behavior belongs to later roadmap issues such as #6 and #7;
- `Compare-Workstations.ps1` remains largely legacy until its dedicated comparison milestone (#10).

This keeps `v0.3.0` focused on architecture rather than prematurely implementing every detector.

## Synthetic example

The following example is intentionally synthetic and must not be treated as a real machine baseline:

```json
{
  "schemaVersion": "1.0.0",
  "generatedAt": "2026-09-21T02:30:00-05:00",
  "audit": {
    "mode": "read-only",
    "toolVersion": "0.3.0"
  },
  "host": {
    "name": "SYNTHETIC-WORKSTATION",
    "platform": "windows",
    "architecture": "x64"
  },
  "summary": {
    "status": "success",
    "providerCount": 1,
    "successCount": 1,
    "warningCount": 0,
    "partialCount": 0,
    "failedCount": 0,
    "unavailableCount": 0,
    "notApplicableCount": 0
  },
  "providers": [
    {
      "providerId": "runtime.synthetic",
      "category": "runtime",
      "status": "success",
      "observedAt": "2026-09-21T02:30:00-05:00",
      "components": [],
      "warnings": [],
      "errors": [],
      "evidence": []
    }
  ],
  "warnings": [],
  "errors": []
}
```

The dedicated synthetic provider fixtures are added by #20 after the contract/runtime/orchestrator implementation is in place.
