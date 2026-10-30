# M1-041 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierKeyboardDecoder.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierKeyboardDecoderTests.swift`,
`docs/components/M1-041-barrier-keyboard-decoder.md`, and this directory.

The decoder turns Barrier `DKDN`, `DKUP` and `DKRP` frames into `BarrierKeyEvent`s and pairs each
release and repeat with its press by the button field. It holds the pressed keys so the
terminal-path cleanup can release them. The contract is
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`. The consumer is the
first-party Linux client (`docs/adr/M4-SCOPE-001-linux-client-first.md`), although the issue sits
under "M1 - Mac Client MVP". The key mapper M1-043 stacks on this branch.

## RED

- Original implementation: the first 19 tests were run against a compiling stub with the design's
  API and no behavior: `✘ Test run with 19 tests in 1 suite failed after 0.018 seconds with 75 issues.`
  18 of the 19 failed; `productionSourceImportsOnlyKVMContracts` only checks imports.
- First-identity change (the lead's decision, below): the renamed test against the previous
  latest-press-wins code: `✘ Test run with 20 tests in 1 suite failed after 5.151 seconds with 6 issues.`
  Only `secondPressOnAHeldButtonKeepsTheFirstIdentity` failed.

## GREEN

At `e189692`:

- Focused: `✔ Test run with 21 tests in 1 suite passed after 5.156 seconds.`
- Full package: `✔ Test run with 268 tests in 9 suites passed after 5.345 seconds.`, also with
  `-Xswiftc -warnings-as-errors`.
- `make verify`: 24 of 24 gates passed.

## Lead decision: the first press identity is kept while a button is held

The design (c.13) let a second `DKDN` on a held button replace the held identity. If M1-043 maps the
two identifiers to different keys, the first key would then stay pressed until the terminal
cleanup. That breaks the contract's decoder policy: "no unknown identifier, button, mask bit or
count may cause a decoder to drop a key or button release" (Frozen Decision 7). The decoder now
keeps the first identity for the whole press lifetime. It emits a second `DKDN` as `.down` with the
held identity, the frame's own mask and the same button, and leaves the held entry unchanged.

## Mutation checks

14 mutants, each killed. The source was restored byte for byte after each (`git diff --exit-code`
0). The runner is `mutations/mutate.py`, which takes the repository path as an argument; its
output with the full failing-test lists is `mutations/mutations.json`.

| Id | Mutation | Killing test |
| --- | --- | --- |
| 1 | a release uses its own identifier | `releaseUsesThePressIdentityByButton` and 7 others |
| 2 | an unpaired release is dropped (`decode` throws) | `unpairedReleasesAndRepeatsAreEmittedWithTheirOwnIdentifier` and 4 others |
| 3a | bits 0x2000, 0x4000 and 0x8000 read as Caps Lock | `modifierMaskDecodesExactlyTheFiveFrozenBits` and 1 other |
| 3b | bit 0x0008 read as Alt | `modifierMaskDecodesExactlyTheFiveFrozenBits` and 1 other |
| 4 | a `DKRP` count N > 1 yields N repeats | `repeatsUseThePressIdentityAndKeepTheHeldSet` and 2 others |
| 5a | `heldKeys` cleared on failure | `failureIsStickyAndHeldKeysSurviveIt` and 1 other |
| 5b | the failure is not latched | `failureIsStickyAndHeldKeysSurviveIt` and 5 others |
| 6 | a second `DKDN` replaces the held identity | `secondPressOnAHeldButtonKeepsTheFirstIdentity` only |
| R1 | the token is checked before the latch | `failureIsStickyAndHeldKeysSurviveIt` only |
| R2 | the held set evicts beyond 8 entries | `everyButtonValueIsHeldAndReleasedWithItsPressIdentity` only |
| F1 | identifier fallback on an unpaired `DKUP` | `releasePairsByButtonOnlyNeverByIdentifier` only |
| F2 | identifier first | `releasePairsByButtonOnlyNeverByIdentifier`, `everyButtonValueIsHeldAndReleasedWithItsPressIdentity` |
| G1 | the identifier is byte-swapped | `goldenKeyFramesReEncodeByteForByte` and 14 others |
| G2 | the button is byte-swapped | `goldenKeyFramesReEncodeByteForByte` and 14 others |

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| Every Focus item (key id, button, modifier and repeat fields; the invalid and unknown key policy; a neutral keyboard event) has an implementation and a test | `tokenBytesBodyLengthsAndPhasesAreFrozen`, `capturedKeyFramesDecodeInOrderAndLeaveNothingHeld`, `releaseUsesThePressIdentityByButton`, `modifierMaskDecodesExactlyTheFiveFrozenBits`, `repeatsUseThePressIdentityAndKeepTheHeldSet`, `unknownIdentifiersAreRecordedAndReleasedCleanly`, `bodyLengthsAreExact`, `unknownAndShortTokensFailClosed`; the output is `BarrierKeyEvent`, not `KVMEvent` (`productionSourceImportsOnlyKVMContracts`) |
| Happy path | `capturedKeyFramesDecodeInOrderAndLeaveNothingHeld` (the 232 and 66 captured key frames in order), `releaseUsesThePressIdentityByButton` (the shifted and punctuation sequences), `modifierKeysCarryTheMaskBeforeOnDownAndIncludingOnUpAndNothingIsSynthesized` (modifiers and Caps Lock), `roundTripThroughTheServerEncoderForEveryEncodableKey` |
| Boundary | `bodyLengthsAreExact`, `repeatsUseThePressIdentityAndKeepTheHeldSet` (counts 0 to 0xFFFF), `unknownIdentifiersAreRecordedAndReleasedCleanly` (identifiers 0x0000 and 0xFFFF, buttons 0 and 0xFFFF), `everyButtonValueIsHeldAndReleasedWithItsPressIdentity` (all 65,536 buttons held at once), `modifierMaskDecodesExactlyTheFiveFrozenBits` (all 32 combinations, every other bit) |
| Invalid input | `bodyLengthsAreExact`, `clientToServerDirectionFailsClosed`, `unknownAndShortTokensFailClosed` |
| Error, cancel and cleanup | `failureIsStickyAndHeldKeysSurviveIt` (the latch, and the held set kept for cleanup), `heldKeysAreSortedByButtonAndFreshDecodersAreIndependent` (reset by a new decoder); there is no I/O, task or resource to cancel |
| Pairing by button; no release dropped | `releaseUsesThePressIdentityByButton`, `releasePairsByButtonOnlyNeverByIdentifier`, `unpairedReleasesAndRepeatsAreEmittedWithTheirOwnIdentifier`, `secondPressOnAHeldButtonKeepsTheFirstIdentity` |
| Golden bytes equal exactly | `goldenKeyFramesReEncodeByteForByte` (fixture bytes; each decoded identifier and button against the frame bytes at offsets 8 and 12, or 14 in `DKRP`; then decode and re-encode whole frames) |
| Fragmentation, coalescing and truncation | `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` |
| Round trip through `BarrierServerInputEncoder` | `roundTripThroughTheServerEncoderForEveryEncodableKey`: all 81 encodable keys in all 32 modifier states |
| Behavior matches the frozen ADR; no new implicit API | module-internal declarations only, with the names and shapes of design a.6 and b.4; the tests above |
| Checker, lint, build and unit tests pass with no new warning | `commands.json`: both `swift format lint --strict` runs (the two files, and the repository command) exited 0 with no finding; `make docs-check` (`docs check OK`); `make architecture-check` (`architecture check OK`); `python3 Tools/Backlog/validate_package.py` (`PACKAGE OK: 217 issues, 5 milestones, 17 epics`); `git diff --cached --check` (exit 0); the issue's `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination platform=macOS build` (`** BUILD SUCCEEDED **`); the package tests with `-warnings-as-errors` (exit 0); `make verify` (24 of 24 gates passed, status passed) |
| Production logs hold no typed text or recoverable content | `productionSourceImportsOnlyKVMContracts` (no logger, `print` or `Foundation`), `errorsCarryOnlyAllowlistedMetadata` |

## Independent review

- Before the PR, a fresh-context Claude Opus reviewer found no divergence from the contract or the
  design. Its Low items were fixed in the tests and the doc (mutants R1 and R2 come from it). Its
  one Medium, latest-press-wins, led to the lead decision above.
- After the PR, a fresh-context Fable reviewer (`independent-review.md`) found no Critical or High
  issue. Its Medium (an unpaired repeat could stick a key if a consumer injected it as a press) and
  its three Low items are resolved at `e189692`:
  - the doc's "Fail-safe requirement for consumers" says the session MUST NOT inject an unpaired
    repeat, and may inject a paired repeat only as a repeat of the held key;
  - `releasePairsByButtonOnlyNeverByIdentifier` is added;
  - the golden test checks the decoded identifier and button;
  - the `DKRP` count rule is labelled first-party.

## Known limitations

- An unpaired release or repeat and a second press of a held button were never observed. Emitting
  the unpaired frame with its own identifier and keeping the first identity are first-party
  policy, pinned by tests.
- The fail-safe requirement for consumers is enforced by the client session
  (M1-029-FOLLOWUP-001) and the injector (M4-024), not by this decoder.
- The register's `consumingTests` for `BARRIER-EVID-0006` and `0008` do not list these tests;
  `evidence/registers/M1-023.json` is outside this issue's files. This is a follow-up.
- The full-stream fragmentation and truncation test decodes the capture's server stream once per
  cut, which takes about 5 seconds of the package test run.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable
test report is in `tests/`.
