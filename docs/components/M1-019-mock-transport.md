# M1-019 MockTransport

## Outcome

`KVMCore` gains one resource-free `Transport` test double. `MockTransport`
scripts ordered inbound byte chunks, records ordered outbound bytes, and injects
the three terminal outcomes the frozen M1-017 contract allows, so protocol and
core Issues can be tested without a socket, network, or platform dependency.

## Source authority

The double follows the Product Owner's source priority:

1. canonical specification §60–64;
2. explicitly frozen decisions;
3. C-002 and the merged M1-017 `Transport` contract; and
4. the existing `KVMContracts` test and error patterns.

M1-019 adds no contract. It implements the merged interface exactly as written
and narrows every failure to the closed M1-015 `CoreError` taxonomy.

## Visibility decision

The Issue forbids a new public contract. `MockTransport` and
`MockTransportCompletion` are therefore declared `package`, not `public`:

- the only public transport API in the repository remains `Transport` itself;
- the concrete double stays reachable to first-party test targets inside the
  MacKVM package without widening `KVMCore`'s public surface; and
- the control surface is a test-double control, not a contract. It is
  deliberately limited to what the frozen interface already defines — an
  inbound script, a finite buffer depth, and one terminal outcome.

Tests import `KVMCore` normally; no `@testable` escape hatch is required.

## Control surface

`MockTransport` is an `actor` and inherits `Sendable` from that.

- `init(inbound:completion:incomingBufferLimit:) throws(CoreError)` scripts the
  lifecycle. Every inbound chunk must be non-empty and the buffer limit must be
  positive; otherwise construction fails closed with
  `internal.preconditionFailed` and finishes the unused stream.
- `connectCount`, `disconnectCount`, and `recordedOutbound` expose observed
  behavior only. `recordedOutbound` holds non-empty outbound values in the order
  `send(_:)` accepted them.

`MockTransportCompletion` offers exactly the contract's terminal outcomes:

- `openUntilDisconnect` — the stream stays open until cleanup runs;
- `endOfStream` — a normal disconnect finishes the stream once; and
- `failure(CoreError)` — the stream finishes by throwing that exact typed error.

Cancellation is injected through `failure` with a cancellation-domain
`CoreError`. The contract expresses cancellation as a typed terminal failure,
so the double adds no separate cancellation channel.

## Contract behavior

- The instance is single-use. Send before connect, repeated connect, and any
  operation after terminal completion or cleanup fail closed with a typed
  `CoreError`.
- Scripted chunks are delivered on `connect()` in script order. Chunk
  boundaries carry no frame meaning; the double parses nothing.
- An empty `Data` passed to `send(_:)` is a successful no-op and is not
  recorded. Empty inbound chunks are never emitted, because they are rejected
  at construction rather than silently dropped.
- Buffering is finite. Every `yield` result is inspected; a dropped chunk
  terminates the stream with `transport.resourceExhausted` and leaves already
  accepted bytes readable and in order.
- `disconnect()` is idempotent, counts one cleanup, and finishes the stream
  exactly once. It has no suspension point that can observe cancellation, so
  cleanup completes even inside an already cancelled task.

## Security and privacy

- The double contains no socket, `NWConnection`, TLS, trust, certificate,
  hostname, address, path, or platform handle.
- It performs no logging and no diagnostics. No raw inbound or outbound byte,
  typed text, clipboard payload, credential, or key material is emitted.
- It carries no arbitrary error string; every failure is a closed `CoreError`
  code.

## Validation coverage

`MockTransportTests` covers, without any wall-clock sleep or retry:

- connect and sequential send preserve outbound byte order;
- scripted inbound chunks arrive in order without implying frame boundaries;
- a zero-length send is a successful no-op;
- an empty scripted chunk and a non-positive buffer limit fail closed;
- invalid lifecycle operations fail closed;
- injected normal end of stream finishes after the script;
- an injected typed failure surfaces as the exact `CoreError`;
- an injected cancellation-domain failure keeps its cancellation code;
- bounded-buffer overflow retains accepted bytes and then fails closed with
  `transport.resourceExhausted`; and
- disconnect is idempotent, finishes the stream once, and completes inside an
  already cancelled task.

## Out of scope

M1-019 implements no protocol, frame, codec, Barrier message, native message,
wire byte, Network.framework, socket, TLS, trust policy, retry, timeout policy,
diagnostics, UI, or platform input behavior. It changes no frozen contract, ADR,
or wire format, and it invents no wire bytes.

## Rollback

Revert the M1-019 PR. The `KVMCoreTests` target and the double disappear with
it; no runtime resource, persisted state, migration, trust state, wire behavior,
or platform input state requires cleanup.
