# JavaScript PATH/environment precedence validation

This suite validates Sprint 3 issue #49 as read-only derived analysis.

It combines synthetic evidence from the existing JavaScript toolchain, command-to-PATH precedence, and approved environment-variable models. It does not execute Node.js, NVM, npm, pnpm, Corepack, or package-manager discovery.

The committed cases cover:

- an intended NVM layout with `NVM_HOME` and `NVM_SYMLINK` represented in Process PATH order;
- stale NVM root/symlink configuration;
- a direct Node.js installation shadowing the configured NVM symlink;
- npm and pnpm PATH collisions;
- active pnpm precedence that disagrees with `PNPM_HOME`;
- absence of optional NVM/pnpm tooling without false conflict findings.

All paths are synthetic. No fixture contains real workstation paths, usernames, machine names, credentials, tokens, or generated machine reports.
