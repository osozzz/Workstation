# Shared version-intelligence source runtime validation

This suite validates issue #79 without using live Internet.

Coverage includes:

- normalized `known`, `unknown`, `unavailable`, and `not-applicable` version-intelligence objects;
- source identity and deterministic checked-at timestamps;
- synthetic successful HTTPS response;
- timeout and unreachable source normalization;
- non-success HTTP normalization;
- explicit offline behavior without invoking transport;
- malformed JSON -> `unknown`;
- oversized/truncated response -> `unknown`;
- bounded source response retention;
- safe evidence attributes that exclude response body, URI, headers, credentials, and exception text;
- rejection of non-HTTPS and credential-bearing source URIs.

The test uses an injected transport and never accesses the public Internet.
