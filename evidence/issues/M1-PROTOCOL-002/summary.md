# M1-PROTOCOL-002 Evidence Summary

## Status

Adds a narrow pending-review Barrier control-message contract candidate for
M1-031 only. M1-031 remains blocked until independent review marks
`BARRIER-EVID-0005` approved. M1-032, M1-033, M1-034 and M1-041 remain blocked
for message-specific semantics not established here.

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
| Exact consumable source for M1-031 control messages | ADR and `BARRIER-EVID-0005` freeze `QINF`, `DINF`, `CIAK`, `CROP`, `DSOP`, `CALV`, `CNOP`, `CINN` and `COUT`. |
| Golden/conformance bytes | Fixture records exact frame bytes and `Tests/Contracts/test_m1_protocol_002_control_message_contracts.py` asserts all retained bytes exactly. |
| Message code/field order/width/endian | ADR field tables and contract tests assert top-level length, token-only frames, DINF fields, CINN fields and DSOP zero value. |
| Unknown fields remain unsupported | ADR non-claims and register ambiguous fields keep mouse, button, wheel, keyboard, clipboard, DSOP non-zero option semantics, CINN modifier mask bits and keepalive timing out of scope. |
| No GPL-derived implementation | Evidence provenance records black-box capture only; no source/header/decompiled material used. |
| Architecture boundaries unchanged | Contract is confined to BarrierCompatibility consumer tests; KVMCore remains KVMEvent-only. |
| TLS/privacy unchanged | TLS disabled only for observation; production default unchanged; committed fixture excludes raw pcap, addresses, hostnames, ports, clipboard payload and hotkey side-effect frame bytes. |

## Known limitations

- This unblocks only M1-031.
- Keepalive timing and timeout behavior are not frozen.
- `DSOP` non-zero values remain unsupported.
- `CINN` modifier-mask bits remain opaque.
- DCLP clipboard and DKDN/DKUP hotkey side-effect frames were observed but
  removed from the committed fixture and are not consumable claims.
- No Windows or production TLS behavior is claimed.

## Rollback

Revert this PR. M1-031 returns to blocked state until another accepted
control-message contract exists.
