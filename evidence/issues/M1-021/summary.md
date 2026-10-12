# M1-021 Evidence Summary — Bounded Barrier Binary Reader/Writer

GitHub Issue: #22

Base commit: `5964788ef74f77f3ec543541e0a73169ea950203` (after M1-PKG-003, PR #297)

Status: **implemented and locally verified**.
The earlier package-ownership blocker is resolved by M1-PKG-003. Reviewer reran
the exact required commands in a normal shell on 2026-10-12; all required gates
passed.

## Preconditions

- M1-015 merged; M1-025 ADR merged (PR #294); M1-025 consumer links (#293) merged (PR #295).
- `Packages/BarrierCompatibility/Package.swift` owns `BarrierCompatibilityTests` (M1-PKG-003).
- `BARRIER-EVID-0001..0003` have disposition `approved`.

## Changes (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierBinaryCodec.swift`:
  module-internal `BarrierBinaryReader`, `BarrierBinaryWriter` and typed
  `BarrierBinaryCodecError` (`truncated`, `oversize`, `integerOverflow`, `invalidCount`).
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierBinaryCodecTests.swift`:
  29 Swift Testing tests.
- `docs/components/M1-021-barrier-binary-codec.md`.
- `evidence/issues/M1-021/` (this package).

No `Package.swift`, Tools, register, ADR, root package or unrelated doc was changed.

## TDD

Tests were written first; the red run failed to compile (`cannot find
BarrierBinaryReader in scope`, `tests/red-phase.json`). The minimal implementation
then passed 28 tests; review-driven hardening raised it to 30 (`tests/barrier-binary-codec-tests.json`).

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Explicit endian | All integers big-endian; `readerDecodesUnsignedIntegersBigEndian`, `writerEncodesUnsignedIntegersBigEndian` |
| Bounds check on every read/write | Remainder-based checks; `readerRejectsTruncated*`, `readerRejectsHugeCountWithoutArithmeticOverflow`, `writerRejectsCapacityOverflow` |
| Typed overflow/oversize errors | `oversize`, `integerOverflow`, `invalidCount` tests; errors carry counts only |
| Happy path | Golden frame read/write, coalesced frames, round trip |
| Boundary/limit | Empty payload, payload at limit, capacity filled exactly, zero capacity, `UInt32` prefix range |
| Invalid input/failure | Truncation at every prefix/payload length, limit+1, `FF FF FF FF` prefix, negative counts |
| Cleanup/idempotency | `failedReadsDoNotAdvanceCursor`, `readerRejectsTruncatedIntegers` cursor checks, `failedWritesLeaveBufferUnchanged`, `failedPrimitiveWritesLeaveBufferUnchanged` |
| Golden bytes equal exactly | `writerProducesGoldenFrameBytes` compares the full 15-byte frame from `BARRIER-EVID-0002` run 0 |
| Fragmentation/coalescing/truncation | Coalesced frames test; every truncated length reported as `truncated` (reassembly is M1-022) |
| Consistent with frozen ADR, no implied API | Internal access only; 4-byte unsigned big-endian envelope; no message codes, marker validation or default limit |
| No new warnings | Child package and root package build with `-warnings-as-errors`; swift-format lint passes |
| No sensitive logging | No logging; errors carry no bytes |
| Architecture checker, lint, build, unit tests | `swift test --package-path Packages/BarrierCompatibility`, `xcodebuild`, `validate_package.py`, `make architecture-check`, `make docs-check`, `git diff --check` and full `make verify` pass |

## Commands

See `commands.json`. The initial Claude author run hit nested sandbox limits, but
reviewer reran the exact required forms in a normal shell:

- `swift test --package-path Packages/BarrierCompatibility` — pass, 30 tests.
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` — pass.
- `python3 Tools/Backlog/validate_package.py` — pass.
- `make architecture-check` — pass.
- `make docs-check` — pass.
- `git diff --check` — pass.
- `make verify` — pass; 24 gates passed, including `swift-package-test:BarrierCompatibility`.

## Independent review

A fresh-context Claude Opus review found no Critical or High issues. Remediated:

- Medium: the doc misattributed client outbound marker/version bytes to M1-026; it
  now states M1-021 declines that M1-025-assigned item (follow-up 1).
- Low: test golden-byte comment now cites JSON pointers; cursor/buffer preservation
  added for integer reads and primitive writes; doc and comments for `invalidCount` vs
  `integerOverflow` aligned; unreachable writer guard removed and the 32-bit-only read
  guard commented; shared `oversize` case documented; `FF FF FF FF` with `Int.max`
  limit test added.

Not remediated here (outside Exact Files): follow-up #298.

## Known limitations

- Golden bytes are copied by hand into the test rather than loaded from the artifact.
- `integerOverflow` on the read path is unreachable on 64-bit macOS and not tested.
- Payload and capacity limits are caller-supplied safety bounds, not Barrier limits.

## Follow-ups

1. Client outbound marker/version bytes: M1-025 assigns them to "M1-021 or later
   writer issue". M1-021 declines because there is no approved evidence; a later
   writer issue must own them.
2. #298: Append `BarrierBinaryCodecTests` to `consumingTests` for
   `BARRIER-EVID-0002`/`0003` in `evidence/registers/M1-023.json` through the
   register's consumer-link path. Owner: Codex; priority: P1; blocking relation:
   complete before the first issue that consumes M1-021 as authoritative
   traceability evidence, or obtain explicit Product Owner waiver.
3. Mapping `BarrierBinaryCodecError` to `CoreError` (`protocol.malformed`/`oversized`)
   belongs to the first consumer that crosses the adapter boundary (M1-022 or later).

## Rollback

Revert the M1-021 PR. No runtime resource, persisted data or migration is involved.
Keep M1-022 blocked until a bounded codec is restored.
