# Sprint 5 Version Intelligence Integration Gate

This gate validates the cross-provider behavior required to close #84 and evaluate the acceptance criteria in #9.

## Coverage

The CI workflow runs the deterministic Sprint 5 fixture suites for:

- shared version-source runtime and offline/malformed/unreachable behavior;
- Node LTS/current plus npm and pnpm update intelligence;
- Angular stable, TypeScript prerelease, and Prisma release-candidate semantics;
- Flutter stable and Java same-major/vendor-aware intelligence;
- WinGet installed-application and upgrade availability intelligence.

The integration gate then validates the cross-cutting behavior that individual suites cannot prove alone:

- all 20 built-in providers still execute in one audit when version intelligence is offline;
- an early controlled provider failure is isolated and does not prevent later providers from running;
- attempted version-intelligence results preserve source identity and checked-at timestamps;
- project-local Node/package-manager pins remain separate from global version intelligence;
- project classification does not modify global runtime evidence;
- WinGet upgrade evidence remains review-only;
- generated reports remain temporary and repository reports are ignored;
- Sprint 5 test sources contain no committed real user-profile paths or common credential/token prefixes.

The controlled project and generated reports are created only under the runner temporary directory and are deleted after validation.
