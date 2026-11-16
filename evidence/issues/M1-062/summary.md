# M1-062 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/InputStateLedger.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/InputStateLedgerTests.swift`,
`docs/components/M1-062-input-state-ledger.md`, and this directory.

`InputStateLedger` decides, for each key, button and clipboard event the client session hands
on, whether it is injected, and records what the injected presses hold, in press order. It
embeds the M1-046 `ModifierStateLedger` as `modifiers` (fed only with injected key events) and
remembers the last clipboard transaction. Its `InputStateSnapshot` carries counts and flags only,
never a key or button identity or typed text. The ledger never injects, synthesizes or logs
anything. The consumer is the first-party Linux client (M4-SCOPE-001).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Actor or single owner? | Single ownership, no actor; the doc states the thread-safety claim. | Client master plan b.2 and the `ClipboardLoopGuard` precedent (the plan is the lead's planning document, not in the repository). |
| What does the ledger record? | Decisions, not platform state. A queue reset before release-all can drop a release the ledger already counted; the injector sweep covers it. | Amendments h.1 and h.6; M4-002, M1-063, M4-024 and M1-063-FOLLOWUP-001 carry the sweep. The doc says so. |
| What happens beyond the bounds (64 keys, 8 buttons by default)? | The press is still injected. The first overflowed presses go into a separate overflow set with the same bound, so a repeat is injected, a release is injected and removed, and a duplicate down is dropped. Presses beyond that are counted in `untrackedKeyCount` and `untrackedButtonCount` until `reset()`. | Plan b.2 asks for a counted, flagged overflow. The independent review found the first design lost pairing under overflow (Mediums 1 and 2); the overflow set is the fix at `44da49d`. |
| Extra API beyond the plan sketch | `init(maximumHeldKeys:maximumHeldButtons:)` (a negative bound is taken as zero) and the snapshot fields `overflowedKeyCount`, `overflowedButtonCount`, `untrackedKeyCount`, `untrackedButtonCount`, `hasOverflowed`. | The bound rule needs the snapshot to flag overflow; the fields are counts only, so no key identity is exposed (frozen decision 8). The doc records this as deliberate (review Lows 3 and 4). |
| Which tests does the issue's `swift test --package-path Packages/KVMCore` mean? | The root package, filtered to this suite, plus the full root suite. | `Packages/KVMCore` has no `Package.swift`; SwiftPM resolves the root package (244 tests). M1-046 and M1-050 record the same deviation. |
| No manual run and no `environment.json` | The issue is a KVMCore-only state machine; there is no hardware half. | Nothing in the ledger touches a platform; the Xvfb test of M4-024 and the owner E2E (#351) cover the whole input path. |

## RED

- Against a compiling stub of the API with no behavior, from the first run: `✘ Test run with 20
  tests in 1 suite failed after 0.300 seconds with 21607 issues.` (`commands.json`, first
  command, exit 1, recorded as an expected failure).
- Review round: the reviewer's Mediums 1 and 2 and Low 3 describe behavior the first suite did
  not pin. Two tests were added at `44da49d` (`untrackedButtonsAreCountedAndSticky` and
  `aNegativeBoundBehavesAsZero`), and the overflow assertions of the existing bound tests were
  extended. Mutants R-M1a, R-M1b, R-M2, R-M2b and R-L3 each fail them.

## GREEN

At `44da49d`:

- Focused: `✔ Test run with 22 tests in 1 suite passed after 0.025 seconds.`
- Full root package: `✔ Test run with 244 tests in 23 suites passed after 0.135 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 244 tests in 23 suites passed after 0.134
  seconds.`
- `swift test --package-path Packages/KVMCore`: `✔ Test run with 244 tests in 23 suites passed
  after 0.131 seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `make verify`: 24 of 24 gates
  passed.

## Mutation checks

20 mutants, each killed and restored byte for byte: `20 of 20 mutants killed; baseline passed;
restores clean`. The runner is `mutations/run_mutations.py`, which takes the repository path as
an argument; the results are `mutations/mutations.json`. Ids 1 to 6 are the issue's required
mutants and 7 to 13 are extras; the `R-` ids answer the independent review.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| 1 | a press of a held key is injected and not re-recorded | `aDuplicateDownOfAHeldKeyIsDropped`, `capsLockIsAnOrdinaryHeldKey`, `heldKeysMatchTheUnmatchedInjectedDowns` and more |
| 2 | every repeat is injected | `aRepeatOfAnUnheldKeyIsDropped`, `heldKeysMatchTheUnmatchedInjectedDowns`, `keysOverTheBoundAreInjectedCountedAndFlagged` and more |
| 3 | a release of an unheld key is recorded as a held key | `aReleaseOfAnUnheldKeyIsInjectedButNotRecorded`, `heldKeysMatchTheUnmatchedInjectedDowns` |
| 4 | a release of a held key is injected but the key stays held | `aReleaseOfAHeldKeyIsInjectedAndFreed`, `aRepeatOfAnUnheldKeyIsDropped`, `capsLockIsAnOrdinaryHeldKey` and more |
| 5 | a new press is inserted first instead of appended | `heldKeysKeepPressOrderAndTheModifiersAtThePress`, `heldKeysMatchTheUnmatchedInjectedDowns` |
| 6a | the key bound check always admits | `aNegativeBoundBehavesAsZero`, `aNegativeOrZeroBoundHoldsNothing`, `heldKeysMatchTheUnmatchedInjectedDowns` and more |
| 6b | an overflowed key press is not counted | `heldKeysMatchTheUnmatchedInjectedDowns`, `keysOverTheBoundAreInjectedCountedAndFlagged`, `resetForgetsEverything` |
| 6c | the button bound check always admits | `aNegativeBoundBehavesAsZero`, `aNegativeOrZeroBoundHoldsNothing`, `buttonsOverTheBoundAreInjectedCountedAndFlagged` and more |
| 7 | the snapshot gains a field holding the held keys | `theSnapshotCarriesNoKeyOrButtonIdentity` |
| 8 | `reset()` changes nothing | `heldKeysMatchTheUnmatchedInjectedDowns`, `resetForgetsEverything`, `untrackedButtonsAreCountedAndSticky` |
| 9 | a clipboard event is injected without remembering its transaction | `theClipboardTransactionIsTracked` |
| 10 | Caps Lock presses and releases are injected but not held | `capsLockIsAnOrdinaryHeldKey`, `heldKeysMatchTheUnmatchedInjectedDowns`, `theModifierLedgerFollowsInjectedKeyEvents` |
| R-M1a | the duplicate check ignores the overflow set | `heldKeysMatchTheUnmatchedInjectedDowns`, `keysOverTheBoundAreInjectedCountedAndFlagged` |
| R-M1b | the repeat check ignores the overflow set | `heldKeysMatchTheUnmatchedInjectedDowns`, `keysOverTheBoundAreInjectedCountedAndFlagged`, `smallBoundsAreEnforcedForKeys` |
| R-M2 | an overflowed key stays in the overflow set after its release | `heldKeysMatchTheUnmatchedInjectedDowns`, `keysOverTheBoundAreInjectedCountedAndFlagged`, `smallBoundsAreEnforcedForKeys` |
| R-M2b | an overflowed button stays in the overflow set after its release | `buttonsOverTheBoundAreInjectedCountedAndFlagged`, `heldKeysMatchTheUnmatchedInjectedDowns`, `untrackedButtonsAreCountedAndSticky` |
| R-L3 | the key bound is taken as given (no clamp) | `aNegativeBoundBehavesAsZero`, `aNegativeOrZeroBoundHoldsNothing` |
| 11 | a button's release frees the first held button | `aButtonReleaseFreesOnlyItsOwnButton`, `heldKeysMatchTheUnmatchedInjectedDowns` |
| 12 | every key event is applied to the modifier ledger | `theModifierLedgerFollowsInjectedKeyEvents` |
| 13 | a press of a held button is injected | `buttonsFollowTheSameRules`, `buttonsOverTheBoundAreInjectedCountedAndFlagged`, `heldKeysMatchTheUnmatchedInjectedDowns` and more |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Every Focus item (pressed keys, buttons, modifiers, clipboard transaction, serialization boundary, no typed text in the snapshot) has an implementation and tests | `aDownOfAnUnheldKeyIsInjectedAndHeld`, `heldKeysKeepPressOrderAndTheModifiersAtThePress`, `capsLockIsAnOrdinaryHeldKey`, `buttonsFollowTheSameRules`, `aButtonReleaseFreesOnlyItsOwnButton`, `theModifierLedgerFollowsInjectedKeyEvents`, `theClipboardTransactionIsTracked`, `theSnapshotCarriesNoKeyOrButtonIdentity`; the single-owner claim is stated in the doc |
| Happy path | `aDownOfAnUnheldKeyIsInjectedAndHeld`, `aRepeatOfAHeldKeyIsInjected`, `aReleaseOfAHeldKeyIsInjectedAndFreed`, `heldKeysMatchTheUnmatchedInjectedDowns` (seeds 1, 2, 3, 42 and 2026) |
| Boundary | `keysOverTheBoundAreInjectedCountedAndFlagged`, `buttonsOverTheBoundAreInjectedCountedAndFlagged`, `smallBoundsAreEnforcedForKeys`, `untrackedButtonsAreCountedAndSticky`, `aNegativeOrZeroBoundHoldsNothing`, `aNegativeBoundBehavesAsZero` |
| Invalid input and failure | `aDuplicateDownOfAHeldKeyIsDropped`, `aRepeatOfAnUnheldKeyIsDropped`, `aReleaseOfAnUnheldKeyIsInjectedButNotRecorded`, `eventsWithoutHeldStateAreIgnored` |
| Error, cancel, cleanup and idempotency | `resetForgetsEverything`, which includes a second `reset()` |
| Consistent with the frozen ADRs; no implicit API | package-only API; the extra init and snapshot fields are recorded as deliberate in the doc; decisions, not platform state (h.1, h.6) |
| Checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 244 root tests with warnings as errors, `make verify` 24 of 24. The SwiftPM "unhandled files" warning predates this change (`Tests/SystemTests`). `xcodebuild` was not run: the change is KVMCore-only. |
| No typed text, payload or secret in logs | the ledger never logs; `theSnapshotCarriesNoKeyOrButtonIdentity` pins that the snapshot holds counts only |

## Independent review

- After the PR, a fresh-context Opus reviewer started by the lead (`independent-review.md`) judged
  it mergeable after fixes: no Critical or High finding, 2 Medium, 2 Low, reviewed at `6ff5368`.
  Both Mediums (an overflowed key's repeat dropped, and `hasOverflowed` stuck until `reset()`)
  are fixed at `44da49d` with the overflow set, new tests and mutants R-M1a, R-M1b, R-M2, R-M2b;
  the Lows are resolved in the doc and by test `aNegativeBoundBehavesAsZero` with mutant R-L3.
- The reviewer did not verify RED against the committed tests, the scope limit to the Exact Files,
  or a per-criterion pass or fail; the lead's finishing commit adds this file and the mapping above.

## Merge

Pending owner approval.

## Known limitations

- The ledger cannot see injector rejections (unknown keys, M1-042); its owner must not record
  events the injector rejects, or must free them.
- An overflowed press beyond the overflow set is only counted; the ledger's plan cannot release
  it, and the cleanup owner reports `inputSafety.cleanupPartial` unless the injector sweep
  (amendment h.1) covers it. `hasOverflowed` stays set for those presses until `reset()`.
- No modifier or Caps Lock synthesis (Product Owner decision of 2026-11-02).
- `xcodebuild` was not run: the change is KVMCore-only.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable test report is in `tests/`.
