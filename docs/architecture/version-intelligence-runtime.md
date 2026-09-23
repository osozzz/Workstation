# Version Intelligence Source Runtime

Sprint 5 adds remote/latest-version intelligence without coupling local workstation detection to network availability.

The shared runtime lives in:

- `scripts/Core/VersionIntelligence.Core.psm1`

It intentionally separates **source transport/decoding** from **ecosystem channel interpretation**.

## Public helpers

### `Invoke-AuditVersionSource`

Performs one bounded, read-only source lookup.

The helper:

- accepts HTTPS sources only;
- rejects embedded URI credentials;
- uses a finite timeout;
- bounds the response retained for downstream parsing;
- records a caller-supplied source identity and checked-at timestamp;
- normalizes offline, timeout, unreachable, invalid transport, and non-success HTTP states to `unavailable`;
- supports an injected transport script block for deterministic tests;
- does not require authentication/account state;
- does not install, update, remove, migrate, or otherwise mutate workstation state.

The returned source result is transient runtime data. Providers must not copy the raw `body` into audit evidence.

### `ConvertFrom-AuditVersionSourceJson`

Decodes a source result without interpreting ecosystem release channels.

It returns:

- `known` when a successful bounded response contains valid JSON;
- `unknown` for empty, truncated, malformed, or otherwise uninterpretable successful responses;
- `unavailable` when the source lookup itself is unavailable.

The decoded JSON is then interpreted by the ecosystem-specific provider.

### `New-AuditVersionIntelligence`

Builds the normalized component `versionIntelligence` object defined by the provider contract.

It enforces:

- `known` has at least one version channel plus source/timestamp;
- `unknown` and `unavailable` preserve source/timestamp but do not fabricate versions;
- `not-applicable` has no source/timestamp/version payload.

### `Get-AuditVersionSourceEvidenceAttributes`

Returns safe metadata for API evidence:

- source status;
- checked-at timestamp;
- whether network was attempted;
- HTTP status code when present;
- content type;
- byte count;
- truncation state;
- normalized failure kind.

It intentionally excludes the raw response body, request URI, headers, credentials, cookies, and exception text.

## Provider pattern

A Sprint 5 ecosystem provider should:

1. preserve its existing local component/runtime evidence;
2. call `Invoke-AuditVersionSource`;
3. store only safe source metadata as audit evidence;
4. decode the response separately;
5. interpret ecosystem-specific stable/LTS/current/prerelease rules;
6. construct normalized version intelligence;
7. leave local detection intact when remote intelligence is unknown or unavailable.

A source failure is data, not a fatal audit failure.

## CI and fixtures

CI must not depend on live Internet.

Synthetic transports represent:

- successful source responses;
- timeout;
- unreachable source;
- HTTP failure;
- malformed JSON;
- oversized/truncated responses;
- explicit offline mode.

This keeps release-channel parsers deterministic while production providers can later use public official/package-registry HTTPS endpoints.


## Audit offline mode

`scripts/Audit-Workstation.ps1 -OfflineVersionIntelligence` keeps all local detection active while preventing remote version-source requests.

This mode is used by CI and is useful for disconnected or restricted environments. Installed/runtime evidence remains available; installed components that would normally query remote latest-version sources expose `versionIntelligence.status = unavailable` with explicit source/check metadata rather than failing the provider or complete audit.

Normal audit execution without this switch may query the public HTTPS sources owned by the relevant ecosystem provider.
