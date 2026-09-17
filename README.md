# Developer Workstation Standard

A Windows developer-workstation toolkit for auditing, standardizing, updating, and comparing development environments across multiple PCs.

## Current release

`0.1.0` — Phase 1 audit and workstation baseline.

## Repository model

This public repository stores only reusable scripts, policies, configuration, validation, and documentation. Generated audits, inventories, comparisons, and other machine-specific outputs remain local to each cloned workstation and are excluded from version control.

Recommended layout after cloning:

```text
workstation/
├── config/
│   └── workstation.policy.json
├── reports/                 # generated locally; ignored by Git
├── scripts/
│   ├── Audit-Workstation.ps1
│   ├── Compare-Workstations.ps1
├── .gitattributes
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── README.md
├── Run-Audit.cmd
├── VERSION
└── .github/
```

## Clone on another PC

With GitHub CLI:

```powershell
gh repo clone osozzz/Workstation
cd Workstation
```

Or with Git:

```powershell
git clone https://github.com/osozzz/Workstation.git
cd Workstation
```


## Phase 1 — Audit (safe)

This phase does **not install, uninstall, update, or edit PATH/environment variables**. It inventories the machine and creates a JSON baseline plus a readable Markdown report.

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Audit-Workstation.ps1 -IncludeWingetInventory
```

Or double-click/run:

```text
Run-Audit.cmd
```

Reports are written to `reports/` and are ignored by Git.

The audit currently covers:

- Windows + PowerShell
- Node / npm / pnpm / NVM
- Angular / TypeScript / Prisma / nodemon / rimraf
- Zoho ZET / Catalyst / Heroku / Redis Commander
- Flutter / Dart
- Python / pip / pipx / uv
- Java / Maven / Gradle
- .NET
- Rust / Cargo / rustup
- Go
- Git / GitHub CLI
- Docker / Docker Compose
- Android ADB
- Supabase / Vercel
- WinGet available upgrades
- npm and pnpm global packages
- PATH duplicates, missing entries, and unresolved variables
- command collisions such as multiple Node, npm, Dart, or Java installations
- a safe whitelist of environment variables including `PNPM_HOME`, `JAVA_HOME`, `ANDROID_HOME`, and `NVM_HOME`

The audit intentionally does not dump every environment variable because developer machines often contain credentials, tokens, or other secrets.

## Compare two PCs

Run the audit on both machines, then compare the generated JSON reports locally:

```powershell
.\scripts\Compare-Workstations.ps1 `
  -Reference .\reports\MAIN-PC.json `
  -Target .\reports\SECOND-PC.json
```

Reports are not intended to be committed. Transfer them privately when a cross-machine comparison is needed.

## Workstation policy

`config/workstation.policy.json` records the target decisions for the workstation standard:

- WinGet for Windows applications
- NVM for Windows for Node runtimes
- latest Node LTS as the default, with Current installed alongside it
- pnpm as the primary/global JavaScript package manager
- project dependencies pinned locally
- Angular major project migrations handled explicitly
- global TypeScript may be current while projects use framework-compatible local TypeScript
- global Prisma RC is allowed while projects pin their required Prisma version
- Flutter stable with Flutter-bundled Dart preferred
- no dead or duplicate PATH entries

## Planned phases

The repository will grow in controlled stages:

1. `Migrate-NodeToNvm.ps1`
2. `Update-Toolchains.ps1`
3. `Update-WindowsApps.ps1`
4. `Repair-Environment.ps1`
5. `Audit-Projects.ps1`
6. `Update-Workstation.ps1` with safe and major-upgrade modes

Major project migrations remain explicitly gated instead of being applied blindly.