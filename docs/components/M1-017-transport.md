# M1-017 Transport Interface and Byte-Stream Semantics

## Outcome

`KVMContracts` defines one protocol-neutral `Transport` interface for ordered
byte streams. Protocol adapters depend on this abstraction rather than a socket
or `NWConnection`, so Barrier and native codecs remain independently testable.

## Source authority

The contract follows the Product Owner's source priority:

1. canonical specification §60–64;
2. explicitly frozen decisions;
3. C-002 and the accepted M1-002 architecture ADR; and
4. the reference `KVMContracts` package.

C-002 requires `connect()`, `send(Data)`, `incomingBytes`, and `disconnect()`
over an ordered byte stream. M1-002 further requires typed transport failure
and cancellation, prohibits protocol codecs from opening sockets, and keeps
TLS enabled by default in production without embedding a concrete trust or
network implementation in this contract.

M1-017 retains the reference interface shape and narrows connect/send failures
to the closed M1-015 `CoreError` taxonomy. The constructible standard-library
`AsyncThrowingStream` currently uses existential `Error`; conformers therefore
MUST translate terminal implementation errors to `CoreError` before they cross
the incoming-byte boundary.

## Contract

`Transport` is `Sendable` and provides:

- `incomingBytes`: one ordered sequence of non-empty byte chunks;
- `connect()`: establishes a usable byte stream;
- `send(_:)`: accepts bytes for ordered transmission; and
- `disconnect()`: performs bounded, idempotent shutdown.

The interface owns connection and byte delivery only. It does not own protocol
handshake, framing, codec, message/event mapping, routing, TLS policy, trust
decisions, retry scheduling, UI, or platform input state.

## Outbound ordering and completion

- For sequential awaited calls, if `send(A)` completes before `send(B)` begins,
  the peer observes every byte of A before every byte of B.
- Concurrent sends are serialized into one total order without byte
  interleaving, but callers cannot assume which concurrent call wins that order.
  A caller needing a specific order must await sends sequentially.
- An empty `Data` is a successful no-op.
- A successful send means the complete value was accepted by the local
  transport for transmission. It is not a peer, protocol, or application-level
  acknowledgement.
- The implementation owns partial-write handling. Callers never receive a byte
  count and must not guess or retry an unknown suffix.
- A failed send throws a typed `CoreError`; error retry disposition does not
  imply that input cleanup or peer delivery occurred.

## Incoming chunks and buffering

Incoming chunk boundaries are implementation details. One protocol frame may
arrive across multiple chunks, and one chunk may contain multiple frames. The
transport does not parse, coalesce into frames, or expose socket read sizes as
protocol semantics. Empty chunks are not emitted.

`incomingBytes` has exactly one consumer. Multiple iterators could divide
chunks and are invalid. The implementation must use finite buffering and
inspect each continuation yield result. When the buffer cannot accept more
data, it must terminate with `CoreError.transport(.resourceExhausted)` rather
than silently drop or reorder bytes, grow without bound, or continue with a
corrupted stream. The concrete transport Issue owns the numeric buffer and
chunk limits and must document/test them before production use.

## Lifecycle and terminal semantics

Each transport instance and incoming-byte stream are single-use:

- the first `connect()` establishes the lifecycle;
- send before connect fails closed;
- repeated connect, including after terminal completion, fails closed;
- reconnect creates a new transport instance and stream;
- send after terminal completion fails closed;
- normal disconnect finishes the incoming stream once;
- unexpected failure finishes by throwing its exact typed `CoreError`;
- cancellation finishes by throwing a cancellation-domain `CoreError`; and
- repeated disconnect is safe and does not repeat cleanup.

Disconnect does not wait for or require a successful network response. Its
bounded resource cleanup and terminal stream delivery must still complete if
the calling Swift task is already cancelled; Task cancellation cannot cause an
early return that skips cleanup.

## Security and privacy

- Production transports keep TLS enabled by default. This interface does not
  authorize plaintext fallback or auto-accept any peer identity.
- Trust and secure-storage decisions remain in their owning contracts/issues;
  Transport surfaces their terminal result through `CoreError` without
  carrying certificate, fingerprint, key, or peer identity data.
- Raw incoming/outgoing bytes are untrusted and may contain typed input,
  clipboard content, credentials, or protocol secrets. They must not be logged,
  reflected, or placed in diagnostic metadata.
- The interface contains no arbitrary error string, socket address, hostname,
  path, platform handle, or concrete network type.

## Validation coverage

Contract tests verify:

- connect and sequential send preserve outbound byte order;
- incoming chunks remain ordered without being treated as frames;
- zero-length send/receive are no-ops;
- invalid lifecycle operations fail closed;
- disconnect is idempotent and finishes the stream;
- terminal transport failure remains the exact typed `CoreError`;
- cancellation remains a typed terminal failure; and
- finite-buffer overflow preserves already accepted bytes, then fails closed
  with `transport.resourceExhausted` instead of dropping silently.

The test conformer owns no socket or platform state. Concrete transport Issues
must repeat these invariants with real tasks, buffers, partial writes, network
failures, TLS, and cleanup under Task cancellation.

## Out of scope

M1-017 does not implement Network.framework, a socket, TLS/trust, DNS, framing,
Barrier/native protocol messages, a codec, connection retry/backoff, timeout
policy, diagnostics, UI, input cleanup, or any platform behavior. It chooses no
wire bytes and changes no frozen protocol or security policy.

## Rollback

Revert the M1-017 PR and keep concrete transport/protocol implementation Issues
blocked. No runtime resource, persisted state, migration, trust state, or wire
behavior requires cleanup.
