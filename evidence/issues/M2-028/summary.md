# M2-028 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClipboardControlEncoder.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierClipboardControlEncoderTests.swift`,
`docs/components/M2-028-barrier-clipboard-control-encoder.md`.

## RED

Before the implementation existed the test target failed to build:
`cannot find type 'BarrierClipboardControlEncoderError' in scope`.

## GREEN

`swift test --package-path Packages/BarrierCompatibility --filter
BarrierClipboardControlEncoder`: 6 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| enter / leave / keepalive | `goldenEnter`, `normalizedEnter`, `tokens`, `singleEnter` |
| clipboard | `clipboardUnsupported` — fails closed; wire not frozen |
| size limits | `clipboardUnsupported` oversize path; `coordinates` |
| no payload logging | `clipboardUnsupported` description check |

## Blocker

Clipboard encoding is blocked: `DCLP` body is excluded by BARRIER-EVID-0005
(docs/adr/M1-PROTOCOL-002 §Excluded side-effect frames, §Non-claims).
Dependencies M2-010 and M2-012 (KVMCore flows) are not consumed by this
encoder.

## Review

Pending independent protocol review.
