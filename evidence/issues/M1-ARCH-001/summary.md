# M1-ARCH-001 Evidence Summary

GitHub Issue: #234

Implementation commits: `45fccf31c64ebae40c4a20a9ed6944745ffdba4b`, `7ca7b7a2e78a74c18597078a3e7ad7508b17b481`, `24860cc81894bf0d77e6c1bbef063ab8d95b045b`

## Trigger and disposition

The independent M1-002 backfill review found one unresolved High: the accepted ADR requires `KVMCore` networking isolation and protocol/platform/concrete-socket enforcement that the initial architecture checker did not fully implement. This corrective change preserves the ADR and expands the gate to cover its presently enforceable boundaries.

## Deliverables

- `Network`, `NetworkExtension`, and `CFNetwork` import rejection in KVMCore.
- Protocol-to-platform import rejection.
- Protocol concrete-network imports, concrete Foundation/Network stream/socket ownership, and direct POSIX `socket` rejection.
- KVMContracts protocol/platform/network import plus reviewed platform key/input type and key-code rejection.
- Platform-to-protocol import rejection and existing Barrier wire-token containment.
- Scoped, attributed, and access-controlled Swift import parsing.
- Explicit documented obligation to add canonical Native wire identifiers when their defining Issue freezes them; no wire name is guessed here.

## Acceptance criteria

- Initial TDD run: 23 tests, 8 expected failures proving the missing rules.
- First independent re-review retained the High after proving five remaining false negatives; those cases were added as a second TDD red set.
- Second independent re-review retained the High for Core Foundation socket streams and found a Medium for `WinSDK`/`XF86XK`; all named cases received negative tests and enforcement.
- Final architecture checker suite: 26/26 passed.
- `make architecture-check`: passed.
- Full local `make verify`: 11/11 gates passed on native arm64 with Swift 6.2.3.
- No product runtime, public API, protocol bytes, platform mapping, TLS/security default, or frozen decision changed.

## Scope and rollback

The checker, focused tests, tooling decision note, evidence, and handoff are the minimal scope owned by Issue #234. SwiftPM graph verification remains authoritative for target dependency edges.

Rollback is a single PR revert. Do not roll back by weakening M1-002. No runtime state or user-data migration exists.

## Remaining verification

Independent read-only re-review of `24860cc` reports Critical 0 / High 0 / Medium 0 / Low 0 and marks the original M1-002 High fully resolved. Protected PR-head CI, zero-annotation inspection, five-axis merge review, protected merge, and post-merge main CI remain required.
