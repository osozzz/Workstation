# Contract Validation

Sprint 1 keeps contract validation intentionally lightweight and deterministic.

## What is validated

`validate_contract_fixtures.py`:

- checks both JSON Schemas as Draft 2020-12 schemas;
- validates every committed provider fixture against `provider-result.schema.json`;
- validates every committed report fixture against `audit-report.schema.json`;
- enforces documented invariants such as unique provider/component/evidence identifiers and valid evidence references;
- verifies report summary counts and aggregate status;
- generates invalid cases in memory to prove malformed envelopes and invalid state/value combinations are rejected;
- scans fixtures for common machine-specific or secret-bearing markers.

Committed fixtures are synthetic only. Invalid examples are generated in memory during validation and are not stored in the repository.

## Fixture coverage

Provider fixtures cover:

- present / success;
- missing / success;
- partial;
- failed;
- unavailable / offline.

The normalized report fixture combines representative provider outcomes in one synthetic audit envelope.

## Run locally

From the repository root:

```powershell
python -m pip install -r .\tests\contract\requirements.txt
python .\tests\contract\validate_contract_fixtures.py
```

The validator does not make network requests. Network access is only required when the pinned Python validation dependency is not already installed.

Full Pester, PSScriptAnalyzer, provider-specific behavior matrices, and broader hardening remain reserved for #11.
