# M1-PKG-003 Evidence Summary

## Scope

M1-PKG-003 unblocks M1-021 by making `Packages/BarrierCompatibility` a real SwiftPM
child package with an owned `BarrierCompatibilityTests` target. Before this fix,
`swift test --package-path Packages/BarrierCompatibility` resolved upward to the root
`MacKVM` package and could pass without compiling the M1-021 exact test path.

- GitHub Issue: #296.
- Branch: `codex/m1-pkg-003-barriercompat-package`.
- Base commit: `4897e2ce38cf079214292c3dc81cd836bf953b4b`.
- Implementation commit: the PR commit that contains this evidence file.
- Status: ready for PR after review and validation.
- Reviewer: Claude CLI independent review plus primary Codex review.

## Changes

- Added `Packages/BarrierCompatibility/Package.swift`.
- Added `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/PackageOwnershipTests.swift`.
- Added the cumulative `swift-package-test:BarrierCompatibility` gate.
- Updated CI-gate inventory tests.
- Updated `docs/tooling/M1-008-cigates.md` so the documented gate inventory matches
  the 24-gate implementation.

## Acceptance Criteria mapping

- `swift package --package-path Packages/BarrierCompatibility describe --type json`
  identifies package `BarrierCompatibility` and target `BarrierCompatibilityTests`.
- `swift test --package-path Packages/BarrierCompatibility` runs
  `childPackageOwnsBarrierCompatibilityTests`.
- `make verify` includes `swift-package-test:BarrierCompatibility`.
- Root module graph and production behavior are unchanged.

## Non-goals

- No Barrier wire contract, parser, codec, networking, KVM Core, input-engine, TLS,
  Windows or server behavior is changed.

## Rollback

Revert this PR. M1-021 must remain blocked until an equivalent child-package ownership
fix is restored.
