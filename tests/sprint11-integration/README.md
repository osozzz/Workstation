# Sprint 11 integration gate

Release gate for issue #183 and parent issue #159 (v2.0.0 — Controlled Updates).

- `coverage-matrix.json` maps the phase-3 acceptance criteria of #159 to committed evidence and CI checks. The real apply rehearsal carries an explicit `manual` marker; automated criteria may not.
- The operator runbook must cover `Run-Update.cmd`, and `docs/README.md` must index the update execution safety policy.

The gate also checks a deliberately broken matrix.
