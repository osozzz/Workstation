# Policy evaluation contract

A policy evaluation compares one normalized audit report with the declared standard in `config/workstation.policy.json` (`docs/policies/workstation-policy.md`). The result follows `schemas/policy-evaluation.schema.json`.

Evaluation is read-only. It reads an existing report and the policy, and it never runs tools or changes the machine.

## Shape

- `policy`: the policy `schemaVersion` and a SHA-256 `digest` of its canonical JSON, so evaluations can be tied to the exact policy used.
- `report`: the evaluated report's schema version, generation time, audit mode and tool version, and host identity. This is the same endpoint shape as comparison output.
- `summary`: `status`, plus counts per finding status.
- `findings`: one entry per evaluated rule and subject.

## Finding status

| Status | Meaning | Evidence |
|---|---|---|
| `compliant` | The report's evidence meets the policy setting. | required |
| `deviation` | The report's evidence contradicts the policy setting. | required |
| `unknown` | Evidence that could decide the setting is missing or unavailable in this report, for example latest versions in an offline audit. | optional |
| `not-evaluable` | The audit never collects evidence for this setting, for example audit-safety switches that the audit itself enforces. | none; `observed` is `null` |

`summary.status` is `deviations` if any finding deviates, `incomplete` if none deviate but some are `unknown`, and `compliant` otherwise.

Every finding carries `ruleId`, the dotted `policyKey` it evaluates (for example `node.defaultTrack`), `componentId` and `subjectId` when they apply, `expected` and `observed` values, a human-readable `message`, and `evidence` references (`providerId`, `componentId`, `evidenceId`) into the audit report. A decision is never made without citing the evidence behind it.

## Determinism

Findings are ordered by `policyKey`, then `ruleId`, then `subjectId`, and each combination appears at most once. The same report and policy always produce byte-identical output.

## Privacy

Evaluation output is shareable, like comparison output. It must not contain absolute paths, user-profile paths, commit IDs, remote URLs, credentials, or secrets.

- PATH findings report counts, not paths.
- Projects use path-safe identities (`project:<hash>`), never their location.

## Validation

`tests/policy/validate_policy_evaluation_contract.py` runs in the `contracts` CI check. It validates committed fixtures that cover every finding status, checks the summary, ordering, and privacy invariants, and rejects 15 controlled invalid variants.
