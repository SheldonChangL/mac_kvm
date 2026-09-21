# M1-019 Evidence Summary

Implementation commit: `c4a69f7fb65e3de3d9d7c68fa2ba50991a0535c8`

## Deliverables

- `Package.swift` (Product Owner authorized scope expansion: adds the
  `KVMCoreTests` target only)
- `Packages/KVMCore/Sources/KVMCore/MockTransport.swift`
- `Packages/KVMCore/Tests/KVMCoreTests/MockTransportTests.swift`
- `docs/components/M1-019-mock-transport.md`
- This evidence package.

## Authorized scope expansion

`Packages/KVMCore` has no nested `Package.swift`, so
`swift test --package-path Packages/KVMCore` resolves upward to the root
package. Before this change that command compiled no KVMCore test target and
ran only three pre-existing scaffold tests, so the Exact Test File could never
be discovered. The Product Owner explicitly authorized adding a `KVMCoreTests`
target to the root `Package.swift` for exactly this reason. The change is one
`.testTarget` entry pointing at `Packages/KVMCore/Tests/KVMCoreTests`; no other
target, dependency, product, or platform setting was touched, and the
authorization is not treated as covering any other file or Issue.

Discovery is verified directly:
`swift test --package-path Packages/KVMCore --list-tests` lists all twelve
`KVMCoreTests.mockTransport*` tests alongside the three scaffold tests.

## Acceptance criteria mapping

- Focus coverage: `MockTransport` implements scripted inbound chunks
  (`init(inbound:)` plus `deliverScriptedInbound()`), outbound recording
  (`recordedOutbound`), and injectable EOF/error/cancellation
  (`MockTransportCompletion`). Each has a named test.
- Happy path: `mockTransportRecordsOutboundBytesInCallOrder` and
  `mockTransportDeliversScriptedInboundChunksInOrder`.
- Boundary/limit: `mockTransportTreatsZeroLengthSendAsSuccessfulNoOp`,
  `mockTransportRejectsNonPositiveBufferLimit`, and
  `mockTransportFailsClosedOnBoundedBufferOverflow`, which asserts that already
  accepted bytes stay readable and in order before the stream fails closed with
  `transport.resourceExhausted`.
- Invalid input/failure: `mockTransportRejectsEmptyScriptedInboundChunk`,
  `mockTransportRejectsInvalidLifecycleOperations`, and
  `mockTransportInjectsTypedTransportFailure`.
- Cancel/cleanup/idempotency: `mockTransportInjectsCancellationDomainFailure`,
  `mockTransportDisconnectIsIdempotentAndFinishesIncomingBytesOnce`, and
  `mockTransportCleanupCompletesInsideAnAlreadyCancelledTask`.
- No new public contract: `MockTransport` and `MockTransportCompletion` are
  declared `package`, so `Transport` remains the only public transport API.
  The reasoning is recorded in the component document.
- Architecture/lint/build/tests: all Required Commands plus `make docs-check`,
  `make code-quality-check`, `git diff --check HEAD`, and
  `make verify` (17/17 gates) passed at the implementation commit with no new
  warning. `swift test -Xswiftc -warnings-as-errors` is part of
  `make code-quality-check` and passed.
- Logging/privacy: the double performs no logging and holds no arbitrary error
  string, address, path, hostname, key, or credential. Raw bytes are only
  stored for test assertions and are never emitted to a log or diagnostic.

## Test determinism

No test uses a wall-clock sleep, a retry, or a timeout. The cancellation
cleanup test uses the repository's existing `withUnsafeCurrentTask` self-cancel
pattern so the task is cancelled before `disconnect()` is awaited.

## Red phase

`evidence/issues/M1-019/tests/red-phase.json` records the genuine failing run:
the test file plus the new target were added first, and
`swift test --package-path Packages/KVMCore` exited 1 with 33
`cannot find 'MockTransport' in scope` compilation errors before any
implementation existed.

## Scope control

- Tracked changes are limited to the four allowed files plus this evidence
  package.
- `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` remain untracked and were
  never staged. Every commit staged explicit paths; `git add -A` was not used.
- `artifacts/ci/m1-019-implementation-report.json` is produced by `make verify`
  and is not a tracked change (`/artifacts/` is gitignored).
- No protocol, frame, codec, Barrier token, wire byte, socket, TLS, trust
  policy, retry, timeout policy, diagnostics, UI, or platform behavior was
  introduced.

## Known limitations and follow-ups

- The whole inbound script is delivered during `connect()`. The double does not
  model interleaving a specific inbound chunk between two specific outbound
  sends. A concrete transport or harness Issue owns that if it is needed.
- Buffer overflow is reachable only through the constructor's
  `incomingBufferLimit`; the double has no runtime backpressure model. Real
  buffer and chunk limits remain with the concrete transport Issue.
- `package` visibility makes the double reachable from every target in the
  MacKVM package, including the `MacKVM` executable target. Narrowing this to a
  dedicated test-support target would require a file outside Exact Files and is
  left as a follow-up.
- Operation-level injection is limited to the contract's fail-closed lifecycle
  errors; `connect()` and `send(_:)` have no separate injectable failure. A
  follow-up Issue owns that if a consumer needs it.
- M1-020 owns the repository-wide deterministic async harness that combines
  this double with the M1-018 clock.

## Rollback

Revert the M1-019 commits. The `KVMCoreTests` target, the double, its tests,
and this evidence package disappear together, restoring the previous root
`Package.swift`. No runtime resource, persisted state, migration, trust state,
wire behavior, or platform input state requires cleanup.
