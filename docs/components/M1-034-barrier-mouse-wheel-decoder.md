# M1-034 Barrier Mouse Wheel Decoder

## Outcome

`BarrierCompatibility` decodes one reassembled Barrier `DMWM` payload, the
server-to-client wheel frame frozen by
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`
(`BARRIER-EVID-0006-CLAIM-003`), into a `KVMEvent.scroll`.
`BarrierMouseWheelDecoder` is a stateless, module-internal namespace of static
functions. It checks the token, the direction and the exact body length, reads
two signed 16-bit deltas, converts each axis to whole notches, and either
returns the scroll or drops a frame that holds less than one notch with a
content-free diagnostic. Anything malformed fails closed with a typed
`BarrierMouseWheelDecoderError`.

The consumer is the first-party Linux client session (M1-029-FOLLOWUP-001, the
approved path in `docs/adr/M4-SCOPE-001-linux-client-first.md`). The issue sits
under the "M1 - Mac Client MVP" milestone heading, but it is one input of that
client session. Nothing consumes the decoder yet.

## Frozen inputs

| Source | What M1-034 uses |
|---|---|
| `docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`, "Wheel: DMWM" | 4-byte body, x delta then y delta, signed big-endian; the four one-notch bodies; the first-party convention block |
| Same ADR, "Rejection semantics" | A known token with a wrong body length fails closed; a drop emits a diagnostic with the token, the direction, the body length and the reason, never body bytes |
| `BARRIER-EVID-0006-CLAIM-003` in `evidence/registers/M1-023.json` | 120 wire units per notch; one notch per direction was observed; other magnitudes are not established |
| `Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json` | The four captured `DMWM` frames (observations with `sequence` 72, 74, 76 and 78) |
| M1-022 `BarrierFrameReassembler` | Complete payloads; fragmentation, coalescing, truncation and the pre-buffer length limit |
| M1-031 `BarrierControlDirection` | The direction type, reused unchanged |

### Exact frozen bytes

All four frames are server-to-client. The capture driver produced them in the
order up, down, left, right.

| Notch | Frame bytes | Body (x, y) |
|---|---|---|
| up | `00 00 00 08 44 4d 57 4d 00 00 00 78` | (0, +120) |
| down | `00 00 00 08 44 4d 57 4d 00 00 ff 88` | (0, -120) |
| left | `00 00 00 08 44 4d 57 4d ff 88 00 00` | (-120, 0) |
| right | `00 00 00 08 44 4d 57 4d 00 78 00 00` | (+120, 0) |

`capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight` reads the fixture,
compares its four `DMWM` frames with these hand-copied bytes in this order, and
decodes the fixture's own frames. `capturedNotchFramesReEncodeByteForByteThroughTheServerEncoder`
then re-encodes each decoded frame with `BarrierServerInputEncoder.scroll` and
compares the whole frame, length prefix included, not only the decoded deltas.

## API and event model

All declarations are module-internal; no public API or contract is added.

- `BarrierMouseWheelDecoder` (caseless enum):
  - `decode(payload:direction:) throws(BarrierMouseWheelDecoderError) -> BarrierMouseWheelOutcome`.
    `payload` is one complete payload, token included, as
    `BarrierFrameReassembler.nextPayload()` returns it. `direction` is the
    M1-031 `BarrierControlDirection`, required on every call;
  - `deltas(wireX:wireY:) -> (deltaX: Int32, deltaY: Int32)`: the per-axis rule
    on already-signed wire values;
  - `bodyByteCount` (4) and `unitsPerNotch` (120).
- `BarrierMouseWheelToken`: `dmwm`, with `bytes` and `init?(payloadPrefix:)`.
- `BarrierMouseWheelOutcome`:
  - `.event(KVMEvent)`: always `KVMEvent.scroll(deltaX:deltaY:)`, with at least
    one non-zero delta;
  - `.dropped(BarrierMouseWheelDropDiagnostic)`.
- `BarrierMouseWheelDropDiagnostic`: `token`, `direction`, `bodyByteCount` (the
  body length, not the payload length) and `reason` (`.noWholeNotch`).
- `BarrierMouseWheelDecoderError`: `unknownToken(payloadByteCount:)`,
  `unexpectedDirection(token:direction:)` and
  `invalidBodyLength(token:bodyByteCount:)`.

The decoder produces a `KVMEvent` and nothing else; there is no later mapping
stage for the wheel, and `KVMEvent` is unchanged
(`outcomeEventsAreAlwaysScroll` is an exhaustive switch over `KVMEvent`).

The token, error, diagnostic and outcome types live in this file. Each
client-direction decoder carries its own copies of one template, because each
issue's Exact Files are hard limits; the session may unify them later.

The client session, which does not exist yet, is expected to route payloads by
their 4-byte token before it offers anything to `BarrierControlDecoder`, which
fails closed on every token it does not know, `DMWM` included. Per the ADR's
"Rejection semantics", a drop emits a diagnostic and the session continues, and a thrown
error is a protocol violation that ends the session. The decoder neither logs
nor disconnects.

## Validation order

Each payload is checked in this order; the first failure is thrown:

1. at least 4 bytes that start with `DMWM`, case-sensitive
   (`unknownToken(payloadByteCount:)`);
2. the direction: only `.serverToClient` (`unexpectedDirection(token:direction:)`),
   checked before the body, so a malformed body cannot mask a wrong direction;
3. exact body length 4 (`invalidBodyLength(token:bodyByteCount:)`);
4. the per-axis rule, then the zero-result policy.

## Per-axis rule and sign convention

This is a first-party convention, not a capture claim. In first-party code a
positive `deltaY` of `KVMEvent.scroll` scrolls up and a positive `deltaX`
scrolls left. A left notch is -120 on the wire, so the horizontal axis is
inverted in both directions:

```text
server:  wireX = -deltaX * 120    wireY = deltaY * 120   (each saturated to 16 bits)
client:  deltaX = -wireX / 120    deltaY = wireY / 120   (integer division toward zero)
```

The first-party Mac server's `BarrierServerInputEncoder.scroll` is the first
line; this decoder is the second.

| Wire body (x, y) | Notch | `KVMEvent.scroll` |
|---|---|---|
| (0, +120) | up | `deltaX: 0, deltaY: +1` |
| (0, -120) | down | `deltaX: 0, deltaY: -1` |
| (-120, 0) | left | `deltaX: +1, deltaY: 0` |
| (+120, 0) | right | `deltaX: -1, deltaY: 0` |

The arithmetic reads each field as `UInt16`, reinterprets it as `Int16`, widens
it to `Int32`, and only then negates and divides. `Int16.min` has no negation in
`Int16`; widening first keeps `0x8000` (-32768) safe. Swift's `/` truncates
toward zero, which is the contract's rule.

**The lesson of the inverted horizontal axis.** The first client rule divided
both axes by 120 without inverting the horizontal one, so a first-party client
would have scrolled horizontally the opposite way from the first-party server.
A Codex review of `fd32fee` found it, and `226b011` corrected the rule (see the
ADR's "Review record"). The decoder pins the sign three independent ways:

- by the captured notches' names, `capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight`;
- by a round trip through `BarrierServerInputEncoder.scroll` for every delta
  pair up to 273,
  `scrollRoundTripsThroughTheServerEncoderForEveryDeltaPairUpTo273`;
- by direct sign assertions, `horizontalAxisIsInvertedAndVerticalIsNot`.

**Not validated end to end.** The M2-035 smoke against a real `barrierc`
validated only the vertical multiple-notch case (a scroll of -2 produced two X
button-5 events). No horizontal scroll was exercised, so the horizontal sign is
backed by the contract, the capture's named notches and the encoder round trip,
not by an interoperability run. M4-036-FOLLOWUP-001, the first-party Linux
client to first-party Mac server run, must include a horizontal scroll.

## Magnitudes beyond one notch are a convention

The capture holds one notch per direction. Bodies such as (0, +240), the
remainder rule and the conversion above for several notches are the ADR's
first-party convention. The ADR's non-claims name "wheel magnitudes other than
one notch, as capture claims".

- (0, +240) and (-240, 0) decode to `deltaY: 2` and `deltaX: 2`;
- the remainder is dropped toward zero: (0, +121) is `deltaY: 1`, and (0, -121)
  is `deltaY: -1`, not -2 (floor division would give -2);
- each axis is rounded on its own: (-119, +120) is `deltaX: 0, deltaY: +1`.

## Zero result policy

A frame whose axes both divide to zero (|wire| below 120 on both, including
(0, 0)) is dropped: `.dropped` with reason `noWholeNotch`. A `.scroll(0, 0)` is
never emitted. This is a first-party policy that uses the contract's drop
diagnostic shape; the ADR's "drop and continue" list names `DMMV`,
`DMDN`/`DMUP` and `DCLP`, not `DMWM`.

- The first-party pair never represents a zero scroll: the Mac capture returns
  `nil` when both deltas are zero, and `BarrierServerInputEncoder.scroll`
  returns `nil` too. The contract drops the remainder.
- A zero `.scroll` would be a no-op that every injector must special-case.
- A diagnostic keeps sub-notch frames visible as counts by reason.

The drop is "drop and continue", not a protocol violation. The diagnostic holds
the four fields the ADR names: token, direction, body length and reason.

## Saturation bound 273

One 16-bit wire value carries at most `Int16.max / 120 = 273` whole notches per
axis: (0x7FFF, 0x7FFF) decodes to `deltaX: -273, deltaY: 273` and
(0x8000, 0x8000) to `deltaX: 273, deltaY: -273`. The first-party encoder
saturates each axis to 16 bits, so a scroll above 273 notches on one axis
arrives as 273 and the round trip is exact only up to 273 notches per axis in
either direction. The tests cover the whole exact range and the saturated
extremes. The decoder neither errors nor rescales beyond it.

## Diagnostics and privacy

- The decoder performs no logging or printing and imports only `KVMContracts`
  (`productionSourceImportsOnlyKVMContracts`).
- Errors and the drop diagnostic carry only enums and `Int` counts: token,
  direction, body length and a fixed reason. The tests reject any string, byte
  array, fixed-width integer (the shape of a wire delta) or class instance in
  their reflected values, and check the walker against positive controls
  (`dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata`, and every thrown
  error in the invalid-input tests).
- Decoded deltas appear only inside `.event`. The event is an output, not a
  diagnostic, and a consumer must not log it: the M1-011 metadata allowlist
  permits only closed enums and bounded counts that do not encode user actions.
- Tests use the capture fixture's frames and synthetic bodies. No typed text,
  clipboard bytes, address or credential appears in tests or evidence.

## Architecture boundary

- Barrier tokens and types stay in `BarrierCompatibility`; nothing is added to
  `KVMContracts`, `KVMCore` or `NativeProtocol`.
- The production file imports `KVMContracts` only, for `KVMEvent`. No OS
  framework, networking, KVM Core, Native Protocol or logging module.
- No transport, socket, TLS, timer or trust logic.
- M1-026 `BarrierMessageRegistry` is not used: its registration is fallible and
  it reports unknown payloads as a non-error outcome, while the wheel decoder
  has one closed token and fails closed on everything else.

## Non-claims

- No claim about a wheel magnitude other than one notch as a Barrier capture
  fact, and none about pixel, smooth or high-resolution scrolling.
- No end-to-end validation of horizontal scroll.
- No claim about the `KVMEvent.scroll` direction convention beyond first-party
  code and the ADR; C-001 does not state it.
- No session behavior: routing, mapping thrown errors to `CoreError`, counting
  drops and cleanup belong to the client session (M1-029-FOLLOWUP-001).
- No Barrier or Deskflow source, header, generated constant or decompiled
  output was consulted; only the frozen ADR, the register and the sanitized
  fixture are used.

## Tests

`BarrierMouseWheelDecoderTests` (17 Swift Testing tests):

- golden bytes and named directions: token bytes; the fixture's `DMWM` frames
  equal the hand-copied frames and decode to up (0, +1), down (0, -1), left
  (+1, 0) and right (-1, 0); each decoded fixture frame re-encodes through
  `BarrierServerInputEncoder.scroll` to the identical frame;
- round trip: every delta pair from {-273, -3 to 3, 273} that is not (0, 0),
  and each axis alone over -273 to 273, decodes back unchanged after the
  encoder;
- the rule: direct sign assertions; remainders toward zero (119 is 0, 121 is 1,
  -121 is -1); every `Int16` value on each axis against an independent oracle
  (Double division rounded toward zero), and a boundary grid on both axes;
- bounds: `0x8000`, `0x7FFF` and the encoder's saturated extremes;
- zero result: frames below one notch on both axes are dropped with a
  diagnostic;
- invalid input: bodies of 0, 1, 2, 3, 5, 6, 8 and 12 bytes; the client-to-server
  direction, also with a malformed body; unknown, short, lowercase, foreign-token
  and whole-frame inputs;
- output and privacy: events are always `scroll`; errors, the reason and a drop
  carry only allowlisted metadata;
- fragmentation, coalescing and truncation: the server-to-client stream of the
  M2-022 capture (four wheel frames among 284 frames) through
  `BarrierFrameReassembler`, coalesced, one byte at a time, split at every byte
  boundary and truncated at every length. Only the wheel frames completed before
  a cut are decoded, and `finish()` reports a partial frame;
- state: the decoder is deterministic and carries no state, and a rejected
  payload latches nothing.

The decoder owns no I/O, timer, task or resource, so there is nothing to cancel
or clean up; cancellation tests do not apply. Idempotency is covered instead by
`decoderIsStatelessAndDeterministic`.

## Limitations

- Multi-notch magnitudes and the remainder rule are first-party conventions.
  M2-035 validated only the server's vertical multi-notch frame against a real
  `barrierc`; no run has validated this decoder's remainder rule. No fixture
  holds a body other than one notch.
- The decoder drops the remainder of each frame and keeps no state across
  frames, so a peer that sends wheel steps below 120 units would produce only
  drop diagnostics. The first-party server never sends them.
- At most 273 notches per axis per frame (above).
- The token, error, diagnostic and outcome types, and the test helpers, are
  per-file copies of a template shared by the client-direction decoders.
- The decoder trusts the caller for the direction and for passing one complete
  payload; it cannot verify the transport itself.
- The register's `consumingTests` links for `BARRIER-EVID-0006` do not list
  these tests, because `evidence/registers/M1-023.json` is outside this issue's
  Exact Files. This is a follow-up for the register owner.

## Rollback

Revert the M1-034 change: `BarrierMouseWheelDecoder.swift`,
`BarrierMouseWheelDecoderTests.swift`, this document and
`evidence/issues/M1-034/`. The decoder owns no runtime resource, persisted data
or migration, and no production code consumes it yet.
