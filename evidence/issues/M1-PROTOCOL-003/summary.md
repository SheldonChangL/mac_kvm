# M1-PROTOCOL-003 Evidence Summary

## Status

Freezes the Barrier pointer, button, wheel, key and clipboard frames that
`BARRIER-EVID-0006`, `0007` and `0008` establish (M2-022 capture). Accepted: the Product
Owner merged PR #334 on 2026-10-29. The client decoders M1-032, M1-033, M1-034 and M1-041
consume it (PRs #336–#339), as will the key mapper M1-043 and the client session
M1-029-FOLLOWUP-001.

Independent protocol review (`independent-review.md`): accept with conditions on the
draft at `4ee8f62`, accept on the revision at `a621ca3`. The five wording nits of the
second review are fixed in `fd32fee`. A Codex finding relayed by the Product Owner (P2):
the client's wheel rule did not invert the horizontal axis. It is fixed in the commit
that adds that finding to `independent-review.md`.

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
| Wheel direction | `test_wheel_rule_inverts_the_horizontal_axis` decodes the captured notches to `KVMEvent.scroll` directions; `scrollRoundTrip` round-trips the encoder through the client rule. |
| Independent review | `independent-review.md`: accept; the later Codex finding is resolved there. |

## Known limitations

- Multi-notch wheel values, multi-chunk transfers and the 34 first-party shifted
  identifiers are conventions, not capture claims. Of the shifted identifiers, only
  Shift+B was validated against a Barrier client (M2-035).
- Pointer values at or above 0x8000, negative origins and a non-zero `DINF` origin are not
  frozen, which blocks multi-monitor client layouts.
- Clipboard format ids, and clipboard id 1, have no frozen meaning; only text is
  supported.
- Non-US layouts are not claimed.
- The horizontal scroll direction is pinned by tests only: M2-035 exercised no horizontal
  scroll, so M4-036-FOLLOWUP-001 must include one.
- The sign convention of `KVMEvent.scroll` is not stated in C-001 (an ADR open question).
- No TLS, Windows or macOS Barrier server behavior is claimed.

## Rollback

Before merge, revert this PR. After merge, revert the ADR, the M2-023 status note and
the `frozenContractRefs` and `consumingTests` links of `BARRIER-EVID-0006` to `0008`.
The decoders return to blocked; the first-party Mac server's encoders keep working, as
they did before this contract.
