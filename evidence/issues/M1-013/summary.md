# M1-013 Evidence Summary

GitHub Issue: #10

Implementation commit: `2e761d287080c3a4fc748775d22e009b0493ce9d`

## Deliverables

- `Packages/KVMContracts/Sources/KVMContracts/KVMEvent.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/KVMEventTests.swift`
- `docs/components/M1-013-kvmevent.md`
- This evidence package.

## Acceptance criteria mapping

- Focus surface: mouse movement, mouse buttons, scroll, keys, clipboard, and
  screen enter/leave are represented by one closed `KVMEvent` enum.
- Value contracts: every event and nested payload is `Sendable` and
  `Equatable`; every public event value is also `Codable`.
- Happy path: all seven event variants round-trip through JSON coding.
- Boundaries: signed scroll extrema, unknown virtual-key extrema, coordinate
  endpoints, infinities, and out-of-range decoded coordinates are covered.
- Invalid input: closed enum values outside the declared catalog fail decoding.
- Non-finite input: NaN normalizes to zero so equality remains reflexive and
  JSON encoding remains defined.
- Cancel/cleanup/idempotency: not applicable because these declarations own no
  async operation, process, file, transport, input state, or mutable resource.
- Architecture: the module imports Foundation only and contains no Barrier
  code, wire message, networking object, or platform key/input type.
- Privacy: no production logging was added; typed text and clipboard content
  remain payload data and are explicitly prohibited from diagnostics.
- Formal gates: every Required Command and all 14 cumulative repository gates
  passed at the implementation commit.

## Security and fail-safe properties

- Raw coordinates are normalized at both direct initialization and decoding.
- Unknown closed-enum values fail rather than silently selecting a behavior.
- `VirtualKey.unknown(UInt32)` preserves unmapped input without inventing a
  platform-specific key code in Core contracts.
- Strong UUID wrappers prevent accidental mixing of device, screen, and
  clipboard transaction identities.
- The value model does not perform input injection, retain pressed state,
  authorize peers, accept certificates, or move bytes over a network; those
  security and cleanup responsibilities remain with their owning Issues.

## Scope control and follow-ups

- M1-014 owns the complete identifier catalog, including `SessionID`, and may
  extract the shared declarations without changing their semantics.
- M1-052 and M1-054 own clipboard UTF-8 bounds, codec behavior, and loop guard.
- No adapter, Core router, platform mapper, transport, TLS/trust behavior,
  runtime logging, or UI was implemented here.

## Rollback

Revert the M1-013 PR and block dependent contract, adapter, Core, and platform
work until C-001 and its tests are restored. There is no persisted data,
runtime input state, trust state, or migration to clean up.
