# Safe environment-variable intelligence validation

This suite validates Sprint 3 issue #47 using only approved environment-variable names and synthetic values.

Coverage includes aligned and conflicting scopes, missing filesystem roots, unset and empty values, unresolved references, approved nested references, GOPATH path-list semantics, and case-insensitive duplicate snapshot rejection.

The safety regression test deliberately creates a process-only unapproved variable with a sentinel value. An approved variable references that name, and the model must preserve the `%NAME%` token without reading or emitting the sentinel value.

Temporary directories and the process-only sentinel variable are restored or deleted in `finally`. No User/Machine environment variables or PATH values are modified.
