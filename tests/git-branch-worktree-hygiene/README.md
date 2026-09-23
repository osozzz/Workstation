# Git branch and worktree hygiene validation

This suite validates issue #68 and the `git.branch-worktree-hygiene` provider with temporary controlled repositories and worktrees.

It covers:

- locally merged branch candidates;
- unmerged branches;
- gone-upstream branches;
- stale branch age evidence using an explicit threshold;
- documented branch-prefix deviations;
- current/default/permanent branch protection;
- branches checked out in linked worktrees;
- linked worktree dirty state;
- Git-reported prunable worktree metadata;
- advisory-only cleanup findings.

The test setup mutates only disposable repositories under the runner temp directory to establish known states. The provider itself must never delete branches/worktrees, prune worktrees, checkout/reset branches, rewrite history, or modify Git configuration.
