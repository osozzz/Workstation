# JavaScript/web project detection validation

This suite validates issue #65 and the `projects.javascript-web` provider.

It builds a temporary bounded project tree, runs `projects.local`, then feeds that normalized discovery evidence to the JavaScript/web classifier.

Coverage includes Node/package projects, Angular, Next.js, Prisma, explicit and missing Node pins, package-manager intent, lockfiles, conflicting signals, and a non-JavaScript candidate that must not be classified.

The provider does not execute project code, invoke package managers, inspect `node_modules`, or perform independent development-root traversal.
