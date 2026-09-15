# M1-006 Evidence Summary

Implementation commit: `f687b268467dd46ab3001ba2f1d406e09e49de6a`

## Deliverables

- Five SwiftPM module boundaries: `KVMContracts`, `KVMCore`, `BarrierCompatibility`, `MacPlatform`, and `NativeProtocol`.
- One-way manifest dependency graph with the `MacKVM` executable restricted to assembly.
- Fail-closed graph/build verifier and contract tests.
- Architecture, security, cleanup applicability, and rollback documentation.

## Acceptance criteria

- Focus items are located in `Package.swift`, module source roots, the verifier, tests, and `docs/build/M1-006-package-boundaries.md`.
- Happy path, exact-dependency boundary, invalid root/arguments, and prohibited-edge tests pass. Runtime cancellation is not applicable because this Issue adds no runtime resources or behavior.
- Module sources are comment-only and introduce no public API, wire token, protocol implementation, networking, platform behavior, or logging.
- Current executable gates pass with no new build warning. The canonical `xcodebuild`, `Tools/Backlog/validate_package.py`, and `make architecture-check` commands remain owned by the authorized M1 tooling-bootstrap sequence and must be backfilled before M1 completion.
- Targeted token and secret scans report no finding.

## Scope and rollback

No M1-007-or-later contract or behavior is implemented. Revert the M1-006 PR to remove the module graph; dependent Issues must then remain blocked until the graph is restored. No data migration or user-state cleanup is required.

## Remaining risk

Source-level import and forbidden-token enforcement is deferred to M1-010. Formal CI/evidence automation is deferred to M1-008. Both are temporary bootstrap obligations, not permanent waivers.
