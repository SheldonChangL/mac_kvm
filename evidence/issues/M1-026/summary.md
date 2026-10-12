# M1-026 Evidence Summary — Barrier Message Registry

GitHub Issue: #39

Base commit: `aef3b2b0f81cf7d382644105163841d83cf86838` (after M1-022 trace follow-up, PR #303)

Status: **implemented and reviewer-verified locally; uncommitted**.

## Preconditions

- M1-025 is merged: `docs/adr/M1-025-barrier-client-wire-contract.md` freezes the
  4-byte length-prefix envelope and first-frame marker/version bytes.
- M1-021 (binary codec) and M1-022 (frame reassembler) are merged.
- M1-025 lists Barrier message codes, names and payload field layouts as **not
  frozen**. M1-026 therefore freezes none of them: the registry hardcodes no message
  code and assumes no code width; later decoder issues register their own evidenced
  codes as opaque byte prefixes. This avoids the stop condition "fields still unknown"
  without inferring wire bytes.

## Changes (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMessageRegistry.swift`:
  module-internal `BarrierMessageCode`, `BarrierMessageRegistry<Message, DecodeFailure>`,
  `BarrierMessageDispatch`, `BarrierUnknownMessageDiagnostic` and typed
  `BarrierMessageRegistryError` (`emptyCode`, `duplicateCode`, `ambiguousCode`).
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierMessageRegistryTests.swift`:
  19 Swift Testing tests.
- `docs/components/M1-026-barrier-message-registry.md`.
- `evidence/issues/M1-026/` (this package).

No `Package.swift`, KVMCore, Tools, register, ADR or unrelated file was changed.

## TDD

Tests were written before the green run. Red run: with the source file temporarily
moved out, `swift test` failed to compile (`cannot find type 'BarrierMessageRegistry'`).
Green run: 74/74 passed, 19/19 M1-026.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| code→decoder registry | `register(_:decoder:)` / `decode(_:)`; `dispatchesGoldenPayloadToRegisteredDecoderWithExactBody`, `dispatchesEachCodeWidthToItsOwnDecoder`, `dispatchDoesNotDependOnRegistrationOrder` |
| Unknown message diagnosable, no crash | `.unknown(BarrierUnknownMessageDiagnostic)`; `unknownPayloadsNeverReachDecodersAndDoNotCrash`, `emptyPayloadIsUnknown`, `emptyRegistryReportsEveryPayloadAsUnknown`, `payloadShorterThanCodeIsUnknown` |
| Code strings do not flow into Core | `BarrierMessageCode` is byte-backed, not string-backed; registry has no KVMCore dependency; diagnostic carries only `payloadByteCount` (`unknownDiagnosticCarriesOnlyAllowlistedMetadata`); `make architecture-check` passes |
| Happy path | Golden payload dispatch; multi-width dispatch; order independence |
| Boundary/limit | Payload equal to code, payload shorter than code at every length, empty payload, empty registry, codes differing in last byte |
| Invalid input/failure | `rejectsEmptyCode`, `rejectsDuplicateCode`, `rejectsCodeThatExtendsRegisteredCode`, `rejectsCodeThatIsPrefixOfRegisteredCode`, `decoderFailurePropagatesTyped` |
| Cleanup/idempotency | `failedRegistrationLeavesRegistryUnchanged`, `repeatedDecodeReturnsSameOutcome`, `decoderFailureDoesNotAffectLaterDispatch`, `registeringOnCopyDoesNotChangeOriginal` |
| Golden bytes equal exactly | `dispatchesGoldenPayloadToRegisteredDecoderWithExactBody`: body equals version bytes `00 01 00 06` and code + body equals the 11-byte `BARRIER-EVID-0002` run 0 payload |
| Fragmentation/coalescing/truncation | Not applicable to the registry: it consumes only complete payloads produced by `BarrierFrameReassembler`. Covered by M1-022 (`evidence/issues/M1-022/`). Payload-shorter-than-code is covered as a registry boundary. |
| Consistent with frozen ADR, no implied API | Internal access only; no message code, width or field layout frozen; M1-025 envelope unchanged |
| No sensitive logging | No logging; errors and diagnostics carry no code or payload bytes |
| Architecture checker, build, unit tests, no new warnings | See `commands.json` |

## Commands

See `commands.json` and `tests/`:

- `swift test --package-path Packages/BarrierCompatibility` — pass, 74 tests (19 M1-026).
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` — pass,
  `** BUILD SUCCEEDED **`. Xcode emitted the existing ambiguous-destination
  warning described by M1-005; no Swift compile warning was observed.
- `python3 Tools/Backlog/validate_package.py` — pass.
- `make architecture-check` — pass.
- `make docs-check` — pass.
- `git diff --check` — pass.
- `make verify` — pass, 24 gates.

## Known limitations

- Golden bytes are copied by hand into the test, as in M1-021/M1-022.
- The frozen M1-025 marker is used in tests only as a dispatch prefix; this is not a
  claim that it is a Barrier message code.
- Code matching is a linear scan over registered codes; acceptable for the expected
  small registry and documented, not optimized.
- Whether a specific unknown message should terminate a session is not decided here;
  it belongs to the later handshake/control issues.

## Follow-ups

1. M1-027 and later decoder issues must register only codes backed by approved
   evidence or a superseding wire-contract ADR.
2. Optional: append `BarrierMessageRegistryTests` to the M1-023 evidence register
   consumer links, following the M1-022 follow-up pattern (#301), if the register
   owner requires it.

## Rollback

Revert the M1-026 PR. No runtime resource, persisted data or migration is involved,
and no production code consumes the registry yet.
