# Developer CLI validation

This suite validates the specialized read-only developer CLI provider introduced for Sprint 2 issue #33.

It covers:

- Git and GitHub CLI version/resolution detection;
- Docker CLI detection through `docker --version` without daemon inspection;
- Docker Compose detection through the modern `docker compose version` plugin command;
- legacy `docker-compose --version` detection for migration/continuity without treating it as the preferred invocation;
- Supabase, Vercel, and Heroku CLI version/resolution detection;
- multiple command resolutions and collision findings;
- resolvable but non-functional CLI states;
- complete migration of the remaining transitional command inventory ownership;
- continuity of Zoho Extension Toolkit, Zoho Catalyst CLI, and Redis Commander coverage already owned by the JavaScript provider;
- explicit guards against authentication/session discovery, Git configuration collection, Docker daemon/context inspection, service control, deployment, package installation, and other mutation.

All committed fixtures are synthetic. They must not contain real workstation paths, usernames, account names, credentials, tokens, machine names, Docker contexts, Git configuration, or generated audit reports.

Only local version commands are executed. The provider does not run account-aware commands such as `gh auth`, `vercel whoami`, Heroku authentication commands, or Supabase login/link operations.

For Docker, `docker --version` is intentionally used instead of `docker version` so the audit only asks the local CLI for its own version and does not inspect the Docker Engine. The current Compose path is `docker compose`; the legacy `docker-compose` command is retained only as diagnostic compatibility evidence.

The workstation policy uses latest-stable for developer CLIs. Actual latest-version lookup and upgrade recommendations remain in the later version-intelligence milestone.
