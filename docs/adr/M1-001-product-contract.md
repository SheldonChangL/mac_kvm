# M1-001 Product Contract and Barrier Exit Criteria

## Status

Accepted by Product Owner for implementation on 2026-09-14. Independent C/H review evidence remains required before M1-001 may be closed or merged.

## Decision owners

- Product contract: Product Owner
- Security interpretation: designated Security Reviewer
- Manual evidence and milestone exit: designated QA/Human Reviewer who is not the implementing agent

## Context

MacKVM must begin with a low-risk, independently implemented Barrier-compatible macOS client without allowing Barrier to become the application architecture. The product must remain able to replace or coexist with protocols behind a stable, platform-neutral core boundary.

The binding sources, in order, are:

1. [`CANONICAL_SPEC_SECTIONS_60_64.md`](../spec/CANONICAL_SPEC_SECTIONS_60_64.md), especially §60–64.
2. [`FROZEN_DECISIONS.md`](../../MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md), but only its explicitly frozen decisions.
3. [`PRODUCT_ROADMAP.md`](../../MacKVM_Implementation_Package_v2/PRODUCT_ROADMAP.md) for sequencing.
4. [`SOURCE_TRACEABILITY.md`](../../MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md) as an index only.

## Selected product contract

### Architecture boundary

- The macOS application is implemented natively in Swift. SwiftUI and AppKit may form the application shell, while platform integration uses native macOS APIs.
- `KVMEvent` is the single platform-neutral event boundary between protocol adapters and KVM Core.
- KVM Core owns session, screen routing, input routing, clipboard routing and product state. It does not parse or emit Barrier message codes.
- Barrier exists only inside an independently implemented Protocol Adapter. Barrier packets are converted to or from `KVMEvent` at that boundary.
- Protocol framing/codecs and networking transports are separate concerns. KVM Core and Input Engine do not depend on a socket implementation.
- Input Engine accepts platform-neutral events and owns platform mapping/injection behavior. It does not depend on Barrier tokens, message codes or networking implementation.
- Clipboard and platform input APIs remain behind platform adapters rather than entering protocol or core contracts.

Required flow:

```text
Barrier packet or future native frame
                 ↓
           Protocol Adapter
                 ↓
              KVMEvent
                 ↓
        KVM Core / Routers
                 ↓
    Input or Clipboard Engine
                 ↓
        Native platform APIs
```

### Delivery contract

#### MacKVM 0.1 / M1 — Mac Client MVP

- Apple Silicon-native macOS client written in Swift.
- Connects to existing Windows and Linux Barrier servers through the Barrier Protocol Adapter.
- Delivers mouse movement, mouse buttons, keyboard, scroll and UTF-8 plain-text clipboard.
- Production behavior uses TLS by default; insecure TCP is not a production fallback.
- Provides reconnect behavior, fail-safe input cleanup and a minimal menu-bar status surface.
- This milestone validates the client and architecture; it is not a claim that MacKVM has replaced Barrier.

#### MacKVM 0.2 / M2 — Mac Server MVP

- Adds the first-party macOS server after the client path has been validated.
- Adds screen switching, safe local/remote input transitions and multi-device routing.
- Uses Barrier clients only as an early interoperability and risk-reduction path.
- This milestone is not a claim that MacKVM has replaced Barrier.

#### MacKVM Native Alpha and cross-platform Beta / M3–M4

- M3 introduces the first-party Native Protocol and proves first-party Mac Server ↔ Mac Client operation with Barrier disabled.
- M4 delivers first-party Windows and Linux applications and cross-platform Native Protocol conformance.
- Barrier becomes an optional build/runtime compatibility module rather than the default product path.

#### MacKVM 1.0 / M5

- First-party Server and Client applications use the first-party Native Protocol as the default complete path.
- Discovery, pairing, trust/revoke, clipboard, screen layout, reconnect, permissions, autostart and signed production distribution satisfy their milestone gates.
- Barrier remains optional compatibility functionality only; removing or disabling it does not break the promised 1.0 workflow.

### Meaning of “replace Barrier”

MacKVM may claim that it replaces Barrier only after M5-028 has recorded all of the following evidence:

1. Every promised 1.0 scenario works from a first-party Server to a first-party Client using the Native Protocol.
2. The scenarios pass with BarrierCompatibility removed or disabled at build and runtime.
3. KVM Core, Input Engine and platform backends contain no Barrier message codes, types or hidden Barrier process dependency.
4. Security, privacy, compatibility, fault, performance and release gates pass with reviewer-verifiable evidence.
5. Product Owner, Security and QA record an explicit Go decision.

Before those conditions are met, releases must use milestone-accurate wording such as “Barrier-compatible client”, “Barrier-compatible server” or “Native Protocol alpha”; they must not claim full replacement.

## Rejected alternatives

### Embed or launch the Barrier executable

Rejected because it makes Barrier part of the product runtime, conflicts with independent implementation policy and prevents clean replacement.

### Put Barrier messages or types in KVM Core

Rejected because it binds routing, state and platform behavior to one wire protocol and breaks the §60–63 architecture.

### Let Input Engine depend on networking or protocol tokens

Rejected because keyboard mapping, injection and input safety must be independently testable and reusable across protocols.

### Implement Server before Client

Rejected for M1 because the client has lower technical risk and can be validated against existing Barrier servers before adding event capture and suppression risks.

### Permit insecure TCP by default in production

Rejected. Development-only diagnostics may be specified by a later security-reviewed issue, but production behavior remains TLS default ON and fail closed.

### Declare Barrier replacement after M1 or M2

Rejected because those milestones deliberately depend on external Barrier peers and do not prove the first-party Native Protocol product path.

## Consequences

### Positive

- Protocols can coexist or be replaced without rewriting KVM Core or platform input logic.
- Early Barrier interoperability reduces client/server validation risk.
- Native Protocol and platform implementations can share canonical events and conformance vectors.
- The replacement claim becomes evidence-based rather than branding-based.

### Costs and constraints

- Barrier compatibility and Native Protocol require separate adapters and test fixtures.
- Cross-platform key, coordinate and clipboard semantics require explicit normalization contracts.
- M1/M2 are transitional deliverables and cannot be marketed as the final architecture.
- Security and real-device evidence remain mandatory even when automated tests pass.

## Security impact

- TLS is enabled by default for production behavior.
- Unknown, changed or revoked identities fail closed according to later frozen trust contracts.
- Protocol decoders must enforce bounds before allocation; this ADR does not select wire bytes or encoding.
- All terminal paths must release pressed keys/buttons and restore local input.
- Logs and diagnostics must not contain typed text, clipboard payloads, passwords or key material.

## Compatibility impact

- M1 and M2 intentionally interoperate with existing Barrier peers through an adapter.
- Core behavior stays protocol-neutral so Deskflow-compatible or future protocols can be added without changing KVMEvent semantics.
- Native Protocol becomes the first-party default beginning with its gated rollout; Barrier compatibility remains optional for users who need it.

## Deferred decisions with owners and blockers

| Decision | Owner | Blocking issue |
|---|---|---|
| Exact Barrier client wire bytes | Protocol owner plus captured-fixture reviewer | M1-025 |
| Exact Barrier server wire bytes | Protocol owner plus captured-fixture reviewer | M2-023 |
| Native transport baseline | Architecture and Security reviewers | M3-003 |
| Native encoding and canonicalization | Architecture and Security reviewers | M3-004 |
| Windows/Linux toolchain and FFI | Cross-platform architecture owner | M4-001 |
| Wayland and privileged uinput support | Linux platform and Security reviewers | M4-029 and M4-030 |
| Signed update and rollback format | Release and Security reviewers | M5-020 |

These decisions do not block accepting M1-001. They block the named downstream work and must not be inferred from this ADR.

## Rollback

If implementation diverges from this contract:

1. Disable or revert the violating adapter or feature without weakening TLS, trust or input cleanup.
2. Restore the `KVMEvent` and adapter boundary before resuming feature work.
3. Do not redefine acceptance criteria to fit the implementation.
4. If the product contract itself must change, create a superseding ADR and update the canonical specification through an explicit Product Owner decision.

Rollback must never introduce insecure production transport, silent identity acceptance, stuck input, local-input suppression or disclosure of user content.

## Acceptance record

- Canonical source integrity: SHA-256 verified from the Product Owner-provided unblock package on 2026-09-14.
- Product Owner direction: treat `CANONICAL_SPEC_SECTIONS_60_64.md` as M1-001 canonical source and continue M1-001, received 2026-09-14.
- Implementing agent: Codex; not authorized to provide independent C/H review or merge approval.
- Required before closure/merge: a non-implementing reviewer must verify the source mapping, decision interpretation and manual evidence requirement.
