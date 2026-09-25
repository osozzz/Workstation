# Pester test conventions

Workstation uses `Pester 6.2.0` as the direct PowerShell test framework for audit-core behavior and provider-contract orchestration.

## Scope

The Sprint 7 Pester baseline covers two layers:

1. `tests/pester/core/Audit.Core.Tests.ps1` directly tests normalized core behavior such as provider status, evidence redaction, issue normalization, and missing-command handling.
2. `tests/pester/provider-contract/Audit.Orchestrator.Tests.ps1` runs the real audit orchestrator against a temporary synthetic provider directory.

The provider-contract suite intentionally does not use the repository's production provider directory. Its synthetic providers represent:

- successful inspection with a `present` component;
- successful inspection with a `missing` component;
- a `partial` provider;
- an `unavailable` provider;
- a provider that throws;
- a later provider that verifies the prior failure was normalized and execution continued.

This keeps the contract suite deterministic and independent from tools installed on the GitHub Actions runner.

## Configuration

Repository defaults live in `/PesterConfiguration.psd1`. CI installs the exact Pester version used by the repository gate and `tests/pester/validate_pester_gate.ps1` applies the configuration with an absolute test path.

The validator also launches a temporary child Pester run containing an intentionally failing `Should` assertion. The child run must return a failure; otherwise the gate itself fails. This proves that failed Pester assertions can fail CI rather than being silently ignored.

## Safety boundary

Pester fixtures and reports are created only under Pester's temporary test workspace or the runner temporary directory. The suite does not install, upgrade, remove, or remediate workstation software; mutate PATH/environment configuration; or modify Git repositories.

Pester installation itself occurs only on the ephemeral GitHub Actions runner.
