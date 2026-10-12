# M1-022-TRACE-001 Evidence Summary

GitHub Issue: #301

Base commit: `c7182fe9634d1c086bbdfec6ec942a3f9fbcd730` (after M1-022, PR #302)

Status: **implemented and locally verified**.

## Scope

Link the M1-022 frame reassembler tests into the M1-023 evidence register
consumer lists for the evidence they directly consume:

- `BARRIER-EVID-0002`: derived golden frame marker/version evidence.
- `BARRIER-EVID-0003`: exact 4-byte big-endian top-level length-prefix evidence.

## Changes

- `evidence/registers/M1-023.json`: adds
  `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierFrameReassemblerTests.swift`
  to `consumingTests` for `BARRIER-EVID-0002` and `BARRIER-EVID-0003`.
- `evidence/issues/M1-023/tests/test_register.py`: asserts the M1-022
  reassembler consumer links and asserts `BARRIER-EVID-0001` is not linked.
- `Tests/Contracts/test_m1_wire_001_contract_sequence.py`: updates the
  `BARRIER-EVID-0002` consumer-link pin.
- `Tests/Contracts/test_m1_wire_002_length_prefix_evidence.py`: updates the
  `BARRIER-EVID-0003` consumer-link pin.
- `docs/evidence/M1-023-barrier-evidence-register.md`: documents the M1-022
  reassembler consumer links.
- `evidence/issues/M1-022-TRACE-001/`: this evidence package.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Register links M1-022 reassembler tests to relevant Barrier evidence | `M1-023.json` entries for `BARRIER-EVID-0002` and `BARRIER-EVID-0003` |
| No frozen contract, ADR, reassembler behavior or fixture bytes changed | Diff is limited to consumer links, tests, docs and this evidence package |
| Evidence register tests pass | `python3 evidence/issues/M1-023/tests/test_register.py` passed: 14 tests |
| Existing contract pins updated | `python3 Tests/Contracts/test_m1_wire_001_contract_sequence.py` passed: 20 tests; `python3 Tests/Contracts/test_m1_wire_002_length_prefix_evidence.py` passed: 7 tests |
| Full repository gates pass | `make verify` passed: 24 gates |

## Non-goals

- No wire contract content is changed.
- No evidence claim, fixture digest, provenance, limitation, unknown field or
  prohibited inference is changed.
- No Swift runtime behavior, parser, codec, networking, TLS, UI or platform
  behavior is implemented.

## Review notes

- `BARRIER-EVID-0001` is intentionally not linked because M1-022 consumes the
  derived golden frame/vector and the exact width-discrimination evidence, not
  the uninterpreted raw handshake runs.
- This is an in-place consumer-link update, matching the existing M1-025 and
  M1-021 consumer-link workflow: it does not rewrite evidence content.

## Rollback

Revert this PR. M1-022 remains implemented, but downstream issues must not rely
on the register as proving M1-022 traceability until the consumer links are
restored.
