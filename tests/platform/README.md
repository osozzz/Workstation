# Platform Provider Validation

Sprint 2 platform validation covers issue #26 without expanding into the full
hardening scope reserved for #11.

## Covered provider behavior

Synthetic fixtures validate:

- Windows platform state plus normalized version/build metadata;
- Windows PowerShell present state;
- PowerShell Core present and missing states;
- multiple PowerShell Core installations and command resolutions;
- partial PowerShell discovery when installation evidence exists without a
  resolvable command;
- WinGet present, unavailable, and partial source-diagnostic states;
- raw WinGet source details are redacted while source-query health is retained.

All fixtures are synthetic and deterministic. They must not contain real
workstation names, user-profile paths, tokens, credentials, or generated
machine audit output.

## Read-only ownership checks

The validator also guards the source split introduced by #26:

- `Host.Provider.ps1` owns Windows PowerShell and PowerShell Core;
- `WinGetBaseline.Provider.ps1` must not run `winget upgrade`;
- WinGet detection must not use `--accept-source-agreements`;
- `CommandInventory.Provider.ps1` must not duplicate WinGet ownership.

Installed-versus-latest intelligence remains reserved for #9.

## Run locally

From the repository root:

```powershell
python -m pip install -r .\tests\contract\requirements.txt
python .\tests\platform\validate_platform_fixtures.py
```
