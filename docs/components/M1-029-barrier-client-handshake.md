# M1-029 Barrier Client Handshake

## Outcome

`BarrierCompatibility` sequences the two frozen Barrier handshake contracts in a
deterministic, module-internal state machine. `BarrierClientHandshake` accepts one
complete server hello payload, validates it with M1-027, composes the client
HelloBack frame with M1-028 and reaches `protocolConnected` once the caller reports
that frame as written. Every other path ends in a sticky, typed
`BarrierClientHandshakeError` that carries no payload or screen-name bytes.

## Frozen inputs and dependency sources

The handshake adds no wire bytes of its own; it only routes the frozen outputs of its
dependencies.

| Dependency | Source | What M1-029 uses |
|---|---|---|
| M1-016 | `docs/components/M1-016-kvmprotocol-session.md` | Session lifecycle direction: single-use, fail-closed after terminal completion, typed closed failures without strings, cancellation as an explicit terminal failure |
| M1-027 | `docs/components/M1-027-barrier-server-hello.md`, `docs/adr/M1-025-barrier-client-wire-contract.md` | `BarrierServerHello(payload:)` and `BarrierServerHelloError`; accepted payload `42 61 72 72 69 65 72 00 01 00 06` (`BARRIER-EVID-0002` run 0) |
| M1-028 | `docs/components/M1-028-barrier-client-hello-back.md`, `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md` | `BarrierClientHelloBackWriter.frame(screenName:)` and `BarrierClientHelloBackError`; golden frames `m1-client` (28 bytes) and `m1x` (22 bytes) from `BARRIER-EVID-0004` |

Fragmentation, coalescing and truncation are handled by `BarrierFrameReassembler`
(M1-022) before a payload reaches the handshake.

M1-016 is a direction, not a conformance: the handshake does not implement
`KVMProtocolSession` and does not produce `CoreError` or `DisconnectReason`. Mapping
`BarrierClientHandshakeError` into the M1-015/M1-016 taxonomy belongs to the Barrier
session adapter that owns the transport.

## Types

All declarations are module-internal; no public API or contract is added.

- `BarrierClientHandshake` (`Sendable` value type):
  - `init(screenName:helloBackWriter:)`; the caller supplies the writer and therefore
    the screen-name bound;
  - `state` (read-only `State`);
  - `start()`, `receiveServerHello(payload:) -> [UInt8]`, `helloBackSent()`, all
    `throws(BarrierClientHandshakeError)`;
  - `timeOut()` and `cancel()`, non-throwing injected signals.
- `BarrierClientHandshake.State`: `connected`, `awaitHello`, `sendHelloBack`,
  `protocolConnected`, `failed(BarrierClientHandshakeError)`.
- `BarrierClientHandshakeError` (`Equatable`, `Sendable`):
  - `serverHelloRejected(BarrierServerHelloError)`;
  - `helloBackRejected(BarrierClientHelloBackError)`;
  - `timedOut`, `cancelled`, `outOfOrderEvent`, `alreadyConnected`.

## State machine

```text
connected --start()--> awaitHello --receiveServerHello(payload:)--> sendHelloBack
    --helloBackSent()--> protocolConnected
```

1. `start()` moves `connected` to `awaitHello`.
2. `receiveServerHello(payload:)` in `awaitHello` validates the payload with
   `BarrierServerHello(payload:)` first, then writes the HelloBack frame with the
   configured writer, releases the screen name, moves to `sendHelloBack` and returns
   the exact M1-028 frame bytes for the caller to write.
3. `helloBackSent()` in `sendHelloBack` moves to `protocolConnected`.

The server hello is validated before the screen name, so no HelloBack is composed for
an unsupported server. The returned frame is byte-identical to
`BarrierClientHelloBackWriter.frame(screenName:)`; the handshake adds no framing.

Every input is an explicit event. The caller owns the transport, the reassembler and
the clock and injects timeout and cancellation, so the state machine contains no I/O,
timer, sleep, retry, task or lock.

## Terminal paths

Failures are terminal and sticky: the first failure is latched in `.failed(error)`,
every later throwing event rethrows it, and a later valid hello cannot revive the
handshake.

| Path | Trigger | Result |
|---|---|---|
| Timeout | `timeOut()` in `connected`, `awaitHello` or `sendHelloBack` | `.failed(.timedOut)` |
| Cancel | `cancel()` in `connected`, `awaitHello` or `sendHelloBack` | `.failed(.cancelled)` |
| Unsupported marker | hello payload whose marker bytes differ | `.failed(.serverHelloRejected(.unsupportedMarker))` |
| Unsupported version | hello payload whose version bytes differ | `.failed(.serverHelloRejected(.unsupportedVersion))` |
| Truncated hello | payload shorter than 11 bytes | `.failed(.serverHelloRejected(.truncatedMarker(payloadByteCount:)))` or `.truncatedVersion(payloadByteCount:)` |
| Trailing hello bytes | payload longer than 11 bytes | `.failed(.serverHelloRejected(.unexpectedTrailingBytes(payloadByteCount:)))` |
| HelloBack validation failure | screen name empty, over the bound or outside the identifier set | `.failed(.helloBackRejected(...))` with the M1-028 error |
| Out-of-order event | `receiveServerHello` before `start()`, repeated `start()`, `helloBackSent()` before the hello, a second hello in `sendHelloBack` | `.failed(.outOfOrderEvent)` |
| Event after completion | any throwing event in `protocolConnected` | throws `alreadyConnected`; state stays `protocolConnected` |

`timeOut()` and `cancel()` are idempotent: in `.failed` they keep the original
reason, and in `protocolConnected` they are ignored because session teardown after
the handshake belongs to the session owner. A frame truncated in the stream never
yields a payload from M1-022, so the handshake stays in `awaitHello` until the
caller's timeout signal.

## Security and privacy

- The handshake performs no logging, printing or diagnostics output and imports no
  logging facility.
- Errors carry only the nested M1-027/M1-028 typed errors, which hold at most a
  payload byte count, a screen-name byte count and the configured limit. No case
  carries payload bytes, screen-name bytes, addresses, paths or arbitrary strings
  (`handshakeErrorsCarryOnlyAllowlistedMetadata`).
- The screen name is stored only while it is needed and is released on entering
  `sendHelloBack` or any terminal state
  (`handshakeReleasesScreenNameOnEveryTerminalState`). The hello payload and the
  returned frame are not retained.
- Tests use only the synthetic `m1-client`, `m1x` and generated ASCII names; no real
  host or user name is used.
- Whether a caller may log the returned frame is decided by the caller under the
  project logging policy; the handshake adds no log site.

## Scope boundaries and non-claims

- No transport, socket, TLS, trust, timer or reconnect logic; timeout and
  cancellation are caller-injected signals.
- No UI, KVM Core, `KVMEvent` or `KVMProtocolSession` conformance, and no mapping to
  `CoreError`.
- No control-message decoder: messages after HelloBack (`QINF`, `CIAK`, `DSOP` and
  later) are not frozen and are not handled. A frame coalesced after the hello stays
  queued in the reassembler for the next owner.
- No version negotiation, downgrade or fallback; the M1-025 exact-version policy is
  applied through M1-027.
- No default screen-name bound; the caller configures it through the writer.
- No Barrier/Deskflow source was consulted or copied; only frozen ADRs, component
  docs and sanitized fixture bytes are used.

## Validation coverage

`BarrierClientHandshakeTests` (26 tests) verifies:

- happy path: every state from `connected` to `protocolConnected`; golden HelloBack
  frames for `m1-client` and `m1x` compared byte-for-byte; output identical to the
  M1-028 writer;
- fragmentation/coalescing/truncation: a hello reassembled byte by byte by M1-022; a
  coalesced follow-up frame left queued in the reassembler; a hello frame truncated
  at every length yields no payload and ends only through the injected timeout;
- boundaries: screen name at exactly the bound, one byte over, a 1-byte name at
  bound 1;
- failures: unsupported marker, every version byte flipped, truncated payload at
  every length, trailing byte, invalid screen names, hello validated before screen
  name, out-of-order events in every pending state, events after
  `protocolConnected`, errors carrying only `Int` metadata;
- cancel/cleanup/idempotency: timeout and cancel from every pending state, repeated
  and mixed signals keep the first reason, failures stay sticky, late signals do not
  tear down `protocolConnected`, the screen name is released on every terminal
  state, repeated runs are deterministic.

## Rollback

Revert the M1-029 change (the two Swift files, this document and
`evidence/issues/M1-029/`). The state machine owns no runtime resource, persisted
data or migration, and no production code consumes it yet.
