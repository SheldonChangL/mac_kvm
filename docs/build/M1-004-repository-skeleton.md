# M1-004 Repository Skeleton

## Outcome

M1-004 establishes the repository roots and a valid SwiftPM workspace with a zero-behavior application shell. It adds no product feature or protocol behavior.

## Layout

| Path | Ownership at this stage |
|---|---|
| `Apps/macOS/MacKVM/` | Zero-behavior macOS application shell |
| `Packages/` | Reserved for first-party Swift modules |
| `Tests/` | Contract tests now; unit, integration, conformance, fixture, and system targets follow |
| `Tools/` | Repository-local verification and automation |
| `docs/` | Specifications, ADRs, build notes, and tooling documentation |
| `Package.swift` | Root SwiftPM workspace metadata and future target entry point |

Tracked placeholder files preserve empty roots until their owning Issues add content. They carry no runtime behavior.

## Build entry points

- `swift build` compiles the zero-behavior `MacKVM` executable target.
- `Tools/verify/M1-004-repository-skeleton.sh` validates required paths and runs the build from any working directory.
- M1-005 adds the macOS 14 deployment target and native arm64/Rosetta verification without changing application behavior.
- Canonical `make` gates and CI are owned by M1-008 through M1-010 and will backfill M1-001 through M1-004 before M1 completion.

## Boundary and failure behavior

- Missing files/directories produce a non-zero verifier exit.
- An invalid repository-root argument produces a non-zero verifier exit.
- An invalid `Package.swift` propagates SwiftPM's non-zero exit.
- The verifier is read-only and creates no persistent resources, so cancellation and cleanup behavior is not applicable.

## Scope controls

- The only Swift target is a zero-behavior executable shell with no public API or dependency.
- No protocol message, networking path, UI, platform input behavior, or third-party dependency is introduced.
- M1-006 remains the owner of `KVMContracts`, `KVMCore`, `BarrierCompatibility`, `MacPlatform`, and `NativeProtocol` target boundaries.
- Existing canonical specifications, ADRs, contract tests, and Product Owner backlog remain unchanged.

## Rollback

Revert the M1-004 PR. Because this change only adds repository structure and metadata, rollback does not migrate data, credentials, runtime state, or public contracts.
