# M1-043 Barrier Key Identifier to VirtualKey Mapper

## Outcome

`BarrierCompatibility` provides `BarrierVirtualKeyMapper`, a table-driven, total
function from the Barrier key identifiers frozen by
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md` to C-005
`VirtualKey` values, and the composition of the client session's `KVMEvent.key`
from a decoded `BarrierKeyEvent` (M1-041). The consumer is the first-party Linux
client that speaks the Barrier wire to the first-party Mac server
(`docs/adr/M4-SCOPE-001-linux-client-first.md`), through its client session
(M1-029-FOLLOWUP-001).

The mapper covers **C-005 VirtualKey catalog version 2**, as frozen by
[`M1-042-virtual-key-catalog.md`](../adr/M1-042-virtual-key-catalog.md), so
`BarrierVirtualKeyMapper.catalogVersion` is `2`. The client must type exactly
what the Mac server sent, so the table is checked against the wire in both
directions: against the M2-022 captures in the capture driver's order, and as
the inverse of the first-party `BarrierServerInputEncoder`.

The files live in `BarrierCompatibility`, not `KVMCore`: M4-SCOPE-001
(superseded clause 8) moved the Exact Files, because Frozen Decision 4 keeps
Barrier key identifiers out of `KVMCore`, which also settles the M1-042 open
question about the placement.

## Interface

```swift
enum BarrierVirtualKeyMapper {
  static let catalogVersion = 2
  static let contractIdentifierCount = 134
  static func virtualKey(for identifier: BarrierKeyIdentifier) -> VirtualKey
  static func isInContract(_ identifier: BarrierKeyIdentifier) -> Bool
  static func kvmEvent(for event: BarrierKeyEvent) -> KVMEvent
}
```

All declarations are module-internal; no public API or contract is added. The
production file imports only `KVMContracts`.

- `virtualKey(for:)` returns the catalog member of a contract identifier, and
  `unknown(rawCode)` for Insert, keypad Enter and every identifier outside the
  contract. It never throws.
- `isInContract(_:)` is true for exactly the 134 contract identifiers: the 100
  frozen ones, including Insert and keypad Enter, and the 34 convention ones.
- `kvmEvent(for:)` returns
  `.key(key: virtualKey(for: event.identifier), phase: event.phase, modifiers: event.modifiers)`.
  The phase and the modifiers pass through unchanged. The button and the pairing
  stay in the protocol adapter: the button is the server's opaque pairing token
  and is never mapped to a key.

The client session routes `DKDN`, `DKUP` and `DKRP` to `BarrierKeyboardDecoder`
and composes each event with `kvmEvent(for:)`. Because a paired release or
repeat carries its press's identifier (M1-041's first-party pairing policy), it
maps to the same key as its press. An unpaired release whose identifier is the
plain or shifted form of its press's also maps to the same key position,
because both forms share one member.

## Source of the table

| Source | What M1-043 uses |
|---|---|
| `BARRIER-EVID-0006-CLAIM-005` (`Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json`) | the identifiers observed for this Linux server with the Xvfb default US keymap; the capture driver's key order, pinned by the contract test's `DRIVER_ORDER`, fixes which identifier belongs to which key |
| `BARRIER-EVID-0008-CLAIM-001` (`Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json`) | the eleven punctuation keys, plain and shifted |
| ADR "Keys", first-party convention | the 34 shifted identifiers the first-party server sends beyond the capture: 0x0042–0x005A (B–Z) and the nine US shifted digits |
| ADR "Non-claims" | no identifier outside the listed set and no non-US layout |
| M1-042 catalog v1 and v2 | positional letters and digits, side-agnostic modifiers (`option` covers Alt, `command` covers Super), punctuation members, no member for keypad Enter or Insert, `unknown(rawCode)` zero-extended for every key without a member |

The identifiers and their keys come only from these sources. No Barrier or
Deskflow source, header or generated constant was consulted. The M1-040 fixture
is not in the evidence register and makes no key-code claim, so nothing is
derived from it, as in M1-041 and M1-042.

### Punctuation: the change M1-042 anticipated

M1-042 "Catalog v2" says that the Barrier client-role inbound mapping (M1-043)
still turns punctuation identifiers into `unknown`, and that this "needs its own
evidence-backed change". M1-PROTOCOL-003 is that change: it freezes the eleven
punctuation identifiers, plain and shifted, from `BARRIER-EVID-0008-CLAIM-001`,
and it names M1-043 as a consumer. The lead decided the M1-043 design's open
question d.2 this way, so this mapper maps them to the `punctuation` members. No
`KVMContracts` change is needed; `PunctuationKey` is already in catalog v2.
M1-042's "Not covered" sentence describes the state before M1-043; amending it
is a follow-up outside this issue's files.

## Mapping table

| Identifiers | Source | Key | `VirtualKey` |
|---|---|---|---|
| 0x0061–0x007A | CLAIM-005 | a–z | `letter(0)` … `letter(25)` |
| 0x0041 | CLAIM-005 | A, with Shift held and with Caps Lock on | `letter(0)` |
| 0x0042–0x005A | ADR convention | B–Z with Shift or Caps Lock | `letter(1)` … `letter(25)` |
| 0x0030–0x0039 | CLAIM-005 | 0–9 (main row) | `digit(0)` … `digit(9)` |
| 0x0021 | CLAIM-005 | exclam, with Shift held | `digit(1)` |
| 0x0029, 0x0040, 0x0023, 0x0024, 0x0025, 0x005E, 0x0026, 0x002A, 0x0028 | ADR convention | `)` `@` `#` `$` `%` `^` `&` `*` `(` | `digit(0)`, `digit(2)` … `digit(9)` |
| 0x0020 | CLAIM-005 | space | `space` |
| 0x002D, 0x005F | CLAIM-005, 0008-CLAIM-001 | minus, plain and shifted | `punctuation(.minus)` |
| 0x003D, 0x002B | CLAIM-005 (plain), 0008-CLAIM-001 | equal | `punctuation(.equal)` |
| 0x005B, 0x007B | CLAIM-005 (plain), 0008-CLAIM-001 | bracketleft | `punctuation(.leftBracket)` |
| 0x005D, 0x007D | CLAIM-005 (plain), 0008-CLAIM-001 | bracketright | `punctuation(.rightBracket)` |
| 0x005C, 0x007C | CLAIM-005 (plain), 0008-CLAIM-001 | backslash | `punctuation(.backslash)` |
| 0x003B, 0x003A | CLAIM-005 (plain), 0008-CLAIM-001 | semicolon | `punctuation(.semicolon)` |
| 0x0027, 0x0022 | CLAIM-005 (plain), 0008-CLAIM-001 | apostrophe | `punctuation(.quote)` |
| 0x0060, 0x007E | CLAIM-005 (plain), 0008-CLAIM-001 | grave | `punctuation(.grave)` |
| 0x002C, 0x003C | CLAIM-005 (plain), 0008-CLAIM-001 | comma | `punctuation(.comma)` |
| 0x002E, 0x003E | CLAIM-005 (plain), 0008-CLAIM-001 | period | `punctuation(.period)` |
| 0x002F, 0x003F | CLAIM-005 (plain), 0008-CLAIM-001 | slash | `punctuation(.slash)` |
| 0xEF0D, 0xEF1B, 0xEF09, 0xEF08, 0xEFFF | CLAIM-005 | Return, Escape, Tab, BackSpace, Delete | `enter`, `escape`, `tab`, `backspace`, `delete` |
| 0xEF51, 0xEF52, 0xEF53, 0xEF54 | CLAIM-005 | Left, Up, Right, Down | `left`, `up`, `right`, `down` |
| 0xEF50, 0xEF57, 0xEF55, 0xEF56 | CLAIM-005 | Home, End, Page Up, Page Down | `home`, `end`, `pageUp`, `pageDown` |
| 0xEFBE–0xEFC9 | CLAIM-005 | F1–F12 | `function(1)` … `function(12)` |
| 0xE0AF, 0xE0AE, 0xE0AD | CLAIM-005 | volume up, volume down, mute | `volumeUp`, `volumeDown`, `mute` |
| 0xEFE1, 0xEFE2 | CLAIM-005 | Shift left/right | `shift` |
| 0xEFE3, 0xEFE4 | CLAIM-005 | Control left/right | `control` |
| 0xEFE9, 0xEFEA | CLAIM-005 | Alt left/right | `option` |
| 0xEFEB, 0xEFEC | CLAIM-005 | Super left/right | `command` |
| 0xEFE5 | CLAIM-005 | Caps Lock | `capsLock` |
| 0xEF63, 0xEF8D | CLAIM-005 | Insert, keypad Enter | `unknown(0xEF63)`, `unknown(0xEF8D)` |
| every other value | none | none | `unknown(rawCode)` |

That is 100 frozen identifiers (CLAIM-005 lists 90, including the plain
punctuation values and the underscore; 0008-CLAIM-001 adds the other ten shifted
punctuation values), 34 convention identifiers, 134 in all. The 132 that
map to a member reach exactly the 81 keys the first-party encoder accepts: two
identifiers for each letter, digit and punctuation key (plain and shifted) and
for each modifier (left and right), one for every other key.

The implementation is one private `[UInt16: VirtualKey]` table built once from
named lists: ranges for the letters, digits and function keys; the shifted
digits and the punctuation pairs in the encoder's order, each pair naming its
`PunctuationKey`; the other named keys; and the two frozen non-members. Every
hexadecimal literal sits in one of those lists, and there is no `switch`
(`productionSourceImportsOnlyKVMContracts` checks both).

## Unknown and invalid keys

- Every identifier without a member becomes `unknown(rawCode)`, the identifier
  zero-extended to `UInt32` (M1-042 adapter rules). It is neither dropped nor
  coerced into the nearest member: all 65,402 values outside the contract map to
  `unknown`, including 0x0000–0x001F (values that coincide with catalog payloads
  and ASCII control keys), 0x007F, and 0xEFBD and 0xEFCA (next to F1 and F12).
- Insert (0xEF63) and keypad Enter (0xEF8D) are frozen identifiers, so
  `isInContract` is true for them, but catalog v2 has no member for either. They
  map to `unknown` like any other key without a member.
- Identifiers are 16 bits wide, so M1-042's rejection of identifiers wider than
  32 bits cannot occur. The table never produces a `letter` above 25, a `digit`
  above 9 or a `function` outside 1–12.
- The mapper does not reject anything itself. "Not injected" happens downstream:
  the client session routes an `unknown` key event like any other, and the
  platform mapper rejects `unknown` with a typed unsupported-key result and does
  not record it as pressed (M1-042 unknown-key policy, rules 2, 3 and 5).

## Shifted identifiers and modifiers

- The catalog is positional: `letter`, `digit` and `punctuation` name a key
  position, not a character. The plain and shifted identifiers of one key
  therefore map to the same member: 0x0041 and 0x0061 to the A key, 0x0021 and
  0x0031 to the 1 key, 0x005F and 0x002D to the minus key. Shift and Caps Lock
  reach the client as their own key events, which the mapper maps like any other
  key, and `kvmEvent(for:)` passes each frame's mask through as `modifiers`; the
  mapper changes neither.
- Left- and right-hand modifiers map to the side-agnostic member, as M1-042
  requires. The mapping does not depend on which of 0xEFE1 and 0xEFE2 is the
  left one: the M1-PROTOCOL-003 review left that identity unpinned by order, and
  both map to `shift`.
- The mapper derives nothing from the modifier state and synthesizes no
  modifier event, as the ADR's decoder policy requires.

### The `modifiers` field, for consumers

`modifiers` is the frame's own wire mask (the five frozen bits), not the
modifier state after the event:

- on any key other than a modifier, it is the modifier state while the key is
  pressed, repeated or released;
- on a modifier key's own press it is the state before the press, and on its
  release the state including it (`BARRIER-EVID-0006-CLAIM-006`);
- on Caps Lock, each frame carries the lock bit as the wire shows it: on
  toggle-on `DKDN` without the bit and `DKUP` with it, on toggle-off the bit on
  both.

On the Mac capture side, `modifiers` is the state after the event, so the two
sides disagree on a modifier key's own events. First-party guidance, not a
Barrier claim: a consumer that tracks modifier or lock state (M1-046, the
pressed-input ledger of M1-063-FOLLOWUP-001, the Linux injector M4-024) must
derive it from the modifier keys' own press and release events, as the ADR's
decoder policy does for the decoder, and must never rebuild it from
`modifiers`. Rebuilding it would leave Shift held after a Shift tap, and Caps
Lock on after a toggle-off.

### Round trip with the first-party server

Every key the first-party `BarrierServerInputEncoder` accepts (81 keys), in all
32 modifier states, is encoded, decoded by `BarrierKeyboardDecoder` and composed
by `kvmEvent(for:)`. The 32 states include the four that choose the identifier
the encoder sends: none, Shift, Caps Lock, and Shift with Caps Lock. Every event
that comes back carries the original key. The phase and the modifiers are the
original's in every case except these:

| Key | Phase sent | After decode and map | Why |
|---|---|---|---|
| the other 76 keys | down, repeat, up | the same key, phase and modifiers | exact |
| `shift`, `control`, `option`, `command` | repeat | the same key, phase and modifiers | the repeat carries the mask unchanged |
| `shift`, `control`, `option`, `command` | down, up | the same key and phase; the modifiers with the key's own bit inverted | see below |
| `capsLock` | down (turned on) | `down` without `capsLock`, then `up` with `capsLock` | see below |
| `capsLock` | up (turned off) | `down`, then `up`, both with `capsLock` | see below |
| `capsLock` | repeat | nothing | the encoder sends no frame |

- A modifier key's own bit: the encoder takes the modifier state after the
  event, as macOS capture reports it. On the wire a modifier's own `DKDN`
  carries the mask before the modifier took effect and its `DKUP` the mask
  including it (`BARRIER-EVID-0006-CLAIM-006`), and the encoder follows that
  rule. The decoder and the mapper pass the wire mask through unchanged and never
  re-derive modifier state, so the key's own bit comes back inverted on its own
  press and release. "The `modifiers` field, for consumers" above says what a
  consumer must do about it.
- Caps Lock: macOS reports Caps Lock once per toggle, `down` when it turns on
  and `up` when it turns off, so the encoder sends each toggle as a whole press
  (`DKDN`, then `DKUP`) and nothing for a repeat. The client therefore receives a
  press and a release for each toggle, as on the wire, and their `capsLock` flag
  follows the encoder's toggle masks, not the input state. How the Linux
  injector replays them is M4-024's.

A release sent under another Shift state, such as A down and a up, also returns
the original key. `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`
pins every row of this table, and fails if any other key differs from the
original.

## US-only limit

The table is the capture's "Xvfb default US keymap" (CLAIM-005): it reads every
identifier as a character on the US ANSI layout and maps it to the US key
position that types it. A Barrier server with another layout sends the
characters of its own layout. A character that also exists on the US layout
lands on the US position of that character, which can be another physical key:
a German server sends 0x007A, z, from the key in the US Y position, and it maps
to the US Z key. A character that does not exist on the US layout maps to
`unknown`. The first-party server sends the US ANSI character of each key
position whatever the Mac's layout, so it is unaffected. The ADR makes no non-US
claim, and layouts belong to M1-045.

## Purity, cancellation and cleanup

`BarrierVirtualKeyMapper` is a caseless enum. It has no instances and no stored
state other than the immutable table, and owns no task, timer, queue, socket or
ledger. Each call derives its result only from its argument and the table.

Cancellation and cleanup are therefore not applicable: there is no
asynchronous work and nothing that outlives a call. Tests show that results are
deterministic across repetition, that an unknown identifier does not affect
later calls, that concurrent callers agree, and that a cancelled task gets the
same answer.

## Diagnostics and privacy

- The mapper performs no logging, printing or diagnostics output, and imports
  only `KVMContracts` (`productionSourceImportsOnlyKVMContracts`).
- `unknown(rawCode)` carries the raw identifier by catalog design (M1-042
  unknown-key policy, rule 1). The composed `KVMEvent` is an output, not a
  diagnostic: a sequence of keys is typed text and is never logged (Frozen
  Decision 8, M1-011). Diagnostics may count unknown or rejected keys; they never
  record the raw value, the key or the sequence.
- Tests use the capture fixtures and synthetic identifiers only; no typed text,
  clipboard content, address or credential appears in tests or evidence.

## Validation coverage

`BarrierVirtualKeyMapperTests` (14 Swift Testing tests):

- table shape: catalog version 2; exactly 134 contract identifiers, equal to the
  frozen set rebuilt as the encoder test does plus the convention list, with the
  100 frozen ones equal to the identifiers the two captures carry; 132 members
  and two `unknown` rows;
- captures in order: all 232 key frames of the server-input capture and all 66
  of the punctuation capture, each frame's own identifier and the decoder's
  composed event, against the key the capture driver pressed (`DRIVER_ORDER`,
  then the combinations, modifiers, Caps Lock and the held key; the punctuation
  driver's plain and shifted presses), with releases and repeats paired by
  button independently of the decoder;
- convention and shifted identifiers: the 34 convention identifiers by produced
  character, and all 47 plain and shifted pairs of the US ANSI layout mapping to
  one key;
- round trips: every identifier the encoder emits for its 81 keys, in all 32
  states and three phases, maps back to the key (the encoder reaches all 34
  convention identifiers); the composed round trip described above;
- composition: `kvmEvent(for:)` keeps the phase and all 32 modifier states, and
  ignores the button and the pairing;
- unknown policy and no raw-value shortcuts: Insert, keypad Enter and all
  65,402 identifiers outside the contract map to `unknown` with the
  zero-extended value; identifiers equal to catalog payloads, the ASCII
  neighbours of the letter and digit ranges and the edges of the function-key
  page; each punctuation key is reached only from its own two identifiers;
  every value stays inside its catalog domain; and, in the source, every
  hexadecimal literal sits in a named list, with no `switch` and no
  `init(rawValue:)`;
- purity, determinism, concurrency and cancellation; the production file's
  imports, and no logging, trap or mutable shared state in it.

Mutation checks and the full gate run are recorded in
`evidence/issues/M1-043/commands.json` and `evidence/issues/M1-043/mutations/`
(`run_mutations.py` and its output `mutations.json`).

The issue's Required Commands run `swift test --package-path Packages/KVMCore`.
`Packages/KVMCore` has no `Package.swift` and M4-SCOPE-001 moved the Exact Files,
so, as the lead decided on the design's open question d.3, the tests run with
`swift test --package-path Packages/BarrierCompatibility`, as M1-060 recorded its
own deviation. The other Required Commands (`xcodebuild`,
`python3 Tools/Backlog/validate_package.py`, `make architecture-check`) run
unchanged.

## Known limitations

- Insert and keypad Enter have no catalog v2 member. They reach the platform
  mapper as `unknown` and are rejected, so typing them on the Mac server does
  nothing on the client until a later catalog version adds members (M1-042 open
  question).
- US ANSI only: a Barrier server with another layout can land on another
  physical key ("US-only limit").
- The mapper maps positions, not characters: the case of a typed letter, and
  whether a digit or punctuation key types its shifted character, come from the
  Shift and Caps Lock state on the client when the key is injected. Lock state
  is not synchronized: the ADR's decoder policy derives no lock state from the
  mask, and the `CINN` mask bits are not frozen. If Caps Lock differs between
  the Mac and the client when the pointer enters, letters come out in the
  opposite case.
- `modifiers` is the wire mask, which differs from the Mac capture side on a
  modifier key's own events and on Caps Lock; consumers must track modifier and
  lock state from the modifier keys' own events ("The `modifiers` field, for
  consumers").
- Modifiers are side-agnostic. When both sides of one modifier are held, the
  first release on either side may release the injected modifier early (M1-042
  costs); this favours release over stuck input.
- Of the 34 convention identifiers, only Shift+B was validated against a real
  `barrierc` (M2-035). The round trip proves that the mapper inverts the
  first-party encoder; it is not a claim about what any Barrier server sends.
- A modifier key's own press and release, and Caps Lock, do not round-trip
  their modifier state and phase exactly, for the reasons above.
- The evidence register's `consumingTests` for `BARRIER-EVID-0006` and `0008`
  do not list these tests; updating `evidence/registers/M1-023.json` is outside
  this issue's files (M1-031 precedent).

## Architecture and scope

- Only the three Exact Files and `evidence/issues/M1-043/` are added. Barrier key
  identifiers and their table stay in `BarrierCompatibility`; nothing is added
  to `KVMContracts`, `KVMCore` or `NativeProtocol`, and `KVMEvent` and
  `VirtualKey` are unchanged.
- No transport, session, injection, pressed-input ledger, logging or trust
  logic. M1-026 `BarrierMessageRegistry` is not used.

## Rollback

Revert the M1-043 change: `BarrierVirtualKeyMapper.swift`,
`BarrierVirtualKeyMapperTests.swift`, this document and
`evidence/issues/M1-043/`. The mapper owns no runtime resource, persisted data or
migration, and no production code calls it yet.

## Follow-up

- A later catalog version (M1-042 open question) adding Insert, keypad and
  side-specific members must add rows to this table and its tests in the same
  change set.
- The register owner adds these tests to the `consumingTests` of
  `BARRIER-EVID-0006` and `0008`.
- M1-029-FOLLOWUP-001 composes `BarrierKeyboardDecoder` and `kvmEvent(for:)` in
  the client session.
- M1-046, M1-063-FOLLOWUP-001 and M4-024 track modifier and lock state from the
  modifier keys' own events, never from `modifiers`.
- Amend M1-042's "Catalog v2" "Not covered" sentence to record that
  M1-PROTOCOL-003 and M1-043 now map the punctuation identifiers; that ADR is
  outside this issue's files.
- The Product Owner may amend the issue's Required Commands from
  `Packages/KVMCore` to `Packages/BarrierCompatibility`, which is outside this
  issue's files.
