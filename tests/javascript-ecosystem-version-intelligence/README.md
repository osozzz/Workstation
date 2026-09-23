# Angular, TypeScript, and Prisma version intelligence validation

This suite validates issue #81 with deterministic synthetic npm registry dist-tag data.

It covers Angular CLI latest stable, TypeScript stable versus prerelease channels, Prisma stable versus release-candidate channels, explicit source/check timestamps, offline/unavailable behavior, project-compatibility safeguards, and the absence of automatic migration or package mutation.

CI does not require live access to the npm registry.
