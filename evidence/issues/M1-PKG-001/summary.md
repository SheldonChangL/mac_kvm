# M1-PKG-001 Evidence Summary

GitHub Issue: #246

Final implementation commit: `4fe69405d0c583fbb4da46146825077b1ff5baa9`

Package/checker implementation commit: `c438ff2e6f3ce2a36797b6d7c1330fcf86510d41`

## Outcome

M1-013's exact `swift test --package-path Packages/KVMContracts` command now
resolves a real child package and executes `KVMContractsTests`, instead of
silently walking upward to the repository package and running unrelated tests.

## Deliverables

- `Packages/KVMContracts/Package.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/PackageOwnershipTests.swift`
- Nested SwiftPM `.build` product exclusion in the architecture checker.
- Architecture regression test and tooling documentation update.
- Named cumulative `swift-package-test:KVMContracts` blocking gate.
- This evidence package.

## Acceptance criteria mapping

- Child command: passes and runs exactly one current ownership test.
- Package identity: `swift package ... describe --type json` reports package
  `KVMContracts`, library target `KVMContracts`, and test target
  `KVMContractsTests` at `Tests/KVMContractsTests`.
- Future M1-013 test ownership: its exact test directory is now the child test
  target source root.
- Sequential compatibility: the exact child test command generates nested
  `.build` products, after which `make architecture-check` and all 14 cumulative
  gates pass without cleanup.
- GitHub enforcement: the cumulative pipeline runs the child package tests once
  with compiler warnings treated as errors; they are not local-only.
- Root compatibility: the canonical Xcode workspace build succeeds, and the
  root package test/build gates remain green.
- Scope: no public API, KVMEvent case, runtime behavior, root dependency edge,
  protocol, platform, networking, TLS, or frozen decision changed.
- Hygiene: owner artifacts and nested build products remain ignored and are not
  committed.

## Five-axis review

1. Source validity / traceability: live Issues #10 and #246 record the original
   false-green parent-package fallback, corrective scope, and blocking relation.
2. Product contract / architecture: the child manifest exposes only the already
   declared `KVMContracts` module; the root module graph and C-001 semantics are
   unchanged.
3. Security / fail-safe / compatibility: no input, secrets, network, logging,
   trust, or runtime resources are added. The checker ignores only directory
   components named `.build`; actual source, other hidden trees, and source
   symlinks remain fail-closed.
4. Tests / validation: the ownership test, 27 architecture tests, 16 CI-gate
   tests, canonical workspace build, and 14 cumulative gates pass.
5. Scope / hygiene / rollback: generated products are ignored, owner artifacts
   remain untracked, and reverting this PR restores the prior state while
   correctly re-blocking M1-013.

## Findings

- Critical: 0.
- High: 0.
- Medium: 0 open.
- Low: 0 open.

## Remediated attempts

- Before the child manifest, the exact command exited zero after running three
  unrelated root tests. This was captured as the primary false-green defect.
- The first cumulative gate after adding the child package failed because the
  architecture checker scanned generated `.build` Swift/symlink content. A TDD
  regression reproduced both violations; the checker now excludes only nested
  SwiftPM `.build` products, and the exact command sequence passes.
- The first PR-head GitHub run passed the old 13-gate set but did not execute the
  child Swift package. Pre-merge review retained that as evidence, added the
  named blocking gate, and requires a replacement GitHub run before merge.

## Known limitations

- The ownership test intentionally proves package/target routing only. M1-013
  owns all KVMEvent behavior and contract tests.
- The same-executor five-axis review uses the Product Owner temporary waiver;
  independent C/H review must be backfilled before M1 completion.

## Rollback

Revert the M1-PKG-001 PR and keep M1-013 blocked until an equivalent child
package/test target and generated-product-safe architecture gate are restored.
