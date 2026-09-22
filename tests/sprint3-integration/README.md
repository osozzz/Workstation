# Sprint 3 integration gate

This directory contains the release-level validation for v0.5.0 PATH and environment intelligence.

The gate does not add detection logic. It verifies that the Sprint 3 work from issues #46-#51 works together and remains within the read-only audit boundary.

It validates:

- explicit coverage of every acceptance criterion in parent issue #7;
- normalized Machine/User/Process PATH behavior, including deterministic scope ordering;
- duplicate, missing, unresolved, and cross-scope PATH/environment cases;
- the approved environment-variable allowlist and prohibition on arbitrary enumeration;
- active/shadowed command precedence without fabricated PATH origins;
- aligned and conflicting JavaScript, JVM/mobile, and Python/.NET/Rust/Go fixtures;
- built-in provider failure isolation in CI;
- fixture/report safety and absence of committed machine reports;
- the controlled real-machine report when invoked with `--report`.

`coverage-matrix.json` is the machine-readable evidence map used to determine whether parent issue #7 has complete acceptance coverage.
