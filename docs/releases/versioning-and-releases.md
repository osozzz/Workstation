# Versioning and Releases

Workstation follows Semantic Versioning for repository releases.

## Roadmap

- `v0.1.0` — Initial Audit Skeleton
- `v0.2.0` — Repository Foundation
- `v0.3.0` — Audit Core
- `v0.4.0` — Runtime & SDK Detection
- `v0.5.0` — PATH & Environment Intelligence
- `v0.6.0` — Project & Git Discovery
- `v0.7.0` — Version Intelligence
- `v0.8.0` — Cross-PC Comparison
- `v0.9.0` — Audit Hardening
- `v1.0.0` — Baseline Ready

## v1.0.0 definition

`v1.0.0` means the read-only audit system can inspect, normalize, and compare the required workstation categories without modifying the machine.

That includes installed software, runtimes/SDKs, package managers, PATH/environment health, local development projects, Git/worktree hygiene, available updates/version intelligence, and cross-PC comparison.

The first real baseline used to define the workstation standard should be generated only after this point.

## Release rules

- Tags are immutable release markers.
- GitHub Releases correspond to meaningful repository versions, not every PR.
- `CHANGELOG.md` records release-level changes.
- Major workstation migrations and mutation/update tooling remain outside the read-only audit milestone and are versioned separately after v1.0.0.
