# PowerShell static analysis

Sprint 7 introduces a repository-owned PSScriptAnalyzer gate for production PowerShell sources.

## Scope

The gate analyzes every `.ps1` and `.psm1` file under `scripts/`. Test fixtures and generated/local reports are intentionally outside the production-analysis surface.

CI uses PSScriptAnalyzer `1.25.0` so analyzer behavior is reproducible.

## Configuration

`PSScriptAnalyzerSettings.psd1` is the canonical repository configuration.

The initial rule set is intentionally bounded to defect and security-oriented rules:

- `PSAvoidAssignmentToAutomaticVariable`
- `PSAvoidUsingConvertToSecureStringWithPlainText`
- `PSAvoidUsingEmptyCatchBlock`
- `PSAvoidUsingInvokeExpression`
- `PSAvoidUsingPlainTextForPassword`
- `PSAvoidUsingUsernameAndPasswordParams`

The repository currently has no global analyzer exclusions: `ExcludeRules = @()`.

A future exclusion must be narrow, justified by repository behavior, and documented here rather than added only to make CI green.

PowerShell-version compatibility rules are deliberately deferred to Sprint 7 issue #117, which owns the Windows PowerShell 5.1 / PowerShell 7 compatibility boundary.

## Gate behavior

`tests/static-analysis/validate_psscriptanalyzer.ps1`:

1. requires the pinned analyzer version;
2. loads the repository settings explicitly;
3. runs a controlled in-memory `Invoke-Expression` violation and verifies that it produces a finding and fails the gate logic;
4. analyzes the complete production PowerShell surface;
5. fails CI if any configured Error or Warning finding remains.

The validation produces console diagnostics only. It does not install, update, repair, or mutate workstation configuration, and it does not persist machine-specific reports.
