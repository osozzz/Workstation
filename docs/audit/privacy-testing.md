# Privacy and redaction testing

`tests/pester/privacy/Audit.Privacy.Tests.ps1` turns the privacy rules of `docs/policies/audit-safety.md` and `SECURITY.md` into automated checks.

## Output boundaries

There are two kinds of output:

| Output | Audience | May contain | Must never contain |
|---|---|---|---|
| Audit report (`*.json`, `*.md` under `reports/`) | The local machine only; ignored by Git | Local paths, repository paths, commit IDs, host name | Credentials, tokens, secrets, credential helpers, Git remote URLs, environment variables outside the approved allowlist, contents of project files beyond their canonical manifest fields |
| Comparison output (`comparison.json`, `comparison.txt`) | Shareable between machines | Normalized, path-safe identities and relative project paths | Everything above, plus absolute development-root and repository paths, commit IDs, and Git remote hosts |

## Runtime checks

The suite builds a synthetic development root whose single project plants a unique canary for each prohibited kind of data:

- an environment variable outside the approved allowlist (name and value);
- a Git remote URL with embedded user and token, on a reserved `example.invalid` host;
- a Git `credential.helper`;
- a secret inside `package.json`, and an auth token in `.npmrc`;
- an untracked file name and the Git author email.

It then runs the real audit and `Compare-Workstations.ps1` in child processes under Windows PowerShell 5.1 and PowerShell 7. The checks require that:

- the synthetic project and repository were actually inspected, so an absent canary is meaningful;
- no canary appears in the JSON report, the Markdown report, `comparison.json`, or `comparison.txt`;
- the commit ID, development root, repository path, and remote host do not appear in comparison output.

## Committed-source checks

- Every committed text file is scanned for GitHub, npm, AWS, JWT, and Slack token shapes; private-key headers; credentials embedded in URLs; secret assignments; real user-profile paths; and personal email addresses. RFC 2606 reserved names (`.invalid`, `.example`, `.test`, `example.com`) stay allowed for fixtures.
- No committed file may contain the user name or computer name of the machine running the tests. The detector sources that list CI identities on purpose are excluded.
- `reports/` and `config/workstation.local.json` must stay ignored by Git.
- Production scripts must never enumerate the whole environment (`Get-ChildItem Env:`, `[Environment]::GetEnvironmentVariables()`). Reading a single named variable is allowed.

## Detector self-tests

Every detector runs against controlled prohibited examples, assembled at runtime so the test file itself holds no secret-like literal, and against allowed synthetic values. A detector that stops matching fails the suite.

An end-to-end check was also verified by hand: injecting a full environment dump into the report fails both runtime checks and the static enumeration guard.

## Limits

- The token shapes are heuristics. A secret with no recognizable shape is covered only by the runtime canaries and by review.
- Local reports intentionally keep machine-specific paths and commit IDs, because they never leave the machine. Share comparison output, not raw reports.
