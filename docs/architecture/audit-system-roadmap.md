# Audit System Roadmap

The audit engine will evolve as modular providers returning a normalized result contract.

Planned detection coverage includes:

- Windows and PowerShell;
- WinGet and installed applications;
- Node, npm, pnpm, NVM/Corepack where present;
- Angular, TypeScript, Prisma, and global JavaScript CLIs;
- Java/JDK/JRE, JAVA_HOME, Maven, and Gradle;
- Flutter, Dart, Android SDK, and ADB;
- Python, py launcher, pip, pipx, uv, and version managers where present;
- .NET SDKs/runtimes/workloads;
- Rust, Cargo, and rustup;
- Go;
- Git and GitHub CLI;
- Docker and Compose;
- Supabase, Vercel, Heroku, and Zoho tooling where installed;
- PATH and selected environment variables;
- local project discovery and per-project runtime/package constraints;
- Git repository/worktree hygiene;
- installed-vs-latest version intelligence;
- normalized cross-PC comparison.

The provider architecture is established in v0.3.0. Subsequent milestones expand ecosystem-specific detection, environment intelligence, project discovery, version intelligence, comparison, and hardening.
