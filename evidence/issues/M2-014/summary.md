# M2-014 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/EmergencyEscape.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/EmergencyEscapeTests.swift`,
`docs/components/M2-014-emergency-escape.md`.

## RED

Before the implementation existed: `cannot find 'EmergencyEscape' in scope`.

## GREEN

`swift test --filter EmergencyEscape`: 4 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| fixed, documented escape gesture | `chordMatches`, `nonMatches`, M2-001 ADR |
| local restored even if network/thread fails | `escapeIsLocalFirst` (best-effort sends only) |
| no dependency on remote acknowledgement | reducer reaches `local` in one step |

## Deviations

Dependencies M2-013 and M1-063 are not merged; the executor of `restoreLocal`
is M2-033. Real-hardware verification not performed.

## Review

Pending independent review.
