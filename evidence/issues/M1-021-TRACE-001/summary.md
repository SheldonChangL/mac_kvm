# M1-021-TRACE-001 Evidence Summary

GitHub Issue: #298

Base commit: `840dc9c4d1646d756bc9b8c9b6959de5312de14e` (after M1-021, PR #299)

Status: **implemented and locally verified**.

## Scope

Link the M1-021 bounded codec tests into the M1-023 evidence register consumer
lists for the evidence they directly consume:

- `BARRIER-EVID-0002`: derived marker/version golden frame evidence.
- `BARRIER-EVID-0003`: exact 4-byte big-endian top-level length-prefix evidence.

## Changes

- `evidence/registers/M1-023.json`: adds
  `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierBinaryCodecTests.swift`
  to `consumingTests` for `BARRIER-EVID-0002` and `BARRIER-EVID-0003`.
- `evidence/issues/M1-023/tests/test_register.py`: asserts the M1-021 codec
  consumer links and asserts `BARRIER-EVID-0001` is not linked.
- `Tests/Contracts/test_m1_wire_001_contract_sequence.py`: updates the
  `BARRIER-EVID-0002` consumer-link pin.
- `Tests/Contracts/test_m1_wire_002_length_prefix_evidence.py`: updates the
  `BARRIER-EVID-0003` consumer-link pin.
- `docs/evidence/M1-023-barrier-evidence-register.md`: documents the
  M1-021 codec consumer links.
- `evidence/issues/M1-021-TRACE-001/`: this evidence package.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Register links M1-021 codec tests to relevant Barrier evidence | `M1-023.json` entries for `BARRIER-EVID-0002` and `BARRIER-EVID-0003` |
| No frozen contract, ADR, codec behavior or fixture bytes changed | Diff is limited to consumer links, tests, docs and this evidence package |
| Evidence register tests pass | `python3 evidence/issues/M1-023/tests/test_register.py` |
| Existing contract pins updated | `python3 Tests/Contracts/test_m1_wire_001_contract_sequence.py` and `python3 Tests/Contracts/test_m1_wire_002_length_prefix_evidence.py` |
| Full repository gates pass | `make verify` passed with 24 gates, including `evidence-test:M1-023/tests/test_register.py` and `swift-package-test:BarrierCompatibility` |

## Non-goals

- No wire contract content is changed.
- No evidence claim, fixture digest, provenance, limitation, unknown field or
  prohibited inference is changed.
- No Swift runtime behavior, parser, codec, networking, TLS, UI or platform
  behavior is implemented.

## Review notes

- `BARRIER-EVID-0001` is intentionally not linked because M1-021 consumes the
  derived golden frame/vector and the exact width-discrimination evidence, not
  the uninterpreted raw handshake runs.
- This is an in-place consumer-link update, matching the existing M1-025
  consumer-link workflow: it does not rewrite evidence content.

## Rollback

Revert this PR. M1-021 remains implemented, but downstream issues must not rely
on the register as proving M1-021 traceability until the consumer links are
restored.
