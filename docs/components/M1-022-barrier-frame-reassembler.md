# M1-022 Barrier Frame Reassembler

## Outcome

`BarrierCompatibility` provides a byte-stream frame reassembler for the Barrier
protocol adapter. It applies the frame envelope frozen by
`docs/adr/M1-025-barrier-client-wire-contract.md` (a 4-byte unsigned big-endian
length prefix followed by exactly that many payload bytes) to the complete
ordered byte stream, so frames split across appended chunks and frames
coalesced within one chunk are both reassembled in order.

## Types

All declarations are module-internal; no public API or contract is added.

- `BarrierFrameReassembler` is a value type:
  - `init(maximumPayloadLength:)` takes the caller-supplied payload limit;
  - `append(_:)` adds stream bytes in any chunking;
  - `nextPayload()` returns the oldest completed payload, or `nil` when none is
    ready;
  - `finish()` marks end of stream;
  - `pendingByteCount` reports the bytes of the current incomplete frame,
    prefix included.
- `BarrierFrameReassemblerError` is the typed failure set, thrown with Swift
  typed throws:
  - `invalidMaximumPayloadLength`: the caller limit is negative;
  - `oversize(limit:)`: a length prefix declares more payload bytes than the
    caller limit;
  - `truncatedPrefix(received:)`: the stream ended after 1 to 3 prefix bytes;
  - `truncatedPayload(expected:received:)`: the stream ended inside a payload.
    Both counts are payload bytes and exclude the 4-byte prefix;
  - `appendAfterFinish`: bytes were appended after a successful `finish()`.

Errors carry only counts and limits, never stream or payload bytes.

## Behavior

- `append(_:)` parses eagerly. Every frame completed by the new bytes moves to
  a FIFO queue drained by `nextPayload()`; only the current incomplete frame
  stays buffered.
- The prefix is checked against the limit as soon as its fourth byte arrives,
  before any of that frame's payload is buffered, so a hostile `FF FF FF FF`
  prefix cannot make the reassembler hold more than the caller limit. Payload
  storage is not pre-reserved from the declared length.
- A zero-length payload completes as soon as its prefix is complete.
- `finish()` with no incomplete frame succeeds and is idempotent. With an
  incomplete prefix or payload it fails with `truncatedPrefix` or
  `truncatedPayload`; the reassembler never reports a truncated frame as a
  clean end of stream.
- Failures are sticky. On `oversize` or truncation the incomplete frame is
  discarded (`pendingByteCount` becomes 0), later `append(_:)` and `finish()`
  calls rethrow the same error, and `nextPayload()` first returns every frame
  completed before the failure, then rethrows the error on every call.
- After a successful `finish()`, `append(_:)` fails with `appendAfterFinish`
  and already completed payloads remain available.

The payload limit is a product safety bound supplied by the caller. M1-025
lists the maximum accepted payload length and oversize behavior as unknown, so
this component defines no default limit and does not present any limit as an
observed Barrier compatibility value.

## Scope boundaries

- The prefix width, byte order and payload-length meaning are exactly the
  M1-025 envelope; nothing is reinterpreted.
- Payloads are returned as opaque bytes. No Barrier message code, message name,
  payload field layout or marker/version validation is introduced; per the
  M1-025 unknowns table those belong to M1-026 or later issues.
- No socket, transport, TLS, logging, threading or KVM Core dependency is
  added. Mapping `BarrierFrameReassemblerError` to `CoreError` is left to the
  first consumer that crosses the adapter boundary.
- No Barrier/Deskflow source was consulted or copied. Golden bytes are the
  M1-021 golden frame from the approved `BARRIER-EVID-0002` conformance
  artifact (first server-to-client frame, prefix `0000000b`) and the M1-025
  marker/version bytes.

## Validation coverage

`BarrierFrameReassemblerTests` verifies:

- happy path: a complete golden frame, the golden frame split at every offset
  (inside the prefix, at the prefix/payload boundary and inside the payload),
  one byte at a time, and coalesced frames delivered in one append, across
  every chunk size and without interleaved draining;
- golden bytes: the reassembled payload equals the golden payload and,
  re-encoded with `BarrierBinaryWriter`, equals the 15-byte golden frame
  exactly;
- boundaries: empty payload with a zero limit, payload exactly at the limit,
  empty append and `finish()` on an empty stream;
- failures: payload one byte over the limit, `FF FF FF FF` rejected before any
  payload is buffered, an oversize prefix split across chunks, truncation at
  every prefix and payload length, a maximum prefix within an `Int.max` limit
  reported as truncated payload, negative limit and append after finish;
- cleanup/idempotency: frames completed before an oversize or truncation
  failure remain available, failures are sticky and release partial bytes,
  repeated clean `finish()` is idempotent and drained payloads are not
  returned twice.

## Rollback

Revert the M1-022 PR. The reassembler owns no runtime resource, persisted data
or migration, and no production code consumes it yet.
