# Rust and Go toolchain validation

This suite validates the specialized read-only Rust/Go provider introduced for Sprint 2 issue #32.

It covers:

- rustup presence/version and installed toolchains through `rustup toolchain list`;
- active/default/channel metadata for rustup-managed toolchains;
- rustc and Cargo independently, including command-resolution collisions;
- a safety guard that refuses to execute rustup proxy binaries when no active installed toolchain is proven, preventing accidental rustup auto-install behavior;
- standalone Rust without inferring that rustup owns the installation;
- allowlisted `RUSTUP_HOME` and `CARGO_HOME`;
- Go version and command resolution with `GOTOOLCHAIN=local` injected only into the isolated child process, preventing module-driven toolchain switching/downloads;
- read-only `go env -json GOROOT GOPATH` inspection without retaining the raw JSON;
- allowlisted `GOROOT` and `GOPATH` mismatch findings;
- migration of Rust/Cargo/rustup/Go ownership out of the transitional command inventory;
- source-level guards against toolchain installation/update/default changes, Cargo package mutation, and `go env -w` or Go package installation.

All committed fixtures are synthetic. They must not contain real workstation paths, usernames, credentials, tokens, machine names, or generated audit reports.

The provider does not infer toolchain ownership unless local command/path evidence proves it. A standalone `rustc`/Cargo installation is reported as standalone rather than being attributed to rustup.

The workstation policy keeps Rust on stable/latest-stable and Go on latest-stable globally while allowing repositories to pin compatible local toolchain versions. Actual latest-version lookup and upgrade recommendations remain in the later version-intelligence milestone.

Rustup 1.28.0 is the minimum safe-inspection baseline for this provider. Modern rustup probes disable automatic installation in the isolated child process; older or unverifiable rustup binaries remain visible as partial state but are not executed.
