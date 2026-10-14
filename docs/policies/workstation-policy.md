# Workstation policy

`config/workstation.policy.json` declares the intended developer-workstation standard. `schemas/workstation-policy.schema.json` defines its shape, and CI validates the committed policy against it (`tests/policy/validate_policy_schema.py`). Unknown sections, misspelled keys, missing keys, and invalid values fail validation instead of silently weakening evaluation.

The policy describes the target state only. It never authorizes the audit to change a machine. Audit-safety switches are pinned by the schema, so editing the policy cannot enable license acceptance, automatic installation, or inspection of accounts, credentials, Git configuration, or the Docker daemon.

## Value sets

- **Track** (`*Track`): `latest-stable`, `lts`, or `release-candidate-allowed`.
- **Legacy manager policy**: `detect-and-migrate`, `detect-without-execution`, or `ignore`.

## Sections

| Section | Keys and meaning |
|---|---|
| `windows` | `applicationManager` (`winget`); `updatePolicy`: `review-then-upgrade` (updates are reviewed before applying) or `report-only` |
| `node` | `manager` (`nvm-windows`); `defaultTrack` (`lts` or `current`); `alsoInstallCurrent`; `projectVersionsMustBePinned`; `managerTrack`; `legacyManagerPolicy` |
| `javascript` | `primaryPackageManager` and `globalPackageManager` (`pnpm` or `npm`); `npmRole` (`bundled-fallback` or `primary`); `projectDependencies` (`local-and-pinned`) |
| `angular` | `globalCliTrack`; `projectMajorUpgradesRequireExplicitMigration` |
| `typescript` | `globalTrack`; `projectsMustUseLocalCompatibleVersion` |
| `prisma` | `globalTrack`; `projectsMustUseLocalPinnedVersion` |
| `flutter` | `channel` (`stable`, `beta`, or `main`); `sdkTrack`; `dartSource` (`flutter-sdk-preferred` or `standalone-allowed`) |
| `path` | `allowMissingEntries`; `allowDuplicateEntries`; `auditCommandCollisions` |
| `versioning` | `globalDefaultTrack`; `prereleasePolicy` (`explicit-opt-in-only` or `allowed`); `projectCompatibilityOverridesGlobal` |
| `java` | `defaultTrack`; `projectsMustUseLocalCompatibleVersion` |
| `android` | `sdkToolsTrack`; `platformToolsTrack`; `preferAndroidHome`; `acceptLicensesDuringAudit` (always `false`) |
| `python` | `defaultTrack`; `windowsManager` (`python-install-manager`, `python-launcher`, or `pyenv-win`); `projectsMustUseLocalCompatibleVersion`; `virtualEnvironments` (`per-project`); `packageToolsTrack` |
| `dotnet` | `defaultTrack`; `projectsMustUseLocalCompatibleVersion`; `workloadsTrack`; `inspectWorkloadsReadOnly` (always `true`) |
| `rust` | `manager` (`rustup`); `defaultChannel` (`stable`, `beta`, or `nightly`); `defaultTrack`; `managerTrack`; `projectsMayPinToolchain`; `autoInstallDuringAudit` (always `false`); `minimumSafeInspectionVersion` (`x.y.z`); `legacyManagerPolicy` |
| `go` | `defaultTrack`; `projectsMustUseLocalCompatibleVersion`; `inspectEnvironmentReadOnly` (always `true`) |
| `developerClis` | `defaultTrack`; `inspectAuthenticationState`, `inspectAccountState`, `inspectGitConfiguration`, `inspectDockerDaemon`, `inspectDockerContexts` (all always `false`) |

## Changing the policy

Change the policy and its schema in the same pull request. Adding a value to an enum is a deliberate decision, and so is adding a section: the schema rejects anything it does not list. Evaluating audit reports against the policy is planned in #159.
