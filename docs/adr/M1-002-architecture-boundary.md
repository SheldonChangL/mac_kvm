# M1-002 KVMEvent, Adapter and Core Architecture Boundary

## Status

Accepted for implementation under the M1 product contract. M1 Bootstrap Exception review applies until the formal repository gates are available.

## Context

MacKVM must interoperate with Barrier during M1 and M2 without allowing Barrier wire concepts to define the application. Canonical specification §60–62 requires protocol packets to cross an adapter boundary, become `KVMEvent`, and only then enter KVM Core or a platform engine.

The authoritative inputs are:

1. [`CANONICAL_SPEC_SECTIONS_60_64.md` §60–62](../spec/CANONICAL_SPEC_SECTIONS_60_64.md#60-long-term-protocol-architecture)
2. [`M1-001-product-contract.md`](M1-001-product-contract.md)
3. [`FROZEN_DECISIONS.md`](../../MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md), especially decisions 3–9
4. [`CONTRACT_CATALOG.md`](../../MacKVM_Implementation_Package_v2/CONTRACT_CATALOG.md), contracts C-001, C-002 and C-003
5. [`ARCHITECTURE_GUARDRAILS.md`](../../MacKVM_Implementation_Package_v2/ARCHITECTURE_GUARDRAILS.md)

This ADR freezes module ownership and dependency direction. It does not choose Barrier bytes, native encoding, socket framing or platform key mappings.

## Decision

### Canonical event boundary — C-001

`KVMEvent` is the only event language accepted by KVM Core. It contains platform-neutral representations of:

- mouse position and buttons
- scroll deltas
- virtual keys, key phases and modifier state
- bounded clipboard payloads and origin metadata
- screen enter/leave control and normalized coordinates

The contract must not contain:

- Barrier or Deskflow message identifiers such as `DKDN`, `DMMV`, `CINN` or `COUT`
- macOS `CGKeyCode`
- Windows virtual-key or scan codes
- Linux evdev, X11 or Wayland-specific codes
- socket handles, `NWConnection`, raw protocol frames or TLS objects

Unknown protocol or platform values are mapped to an explicit platform-neutral unknown representation at their owning adapter boundary. They are not silently discarded or leaked into Core as vendor-specific types.

### Transport boundary — C-002

`Transport` is an ordered byte-stream abstraction responsible only for:

- connecting and disconnecting
- sending bytes
- yielding incoming bytes
- reporting typed transport failures and cancellation

Transport does not interpret frames, events, screen routing or input state. Protocol codecs do not open sockets directly. Production transport security remains TLS default ON, but the exact TLS and trust implementation belongs to its designated Issue.

### Session boundary — C-003

`KVMProtocolSession` converts between protocol traffic and `KVMEvent`. It is responsible for:

- protocol handshake and lifecycle
- framing and bounded codec invocation
- version/capability behavior defined by the selected protocol
- emitting decoded `KVMEvent` values
- encoding outbound `KVMEvent` values
- mapping protocol, transport and security termination into typed session outcomes

KVM Core depends on the `KVMProtocolSession` contract, never a concrete Barrier or Native Protocol session.

### Module ownership

| Concern | Owning module | Allowed dependencies | Prohibited dependencies |
|---|---|---|---|
| Shared events and identifiers | `KVMContracts` | Foundation value types | protocol codes, OS input frameworks, networking implementations |
| Product state and routing | `KVMCore` | `KVMContracts` | `BarrierCompatibility`, `NativeProtocol`, CoreGraphics, AppKit input APIs, socket implementations |
| Barrier framing and mapping | `BarrierCompatibility` | `KVMContracts`, abstract `Transport`/session contracts | KVM Core internals, platform injection APIs |
| First-party protocol framing and mapping | `NativeProtocol` | `KVMContracts`, abstract `Transport`/session contracts | KVM Core internals, platform injection APIs |
| macOS capture/injection/clipboard | `MacPlatform` | `KVMContracts`, native macOS frameworks | Barrier or Native Protocol message codes and concrete sessions |
| Application presentation | macOS app shell | Core state and intent interfaces | protocol parsing, socket state machines, direct input-hook policy |

### Dependency direction

The required dependency graph is one-way:

```text
App shell
   ↓
KVM Core ───────────────→ KVMContracts
   ↑                            ↑
Protocol session adapters ─────┤
   ↑                            │
Transport implementations      │
                                │
Platform backends ──────────────┘
```

Concrete application composition may construct a Core instance, a protocol session and platform backends. Construction does not permit Core to import or downcast to those concrete implementations.

### Runtime data flow

Inbound input follows:

```text
Transport bytes
  → bounded frame decoder
  → Barrier or Native Protocol Adapter
  → KVMEvent
  → KVM Core routing/state
  → platform-neutral backend intent
  → macOS Input or Clipboard Engine
```

Outbound input follows the reverse adapter path, but platform values must first become a platform-neutral `KVMEvent`; protocol code never consumes `CGEvent`, `CGKeyCode` or pasteboard objects.

### Failure and cleanup boundary

- Malformed, unknown and oversized frames are rejected in the protocol adapter before entering Core.
- Allocation limits are checked before allocating payload storage.
- Transport errors are surfaced to the session, which produces a typed terminal outcome for Core.
- Terminal, timeout, cancellation and security-rejection paths trigger idempotent input cleanup through platform-neutral safety interfaces.
- Cleanup cannot depend on a successful network response or UI availability.
- Callback and event-tap paths enqueue bounded work and never wait for network operations.

### Enforcement

M1-010 will provide automated import/dependency enforcement. The checker must reject at least:

- `KVMCore` importing `BarrierCompatibility`, `NativeProtocol`, Network.framework or OS input frameworks
- protocol modules importing platform injection/capture implementations
- `KVMContracts` declaring Barrier message codes or platform key-code types
- platform backends referencing Barrier/Native wire message identifiers
- protocol codecs constructing or owning concrete sockets instead of depending on `Transport`

Until M1-010 is available, review and targeted source scans are the bootstrap enforcement mechanism.

## Selected versus rejected alternatives

### Selected: ports-and-adapters boundary using KVMEvent

Selected because it directly implements canonical §60–62 and allows Barrier, a first-party Native Protocol and future adapters to coexist without changing Core.

### Rejected: Barrier-derived domain model

Rejected because message names and wire fields would become application semantics, making later Native Protocol replacement invasive and error-prone.

### Rejected: protocol sessions call platform input APIs directly

Rejected because it couples codec/network lifecycle to key mapping, input permission and fail-safe behavior, preventing isolated testing and safe reuse.

### Rejected: Core owns raw bytes and selects a codec

Rejected because Core would depend on framing and protocol negotiation. The session adapter must deliver only `KVMEvent` and typed lifecycle outcomes.

### Rejected: one universal platform key-code field

Rejected because macOS, Windows and Linux key spaces and layout semantics differ. `VirtualKey` remains platform-neutral; each platform adapter owns conversion.

## Consequences

### Positive

- Core routing and state reducers can be deterministic and protocol-independent.
- Platform input behavior can be tested without networking.
- Protocol conformance and platform conformance can evolve independently.
- Barrier can be disabled or removed without changing Core APIs.
- Security and resource limits are enforced at the earliest owning boundary.

### Costs

- Each protocol and platform requires explicit mapping layers.
- Unknown-value and error mapping policies must be specified and tested.
- Application composition must wire several narrow interfaces rather than using a monolithic session object.
- Cross-platform conformance requires canonical vectors rather than sharing platform-native codes.

## Security impact

- Raw network data remains untrusted until bounded decoding and validation complete.
- Protocol-specific attack surface stays outside KVM Core and platform injection logic.
- TLS remains the production default; this ADR does not authorize plaintext fallback.
- No layer may log typed text, clipboard payloads, private keys or reconstructable user content.
- Input cleanup and local restoration remain available even when transport or protocol state is corrupt.

## Compatibility impact

- Barrier compatibility is implemented as an adapter, preserving interoperability without becoming a Core dependency.
- The same `KVMEvent` semantics are used by the first-party Native Protocol.
- Platform-specific key and coordinate behavior is adapted at platform boundaries, allowing OS-specific correctness without contaminating wire contracts.
- Changes to C-001, C-002 or C-003 require a dedicated contract/ADR change; they cannot be introduced incidentally by a protocol or platform Issue.

## Deferred decisions with owners and blockers

| Decision | Owner | Blocking Issue |
|---|---|---|
| Exact `KVMEvent` cases and value invariants | Contracts owner | M1-013 |
| Final Transport interface semantics | Contracts/transport owner | M1-017 |
| Final session lifecycle implementation | Protocol session owner | M1-016 |
| Barrier client wire representation | Protocol owner plus fixture reviewer | M1-025 |
| Native wire representation | Architecture and Security reviewers | M3-003 through M3-005 |
| Automated boundary checker rules | Architecture/tooling owner | M1-010 |

These questions do not change the dependency rules frozen here. The listed Issue must decide them before its dependent implementation begins.

## Rollback

If an implementation violates this boundary:

1. Stop the violating feature from advancing to dependent Issues.
2. Move protocol-specific conversion back into its protocol adapter.
3. Move platform-specific conversion back into its platform backend.
4. Restore Core dependencies to `KVMContracts` and internal Core modules only.
5. Add a boundary regression check before re-enabling the feature.

Rollback must not weaken TLS, decoder bounds, privacy-safe logging or fail-safe input cleanup. Changing this architecture requires a superseding ADR and explicit Product Owner approval.

## Acceptance record

- M1-001 dependency: merged by PR #218.
- Canonical source: §60–62 present and SHA-256-verified in M1-001.
- Contract references: C-001, C-002 and C-003 reviewed against the reference Swift package.
- Bootstrap review: permitted by explicit Product Owner exception for M1-001–M1-003 only.
- Formal follow-up: rerun repository gates and obtain independent Critical/High review after M1-004–M1-008 establish them and before declaring M1 complete.
