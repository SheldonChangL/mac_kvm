# M1-025 Barrier Client Wire Contract v0.1

## Status

Accepted for PR review under Product Owner standing authorization on 2026-10-08.
Final repository acceptance occurs through the M1-025 PR merge gate. Independent
Claude review is recorded in `evidence/issues/M1-025/independent-review.md`.

## Context

M1-025 freezes the Barrier client wire contract subset that later M1 work may consume.
The contract is intentionally narrow: it defines the top-level frame envelope and the
observed marker/version acceptance policy, but it does not define Barrier message codes
or implement a parser.

The approved inputs are:

- `BARRIER-EVID-0001`: approved uninterpreted Barrier run provenance, including byte
  lengths, direction and ordering, without message semantics.
- `BARRIER-EVID-0002`: approved candidate frame conformance evidence, including the
  observed marker bytes and version bytes, without resolving the exact prefix width.
- `BARRIER-EVID-0003`: approved discriminating evidence resolving the length-prefix
  width as 4 bytes within the approved `{2, 4}` big-endian candidate set.
- `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`.
- `docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`.
- `docs/adr/M1-WIRE-002-barrier-length-prefix-width.md`.

M1-WIRE-002 is the separately approved discriminating evidence required by the M1-025
preconditions. Without it, M1-025 would have had to keep the exact prefix width open.

## Decision

Barrier Client Wire Contract v0.1 is frozen as the following contract.

### Frame envelope

Every top-level Barrier frame consumed by the Barrier compatibility adapter is:

1. a 4-byte unsigned big-endian length prefix; followed by
2. exactly that many payload bytes.

The prefix value is the number of payload bytes following the prefix. Consumers must
apply this contract to the complete ordered byte stream, not to individual TCP packets,
read calls or packet-capture records. Coalesced frames are therefore valid input to a
downstream reassembler. Handling incomplete stream fragments is left to M1-022, but
M1-022 must not reinterpret the prefix width, byte order or payload-length meaning.

The prefix decision is limited to the approved evidence and candidate set. It does not
claim that every possible Barrier variant has been exhaustively evaluated.

### Marker and version behavior

For the first marker-bearing frame payload at the Barrier client/server compatibility
handshake boundary, the compatibility adapter may accept only the observed marker/version
prefix:

- ASCII marker bytes: `42 61 72 72 69 65 72` (`Barrier`)
- version bytes immediately after the marker: `00 01 00 06`

The 4 bytes after the marker are treated as an opaque 4-byte sequence for M1-025. This
ADR does not freeze whether they are one integer, two unsigned 16-bit values or any other
semantic field layout.

Any different marker or version at this validation point is an unsupported variant and
must fail closed with a typed error before interpreting later frame payloads.

This adopts the M1-WIRE-001 proposed `exact-supported-version-fail-closed` policy. It
does not create version negotiation, version ranges, downgrade behavior, fallback to
unknown variants or cross-version compatibility.

### Explicitly unknown or unsupported

M1-025 does not freeze any of the following. Each item has an owner and blocking
condition so it is not implicitly deferred without accountability.

| Unknown or unsupported item | Owner | Blocking condition |
| --- | --- | --- |
| Barrier message codes or message names | M1-026 or later message-registry issue | Blocks message parsing beyond the envelope |
| Payload field layout beyond the top-level prefix and listed marker/version bytes | M1-026 or later parser issue | Blocks semantic payload decoding |
| Optional fields | M1-026 or later parser issue | Blocks optional-field support |
| Maximum accepted payload length | Security/product safety owner for the bounded reader issue | Blocks claiming Barrier compatibility max length |
| Oversize-frame behavior | Security/product safety owner for the bounded reader issue | Blocks protocol-compatible oversize handling |
| Chunking policy beyond the byte-stream framing rule | M1-022 frame reassembler | Blocks split-frame behavior beyond prefix preservation |
| Clipboard, input, display, screen-edge or semantic event payloads | Respective later protocol-message issues | Blocks event-level Barrier compatibility |
| Client outbound marker/version bytes | M1-021 or later writer issue | Blocks writer behavior beyond this receive-side validation policy |
| Server behavior | Future server milestone owner | Blocks server mode |
| Windows behavior | Windows milestone owner; Windows is out of M1 scope | Blocks Windows claims |
| Production TLS behavior | Production networking/security owner | Blocks TLS/certificate claims from this ADR |
| Successful interoperability for the M1-WIRE-002 protocol-error capture attempt | M1-WIRE-002 follow-up or later interoperability issue | Blocks claiming successful interoperability from that attempt |
| Evidence-register consumer links for M1-025 | GitHub Issue #293 owner | Blocks M1-021 or M1-022 from consuming M1-025 without completed traceability links |

Downstream implementation may introduce safety bounds for memory or denial-of-service
protection, but those bounds are product safety policy and must not be presented as
observed Barrier compatibility limits unless separately evidenced.

## Consequences

- M1-021 may implement a bounded binary reader/writer against the 4-byte unsigned
  big-endian frame envelope.
- M1-022 may implement a frame reassembler against the complete ordered byte stream.
- Later message parsing work must use this document and fixtures as its framing input,
  but must not infer message codes or field layouts from this ADR.
- Unknown marker/version variants fail closed.
- Protocol and KVM Core remain separated: this contract belongs to the Barrier protocol
  adapter boundary and does not introduce Barrier message codes into the input engine or
  KVM Core.
- Production TLS remains default-on where production networking behavior exists; this
  ADR does not modify TLS policy.
- GitHub Issue #293 must complete the append-only evidence-register consumer-link update
  before M1-021 or M1-022 consumes this contract as implementation input. M1-025 does
  not silently expand its Exact Files to edit the register.

## Security/Compatibility impact

- Unsupported marker/version variants fail closed with a typed error before later payload
  interpretation.
- No downgrade, fallback or general version negotiation is introduced.
- The contract is limited to the approved Barrier evidence set and does not claim
  compatibility with other Barrier versions, Windows, server mode, successful
  interoperability or production TLS behavior.
- Production TLS remains default-on where production networking exists. The evidence used
  for this ADR does not validate or weaken TLS, certificate or trust behavior.
- No raw packet payload, typed text, clipboard payload, secret, credential or private path
  is added by this ADR.

## Alternatives considered

- Keep the exact prefix width open. Rejected because `BARRIER-EVID-0003` now resolves the
  M1-WIRE-001 ambiguity within the approved candidate set.
- Freeze Barrier message codes now. Rejected because the approved evidence does not
  establish message-code semantics.
- Infer maximum frame size or oversize behavior now. Rejected because no approved source
  establishes those limits.
- Implement a parser, codec or networking behavior in this issue. Rejected as out of
  scope for this decision issue.
- Support version negotiation or version ranges. Rejected because M1-WIRE-001 only
  proposed an exact supported-version fail-closed policy for M1-025.

## Rollback

If this contract is later invalidated, add a superseding ADR and block consumers that
depend on this decision. Do not silently rewrite approved evidence entries. If downstream
M1-021, M1-022 or later parser work has consumed this ADR, revert or supersede those
changes through follow-up PRs tied back to the superseding decision.
