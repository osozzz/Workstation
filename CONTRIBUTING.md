# Contributing

## Workflow

- `main` is the canonical branch.
- Create a short-lived branch for every change.
- Use intent-based branch prefixes such as `feat/`, `fix/`, `docs/`, `test/`, `refactor/`, `chore/`, `ci/`, `build/`, `perf/`, or `security/`.
- Open a pull request into `main`.
- Keep commits meaningful and use Conventional Commit-style prefixes.
- Resolve review conversations and required checks before merging.
- Use squash merge as the default merge strategy, then delete the temporary branch.
- Do not force-push `main`.

## Commit examples

```text
feat: add workstation environment audit
fix: handle missing PATH entries safely
docs: document Node runtime policy
test: validate policy schema
chore: update toolchain baseline
ci: validate PowerShell scripts
```

## Repository scope

Version reusable scripts, policies, configuration, documentation, and validation assets. Do not commit machine-specific reports, exported inventories, credentials, tokens, local paths containing sensitive data, or generated diagnostic output.

## Pull requests

A pull request should explain what changed, why it changed, how it was validated, and whether it affects workstation policy or requires manual migration steps.