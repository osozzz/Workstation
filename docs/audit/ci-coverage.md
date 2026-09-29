# CI checks and tested coverage

`.github/workflows/validate.yml` runs on every pull request and on every push to `main`. It is split into jobs with stable names, so a failure identifies its hardening area directly.

## Required check

The `main` ruleset requires a single status check, `validate`. It is an aggregator job that runs after every area job and passes only when all of them pass; it prints each area's result. The area jobs can be added, split, or renamed without editing the ruleset, and a skipped or cancelled area still blocks the merge.

Pinned PowerShell modules are installed through `.github/scripts/Install-PinnedModule.ps1`. Hosted runners intermittently lose the PSGallery registration, so the helper re-registers it and retries with backoff. That infrastructure noise does not fail a required check, while a real installation failure still does after the last attempt.

## Area checks

| Check | What it runs | Documented in |
|---|---|---|
| `static-analysis` | PSScriptAnalyzer gate, Windows PowerShell 5.1 compatibility gate, PowerShell syntax, the Sprint 7 hardening gate (acceptance coverage, check integrity, documentation index, no workstation mutation), JSON configuration | `powershell-static-analysis.md`, `../policies/powershell-runtime.md`, `tests/sprint7-integration/README.md` |
| `pester` | Pester core, orchestrator contract, failure paths, collection safety (both hosts), provider tests, and privacy (both hosts) | `pester-testing.md`, `failure-path-testing.md`, `collection-safety.md`, `privacy-testing.md` |
| `contracts` | Normalized schemas, hardening fixture matrix, per-provider fixtures, Sprint 2 fixtures | `schema-fixture-hardening.md`, `../architecture/audit-provider-contract.md` |
| `providers` | PATH/environment models, precedence, project discovery, Git health and hygiene, version intelligence, and the Sprint 3, 4, and 5 gates | `../architecture/version-intelligence-runtime.md` |
| `comparison` | Comparison contract, every comparison category, report outputs, the Sprint 6 gate | `../architecture/comparison-contract.md` |
| `integration` | Real audit smoke tests on the runner, plus the controlled Sprint 4 integration audit validated by the Sprint 2, 3, and 4 suites | `../architecture/audit-provider-contract.md` |
| `windows-powershell` | Project/Git discovery and version-intelligence validators under `shell: powershell` | `../policies/powershell-runtime.md` |

## Proof that gates can fail

Each gate is backed by a controlled failing example, so a green run is meaningful:

- The PSScriptAnalyzer and compatibility gates analyze a synthetic violating script and require the expected diagnostics.
- The Pester gate runs a child suite with a deliberately failing assertion and requires it to fail.
- Failure-path, collection-safety, and privacy suites include negative cases: malformed provider output, unsafe idioms, and prohibited secret examples.
- Schema validators generate invalid cases in memory that must be rejected, so no invalid fixture is ever committed.
- The Sprint 7 gate rejects a broken coverage matrix and 13 controlled workstation-mutating invocations.

## Known gaps

- **Live Internet:** CI never contacts real version sources. Transports are synthetic or a loopback listener, by design, and real online audits are verified manually.
- **Runner tools:** the GitHub runner has most developer tools installed. Minimal-`PATH` audits and fake-command provider tests cover machines without them, but other tool combinations are not exercised.
- **Platform:** only Windows runners are used. The audit targets Windows workstations.
- **Runtime parity:** Windows PowerShell 5.1 comparison JSON is semantically but not byte-identical to PowerShell 7, and the Sprint 6 gate runs only on PowerShell 7 (see the runtime policy).
- **Heuristics:** compatibility analysis cannot see splatted parameters, and secret scanning relies on token shapes; runtime checks and review cover the rest.
