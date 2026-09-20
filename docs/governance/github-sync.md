# GitHub Repository Sync

Workstation keeps its intended GitHub repository configuration in `config/github.sync.json`.

The configuration is applied by:

```powershell
.\scripts\Sync-GitHubRepository.ps1
```

This is intentionally separate from workstation auditing. It changes **GitHub repository state**, not the local development workstation.

## What it manages

The sync covers:

- repository description and topics;
- merge-method settings;
- automatic merged-branch deletion and branch-update policy;
- selected public-repository security settings;
- repository labels;
- release/sprint milestones;
- the user-owned `Workstation — Development` Project;
- Project single-select fields and options;
- Project views;
- Issue assignee, labels, milestone, Project membership, and Project field values;
- native parent/sub-issue relationships;
- native blocked-by relationships;
- the `main` repository ruleset;
- cleanup of explicitly listed branches after verifying that a merged Pull Request exists.

The script is designed to be idempotent: rerunning it should converge GitHub toward the declared configuration rather than create duplicate planning objects.

## Prerequisites

- GitHub CLI (`gh`) installed and current enough to support native issue relationships.
- An authenticated GitHub user with administrator access to `osozzz/Workstation`.
- GitHub Project scope.

Verify authentication:

```powershell
gh auth status
```

If Project access is missing:

```powershell
gh auth refresh -s project
```

## Preview

Before applying changes:

```powershell
.\scripts\Sync-GitHubRepository.ps1 -PlanOnly
```

Plan-only mode validates authentication and configuration and describes the intended synchronization without changing GitHub state.

## Apply

```powershell
.\scripts\Sync-GitHubRepository.ps1
```

Optional public-repository security settings can be skipped when diagnosing permission or account-feature availability:

```powershell
.\scripts\Sync-GitHubRepository.ps1 -SkipOptionalSecurity
```

## Governance rules encoded by the sync

The intended `main` workflow is:

- Pull Requests required;
- squash merge only;
- zero required external approvals for the solo-maintainer workflow;
- review conversations resolved before merge;
- linear history;
- the stable `validate` check required;
- force pushes blocked;
- deletion of `main` blocked.

Project planning uses:

- `Status`: Backlog, Ready, In Progress, Review, Done;
- `Priority`: P0 — Critical through P3 — Low;
- `Area`: repository/audit domain;
- `Risk`: Low, Medium, High, Critical.

Planning dimensions belong in Project fields and are not duplicated as labels.

## Security behavior

The sync attempts to enable:

- private vulnerability reporting;
- vulnerability/dependency alerts;
- secret scanning;
- secret-scanning push protection.

Some settings depend on account/repository feature availability. Optional security failures are surfaced as warnings rather than silently ignored.

## Safety

Do not add secrets, tokens, machine reports, or private workstation data to `github.sync.json`.

The configuration contains only public repository governance state.

Branch cleanup is intentionally conservative: a branch in the configured cleanup list is removed only when GitHub reports at least one merged Pull Request with that branch as its head.

## Updating the configuration

Changes to `config/github.sync.json` or the sync script follow the normal repository workflow:

1. assigned Issue;
2. short-lived branch;
3. Pull Request;
4. validation;
5. squash merge;
6. execute the merged sync from `main`;
7. verify the resulting GitHub state.
