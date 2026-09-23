# WinGet upgrade intelligence validation

This suite validates issue #83 using deterministic WinGet table and failure fixtures.

It covers installed-application normalization, upgrade availability, fully current systems, unavailable sources, source-agreement requirements, generic command failures, truncated package identities, explicit checked-at timestamps, and read-only provider wiring.

The suite does not require live WinGet sources and does not install, upgrade, remove, repair, or accept package/source agreements.
