# Audit System Coverage

This is the authoritative statement of what the read-only audit covers at v1.0.0 — Baseline Ready. Every category in the v1.0.0 definition (`docs/releases/versioning-and-releases.md`) is implemented as one or more providers that return the normalized contract in `audit-provider-contract.md`.

## Coverage by category

| Category | Provider | Components or findings | Latest-version intelligence |
|---|---|---|---|
| Windows and PowerShell | `host.system` | `windows`, `powershell.windows`, `powershell.core` | not applicable |
| Installed applications and updates | `winget.baseline` | `winget`; optional full inventory (`-IncludeWingetInventory`); available upgrades | review-only upgrade availability per package |
| Windows Subsystem for Linux | `wsl.baseline` | `wsl --version` (with `WSL_UTF8=1`); distributions and their state (`wsl --list --verbose`), without starting any | latest stable release from the `microsoft/WSL` GitHub releases |
| Editor extensions | `editors.extensions` | `vscode`, `cursor`, `windsurf`, `trae`: version and installed extensions (`<cli> --list-extensions --show-versions`) | not checked per extension; the plan runs `<cli> --update-extensions`, which updates only outdated ones |
| Chocolatey packages and updates | `chocolatey.baseline` | `choco`; installed packages (`choco list`); outdated packages (`choco outdated`) | review-only upgrade availability per package; pinned packages are reported and left alone |
| JavaScript runtimes and package managers | `javascript.toolchain` | `node`, `npm`, `pnpm`, `corepack`, `nvm-windows` | Node (LTS and Current), npm, pnpm |
| Global JavaScript CLIs | `javascript.toolchain` | `angular-cli`, `typescript`, `prisma`, `nodemon`, `rimraf`, `zoho-extension-toolkit`, `zoho-catalyst-cli`, `redis-commander` | Angular CLI, TypeScript (stable/prerelease), Prisma (stable/release candidate) |
| Java and build tools | `java.jvm` | `java`, `javac`, `maven`, `gradle` | Java, matched to installed major, vendor, and package type |
| Flutter and Android | `mobile.flutter-android` | `flutter`, `dart`, `android-sdk`, `adb`, `sdkmanager` | Flutter stable channel; platform-tools and cmdline-tools from the Android SDK repository manifest |
| Python | `python.ecosystem` | `python`, `python-launcher`, `pip`, `pipx`, `uv`, `pyenv-win` | Python (endoflife.date, newest released cycle), pip (PyPI) and uv (GitHub releases) |
| .NET | `dotnet.toolchain` | `dotnet-sdk`, `dotnet-runtime`, `dotnet-workloads` | SDK from the official .NET releases index (supported, non-preview channels); runtime and workloads not provided |
| Rust and Go | `rust-go.toolchains` | `rustup`, `rust-toolchains`, `rustc`, `cargo`, `go` | Rust (rust-lang/rust GitHub releases) and Go (go.dev/dl) |
| Developer CLIs | `developer.clis` | `git`, `github-cli`, `docker`, `docker-compose`, `supabase-cli`, `vercel-cli`, `heroku-cli` | not provided |
| Command inventory | `inventory.commands` | resolution evidence for known commands | not applicable |
| PATH and environment | `path.precedence`, `environment.baseline` | Machine/User/Process PATH health, duplicates, dead entries, approved environment variables | not applicable |
| Command precedence | `javascript.precedence`, `jvm-mobile.precedence`, `python-dotnet-rust-go.precedence` | which installation wins on `PATH`, shadowing, and home-variable mismatches | not applicable |
| Local projects | `projects.local`, `projects.javascript-web`, `projects.non-javascript` | bounded discovery under configured roots; project types and pinned runtime/package-manager constraints | not applicable; project pins take precedence over global latest |
| Git health and hygiene | `git.repository-health`, `git.branch-worktree-hygiene` | working-tree state, upstream divergence, stale/merged branches, worktree hygiene | not applicable |
| Cross-PC comparison | `scripts/Compare-Workstations.ps1` | normalized differences between two reports, as `comparison.json` and `comparison.txt` | compares the intelligence each report recorded |

"Not provided" means the component is detected and versioned locally, but no remote latest-version source is queried. Its `versionIntelligence.status` is `not-applicable`, never a fabricated value. Where a remote source is queried but cannot be reached, or offline mode is set (`-OfflineVersionIntelligence`), the status is explicitly `unavailable` or `unknown`.

## Safety guarantees

- The audit is read-only (`docs/policies/audit-safety.md`). It never installs, upgrades, or removes software; changes PATH or environment variables; changes Git state; or accepts package-source agreements. The Sprint 7 gate rejects mutating invocations in scripts and tests.
- Reports stay local under the ignored `reports/` directory. Comparison output is the shareable form and excludes absolute paths, commit IDs, and remote URLs (`docs/audit/privacy-testing.md`).
- Only an approved allowlist of environment variables is read. Credentials, tokens, credential helpers, and Git remote URLs are never collected.
- Both Windows PowerShell 5.1 (`Run-Audit.cmd`) and PowerShell 7 are supported and tested (`docs/policies/powershell-runtime.md`).

## Known limitations

- Platform: Windows workstations only.
- Project discovery runs only under explicitly configured development roots (`config/workstation.local.json`). Without them, the project and Git providers report `not-applicable`.
- Latest-version intelligence needs network access to public registries, and covers only the components listed above.
- Detection reflects what is resolvable on `PATH` plus documented install locations, registry entries, and environment variables. Tools installed elsewhere may be reported as missing.
- Remaining runtime differences between Windows PowerShell 5.1 and PowerShell 7 are listed in `docs/policies/powershell-runtime.md`.
- What CI does and does not exercise is listed in `docs/audit/ci-coverage.md`.

## After v1.0.0

Workstation mutation, such as installing, upgrading, migrating, or synchronizing toward the standard in `config/workstation.policy.json`, is outside the read-only audit. It is versioned separately after v1.0.0.
