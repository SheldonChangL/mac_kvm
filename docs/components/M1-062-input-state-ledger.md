# M1-062 Input State Ledger

## Outcome

`KVMCore` provides `InputStateLedger`, `HeldKey`, `LedgerDecision` and
`InputStateSnapshot` in `Packages/KVMCore/Sources/KVMCore/InputStateLedger.swift`,
with `package` access. For each key, button and clipboard event the client
session hands on, the ledger decides whether it is injected and records what
the injected presses hold, in press order. It embeds the M1-046
`ModifierStateLedger` as `modifiers` and remembers the last clipboard
transaction. It never injects, synthesizes or logs anything.

## API

| Member | Meaning |
|---|---|
| `init(maximumHeldKeys:maximumHeldButtons:)` | Empty ledger; defaults 64 keys and 8 buttons; a negative bound is taken as zero |
| `record(_ event: KVMEvent) -> LedgerDecision` | Records one event and returns the decision |
| `heldKeys: [HeldKey]` | Held keys in press order, each with the modifiers its press carried |
| `heldButtons: [MouseButton]` | Held buttons in press order |
| `modifiers: ModifierStateLedger` | The M1-046 ledger, fed only with injected key events |
| `snapshot() -> InputStateSnapshot` | Counts, overflow counts, modifier state and clipboard transaction |
| `reset()` | Forgets everything except the bounds; idempotent |

`LedgerDecision` is `inject`, `dropDuplicateDown`, `dropUnheldRepeat`,
`injectUnheldRelease` or `ignore`.

## Rules (first-party policy)

| Event | Ledger holds it | Ledger does not hold it |
|---|---|---|
| key or button `.down` | `dropDuplicateDown` | `inject`, held (or counted as overflow at the bound) |
| key `.repeatKey` | `inject` | `dropUnheldRepeat` |
| key or button `.up` | `inject`, freed | `injectUnheldRelease`, not recorded |
| clipboard | `inject`, transaction ID remembered | same |
| move, scroll, enter, leave | `ignore` | `ignore` |

- A duplicate press is dropped whatever its modifiers: the decoder reports a
  second `DKDN` for a held button as `.down` with the held identity
  (M1-041), and under the V1 repeat policy it is not re-injected.
- Caps Lock is an ordinary key: it arrives as a press and a release for each
  toggle (M1-043) and is held between them. Its lock bit is the modifier
  ledger's business. M1-050 groups Caps Lock with the modifiers when it orders
  a release plan (plan amendment h.6); that ordering is not the ledger's.
- Buttons follow the same rules, each button by its own identity.
- Injected key events, including unheld releases, are applied to `modifiers`
  in order; dropped ones are not.

## Bounds (fail-safe)

The bound is checked before anything is stored, so the ledger never grows
past 64 keys or 8 buttons. A press over the bound is still injected, because
dropping it would lose the user's input, but it is not held: it goes into a
separate overflow set with the same bound. An overflowed key or button keeps
rules 1-3: a second press is dropped as a duplicate, a repeat is injected (so
autorepeat keeps working), and its release is injected and removes it, which
clears the flag. Only a press beyond the overflow set's bound too is not
tracked at all; it is counted in `untrackedKeyCount` or
`untrackedButtonCount`, which stay set until `reset()`.

`snapshot().hasOverflowed` is true while the overflow sets are not empty or an
untracked count is set. A release-all built from `heldKeys` and `heldButtons`
cannot release overflowed presses, so the cleanup owner reports
`inputSafety.cleanupPartial` unless the injector sweep covers them.

The snapshot fields `overflowedKeyCount`, `overflowedButtonCount`,
`untrackedKeyCount`, `untrackedButtonCount` and `hasOverflowed` go beyond the
plan b.2 sketch on purpose: they are how the snapshot flags overflow, as the
plan's bound rule requires. They are counts only.

## Records decisions, not platform state (plan amendments h.1 and h.6)

The ledger records the routing decisions it made, not what the platform
holds. A release it freed may still sit in the injection queue when a
terminal path resets that queue, or be lost to a queue overflow. A terminal
path therefore stops and joins the drain worker, resets the queue, executes
the release plan built from `heldKeys` and `heldButtons`, and then runs the
injector's own sweep (`releaseAllHeld()`), whose record of what it pressed is
the authority for the platform. `reset()` follows.

## Privacy (Frozen Decision 8)

`InputStateSnapshot` carries counts, the modifier flags and an opaque
clipboard transaction UUID. It carries no key or button identity, no text and
no clipboard content, so it may be logged or reported. The ledger keeps no
clipboard text or hash.

## Concurrency and cleanup

The ledger is a `Sendable` value with no lock, clock, task or shared state.
The issue's "actor/serialization boundary" is met by single ownership: the
client coordinator owns it behind its one lock, as `ClipboardLoopGuard`
documents for its owner. `reset()` is the cleanup step and is idempotent.

## Validation coverage

`Packages/KVMCore/Tests/KVMCoreTests/InputStateLedgerTests.swift` (Swift
Testing) covers every decision row for keys and buttons, press order with the
press modifiers, Caps Lock as an ordinary key, the modifier ledger fed only by
injected events, ignored events, clipboard transaction tracking, both bounds
(default and small, the overflow set's pairing, untracked presses, and a negative bound behaving as zero), the snapshot's lack of identities (a
`Mirror` walker), `reset()` and its idempotence, and a seeded property test
over random sequences: `heldKeys` equals, in press order, the keys with an
injected down and no injected up since, and every decision matches an
independent model. Mutation evidence is in `evidence/issues/M1-062/mutations/`.

## Required command note

`Packages/KVMCore` has no manifest of its own; `swift test --package-path
Packages/KVMCore` resolves the enclosing root package and runs the same tests
as `swift test` at the root.

## Known limitations

- The ledger cannot see injector rejections (unknown keys, M1-042); its owner
  must not record events the injector rejects, or must free them.
- An overflowed press is not released by the ledger's plan; only the injector
  sweep can release it.
- No modifier or Caps Lock synthesis (Product Owner decision of 2026-11-02).

## Architecture and scope

New file in `KVMCore`, importing only `KVMContracts`. No public contract,
protocol message or platform code changes.

## Rollback

Revert the commit; nothing depends on the ledger yet (M1-063 will).
