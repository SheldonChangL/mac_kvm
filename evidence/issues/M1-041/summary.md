# M1-041 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierKeyboardDecoder.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierKeyboardDecoderTests.swift`,
`docs/components/M1-041-barrier-keyboard-decoder.md`, and this directory's `summary.md` and
`commands.json`.

The issue sits under "M1 - Mac Client MVP", but the consumer is the first-party Linux client that
speaks the Barrier wire to the first-party Mac server
(`docs/adr/M4-SCOPE-001-linux-client-first.md`). The contract is
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`. The key mapper M1-043
stacks on this branch and uses `BarrierKeyIdentifier`, `BarrierKeyEvent` and
`BarrierKeyboardDecoder`.

## RED

The first 19 tests were written before the implementation and run against a compiling stub with
the design's API and no behavior: `✘ Test run with 19 tests in 1 suite failed after 0.018 seconds with 75 issues.` 18 of the 19 failed.
`productionSourceImportsOnlyKVMContracts` passed, because it only checks the file's imports.

The fresh-context review below added a 20th test, `everyButtonValueIsHeldAndReleasedWithItsPressIdentity`,
and two checks in existing tests. Mutants R1 and R2 show that they fail when the behavior they
pin is broken.

## GREEN

`timeout 900 swift test --package-path Packages/BarrierCompatibility --filter BarrierKeyboardDecoderTests`: `✔ Test run with 20 tests in 1 suite passed after 5.187 seconds.`

The full package, `timeout 900 swift test --package-path Packages/BarrierCompatibility`: `✔ Test run with 267 tests in 9 suites passed after 5.503 seconds.` With `-Xswiftc -warnings-as-errors`: `✔ Test run with 267 tests in 9 suites passed after 6.280 seconds.`

## Mutation checks

Each mutant edited the source, ran the M1-041 suite, and was restored from a backup copy. After
every restore the source was byte-for-byte the original and `git diff --exit-code` against the
staged file returned 0. Mutants 1 to 6 are the required checks; R1 and R2 come from the review.

| # | Mutation | Result | Failing tests |
| --- | --- | --- | --- |
| 1 | A release uses its own identifier instead of the press's | killed: exit 1, 8 tests failed | `capturedKeyFramesDecodeInOrderAndLeaveNothingHeld`, `everyButtonValueIsHeldAndReleasedWithItsPressIdentity`, `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated`, `releaseUsesThePressIdentityByButton`, `repeatsUseThePressIdentityAndKeepTheHeldSet`, `roundTripThroughTheServerEncoderForEveryEncodableKey`, `secondPressOnAHeldButtonReplacesTheIdentity`, `unknownIdentifiersAreRecordedAndReleasedCleanly` |
| 2 | An unpaired release is dropped instead of emitted (no event: `decode` throws) | killed: exit 1, 4 tests failed | `bodyLengthsAreExact`, `goldenKeyFramesReEncodeByteForByte`, `secondPressOnAHeldButtonReplacesTheIdentity`, `unpairedReleasesAndRepeatsAreEmittedWithTheirOwnIdentifier` |
| 3a | Mask bits beyond the five are kept: 0x2000, 0x4000, 0x8000 read as Caps Lock | killed: exit 1, 2 tests failed | `modifierMaskDecodesExactlyTheFiveFrozenBits`, `unknownIdentifiersAreRecordedAndReleasedCleanly` |
| 3b | Mask bits beyond the five are kept: 0x0008 read as Alt | killed: exit 1, 2 tests failed | `modifierMaskDecodesExactlyTheFiveFrozenBits`, `unknownIdentifiersAreRecordedAndReleasedCleanly` |
| 4 | A `DKRP` with count N > 1 yields N repeats (the extra ones on the next `decode` calls) | killed: exit 1, 3 tests failed | `repeatsUseThePressIdentityAndKeepTheHeldSet`, `unknownIdentifiersAreRecordedAndReleasedCleanly`, `unpairedReleasesAndRepeatsAreEmittedWithTheirOwnIdentifier` |
| 5a | `heldKeys` is cleared after a fail-closed error | killed: exit 1, 2 tests failed | `failureIsStickyAndHeldKeysSurviveIt`, `heldKeysAreSortedByButtonAndFreshDecodersAreIndependent` |
| 5b | The failure is not latched after a fail-closed error | killed: exit 1, 6 tests failed | `bodyLengthsAreExact`, `clientToServerDirectionFailsClosed`, `errorsCarryOnlyAllowlistedMetadata`, `failureIsStickyAndHeldKeysSurviveIt`, `heldKeysAreSortedByButtonAndFreshDecodersAreIndependent`, `unknownAndShortTokensFailClosed` |
| 6 | A second `DKDN` on a held button keeps the first identity (first press wins) | killed: exit 1, 1 test failed | `secondPressOnAHeldButtonReplacesTheIdentity` |
| R1 | Review: the token is checked before the latch, so an unknown token after a failure reports itself instead of the latched error | killed: exit 1, 1 test failed | `failureIsStickyAndHeldKeysSurviveIt` |
| R2 | Review: the held set evicts its lowest button beyond 8 entries | killed: exit 1, 1 test failed | `everyButtonValueIsHeldAndReleasedWithItsPressIdentity` |

`decode` returns exactly one event per frame, so mutants 2 and 4 take the only shapes that
signature allows: a dropped release can only be a throw, and extra repeats can only come back
from the following `decode` calls.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| Every Focus item (key id, button, modifier and repeat fields; the invalid and unknown key policy; a neutral keyboard event) has an implementation and a test | `tokenBytesBodyLengthsAndPhasesAreFrozen`, `capturedKeyFramesDecodeInOrderAndLeaveNothingHeld`, `releaseUsesThePressIdentityByButton`, `modifierMaskDecodesExactlyTheFiveFrozenBits`, `repeatsUseThePressIdentityAndKeepTheHeldSet`, `unknownIdentifiersAreRecordedAndReleasedCleanly`, `bodyLengthsAreExact`, `unknownAndShortTokensFailClosed`; the output is `BarrierKeyEvent`, not `KVMEvent` (`productionSourceImportsOnlyKVMContracts`) |
| Happy path | `capturedKeyFramesDecodeInOrderAndLeaveNothingHeld` (the 232 and 66 captured key frames in order), `releaseUsesThePressIdentityByButton` (the shifted and punctuation sequences), `modifierKeysCarryTheMaskBeforeOnDownAndIncludingOnUpAndNothingIsSynthesized` (modifiers and Caps Lock), `roundTripThroughTheServerEncoderForEveryEncodableKey` |
| Boundary | `bodyLengthsAreExact`, `repeatsUseThePressIdentityAndKeepTheHeldSet` (counts 0 to 0xFFFF), `unknownIdentifiersAreRecordedAndReleasedCleanly` (identifiers 0x0000 and 0xFFFF, buttons 0 and 0xFFFF), `everyButtonValueIsHeldAndReleasedWithItsPressIdentity` (all 65,536 buttons held at once), `modifierMaskDecodesExactlyTheFiveFrozenBits` (all 32 combinations, every other bit) |
| Invalid input | `bodyLengthsAreExact`, `clientToServerDirectionFailsClosed`, `unknownAndShortTokensFailClosed` |
| Error, cancel and cleanup | `failureIsStickyAndHeldKeysSurviveIt` (the latch, and the held set kept for cleanup), `heldKeysAreSortedByButtonAndFreshDecodersAreIndependent` (reset by a new decoder); there is no I/O, task or resource to cancel |
| Pairing by button; no release dropped | `releaseUsesThePressIdentityByButton`, `unpairedReleasesAndRepeatsAreEmittedWithTheirOwnIdentifier`, `secondPressOnAHeldButtonReplacesTheIdentity` |
| Golden bytes equal exactly | `goldenKeyFramesReEncodeByteForByte` (fixture bytes, then decode and re-encode whole frames) |
| Fragmentation, coalescing and truncation | `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` |
| Round trip through `BarrierServerInputEncoder` | `roundTripThroughTheServerEncoderForEveryEncodableKey`: all 81 encodable keys in all 32 modifier states |
| Behavior matches the frozen ADR; no new implicit API | module-internal declarations only, with the names and shapes of design a.6 and b.4; the tests above |
| Checker, lint, build and unit tests pass with no new warning | `commands.json`: both `swift format lint --strict` runs (the two files, and the repository command) exited 0 with no finding; `make docs-check` (`docs check OK`); `make architecture-check` (`architecture check OK`); `python3 Tools/Backlog/validate_package.py` (`PACKAGE OK: 217 issues, 5 milestones, 17 epics`); `git diff --cached --check` (exit 0); the issue's `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination platform=macOS build` (`** BUILD SUCCEEDED **`); the package tests with `-warnings-as-errors` (exit 0); `make verify` (24 of 24 gates passed, status passed) |
| Production logs hold no typed text or recoverable content | `productionSourceImportsOnlyKVMContracts` (no logger, `print` or `Foundation`), `errorsCarryOnlyAllowlistedMetadata` |

## Known limitations

- An unpaired release or repeat and a second press of a held button were never observed. Emitting
  the unpaired frame with its own identifier and letting the latest press win are first-party
  policy (design c.12 and c.13), pinned by tests.
- Because the latest press wins, a second press of a held button with another identifier
  displaces the first identity. If M1-043 maps the two identifiers to different keys, the first
  key's downstream press is released only by the session's terminal cleanup.
- The issue lists `evidence/issues/M1-041/tests/` as expected evidence. This PR's file list allows
  only `summary.md` and `commands.json`, so `commands.json` carries the test output instead.
- The register's `consumingTests` for `BARRIER-EVID-0006` and `0008` do not list these tests.
  `evidence/registers/M1-023.json` is outside this issue's files (M1-031 precedent); this is a
  follow-up for the register owner.
- The full-stream fragmentation and truncation test decodes the capture's server stream once per
  cut, which takes about 5 seconds of the package test run.

Full gates are in `commands.json`.

## Review

Before the PR, a fresh-context reviewer (Claude Opus, read-only, given the code and the sources
but not the author's reasoning) found no divergence from the contract or the design and no way
around the failure latch. It reported one Medium and nine Low items:

- Medium: the latest press wins, so a displaced identity is released only by cleanup. Kept,
  because it is design decision c.13 and a required mutation check; recorded above and in the
  component doc for the lead's decision.
- Low, fixed in the tests: an unknown or empty payload after a failure (mutant R1); no test held
  more than six buttons (mutant R2); the error-kind exhaustiveness check counted a literal.
- Low, fixed in the doc: the pairing label (contract versus first-party policy), the
  shifted-identifier convention in the unknown-identifier rule, the Caps Lock wording, routing key
  frames instead of `BarrierControlDecoder` (which fails closed on `DKRP`), unpaired repeats, the
  value-type latch, and the 65,536-entry bound.
- Low, documented only: default `description` and reflection are not redacted. Redacting
  conformances would add API beyond design a.6 and b.4, so the doc states the logging rule.

Tier B: a full review by a stronger model or an engineer is still required, then the Product
Owner's merge.
