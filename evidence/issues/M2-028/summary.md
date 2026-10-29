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

## Addendum (2026-10-29): clipboard transfer

The blocker above is resolved by the M2-022 punctuation and clipboard capture
(`evidence/e2e/M2-022/punctuation-clipboard.md`). `clipboard(_:limit:)` now
returns the `DCLP` transfer of clipboard 0 with sequence 0, and
`BarrierClipboard.swift` holds the codec and assembler. RED: the clipboard test
failed to build against the old method (`binary operator '==' cannot be applied
to operands of type '()' and '[UInt8]'`), and the byte order mark test failed
because the old decoder dropped U+FEFF. GREEN: `swift test --package-path
Packages/BarrierCompatibility`: 241 tests in 8 suites passed. Full gates at
`cba4ca8` are in `evidence/issues/M2-032/commands.json`.

## Review

Pending independent protocol review.
