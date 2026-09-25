# PowerShell static analysis

Workstation uses `PSScriptAnalyzer` as a deterministic CI quality gate for production PowerShell under `scripts/`.

## Analyzer version

CI installs and requires PSScriptAnalyzer `1.25.0`. Pinning the analyzer version prevents rule changes in a future module release from silently changing the result of an existing commit.

## Repository settings

The repository-owned settings file is `/PSScriptAnalyzerSettings.psd1`.

Sprint 7 starts with an explicit safety-focused baseline:

- `PSAvoidUsingAllowUnencryptedAuthentication`
- `PSAvoidUsingBrokenHashAlgorithms`
- `PSAvoidUsingConvertToSecureStringWithPlainText`
- `PSAvoidUsingInvokeExpression`
- `PSAvoidUsingPlainTextForPassword`
- `PSAvoidUsingUsernameAndPasswordParams`
- `PSAvoidUsingWMICmdlet`

The gate evaluates warnings and errors from those rules. Any diagnostic fails CI.

## Explicit exclusions

The initial hardening gate does not enable the following rules:

- `PSAvoidUsingPositionalParameters` — existing production code contains intentional positional calls; converting those calls is separate refactoring work.
- `PSAvoidUsingWriteHost` — command-line entry points intentionally write user-facing progress/status output.
- `PSReviewUnusedParameter` — provider entry points and compatibility surfaces can require parameters that are not consumed in every execution path.
- `PSUseApprovedVerbs` and `PSUseSingularNouns` — the existing internal helper API predates the hardening gate; renaming helpers would be a behavior-neutral but broad refactor.
- `PSUseBOMForUnicodeEncodedFile` — repository encoding policy is UTF-8 and is not coupled to a BOM requirement.
- `PSUseShouldProcessForStateChangingFunctions` — the audit product remains read-only; some internal helper names can look state-changing even though they operate only on in-memory/ephemeral audit data.

Compatibility-specific analyzer rules are intentionally deferred to #117, where Windows PowerShell 5.1 and PowerShell 7 support is tested as an explicit runtime matrix.

These exclusions are narrow and documented. They do not suppress diagnostics inline in production scripts.

## CI behavior

`tests/static-analysis/validate_psscriptanalyzer_gate.ps1` performs two checks:

1. Recursively analyzes only production PowerShell under `scripts/` with the repository settings.
2. Creates a temporary synthetic script outside the repository that contains `Invoke-Expression` and verifies that the analyzer reports `PSAvoidUsingInvokeExpression`.

The negative fixture proves that the gate is capable of failing rather than reporting unconditional success. Temporary files are removed after validation.

Installing PSScriptAnalyzer occurs only on the ephemeral GitHub Actions runner. The Workstation audit runtime itself does not install modules or modify a workstation.
