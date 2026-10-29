# M1-PROTOCOL-003 Evidence Summary

## Status

Freezes the Barrier pointer, button, wheel, key and clipboard frames that
`BARRIER-EVID-0006`, `0007` and `0008` establish (M2-022 capture). Once the Product
Owner merges it, the client decoders M1-032, M1-033, M1-034 and M1-041, the key mapper
M1-043 and the client session M1-029-FOLLOWUP-001 may consume it.

Independent protocol review (`independent-review.md`): accept with conditions on the
draft at `4ee8f62`, accept on the revision at `a621ca3`. The five wording nits of the
second review are fixed in the commit that adds this file. Merging needs the Product
Owner's explicit approval.

Base commit: `b48bf5ce3d2d32c31369ddf107344251a1cd7424`.

## Deliverables

- `docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`
- `docs/adr/M2-023-barrier-server-wire-contract.md` (status note and superseded rows)
- `Tests/Contracts/test_m1_protocol_003_input_clipboard_message_contracts.py`
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierServerInputEncoderTests.swift`
  (`identifiersStayInContract`)
- `evidence/registers/M1-023.json` (`frozenContractRefs` and `consumingTests` of
  `BARRIER-EVID-0006` to `0008`; claims and fixtures unchanged)
- `docs/evidence/M1-023-barrier-evidence-register.md`
- `docs/components/M2-028-barrier-clipboard-control-encoder.md`,
  `evidence/issues/M2-022/summary.md` and
  `evidence/issues/M2-022/incident-001-unobserved-labels.md` (name the contract)
- `evidence/issues/M1-PROTOCOL-003/`

## Acceptance mapping

| Criterion | Evidence |
|---|---|
| Exact consumable source for the client decoders | The ADR freezes `DMMV`, `DMDN`, `DMUP`, `DMWM`, `DKDN`, `DKUP`, `DKRP`, `DCLP` and `CCLP` from `BARRIER-EVID-0006` to `0008` only, and labels every first-party convention separately. |
| Field order, width and byte order | ADR field tables; the contract test checks each frozen layout against the registered fixtures by observation index. |
| Unknown values stay unsupported | "Rejection semantics" separates drop-and-continue from fail-closed cases; "Non-claims" lists what stays unfrozen. |
| The first-party server stays inside the contract | `identifiersStayInContract` enumerates every encodable key in four modifier states and three directions and requires each emitted identifier to be frozen or a declared convention. |
| No GPL-derived material | The contract derives from black-box captures only (M2-022 provenance). |
| Privacy | No new fixture. The registered fixtures zero-fill clipboard content; the filed reviews have local paths masked. |
| Independent review | `independent-review.md`: accept. |

## Known limitations

- Multi-notch wheel values, multi-chunk transfers and the 34 first-party shifted
  identifiers are conventions, not capture claims. Of the shifted identifiers, only
  Shift+B was validated against a Barrier client (M2-035).
- Pointer values at or above 0x8000, negative origins and a non-zero `DINF` origin are not
  frozen, which blocks multi-monitor client layouts.
- Clipboard format ids, and clipboard id 1, have no frozen meaning; only text is
  supported.
- Non-US layouts are not claimed.
- No TLS, Windows or macOS Barrier server behavior is claimed.

## Rollback

Before merge, revert this PR. After merge, revert the ADR, the M2-023 status note and
the `frozenContractRefs` and `consumingTests` links of `BARRIER-EVID-0006` to `0008`.
The decoders return to blocked; the first-party Mac server's encoders keep working, as
they did before this contract.
