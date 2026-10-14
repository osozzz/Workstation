# Update plan contract

An update plan lists, in order, everything on one PC that can be updated. It is built from one normalized audit report and `config/workstation.policy.json`. The result follows `schemas/update-plan.schema.json`.

Planning is read-only. A plan describes commands; it never runs them. Applying a plan is a later, separate phase with its own safety rules (#159).

## Sources

- **`policy`**: a `deviation` from the policy evaluation (`policy-evaluation-contract.md`), for example Node behind its LTS track or missing PATH entries. `source.policyKey` names the setting.
- **`winget`**: an upgrade that WinGet reports for an installed package. `subjectId` is `winget:<packageId>`.

## Actions

Each action has:

- `order`, its 1-based position, and `actionId`, a stable identity such as `winget-upgrade:Git.Git` or `policy:node.defaultTrack`.
- `kind`: `upgrade`, `install`, `configure`, or `cleanup`.
- `componentId` and `subjectId` when they apply.
- `title` and `message` in plain language.
- `currentVersion` and `targetVersion` when versions apply.
- `command`: the exact command that would run, for example `winget upgrade --id Git.Git --exact`. It is `null` when the action needs the operator, for example when the command would contain a user-specific path, or for a migration.
- `risk`: `low` for routine, isolated updates; `medium` when the update may affect projects or other tools; `high` for migrations or removals that are hard to undo.
- `reversible`: whether the change can be undone directly.
- `evidence`: references into the audit report, in the same shape as evaluation evidence. Every action cites at least one.

`summary` counts actions in total, by risk, reversible actions, and manual actions (those without a command).

## Determinism

Actions are ordered by risk (`low`, `medium`, `high`), then by `actionId` in ordinal order. `order` counts 1, 2, 3, ... with no gaps, and each `actionId` appears once. The same report and policy always produce byte-identical output.

## Privacy

Plans are shareable, like evaluation output. They must not contain absolute paths, user-profile paths, commit IDs, remote URLs, credentials, or secrets. A command that would need a user path is not emitted; the action becomes manual and its message points to the audit report.

## Producer

`scripts/Plan-WorkstationUpdate.ps1` (launcher: `Run-Plan.cmd`) builds the plan with `scripts/Core/UpdatePlan.Core.psm1` and writes `update-plan.json` and `update-plan.txt`. It runs the policy evaluation first, then:

- Turns each policy `deviation` into one action from a per-key catalog. Per-project deviations (pins, lockfiles) are grouped into one action per key. A deviation without a catalog entry still becomes a manual action, so none is dropped.
- Turns each WinGet upgrade with a reliable identity into `winget upgrade --id <packageId> --exact`.
- Emits commands only when they are unambiguous: WinGet upgrades, `flutter upgrade`, `flutter channel <channel>`, `pnpm add -g <cli>@<version>` for global JavaScript CLIs (the policy's global package manager), and installing pnpm. Everything else is manual.
- Sets an upgrade's risk to `medium` when the major version changes, and to `low` otherwise. Catalog entries set the risk of other actions.

Output is byte-identical on Windows PowerShell 5.1 and PowerShell 7.

## Validation

`tests/policy/validate_update_plan_contract.py` runs in the `contracts` CI check. It validates committed fixtures, which cover every kind, risk and source. It checks the summary, ordering, uniqueness, and privacy invariants, and it rejects 15 controlled invalid variants. Given file paths, it validates generated plans instead; CI plans `tests/fixtures/reports/mixed-provider-report.json` this way. `tests/pester/policy/PolicyEvaluation.Tests.ps1` covers each action source, and `tests/launchers/validate_launchers.ps1` checks that `Run-Plan.cmd` (Windows PowerShell 5.1) and PowerShell 7 write identical bytes.
