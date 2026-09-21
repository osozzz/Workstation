# Python / .NET / Rust / Go precedence fixtures

This suite validates Sprint 3 issue #51 without mutating the runner.

It exercises derived cross-provider intelligence for:

- `PYENV_ROOT` versus active `pyenv` and Python origins;
- multiple `.NET` root variables without assuming an architecture;
- `CARGO_HOME` versus `rustup`, `rustc`, and `cargo` command precedence;
- `RUSTUP_HOME` versus discovered managed-toolchain roots;
- `GOROOT` versus active `go` command precedence;
- configured versus observed `GOROOT` / `GOPATH` while preserving `GOTOOLCHAIN=local`;
- missing optional roots/tooling without false conflict findings.

The dedicated validator confirms that `python-dotnet-rust-go.precedence` owns zero
components, performs no runtime discovery, filesystem probing, environment mutation,
toolchain switching, package installation, or Go auto-download behavior.
