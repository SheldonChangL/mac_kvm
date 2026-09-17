# M1-XCODE-001 Evidence Summary

GitHub Issue: #241

Implementation commit: `ba7db5410c4218984ce1cd9a252a4f5e527362cf`

## Deliverables

- `MacKVM.xcworkspace/contents.xcworkspacedata`
- `MacKVM.xcworkspace/xcshareddata/xcschemes/MacKVM.xcscheme`
- `Tests/Contracts/test_m1_xcode_workspace.py`
- `docs/tooling/M1-XCODE-001-workspace.md`
- This evidence package.

## Acceptance criteria mapping

- Exact M1 build contract: the required `xcodebuild` invocation exited 0 with
  `BUILD SUCCEEDED` at implementation commit `ba7db54`.
- Portable shared metadata: XML contract tests require repository-relative
  `group:`/`container:` references and reject `/Users/`, `xcuserdata`, and
  `DerivedData` content.
- Fail-closed contract: a missing or malformed workspace/scheme causes XML
  parsing or assertions to fail; the red phase produced four missing-file test
  errors before implementation.
- Formal gates: all 11 `make verify` gates passed on native arm64; explicit
  backlog, architecture, docs, and diff checks also passed.
- Repository hygiene: only the workspace, scheme, contract test, documentation,
  and evidence are in scope. No signing state, credentials, owner artifacts,
  derived products, or user-specific Xcode state are included.

## Architecture, security, and compatibility

The SwiftPM graph remains authoritative and unchanged. No runtime, protocol,
TLS, trust, input, logging, or diagnostic-bundle behavior changes. The scheme
build proves the existing six-target dependency graph resolves without moving
Barrier code outside `BarrierCompatibility`.

## Known limitations and follow-ups

- Xcode reports that several macOS destination variants match
  `platform=macOS` and selects the first one; this is informational and the
  required command succeeds.
- M1-012 (#8) remains responsible for the redacted diagnostic bundle and is not
  implemented here.

## Rollback

Revert the corrective PR. `Package.swift`, `swift build`, and `swift test`
remain available and no runtime/user data migration is involved.
