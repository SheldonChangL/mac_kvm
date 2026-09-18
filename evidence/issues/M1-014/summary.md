# M1-014 Evidence Summary

GitHub Issue: #13

Implementation commit: `082ff1843d8a4fa8e562d6caa74d2cef8e287b59`

## Deliverables

- `Packages/KVMContracts/Sources/KVMContracts/DomainIdentifiers.swift`
- `Packages/KVMContracts/Sources/KVMContracts/KVMEvent.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/DomainIdentifiersTests.swift`
- `docs/components/M1-014-domain-identifiers.md`
- This evidence package.

## Acceptance criteria mapping

- Focus surface: separate `DeviceID`, `ScreenID`, and `SessionID` structs wrap
  UUID values and prevent cross-domain or raw string/UUID substitution.
- Value contracts: compile-time generic constraints verify all three types are
  `RawRepresentable` over UUID, `Codable`, `Hashable`, and `Sendable`.
- Compatibility: the existing `DeviceID` and `ScreenID` declarations were
  extracted without semantic changes; the complete KVMEvent suite still passes.
- Happy path: fixed identifiers preserve their UUIDs and round-trip through
  synthesized Codable.
- Boundaries: all-zero and all-maximum UUID values round-trip unchanged.
- Invalid input: malformed UUID payloads fail with `DecodingError` for every
  identifier type.
- Cancel/cleanup/idempotency: not applicable because these immutable values own
  no async operation, stateful resource, input state, or lifecycle.
- Architecture: no protocol code, wire token, networking object, platform input
  type, or dependency was introduced.
- Privacy: no logging or diagnostic surface was added.
- Formal gates: all Required Commands and all 17 cumulative repository gates
  passed at the implementation commit.

## Security and fail-safe properties

- Invalid serialized UUIDs fail decoding instead of producing a fallback
  identity.
- Identifier construction does not authorize, trust, connect, route, or inject
  input; those security decisions remain with their owning Issues.
- No typed text, clipboard payload, credential, key material, or private data is
  logged or stored by these types.

## Scope control and follow-ups

- Only the four corrected Exact Files contain implementation/test/docs changes.
- Evidence files are added solely because the Issue explicitly requires the
  `evidence/issues/M1-014/` package.
- Identifier persistence, display names, protocol encoding, trust, routing, and
  session lifecycle remain out of scope.

## Rollback

Revert the M1-014 PR, remove `SessionID`, restore the unchanged `DeviceID` and
`ScreenID` declarations to `KVMEvent.swift`, and block dependent Issues. No
persisted state, runtime input state, trust state, or migration requires cleanup.
