# M1-025 Evidence Summary

## Scope

M1-025 freezes Barrier Client Wire Contract v0.1 as an ADR-only product contract. It
does not implement a parser, codec, message registry, networking behavior or platform
behavior.

## Approved inputs

- `BARRIER-EVID-0001`: approved uninterpreted run provenance.
- `BARRIER-EVID-0002`: approved candidate frame conformance and observed marker/version
  bytes.
- `BARRIER-EVID-0003`: approved discriminating evidence for 4-byte unsigned big-endian
  length prefix.
- `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`.
- `docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`.
- `docs/adr/M1-WIRE-002-barrier-length-prefix-width.md`.

## Frozen decision

`docs/adr/M1-025-barrier-client-wire-contract.md` freezes:

- top-level frame prefix width: 4 bytes;
- byte order: unsigned big-endian;
- prefix meaning: payload byte count after the prefix;
- stream rule: complete ordered byte stream, not packet/read boundaries;
- marker/version policy: accept only `Barrier` plus `00 01 00 06` at the M1-025-owned
  validation point, otherwise fail closed.

## Deliberately not frozen

The ADR does not freeze message codes, message names, payload field layout beyond the
prefix and listed marker/version bytes, optional fields, maximum accepted payload length,
oversize behavior, successful interoperability, Windows behavior, server behavior,
semantic input/clipboard/display payloads or production TLS behavior.

## Validation evidence

Validation commands and exact results are recorded in `commands.json`. Machine-readable
test output is recorded in `tests/results.json`.

## Acceptance Criteria mapping

- Focus items have ADR evidence and objective tests:
  `docs/adr/M1-025-barrier-client-wire-contract.md` and
  `Tests/Contracts/test_m1_025_barrier_client_wire_contract.py`.
- Selected, rejected alternatives, consequences, Security/Compatibility impact and
  rollback are recorded in the ADR.
- Open questions have owner and blocking-condition rows in the ADR.
- Owner/Human standing authorization and independent review are recorded in
  `evidence/issues/M1-025/independent-review.md`.
- Required commands and full `make verify` passed; exact results are in `commands.json`.

## Follow-up blocker

GitHub Issue #293 tracks evidence-register consumer links for M1-025. The M1-025 canonical
issue forbids silently expanding Exact Files, so M1-025 does not directly edit the
append-only register. M1-021 and M1-022 must not consume the final M1-025 contract as
implementation input until #293 closes.
