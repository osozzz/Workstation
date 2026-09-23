# Node, npm, and pnpm version intelligence validation

This suite validates issue #80 with deterministic synthetic version-source data and a real local provider invocation.

It covers Node Latest LTS versus Latest Current, the LTS-default policy, npm/pnpm latest stable metadata, update-available/already-current comparisons, explicit offline/unavailable behavior, safe source identities/timestamps, and the absence of Node/NVM/package-manager mutation.

CI does not require live access to nodejs.org or the npm registry.
