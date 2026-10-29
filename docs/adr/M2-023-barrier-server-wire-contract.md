# M2-023 Barrier Server Wire Contract v0.1

## Status

Proposed on 2026-10-27 under the Product Owner M2 execution-order pivot.
Acceptance requires a non-implementing protocol reviewer. M2-022 (server-side
fixture capture) has not been executed: no approved M2 capture plan exists, so
this ADR freezes nothing new from observation. It only proposes that the
server role may write and read the exact byte sequences already accepted in
`BARRIER-EVID-0004` (M1-PROTOCOL-001) and `BARRIER-EVID-0005`
(M1-PROTOCOL-002), whose consumption was scoped to M1-028 and M1-031. Reusing
them for the server role is the decision under review here.

## Binding sources

- `docs/adr/M1-025-barrier-client-wire-contract.md` (4-byte big-endian frame
  envelope, marker `Barrier`, version `00 01 00 06`, exact-version fail closed)
- `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md` (HelloBack layout)
- `docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md` (control
  frames, DINF, CINN, COUT, keepalive)
- `evidence/registers/M1-023.json` entries `BARRIER-EVID-0001`…`0005`
- `docs/adr/M2-001-mac-server-safety-model.md`

## Decision (proposed server subset)

### Listener handshake

| Step | Direction | Bytes / rule | Source |
|---|---|---|---|
| 1 | server→client | hello `00 00 00 0b 42 61 72 72 69 65 72 00 01 00 06` | EVID-0004/0005 setup context |
| 2 | client→server | HelloBack: length, marker, version `00 01 00 06`, 4-byte big-endian name length, UTF-8 name | EVID-0004 |
| 3 | server→client | `QINF` token-only | EVID-0005 |
| 4 | client→server | `DINF` 14-byte body, validated exactly as M1-031 does | EVID-0005 |
| 5 | server→client | `CIAK`, `CROP`, `DSOP` with 4-byte zero body | EVID-0005 observed order |

The server reads HelloBack only with the exact marker and version; anything
else fails closed. Client screen names follow the M1-028 policy: non-empty
ASCII identifier bytes within a conservative MacKVM bound. The server sends
step 5 only after a valid `DINF`; the cross-direction interleaving of steps 4
and 5 was not discriminated by evidence and is a conservative choice.

### Client lifecycle

| Purpose | Direction | Bytes | Source |
|---|---|---|---|
| Enter | server→client | `CINN` with x, y (each `0x0000…0x7fff` and inside the client DINF rectangle), 4-byte sequence, 2-byte mask | EVID-0005 |
| Leave | server→client | `COUT` token-only | EVID-0005 |
| Keepalive | both | `CALV` token-only | EVID-0005 |
| No-op | client→server | `CNOP` token-only, ignored | EVID-0005 |

Because only one `CINN` was observed, the server writer supports only the
observed values: sequence `1` and the opaque mask `0x2000`, once per session.
A second enter in the same session, or any other sequence or mask, fails
closed as unsupported. The session owner must end and re-establish the session
instead of guessing increment or modifier semantics.

Keepalive interval and timeout are not frozen. They are caller configuration
and are not compatibility claims.

### Unsupported behavior (fail closed)

| Behavior | Reason | Unblocking condition |
|---|---|---|
| Pointer move, button, wheel (M2-026) | No frozen encoding in any accepted evidence | Approved server-side capture (M2-022) and an accepted contract entry |
| Key down/up/repeat, modifier mapping (M2-027) | `DKDN`/`DKUP` bodies explicitly excluded by EVID-0005 | Same as above, plus M1-041/M1-043 key mapping |
| Clipboard (M2-028 clipboard part) | `DCLP` body excluded by EVID-0005 | Same as above |
| Second and later `CINN` per session; non-observed mask | Sequence and mask semantics not frozen | Discriminating evidence |
| Server TLS listener | No server identity provisioning decision; TLS must stay default on | Security decision on server certificate identity and a TLS listener issue |
| Any token outside the subset from the client | Unknown | Fails closed except the M1-031 excluded-token skip rule does not apply to the server direction |
| Windows clients | Out of executed scope | Windows milestone evidence |

Encoders for unsupported behavior must return a typed unsupported error and
must never emit bytes. Core code never sees any of these tokens.

## Security and privacy

- TLS stays default on. The plaintext listener used by tests is not a
  production path; a production listener without TLS identity must refuse to
  start.
- Screen names are validated and never logged; diagnostics carry only token,
  direction, counts and typed reasons.

## Compatibility impact

With only this subset the Mac server can complete setup with a Barrier 2.4.0
protocol 1.6 client, enter once and leave, and keep the session alive. It
cannot deliver pointer, keyboard or clipboard input. No full interoperability
or Windows claim is made.

## Rejected alternatives

- Inferring pointer/key encodings from token names or upstream sources:
  rejected by M1-003 and the frozen independent-implementation decision.
- Guessing a `CINN` increment or a zero modifier mask: rejected; not observed.
- Plaintext production listener: rejected by FROZEN_DECISIONS item 6.

## Rollback

Revert this ADR. M2-024, M2-025 and M2-028 return to blocked state.

## Traceability

Issue: `MacKVM_Implementation_Package_v2/issues/M2/M2-023-barrier-server-wire-contract.md`.
