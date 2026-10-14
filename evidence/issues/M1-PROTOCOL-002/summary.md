# M1-PROTOCOL-002 Evidence Summary

## Status

Adds a narrow approved Barrier control-message contract for M1-031 only.
M1-032, M1-033, M1-034 and M1-041 remain blocked for message-specific semantics
not established here.

Base commit: `dc512140d547a5da4594a3b7da62b9736aece1fe`.

## Deliverables

- `docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md`
- `Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/sanitized.json`
- `Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/metadata.json`
- `Tests/Contracts/test_m1_protocol_002_control_message_contracts.py`
- `evidence/registers/M1-023.json` (`BARRIER-EVID-0005`)
- `docs/evidence/M1-023-barrier-evidence-register.md`
- `evidence/issues/M1-PROTOCOL-002/`

## Acceptance mapping

| Criterion | Evidence |
|---|---|
| Exact consumable source for M1-031 control messages | ADR and approved `BARRIER-EVID-0005` freeze `QINF`, `DINF`, `CIAK`, `CROP`, `DSOP`, `CALV`, `CNOP`, `CINN` and `COUT` for M1-031 only. |
| Golden/conformance bytes | Fixture records exact frame bytes and `Tests/Contracts/test_m1_protocol_002_control_message_contracts.py` asserts all retained bytes exactly. |
| Message code/field order/width/endian | ADR field tables and contract tests assert top-level length, token-only frames, DINF fields, CINN fields and DSOP zero value. |
| Unknown fields remain unsupported | ADR non-claims and register ambiguous fields keep mouse, button, wheel, keyboard, clipboard, DSOP non-zero option semantics, DINF cursor signedness, CINN coordinate signedness, CINN sequence semantics, CINN modifier mask bits and keepalive timing out of scope. |
| No GPL-derived implementation | Evidence provenance records black-box capture only; no source/header/decompiled material used. |
| Architecture boundaries unchanged | Contract is confined to BarrierCompatibility consumer tests; KVMCore remains KVMEvent-only. |
| TLS/privacy unchanged | TLS disabled only for observation; production default unchanged; committed fixture excludes raw pcap, addresses, hostnames, ports, clipboard payload and hotkey side-effect frame bytes. |

## Known limitations

- This unblocks only M1-031.
- Keepalive timing and timeout behavior are not frozen.
- `DSOP` non-zero values remain unsupported.
- `CINN` modifier-mask bits remain opaque.
- DCLP, DKDN and DKUP hotkey side-effect frames were observed but
  removed from the committed fixture and are not consumable claims; M1-031 may
  only skip their complete top-level frames by length without decoding or
  forwarding them.
- DINF geometry is real display/cursor geometry from the controlled peer,
  retained as low-sensitivity M1-031 protocol evidence. It is not host identity
  or private content.
- BARRIER-EVID-0004 remains append-only and still records that it did not
  establish enter, leave or keepalive semantics; this later entry resolves that
  M1-031-specific blocker.
- No Windows or production TLS behavior is claimed.

## Rollback

Before merge, revert this PR. After merge, preserve the append-only register by
marking `BARRIER-EVID-0005` rejected or superseded in a follow-up change.
M1-031 returns to blocked state until another accepted control-message contract
exists.
