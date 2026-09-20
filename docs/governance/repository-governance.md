# Repository Governance

## Branch model

- `main` is the only permanent branch.
- All normal work uses short-lived branches created from the latest `main`.
- Do not create permanent `develop`, `staging`, or release branches.
- Branches use intent-based prefixes such as `feat/`, `fix/`, `docs/`, `test/`, `refactor/`, `chore/`, `ci/`, `build/`, `perf/`, or `security/`.
- Merged branches should be deleted.
- Stale and merged local/remote branch detection will be part of the audit system.

## Pull requests

- Normal changes to `main` go through a Pull Request.
- Keep each PR scoped to one Issue or one cohesive governance task.
- Required checks must pass before merge.
- Resolve review conversations before merge.
- Squash merge is the default merge method.
- Force pushes and direct history rewrites on `main` are not part of the normal workflow.

## Worktree hygiene

Before destructive or migration operations:

- the relevant Git working tree must be clean;
- staged changes must be understood;
- untracked files must be reviewed;
- unpushed commits must be surfaced;
- detached HEAD states must be surfaced;
- stale or prunable worktrees must be detected before cleanup.

The audit system detects these conditions. Future repair tooling may automate cleanup only through explicit, gated actions.

## Authorship

The project owner remains responsible for repository work.

Automated tools must not add authorship/co-authorship trailers, generated-by notices, promotional attribution, badges, or equivalent provenance metadata unless explicitly required for a specific dependency or legal reason.
