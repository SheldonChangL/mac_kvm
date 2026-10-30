# M1-043 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierVirtualKeyMapper.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierVirtualKeyMapperTests.swift`,
`docs/components/M1-043-barrier-virtual-key-mapper.md`, and this directory.

The mapper turns a Barrier key identifier from `BarrierKeyEvent` (M1-041) into a C-005
`VirtualKey` and composes `KVMEvent.key`. Its table has 134 rows: the 100 frozen identifiers of
`BARRIER-EVID-0006-CLAIM-005` and `0008-CLAIM-001`, and the 34 convention identifiers of
M1-PROTOCOL-003. A shifted identifier maps to its physical key; Shift travels in the modifiers.
Insert, keypad Enter and every other identifier map to `.unknown(raw)`. The consumer is the
first-party Linux client (M4-SCOPE-001).

## Decisions recorded

Both were made by the implementation lead (Claude), not by the Product Owner, on 2026-10-29,
when the decoder design's open questions were settled. They were reported to the Product Owner in
the session that day.

| Question | Decision | Basis |
| --- | --- | --- |
| d.2: may M1-043 map the punctuation identifiers, which M1-042 left to "its own evidence-backed change"? | Yes. M1-PROTOCOL-003 is that change. | It freezes the eleven punctuation identifiers, plain and shifted, from `BARRIER-EVID-0008`, and names M1-043 as a consumer. The M1-042 note recording this is in PR #340. |
| d.3: which tests does the issue's `swift test --package-path Packages/KVMCore` mean? | Run `swift test --package-path Packages/BarrierCompatibility`. | `Packages/KVMCore` has no `Package.swift`, and M4-SCOPE-001 moved M1-043's files into `BarrierCompatibility`. M1-060 recorded the same deviation. |

## RED

Against a stub with the API and no behavior, at `3578e01`:
`✘ Test run with 14 tests in 1 suite failed after 0.764 seconds with 752 issues.` 12 of the 14
failed; the import check and the determinism check passed. The RED output names
`noKeyComesFromRawValueArithmetic`, which was later renamed
`identifiersAtRawValueShortcutEdgesMapToTheirOwnKeys` (`commands.json`, `testRenames`).

## GREEN

At `ddbf459`:

- Focused: `✔ Test run with 15 tests in 1 suite passed after 0.587 seconds.`
- Full package: `✔ Test run with 336 tests in 13 suites passed after 9.013 seconds.`, and 336
  passed with `-Xswiftc -warnings-as-errors`.
- `make verify`: 24 of 24 gates passed.

## Mutation checks

12 mutants, each killed (exit 1), each restored byte for byte. The runner is
`mutations/run_mutations.py`, which takes the repository path as an argument; the results are
`mutations/mutations.json`. Mutant 8 changes no behavior, so only the source check can catch it.
Against the previous suite it survived (`mutations/mutations-previous-suite.json`); the current
suite kills it.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| 1 | bracketleft (0x005B/0x007B) and bracketright (0x005D/0x007D) map to each other's key | 6: `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`, `identifiersAtRawValueShortcutEdgesMapToTheirOwnKeys` and 4 more |
| 2 | an identifier without a table row maps to .space | 4: `everyTableValueStaysInsideItsCatalogDomain`, `frozenNonMembersAndUnknownIdentifiersBecomeUnknownWithTheZeroExtendedRawValue` and 2 more |
| 3 | 0x0042-0x005A and the nine shifted digits other than 0x0021 are removed from the table, so they fall back to unknown(raw) | 9: `catalogVersionIsTwoAndTheTableHas134Identifiers`, `contractIdentifiersEqualTheFrozenSetUnionTheConventionList` and 7 more |
| 4a | the captured underscore 0x005F maps to the equal key; its plain pair 0x002D stays minus | 9: `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`, `everyTableValueStaysInsideItsCatalogDomain` and 7 more |
| 4b | the convention identifier 0x0040 (@) maps to the 3 key; its plain pair 0x0032 stays the 2 key | 7: `conventionIdentifiersMapToTheirLettersAndDigits`, `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey` and 5 more |
| 5a | keypad Enter 0xEF8D maps to .enter | 6: `catalogVersionIsTwoAndTheTableHas134Identifiers`, `everyTableValueStaysInsideItsCatalogDomain` and 4 more |
| 5b | Insert 0xEF63 maps to .delete | 5: `catalogVersionIsTwoAndTheTableHas134Identifiers`, `everyTableValueStaysInsideItsCatalogDomain` and 3 more |
| 6a | kvmEvent(for:) drops the modifiers | 6: `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`, `frozenNonMembersAndUnknownIdentifiersBecomeUnknownWithTheZeroExtendedRawValue` and 4 more |
| 6b | kvmEvent(for:) turns a repeat into a press | 3: `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`, `kvmEventKeepsThePhaseAndModifiersAndIgnoresTheButtonAndPairing` and 1 more |
| 7a | letters computed by arithmetic over 0x0041-0x007A, which turns 0x005B-0x0060 into out-of-domain letters | 10: `conventionIdentifiersMapToTheirLettersAndDigits`, `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey` and 8 more |
| 7b | kvmEvent(for:) maps the button (the server's key code) instead of the identifier | 7: `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`, `frozenNonMembersAndUnknownIdentifiersBecomeUnknownWithTheZeroExtendedRawValue` and 5 more |
| 8 | virtualKey(for:) answers 97 (0x0061) with .letter(0) before the table lookup; the behavior is unchanged, so only the source check can catch it | 1: `productionSourceKeepsEveryNumericLiteralInsideTheNamedLists` |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Table-driven, no magic numbers in a switch | `productionSourceKeepsEveryNumericLiteralInsideTheNamedLists` (no hexadecimal or decimal literal outside the named lists, with comments and strings removed), `productionSourceImportsOnlyKVMContracts` (no switch, no `(rawValue:`, no logger, trap or mutable state) |
| Every fixture key has an expected `VirtualKey` | `serverInputCaptureKeysMapToTheKeysTheDriverPressedInOrder` (232 frames), `punctuationCaptureKeysMapToTheKeysTheDriverPressedInOrder` (66) |
| Happy path | the two capture tests, `mapperIsTheInverseOfTheServerEncoderForEveryEncodableKey`, `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey` |
| Boundary | `identifiersAtRawValueShortcutEdgesMapToTheirOwnKeys`, `everyTableValueStaysInsideItsCatalogDomain`, `catalogVersionIsTwoAndTheTableHas134Identifiers` |
| Invalid input | `frozenNonMembersAndUnknownIdentifiersBecomeUnknownWithTheZeroExtendedRawValue` (all 65,402 non-contract values) |
| Cancel and cleanup | `mappingIsPureDeterministicAndConcurrencySafe` (no state; concurrent callers; a cancelled task) |
| Consistent with the frozen ADR and catalog; no implicit API | module-internal only; `contractIdentifiersEqualTheFrozenSetUnionTheConventionList`, `conventionIdentifiersMapToTheirLettersAndDigits`, `shiftedIdentifiersMapToThePhysicalKeyOfTheirPlainPair`, `kvmEventKeepsThePhaseAndModifiersAndIgnoresTheButtonAndPairing` |
| Round trip through the first-party encoder | `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey` (81 keys, 32 modifier states, three phases) |
| Checker, lint, build and unit tests with no warnings | `commands.json`: architecture check OK, both lints exit 0, `** BUILD SUCCEEDED **`, `-warnings-as-errors` 336 passed, `make verify` 24 of 24 |
| No typed text in logs | `productionSourceImportsOnlyKVMContracts` (no logger, print or trap) |

## Independent review

- Before the PR, a fresh-context Claude Opus reviewer re-derived all 134 rows with no difference.
  Its Medium and Low items were fixed in the doc and the tests before the first commit.
- After the PR, a fresh-context Fable reviewer (`independent-review.md`) re-derived all 134 rows
  from both captures, the register claims and the encoder: zero differences, and no Critical or
  High finding. Its Medium (an over-constraining consumer rule) and its three Low items are
  resolved at `ddbf459`.

## Known limitations

- Insert and keypad Enter map to `unknown` and are rejected downstream; catalog v2 has no member
  for them.
- US ANSI only. Non-US identifiers are not frozen, and their behavior is unknown.
- Letter case comes from the client's Shift and Caps Lock state; lock state is not synchronized
  at enter.
- `modifiers` is the raw wire mask, in which a modifier key's own event inverts its own bit. The
  doc's first-party guidance: do not take the state after a modifier key's own event from that
  event's `modifiers`.
- Open questions for M1-046 and M4-024: modifiers already held when the pointer enters, and the
  Caps Lock state at enter. Neither produces a modifier key event on the client.
- A modifier's own press and release round-trip with its own bit inverted. Caps Lock arrives as
  a whole press per toggle and nothing for a repeat.
- Modifiers are side-agnostic.
- Only Shift+B of the 34 convention identifiers was validated against a real `barrierc`.
- The register's `consumingTests` will list this suite after the merge (PR #340).

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable test
report is in `tests/`.
