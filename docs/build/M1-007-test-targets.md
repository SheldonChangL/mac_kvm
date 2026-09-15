# M1-007 Test Targets and Fixture Layout

## Outcome

M1-007 creates three SwiftPM test layers and empty Barrier/Native fixture roots. It adds test infrastructure only; it does not add production behavior, protocol bytes, captures, platform permission access, or public contracts.

## Test targets

| Target | Path | Direct dependencies | Execution policy |
|---|---|---|---|
| `MacKVMUnitTests` | `Tests/Unit` | `KVMContracts`, `KVMCore` | Pure tests only; OS permission frameworks are prohibited. |
| `MacKVMIntegrationTests` | `Tests/Integration` | Contracts, Core, Barrier and Native adapters | Runs with ordinary `swift test`; no external peer is required by the scaffold. |
| `MacKVMSystemTests` | `Tests/SystemTests` | Contracts, Core, both adapters, MacPlatform | Individual system tests may use `.disabled(...)` until an owning Issue supplies explicit opt-in and required environment evidence. |

Disabled system tests must explain the missing opt-in/environment. They must not silently return success, weaken assertions, or be counted as executed E2E evidence.

## Fixture layout and metadata

```text
Tests/Fixtures/
├── fixture-metadata.schema.json
├── Barrier/
└── Native/
```

Every future fixture uses its own `<fixture-id>/metadata.json` and a relative payload path. Metadata schema version 1 records fixture identity, protocol, provenance, payload SHA-256/byte length, and sanitization status. It rejects unknown top-level fields, parent-directory traversal, and metadata that says sensitive data is present.

The schema is a test-data governance format, not a wire contract. It does not select Native encoding or assert Barrier bytes. The owning evidence/capture Issues must provide reproduction steps and validate the actual payload hash and redaction before committing a fixture.

## Verification

Run:

```bash
Tools/verify/M1-007-test-targets.sh
```

The verifier checks exact test target names, paths, dependencies, permission-free Unit imports, system skip annotation, fixture schema safety invariants, and an arm64 `swift test` run. Missing roots, malformed schemas, excess arguments, or prohibited configuration fail non-zero.

## Cleanup and rollback

The scaffold creates no runtime resource, task, socket, event tap, input state, or persistent user data, so runtime cancellation/cleanup is not applicable. Revert the M1-007 PR to remove the targets and fixture format; later tests that depend on them must remain blocked until the scaffold is restored.
