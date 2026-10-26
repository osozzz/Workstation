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
| `pnpm add -g <package>@<version>` or `npm install -g <package>@<version>` | `<package>` is `@angular/cli`, `typescript` or `prisma` (policy tracks), or equals the action's `subjectId` (`npm:<package>`) for a global CLI; the manager matches the one that installed the package; `<version>` is a semantic version equal to the action's `targetVersion`. |
| `choco upgrade <packageId> -y` | `<packageId>` matches the action's `subjectId` (`choco:<packageId>`). Runs only from an elevated shell; otherwise the action is skipped. |
| `wsl --update` | Exact text. |
| `pnpm self-update` | Exact text. |
| `python -m pip install pip==<version>` | `<version>` equals the action's `targetVersion`; runs the active `python`. An unpinned upgrade is not allowed. |
| `uv self update` | Exact text; only when uv was installed with its standalone installer. |
| `sdkmanager platform-tools` | Exact text. |
| `sdkmanager cmdline-tools;latest` | Exact text; passed as one argument. |

Anything else, including every action whose `command` is `null` (manual), is never executed. It is reported as skipped.

WinGet calls add `--accept-package-agreements --accept-source-agreements --disable-interactivity`. The confirmation prompt states that agreements will be accepted, so accepting them is part of the operator's explicit consent. Licenses are never accepted for actions the operator did not confirm.

## Selection, preview, and confirmation

- **Dry run is the default.** Without `-Apply`, the executor only prints what it would run, in plan order, and changes nothing.
- **Nothing is selected by default.** The operator chooses actions by `order` or `actionId`, or with `-Risk low` (every low-risk action). There is no "everything" switch that includes high risk. High-risk actions are always manual.
- **Per-action confirmation (default).** With `-Apply`, each action shows its title, versions, risk, reversibility, the exact command, and the agreement notice, and it runs only after the operator answers yes. `-Confirm:$false` is not supported.
- **Batch confirmation (`-ConfirmAll`, from v2.1.0).** Every selected action is validated first and the complete list is shown, with each exact command and agreement notice. The operator then confirms the whole batch once by typing the number of actions that will run; anything else cancels and nothing runs. The same allow-list, elevation, manual and high-risk rules apply. `-ConfirmAll` without `-Apply` is still a dry run.
- The executor never elevates itself. If an installer asks for administrator rights, Windows shows its own prompt and the operator decides.

## Running and failure handling

- Actions run one at a time, in plan order, each with a timeout (30 minutes).
- With per-action confirmation, the executor stops at the first failed action (non-zero exit code or timeout). With `-ConfirmAll`, a failure is recorded and the remaining actions, which are independent package updates, still run; the summary lists every failure. The executor never retries and never rolls back automatically. Reversal, where possible, is the operator's decision.
- Each command runs with its output written to files and an empty standard input. The executor waits only for the process it started, so a child process left running by a tool (for example the Dart processes `flutter upgrade` starts) cannot keep an action running after the update finished, and a prompt receives end-of-input instead of waiting. On timeout the process is stopped and its partial output is kept in the log.
- Interrupting with Ctrl+C stops after the current action. Later actions are not started.

## Execution log

- Each run, including a dry run, writes `reports/update-log/<timestamp>.json` before the first action and updates it after every action. The log records the plan digest, the selected actions, the exact command, start and end times, exit code, a bounded output tail, and the result (`succeeded`, `failed`, `skipped`, or `not-run`).
- The log is local and ignored by Git, like audit reports. It may contain machine-specific output.
- After a run, re-audit and re-plan. The new plan is the source of truth for what remains.

## Never

- Uninstall software, or change PATH or environment variables.
- Change Git repositories, project files, or lockfiles.
- Run manual actions, high-risk actions, or commands outside the allow-list.
- Run without the operator's confirmation, per action or for the whole listed batch.
- Send data anywhere. Execution output stays in the local log.
