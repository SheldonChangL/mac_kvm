# M1-016 KVMProtocolSession Interface

## Outcome

`KVMContracts` defines the protocol-neutral session boundary used by Barrier
and first-party native adapters. Core sends and receives only `KVMEvent`; the
interface exposes no wire token, socket implementation, platform input type,
or trust-store implementation.

## Source authority and refinement

The interface follows the source priority established by the Product Owner:

1. canonical specification §60–64;
2. explicitly frozen decisions;
3. C-003 and the accepted M1-002 architecture ADR; and
4. the reference `KVMContracts` package.

Canonical §60 defines `connect`, `disconnect`, `send(event:)`, and an event
stream. C-003 and M1-016 refine that architectural shape without changing its
direction:

- `disconnect(reason:)` records a closed, machine-readable terminal reason;
- disconnect is `async` so a caller can await stream termination and bounded
  protocol/transport cleanup;
- `connect` and `send` use typed throws so only `CoreError` crosses those
  failure boundaries;
- the event sequence is an `AsyncThrowingStream` so cancellation and failure
  cannot be silently represented as successful completion; and
- `send(_:)` accepts only `KVMEvent`, matching the frozen Core boundary.

These refinements do not authorize protocol-specific error strings or wire
values. Swift currently constructs `AsyncThrowingStream` with existential
`Error`; conformers therefore MUST translate any thrown implementation error
to the closed `CoreError` taxonomy before it crosses this boundary.

### Reference package delta

The reference package predates M1-015 and uses free-form String payloads for
`protocolError` and `securityRejected`, plus standalone `timeout`. M1-016
intentionally replaces those reference-only cases with:

- `.failure(CoreError)`, which represents protocol, security, timeout,
  transport, and other failures through the closed M1-015 taxonomy; and
- `.cancellation(CancellationReason)`, which makes structured cancellation an
  explicit terminal failure.

`userRequested`, `transportClosed`, and `applicationTermination` remain as
closed non-payload cases. This delta removes privacy-unsafe strings without
changing C-003's reasoned disconnect semantics.

## Contract

`KVMProtocolSession` is `Sendable` and provides:

- `events`: ordered decoded events for one session lifecycle;
- `connect()`: completes only when the protocol session is ready to send;
- `send(_:)`: accepts one platform-neutral event and preserves session order;
  and
- `disconnect(reason:)`: terminates the lifecycle and releases the adapter's
  protocol/transport resources.

Barrier and Native Protocol implementations conform to the same interface.
KVM Core depends on this protocol, never on either concrete implementation.

Each session instance and its event stream are single-use. `events` has one
consumer; multiple iterators could divide events and are invalid. A repeated
`connect()`, including after terminal completion, fails closed with a typed
error. Reconnect creates a new session instance with a new event stream.

## Terminal and cancellation semantics

A conforming implementation must satisfy all of the following:

- a normal user request, orderly peer close, or application termination
  finishes `events` normally and exactly once;
- `.failure(CoreError)` finishes `events` by throwing that typed failure;
- `.cancellation(CancellationReason)` finishes `events` by throwing a
  `CoreError` in the cancellation domain;
- every unexpected implementation error is mapped to `CoreError` without its
  original message, description, path, address, peer identity, or payload;
- after terminal completion, new sends fail closed with a typed error;
- repeated disconnect calls are safe and do not repeat resource cleanup; and
- disconnect and cleanup do not depend on receiving a network response;
- cleanup completes in bounded time even if the caller's task is already
  cancelled; and
- Task cancellation cannot skip cleanup or terminal stream delivery.

`DisconnectReason` is deliberately closed and `Codable`:

- `userRequested`;
- `transportClosed` for an orderly peer transport close;
- `cancellation(CancellationReason)`;
- `failure(CoreError)`; and
- `applicationTermination`.

An abnormal transport close is not `transportClosed`; it is a typed
`.failure` using the M1-015 transport taxonomy.

## Fail-safe boundary

This contract owns protocol-session termination and adapter resource cleanup.
It does not own pressed keys, mouse buttons, local-input suppression, or
platform state. A terminal stream result lets KVM Core invoke the separate
platform-neutral input-safety boundary. Session implementations must not reach
into a platform backend to perform that cleanup directly.

The eventual resource-owning implementations must test idempotent cleanup.
M1-016 contract tests demonstrate terminal, cancellation, and repeated
disconnect behavior with a resource-free conformer; they do not claim to test
future sockets, tasks, or input state.

## Security and privacy

- Production TLS remains default-on; this interface does not select or weaken
  transport security.
- Unknown or changed peer identity remains fail-closed and is represented by
  the existing typed security taxonomy.
- Disconnect reasons contain no arbitrary strings or metadata dictionaries.
- Typed text, clipboard payloads or hashes, protocol frames, credentials,
  secrets, keys, fingerprints, paths, addresses, and peer identifiers are not
  part of the session API and must not be logged from it.
- `Codable` conformance is not permission to log a reason or `CoreError`; the
  M1-011 diagnostic allowlist still applies.

## Validation coverage

Contract tests verify:

- a `Sendable` conformer can connect, send, and emit a `KVMEvent`;
- every disconnect reason round-trips and unknown values fail decoding;
- encoded reasons introduce no message or description field;
- normal disconnect finishes the event stream and repeated disconnect is safe;
- terminal failure preserves the exact typed `CoreError`;
- cancellation remains a typed terminal failure; and
- sending after termination fails closed.

## Out of scope

M1-016 does not implement a Barrier or Native session, Transport, framing,
codec, handshake, retry loop, timer, TLS/trust policy, network connection,
platform input cleanup, logging sink, UI behavior, or wire representation.
Those remain with their owning Issues.

## Rollback

Revert the M1-016 PR and keep dependent concrete-session Issues blocked. The
change owns no runtime resource, persisted state, migration, or wire behavior,
so rollback requires no data or connection cleanup.
