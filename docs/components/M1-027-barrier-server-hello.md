# M1-027 Barrier Server Hello

## Outcome

`BarrierCompatibility` validates the first marker-bearing server-to-client frame
payload against the frozen M1-025 marker/version bytes and produces a typed,
module-internal `BarrierServerHello` value. Any other payload fails closed with a
typed `BarrierServerHelloError` that carries no payload bytes.

## Frozen input

`docs/adr/M1-025-barrier-client-wire-contract.md` freezes exactly one accepted
payload for this validation point:

- ASCII marker bytes `42 61 72 72 69 65 72` (`Barrier`);
- immediately followed by the opaque version bytes `00 01 00 06`;
- policy `exact-supported-version-fail-closed`: no version ranges, negotiation,
  downgrade or fallback.

The golden payload is the 11-byte payload of `BARRIER-EVID-0002` run 0
(`evidence/issues/M1-WIRE-001/barrier-frame-conformance.json` `/derived/runs/0`,
`/derived/markerObservations`, `/derived/versionByteObservations`).

## Why no message code is defined here

M1-025 lists Barrier message codes, message names, code width, optional fields and
payload field layout beyond the marker/version as not frozen. The parser therefore:

- hardcodes no Barrier message code or name and does not register the marker as a
  code in `BarrierMessageRegistry` (M1-026);
- treats the version as an opaque 4-byte sequence, not as one or more integers;
- accepts nothing after the version, because no trailing field layout is frozen.

Routing this validation into a handshake belongs to the M1-029 handshake state machine.

## Types

All declarations are module-internal; no public API or contract is added.

- `BarrierServerHello` (`Equatable`, `Sendable`):
  - `init(payload:) throws(BarrierServerHelloError)` is the only initializer;
  - `supportedMarkerBytes`, `supportedVersionBytes`, `payloadByteCount` (11) are
    the frozen constants;
  - `versionBytes` (stored) and `markerBytes` (computed) are the accepted bytes.
- `BarrierServerHelloError` (`Equatable`, `Sendable`):
  - `truncatedMarker(payloadByteCount:)`, `unsupportedMarker`;
  - `truncatedVersion(payloadByteCount:)`, `unsupportedVersion`;
  - `unexpectedTrailingBytes(payloadByteCount:)`.

Errors carry at most the payload byte count. No KVM Core dependency is added; the
value does not reach KVM Core.

## Behavior

Validation runs in order and stops at the first failure:

1. Compare the bytes present against the marker. A mismatch is
   `unsupportedMarker`; a matching but short payload is `truncatedMarker`.
2. Compare the next bytes against the version. A mismatch is
   `unsupportedVersion`; a matching but short payload is `truncatedVersion`.
3. Any byte after the version is `unexpectedTrailingBytes`.

A mismatch in the bytes present is reported before truncation, so a foreign variant
is never reported as a partial supported hello. An empty payload is
`truncatedMarker(payloadByteCount: 0)`.

The parser is a pure synchronous function of one payload. It owns no resource,
state, threading or I/O, so there is nothing to cancel or clean up; a failed parse
cannot affect a later one. The parser
performs no logging.

## Scope boundaries

- Stream fragmentation, coalescing and stream truncation are handled and tested by
  `BarrierFrameReassembler` (M1-022). This parser sees only complete payloads, so
  truncation is tested at payload level; one test feeds the golden frame through
  the reassembler byte by byte and parses the yielded payload to pin the hand-off.
- Oversize limits stay with M1-021/M1-022; the parser compares at most 11 bytes and
  rejects longer payloads by count without copying them.
- No client hello-back (M1-028), handshake state machine (M1-029) or control message (M1-031).
- No socket, transport, TLS, logging, threading or KVM Core dependency.
- No Barrier/Deskflow source was consulted or copied; only the frozen ADR and the
  sanitized fixture bytes are used.

## Validation coverage

`BarrierServerHelloTests` (19 tests) verifies:

- happy path: the golden payload parses and marker plus version bytes equal it
  exactly; the frozen constants equal the golden bytes; the golden frame split
  into 1-byte fragments and reassembled by M1-022 parses unchanged;
- boundaries: 7 + 4 = 11 byte length, empty payload, truncation at every marker
  and version length, trailing bytes of 1, 4 and 65 536 bytes;
- failures: every single-byte marker and version mutation, neighbouring and
  extreme versions, case variants of the marker, mismatch-before-truncation and
  marker-before-version-before-trailing ordering, errors carrying only
  `payloadByteCount` (checked on errors the parser actually throws), hello carrying
  only the accepted version bytes;
- cleanup/idempotency: repeated parses are equal, failed parses do not affect a
  later parse.

## Rollback

Revert the M1-027 PR. The parser owns no runtime resource, persisted data or
migration, and no production code consumes it yet.
