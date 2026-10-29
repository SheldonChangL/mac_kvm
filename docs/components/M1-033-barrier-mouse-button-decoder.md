# M1-033 Barrier Mouse Button Decoder

## Outcome

`BarrierCompatibility` decodes the Barrier `DMDN` and `DMUP` frames frozen by
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`
(`BARRIER-EVID-0006-CLAIM-002`) into `KVMEvent.mouseButton` values.
`BarrierMouseButtonDecoder` is a stateless, module-internal decoder. It checks the
token, the direction and the exact body length, maps the one-byte button number
to a `MouseButton` with an explicit table, and turns `DMDN` into a press and
`DMUP` into a release. A button number that `MouseButton` cannot represent is
dropped with a content-free diagnostic and the session continues. Every other
failure throws a typed `BarrierMouseButtonDecoderError`.

The consumer is the first-party Linux client's session (M1-029-FOLLOWUP-001, see
`docs/adr/M4-SCOPE-001-linux-client-first.md`). The issue sits under the M1
milestone, but M4-SCOPE-001 makes the first-party Linux client the approved path.

## Frozen inputs

| Source | What M1-033 uses |
|---|---|
| `docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md` | "Buttons": a 1-byte body, the observed values 1 to 5, equal values in each down/up pair, a held button spanning pointer moves; "Rejection semantics": `DMDN` or `DMUP` outside 1 to 5 is dropped with a diagnostic of token, direction, body length and reason, and a known token with the wrong body length fails closed; Frozen Decision 7 (fail-safe) |
| `BARRIER-EVID-0006-CLAIM-002` in `evidence/registers/M1-023.json` | The observed button values |
| `Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json` | The twelve button frames below |
| `BarrierServerInputEncoder.button` | The first-party button table that this decoder inverts (first-party, not a Barrier claim) |
| M1-022 `BarrierFrameReassembler` | Complete payloads; fragmentation, coalescing, truncation and the pre-buffer length limit |

### Exact frozen bytes

The capture holds twelve server-to-client button frames. "Observation" is the
fixture's 1-based `sequence` field.

| Observation | Frame bytes | Token | Value | Decoder outcome |
|---|---|---|---|---|
| 43 | `00 00 00 05 44 4d 44 4e 01` | `DMDN` | 1 | left press |
| 44 | `00 00 00 05 44 4d 55 50 01` | `DMUP` | 1 | left release |
| 47 | `00 00 00 05 44 4d 44 4e 03` | `DMDN` | 3 | right press |
| 48 | `00 00 00 05 44 4d 55 50 03` | `DMUP` | 3 | right release |
| 51 | `00 00 00 05 44 4d 44 4e 02` | `DMDN` | 2 | middle press |
| 52 | `00 00 00 05 44 4d 55 50 02` | `DMUP` | 2 | middle release |
| 55 | `00 00 00 05 44 4d 44 4e 04` | `DMDN` | 4 | auxiliary press |
| 56 | `00 00 00 05 44 4d 55 50 04` | `DMUP` | 4 | auxiliary release |
| 59 | `00 00 00 05 44 4d 44 4e 05` | `DMDN` | 5 | dropped, `unrepresentableButton` |
| 60 | `00 00 00 05 44 4d 55 50 05` | `DMUP` | 5 | dropped, `unrepresentableButton` |
| 63 | `00 00 00 05 44 4d 44 4e 01` | `DMDN` | 1 | left press |
| 70 | `00 00 00 05 44 4d 55 50 01` | `DMUP` | 1 | left release |

In the capture, the driver's X buttons 1, 3, 2, 8 and 9 produced the wire values
1, 3, 2, 4 and 5. Observations 63 to 70 hold, server to client, a `DMDN` 1, a
`DMMV`, a `CALV` and a `DMUP` 1: the held button spans a pointer move.

`goldenButtonFramesEqualTheBarrierEvid0006FixtureBytesExactly` reads the fixture
and compares every button frame, in order, byte for byte with the hand-copied
constants. `capturedButtonFramesDecodeInOrderWithButtonFiveDropped` decodes the
fixture's frames and compares the outcomes with the table above.

## API and event model

All declarations are module-internal; no public API or contract is added.

- `BarrierMouseButtonDecoder` (a caseless `enum`):
  - `decode(payload:direction:) throws(BarrierMouseButtonDecoderError) -> BarrierMouseButtonOutcome`;
  - `mouseButton(wireValue:) -> MouseButton?`, the table;
  - `bodyByteCount` (1).
- `BarrierMouseButtonToken`: `dmdn` and `dmup`, with `bytes`, `phase` and
  `init?(payloadPrefix:)`.
- `BarrierMouseButtonOutcome`:
  - `.event(KVMEvent)`, always `.mouseButton(button:phase:)`;
  - `.dropped(BarrierMouseButtonDropDiagnostic)`.
- `BarrierMouseButtonDropDiagnostic`: `token`, `direction`, `bodyByteCount` and a
  closed `Reason` (`buttonOutOfContract`, `unrepresentableButton`).
- `BarrierMouseButtonDecoderError`: `unknownToken(payloadByteCount:)`,
  `unexpectedDirection(token:direction:)` and `invalidBodyLength(token:bodyByteCount:)`.

The input is one complete payload from `BarrierFrameReassembler`, token included
and without the 4-byte length prefix, plus a `BarrierControlDirection` (the M1-031
type, reused unchanged). The decoder re-checks its own token, so a payload routed
to it by mistake fails closed instead of being parsed.

The client session (M1-029-FOLLOWUP-001, not implemented here) routes a payload
whose token is `DMDN` or `DMUP` to this decoder, yields a `.event`, counts a
`.dropped` by its reason, and ends the session on a thrown error so that cleanup
runs (M1-PROTOCOL-003 "Fail closed"). The decoder neither logs nor disconnects.

## Validation order

Each payload is checked in this order:

1. The token, case-sensitive, from the first four bytes: otherwise
   `unknownToken(payloadByteCount:)`. A payload shorter than four bytes, another
   token (`DMMV`, `DMWM`, `DKDN`, `CALV` and so on), `dmdn` and a whole frame with its
   length prefix all fail here.
2. The direction: `DMDN` and `DMUP` were observed only server to client, so
   `.clientToServer` throws `unexpectedDirection(token:direction:)`.
3. The body length: exactly one byte, otherwise
   `invalidBodyLength(token:bodyByteCount:)`. A wrong length is never reported as a
   drop, even when the bytes would have been out of contract.
4. The value:
   - 1 to 4: `.event(.mouseButton(button:phase:))`;
   - 5: dropped, `unrepresentableButton`;
   - 0 and 6 to 255: dropped, `buttonOutOfContract`.

The phase comes from the token alone: `DMDN` is `.down` and `DMUP` is `.up`.

## Button table

| Wire value | `MouseButton` | Driver's X button in the capture |
|---|---|---|
| 1 | `.left` | 1 |
| 2 | `.middle` | 2 |
| 3 | `.right` | 3 |
| 4 | `.auxiliary` | 8 |
| 5 | none; dropped, `unrepresentableButton` | 9 |
| 0, 6 to 255 | none; dropped, `buttonOutOfContract` | not observed |

What each column rests on:

- The wire values 1 to 5 and their pairing with the driver's X buttons come from
  the contract.
- The `MouseButton` names are the first-party table of
  `BarrierServerInputEncoder.button` (left 1, middle 2, right 3, auxiliary 4). The
  contract does not name the buttons. The encoder's frames equal the captured
  frames byte for byte (`BarrierServerPointerEncoderTests`, `buttons`), and
  `everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder` runs this decoder
  against the encoder for all four buttons and both phases.
- Smoke evidence, not a contract claim: the M2-035 automated smoke
  (`evidence/issues/M2-035/automated-smoke/README.md` and `x-events.txt`), first-party
  server to a real `barrierc`, sent left, right and middle, and the real client
  produced X raw buttons 1, 3 and 2. That smoke did not send the auxiliary button.

**Raw-value warning.** `MouseButton`'s raw values are left 1, right 2, middle 3,
auxiliary 4. They are not the wire values. `MouseButton(rawValue:)` applied to a
wire value would silently swap right and middle: wire 2 would click the right
button and wire 3 the middle button. The decoder uses an explicit table, and
`wireValuesFollowTheEncodersTableNotMouseButtonRawValues` asserts both the trap and
the table.

## Button 5

**Decoder policy (first-party, not a capture claim).** Wire value 5 is inside the contract's 1 to 5, but `MouseButton` has four cases, so
no `KVMEvent` can carry it. Both `DMDN` 5 and `DMUP` 5 are dropped with
`unrepresentableButton`.

- It is "drop and continue", not a protocol violation: the capture shows a server
  sending wire 5 for the driver's X button 9, so a user pressing that button must
  not end the session.
- The first-party Mac server never sends 5.
- The capture contains it (observations 59 and 60), so
  `capturedButtonFramesDecodeInOrderWithButtonFiveDropped` pins the drop.
- This is a known limitation of this issue and not a contract change. Supporting
  a fifth button would add a `KVMContracts` case and would also change the Mac
  capture and the server encoder; that needs its own issue.

## Statelessness

The decoder keeps no pressed-button set. Whether a frame is emitted or dropped
depends only on its own bytes.

- The drop is decided by the button value alone, so a `DMUP` is dropped exactly
  when the `DMDN` with the same value is. Every press the decoder emits can
  therefore be released by an emitted `DMUP` with the same value, and a dropped
  release never strands a press of its own value (Frozen Decision 7; the contract:
  "its `DMDN` was dropped, so nothing is held").
  `aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue` checks the
  invariant for all 256 values. The guarantee is for pairs with equal values, the
  only pairs the contract observed; see "Limitations" for a pair whose values
  differ.
- Decoder policy (first-party, not a capture claim): a `DMUP` of a representable
  button is emitted even when no `DMDN` preceded it.
  A release is never dropped for lack of a press
  (`releaseWithoutAPressIsStillEmitted`). What an unpaired release means is the
  decision of the client's pressed-input ledger (M1-063-FOLLOWUP-001), not of the
  decoder.
- Releasing whatever is still held when the session ends is also the Core's cleanup
  (M1-PROTOCOL-003 "Fail closed", M1-063-FOLLOWUP-001), not the decoder's.
- A failure does not latch, unlike the control decoder of M1-031: the next valid
  payload decodes. Ending the session is the caller's job.
- The decoder owns no I/O, timer, task, lock or other resource, so there is nothing
  to cancel or clean up; cancellation tests do not apply. Idempotency is covered by
  `decoderIsStatelessAndDeterministic`.

## Diagnostics and privacy

- The decoder performs no logging or printing and imports only `KVMContracts`
  (`productionSourceImportsOnlyKVMContracts`).
- Errors and the drop diagnostic carry only allowlisted metadata: token, direction,
  the body length as an `Int` and a closed reason. No case holds a payload byte,
  the button value, a string or a fixed-width integer; the tests reject any of them
  in the reflected values of every error case, both reasons, and the diagnostic
  each dropped value produces
  (`dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata`).
- The decoded button and phase appear only inside `.event`. They are an output, not
  a diagnostic, and must not be logged either.
- The session decides how to count dropped frames under M1-011: closed reason enums
  and counts only, never the raw value.
- Tests use the fixture's frames and synthetic one-byte values. No typed text,
  clipboard content, address, host name or credential appears in the tests or the
  evidence.

## Architecture boundary

- Barrier tokens and types stay in `BarrierCompatibility`. Nothing is added to
  `KVMContracts`, `KVMCore` or `NativeProtocol`; `KVMEvent` and `MouseButton` are
  unchanged.
- The production file imports `KVMContracts` only: no OS framework, networking,
  KVM Core or Native Protocol module.
- The decoder updates no macOS state; it returns a value.
- No transport, socket, TLS, timer or trust logic. Production TLS defaults are
  unchanged.
- M1-026 `BarrierMessageRegistry` is not used, for the reason M1-031 gives: its
  registration is fallible and it reports unknown payloads as a non-error outcome,
  while this decoder has a closed token set that fails closed.

## Non-claims

- No Barrier meaning is claimed for the button numbers beyond the contract's
  observed table. The `MouseButton` names are the first-party encoder's.
- Wire 4 was captured (the driver's X button 8), but the first-party server's
  auxiliary button was not exercised against a real `barrierc` in the M2-035 smoke
  (`evidence/issues/M2-035/automated-smoke/x-events.txt`).
- Nothing is claimed about the wire values 0 and 6 to 255 except that they are
  dropped.
- No click count, pointer position, modifier or other input is decoded here.
- No Barrier/Deskflow source, header, generated constant or decompiled output was
  consulted; only the frozen contract, the register entry and the sanitized fixture
  are used.

## Tests

`BarrierMouseButtonDecoderTests` (20 Swift Testing tests):

- golden bytes: the token bytes and phases; the hand-copied frames equal the
  fixture's, in order; the fixture frames decode in order with wire 5 dropped; all
  four buttons and both phases round-trip through `BarrierServerInputEncoder`, and
  each encoder frame equals the captured frame;
- the table: wire values against `MouseButton`'s raw values, wire 5 as
  unrepresentable, the values 0, 6, 7, 127, 128 and 255 as out of contract, and
  every one of the 256 body bytes for both tokens, with the count of emitted and
  dropped frames;
- release safety: a press and its release are emitted or dropped together for every
  value; a release without a press is emitted; the held button spans a pointer move
  and a keepalive in the fixture stream;
- invalid input: a body of 0, 2, 3, 4 and 9 bytes; the length is judged before the
  value; the client-to-server direction before the body; unknown, short,
  lower-case, foreign and whole-frame payloads;
- output shape and privacy: events are always `.mouseButton` (an exhaustive switch
  over `KVMEvent`); error and diagnostic reflection holds only enums and counts;
- fragmentation, coalescing and truncation: the whole server-to-client stream of
  the capture (284 frames, 3,849 bytes) through `BarrierFrameReassembler`,
  coalesced, one byte at a time, split in two at every position and truncated at
  every length, routed by token prefix; only complete frames reach the decoder and
  a partial frame cannot finish;
- statelessness: repeated and reversed passes, no pressed set, no latching;
- the source boundary: only `import KVMContracts`, no logging, nothing declared
  `public`, `open` or `package`.

## Limitations

- Wire 5 is dropped (see "Button 5").
- Pairing is by value, not by state. A server that sent `DMDN` 1 and then a `DMUP`
  with another value would leave the left button held until a `DMUP` 1 or the
  session's terminal-path cleanup; the contract's observed pairs carry equal
  values.
- The names of the wire values are the first-party encoder's (see "Button table").
- Golden bytes are hand-copied into the tests, as in earlier Barrier issues, and are
  cross-checked against the fixture file.
- The decoder trusts the caller to pass the direction the payload was read from and
  to route only `DMDN` and `DMUP` payloads to it. Anything else fails closed.
- The register's `consumingTests` for `BARRIER-EVID-0006` do not list this suite.
  Updating `evidence/registers/M1-023.json` is outside this issue's Exact Files and
  is a follow-up for the register owner.

## Rollback

Revert the M1-033 change: `BarrierMouseButtonDecoder.swift`,
`BarrierMouseButtonDecoderTests.swift`, this document and `evidence/issues/M1-033/`.
The decoder owns no runtime resource, persisted data or migration, and no
production code consumes it yet.
