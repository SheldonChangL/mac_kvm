# M1-032 Barrier Mouse Move Decoder

## Outcome

`BarrierCompatibility` decodes the Barrier pointer frame `DMMV` frozen by
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`
(`BARRIER-EVID-0006-CLAIM-001`) into `KVMEvent.mouseMove(position:)`.
`BarrierMouseMoveDecoder` holds the client's own screen rectangle, validates the
exact body length, the raw coordinate bound `0x0000...0x7FFF` and the client
rectangle, drops out-of-range and out-of-rectangle values with a content-free
diagnostic, and fails closed on a wrong token, direction or body length.

The pixel-to-`NormalizedPoint` conversion inverts the first-party
`BarrierServerInputEncoder`'s pixel mapping, so the pointer lands where the Mac
server put it: exactly for every wire-reachable pixel and at both edges, and within
half a pixel at the center (see "Pixel to `NormalizedPoint`").
`BarrierMouseMoveDecoderTests` proves this by round trips through the encoder in
both directions.

The consumer is the first-party Linux client that speaks the Barrier wire to the
first-party Mac server (`docs/adr/M4-SCOPE-001-linux-client-first.md`); the issue
sits under the M1 milestone, but nothing here is Mac-specific. The decoder is one
input of the later client session (M1-029-FOLLOWUP-001), which is not part of this
issue.

## Frozen inputs

| Source | What M1-032 uses |
|---|---|
| `docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md` | `DMMV` layout (4-byte body, x then y, big-endian, accepted only in `0x0000...0x7FFF`, absolute client pixels); "Rejection semantics" (drop and continue, fail closed); "Non-claims" |
| `BARRIER-EVID-0006-CLAIM-001` in `evidence/registers/M1-023.json` | The seven observed positions; "Only values below 0x8000 were observed; signedness and clamping are not established." |
| `Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json` | The seven server-to-client `DMMV` frames, and the whole server-to-client stream for the fragmentation tests |
| M1-031 `BarrierScreenInfo`, `BarrierControlDirection` | The client's `DINF` rectangle and its containment rule `[origin, origin + size)`; the direction enum |
| M1-022 `BarrierFrameReassembler` | Complete payloads; fragmentation, coalescing and truncation are handled there |
| M2-026 `BarrierServerInputEncoder` | The first-party pixel mapping this decoder inverts; used by the tests only |

### Exact frozen bytes

The capture's client `DINF` is origin (0, 0), 1600 x 900. Each frame below is a
server-to-client `DMMV` of the fixture, identified by the `sequence` of its
observation; the pixel pair is the one the register records.

| Sequence | Frame bytes | Pixel (x, y) | `NormalizedPoint` on 1600 x 900 |
|---:|---|---|---|
| 28 | `00 00 00 08 44 4d 4d 56 00 0a 01 c2` | (10, 450) | (10/1599, 450/899) |
| 30 | `00 00 00 08 44 4d 4d 56 00 0a 01 cc` | (10, 460) | (10/1599, 460/899) |
| 32 | `00 00 00 08 44 4d 4d 56 00 00 01 cc` | (0, 460) | (0/1599, 460/899) |
| 34 | `00 00 00 08 44 4d 4d 56 00 00 01 c2` | (0, 450) | (0/1599, 450/899) |
| 39 | `00 00 00 08 44 4d 4d 56 00 64 01 f4` | (100, 500) | (100/1599, 500/899) |
| 41 | `00 00 00 08 44 4d 4d 56 00 65 01 f5` | (101, 501) | (101/1599, 501/899) |
| 65 | `00 00 00 08 44 4d 4d 56 00 74 01 fa` | (116, 506) | (116/1599, 506/899) |

`capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne` reads the
fixture, checks that each frame holds the pair above and that it decodes to the point
in the last column. `capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder`
re-encodes each decoded point with `BarrierServerInputEncoder` and compares the
whole frame, length prefix included, with the captured bytes.

## API and event model

All declarations are module-internal; no public API or contract is added.

- `BarrierMouseMoveDecoder` (`Sendable` value type):
  - `init(screen:)`, with the client's `BarrierScreenInfo`; the cursor is not read;
  - `decode(payload:direction:) throws(BarrierMouseMoveDecoderError) -> BarrierMouseMoveOutcome`;
  - `bodyByteCount` (4);
  - `normalized(pixel:origin:extent:)`, the pixel formula below.
- `BarrierMouseMoveToken`: `dmmv`, with `bytes`, `byteCount` and
  `init?(payloadPrefix:)` (case-sensitive match of the first four bytes).
- `BarrierMouseMoveOutcome`:
  - `.event(KVMEvent)`, always `.mouseMove(position:)` (an exhaustive switch over
    `KVMEvent` in the tests pins this);
  - `.dropped(BarrierMouseMoveDropDiagnostic)`.
- `BarrierMouseMoveDropDiagnostic`: `token`, `direction`, `bodyByteCount`
  (`Int`) and `reason`, the four fields the contract names. Reasons:
  `coordinateOutOfRange` and `coordinateOutsideScreen`.
- `BarrierMouseMoveDecoderError`: `unknownToken(payloadByteCount:)`,
  `unexpectedDirection(token:direction:)`, `invalidBodyLength(token:bodyByteCount:)`.
  The same names and shapes as `BarrierControlMessageError`, so the session can
  map them uniformly.

The decoder is a value built for one screen. The session builds a new one when a
`DINF` replaces the client screen. `payload` is one complete payload from
`BarrierFrameReassembler`, token included; a whole frame with its length prefix is
not a payload and fails closed as an unknown token.

## Validation

Each payload is checked in this order, and the first failure decides:

| Step | Rule | Result |
|---:|---|---|
| 1 | The first four bytes are `DMMV`, case-sensitive; a payload shorter than four bytes never matches | throws `unknownToken(payloadByteCount:)` |
| 2 | The direction is server-to-client | throws `unexpectedDirection(token:direction:)` |
| 3 | The body is exactly 4 bytes | throws `invalidBodyLength(token:bodyByteCount:)` |
| 4 | Raw x and raw y are both `<= 0x7FFF` | `.dropped(.coordinateOutOfRange)` |
| 5 | The point lies in `[origin, origin + size)` of the client screen on both axes | `.dropped(.coordinateOutsideScreen)` |
| 6 | Otherwise | `.event(.mouseMove(position:))` |

Steps 1 and 3 are the contract's "fail closed" cases (any token not listed, and a
known token whose body length does not match its layout). Step 2 applies the same
rule to a token seen in a direction the contract does not list it in, as M1-031 does
for its tokens; that is a first-party choice. Steps 4 and 5 are the contract's "drop
and continue" cases: a value outside `0x0000...0x7FFF` or outside the client's `DINF`
rectangle is dropped, a diagnostic is emitted and the session continues. A value is
never clamped, because clamping was never observed. The issue's "invalid
coordinate typed error" is this typed drop: the contract's "Rejection semantics"
make an invalid coordinate drop-and-continue, so only the fail-closed cases throw.

- The raw bound is checked before the rectangle, so a raw value above `0x7FFF` is
  reported as `coordinateOutOfRange` even where the rectangle would also reject it.
  It is dropped even when the rectangle contains it: a rectangle that extends past
  `0x7FFF` contains `0x8000`, and a rectangle that starts at -32768 would contain
  it if it were read as signed. The contract does not freeze signedness, so neither
  reading is used.
- The rectangle is `[origin, origin + size)` on each axis, computed in `Int`, so the
  first and last cells are inside, `origin + size` is outside, and no edge can
  overflow (`BarrierScreenInfo.contains`, M1-031).
- The split of the drop reasons into two is a first-party diagnostic; the contract
  names only "the reason".
- The decoder trusts the screen it is given. A zero-size screen, which M1-031 never
  produces, drops every point.

## Pixel to `NormalizedPoint`

First-party convention, not a Barrier claim:

```text
normalized = (pixel - origin) / (extent - 1)      0 when extent is 1
```

per axis, with `extent` the width or height of the client `DINF` and `pixel` the raw
wire value. It is the inverse of `BarrierServerInputEncoder`, which sends
`origin + round(normalized * (extent - 1))`, clamped into the rectangle and into
`0...0x7FFF`. The first pixel is 0 and the last is 1. Dividing by `extent` instead
would map the last pixel to `(extent - 1) / extent`, so the edge round trip below
would fail.

`NormalizedPoint` clamps to `0...1`. Containment is checked first, so the quotient
is already in that range and nothing is clamped silently. A consumer that turns the
point back into a pixel lands on the pixel the server sent only if it uses the same
`origin + round(normalized * (extent - 1))` mapping.

Exactness, as the tests state it:

- **Decode then encode is exact for every wire-reachable pixel.** The product
  `(p / (extent - 1)) * (extent - 1)` differs from `p` by far less than 0.5, so the
  encoder's rounding restores `p`.
  `everyReachablePixelRoundTripsDecodeThenEncode` sweeps every pixel of several small
  screens, including origins -3 and `0x7FF9`, and every column and every row of the
  capture screen, 1920 x 1080, 3840 x 2160 and the largest extent the contract allows
  (`0x7FFF`).
- **Encode then decode is exact at both edges.** 0.0 gives the origin pixel and
  decodes to 0.0; 1.0 gives the last pixel and decodes to 1.0, on every screen with
  two or more pixels per axis that lies inside `0...0x7FFF`. A one-pixel axis has one
  position, so both edges decode to 0.
- **At the center 0.5 it is exact only when `extent - 1` is even.** On 1601 x 901,
  0.5 is pixel 800 and 450 and decodes back to exactly 0.5. On the capture's
  1600 x 900, 0.5 times 1599 is 799.5, which rounds to pixel 800; that decodes to
  800/1599, within `1 / (2 * 1599)` of 0.5 but not equal to it, and re-encoding gives
  pixel 800 again. This is a property of the first-party mapping, not of the decoder.
  (`edgesAndCenterRoundTripThroughTheEncoder`)
- Pixels below 0 are unreachable on the wire, and the encoder clamps `lowest` to 0.
  On the M1-031 golden screen (origin -1920, width 3648), pixel 0 decodes to
  1920/3647.

## Drop diagnostics and privacy

- The decoder never logs, prints or imports a logger
  (`productionSourceImportsOnlyKVMContracts`).
- Errors and the drop diagnostic carry only allowlisted metadata: the token, the
  direction, the body length as an `Int` and a fixed reason. No case holds payload
  bytes, a coordinate, a string or screen geometry; the tests reject any fixed-width
  integer, floating-point number, byte array or screen value in their reflected
  values, over an exhaustive list of error cases and both reasons
  (`dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata`). That test also checks that
  the walker would detect each forbidden shape.
- The decoded position appears only inside `.event`, where the injector needs it. It
  is an output, not a diagnostic: the session must never log it. How the session
  counts drops under M1-011 (closed reasons and counts only) is its own decision.
- Tests use the fixture's frames and synthetic values; no real typed text,
  clipboard content, address or credential appears in tests or evidence.

## Architecture boundary

- Barrier tokens and types stay in `BarrierCompatibility`; nothing is added to
  `KVMContracts`, `KVMCore` or `NativeProtocol`, and `KVMEvent` is unchanged.
- The production file imports `KVMContracts` only (for `KVMEvent` and
  `NormalizedPoint`). No OS framework, networking, logging or Native Protocol module.
- No transport, socket, TLS, timer or trust logic. Production TLS defaults are
  unchanged.
- M1-026 `BarrierMessageRegistry` is not used, for M1-031's reason: its registration
  is fallible and it reports unknown payloads as a non-error outcome, while this
  decoder has a closed token set that fails closed.
- The session must offer a `DMMV` payload to this decoder before it offers it to
  `BarrierControlDecoder`, which does not recognize the token and fails closed.
  This decoder in turn re-checks its own token, so a mis-routed payload fails closed
  instead of being parsed.
- The decoder is stateless: it owns no I/O, timer, task, lock or other resource, so
  there is nothing to cancel or clean up and cancellation tests do not apply. A
  thrown error or a drop latches nothing, unlike `BarrierControlDecoder`'s sticky
  failure. On any thrown error the session ends the session and its cleanup
  (M1-063-FOLLOWUP-001) releases pressed keys and buttons; the decoder does neither.

## Non-claims

- No pointer value at or above `0x8000`, and no negative coordinate, is interpreted:
  the first is dropped, the second cannot be expressed in the accepted raw range.
- No clamping: it was never observed, so out-of-range and out-of-rectangle values
  are dropped.
- No claim about `DMMV` relative to a non-zero `DINF` origin: the `DINF` origin was
  (0, 0) in every capture, and the contract lists this as an open question. For a
  non-zero origin the decoder applies the same first-party inverse as the encoder,
  `pixel - origin`; that this matches how a Barrier server addresses such a client
  is not claimed. Multi-monitor client layouts stay blocked on that question.
- No signedness claim for x and y beyond "accepted only in `0x0000...0x7FFF`".
- No `DMDN`, `DMUP`, `DMWM`, key or clipboard decoding; no `KVMProtocolSession`
  conformance, no mapping to `CoreError`, no `DINF` reply.
- No TLS, Windows or full-interoperability claim.
- No Barrier/Deskflow source, header, generated constant or decompiled output was
  consulted; only the contract, the register and the fixture are used.

## Tests

`BarrierMouseMoveDecoderTests` (16 Swift Testing tests):

- token: the frozen ASCII bytes, case sensitivity and short prefixes;
- golden: the seven captured frames decode to the observed pixels normalized by
  `extent - 1`; the same frames re-encode byte for byte through the server encoder;
- round trips through the encoder: every reachable pixel decode-then-encode; edges
  and center encode-then-decode; the pixel formula itself (`normalized`), including
  one-pixel axes;
- boundaries: raw `0x8000`, `0x8001` and `0xFFFF` on each axis, with a rectangle past
  `0x7FFF` and a rectangle read as signed; first and last cells inside and one past
  each edge outside, with negative and extreme origins;
- invalid input: wrong body lengths, with and without trailing bytes; wrong
  direction before any body check; unknown, short, lowercase and foreign tokens,
  including a whole frame passed as a payload;
- output type and privacy: events are always `mouseMove`; reflected errors and
  diagnostics hold only enums and `Int` counts;
- fragmentation/coalescing/truncation: the fixture's server-to-client stream, routed
  by token to this decoder only, coalesced, one byte at a time and split at every
  boundary; truncated at every byte it hands the decoder only complete frames, and
  `finish()` throws on a partial frame;
- purity: the same payload gives the same outcome, drops and failures latch nothing,
  and two screens differ only through the formula;
- architecture: the production source imports only `KVMContracts` and names no logger.

## Limitations

- Only a client at origin (0, 0), 1600 x 900, was captured; other geometry rests on
  the first-party inverse and on the round-trip tests, not on Barrier evidence.
- The contract accepts only `0x0000...0x7FFF`, so a server that sent negative
  positions for a client at a negative origin would have them dropped as
  `coordinateOutOfRange`. The contract's open question about negative coordinates
  must be answered before that is relaxed.
- The decoder relies on the caller for the direction and for passing the client's own
  `DINF` screen; it cannot verify the transport direction itself.
- The center of an even extent decodes to within `1 / (2 * (extent - 1))` of 0.5,
  not exactly 0.5.
- `evidence/registers/M1-023.json` does not list this suite under
  `consumingTests` for `BARRIER-EVID-0006`: the register is outside this issue's
  files. That is a follow-up for the register owner.

## Rollback

Revert the M1-032 change: `BarrierMouseMoveDecoder.swift`,
`BarrierMouseMoveDecoderTests.swift`, this document and `evidence/issues/M1-032/`.
The decoder owns no runtime resource, persisted data or migration, and no production
code consumes it yet.
