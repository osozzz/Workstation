# Sprint 9 integration gate

Release gate for issue #166 and parent issue #159 (v1.1.0 — Policy Evaluation).

- `coverage-matrix.json` maps the phase-1 acceptance criteria of #159 to committed evidence and CI checks. The real-report rehearsal carries an explicit `manual` marker; automated criteria may not.
- Every rule in the evaluation module must match a policy key, checked in both directions independently of the Pester drift test.
- The operator runbook must cover `Run-Evaluate.cmd`, and `docs/README.md` must index the evaluation contract.

The gate also checks a deliberately broken matrix.
