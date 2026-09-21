# PATH scope model validation

This suite validates the normalized PATH model introduced for Sprint 3 issue #46.

It exercises synthetic Machine, User, and Process PATH values and verifies:

- stable entry ordering and scope identity;
- quote, slash, repeated-separator, trailing-separator, and case normalization;
- case-insensitive comparison keys on Windows;
- duplicate detection within one PATH scope;
- persistent duplicate detection between Machine and User scopes;
- explicit exclusion of Process PATH from persistent cross-scope duplicate findings;
- environment-reference expansion and unresolved-reference handling;
- empty-segment filtering;
- drive-root and UNC path preservation.

The fixture uses only synthetic paths. The validation may set a temporary process-scoped test variable and restores its previous value before exiting. It does not modify Machine/User PATH or persistent environment variables.
