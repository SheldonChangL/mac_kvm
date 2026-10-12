# M1-021 Barrier Bounded Binary Reader/Writer

## Outcome

`BarrierCompatibility` provides a bounded, big-endian binary reader and writer
for the Barrier protocol adapter. It implements only the frame envelope frozen
by `docs/adr/M1-025-barrier-client-wire-contract.md`: a 4-byte unsigned
big-endian length prefix followed by exactly that many payload bytes.

## Types

All declarations are module-internal; no public API or contract is added.

- `BarrierBinaryReader` reads from a complete in-memory byte buffer:
  `readUInt8`, `readUInt16`, `readUInt32`, `readBytes(count:)` and
  `readLengthPrefixedPayload(maximumPayloadLength:)`.
- `BarrierBinaryWriter` appends to a buffer capped at a caller-supplied
  `maximumByteCount`: `writeUInt8`, `writeUInt16`, `writeUInt32`,
  `writeBytes(_:)` and `writeLengthPrefixedPayload(_:maximumPayloadLength:)`.
- `BarrierBinaryCodecError` is the typed failure set, thrown with Swift typed
  throws:
  - `truncated(requested:remaining:)`: fewer bytes remain than the read needs;
  - `oversize(limit:)`: a payload or buffer would exceed its caller limit. The
    payload limit and the writer capacity share this case; callers that must
    tell them apart should use different limit values;
  - `integerOverflow`: a count, including a negative one, does not fit the
    4-byte unsigned prefix (`BarrierBinaryWriter.lengthPrefix(for:)`). On the
    read path this is reachable only where `Int` is 32 bits, so it is not
    exercised on the 64-bit macOS targets;
  - `invalidCount`: a read count, payload limit or buffer capacity is negative.

Errors carry only counts and limits, never input or payload bytes.

## Bounds and safety

- Every integer is encoded and decoded big-endian.
- Every read checks the remaining byte count before touching the buffer. The
  comparison is made against the remainder, so a huge requested count cannot
  overflow cursor arithmetic.
- `readLengthPrefixedPayload` rejects a prefix above `maximumPayloadLength`
  before checking for or copying payload bytes, so a hostile `FF FF FF FF`
  prefix cannot force a large allocation.
- A failed read never advances the cursor, and a failed write never changes
  the buffer. Repeating a failed operation yields the same error.

Payload and buffer limits are product safety bounds supplied by the caller.
M1-025 lists the maximum accepted payload length and oversize behavior as
unknown, so this component defines no default limit and does not present any
limit as an observed Barrier compatibility value.

## Scope boundaries

- The reader operates on a complete buffer. Incomplete stream fragments are
  reported as `truncated`; reassembly across reads belongs to M1-022.
- No Barrier message code, message name, payload field layout or receive-side
  marker/version validation is introduced; per the M1-025 unknowns table those
  belong to M1-026 or later issues.
- The M1-025 unknowns table assigns client outbound marker/version bytes to
  "M1-021 or later writer issue". M1-021 explicitly declines that item: no
  approved evidence establishes the client's outbound bytes, so the writer only
  frames caller-supplied payloads. A later writer issue must own it (see
  `evidence/issues/M1-021/summary.md` follow-ups).
- No socket, transport, TLS, logging or KVM Core dependency is added.
- No Barrier/Deskflow source was consulted or copied. Golden bytes come from the
  approved `BARRIER-EVID-0002` conformance artifact (first server-to-client
  frame, prefix `0000000b`) and the M1-025 marker/version bytes.

## Validation coverage

`BarrierBinaryCodecTests` verifies:

- big-endian decode/encode of 8-, 16- and 32-bit unsigned integers;
- golden frame bytes from the writer equal the evidence bytes exactly, and the
  reader extracts the golden payload. The bytes are copied by hand into the
  test with JSON pointers to the source artifact; they are not loaded at test
  time, so a superseding evidence artifact requires updating the test;
- coalesced frames read in order and writer output round-trips;
- boundaries: empty payload, payload exactly at limit, zero-count read, writer
  filling capacity exactly, zero-capacity writer and the `UInt32` prefix range;
- failures: truncation at every prefix and payload length, oversize one byte
  over the limit, maximum prefix rejected as oversize (or as truncated when the
  caller limit is `Int.max`), huge counts, negative
  counts/limits, capacity overflow and prefix values outside `UInt32`;
- cleanup/idempotency: failed integer, byte and frame reads keep the cursor and
  failed primitive and frame writes keep the buffer, across repeated failures,
  followed by a successful operation.

## Rollback

Revert the M1-021 PR. The codec owns no runtime resource, persisted data or
migration. Keep M1-022 blocked until a bounded codec is restored.
