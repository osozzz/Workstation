# Update plan contract

An update plan lists, in order, everything on one PC that can be updated. It is built from one normalized audit report and `config/workstation.policy.json`. The result follows `schemas/update-plan.schema.json` (schema version 1.1.0; 1.1.0 added the `chocolatey`, `wsl`, `npm-registry`, `toolchain` and `consolidation` sources).

Planning is read-only. A plan describes commands; it never runs them. Applying a plan is a later, separate phase with its own safety rules (#159).

## Sources

- **`policy`**: a `deviation` from the policy evaluation (`policy-evaluation-contract.md`), for example Node behind its LTS track or missing PATH entries. `source.policyKey` names the setting.
- **`winget`**: an upgrade that WinGet reports for an installed package, from the `winget` or `msstore` (Microsoft Store) source. `subjectId` is `winget:<packageId>`. Store upgrades add `--source msstore` to the command, because Store IDs are only unambiguous within that source. Store apps that are not in the WinGet msstore catalog are not visible to WinGet and are updated by the Store itself.
- **`wsl`**: WSL is behind its latest stable release. The command is `wsl --update`. Running distributions are shut down while WSL updates.
- **`npm-registry`**: pnpm itself (`pnpm self-update`) and global JavaScript CLIs without a policy track (for example nodemon, rimraf, Zoho CLIs, redis-commander) when the npm registry reports a newer version. `subjectId` is `npm:<package>`, and the command uses the manager that installed the package (`pnpm add -g` or `npm install -g`), so it is not duplicated under the other one. npm itself is not planned: the policy treats it as the copy bundled with Node.js.
- **`toolchain`**: developer tools updated by their own command when their latest-version source reports a newer release: pip (`python -m pip install pip==<version>`, pinned to the reviewed PyPI version), uv (`uv self update`, GitHub releases; manual unless uv was installed with its standalone installer), Android SDK platform-tools (`sdkmanager platform-tools`) and command-line tools (manual: sdkmanager cannot replace the tools it runs from, so they are updated from Android Studio), both from Google's SDK repository manifest. A numeric suffix such as adb's `37.0.0-14910828` is a build number and is ignored when comparing.
- **`consolidation`**: a tool owned by more than one package manager, for example Python installed through Chocolatey, WinGet and the Python Install Manager, or Visual Studio Build Tools seen by both Chocolatey and WinGet. The action is manual (`cleanup`, medium risk) and names each manager and its package IDs, because upgrading the same tool through several managers can install side-by-side copies. Matching uses anchored package-ID patterns per tool. When the policy names WinGet as the application manager (`windows.applicationManager`) and WinGet manages a shared tool, the plan leaves out that tool's Chocolatey upgrades, so a batch never upgrades it twice. For Python this is per minor version: `python3NN` is left out only when WinGet manages Python 3.NN. Likewise, WinGet's `Microsoft.WSL` upgrade is left out when `wsl --update` is planned, because it installs the newer release.
- **`chocolatey`**: an outdated Chocolatey package that is not pinned. `subjectId` is `choco:<packageId>`, and the command is `choco upgrade <packageId> -y`, which needs an elevated shell. Pinned packages are left alone.

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
- Turns each WinGet upgrade with a reliable identity into `winget upgrade --id <packageId> --exact`, and each unpinned outdated Chocolatey package into `choco upgrade <packageId> -y`.
- Emits commands only when they are unambiguous: WinGet upgrades, `flutter upgrade`, `flutter channel <channel>`, `pnpm add -g <cli>@<version>` for global JavaScript CLIs (the policy's global package manager), installing pnpm, and installing the Python Install Manager. Everything else is manual; a manual runtime upgrade says whether WinGet manages the installation, from the WinGet inventory.
- Sets an upgrade's risk to `medium` when the major version changes, and to `low` otherwise. Catalog entries set the risk of other actions.

Output is byte-identical on Windows PowerShell 5.1 and PowerShell 7.

## Validation

`tests/policy/validate_update_plan_contract.py` runs in the `contracts` CI check. It validates committed fixtures, which cover every kind, risk and source. It checks the summary, ordering, uniqueness, and privacy invariants, and it rejects 15 controlled invalid variants. Given file paths, it validates generated plans instead; CI plans `tests/fixtures/reports/mixed-provider-report.json` this way. `tests/pester/policy/PolicyEvaluation.Tests.ps1` covers each action source, and `tests/launchers/validate_launchers.ps1` checks that `Run-Plan.cmd` (Windows PowerShell 5.1) and PowerShell 7 write identical bytes.
