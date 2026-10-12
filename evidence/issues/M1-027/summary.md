# M1-027 Evidence Summary — Barrier Server Hello Parser

GitHub Issue: #40

Base commit: `1425960` (after M1-026 merge, PR #304)

Status: **implemented and reviewer-verified locally; uncommitted**.

## Preconditions

- M1-025 is merged: `docs/adr/M1-025-barrier-client-wire-contract.md` freezes the
  first server-to-client marker-bearing payload as marker `42 61 72 72 69 65 72`
  followed immediately by opaque version bytes `00 01 00 06`, with the
  `exact-supported-version-fail-closed` policy.
- M1-026 (message registry) is merged; M1-021 (codec) and M1-022 (reassembler) are
  merged.
- The golden fixture exists:
  `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json` `/derived/runs/0`,
  `/derived/markerObservations`, `/derived/versionByteObservations`.
- M1-025 lists Barrier message codes, names, code width, optional fields and field
  layout beyond the marker/version as **not frozen**. M1-027 therefore validates
  only the frozen marker/version payload, defines no message code and accepts no
  trailing bytes.

## Changes (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierServerHello.swift`:
  module-internal `BarrierServerHello` (validated value, only constructible via
  `init(payload:)`) and typed `BarrierServerHelloError` (`truncatedMarker`,
  `unsupportedMarker`, `truncatedVersion`, `unsupportedVersion`,
  `unexpectedTrailingBytes`). Errors carry at most `payloadByteCount`.
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierServerHelloTests.swift`:
  19 Swift Testing tests.
- `docs/components/M1-027-barrier-server-hello.md`.
- `evidence/issues/M1-027/` (this package).

No `Package.swift`, KVMCore, registry, reassembler, Tools, register, ADR or unrelated
file was changed.

## TDD

Tests were written first. Red run: without `BarrierServerHello.swift`, `swift test`
failed to compile (`cannot find type 'BarrierServerHelloError' in scope`, exit 1).
Green run: 94/94 passed, 20/20 M1-027. After the fresh-context review, one
vacuous test was removed and the metadata test now checks errors the parser actually
throws; final run: 93/93 passed, 19/19 M1-027.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Only frozen wire variants accepted | `init(payload:)` accepts only marker + version, exactly 11 bytes; `rejectsEverySingleByteMarkerMutation`, `rejectsEverySingleByteVersionMutation`, `rejectsNeighbouringVersionsWithoutNegotiation`, `rejectsOtherMarkersIncludingCaseVariants`, `rejectsTrailingBytesAfterVersion` |
| Length/version/string limits validated | `payloadLengthIsExactlyMarkerPlusVersion`, `rejectsEmptyPayloadAsTruncatedMarker`, `rejectsTruncatedMarkerAtEveryLength`, `rejectsTruncatedVersionAtEveryLength`; marker compared as bytes, case variants rejected |
| Typed compatibility message output | `BarrierServerHello` (internal, `Equatable`, `Sendable`); `parsesGoldenPayloadWithExactBytes`, `helloCarriesOnlyAcceptedMarkerAndVersion` |
| Happy path | `parsesGoldenPayloadWithExactBytes`, `frozenConstantsEqualGoldenBytesExactly`, `parsesGoldenPayloadReassembledFromByteByByteFragments` |
| Boundary/limit | Exact 7 + 4 = 11 length, empty payload, truncation at every length 0–10, trailing 1/4/65 536 bytes |
| Invalid input/failure | Single-byte mutations, neighbouring/extreme versions, marker case variants, `reportsMismatchBeforeTruncation`, `reportsMarkerMismatchBeforeVersionMismatchOrTrailingBytes`, `reportsVersionMismatchBeforeTrailingBytes` |
| Cancel/cleanup/idempotency | Pure synchronous parser with no resource or state; `repeatedParseReturnsEqualValues`, `failedParseDoesNotAffectLaterParse` |
| Golden bytes equal exactly | `parsesGoldenPayloadWithExactBytes`: `markerBytes + versionBytes` equals the 11-byte `BARRIER-EVID-0002` run 0 payload; `frozenConstantsEqualGoldenBytesExactly` |
| Fragmentation/coalescing/truncation | Stream-level handling belongs to M1-022 (`evidence/issues/M1-022/`). Here: payload-level truncation at every length, and `parsesGoldenPayloadReassembledFromByteByByteFragments` pins the M1-022 hand-off |
| Consistent with frozen ADR, no implied API | Internal access only; no message code, code width, version semantics or trailing layout introduced; marker not registered in `BarrierMessageRegistry` |
| No sensitive logging | No logging; `thrownErrorsCarryOnlyAllowlistedMetadata` verifies errors thrown for each case expose only `payloadByteCount` |
| Architecture checker, build, unit tests, no new warnings | See `commands.json` |

## Commands

See `commands.json` and `tests/`:

- `swift test --package-path Packages/BarrierCompatibility` — pass, 93 tests (19 M1-027).
- `swift build --build-tests --package-path Packages/BarrierCompatibility` after
  touching both M1-027 Swift files — 0 warnings.
- `swift format lint --recursive --strict ...` — pass.
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` —
  pass, `** BUILD SUCCEEDED **`. Xcode emitted the existing ambiguous-destination
  warning described by M1-005; no Swift compile warning was observed.
- `python3 Tools/Backlog/validate_package.py` — pass.
- `make architecture-check` — pass.
- `make docs-check` — pass.
- `git diff --check` — pass.
- `make verify` — pass, 24 gates.

## Known limitations

- Golden bytes are copied by hand into the test, as in M1-021/M1-022/M1-026.
- Trailing bytes after the version are rejected because no trailing layout is
  frozen. If later evidence shows the server hello carries further fields, a
  superseding ADR must define them before this parser accepts them.
- The version is kept opaque; no major/minor interpretation is exposed.
- Which frame is the "first marker-bearing frame" and what happens after a failure
  (disconnect, diagnostic) is handshake policy owned by M1-029.

## Follow-ups

1. M1-029 (handshake state machine) consumes `BarrierServerHello` and decides session behavior on
   each `BarrierServerHelloError`.
2. Optional: append `BarrierServerHelloTests` to the M1-023 evidence register
   consumer links, following the M1-022 follow-up pattern (#301), if the register
   owner requires it.

## Rollback

Revert the M1-027 PR. No runtime resource, persisted data or migration is involved,
and no production code consumes the parser yet.
