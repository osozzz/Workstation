# Sprint 10 integration gate

Release gate for issue #176 and parent issue #159 (v1.2.0 — Update Plan).

- `coverage-matrix.json` maps the phase-2 acceptance criteria of #159 to committed evidence and CI checks. The real-report rehearsal carries an explicit `manual` marker; automated criteria may not.
- The operator runbook must cover `Run-Plan.cmd`, and `docs/README.md` must index the update plan contract.

The gate also checks a deliberately broken matrix.
