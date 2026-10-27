# M2-005 macOS Keyboard Capture Adapter

## Outcome

`MacPlatform` now has `MacKeyboardCapture.map(_:)`, mapping one physical
keyboard `CGEvent` from the server event tap to a `KVMEvent.key` plus its
timestamp (`MacCapturedInput`). Declarations are `package`; `CGKeyCode` never
leaves `MacPlatform`.

## Mapping

- Key table: the exact inverse of the M1-044 `MacKeyCodeMapper` US ANSI
  baseline (built from it at load time, so capture and injection cannot
  disagree), plus the SDK right-side modifier codes `kVK_RightShift` 0x3C,
  `kVK_RightControl` 0x3E, `kVK_RightOption` 0x3D and `kVK_RightCommand` 0x36
  mapped to the side-agnostic v1 modifiers.
- `keyDown` → `.down`, or `.repeatKey` when `keyboardEventAutorepeat` is set;
  `keyUp` → `.up`.
- `flagsChanged` for a catalog modifier → `.down` when its flag is set after
  the change, else `.up`. The fn key (`kVK_Function` 0x3F) uses
  `maskSecondaryFn` and maps to `unknown(0x3F)`. Other `flagsChanged` codes
  carry no phase and return `nil`.
- Codes without a v1 member become `unknown(rawCode)` (M1-042 adapter rule);
  the M1-042 reject-only rule still prevents any injector from using them.
- `ModifierState` is read from the event flags.

## Privacy

No text is produced or retained; no logging. Key identity exists only in the
returned event, which the owner routes without logging.

## Tests

`MacKeyboardCaptureTests` (6): phases including autorepeat, round trip of
every mapped catalog member through real `CGEvent`s, modifier flags,
`flagsChanged` both sides and fn, unknown codes, timestamps and non-keyboard
events.

## Known limitations

- Layout is positional (US ANSI baseline), per M1-042; no character
  translation.
- The M1-046 `ModifierState` ledger is not merged; modifiers come from event
  flags only (C-006 notes this is insufficient on its own).
- Real-hardware verification is pending.

## Rollback

Revert the three M2-005 files.
