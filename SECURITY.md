# Security Policy

Workstation is a public repository for reusable developer-workstation audit and standardization logic. Machine-specific diagnostics, environment inventories, local paths, and generated reports must remain local and must not be committed.

## Reporting a vulnerability

Do not publish exploitable details in a public Issue.

Use GitHub's private vulnerability reporting or security advisory capability when available, or contact the repository owner privately through the contact channel listed on the owner's GitHub profile.

Include, when possible:

- affected script, provider, workflow, or configuration surface;
- reproduction steps;
- expected vs. observed behavior;
- impact;
- suggested mitigation;
- whether the issue appears actively exploitable.

## Sensitive information

Never include passwords, MFA material, auth cookies, access or refresh tokens, provider secrets, private keys, production credentials, private package-registry credentials, or private source data in Issues, Pull Requests, logs, screenshots, fixtures, or reports committed to this repository.

Generated workstation outputs belong in local ignored directories only.

## Supported versions

Before v1.0.0, only the latest `main` and active release candidate are supported.

After v1.0.0, the support policy tracks the current production release unless a later security policy explicitly changes it.
