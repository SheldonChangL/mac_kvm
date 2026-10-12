# M1-022 Evidence Summary — Barrier Frame Reassembler

GitHub Issue: #36

Base commit: `64d94c7e37941b5b3c4470a58113153765d36b4e` (after M1-021 trace follow-up, PR #300)

Status: **implemented and locally verified**. The authoring session could not
run build/test commands, so reviewer reran every required command in a normal
shell on 2026-10-12; all required gates passed.

## Preconditions

- M1-019 (#27), M1-020 (#32), M1-021 (#22, PR #299) and M1-021 trace follow-up
  (#298, PR #300) are merged.
- `docs/adr/M1-025-barrier-client-wire-contract.md` is merged and freezes the
  4-byte unsigned big-endian length-prefix envelope.
- `evidence/registers/M1-023.json` lists `BarrierBinaryCodecTests` as a consumer
  of the approved Barrier evidence (PR #300).

## Changes (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierFrameReassembler.swift`:
  module-internal `BarrierFrameReassembler` and typed
  `BarrierFrameReassemblerError` (`invalidMaximumPayloadLength`, `oversize`,
  `truncatedPrefix`, `truncatedPayload`, `appendAfterFinish`).
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierFrameReassemblerTests.swift`:
  25 Swift Testing tests.
- `docs/components/M1-022-barrier-frame-reassembler.md`.
- `evidence/issues/M1-022/` (this package).

No `Package.swift`, Tools, register, ADR, root package or unrelated doc was changed.

## TDD

Tests were written before the implementation, but the red run could not be
executed because `swift test` was denied in the authoring session. Reviewer
reran the green phase successfully; `tests/barrier-frame-reassembler-tests.json`
records the final package test result.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Split/coalesced frames | `reassemblesGoldenFrameSplitAtEveryOffset`, `reassemblesGoldenFrameOneByteAtATime`, `reassemblesCoalescedFramesFromSingleAppend`, `reassemblesCoalescedFramesAcrossEveryChunkSize`, `reassemblesCoalescedFramesWithoutInterleavedDraining` |
| Maximum frame size (caller supplied, fail closed, typed) | `init(maximumPayloadLength:)` without default; `rejectsFrameOneByteOverLimit`, `rejectsMaximumPrefixBeforeBufferingPayload`, `rejectsOversizePrefixSplitAcrossChunksWhenLastPrefixByteArrives`, `rejectsNegativeMaximumPayloadLength` |
| Explicit truncated-frame error at EOF | `finishReportsTruncatedPrefixAtEveryLength`, `finishReportsTruncatedPayloadAtEveryLength`, `finishReportsTruncationForMaximumPrefixWithinUnboundedLimit` |
| Happy path | Golden frame in one append, split, byte-at-a-time and coalesced |
| Boundary/limit | Empty payload with zero limit, payload at limit, limit one below, every chunk boundary around prefix and payload, empty append, empty stream |
| Invalid input/failure | Oversize prefix, truncated prefix/payload at EOF, append after finish, negative limit |
| Cleanup/idempotency | `framesCompletedBeforeOversizeRemainAvailable`, `framesCompletedBeforeTruncationRemainAvailable`, `failureIsStickyAndReleasesPartialBytes`, `truncationAtFinishIsStableAndReleasesPartialBytes`, `cleanFinishIsIdempotent`, `drainedPayloadsAreNotReturnedTwice` |
| Golden bytes equal exactly | `reassembledGoldenPayloadReencodesToExactGoldenBytes` compares the reassembled payload and its `BarrierBinaryWriter` re-encoding with the 15-byte `BARRIER-EVID-0002` run 0 frame |
| Fragmentation/coalescing/truncation | Listed above |
| Consistent with frozen ADR, no implied API | Internal access only; M1-025 envelope unchanged; no message codes, marker validation or default limit |
| No sensitive logging | No logging; errors carry counts and limits only |
| Architecture checker, lint, build, unit tests, no new warnings | `swift test --package-path Packages/BarrierCompatibility`, `xcodebuild`, `validate_package.py`, `make architecture-check`, `make docs-check`, `git diff --check` and full `make verify` pass |

## Commands

See `commands.json`. Reviewer reran the required commands in a normal shell:

- `swift test --package-path Packages/BarrierCompatibility` — pass, 55 tests
  (25 M1-022 tests plus existing BarrierCompatibility tests).
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` — pass.
- `python3 Tools/Backlog/validate_package.py` — pass.
- `make architecture-check` — pass.
- `make docs-check` — pass.
- `git diff --check` — pass.
- `make verify` — pass; 24 gates passed, including `swift-package-test:BarrierCompatibility`.

## Known limitations

- Golden bytes are copied by hand into the test, as in M1-021.
- The 32-bit-only `Int(exactly:)` guard path is unreachable on 64-bit macOS and untested.
- The payload limit is a caller-supplied safety bound, not a Barrier limit.
- Payload storage grows by appended chunks; it is bounded by the caller limit
  but not pre-reserved, so very large accepted frames may reallocate.

## Follow-ups

1. Mapping `BarrierFrameReassemblerError` and `BarrierBinaryCodecError` to
   `CoreError` belongs to the first consumer that crosses the adapter boundary.
2. #301: append `BarrierFrameReassemblerTests` to `consumingTests` for
   `BARRIER-EVID-0002` and `BARRIER-EVID-0003` through the register's
   consumer-link path. Owner: Codex; priority: P1; blocking relation: complete
   before the first downstream issue consumes M1-022 as authoritative
   traceability evidence, or obtain explicit Product Owner waiver.

## Rollback

Revert the M1-022 PR. No runtime resource, persisted data or migration is
involved, and no production code consumes the reassembler yet.
