# M1-044 VirtualKey to macOS CGKeyCode Mapper (US Baseline)

## Outcome

`MacPlatform` provides `MacKeyCodeMapper`, a pure function from a C-005
`VirtualKey` to the macOS US ANSI baseline `CGKeyCode`. Every key without a
macOS code is rejected explicitly with a closed, typed reason.

The mapper covers **C-005 VirtualKey catalog v1** exactly as frozen by
[`M1-042-virtual-key-catalog.md`](../adr/M1-042-virtual-key-catalog.md).
`MacKeyCodeMapper.catalogVersion` is `1`.

No public or package contract is added. `MacKeyCodeMapper` and
`MacKeyCodeMappingFailure` are `internal`, so `CGKeyCode` never reaches the
`MacPlatform` package surface, `KVMEvent`, `KVMCore` or any wire schema. The
future keyboard injector lives in this module and consumes the result directly.

## Interface

```swift
enum MacKeyCodeMappingFailure: String, Error, CaseIterable, Codable, Hashable, Sendable {
  case unknownKey
  case payloadOutOfDomain
  case noMacOSBaseline
}

enum MacKeyCodeMapper {
  static let catalogVersion = 1
  static func keyCode(for key: VirtualKey) -> Result<CGKeyCode, MacKeyCodeMappingFailure>
}
```

The failure reasons carry no payload, so a rejection can be counted without
ever exposing the rejected raw code or payload value.

| Input | Result |
|---|---|
| Catalog v1 member with a macOS baseline (78 members) | `.success(code)` |
| `function(21...24)` | `.failure(.noMacOSBaseline)` |
| `letter` above `25`, `digit` above `9`, `function(0)` or `function` above `24` | `.failure(.payloadOutOfDomain)` |
| `unknown(rawCode)`, any value | `.failure(.unknownKey)` |

The switch over `VirtualKey` is exhaustive with no `default`, so a later
catalog member fails compilation until it is mapped or rejected (M1-042
unknown-key policy rule 6).

## Source of the table

Every code is transcribed from the `kVK_` constants in
`Carbon.framework/.../HIToolbox.framework/Headers/Events.h` of
`MacOSX26.2.sdk`. The header documents them as identifying physical keys, with
the `ANSI` constants "labeled according to the key position on an
ANSI-standard US keyboard". That matches the positional, layout-free meaning
M1-042 gives `letter` and `digit`, so the table maps positions, not characters.
`CGKeyCode` is `typedef uint16_t CGKeyCode` in `CGRemoteOperation.h`.

Production writes the values as hexadecimal literals and does not import
Carbon. The test file imports `Carbon.HIToolbox` and compares every mapped
value with the SDK constant it was taken from, so a transcription slip on
either side fails the suite.

| Catalog member | SDK constant |
|---|---|
| `letter(0...25)` | `kVK_ANSI_A` ... `kVK_ANSI_Z` |
| `digit(0...9)` | `kVK_ANSI_0` ... `kVK_ANSI_9` (main row) |
| `function(1...20)` | `kVK_F1` ... `kVK_F20` |
| `enter`, `escape`, `tab`, `space` | `kVK_Return`, `kVK_Escape`, `kVK_Tab`, `kVK_Space` |
| `backspace`, `delete` | `kVK_Delete`, `kVK_ForwardDelete` |
| `left`, `right`, `up`, `down` | `kVK_LeftArrow`, `kVK_RightArrow`, `kVK_UpArrow`, `kVK_DownArrow` |
| `home`, `end`, `pageUp`, `pageDown` | `kVK_Home`, `kVK_End`, `kVK_PageUp`, `kVK_PageDown` |
| `shift`, `control`, `option`, `command`, `capsLock` | `kVK_Shift`, `kVK_Control`, `kVK_Option`, `kVK_Command`, `kVK_CapsLock` |
| `volumeUp`, `volumeDown`, `mute` | `kVK_VolumeUp`, `kVK_VolumeDown`, `kVK_Mute` |

Catalog v1 modifiers are side-agnostic, so each maps to the left-side key,
which the SDK names without a side prefix. Right-side modifiers are never
produced.

### Catalog v1 gap: F21 to F24

M1-042 makes `function(1...24)` catalog members, but the SDK declares no
`kVK_F21` through `kVK_F24`. Inventing codes would be a guess about the
platform, so these four members are rejected as `noMacOSBaseline`, separately
from out-of-domain payloads.

## Unknown and invalid keys

- `unknown(rawCode)` is rejected for every raw value. The raw value is never
  reused as a `CGKeyCode`, including values that coincide with a real key code
  such as `0x24` (Return), per M1-042 unknown-key policy rule 3.
- Out-of-domain `letter`, `digit` and `function` payloads are rejected with
  the same typed result kind, per rule 4.
- A rejected key was never mapped, so the injector must not inject it and must
  not record it as pressed. No cleanup is owed for it (rule 5).

## Purity, cancellation and cleanup

`MacKeyCodeMapper` is a caseless enum. It has no instances and no stored state
and owns no task, timer, queue, event source, event tap or ledger. Each call
derives its result only from its argument and the immutable tables.

Cancellation and cleanup are therefore not applicable: there is no
asynchronous work and nothing that outlives a call. The equivalent obligation
is covered by tests showing that results are deterministic across repetition,
that a rejection does not latch or affect later calls, that concurrent callers
off the main thread agree, and that a cancelled task gets the same answer.

## Privacy and logging

The mapper emits no log and no diagnostic. A failure renders and encodes as
its case name only; a test confirms the rejected raw code appears in neither
the description nor the JSON encoding.

## Validation coverage

Automated tests in `MacKeyCodeMapperTests.swift` verify:

- representative happy-path keys against literal header values;
- all 26 letters, 10 digits, F1 to F20 and 22 payload-free members against the
  SDK constants;
- domain edges (`letter(25)`/`letter(26)`, `digit(9)`/`digit(10)`,
  `function(0)`, `function(1)`, `function(20)`, `function(25)`), every
  out-of-domain `UInt8` payload, and F21 to F24 as `noMacOSBaseline`;
- `unknown` across `0`, codes equal to real keys, the `UInt16` boundary and
  `UInt32.max`;
- that the 82 catalog v1 members yield 78 distinct codes and exactly the four
  F21 to F24 gaps, and never produce right-side modifiers, Fn, keypad, Help or
  ISO/JIS keys; and
- purity, determinism, concurrency and cancellation behavior as above.

## Known limitations

- Catalog v1 cannot express punctuation/OEM, keypad, Insert, Fn/Globe, media
  transport or side-specific modifiers; those reach this mapper as `unknown`
  and are rejected. M1 must not claim full typing support.
- The table is the US ANSI positional baseline. Layout and IME semantics
  belong to M1-045.
- The SDK declares `kVK_VolumeUp`, `kVK_VolumeDown` and `kVK_Mute`, and the
  mapper returns them. Whether posting a keyboard `CGEvent` with these codes
  changes system volume is injector behavior, not verified here.

## Architecture and scope boundaries

Only the three Exact Files and `evidence/issues/M1-044/` are added. No
`KVMContracts`, `KVMCore`, Barrier, Native protocol, UI, package manifest or
wire change is made. No event is created or posted.

## Rollback

Revert the M1-044 pull request. The mapper has no caller yet and stores
nothing, so no runtime state, permission or migration needs cleanup.

## Follow-up

- The keyboard injector Issue consumes `MacKeyCodeMapper` and decides how
  `MacKeyCodeMappingFailure` is reported as a `CoreError`.
- Catalog v2 (M1-042 open question) must add rows to this table and to its
  tests in the same change set.
