# Sprint 8 integration gate

Release gate for issue #147 and parent issue #12 (v1.0.0 — Baseline Ready).

- `coverage-matrix.json` maps all twelve acceptance criteria of #12 to committed evidence and CI checks. The two criteria that need real workstations (`pc1-audit`, `pc2-comparison`) carry an explicit `manual` marker; automated criteria may not.
- `docs/architecture/audit-system-roadmap.md` must name every built-in provider, discovered by running each provider with `-Describe`, so a new provider cannot ship undocumented.
- The operator runbook must cover both launchers, local configuration, safety, and coverage, and the README must link it.

The gate also checks a deliberately broken matrix and prints the manual evidence still required after release (#148).
