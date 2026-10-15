# M1-031 Barrier Control Messages

## Outcome

`BarrierCompatibility` decodes the Barrier control frames frozen by
`docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md`
(`BARRIER-EVID-0005`) into platform-neutral, module-internal control outcomes.
`BarrierControlDecoder` validates exact body lengths, DINF screen bounds and
CINN enter coordinates against the current screen, keeps keepalive/no-op frames
out of the control-event type, skips the known excluded side-effect frames with
a content-free diagnostic, and fails closed on everything else with a sticky,
typed `BarrierControlMessageError`.

## Frozen inputs

| Source | What M1-031 uses |
|---|---|
| `docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md` | Token-only frames, DSOP zero body, DINF 14-byte layout, CINN 10-byte layout, directions, coordinate rule, excluded-token rule, non-claims |
| `Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/sanitized.json` | Golden frame bytes, observed directions, omitted excluded-token counts |
| M1-022 `BarrierFrameReassembler` | Complete payloads; fragmentation, coalescing, truncation and the pre-buffer length limit |

The ADR is accepted for M1-031 only. Nothing here is consumed by, or unblocks,
M1-032, M1-033, M1-034 or M1-041.

### Exact frozen bytes

| Direction | Token | Frame bytes |
|---|---|---|
| server-to-client | `QINF` | `00 00 00 04 51 49 4e 46` |
| server-to-client | `CIAK` | `00 00 00 04 43 49 41 4b` |
| server-to-client | `CROP` | `00 00 00 04 43 52 4f 50` |
| server-to-client | `DSOP` | `00 00 00 08 44 53 4f 50 00 00 00 00` |
| both | `CALV` | `00 00 00 04 43 41 4c 56` |
| client-to-server | `CNOP` | `00 00 00 04 43 4e 4f 50` |
| server-to-client | `CINN` | `00 00 00 0e 43 49 4e 4e 03 04 02 52 00 00 00 01 20 00` |
| server-to-client | `COUT` | `00 00 00 04 43 4f 55 54` |
| client-to-server | `DINF` | `00 00 00 12 44 49 4e 46 f8 80 00 00 0e 40 04 5d 00 00 03 04 02 52` |

`goldenFramesEqualTheBarrierEvid0005FixtureBytesExactly` reads the fixture,
base64-decodes every consumable frame and compares it byte-for-byte with the
hand-copied constants above.

## API and event model

All declarations are module-internal; no public API or contract is added.

- `BarrierControlDecoder` (`Sendable` value type):
  - `init(maximumPayloadLength:) throws(BarrierControlMessageError)`;
  - `decode(payload:direction:) throws(BarrierControlMessageError) -> BarrierControlOutcome`;
  - `state` (read-only `State`), `maximumPayloadLength`,
    `minimumMaximumPayloadLength` (18).
- `BarrierControlDirection`: `serverToClient`, `clientToServer`. Required on every
  call.
- `BarrierControlToken`: the twelve recognized ASCII tokens (`bytes`,
  `observedDirections`).
- `BarrierControlOutcome`:
  - `.event(BarrierControlEvent)` — `screenInfoRequested` (QINF),
    `setup(.ciak | .crop | .dsopZero)`, `screenInfo(BarrierScreenInfo)` (DINF),
    `enter(BarrierEnter)` (CINN), `leave` (COUT);
  - `.keepalive(BarrierKeepalive)` — `keepalive(direction)` (CALV) or `noOp`
    (CNOP);
  - `.skipped(BarrierExcludedFrameDiagnostic)` — DCLP, DKDN, DKUP.
- `BarrierScreenInfo`: `originX`/`originY` (`Int16`), `width`/`height`
  (`UInt16`, `1...0x7fff`), `cursorX`/`cursorY` (`UInt16`, `0...0x7fff`).
- `BarrierEnter`: `x`/`y` (`UInt16`, `0...0x7fff`), opaque
  `BarrierEnterSequence(rawValue: UInt32)` and opaque
  `BarrierEnterModifierMask(rawValue: UInt16)`. Neither is `Comparable`, and no
  bit or ordering meaning is assigned.

`BarrierControlEvent` has no keepalive, no-op or excluded case, so a consumer
that forwards control events cannot forward keepalives
(`controlEventTypeHasNoKeepaliveOrExcludedCase` is an exhaustive switch that
stops compiling if one is added). The outputs are protocol-adapter outputs, not
input events and not `KVMEvent`; mapping `enter`/`leave` into the Core event
language belongs to a later Barrier session adapter issue.

The caller owns the transport and the reassembler and passes every complete
payload of both directions, including the client's own outbound DINF, so the
decoder sees the screen that enter coordinates are validated against.

## Validation

Each payload is checked in this order; the first failure is thrown and latched:

1. payload length `<= maximumPayloadLength` (`oversizePayload(limit:)`);
2. a recognized 4-byte token, case-sensitive (`unknownToken(payloadByteCount:)`);
3. the direction the token was observed in (`unexpectedDirection(token:direction:)`);
4. exact body length (`invalidBodyLength(token:bodyByteCount:)`): 0 for
   QINF/CIAK/CROP/CALV/CNOP/COUT, 4 for DSOP, 14 for DINF, 10 for CINN;
5. field rules:
   - DSOP: all four bytes zero, else `unsupportedSetupOption`;
   - DINF: reserved field zero (`nonZeroReservedField`); width and height raw
     `0x0001...0x7fff` (`invalidScreenSize`); cursor raw `0x0000...0x7fff`
     (`coordinateOutOfRange(token: .dinf)`); cursor inside the DINF's own
     rectangle (`coordinateOutsideScreen(token: .dinf)`);
   - CINN: coordinates raw `0x0000...0x7fff`
     (`coordinateOutOfRange(token: .cinn)`);
6. session state (below), then for CINN containment in the current screen
   (`coordinateOutsideScreen(token: .cinn)`).

The rectangle is `[origin, origin + size)` on each axis: the first and last
cells are inside, `origin + size` is outside. Edges are computed in `Int` from
`Int16`/`UInt16` values, so no edge can overflow; tests cover
`origin = 0x7fff, size = 0x7fff`, `origin = -32768`, and negative origins with
a non-negative cursor. Width/height signedness beyond "positive non-zero raw
value up to `0x7fff`" is not claimed.

## Session state

`State`: `setup(BarrierScreenInfo?)`, `active(BarrierScreenInfo)`,
`inactive(BarrierScreenInfo)`, `failed(BarrierControlMessageError)`; the
decoder starts in `setup(nil)`.

| Token | `setup` | `active` | `inactive` |
|---|---|---|---|
| QINF | event | fail | event |
| CIAK, CROP, DSOP | event | fail | fail |
| DINF | sets/replaces screen | fail | replaces screen |
| CINN | needs a screen → `active`; without one `enterWithoutScreenInfo` | fail | → `active` |
| COUT | fail | → `inactive` | fail |
| CALV, CNOP, excluded | no change | no change | no change |

"fail" is `unexpectedInState(token:)`. These are the minimal deterministic
rules the frozen contract needs, not a claimed Barrier ordering:

- enter is validated against a current, valid DINF rectangle, so CINN fails
  closed without one;
- the ADR accepts DSOP "during setup", so setup frames are accepted only before
  the first enter;
- screen geometry changes only while the client screen is not active, so the
  enter point can never be outside the current screen;
- repeated enter (CINN while active) and leave without enter are not evidenced
  and fail closed. Enter after leave uses the same frame contract and is
  accepted; no relation between sequence values is checked.

A rejected DINF fails the decoder, so no partial or stale geometry survives.
Failures are terminal and sticky: `.failed` holds only the error (no geometry),
and every later payload rethrows the first error. The reset path is to discard
the decoder and create a new one per session
(`freshDecodersAreIndependentAndRunsAreDeterministic`).

The decoder owns no I/O, timer, task, lock or other resource, so there is
nothing to cancel or clean up; cancellation tests do not apply. State
reset/idempotency is covered instead: sticky failure, keepalive and excluded
frames leaving state unchanged in every live state, and deterministic repeated
runs.

## Excluded tokens

DCLP, DKDN and DKUP, observed only server-to-client, are recognized by token
only. One complete payload, already bounded and reassembled by M1-022, is
skipped in any live state and reported as
`BarrierExcludedFrameDiagnostic(token:direction:payloadByteCount:reason:)` with
reason `excludedSideEffectNotConsumable`. The body is never decoded, copied or
retained, and no event is synthesized. The same tokens client-to-server fail
closed with `unexpectedDirection`.

The bounded-frame limit is the caller-supplied `maximumPayloadLength`, at least
18 (DINF). It is a product safety bound, not an observed Barrier limit. The
caller configures `BarrierFrameReassembler` with the same value, which rejects
an oversize prefix before buffering any body byte; the decoder re-checks the
limit before reading the token. An excluded frame above the limit therefore
fails closed. Every other token, including tokens a later ADR may freeze such
as DMMV, fails closed as `unknownToken`.

## Diagnostics and privacy

- The decoder performs no logging, printing or diagnostics output and imports
  no module (`productionSourceImportsNothingAndNeverNamesKVMCoreTypes`).
- Errors and the excluded-frame diagnostic carry only allowlisted metadata:
  token, direction, byte counts, limit and a fixed reason. No case holds payload
  bytes, body bytes, strings or screen geometry; the tests reject any
  fixed-width integer (the shape of a wire field) in their reflected values
  (`errorsAndStatesForFailuresCarryOnlyAllowlistedMetadata`,
  `knownExcludedFramesAreSkippedWithAContentFreeDiagnostic`).
- DINF/CINN geometry appears only in successful outcomes and live state, where
  the adapter needs it. The ADR classifies it as low-sensitivity capture
  geometry, not identity; the decoder never logs it.
- Tests use the fixture's frames and a synthetic excluded body
  (`a5 5a c3 3c 96 69`); no real excluded-frame body, typed text, clipboard
  bytes, address or credential appears in tests or evidence.

## Architecture boundary

- Barrier tokens and types stay in `BarrierCompatibility`; nothing is added to
  `KVMContracts`, `KVMCore` or `NativeProtocol`, and `KVMEvent` is unchanged.
- The production file imports nothing: no OS framework, networking, KVM Core or
  Native Protocol module.
- No transport, socket, TLS, timer or trust logic. Production TLS defaults are
  unchanged.
- M1-026 `BarrierMessageRegistry` is not used: its registration is fallible and
  it reports unknown payloads as a non-error outcome, while M1-031 has a closed
  token set with a fail-closed unknown policy. A direct lookup over the closed
  enum avoids an unreachable registration-failure path.

## Non-claims

- No DCLP, DKDN, DKUP, mouse, button, wheel, keyboard, clipboard, TLS, Windows
  or full interoperability behavior.
- No general DSOP option semantics, CINN modifier-mask bit meanings, CINN
  sequence semantics, DINF reserved-field meaning, or general coordinate or size
  signedness.
- No complete control-message ordering, keepalive interval, timeout or reply
  behavior; the decoder does not send CALV/CNOP or DINF.
- No DINF writer; composing the client's DINF reply is out of scope.
- No `KVMProtocolSession` conformance and no mapping to `KVMEvent`,
  `CoreError` or `DisconnectReason`.
- No Barrier/Deskflow source, header, generated constant or decompiled output
  was consulted; only the frozen ADR and sanitized fixture are used.

## Tests

`BarrierControlMessagesTests` (34 Swift Testing tests):

- golden: fixture bytes equal the hand-copied frames; token bytes; golden DINF
  and CINN decode to the observed values and re-serialize to the golden frames;
- happy path: the observed sequence through every allowed token and direction;
  enter after leave against a replaced screen; opaque sequence/mask extremes;
- boundaries: sizes `1`, `0x7ffe`, `0x7fff`; first/last cells inside, one past
  outside; extreme origins without overflow; payload limit inclusive; limit 18;
- invalid input: wrong body lengths for every token; non-zero DSOP and reserved
  values; zero/high-bit sizes; high-bit coordinates; wrong directions; unknown
  and short tokens;
- state: enter without screen; repeated enter; leave without enter; setup
  frames after enter; geometry while active; sticky failure; keepalive/excluded
  neutrality; fresh-decoder reset and determinism;
- fragmentation/coalescing/truncation: the server stream (with synthetic
  excluded frames) coalesced, one byte at a time and split at every boundary;
  the client stream one byte at a time; truncation at every length yields only
  complete frames; an oversize excluded prefix is rejected before buffering;
- keepalive isolation and privacy: keepalives are never control events; error
  and diagnostic reflection holds no bytes, strings, fixed-width integers or
  geometry, over an exhaustive list of error cases; flipping any one bit of the
  golden DINF or CINN payload never yields the golden value (flips in the
  opaque sequence/mask decode to a different opaque value; all others fail
  closed or change a decoded field).

## Limitations

- Fail-closed state rules may reject valid Barrier traffic that was not
  observed (for example screen changes or setup frames while active, repeated
  enter, a late DSOP). Widening them needs new evidence.
- Golden bytes are copied by hand into the tests, as in earlier Barrier issues,
  and are cross-checked against the fixture file.
- The decoder trusts the caller to pass the client's own DINF and the correct
  direction; it cannot verify transport direction itself.

## Rollback

Revert the M1-031 change: `BarrierControlMessages.swift`,
`BarrierControlMessagesTests.swift`, this document and `evidence/issues/M1-031/`.
The decoder owns no runtime resource, persisted data or migration, and no
production code consumes it yet.
