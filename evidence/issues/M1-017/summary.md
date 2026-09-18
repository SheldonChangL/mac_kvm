# M1-017 Evidence Summary

GitHub Issue: #20

Implementation commit: `5f2bb6c15bd22c2848531fd985d2dc798cd56a64`

## Deliverables

- `Packages/KVMContracts/Sources/KVMContracts/Transport.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/TransportTests.swift`
- `docs/components/M1-017-transport.md`
- This evidence package.

## Acceptance criteria mapping

- Focus contract: `Transport` exposes connect, ordered send, ordered incoming
  bytes, and disconnect without exposing `NWConnection` or another concrete
  socket/network implementation.
- Happy path: a `Sendable` conformer connects and preserves sequential outbound
  byte order.
- Chunk semantics: incoming chunks preserve order but do not imply protocol
  frame boundaries; empty sends/receives are successful no-ops.
- Boundary/failure: send-before-connect, repeated connect, send-after-terminal,
  and reconnect-after-terminal all fail closed with typed `CoreError`.
- Cancellation/cleanup: cancellation remains a typed terminal failure,
  disconnect is idempotent, and normal disconnect finishes incoming bytes.
- Resource bound: finite-buffer overflow preserves already accepted order, then
  terminates with `transport.resourceExhausted` rather than silently dropping.
- Architecture: no protocol frame/message, KVM event mapping, Barrier/native
  token, `NWConnection`, OS input type, TLS/trust implementation, UI, retry
  loop, or logging sink is introduced.
- Formal gates: all Required Commands and all 17 cumulative repository gates
  passed at the implementation commit.

## Security and fail-safe properties

- Connect/send use typed `CoreError` throws; incoming terminal errors must be
  translated to the same closed taxonomy.
- `incomingBytes` is single-consumer and must be finitely buffered. Overflow is
  terminal and observable rather than a silent byte drop or unbounded growth.
- Raw bytes are treated as untrusted and may not enter logs or diagnostics.
- Disconnect is specified as bounded, idempotent, cancellation-resilient, and
  independent of a successful network response.
- Production TLS remains default-on; the abstraction does not authorize
  plaintext fallback or automatic trust.

## Scope control and known limitations

- Implementation/test/docs changes are limited to the three Exact Files.
- Evidence files are added only because the Issue explicitly requires
  `evidence/issues/M1-017/`.
- `AsyncThrowingStream` uses existential `Error`; documentation and tests
  require concrete transports to surface only `CoreError` terminal failures.
- Numeric buffer/chunk limits are intentionally owned by the future concrete
  transport Issue. It must choose finite values and test real overload.
- The resource-free conformer proves contract semantics, not future socket,
  partial-write, TLS, timer, or Task-cancel cleanup behavior.
- The recorded local Xcode result is incremental. PR CI must also pass from a
  clean checkout before merge.

## Rollback

Revert the M1-017 PR and keep concrete transport/protocol implementation Issues
blocked. No runtime resource, persisted state, migration, trust state, or wire
behavior requires cleanup.
