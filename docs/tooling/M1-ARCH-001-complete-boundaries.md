# M1-ARCH-001 Complete Architecture Boundary Enforcement

## Trigger

The independent M1-002 backfill review found that the accepted ADR requires more than the initial M1-010 token/import checks. In particular, `KVMCore` could import `Network`, and protocol modules could import or own concrete networking and platform implementations while `make architecture-check` remained green.

Issue #234 is the blocking corrective owner. This change strengthens the checker; it does not weaken or revise the M1-002 ADR.

## Enforced boundaries

The source checker now fails closed when it finds:

- `KVMCore` importing protocol adapters, concrete Apple networking modules, or macOS input frameworks;
- `KVMContracts` importing protocol, platform, or concrete networking modules;
- `KVMContracts` naming reviewed macOS, Windows, X11, evdev, or Wayland key/input types;
- Barrier or Native protocol modules importing `MacPlatform` or macOS input frameworks;
- Barrier or Native protocol modules importing concrete Apple networking modules;
- Barrier or Native protocol modules naming reviewed concrete stream/socket types or calling POSIX `socket` directly;
- platform backends importing protocol implementation modules; or
- Barrier wire identifiers outside `BarrierCompatibility`, including platform backends.

The SwiftPM graph verifier remains the authority for target dependency edges. These source rules close system-module and concrete-type paths that the manifest alone cannot express.

## Explicit catalogs

The checker uses reviewed, finite import/type/token catalogs. It does not guess future Native Protocol wire names because no canonical Native wire identifiers exist yet. The Issue that first freezes such identifiers must add them to the checker with a negative platform-backend test in the same PR. Until then, inventing a Native wire identifier is prohibited by the frozen decision process rather than silently inferred by a regex.

Identifiers are checked throughout Swift source, including comments and string literals. This deliberately keeps concrete networking/platform vocabulary out of contracts and protocol implementations; an owning adapter or transport implementation may document those details in its own module.

## Compatibility, security, and rollback

No Swift product behavior, public API, wire format, TLS policy, or platform mapping changes. Allowed `Foundation`, `KVMContracts`, and abstract `Transport` vocabulary continue to pass.

Rollback by reverting the corrective PR. Do not roll back by weakening M1-002, the canonical architecture, TLS defaults, or fail-safe behavior.
