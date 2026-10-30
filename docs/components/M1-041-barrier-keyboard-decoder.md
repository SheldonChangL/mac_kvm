# M1-041 Barrier Keyboard Decoder

## Outcome

`BarrierCompatibility` decodes the Barrier `DKDN`, `DKUP` and `DKRP` frames
frozen by `docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`
into module-internal `BarrierKeyEvent` values. The consumer is the first-party
Linux client that speaks the Barrier wire to the first-party Mac server
(`docs/adr/M4-SCOPE-001-linux-client-first.md`), through its client session
(M1-029-FOLLOWUP-001) and the key mapper (M1-043).

`BarrierKeyboardDecoder` pairs every release and repeat with its press by the
opaque button field, so a release carries its press's identifier even when the
frame's own identifier differs, and a held button keeps its first press's
identity until it is released. It never drops a release, ignores mask bits
outside the five frozen ones, treats any repeat count as one repeat, passes
every identifier through unchanged, and fails closed with a sticky, typed
`BarrierKeyboardDecoderError` that leaves the held keys readable for the
session's cleanup. A stuck key on the client is the failure this design guards
against (Frozen Decision 7: fail safe).

## Frozen inputs

| Source | What M1-041 uses |
|---|---|
| ADR "Keys" | `DKDN`/`DKUP` body of 6 bytes (identifier, mask, button), `DKRP` body of 8 bytes (identifier, mask, count, button), all big-endian u16, server-to-client only; the button as an opaque pairing token; the five mask bits; a modifier's own mask rule; the Caps Lock toggles |
| ADR "Decoder policy (first-party, not a capture claim)" | any `DKRP` count is one repeat; an identifier outside the frozen set and the shifted-identifier convention is not injected, but its button is recorded; other mask bits are ignored; no lock state and no synthesized modifier presses; no release is dropped |
| ADR "Rejection semantics" | a wrong body length and any unlisted token fail closed; on that terminal path the client's cleanup (M1-063-FOLLOWUP-001) releases every pressed key |
| `BARRIER-EVID-0006-CLAIM-004`, `-005`, `-006` (`Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json`) | pairing by button, with a release identifier that differs from its press (0x0041/0x0061, 0x0021/0x0031, 0x005F/0x002D); key identifiers; mask bits, modifier masks and Caps Lock |
| `BARRIER-EVID-0008-CLAIM-001` (`Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json`) | the eleven punctuation keys, plain and shifted, in the four-frame shifted order |
| M1-022 `BarrierFrameReassembler` | complete payloads; fragmentation, coalescing and truncation |
| M2-027 `BarrierServerInputEncoder` | the first-party server's key frames, for the round trip |

The decoder must not depend on the observed four-frame shifted order (Shift
down, shifted key down, Shift up, plain key up). It pairs by button only.

M1-040 is a dependency only as evidence that a Barrier keyboard capture exists.
Its fixture (`Tests/Fixtures/Barrier/m1-040-linux-keyboard/`) is not in the
evidence register, and its metadata makes no key-code, message-code,
endianness or compatibility claim. M1-041 consumes and derives nothing from
it, as M1-042 did.

### Exact frozen bytes

A representative set from the server-input capture (observation sequence):

| seq | Frame bytes | Frame |
|---|---|---|
| 80 | `00 00 00 0a 44 4b 44 4e 00 61 00 00 00 26` | `DKDN` 0x0061, mask 0, button 38 |
| 82 | `00 00 00 0a 44 4b 55 50 00 61 00 00 00 26` | `DKUP` 0x0061, mask 0, button 38 |
| 404 | `00 00 00 0a 44 4b 44 4e ef e1 00 00 00 32` | `DKDN` 0xEFE1 (Shift), mask 0, button 50 |
| 406 | `00 00 00 0a 44 4b 44 4e 00 41 00 01 00 26` | `DKDN` 0x0041, mask Shift, button 38 |
| 408 | `00 00 00 0a 44 4b 55 50 ef e1 00 01 00 32` | `DKUP` 0xEFE1, mask Shift, button 50 |
| 410 | `00 00 00 0a 44 4b 55 50 00 61 00 00 00 26` | `DKUP` 0x0061, mask 0, button 38: releases seq 406 |
| 425 | `00 00 00 0a 44 4b 44 4e 00 5f 00 01 00 14` | `DKDN` 0x005F, mask Shift, button 20 |
| 515 | `00 00 00 0a 44 4b 44 4e ef e5 00 00 00 42` | `DKDN` 0xEFE5 (Caps Lock), mask 0: toggle-on |
| 517 | `00 00 00 0a 44 4b 55 50 ef e5 10 00 00 42` | `DKUP` 0xEFE5, mask Caps Lock: toggle-on |
| 523 | `00 00 00 0a 44 4b 44 4e ef e5 10 00 00 42` | `DKDN` 0xEFE5, mask Caps Lock: toggle-off |
| 525 | `00 00 00 0a 44 4b 55 50 ef e5 10 00 00 42` | `DKUP` 0xEFE5, mask Caps Lock: toggle-off |
| 532 | `00 00 00 0c 44 4b 52 50 00 61 00 00 00 01 00 26` | `DKRP` 0x0061, mask 0, count 1, button 38 |

`goldenKeyFramesReEncodeByteForByte` checks these hand-copied frames against
the fixture byte for byte, decodes them, re-encodes the key through
`BarrierServerInputEncoder` and compares whole frames.

## API and event model

All declarations are module-internal; no public API or contract is added. The
production file imports only `KVMContracts`, for `KeyPhase` and
`ModifierState`.

- `BarrierKeyboardDecoder` (`Sendable` value type):
  - `init()`;
  - `decode(payload:direction:) throws(BarrierKeyboardDecoderError) -> BarrierKeyEvent`:
    one complete payload (token and body) and the direction it was read from;
    exactly one event per frame;
  - `heldKeys: [BarrierHeldKey]`: the held presses in ascending button order,
    readable after a failure;
  - `failure: BarrierKeyboardDecoderError?` (read-only): the latched first
    error;
  - `static func modifiers(mask:) -> ModifierState` and the bit constants
    `shiftBit` 0x0001, `controlBit` 0x0002, `altBit` 0x0004, `superBit` 0x0010
    and `capsLockBit` 0x1000.
- `BarrierKeyEvent`: `phase` (`KeyPhase`: `down`, `up`, `repeatKey`),
  `identifier`, `modifiers` (`ModifierState`), `button` and `pairing`.
- `BarrierKeyPairing`: `press` (`DKDN` of a button that is not held), `paired`
  (a press, release or repeat of a held button, carrying the press's
  identifier) and `unpaired` (a release or repeat
  of a button that is not held, carrying its own identifier).
- `BarrierHeldKey`: `button` and `identifier`, the identity its release will
  carry.
- `BarrierKeyIdentifier(rawValue: UInt16)`: opaque; its meaning is assigned
  only by M1-043.
- `BarrierKeyButton(rawValue: UInt16)`: the opaque pairing token. It is
  `Comparable` by raw value only to order `heldKeys`; it is never interpreted
  or mapped.
- `BarrierKeyboardToken`: `dkdn`, `dkup`, `dkrp`, with `bytes`,
  `bodyByteCount` (6, 6, 8) and `phase`.
- `BarrierKeyboardDecoderError`: `unknownToken(payloadByteCount:)`,
  `unexpectedDirection(token:direction:)` and
  `invalidBodyLength(token:bodyByteCount:)`. `BarrierControlDirection` is
  reused unchanged from M1-031.

Unlike the pointer, button and wheel decoders (M1-032, M1-033, M1-034), this
decoder has no outcome enum and no drop case: no key frame is ever dropped, so
`decode` returns the event directly. The output is a protocol-adapter value,
not a `KVMEvent`; mapping the identifier to a key belongs to M1-043.

The decoder is a value type. A session keeps one instance and decodes in
place; a copy carries its own held set and its own failure latch.

## Validation

Each payload is checked in this order; the first failure is thrown and latched:

1. a latched failure is rethrown, and nothing else is checked;
2. a recognized 4-byte token, case-sensitive: `DKDN`, `DKUP` or `DKRP`
   (`unknownToken(payloadByteCount:)`, also for a payload shorter than a
   token);
3. the server-to-client direction (`unexpectedDirection(token:direction:)`);
4. the exact body length, 6 for `DKDN`/`DKUP` and 8 for `DKRP`
   (`invalidBodyLength(token:bodyByteCount:)`).

No field value is rejected: every identifier, mask, count and button decodes.
The direction is checked before the body, so a malformed body cannot mask a
wrong direction.

## Pairing rules

| Frame | Button held? | Event | Held set |
|---|---|---|---|
| `DKDN` | no | `down`, own identifier, `press` | the button is held with this identifier |
| `DKDN` | yes | `down`, the press's identifier, `paired` | unchanged: the first identity stays for the whole press |
| `DKUP` | yes | `up`, the press's identifier, `paired` | the button is freed |
| `DKUP` | no | `up`, own identifier, `unpaired` | unchanged |
| `DKRP` | yes | `repeatKey`, the press's identifier, `paired` | unchanged |
| `DKRP` | no | `repeatKey`, own identifier, `unpaired` | unchanged |

Every event carries the modifier state of its own frame's mask and its own
button.

- Contract: a release pairs with its press by button, and its identifier may
  differ from the press's (`BARRIER-EVID-0006-CLAIM-004`): 0x0041 down then
  0x0061 up after Shift was released, and likewise 0x0021/0x0031 and
  0x005F/0x002D. Every release and repeat in both captures pairs.
- First-party policy, not a Barrier claim: a paired release carries the
  press's identifier. That is how this decoder represents the pairing, so that
  M1-043 maps a release to the same key as its press.
- First-party policy, not a Barrier claim (the ADR files it under "Decoder
  policy (first-party, not a capture claim)"): the `DKRP` count is never read;
  any count is one repeat. Only count 1 was captured.
- First-party policy, not a Barrier claim: an unpaired release or repeat is
  emitted with its own identifier. No release is dropped, and emitting it lets
  a key that this view lost be released on the injector side; what an unpaired
  release means is decided downstream by the pressed-input ledger
  (M1-063-FOLLOWUP-001). An unpaired repeat must never be injected; see the
  fail-safe requirement for consumers below.
- First-party fail-safe policy, not a Barrier claim: a second `DKDN` for a
  held button was never observed. While the button is held, the first press's
  identity stays for the whole press: the second `DKDN` is emitted as `down`
  with the held identifier, its own mask and the same button (`paired`), and
  the held entry is unchanged. Every emitted press is therefore matched by a
  release of the same identity. Replacing the identity instead could leave the
  first key pressed if M1-043 maps the two identifiers to different keys, which
  the contract's decoder policy rules out: "no unknown identifier, button, mask
  bit or count may cause a decoder to drop a key or button release" (Frozen
  Decision 7: fail-safe outweighs completeness). The cost is a duplicate
  `down` of a key that is already pressed.
- First-party policy, not a Barrier claim: a paired repeat carries the press's
  identity. All 14 captured repeats carry the press identifier, so no
  observation distinguishes this from using the repeat's own.

## Modifier mask

- The five frozen bits map to `ModifierState`: 0x0001 `shift`, 0x0002
  `control`, 0x0004 `option` (Alt), 0x0010 `command` (Super) and 0x1000
  `capsLock`. `option` covers Alt and `command` covers Super, as in the M1-042
  catalog; the first-party encoder uses the same bits.
- Every other bit is ignored, and the frame still decodes.
- Each event reports its own frame's mask. A modifier's own `DKDN` carries the
  mask before it took effect and its `DKUP` the mask including it; the decoder
  passes both through unchanged.
- No lock state is kept. Caps Lock is only what each frame's mask says: the
  captured toggle-on is `DKDN` 0x0000 then `DKUP` 0x1000, and the toggle-off
  carries 0x1000 on both frames. Toggles whose masks differ, such as the
  first-party server's toggle that the ADR contrasts with the captured
  toggle-off, therefore change only the `capsLock` flag reported for their own
  frames; nothing is derived from them.
- No modifier event is synthesized from a mask. A frame whose mask carries
  Shift creates no Shift press and holds no Shift button.

## Unknown identifiers

Every identifier is recorded and emitted unchanged, inside the frozen set or
not; the decoder holds no identifier table. A press of an identifier outside
the frozen set holds its button like any other, so its release pairs and frees
it cleanly. "Not injected" happens downstream: M1-043 maps an identifier
without a mapping to `unknown(rawCode)`, and a platform mapper rejects
`unknown` with a typed unsupported-key result (M1-042 unknown-key policy).

## Fail-safe

- The first fail-closed error is latched in `failure`. Every later `decode`
  rethrows it without reading the payload or changing the held set, so a
  session that keeps feeding frames after an error cannot inject more input.
- `heldKeys` survives the failure. On the terminal path the client session ends
  with a typed protocol-violation error, and its cleanup releases everything
  pressed. The authoritative pressed-input ledger is
  M1-063-FOLLOWUP-001's in `KVMCore`, fed by the events; `heldKeys` lets the
  session count what was held at failure, or synthesize releases from it if
  M1-029-FOLLOWUP-001 chooses a second line of defense.
- There is no `releaseAll()`: a synthesized release would need a mask the wire
  never showed.
- The reset path is to discard the decoder and create a new one per session.
  The decoder owns no I/O, timer, task, lock or other resource, so there is
  nothing to cancel.

## Interface for M1-043

`BarrierKeyIdentifier`, `BarrierKeyEvent` and `BarrierKeyboardDecoder` are the
stable interface M1-043 builds on. M1-043 (`BarrierVirtualKeyMapper`) maps
`identifier` to a `VirtualKey`, and the session composes
`KVMEvent.key(key:phase:modifiers:)` from that key and the event's `phase` and
`modifiers`. Because the release carries the press's identifier, a release
maps to the same `VirtualKey` as its press.

The client session must route `DKDN`, `DKUP` and `DKRP` to this decoder
instead of `BarrierControlDecoder`, and never to both. M1-031's
`BarrierControlToken` lists `DKDN` and `DKUP` as excluded tokens that it skips,
and does not know `DKRP` at all, so a `DKRP` passed to it fails that decoder
closed and would end the session on the first key repeat.

## Fail-safe requirement for consumers

**MUST:** the session must not inject an unpaired repeat
(`pairing == .unpaired`); a paired repeat may be injected only as a repeat of
the held key, never as a new press.

An unpaired repeat is neither a held press nor a release, and it is absent from
`heldKeys`. If the client session or the X11 injector (M4-024) turned it into a
key press, that key would stick with no release and no cleanup entry. The
contract's decoder policy says that "no unknown identifier, button, mask bit or
count may cause a decoder to drop a key or button release", and Frozen Decision
7 puts fail-safe above completeness, so the decoder's view must never create a
press that nothing releases. A paired repeat belongs to a press that `heldKeys`
lists, so its release and the terminal cleanup cover it, as long as it repeats
the held key and does not start a new press.

An unpaired release is different: it may be injected, because releasing a key
that is not pressed leaves nothing stuck.

## Diagnostics and privacy

- The decoder performs no logging, printing or diagnostics output, and imports
  only `KVMContracts` (`productionSourceImportsOnlyKVMContracts`).
- Errors carry only allowlisted metadata: a token, a direction and `Int` byte
  counts. No case holds an identifier, mask, count, button or body byte; the
  tests reject any fixed-width integer in their reflected values
  (`errorsCarryOnlyAllowlistedMetadata`).
- `BarrierKeyEvent` and `heldKeys` carry wire values (identifier, button,
  modifiers). They are outputs, not diagnostics, and are never logged: a
  sequence of identifiers is typed text (Frozen Decision 8, M1-011). A session
  counts events; it does not log them.
- Neither the decoder nor its outputs redact their default `description` or
  reflection: interpolating a decoder, an event or `heldKeys` into a log would
  write key identifiers. The rule above is the protection; on a failure path
  the session logs the error and the count of held keys only.
- Tests use the capture fixtures' frames and synthetic frames only; no typed
  text, clipboard content, address or credential appears in tests or evidence.

## Architecture boundary

- Barrier tokens and key types stay in `BarrierCompatibility`; nothing is added
  to `KVMContracts`, `KVMCore` or `NativeProtocol`, and `KVMEvent` is
  unchanged.
- The decoder produces no `KVMEvent` and holds no identifier-to-key table.
- No transport, socket, TLS, timer or trust logic.
- M1-026 `BarrierMessageRegistry` is not used, for M1-031's reason: the token
  set is closed and fails closed.

## Non-claims

- No meaning for any identifier, and no non-US layout.
- No `DKRP` count semantics beyond "one repeat"; counts other than 1 were never
  captured.
- No mask bit other than the five, and no lock-state semantics.
- No Barrier claim for the first-party policies above: unpaired emission, a
  held button keeping its first identity, and the repeat taking the press
  identity.
- No key injection, pressed-input ledger, client session, `KVMEvent` mapping or
  TLS behavior.
- No Barrier/Deskflow source, header, generated constant or decompiled output
  was consulted; only the frozen ADR and the sanitized fixtures are used.

## Tests

`BarrierKeyboardDecoderTests` (21 Swift Testing tests):

- golden and fixtures: the token bytes, body lengths and phases; every key
  frame of both captures in order through one decoder each, compared with an
  independent pairing walk (232 and 66 frames, nothing left held); the shifted
  sequences and the eleven punctuation sequences with literal identifiers; the
  14 captured repeats; Caps Lock toggles; golden frames decoded with each
  event's identifier and button checked against the frame's bytes, then
  re-encoded byte for byte;
- round trip: every key the first-party encoder accepts (81) in all 32
  modifier states, down then repeat then up through one decoder, plus a release
  under the other Shift state; Caps Lock as two frames per toggle with no
  repeat; one stable button per key and no two keys sharing a button;
- pairing and policy: unpaired releases and repeats, pairing by button only
  (never by an equal identifier on another button), a second release, a
  second press of a held button keeping the first identity until its release,
  identifiers outside the frozen set with
  extreme buttons, masks and counts, every one of the 65,536 button values held
  at once and each released with another identifier, repeat counts 0 to
  0xFFFF, the five mask bits in all 32 combinations with every other bit
  ignored, modifier keys and right-hand modifiers, no lock state and no
  synthesized modifiers;
- invalid input: wrong body lengths for every token, the wrong direction
  (checked before the body), unknown, lowercase, foreign and short tokens;
- failure and cleanup: the sticky failure for each error kind with the held set
  intact, rethrown for every later payload including the held keys' releases
  and unknown or empty payloads; `heldKeys` order, value independence, a fresh
  decoder after a failure, determinism;
- fragmentation, coalescing and truncation: the capture's server stream through
  `BarrierFrameReassembler` coalesced, one byte at a time and split at every
  byte; truncated at every length, only complete frames decode and `heldKeys`
  is exactly what those frames left pressed;
- privacy: error reflection holds no bytes, strings or fixed-width integers,
  over an exhaustive list of error cases; the production file imports only
  `KVMContracts` and never names `KVMEvent` or a logger.

## Limitations

- A second press of a held button and an unpaired release or repeat were never
  observed; their handling is first-party policy pinned by tests.
- The decoder trusts the caller to pass the correct direction; it cannot verify
  the transport direction itself.
- The held set holds at most one entry per button value, so at most 65,536
  entries. `heldKeys` is sorted on every read.
- The evidence register's `consumingTests` for `BARRIER-EVID-0006` and `0008`
  do not list these tests; updating `evidence/registers/M1-023.json` is outside
  this issue's files (M1-031 precedent). Follow-up for the register owner.

## Rollback

Revert the M1-041 change: `BarrierKeyboardDecoder.swift`,
`BarrierKeyboardDecoderTests.swift`, this document and
`evidence/issues/M1-041/`. The decoder owns no runtime resource, persisted data
or migration, and no production code consumes it yet; M1-043 and the client
session build on it later.
