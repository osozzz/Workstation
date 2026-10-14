# Update Execution Safety Policy

From v2.0.0, the toolkit can apply updates to a workstation. This policy defines when and how it may do so. It applies only to the update executor. The audit, the policy evaluation, the update plan, and the comparison remain read-only (`audit-safety.md`).

## Boundary with the read-only tools

- Only the executor entry point (`scripts/Update-Workstation.ps1`, launcher `Run-Update.cmd`) may change the machine. Its execution code lives in `scripts/Execution/`.
- Every other script stays under the Sprint 7 no-mutation gate. `scripts/Execution/` is the only path the gate exempts, and it has its own tests.
- Running the audit, evaluation, plan, or comparison never triggers execution.

## Input

- The executor reads an `update-plan.json` that validates against `schemas/update-plan.schema.json`. It never recomputes the plan.
- A plan whose audit report is older than 24 hours is refused. Re-run the audit and the plan instead.
- A plan built from a different policy than the current `config/workstation.policy.json` is refused (`policy.digest` must match).

## Allowed commands

Only these command shapes run. The executor parses each one from the plan's `command`, validates every part, and rebuilds the call from those parts. A plan's command text is never passed to a shell or `Invoke-Expression`.

| Shape | Validation |
|---|---|
| `winget upgrade --id <packageId> --exact` (optionally `--source msstore`) | `<packageId>` matches the action's `subjectId` (`winget:<packageId>`) and the WinGet ID character set; `--source msstore` only for Microsoft Store packages. |
| `winget install --id pnpm.pnpm --exact` | Exact text. |
| `winget install --id Python.PythonInstallManager --exact` | Exact text. |
| `flutter upgrade` | Exact text. |
| `flutter channel <channel>` | `<channel>` is `stable`, `beta`, or `master`. |
| `pnpm add -g <package>@<version>` | `<package>` is `@angular/cli`, `typescript`, or `prisma`; `<version>` is a semantic version equal to the action's `targetVersion`. |

Anything else, including every action whose `command` is `null` (manual), is never executed. It is reported as skipped.

WinGet calls add `--accept-package-agreements --accept-source-agreements --disable-interactivity`. The confirmation prompt states that agreements will be accepted, so accepting them is part of the operator's explicit consent. Licenses are never accepted for actions the operator did not confirm.

## Selection, preview, and confirmation

- **Dry run is the default.** Without `-Apply`, the executor only prints what it would run, in plan order, and changes nothing.
- **Nothing is selected by default.** The operator chooses actions by `order` or `actionId`, or with `-Risk low` (every low-risk action). There is no "everything" switch that includes high risk. High-risk actions are always manual in v2.0.0.
- **Per-action confirmation.** With `-Apply`, each action shows its title, versions, risk, reversibility, the exact command, and the agreement notice, and it runs only after the operator answers yes. `-Confirm:$false` is not supported in v2.0.0.
- The executor never elevates itself. If an installer asks for administrator rights, Windows shows its own prompt and the operator decides.

## Running and failure handling

- Actions run one at a time, in plan order, each with a timeout (30 minutes).
- The executor stops at the first failed action (non-zero exit code or timeout). It never retries and never rolls back automatically. Reversal, where possible, is the operator's decision.
- Interrupting with Ctrl+C stops after the current action. Later actions are not started.

## Execution log

- Each run writes `reports/update-log/<timestamp>.json` before the first action and updates it after every action. The log records the plan digest, the selected actions, the exact command, start and end times, exit code, a bounded output tail, and the result (`succeeded`, `failed`, `skipped`, or `not-run`).
- The log is local and ignored by Git, like audit reports. It may contain machine-specific output.
- After a run, re-audit and re-plan. The new plan is the source of truth for what remains.

## Never, in v2.0.0

- Uninstall software, or change PATH or environment variables.
- Change Git repositories, project files, or lockfiles.
- Run manual actions, high-risk actions, or commands outside the allow-list.
- Run without a per-action confirmation.
- Send data anywhere. Execution output stays in the local log.
