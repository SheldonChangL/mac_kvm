# M1-PROTOCOL-001 Evidence Summary

## Status

Adds a narrow consumable Barrier message contract for M1-028 only. M1-031, M1-032, M1-033, M1-034 and M1-041 remain blocked for message-specific contracts not established here.

## Deliverables

- `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md`
- `Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json`
- `Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/metadata.json`
- `evidence/registers/M1-023.json` (`BARRIER-EVID-0004`)
- `docs/evidence/M1-023-barrier-evidence-register.md`
- `evidence/issues/M1-023/tests/test_register.py`
- `evidence/issues/M1-PROTOCOL-001/`

## Acceptance mapping

| Criterion | Evidence |
|---|---|
| Exact consumable source for unblocked message | ADR and `BARRIER-EVID-0004` freeze HelloBack marker/version/screen-name length/screen-name bytes. |
| Golden/conformance bytes | Fixture records two HelloBack frames for `m1-client` and `m1x`; ADR lists exact hex bytes. |
| Message code/field order/width/endian | HelloBack field table in ADR; frame and name lengths are unsigned big-endian. |
| Unknown fields remain unsupported | ADR open questions and register ambiguous fields keep M1-031/032/033/034/041 blocked. |
| No GPL-derived implementation | Evidence provenance records black-box capture only; no source/header/decompiled material used. |
| Architecture boundaries unchanged | Contract is confined to BarrierCompatibility consumer tests; KVMCore remains KVMEvent-only. |
| TLS/privacy unchanged | TLS disabled only for observation; production default unchanged; committed fixture excludes raw pcap, addresses, hostnames, ports, credentials and typed text. |

## Known limitations

- M1-028 is unblocked only for the supported M1 HelloBack writer policy.
- M1-031 and later semantic decoders remain blocked for messages not frozen here.
- The general Barrier peer maximum for screen-name length is not established.

## Rollback

Revert this PR. M1-028 returns to blocked state until another accepted HelloBack contract exists.
