# Git repository health validation

This suite validates issue #67 and the `git.repository-health` provider using only temporary controlled repositories.

It covers:

- clean repositories;
- staged, unstaged, and untracked working-tree changes;
- detached HEAD;
- missing upstream;
- locally known ahead/behind state;
- diverged branches;
- unpushed commit detection;
- no remote URL, credential-helper, or authentication-state collection;
- `git --no-optional-locks` read-only inspection;
- dependency on `projects.local` repository candidates instead of independent filesystem traversal.

The test setup may mutate its own disposable repositories to establish known states. The provider itself must remain read-only and must never fetch, pull, push, checkout, reset, clean, stash, commit, or mutate Git configuration.
