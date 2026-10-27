# M2-029-FOLLOWUP-001 Evidence Summary

## Scope (outside Exact Files; new files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierServerProtocolSession.swift`
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierServerProtocolSessionTests.swift`
- `Tests/Integration/M2ServerControlPathIntegrationTests.swift`
- `docs/components/M2-029-FOLLOWUP-001-barrier-server-protocol-session.md`

## Process note (TDD deviation, recorded honestly)

The adapter draft was written before its tests. RED was then established by
moving the implementation out of the tree: the test target failed with
`cannot find type 'BarrierServerProtocolSession' in scope`. The integration
test's first run failed on a wrong byte offset in the test itself (token is at
`suffix(14)`, not `suffix(10)`); production was unchanged by that fix.

## GREEN

- `swift test --package-path Packages/BarrierCompatibility --filter
  BarrierServerProtocolSession`: 8 passed; 5 repeated runs passed.
- `swift test --filter M2ServerControlPath`: 1 passed; 3 repeated runs passed.
- Full gates in `commands.json`.

## Review

Requires reviewer acceptance of the out-of-scope file or a backlog Issue.
