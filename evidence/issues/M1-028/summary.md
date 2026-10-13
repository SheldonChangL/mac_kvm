# M1-028 Evidence Summary — Barrier Client HelloBack Writer

Base commit: `ce20492` (M1-PROTOCOL-001 HelloBack contract frozen)

Branch: `codex/m1-028-barrier-client-hello-back`

Status: **implemented; reviewer SwiftPM tests and `xcodebuild` pass;
uncommitted.**

## Preconditions

- M1-025 (wire contract) and M1-026 (message registry) are merged; M1-021 (codec) and
  M1-022 (reassembler) are merged.
- `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md` is accepted for M1-028
  consumption and freezes the HelloBack frame as evidence entry `BARRIER-EVID-0004`.
- Golden frames exist in
  `Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json`
  (`m1-client`, 28 bytes; `m1x`, 22 bytes).
- The ADR leaves the general Barrier peer maximum for screen-name length open and
  requires a conservative MacKVM fail-closed bound instead; M1-028 follows that.

## Deliverables (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClientHelloBack.swift`:
  module-internal `BarrierClientHelloBackWriter` (`init(maximumScreenNameByteCount:)`,
  `frame(screenName:) -> [UInt8]`) and typed `BarrierClientHelloBackError`
  (`invalidMaximumScreenNameByteCount`, `emptyScreenName`,
  `screenNameTooLong(byteCount:limit:)`, `unsupportedScreenNameCharacter`,
  `frameEncodingFailed`). Errors carry at most a byte count and the configured limit.
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierClientHelloBackTests.swift`:
  21 Swift Testing tests.
- `docs/components/M1-028-barrier-client-hello-back.md`.
- `evidence/issues/M1-028/` (this package: `summary.md`, `commands.json`, `tests/`).

No `Package.swift`, KVMCore, registry, codec, reassembler, Tools, register, ADR,
fixture or other file was changed. The untracked `MacKVM_M1-001_unblock.zip` and
`mackvm-unblock/` in the working tree are unrelated to M1-028 and are not part of
this change.

## TDD

Tests were written first. Red run: without `BarrierClientHelloBack.swift`, the test
target failed to compile (`cannot find type 'BarrierClientHelloBackWriter'`, exit 1).
That run also exposed two test names colliding with `BarrierServerHelloTests`; they
were renamed with a `helloBack` prefix. Green run: 114/114 passed, 21/21 M1-028.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Output equals golden bytes exactly | `writesGoldenFrameForM1ClientExactly`, `writesGoldenFrameForM1xExactly` compare the full written frame byte-for-byte with the `BARRIER-EVID-0004` frames; `helloBackConstantsEqualGoldenBytesExactly`; `goldenFramesDifferOnlyByScreenNameDelta` |
| Screen-name encoding/length validated | Non-empty, UTF-8 byte count ≤ caller-configured bound, ASCII letters/digits/`-`/`_` only: `rejectsEmptyScreenName`, `acceptsScreenNameAtExactlyTheConfiguredLimit`, `rejectsScreenNameOneByteOverTheConfiguredLimit`, `acceptsSingleByteScreenNameAtMinimumLimit`, `rejectsNonASCIIScreenNames`, `rejectsASCIIOutsideTheIdentifierSet`, `acceptsEveryAllowedCharacterClass`, `checksLengthBeforeCharacters`, `rejectsInvalidConfiguredLimits`, `acceptsLargestLimitThatFitsTheLengthPrefix` |
| No platform default endian | All integers written through `BarrierBinaryWriter` (M1-021) explicit big-endian writes; `lengthFieldsAreBigEndianAcrossByteBoundary` uses a 300-byte name so both length fields span more than one byte |
| Happy path test | `writesGoldenFrameForM1ClientExactly`, `writesGoldenFrameForM1xExactly` |
| Boundary/limit test | Exact bound, bound + 1, bound 1 with a 1-byte name, 300-byte name, invalid (0, negative, too large) and largest supported bound |
| Invalid input/failure test | Empty, non-ASCII, ASCII separators and control bytes, length-before-characters ordering, invalid bounds |
| Cancel/cleanup/idempotency test | Pure synchronous writer with no resource or mutable state; `repeatedWritesReturnIdenticalBytes`, `failedWriteDoesNotAffectLaterWrite` |
| Fragmentation/coalescing/truncation test | Stream handling belongs to M1-022; `reassemblerYieldsGoldenPayloadsFromFragmentedAndCoalescedFrames` (byte-by-byte and coalesced) and `truncatedWrittenFrameIsReportedByReassembler` (truncation at every length) pin the hand-off |
| Consistent with frozen ADR, no implied API | Internal access only; no message code, handshake sequencing, default bound or public contract added |
| No sensitive logging | Writer has no logging; `helloBackErrorsCarryOnlyAllowlistedMetadata` and `writerCarriesOnlyTheConfiguredLimit` show no screen-name bytes are retained in errors or writer state |
| Architecture checker, lint, build, unit tests, no new warnings | SwiftPM test/build, `swift format lint --strict`, `validate_package.py`, `make architecture-check`, `make docs-check` pass; reviewer rerun of required `xcodebuild` passes |

## Tests and validation performed

All results are recorded in `commands.json`; test cases in
`tests/barrier-client-hello-back-tests.json` and raw xUnit in
`tests/swift-testing-xunit.xml`.

- Authoring session: `swift test --disable-sandbox --package-path Packages/BarrierCompatibility` — pass,
  114 tests (21 M1-028). Rerun during the evidence-completion pass: pass, 114 tests.
  `--disable-sandbox` was needed because the session itself runs inside a macOS
  sandbox where SwiftPM's nested sandbox fails (`sandbox_apply: Operation not
  permitted`); the flag does not change compilation or test selection.
- Reviewer rerun outside the nested SwiftPM sandbox:
  `swift test --package-path Packages/BarrierCompatibility` — pass, 114 tests.
- `swift build --disable-sandbox --build-tests --package-path Packages/BarrierCompatibility`
  after touching both M1-028 Swift files — 0 warnings, 0 errors.
- `swift format lint --strict` on both M1-028 Swift files — pass.
- `python3 Tools/Backlog/validate_package.py` — pass.
- `make architecture-check` — pass.
- `make docs-check` — pass.
- `git diff --check` — pass for tracked changes (there are none). Because every
  M1-028 file is untracked, each was checked separately with
  `git diff --no-index --check /dev/null <file>` — no whitespace errors reported.
- Reviewer rerun:
  `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`
  — pass, `** BUILD SUCCEEDED **`.
- `make verify` — not run; it is not a Required Command for M1-028. PR CI will
  run repository gates after the PR is opened.

## Known limitations

- Golden bytes are copied by hand into the tests, as in M1-021/M1-022/M1-026/M1-027.
- No default screen-name bound is chosen; the caller (M1-029 or later configuration)
  must supply one. The ASCII identifier set is a MacKVM conservative support policy,
  not a claim about what Barrier accepts; names outside it fail closed.
- The version bytes are opaque; no version negotiation or interpretation is
  implemented.
- When to send HelloBack, and what to do on each `BarrierClientHelloBackError`, is
  handshake policy owned by M1-029.
- `frameEncodingFailed` is defensive and not reachable through valid bounds, so it
  has no direct test.

## Follow-ups

1. M1-029 (handshake state machine) consumes `BarrierClientHelloBackWriter`, chooses
   the configured bound and decides session behavior on each error.
2. Optional: add `BarrierClientHelloBackTests` to the M1-023 evidence register
   consumer links if the register owner requires it.

## Rollback

Revert the M1-028 change (the two Swift files, the component doc and this evidence
directory). No runtime resource, persisted data or migration is involved, and no
production code consumes the writer yet.

## Reviewer requirements

Reviewer rerun completed for:

- `swift test --package-path Packages/BarrierCompatibility` (without
  `--disable-sandbox`) — pass.
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`
  — pass.
- `python3 Tools/Backlog/validate_package.py`, `make architecture-check` and
  `make docs-check` — pass.

Final staged-file reviewer gate completed:

- M1-028 files were staged and `git diff --cached --check` passed.

Still required before PR merge:

- run the repository CI/PR checks after opening the PR.
