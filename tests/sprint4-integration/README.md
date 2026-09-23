# Sprint 4 integration gate

This directory is the release gate for issue #69 and parent issue #8.

It validates the complete Project & Git Discovery slice rather than any single provider:

- bounded machine-local development-root discovery;
- JavaScript/web and non-JavaScript project classification;
- project-local runtime/package-manager constraints;
- Git repository working-tree/upstream health;
- branch and worktree hygiene;
- privacy and read-only safety boundaries;
- provider failure isolation;
- controlled Windows audit integration;
- coverage of all nine acceptance criteria in #8.

The controlled report remains ephemeral under RUNNER_TEMP and is never committed or uploaded.
