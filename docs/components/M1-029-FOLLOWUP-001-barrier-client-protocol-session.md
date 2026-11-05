# M1-029-FOLLOWUP-001 Barrier Client Protocol Session

## Why this follow-up exists

[`M4-SCOPE-001`](../adr/M4-SCOPE-001-linux-client-first.md) lists M1-029-FOLLOWUP-001
as step 3 of its order of work: a client-role `KVMProtocolSession` for the Barrier wire,
used by the first-party Linux client. GitHub issue #342 fixes its Exact Files. Like
M2-029-FOLLOWUP-001, a FOLLOWUP id has no manifest, `issues_index.csv` or
`EXECUTION_ORDER.md` entry, because the issue schema's id pattern does not allow one.

This session is what turns the Mac server's bytes into `KVMEvent`s on Linux. It mirrors
the server side, `BarrierServerProtocolSession` (M2-029-FOLLOWUP-001).

## Outcome

`BarrierCompatibility` adds two source files. `BarrierClientProtocolSession.swift` holds
the first three types below, and `BarrierClientControlEncoder.swift` the encoder.

- `BarrierClientProtocolSession` (`package`): the client session.
  - `init?(transport:screenName:localScreen:screen:clock:handshakeTimeout:)` returns
    `nil` for a screen name that M1-028 would reject or that is over 64 bytes, and for a
    timeout that is not positive.
  - `connect()`, `send(_:)`, `disconnect(reason:)` and `events` implement
    `KVMProtocolSession` (C-003).
  - `updateScreen(_:)` reports a new local screen.
  - `diagnostics` holds counts only: `dropsByReason`, `unpairedRepeatsDropped` and
    `heldKeyCount`.
  - `waitForReceivedFrames(atLeast:)` and `waitForPendingWrites(atLeast:)` are test
    barriers, and both observe cancellation.
- `BarrierLocalScreen` (`package`): the screen the client reports in `DINF`. Its
  initializer takes `Int` values and returns `nil` unless they form a valid `DINF` screen,
  checked by decoding the encoded frame with `BarrierControlDecoder`.
- `BarrierClientSessionDiagnostics` (`package`): the counts above.
- `BarrierClientControlEncoder` (internal, a namespace of pure functions) writes the
  client's frames:
  - `screenInfo(_:)` writes `DINF`, the exact inverse of the M1-031 parse;
  - `keepalive()` writes `CALV`;
  - `clipboardOwnership(id:sequence:)` writes `CCLP`;
  - `clipboard(marshalled:sequence:)` writes `CCLP`, then the `DCLP` transfer with
    `BarrierClipboard.frames(id:sequence:data:)`.

## Sources

| Source | What this session uses |
| --- | --- |
| [`M1-PROTOCOL-002`](../adr/M1-PROTOCOL-002-barrier-control-message-contracts.md) | Token-only control frames, `DSOP`, `DINF` and `CINN` layouts, directions |
| [`M1-PROTOCOL-003`](../adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md) | Input, key and clipboard layouts, `CALV` answer, `CINN` sequence for `CCLP`/`DCLP`, rejection semantics |
| M1-029 `BarrierClientHandshake` | Hello validation (M1-027) and HelloBack (M1-028) |
| M1-031 `BarrierControlDecoder` | Control frames, including the client's own `DINF` |
| M1-032, M1-033, M1-034, M1-041 | `DMMV`, `DMDN`/`DMUP`, `DMWM`, `DKDN`/`DKUP`/`DKRP` decoders |
| M1-043 `BarrierVirtualKeyMapper` | `KVMEvent.key` composition |
| M2-028 `BarrierClipboard` | Marshalled clipboard, `DCLP` framing and reassembly |
| M2-029-FOLLOWUP-001 | The server-side mirror: limits, task-group handshake timeout, teardown |

Barrier names and meanings come only from these contracts and the evidence register.

## Handshake

1. `connect()` connects the transport and waits for the server hello.
2. The hello is validated (M1-027), and HelloBack is written (M1-028).
3. `QINF` is answered with `DINF` for the current local screen. The session feeds that
   `DINF` to its own `BarrierControlDecoder` as a client-to-server frame (M1-031), so
   enter coordinates are validated against it.
4. `connect()` returns once that `DINF` is written.

The whole sequence runs under `handshakeTimeout` on the injected `KVMClock`, with the
server session's task-group pattern. A cancelled `connect()` fails closed with the
clock's cancellation error. It never disables the timeout. `CIAK`, `CROP` and `DSOP`
(zero) are accepted and ignored. Any failure disconnects the transport before
`connect()` throws.

## Routing

After HelloBack, every complete payload is routed by its 4-byte token, in this order,
before anything reaches `BarrierControlDecoder`:

| Token | Goes to |
| --- | --- |
| `DMMV` | `BarrierMouseMoveDecoder` for the reported screen, rebuilt on every `DINF` |
| `DMDN`, `DMUP` | `BarrierMouseButtonDecoder` |
| `DMWM` | `BarrierMouseWheelDecoder` |
| `DKDN`, `DKUP`, `DKRP` | the session's `BarrierKeyboardDecoder`, then `BarrierVirtualKeyMapper.kvmEvent(for:)` |
| `DCLP` | `BarrierClipboardAssembler` (clipboard 0 only) |
| `CCLP` | fail closed (a server-to-client `CCLP`) |
| anything else | `BarrierControlDecoder` with `.serverToClient` |

The order matters. `BarrierControlDecoder` skips `DKDN`, `DKUP` and `DCLP`, and fails
closed on `DKRP` and the pointer tokens, so consulting it first would lose every key and
end the session on the first key repeat (M1-041, "Interface for M1-043"). An input or
clipboard frame before the first `DINF` has no screen to check against, so it fails
closed.

`CALV` is answered with `CALV` at once (M1-PROTOCOL-003). `CINN` yields
`.enterScreen(screen: localScreen, position:)`. The position uses the pixel-to-normalized
mapping of `BarrierMouseMoveDecoder`, which is a first-party convention. The `CINN`
sequence is not validated, because the increment rule is not frozen. The latest value is
kept for `CCLP` and `DCLP`. `COUT` yields `.leaveScreen(screen: localScreen)`.

## Rejection semantics

The rules follow M1-PROTOCOL-003 "Rejection semantics".

**Drop and continue.** A dropped frame is counted by reason and the session goes on.
The counts never hold a wire value.

| Case | Reason |
| --- | --- |
| `DMMV` coordinate above 0x7FFF | `pointerOutOfRange` |
| `DMMV` outside the reported rectangle | `pointerOutsideScreen` |
| `DMDN`/`DMUP` outside 1–5 | `buttonOutOfContract` |
| `DMDN`/`DMUP` 5 (no `MouseButton` case) | `buttonUnrepresentable` |
| `DMWM` with no whole notch | `wheelWithoutNotch` |
| `DKRP` of a key that is not held | `unpairedRepeat` |
| `DCLP` transfer that breaks the start, chunk and end rules, an inner length mismatch, or a malformed marshalled clipboard | `clipboardMalformed` |
| transfer over 4 MiB, or text over 1 MiB | `clipboardOversized` |
| complete transfer without text (format 0) | `clipboardWithoutText` |

Clipboard ids other than 0 are ignored without being counted. This is the first-party
convention that only clipboard 0 is shared.

**Fail closed.** These cases end the session with `protocolViolation`, and the events
stream finishes with that error:

- a known token whose body length does not match its layout, for example a 5-byte
  `DMMV`, a 9-byte `CINN`, `CALV` with a body, or a `DCLP` shorter than its fixed 10-byte
  header (id, sequence, mark and data length);
- a server-to-client `CCLP`;
- an unknown token, a payload shorter than a token, and the client-only `CNOP` and
  `DINF` arriving from the server;
- a `DSOP` with a value other than zero;
- control frames in the wrong state (M1-031): `CINN` while entered, `COUT` while not
  entered, `QINF` while entered, setup frames after the first enter;
- a `CINN` outside the reported rectangle;
- a frame over 64 KiB, or a control frame over 4 KiB.

On that terminal path the client Core's cleanup (M1-063-FOLLOWUP-001) releases every
pressed key and button.

## Keys and the fail-safe rule

This follows the M1-041 rule "Fail-safe requirement for consumers" and Frozen Decision 7.

- A `BarrierKeyEvent` with `phase == .repeatKey` and `pairing == .unpaired` is never
  composed into a `KVMEvent`. It is counted as `unpairedRepeat`. A paired repeat is
  yielded as `.repeatKey` of the held key, with the press's identity.
- An unpaired release is passed on, because releasing a key that is not pressed leaves
  nothing stuck.
- The session never synthesizes releases. The Core ledger is the authority.
  `heldKeyCount` (the decoder's held presses) is exposed for the fail-safe report only.

## Liveness (first-party policy)

This is first-party policy, not a Barrier claim, because M1-PROTOCOL-003 does not freeze
the keepalive interval or timeout. The first-party server sends `CALV` every 3 s and
drops a client that is silent for three intervals (M2-029-FOLLOWUP-001).

- The client answers every `CALV` at once.
- It checks once a second whether any server frame arrived.
- After nine silent checks in a row it ends the session with `timeout.keepalive`. That
  is between 9 and 10 seconds after the last server frame.
- The check runs on the injected `KVMClock`, so the tests drive it with a fake clock.
- `CNOP` is not sent, because the first-party server accepts but does not require it
  (`BARRIER-EVID-0006-CLAIM-009`).

## Clipboard (first-party policy)

The client follows the first-party conventions of M1-PROTOCOL-003: UTF-8 text in format 0
of clipboard 0, multi-chunk transfers, and at least 1 MiB of text.

**Inbound.** A complete transfer of clipboard 0 becomes one `.clipboard` event when its
text is at most `clipboardByteLimit` (1 MiB, the server's limit). The payload has origin
`.remote` with one device identifier per session and an empty `contentHash`, which the
platform computes. Transfers may be up to 4 MiB, and frames up to 64 KiB, as on the
server. A server `CALV` between the frames of a transfer is answered at once. The
server's `DCLP` sequence is not validated. The assembler only requires the frames of one
transfer to agree.

**Outbound.** `send(.clipboard)` writes `CCLP` (clipboard 0, the sequence of the `CINN`
in force) and then the `DCLP` transfer with that same sequence, in chunks of at most
32 KiB. That follows `BARRIER-EVID-0007` and `0008`: the captured client used the
sequence of the enter for both. Sending right after the copy is first-party policy, and
the first-party server accepts `CCLP` and `DCLP` at any time while ready. The latest
sequence stays in force after `COUT`.

`send` refuses, without writing a byte:

- text over 1 MiB, with `clipboard.oversized`;
- a send before the first `CINN` (no sequence is in force), or before setup or after
  close, with `lifecycle.subsystemUnavailable`;
- any other event, with `protocol.unsupportedMessage`. The client sends no input.

## Screen updates

`updateScreen(_:)` reports a new local screen.

- **Before the first `DINF`.** The new screen replaces the one `QINF` will get.
- **While the screen is not entered.** `DINF` is written at once. It is fed to the
  control decoder and the pointer decoder is rebuilt.
- **While the screen is entered.** The update is deferred, because M1-031 accepts `DINF`
  only while not entered. It is written right after the next `COUT`, which is yielded
  first. Pointer frames keep using the reported rectangle until then.

An unchanged screen writes nothing. A change followed by its reversal while entered
leaves nothing pending.

## Write order

The reader writes HelloBack, `DINF` and `CALV`. `send` writes the clipboard, and
`updateScreen` writes `DINF`. Each frame takes a ticket in the same critical section that
changed the session's state, and frames are written in ticket order. A `DINF` therefore
never overtakes an earlier `DINF` or any other earlier frame. Every reserved ticket is
written, or skipped once the session is closed, so the order never stalls.

## Errors

| Situation | `CoreError` | Retry |
| --- | --- | --- |
| body length mismatch, malformed values, a truncated or over-long hello, reassembler failure, short `DCLP` | `protocolViolation(.malformed)` | `.backoff` |
| unknown token, wrong direction, server `CCLP`, non-zero `DSOP` | `protocolViolation(.unsupportedMessage)` | `.backoff` |
| frame over 64 KiB, control frame over 4 KiB | `protocolViolation(.oversized)` | `.backoff` |
| control frame in the wrong state, input before setup | `protocolViolation(.invariantViolation)` | `.backoff` |
| hello with another marker or version | `protocolViolation(.unsupportedVersion)` | `.backoff` |
| no server frame for nine checks | `timeout(.keepalive)` | `.backoff` |
| setup not complete within `handshakeTimeout` | `timeout(.handshake)` | `.backoff` |
| end of stream during setup | `transport(.disconnected)` | `.backoff` |
| transport connect or write failure | the transport's own `CoreError`, unchanged | as the transport says |
| `connect()` twice | `internalFailure(.preconditionFailed)` | `.never` |
| refused `send` | see "Clipboard" | `.never` |

The retry dispositions are first-party policy (master plan a.5): `ReconnectManager`
retries only `.backoff`, and a fresh session usually clears a protocol failure. The end
of the stream after setup is a clean end, with `.transportClosed`.

## Concurrency and teardown

- The state lives behind one `NSLock`, hence `@unchecked Sendable`, as in the server
  session. Nothing is awaited while the lock is held.
- One reader task connects the transport and handles payloads in order. Each payload's
  events are yielded before its reply is written.
- `disconnect(reason:)` does the following, once:
  - cancels the reader and the keepalive check;
  - disconnects the transport;
  - finishes `events`. A failure throws its error, a cancellation throws a
    `cancellation` error, and every other reason finishes normally.
- A later `disconnect` call returns once that first teardown has finished. The
  transport's own bounded `disconnect()` bounds it.
- After `disconnect`, `send` and `updateScreen` fail with `lifecycle.subsystemUnavailable`.

## Privacy

Nothing is logged or printed. Errors carry only frozen `CoreError` codes. Diagnostics
hold only `Int` counts and payload-free reasons (`diagnosticsHoldOnlyCounts` walks them by
reflection). Key and clipboard content appears only inside the events, which the
consumer must not log either (M1-011).

## Deviations from the master plan

- **Screen type.** The plan's API sketch passes `BarrierScreenInfo`, which is
  module-internal on main (M1-031). A `package` initializer cannot take it, and the Linux
  composition root needs a `package` API, so the session takes `BarrierLocalScreen`. That
  is a `package` carrier, validated at construction, holding a `BarrierScreenInfo`.
  `BarrierControlMessages.swift` is not changed.
- **Extra barrier.** `waitForPendingWrites(atLeast:)` was added as a second test
  barrier, for the write-order test.
- **Error codes beyond a.5.** a.5 does not list `invariantViolation` (state errors) or
  `unsupportedVersion` (hello). Both carry `.backoff`, like every other protocol
  violation.

## Tests

- `BarrierClientControlEncoderTests` (7 tests):
  - the M1-031 golden `DINF`;
  - the capture-screen `DINF` equals every captured client `DINF`;
  - `DINF` round-trips through `BarrierControlDecoder` with `.clientToServer`, including
    edges and the signed origin;
  - `CALV`;
  - `CCLP` against the capture;
  - the client transfer equals the captured `CCLP` and `DCLP` frames byte for byte;
  - texts up to 600,001 bytes reassemble with the enter's sequence.
- `BarrierClientProtocolSessionTests` (31 tests), driven by a scripted `Transport`, a fake
  `KVMClock`, cancellation-aware barriers and a one-minute suite time limit:
  - golden handshake (hello, HelloBack `m1-client`, the M1-031 `DINF`), and split and
    coalesced chunks;
  - the M2-022 server stream replayed into the expected 257 events. The session writes
    exactly the captured client frames minus `CNOP`. The 7 moves, the button pairs with
    button 5 dropped, the 4 notches and the 232 key events come from an independent
    pairing model. The 2 enters and 2 leaves are in order, and the empty clipboard 0 is
    dropped;
  - five repeated replays with identical results;
  - every fail-closed case above (27 cases), the drop-and-continue cases (22 cases plus
    ignored clipboard ids), and a failed write;
  - the unpaired repeat is never yielded, and an unpaired release is passed on. Random
    key streams (3 seeds, 300 frames each) never yield a repeat of a key that is not held;
  - the `CALV` answer, also inside a clipboard transfer, and the nine-second keepalive
    timeout with a fake clock;
  - clipboard both ways: a 600,001-byte text with a 900,000-byte second format in 32 KiB
    chunks, `CCLP`/`DCLP` with the `CINN` sequence in force (7, then 9), and the 1 MiB
    edge;
  - `send` of input fails closed with no bytes;
  - `updateScreen` deferral while entered, at once while not entered, before setup, and
    the new rectangle validating enters;
  - write order under a held transport write;
  - cancellation during connect (slow server and slow transport), the handshake
    timeout, the hello rejections, input before setup;
  - idempotent disconnect and the disconnect reasons;
  - diagnostics hold only counts.
- `Tests/Integration/BarrierClientServerLoopbackIntegrationTests` (2 tests), with
  `BarrierServerProtocolSession` driven by KVMCore's `ServerSession` and this session
  over an in-memory duplex transport:
  - keepalive answered, enter, move, buttons, wheel, keys with Shift and a repeat,
    clipboard both ways (600,001 bytes included), leave, and client disconnect seen by
    `ServerSession.monitorPeer` as `.transportClosed`;
  - a server close with a key held ends the client stream without a synthesized release.
- Mutation testing: `evidence/issues/M1-029-FOLLOWUP-001/mutations/` holds the runner
  and its report.

## Known limitations

- **No real Barrier server.** Only the first-party Mac server is a supported peer.
  Interoperability with a real Barrier server is not claimed. M4-036-FOLLOWUP-001
  validates the client against the Mac server on the owner's hardware.
- **Non-zero `DINF` origin.** How `DMMV` relates to a non-zero origin is an open question
  in M1-PROTOCOL-003. The session accepts any valid `DINF` screen, and the Linux client
  reports origin (0, 0).
- **Race with a smaller screen.** A `CINN` that the server computed against a screen the
  client has just shrunk can fall outside the new rectangle. It then fails closed, and
  the client reconnects.
- **Unbounded event buffer.** The events stream does not limit its buffer, as in the
  server session. Dropping events could drop a release.
- **No Linux build yet.** The code has not been compiled on Linux in this PR. Linux CI
  (`verify-linux`) arrives with M4-020. The code uses the same Foundation APIs as the
  server session, which the M4-001 spike built on Linux.

## Rollback

Revert the two source files, their two test files, the integration test, this document
and `evidence/issues/M1-029-FOLLOWUP-001/`. No existing file changes, and no consumer
exists yet.
