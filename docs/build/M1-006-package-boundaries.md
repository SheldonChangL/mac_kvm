# M1-006 Swift Package Boundaries

## Outcome

M1-006 establishes compile-time targets and a one-way dependency graph without defining any new public contract or behavior.

## Target graph

```text
MacKVM app shell
├── KVMCore ───────────────→ KVMContracts
├── BarrierCompatibility ──→ KVMContracts
├── MacPlatform ───────────→ KVMContracts
└── NativeProtocol ────────→ KVMContracts
```

| Target | Allowed direct dependencies in M1-006 | Prohibited direct dependencies |
|---|---|---|
| `KVMContracts` | none | all implementation targets, networking, platform frameworks |
| `KVMCore` | `KVMContracts` | protocol adapters, platform implementation, concrete networking |
| `BarrierCompatibility` | `KVMContracts` | KVM Core internals, Native Protocol, platform implementation |
| `NativeProtocol` | `KVMContracts` | KVM Core internals, Barrier compatibility, platform implementation |
| `MacPlatform` | `KVMContracts` | protocol adapters, concrete protocol sessions |
| `MacKVM` | assembly dependencies shown above | protocol parsing or platform behavior in app source |

The dependency declarations make targets available for later owning Issues. Their source files intentionally contain comments only: M1-013 owns the concrete `KVMEvent` contract, M1-016 owns session behavior, M1-017 owns Transport, and M1-023/M1-025 gate Barrier evidence and wire behavior.

## Verification

Run:

```bash
Tools/verify/M1-006-package-boundaries.sh
```

The verifier parses `swift package dump-package` as JSON, checks the required graph, checks that the app target assembles all five boundaries, and builds every target for arm64. Missing roots, targets, or invalid dependency edges produce non-zero exits.

M1-010 will add source-level import/token enforcement. M1-006 does not pretend that the manifest alone can detect imports, hidden wire tokens, or platform APIs.

## Security and compatibility

- No Barrier/Deskflow implementation, protocol byte, key material, trust state, logging payload, or user data is added.
- Barrier and Native Protocol targets cannot depend on each other or call platform input code through the declared graph.
- KVM Core cannot depend on either protocol adapter or MacPlatform.
- The same `KVMContracts` boundary is reserved for all protocol and platform adapters.

## Failure and cleanup

The verifier is read-only except for ignored SwiftPM build output. Invalid manifests and builds fail closed. No runtime session, callback, socket, permission, input state, or persistent application data exists, so runtime cancellation/cleanup is not applicable.

## Rollback

Revert the M1-006 PR. Later Issues that depend on these targets must remain blocked until the graph is restored; no user data or public contract migration is required.
