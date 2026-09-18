# M1-016 Evidence Summary

GitHub Issue: #19

Implementation commit: `a3d292c554cc95b1dd8c00d982d8214d731338e9`

## Deliverables

- `Packages/KVMContracts/Sources/KVMContracts/KVMProtocolSession.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/KVMProtocolSessionTests.swift`
- `docs/components/M1-016-kvmprotocol-session.md`
- This evidence package.

## Acceptance criteria mapping

- Focus contract: `KVMProtocolSession` exposes connect, typed send, ordered
  events, and reasoned disconnect for both Barrier and native adapters.
- Canonical/C-003 alignment: the canonical §60 session shape is preserved;
  C-003's reasoned async disconnect and throwing event stream are documented as
  terminal/cancellation refinements rather than an unreported replacement.
- Happy path: a `Sendable` conformer connects, sends, and emits the same
  platform-neutral `KVMEvent`.
- Boundary and invalid input: send after terminal completion fails closed,
  every closed disconnect reason round-trips, and an unknown reason fails
  decoding.
- Error and privacy: connect/send use typed `CoreError` throws; failure stream
  termination preserves the typed error and encoded reasons contain no message
  or description field.
- Cancellation and cleanup: cancellation remains a typed terminal failure,
  normal disconnect completes once, repeated disconnect is safe, and send
  after termination fails closed.
- Single-use lifecycle: repeated connect and reconnect after terminal state
  both fail closed in the contract conformer test.
- Architecture: no Barrier/native wire token, Transport implementation, socket,
  OS input type, platform cleanup, UI, TLS implementation, or logging sink is
  introduced.
- Formal gates: every Required Command and all 17 cumulative repository gates
  passed at the implementation commit.

## Security and fail-safe properties

- `DisconnectReason` is a closed enum containing only closed M1-015 values; it
  cannot retain arbitrary protocol text, peer data, input, clipboard content,
  secret, path, address, or key material.
- Unexpected failures must be mapped to `CoreError`; connect and send enforce
  that at compile time.
- Cancellation and abnormal termination cannot be silently reported as a
  successful event-stream completion.
- Disconnect is specified as idempotent, bounded, and independent of a network
  response.
- Protocol-session cleanup remains separate from platform input-safety cleanup;
  Core consumes terminal state and invokes the owning safety interface.

## Scope control and known limitations

- Implementation/test/docs changes are limited to the three Exact Files.
- Evidence files are added only because the Issue explicitly requires
  `evidence/issues/M1-016/`.
- Swift's constructible `AsyncThrowingStream` currently uses existential
  `Error`. The public documentation and tests require conformers to emit only
  `CoreError`; concrete session Issues must retain this invariant.
- The recorded local Xcode result is an incremental workspace build. The PR CI
  must also pass from its clean checkout before merge.
- The resource-free test conformer proves contract behavior, not future socket,
  task, timer, TLS, trust, or input-state cleanup. Resource owners must add
  implementation-level idempotency and cancellation tests.
- Barrier/native sessions, Transport, framing, codec, handshake, reconnect,
  platform cleanup, and UI remain with their owning Issues.

## Rollback

Revert the M1-016 PR and keep dependent concrete-session Issues blocked. No
runtime resource, persisted state, migration, or wire behavior requires cleanup.
