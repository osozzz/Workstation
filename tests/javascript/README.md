# JavaScript toolchain validation

This suite validates the specialized read-only JavaScript toolchain provider introduced for Sprint 2 issue #27.

It covers:

- standalone Node.js detection;
- NVM for Windows topology and multiple managed Node versions;
- independent npm, pnpm, Corepack, and NVM component states;
- preservation of command-resolution precedence and collisions;
- partial NVM configuration without failing the complete audit;
- representative global JavaScript CLI visibility from command resolution and selected npm/pnpm global package inventory;
- migration of JavaScript-specific ownership out of the transitional command inventory;
- source-level guards against Node/package-manager mutation behavior.

All fixtures are synthetic. They must not contain real workstation paths, usernames, credentials, tokens, machine names, or generated audit reports.

The provider is intentionally read-only. It may inspect local command resolution, allowlisted environment variables, known Node installation locations, NVM version directories, and selected global package metadata from npm/pnpm. Only package names relevant to the maintained CLI coverage are retained; raw global inventory and global-root output are redacted. It must not install, switch, enable, upgrade, remove, migrate, or repair Node.js, NVM, Corepack, npm, pnpm, or global packages.

Latest-version intelligence remains outside this provider and belongs to the later version-intelligence milestone.
