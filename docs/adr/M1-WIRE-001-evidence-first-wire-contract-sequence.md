# M1-WIRE-001 Evidence-first Barrier Wire Contract Sequence

## Status

Accepted by Product Owner authorization on 2026-10-02, tracked in GitHub Issue #278 (M1-WIRE-001).

The evidence entry this decision appends, `BARRIER-EVID-0002`, was non-consumable as `pending-review` in the author change. A reviewer who was not the M1-WIRE-001 implementation author recorded the five-axis review in `evidence/issues/M1-WIRE-001/independent-review.md` at `2026-10-02T08:20:10Z`; the entry is now `approved` for its narrow candidate-only claims.

## Decision owners

- Barrier wire sequence and corrective scope: Product Owner
- Derived evidence approval: independent reviewer who is not the implementation author
- Wire contract freeze and the version policy decision: M1-025 owner
- Security and privacy interpretation: designated Security Reviewer

## Context

The packaged plan placed M1-025 (freeze the Barrier client wire contract) after M1-021 (bounded binary reader and writer) and M1-022 (frame reassembler). M1-021 and M1-022 both require a frozen wire contract and frozen fixtures before they start, and both stop when the contract is missing or a field is still unknown. The plan therefore could not proceed: the codec waited for the contract, and the contract waited for the codec.

[`PROTOCOL_EVIDENCE_POLICY.md`](../../MacKVM_Implementation_Package_v2/PROTOCOL_EVIDENCE_POLICY.md) orders the work the other way: register evidence, obtain sanitized fixtures, freeze layout, byte order, limits and version behavior, and only then write a parser or encoder from the frozen contract and fixtures.

M1-024 produced the approved sanitized fixture `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json`, and M1-EVIDENCE-001 registered it as `BARRIER-EVID-0001` in `evidence/registers/M1-023.json`. That entry deliberately records only uninterpreted runs and their lengths, and keeps layout, byte order, framing and version behavior unknown. M1-025 therefore had no byte-level evidence from which to freeze anything.

M1-WIRE-001 is a corrective GitHub Issue outside the canonical 70-entry `issues_manifest.json`. The package validator accepts only manifest Issue ids in `depends_on`.

## Decision

1. Append `BARRIER-EVID-0002` to `evidence/registers/M1-023.json` as a `sanitized-conformance-vector` entry derived from the approved fixture. `BARRIER-EVID-0001` is preserved byte for byte and is not rewritten, upgraded or marked `superseded`; its unknown fields stay unknown in that entry. `BARRIER-EVID-0002` pins the same fixture path, SHA-256 and byte length, introduces no new byte, and remained `pending-review` until the independent review was recorded; it is now `approved` only for the candidate-only claims that review verified. Its `relatedIssue` is `M1-024`, the producer of the bytes, because the entry contract admits canonical manifest ids only.
2. Add the deterministic derived artifact `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`. Its `derived` section is exactly the output of `derive_conformance` in `Tests/Contracts/test_m1_wire_001_contract_sequence.py` applied to the fixture bytes. It records one candidate framing interpretation, a 4-byte unsigned big-endian length prefix, which partitions every retained run with no remaining bytes; this is not proof of the prefix width, because a narrower 2-byte big-endian reading partitions every run as well. Under that candidate interpretation it records the offsets and candidate prefix values of all 11 candidate frames, the 7 marker bytes `42 61 72 72 69 65 72` (the ASCII word Barrier) at the start of the first candidate frame in each direction, and the 4 bytes `00 01 00 06` after the marker. Every other payload byte is recorded by offset and length only, and the artifact lists its limits and non-claims explicitly. The exact prefix width stays unknown and blocked pending separately approved discriminating evidence.
3. Version behavior is limited to the observed bytes and a proposal. The 4 bytes after the marker coincide with the protocol version 1.6 that the external programs reported through their own metadata; nothing about negotiation, version ranges, downgrade or other versions is observed or claimed. The exact-supported-version policy below is a proposal for M1-025 to adopt or reject.
4. Reorder the Barrier wire sequence to M1-WIRE-001 → M1-025 → M1-021 → M1-022:
   - M1-025 `depends_on` becomes `M1-024` only. Its M1-WIRE-001 prerequisite is recorded in its Preconditions and in `SOURCE_TRACEABILITY.md`, not in `depends_on`, because M1-WIRE-001 is not a manifest id.
   - M1-021 `depends_on` becomes `M1-015`, `M1-025`.
   - M1-022 keeps `M1-019`, `M1-020`, `M1-021`, so it stays after M1-021. Its Preconditions now name the frozen M1-025 contract explicitly.
   - `topological_order` rotates among the three slots only: M1-025 takes 22, M1-021 takes 36 and M1-022 takes 38. Every other order is unchanged, and every dependency still precedes its dependent.
   - The package Issue files, `issues_manifest.json`, `issues_index.csv` and `EXECUTION_ORDER.md` carry the same data.
5. `Tests/Contracts/test_m1_wire_001_contract_sequence.py` enforces all of the above with fail-closed checks and in-memory mutations, using the Python standard library only.

This decision does not change canonical or frozen product architecture: the canonical specification, `FROZEN_DECISIONS.md`, `ARCHITECTURE_GUARDRAILS.md`, `CONTRACT_CATALOG.md` and every public contract remain unchanged. It adds no Swift source, no parser, no encoder and no runtime behavior, and it freezes no wire contract.

## Candidate frame view

| Run | Direction label | Bytes | Candidate frames | Candidate length values |
|---:|---|---:|---:|---|
| 1 | server-to-client | 15 | 1 | 11 |
| 2 | client-to-server | 28 | 1 | 24 |
| 3 | server-to-client | 8 | 1 | 4 |
| 4 | client-to-server | 22 | 1 | 18 |
| 5 | server-to-client | 36 | 4 | 4, 4, 8, 4 |
| 6 | client-to-server | 16 | 2 | 4, 4 |
| 7 | server-to-client | 8 | 1 | 4 |

Under the candidate interpretation the 133 retained bytes are 44 candidate prefix bytes and 89 candidate payload bytes. Reading the first 4 bytes of each run as little-endian partitions none of the 7 runs. A narrower 2-byte big-endian reading partitions all 7 runs, because every candidate length value is below 256 and the high-order candidate prefix bytes are zero. The candidate interpretation therefore partitions the retained bytes but does not establish the prefix width, and the derived entry keeps the width unknown; M1-025 stays blocked from freezing an exact width until separately approved discriminating evidence exists.

## Proposed version policy for M1-025

Policy name: `exact-supported-version-fail-closed`.

If M1-025 adopts it, the first-party client accepts a peer only when the 4 bytes after the marker equal `00 01 00 06` exactly, and rejects any other value with a typed error before it interprets any later frame. No version range, negotiation, downgrade or fallback is proposed. M1-025 must record the adoption or rejection and its reason; it must not claim general negotiation or cross-version interoperability, which no evidence shows.

## Selected alternative

A separate append-only derived entry plus a deterministic artifact, re-derived by a test from the approved fixture, together with a three-slot reorder of the Barrier wire sequence. It gives M1-025 byte-level evidence without touching the approved capture entry and without writing any codec.

## Rejected alternatives

### Rewrite or upgrade BARRIER-EVID-0001 in place

Rejected because the register is append-only and the approved entry records what its review covered. Promoting its unknown fields would change reviewed history.

### Mark BARRIER-EVID-0001 superseded

Rejected because nothing in that entry is wrong. The derived entry adds claims over the same bytes and does not correct the capture record.

### Register the derived artifact itself as the entry fixture

Rejected because the register pins byte evidence by SHA-256 and length, and the bytes being evidenced are the approved fixture. The derived view is pinned instead by exact re-derivation from that fixture in the test.

### Freeze the wire contract in this Issue

Rejected because the freeze, its unknown and unsupported variants and its version policy belong to M1-025.

### Claim version negotiation or cross-version behavior from the observation

Rejected because one observation of one version pair cannot show negotiation, ranges, downgrade or behavior on a mismatch.

### Add M1-WIRE-001 to the manifest or to `depends_on`

Rejected because the 70-entry M1 plan stays stable and the package validator only accepts manifest ids. The prerequisite is recorded in M1-025 prose and in traceability instead.

### Keep M1-025 after M1-021 and M1-022

Rejected because it leaves the codec Issues waiting for a contract that cannot be frozen until they finish.

### Prove the framing with a parser or Swift codec

Rejected because a parser is M1-021 and M1-022 scope, and writing it before the contract is frozen would guess wire behavior.

## Security and privacy

- No new capture is made and no new byte enters the repository. The artifact and the derived entry copy no payload text other than the marker bytes; the test rejects any other printable payload text, any encoded payload, any address, path containing a username, email, host name, token, key material or certificate fingerprint in them.
- No Barrier or Deskflow source, header, constant table, generated implementation artifact or decompiled material is read, copied, linked or bundled, and the test rejects GPL-derived markers in the new documents.
- TLS was disabled only for the M1-024 observation so that payload bytes were observable. The MacKVM production TLS default stays enabled and fail-closed; this decision neither exercises nor changes it, and the test checks the canonical specification digest, frozen decision 6 and the M1-001 production TLS statement.
- Fail-safe cleanup, trust handling and privacy-safe logging requirements are unchanged.

## Compatibility

No compatibility claim is made. The evidence is one observation of one external version pair. Windows was not executed in M1 under [`M1-SCOPE-001`](M1-SCOPE-001-linux-only-validation.md), so no Windows result and no Windows Barrier Server compatibility is claimed.

The architecture boundaries stay as frozen: Swift-native macOS implementation, Barrier only inside the Protocol Adapter, `KVMEvent` as the Core and Protocol boundary, Protocol and KVM Core separation, an Input Engine independent of Barrier codes and networking, client before server, production TLS default ON, and clean-room independent implementation.

## Consequences

- M1-025 can start once this change is merged and `BARRIER-EVID-0002` is `approved`, and it decides the frame layout, the limits and the version policy only from registered `approved` evidence. `BARRIER-EVID-0002` and the derived artifact show only that the candidate interpretation partitions the retained bytes, so they are not sufficient for an exact prefix width: M1-025 must stop before freezing an exact width, and keep it unknown and blocked, unless separately approved discriminating evidence uniquely establishes it.
- That discriminating evidence is the owner-tracked follow-up blocker GitHub Issue #279 (M1-WIRE-002, Acquire discriminating Barrier length-prefix evidence), which depends on #278 and blocks M1-025 from completing an exact prefix width freeze. #279 is not complete, is outside the canonical 70-entry `issues_manifest.json` like M1-WIRE-001, and is not added to any `depends_on`; any package change it needs is decided in its own scope.
- M1-021 and M1-022 start only after M1-025 freezes and merges its ADR, and the test fails if a Barrier codec or parser Swift file appears before that ADR exists.
- `MacKVM_Implementation_Package_v2_Combined.md` and `MacKVM_Implementation_Package_v2.zip` are bootstrap snapshots that no repository tool regenerates and that earlier corrective Issues also left unchanged; they are not updated here, and the Issue files and `issues_manifest.json` stay authoritative.

## Rollback

Revert this ADR, the appended `BARRIER-EVID-0002` entry, the derived artifact, the M1-021, M1-022 and M1-025 Issue and manifest changes, `issues_index.csv`, `EXECUTION_ORDER.md`, the traceability and register documentation changes, the contract test and the M1-WIRE-001 evidence together in one change. `BARRIER-EVID-0001` needs no rollback because it is unchanged. Keep M1-025, M1-021 and M1-022 blocked until an equivalent corrective decision is accepted. If the change has already merged, the register stays append-only: the derived entry is marked `rejected` or `superseded` by a reviewed follow-up rather than deleted.

## Traceability

- GitHub Issue #278 (M1-WIRE-001)
- GitHub Issue #279 (M1-WIRE-002), the owner-tracked follow-up blocker that must supply discriminating prefix width evidence, not complete
- `evidence/registers/M1-023.json` (`BARRIER-EVID-0001` unchanged, `BARRIER-EVID-0002` appended)
- `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`
- `Tests/Contracts/test_m1_wire_001_contract_sequence.py`
- `evidence/issues/M1-WIRE-001/summary.md`
- `evidence/issues/M1-WIRE-001/independent-review.md` (reviewer deliverable; absent until the review is complete)
- [`MacKVM_Implementation_Package_v2/issues/M1/M1-025-barrier-client-wire-contract.md`](../../MacKVM_Implementation_Package_v2/issues/M1/M1-025-barrier-client-wire-contract.md)
- [`MacKVM_Implementation_Package_v2/issues/M1/M1-021-barrier-binary-codec.md`](../../MacKVM_Implementation_Package_v2/issues/M1/M1-021-barrier-binary-codec.md)
- [`MacKVM_Implementation_Package_v2/issues/M1/M1-022-barrier-frame-reassembler.md`](../../MacKVM_Implementation_Package_v2/issues/M1/M1-022-barrier-frame-reassembler.md)
- [`MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md`](../../MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md)
- [`docs/evidence/M1-023-barrier-evidence-register.md`](../evidence/M1-023-barrier-evidence-register.md)
- [`M1-SCOPE-001`](M1-SCOPE-001-linux-only-validation.md)
