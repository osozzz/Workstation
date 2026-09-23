# Local workstation configuration

Machine-specific Workstation settings belong in `config/workstation.local.json`.

That file is intentionally ignored by Git and must never contain shared baseline data.

Start from:

`config/workstation.local.example.json`

Current local-only project discovery settings:

- `projects.developmentRoots`: explicit directories that may be scanned for repositories/project candidates.
- `projects.maxDiscoveryDepth`: bounded traversal depth from each configured root; valid range is 1-32 and the default is 6.

The audit does not fall back to scanning an entire drive or the user profile when no development roots are configured.

Filesystem roots such as `C:\` are rejected as too broad, and reparse-point roots/descendants are not followed by `projects.local`.

Real machine paths remain local report evidence and must not be committed.


Current local-only Git hygiene settings:

- `git.branchStaleDays`: branch-tip age threshold used by the Git hygiene provider; valid range is 1-3650 days and the default is 90.

A stale branch is an advisory finding based on the tip commit age. Staleness alone never authorizes branch deletion or makes a branch a cleanup candidate.
