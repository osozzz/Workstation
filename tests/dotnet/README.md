# .NET toolchain validation

This suite validates the specialized read-only .NET SDK/runtime/workload provider introduced for Sprint 2 issue #31.

It covers:

- active `dotnet` command resolution and SDK version;
- multiple installed SDKs from `dotnet --list-sdks`;
- multiple runtime products and versions from `dotnet --list-runtimes`;
- version-specific SDK/runtime installation paths;
- allowlisted `DOTNET_ROOT`, `DOTNET_ROOT_X64`, and `DOTNET_ROOT_X86` state;
- installed workloads through `dotnet workload list --machine-readable`;
- both modern JSON-only workload output and the older machine-readable wrapper format;
- runtime-only hosts, unavailable workload inspection, and a fully unavailable CLI;
- migration of `dotnet-sdk` ownership out of the transitional command inventory;
- source-level guards against SDK/workload/tool installation, update, repair, restore, or other mutation.

All committed fixtures are synthetic. They must not contain real workstation paths, usernames, credentials, tokens, machine names, or generated audit reports.

The workload parser only normalizes the installed workload IDs. Any `updateAvailable` data emitted by the CLI is intentionally ignored because latest-version intelligence belongs to a later milestone.

The workstation policy uses latest-stable for the global .NET toolchain while allowing projects to pin locally compatible SDK versions. Sprint 2 detects only the architecture represented by the active `dotnet` resolution; cross-architecture inventory can be expanded separately without changing this provider contract.
