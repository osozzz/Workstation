# Schema and fixture hardening

Sprint 7 validates normalized audit and comparison contracts with a committed synthetic state matrix in addition to the earlier contract-specific validators.

## Hardening fixtures

The canonical fixtures live under `tests/hardening-contract/fixtures/`:

- `audit-state-matrix.json` covers component states `present`, `missing`, `partial`, `unavailable`, and `unknown`, plus provider-level `partial`, `unavailable`, and `not-applicable` outcomes.
- `comparison-state-matrix.json` covers known drift, a conflicting/different partial component state, unavailable and unknown comparison outcomes, not-applicable semantics, and directional target-only presence.
- `fixture-manifest.json` pins a canonical SHA-256 digest for each matrix fixture.

All timestamps, versions, host names, identifiers, and values are fixed synthetic data. The validator rejects common user-profile, credential, token, and email markers.

## Schema validation

`tests/hardening-contract/validate_hardening_fixtures.py` validates:

- `schemas/audit-report.schema.json` and all nested provider results;
- `schemas/comparison-result.schema.json`;
- audit summary counts and aggregate status;
- provider/component/evidence identity invariants;
- comparison summary counts and directional relation coverage;
- required component, provider, and version-intelligence state coverage;
- explicit offline/unavailable behavior;
- fixture canonical digests and JSON round-trip determinism.

Negative cases are generated in memory rather than committed as intentionally invalid fixtures.

## Compatibility behavior

The audit report schema continues to accept only audit schema `1.0.0`.

The comparison result schema declares `auditSchemaMajor: 1`, so comparison endpoint descriptors now accept only semantic audit versions in major `1`. A `2.x` endpoint therefore fails schema validation instead of being silently representable in a comparison result.

The comparison runtime independently rejects unsupported audit schema majors before comparison. The existing comparison-core gate remains responsible for that execution-level compatibility behavior.

The normalized comparison output itself remains fixed at schema `1.1.0`.

## Determinism and safety

Fixtures contain no real workstation paths, usernames, hostnames, account identifiers, credentials, or tokens. Canonical JSON digests make unintended fixture drift visible in CI.

This validation is read-only. It does not install, upgrade, remove, remediate, or mutate workstation state.
