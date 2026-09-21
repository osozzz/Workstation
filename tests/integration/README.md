# Sprint 2 integration gate

This suite is the final integration gate for Runtime & SDK Detection milestone `v0.4.0` and issue #34.

It validates the specialized providers as one system rather than as isolated ecosystems.

## Static integration checks

`validate_sprint2_suite.py` validates every committed Sprint 2 provider fixture against the normalized provider schema and confirms that the suite collectively covers:

- successful and unavailable provider states;
- present, missing, and partial component states;
- multiple installations;
- multiple command resolutions/collisions;
- all specialized Sprint 2 provider IDs;
- fixture safety against real user paths and common secret/token markers;
- synchronization between the core environment allowlist and the aggregate audit context;
- complete migration of transitional command inventory ownership.

The ecosystem-specific validators remain authoritative for their deeper domain rules. This integration validator checks the cross-provider guarantees that only become meaningful once all providers coexist.

## Controlled real-machine audit

CI runs `scripts/Audit-Workstation.ps1` on the Windows runner with its output directory under `RUNNER_TEMP`.

The generated JSON report is then validated against `audit-report.schema.json` and checked for:

- the exact built-in provider set;
- no failed built-in provider;
- no report-level errors;
- internally consistent provider summary counts;
- unique provider IDs and unique cross-provider component ownership;
- zero components remaining in the transitional command inventory;
- preserved developer-CLI safety boundaries;
- `DOTNET_ROOT`, `DOTNET_ROOT_X64`, and `DOTNET_ROOT_X86` coverage in the environment baseline.

The JSON and Markdown reports are not uploaded as artifacts and are deleted from the runner after validation. Machine-specific reports remain local/ephemeral and `reports/` stays Git-ignored.

This is an integration gate, not the later hardening milestone. Broad static-analysis/Pester matrices remain outside Sprint 2.
