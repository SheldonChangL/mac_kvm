# M1-046 Modifier State Ledger

## Outcome

`KVMCore` provides `ModifierStateLedger` and `ModifierDiscrepancy` in
`Packages/KVMCore/Sources/KVMCore/ModifierStateLedger.swift`, with `package`
access. The ledger records which of Shift, Control, Option and Command the
client's injected modifier keys hold, plus the Caps Lock bit of the last key
event, and reconciles every key event against that state (contract C-006:
"explicit state for Shift/Control/Option/Command/CapsLock; never rely on one
event's flags alone").

The consumer is the first-party Linux client on the Barrier wire
(`docs/adr/M4-SCOPE-001-linux-client-first.md`). M1-062's `InputStateLedger`
owns one. The release plan on a terminal path (M1-050, run by M1-063) comes
from M1-062's held-key record, which lists every held key, modifier keys
included, in press order; this ledger's `state` must not drive releases
(section "Consulted, not authoritative, for injection"). The API is the master
plan's design for M1-046 (section b.1), plus the `ModifierDiscrepancy`
initializer that the plan's sketch left implicit.

## API

```swift
package struct ModifierDiscrepancy: Equatable, Sendable {
  package let implied: ModifierState  // reported held or on, not held by the ledger
  package let stale: ModifierState    // held or on in the ledger, reported released or off
  package init(implied: ModifierState = ModifierState(), stale: ModifierState = ModifierState())
  package var isEmpty: Bool { get }
}

package struct ModifierStateLedger: Equatable, Sendable {
  package private(set) var state: ModifierState  // held modifiers, plus the last key event's lock bit
  package init()
  package mutating func apply(_ event: KVMEvent) -> ModifierDiscrepancy
  package func reconcile(with reported: ModifierState) -> ModifierDiscrepancy
  package mutating func clear()
}
```

Nothing is public and `KVMContracts` is unchanged. The production file imports
only `KVMContracts` and contains no Barrier token or type (Frozen Decision 4).
Besides `state`, the ledger keeps one private flag: whether the last key event
was a Caps Lock event (rule 3).

## Wire facts the ledger relies on

| Fact | Source |
|---|---|
| Every key frame carries a mask with five frozen bits: Shift, Control, Alt, Super and Caps Lock. | M1-PROTOCOL-003 "Keys" (lines 130-131) |
| A modifier's own `DKDN` carries the mask before the modifier took effect, and its `DKUP` the mask including it. | same, `BARRIER-EVID-0006-CLAIM-006` |
| Caps Lock toggle-on: `DKDN` 0x0000, then `DKUP` 0x1000. Toggle-off: 0x1000 on both frames. | same |
| The client session passes each frame's mask through unchanged as `KVMEvent.key(...).modifiers`. | M1-041 "Modifier mask"; M1-043 "The `modifiers` field, for consumers" |
| Left- and right-hand modifiers map to one side-agnostic catalog member; Alt is `option`, Super is `command`. | M1-042 catalog; M1-043 mapping table |
| The first-party server's capture maps a modifier key's `flagsChanged` to a press while its flag is set after the change, and to a release otherwise. | `MacKeyboardCapture.swift` (M2-005), line 16 |
| The first-party encoder flips the own bit of the state after the event on a modifier's own press and release, and sends each Caps Lock toggle as a press and a release with the captured masks. | `BarrierServerInputEncoder.key` (line 75); pinned by M1-043's round-trip table |
| Before it leaves, the first-party server releases every key it holds on the client, newest press first, each with the modifiers recorded at its press. | `ServerCoordinator.swift`, `releaseRemoteInput` and `noteRemote` (lines 374-378, 476-485) |

Inference, not verified on hardware: macOS keeps the device-independent flag of
a modifier set while either side is held, so with the capture rule above,
releasing one side while the other is held arrives as a press.

## Rules

Every rule below is first-party policy over those facts, not a Barrier claim.

1. **A held modifier follows its key, not the mask.** A press of Shift,
   Control, Option or Command sets its flag, a release clears it, and a repeat
   changes nothing. On the key's own press and release the wire's own bit is
   the opposite of the state after the event, so taking the state from the
   mask would leave Shift held after every Shift tap (M1-043's warning).
2. **Left and right collapse.** One flag stands for both sides: any press sets
   it and any release clears it. A server that reports a release per side
   therefore releases the modifier at the first release, which favours release
   over stuck input and never leaves a modifier held after its last source
   release (M1-042 "Costs and limitations"). By the inference above, the
   first-party server reports a press while either side is still held, so it
   does not release early.
3. **The lock bit is taken from the key events, never derived from Caps Lock
   presses.** Whether a Caps Lock press toggles the lock differs between
   platforms and is left open by M1-043, and Caps Lock is never a held
   modifier. `state.capsLock` is the lock bit of the last key event:
   - A Caps Lock event's own frames, and the first other key event after them,
     may carry a bit that the toggle changed: the toggle-on press lacks the bit
     and its release has it, and the toggle-off pair carries it on both frames
     while the lock goes off, so only the next key event shows it off. Their
     bit is taken as it is.
   - Any other change of the bit was not seen being made, such as a lock that
     was already on at the server when the pointer entered. It is reported once,
     as `implied` when the bit turns on and `stale` when it turns off, and then
     taken.
4. **Reconciliation reports; it never corrects.** Each key event's modifiers
   are compared with the ledger:
   - `implied`: what the event reports held, or the lock it reports on, that
     the ledger does not hold: a modifier held at enter, a modifier the ledger
     released at the first of two side releases, or a lock turned on unseen.
   - `stale`: what the ledger holds, or the lock it has on, that the event
     reports released or off: a release that never arrived, or a lock turned off
     unseen.

   The four held modifiers are compared with the ledger after the event. On a
   modifier key's own press or release, the key's own bit is first replaced by
   the state the key gives: with the sides collapsed the key cannot tell
   whether the other side is held, and when the capture reports a second press
   while one side is held, the first-party encoder sends its own bit clear (it
   flips the bit of the state after the event), while the wire rule, read
   literally, would carry it set. The other bits of a modifier's own frame are
   compared as reported. The lock bit is compared with the last key event's bit,
   except as rule 3 says. `reconcile(with:)` compares all five fields with
   `state` and changes nothing.
5. **Events other than key events change nothing and report nothing.** Leaving
   the screen and disconnecting are the owner's `clear()`, which also forgets a
   pending Caps Lock toggle.

| Caps Lock frames (toggle) | `capsLock` after the press | after the release | at the next key event |
|---|---|---|---|
| toggle-on: press 0, release 1 | off | on | that event's bit (on), not reported |
| toggle-off: press 1, release 1 | on | on | that event's bit (off), not reported |

### Lock bit: the design sketch and C-006

The design's sketch says that Caps Lock frames copy the bit and that other keys
"only reconcile". Copying only from Caps Lock frames would show the lock on
after every toggle-off, whose frames both carry the bit, until the next Caps
Lock press, and reconciling against that value would report every later key.
Rule 3 keeps the sketch's own definition of the field ("the lock bit last
seen"), still copies the bit of Caps Lock frames, and lets the other keys both
reconcile and refresh it. This refinement is recorded for the reviewer.

C-006 asks for explicit state that never relies on one event's flags alone. The
held modifiers never come from flags. The lock has no key identity to follow:
the lead's design forbids deriving it from Caps Lock presses, so it comes from
the frames, and every change that no Caps Lock event explains is reported
rather than silently taken. This reading of C-006 for the lock is recorded for
the lead and the Product Owner to confirm.

## Consulted, not authoritative, for injection

The ledger never injects, synthesizes, drops or changes an event. It answers
which modifiers the injected modifier keys hold and reports where a server's
mask disagrees. `state` must not drive releases: its lock bit is a report, not
a held key, and releasing from it could toggle the client's lock.

It is only as accurate as the events applied. Its owner (M1-062) applies exactly
the key events that the injector performs, in order, so a key the injector
rejects is never applied (M1-042 unknown-key policy, rule 5). A release that is
applied and then dropped before the injector performs it would leave a
modifier held on the client that neither this ledger nor M1-062's held-key
record lists. The master plan's terminal path resets the injection queue before
the release-all (sections a.3 and b.4), and `CaptureQueue.reset()` discards
every queued event, releases included; the owners must close that gap (Follow-up).

## Modifiers held at enter (Product Owner decision of 2026-11-02)

A modifier already held on the server when the pointer enters this screen
produces no key event; only the masks of later keys show it (M1-043 open
question). V1 does not synthesize it: the ledger reports it as `implied` on
every key event that carries it and never adopts it, so nothing is pressed on
the client that a release-all would then have to undo. The Caps Lock state at
enter is not synchronized either; the client's own lock state applies (master
plan e.3 and risk f.6). A lock already on at the server is reported once, at
the first key event (rule 3). The visible effect, such as an unshifted letter,
is recorded by the owner E2E (M4-036-FOLLOWUP-001).

## Fail-safe (Frozen Decision 7)

- A stale modifier stays held in the ledger until its own release or `clear()`,
  so the release-all on a terminal path still releases it. On the client it
  stays held until then too: V1 only reports it, and whether a stale report
  should release it at once is the coordinator's decision (Follow-up). The
  first-party server sends a release for every key it held, on every path it
  controls.
- An implied modifier is never adopted, so no press is synthesized and the
  release-all never has to release something nobody pressed.
- With collapsed sides, a modifier is never held after its last release.
- `clear()` forgets every modifier, the lock bit and a pending toggle, and is
  idempotent; the owner calls it on disconnect, after the releases.

## Privacy

The ledger never logs or prints and holds only the five `ModifierState` flags
and one flag for a pending toggle: no key identity, sequence or timing. A
discrepancy carries flags only. Frozen Decision 8 is unaffected;
`productionSourceImportsOnlyKVMContractsAndNeverLogs` checks the imports and the
absence of logging.

## Determinism, concurrency and cleanup

The ledger is a `Sendable` value with no lock, clock, task, queue or shared
state, so cancellation does not apply. Its single owner serializes access, as
for `ClipboardLoopGuard` (M1-054). Results depend only on the events applied
and are the same on every run, on concurrent owners and on a cancelled task.
`clear()` is the cleanup, and it is idempotent.

## Validation coverage

`ModifierStateLedgerTests` (20 Swift Testing tests):

- each modifier from press to release, alone and all four together; the
  inverted own bit gives an empty discrepancy, an own bit that says otherwise
  is ignored, and the other bits of a modifier's own frame are reconciled;
- both sides collapse, and the first-party pattern (three presses, one
  release) leaves nothing held;
- Caps Lock through both toggle patterns without a report, a later unexplained
  change reported once, and a lock bit that changes without any Caps Lock event
  reported once on every kind of key event;
- `reconcile(with:)` against all 16 held states, both lock bits and all 32
  reported states, field by field, and `apply` on the same pairs;
- a modifier held at enter is implied and never adopted; a missed release is
  stale and stays held until its own release; repeats change nothing;
- every other catalog key and every non-key event change no held modifier;
  `clear()`, its idempotency and the pending toggle it forgets; `isEmpty` field
  by field;
- a round trip through the first-party server chain as M1-043's round-trip
  table states it: a scripted capture session (Shift and Control combinations,
  Option and Command, both Shift keys, Caps Lock on and off, repeats, a
  function key) keeps the ledger on the server's state with no discrepancy;
- the server's releases before it leaves, newest press first with the
  modifiers of each press: nothing stays held, nothing is reported when no
  modifier was released in between, and a modifier released in between is
  reported as implied by the release that still carries it;
- 200 seeded random sequences of 64 events against the rules stated over the
  whole history; value semantics; concurrent and cancelled owners; `Sendable`
  checked at compile time; the production file's imports and the absence of
  logging, traps, shared mutable state and a `default` branch in the key
  classification.

`evidence/issues/M1-046/mutations/` holds the mutation runner and its output.
The mutants cover the six checks the lead's brief requires: own-bit logic
inverted (1a in the state, 1b in the comparison), Caps Lock taken from presses
(2a), `clear()` as a no-op (3), sides not collapsed (4), implied not reported
(5) and stale not reported (6). The extra mutants are: the flag taken from the
frame's own bit (1c), Caps Lock held like a modifier (2b), the lock copied only
from Caps Lock frames (2c), a stale modifier corrected from the mask (7), an
implied one adopted (8), a repeat treated as a press (9), `isEmpty` ignoring
stale (10), crossed fields (11), a `default` branch (12), non-key events
clearing the ledger (13), a toggle's lock change reported (14), an unexplained
lock change not reported (15), the toggle exemption kept too long (16) and
`clear()` keeping a pending toggle (17).

## Required command note

The issue lists `swift test --package-path Packages/KVMCore`. `Packages/KVMCore`
has no `Package.swift` of its own, so SwiftPM resolves the enclosing root
package, `MacKVM`, and the command runs the whole root package, `KVMCoreTests`
included; `commands.json` records it and the resolution. As M1-060 did, the
focused and full runs name the root package directly:
`swift test --filter ModifierStateLedger` and `swift test`. The other Required
Commands (`xcodebuild`, `python3 Tools/Backlog/validate_package.py`,
`make architecture-check`) run unchanged.

## Known limitations

- After a toggle-off, `state.capsLock` stays on until the next key event,
  because both of the toggle's frames carry the bit (rule 3). The ledger does
  not know the client's own lock state, and nothing synchronizes it in V1.
- On a modifier's own press or release the own bit is not compared, so a
  modifier held at enter is not reported again at its release. It is reported
  as implied on every key typed while it is held, which is when it matters.
- No test runs the real encoder, decoder, mapper and ledger together. The
  round trip here uses M1-043's round-trip table, because `KVMCoreTests`
  depends only on `KVMContracts` and `KVMCore`, and adding a dependency means
  editing the root `Package.swift`, a shared file owned by M4-020. The place for
  such a test is `Tests/Integration`, whose target imports both
  `BarrierCompatibility` and `KVMCore` (Follow-up). The scripted session sends
  no unknown key, because the encoder sends nothing for a key outside its table.
- Side-agnostic modifiers: with a server that reports a release per side, the
  first release releases the modifier while the other side is still held
  (M1-042 cost).
- No synthesis at enter (V1): a modifier held on the server at enter has no
  effect on the client until it is pressed again.
- When the first-party server leaves the screen, it releases each key with the
  modifiers recorded at that key's press. If a modifier was released after that
  press, the key's release reports it as implied. The report changes nothing,
  and the releases leave nothing held (`serverReleasesBeforeLeavingLeaveNothingHeld`).

## Architecture and scope

Only the three Exact Files and `evidence/issues/M1-046/` are added. No
transport, session, injection, logging or trust logic, and no change to
`KVMContracts`, the catalog or any other component.

## Rollback

Revert `ModifierStateLedger.swift`, `ModifierStateLedgerTests.swift`, this
document and `evidence/issues/M1-046/`. Nothing calls the ledger yet, and it
owns no runtime resource or persisted state.

## Follow-up

- Before M1-062, M1-063 and M1-063-FOLLOWUP-001 are built: the terminal path's
  queue reset discards queued releases that the held-key records already
  count as done, which can leave a key held on the client (section "Consulted,
  not authoritative, for injection"). Options include recording a release only
  when the injector performs it, keeping queued releases through the reset, or
  adding them to the release plan. The lead decides; it is a master plan issue,
  not an M1-046 change.
- M1-062 owns a `ModifierStateLedger`, applies the key events the injector
  performs and clears it with the rest of its state.
- M1-063-FOLLOWUP-001 decides what a stale report triggers: counting only (V1
  as built here), or releasing the stale modifier at once.
- A test in `Tests/Integration` runs the real encoder, decoder, mapper and
  ledger, for example in M1-029-FOLLOWUP-001's loopback integration test.
- M1-046-FOLLOWUP-001 only if the Product Owner later wants modifiers held at
  enter synthesized (master plan e.3).
- The issue's Required Commands need no amendment: its
  `--package-path Packages/KVMCore` resolves to the root package.
