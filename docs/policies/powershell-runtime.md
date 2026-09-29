# PowerShell runtime policy

## Supported runtimes

All production PowerShell under `scripts/` supports both runtimes:

| Runtime | Why it is supported |
|---|---|
| Windows PowerShell 5.1 | `Run-Audit.cmd` launches the audit with `powershell.exe`, and it ships with every supported Windows version. |
| PowerShell 7.x | CI runs primarily on `pwsh`, and it is the recommended interactive shell. PowerShell 7.5+ is preferred for comparison because `ConvertFrom-Json -DateKind String` keeps report timestamps byte-for-byte. |

Neither runtime is optional: a change that works on only one of them is a defect.

The Pester suites and the Python validators are test tooling, not production code. Pester runs under PowerShell 7 in CI, and suites that must prove 5.1 behavior start `powershell.exe` child processes.

## Enforcement

**Static gate.** `tests/static-analysis/validate_windows_powershell_compatibility.ps1` runs the PSScriptAnalyzer rules `PSUseCompatibleTypes`, `PSUseCompatibleCommands`, and `PSUseCompatibleSyntax` against the Windows PowerShell 5.1 profile. The analyzer resolves only full type names, so the gate first rewrites short names such as `[IO.Path]` in a scratch copy of the scripts. A controlled negative fixture proves the gate detects every construct that has broken 5.1 in this repository.

**Runtime checks on Windows PowerShell 5.1 in CI:**

- the real audit with a minimal `PATH` and no local configuration (`tests/pester/collection-safety`, which starts both hosts);
- the version-intelligence runtime, including the default HTTP transport against a loopback listener, and the JavaScript version intelligence;
- project discovery, project classification, and Git health/hygiene validators;
- the `Compare-Workstations.ps1` entry point (`tests/comparison-output`).

## Runtime differences handled in code

| Difference | Handling |
|---|---|
| `ConvertFrom-Json -Depth` and `-DateKind` exist only on PowerShell 7; PowerShell 7 converts date-time text into local `DateTime` values | `ConvertFrom-WorkstationJson` in `Comparison.Core` and the version-source parser pass these parameters only where supported. Timestamps stay strings. |
| `Invoke-WebRequest -SkipHttpErrorCheck` exists only on PowerShell 7; 5.1 throws `WebException` for non-2xx responses | The default version-source transport returns non-2xx statuses as data and maps 5.1 failures onto the PowerShell 7 exception types. |
| `System.Net.Http` is not loaded by default on 5.1 | `VersionIntelligence.Core` loads it explicitly. |
| .NET Core-only APIs such as `[IO.Path]::GetRelativePath` and `[Convert]::ToHexString` | Replaced with .NET Framework equivalents. The static gate rejects new uses. |
| `.Count` on a single item fails under StrictMode on 5.1; `@($null)` on an `[object[]]` parameter has one element on 7 and none on 5.1 | Collection-safe idioms (`docs/audit/collection-safety.md`) and null filtering. |
| Native stderr redirected with `2>&1` becomes a terminating error under `$ErrorActionPreference = 'Stop'` on 5.1 | Production commands run through `Invoke-AuditCommand`, whose module scope keeps the default preference. Test helpers that call `git` directly lower the preference locally and check `$LASTEXITCODE`. |

## Known limitations

- The analyzer cannot see parameters passed through splatting (`Invoke-WebRequest @parameters`) or instance members on untyped variables. Runtime checks on 5.1 cover those paths.
- Windows PowerShell 5.1's `ConvertTo-Json` escapes `<`, `>`, `&`, and `'` as `<`-style sequences. JSON output is semantically identical across runtimes but not byte-identical.
- The Sprint 6 comparison gate builds in-memory reports that 5.1 serializes with a `{"value": [...], "Count": n}` wrapper, so that gate runs only on PowerShell 7. Real reports produced by the audit are unaffected.
