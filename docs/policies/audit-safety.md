# Audit Safety Policy

The audit system is read-only by default.

It may:

- inspect commands and versions;
- inspect known safe installation locations;
- inspect PATH and an explicit environment-variable whitelist;
- inspect package-manager inventories and update availability;
- inspect Git repository/worktree state;
- inspect configured development roots;
- generate local JSON/Markdown/HTML reports.

It must not, during audit:

- install or uninstall software;
- mutate PATH or environment variables;
- delete branches or worktrees;
- upgrade dependencies;
- rewrite Git history;
- expose credentials, tokens, secrets, or arbitrary environment variables;
- commit machine-specific reports.

Offline or unreachable version sources should produce an explicit unknown/unavailable state rather than fail the entire audit.

Local reports may contain machine-specific paths and commit IDs because they stay on the machine. Comparison output is the shareable form and excludes them. `docs/audit/privacy-testing.md` lists the automated checks behind these rules.
