# M1-PROTOCOL-001 Barrier Message Contracts

## Status

Accepted for M1-028 consumption after review. M1-031 through M1-034 and M1-041
remain blocked for any message semantics not explicitly frozen here.

## Context

GitHub Issue #306 was opened because the accepted M1 Barrier evidence froze the
top-level frame prefix, the initial `Barrier` marker, and version bytes, but it
did not freeze the message codes and payload fields needed by the downstream
Barrier encoder/decoder Issues. The existing M1-024 and M1-040 fixtures
intentionally prohibit semantic inference from uninterpreted bytes.

M1-028 needs one narrow contract: the client HelloBack frame produced after the
server hello, including client screen-name encoding and length. M1-031 and later
decoder Issues need additional control, pointer, button, wheel, and keyboard
message contracts that are not established by this decision.

## Decision

Add `BARRIER-EVID-0004` as a consumable, narrow black-box evidence entry for
Barrier client HelloBack screen-name encoding.

The supported M1 HelloBack frame is:

| Field | Width | Encoding | Frozen value / rule |
|---|---:|---|---|
| Frame length | 4 bytes | unsigned big-endian | Number of payload bytes after this prefix |
| Marker | 7 bytes | ASCII | `42 61 72 72 69 65 72` (`Barrier`) |
| Version | 4 bytes | opaque bytes | `00 01 00 06` |
| Screen-name length | 4 bytes | unsigned big-endian | UTF-8 byte count of screen-name bytes |
| Screen-name bytes | variable | UTF-8 bytes | Exactly `screen-name length` bytes |

M1-028 may implement only this writer contract. For M1 support, screen names are
limited to non-empty, privacy-safe ASCII identifiers whose UTF-8 byte count is
small enough to fit the configured writer bound. That support bound is a MacKVM
fail-closed policy, not a claim about Barrier's maximum accepted screen-name
length.

The following observed bytes are retained as evidence but are not enough to
complete M1-031:

| Direction | Payload token | Frozen by this ADR |
|---|---|---|
| server-to-client | `QINF` | Observation only; may identify a request token in a future contract |
| server-to-client | `CIAK` | Observation only |
| server-to-client | `CROP` then `DSOP` | Observation only |

This ADR does not freeze `CINN`, `COUT`, `CALV`, `CNOP`, `DMMV`, mouse button,
mouse wheel, `DKDN`, `DKUP`, `DKRP`, clipboard, or any production TLS behavior.

## Evidence

Evidence entry: `BARRIER-EVID-0004`

Fixture:

- `Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json`
- `Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/metadata.json`

The capture used two deterministic synthetic client screen names:

| Screen name | UTF-8 byte count | HelloBack frame bytes |
|---|---:|---|
| `m1-client` | 9 | `00 00 00 18 42 61 72 72 69 65 72 00 01 00 06 00 00 00 09 6d 31 2d 63 6c 69 65 6e 74` |
| `m1x` | 3 | `00 00 00 12 42 61 72 72 69 65 72 00 01 00 06 00 00 00 03 6d 31 78` |

Only the synthetic screen-name input changed. The payload length and
screen-name length changed by the same six-byte delta, and the retained
screen-name bytes match the configured UTF-8 bytes exactly.

## Security and privacy

- TLS was disabled only for the bounded observation. Production TLS defaults
  stay fail-closed and unchanged.
- The raw pcaps are not committed. The committed fixture retains only sanitized
  application payload bytes, byte counts, synthetic names, and raw pcap digests.
- The screen names are deterministic non-personal ASCII strings.
- No typed text, clipboard payload, credential, private key, token, hostname,
  IP address or real port is committed.
- No Barrier or Deskflow source, header, generated code, constant table,
  decompiled output, packet injection, binary patching or instrumentation was
  used.

## Compatibility impact

M1-028 can now write a HelloBack frame matching the observed Barrier 2.4.0
protocol 1.6 behavior for the supported M1 name policy.

The decision intentionally does not claim broader Barrier compatibility. It
does not unblock M1-031, M1-032, M1-033, M1-034, or M1-041 for their semantic
decoder work. Those Issues still need message-specific consumable contracts or
approved evidence.

## Rejected alternatives

### Reinterpret M1-024 or M1-040 directly

Rejected. Those accepted evidence entries explicitly preserve payload bytes as
uninterpreted observations and prohibit downstream semantic inference.

### Freeze all visible control tokens now

Rejected. The bounded captures observed some early control tokens, but not the
full enter/leave/keepalive, pointer, button, wheel, or keyboard contracts needed
by downstream Issues.

### Use Barrier or Deskflow source/header constants

Rejected. The M1 independent implementation policy forbids copying or
translating GPL implementation material into the first-party adapter.

## Open questions

| Question | Owner | Blocking condition |
|---|---|---|
| Exact consumable contracts for M1-031 control decoder | M1-031 implementer with reviewer | Blocks M1-031 completion until frozen by a follow-up evidence/ADR entry |
| Exact consumable contracts for M1-032 through M1-034 mouse decoders | Each decoder implementer with reviewer | Blocks the relevant decoder until frozen by a follow-up evidence/ADR entry |
| Exact consumable contract for M1-041 keyboard decoder | M1-041 implementer with reviewer | Blocks M1-041 and dependent M1-043/M1-046 until frozen by a follow-up evidence/ADR entry |
| General Barrier peer maximum for screen-name length | Protocol compatibility owner | Does not block M1-028; M1-028 must use a conservative MacKVM fail-closed support bound |

## Rollback

Revert this ADR, the M1-PROTOCOL-001 fixture, and the `BARRIER-EVID-0004`
register entry. M1-028 must then return to blocked state until another accepted
HelloBack contract exists. Downstream Issues must not consume this entry after
rollback.
