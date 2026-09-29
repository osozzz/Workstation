# Sprint 7 integration gate

This directory is the release gate for issue #120 and parent issue #11 (v0.9.0 — Audit Hardening).

The area checks in CI prove behavior. This gate proves the hardening surface is complete and consistent:

- `coverage-matrix.json` maps each of the nine acceptance criteria in #11 to committed evidence and to the CI checks that exercise it. Missing evidence, unknown checks, or a dropped criterion fail the gate.
- Every CI job has a stable name, and the `validate` check required by the `main` ruleset runs `always()`, depends on every area check, and fails on any non-success result.
- `docs/README.md` lists every audit and policy document, and `docs/audit/ci-coverage.md` documents every area check and links only to existing documents.
- No production script or test invokes a workstation-mutating operation: persistent environment writes, `setx`, registry writes, package installs or upgrades, global Git configuration, or toolchain switching. The guard inspects real invocations in the syntax tree, including `Invoke-AuditCommand` targets, so lists of forbidden strings do not trigger it.

Every check is also run against controlled failing examples, so the gate cannot pass vacuously.
