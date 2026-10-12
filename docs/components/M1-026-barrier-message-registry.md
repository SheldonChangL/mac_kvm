# M1-026 Barrier Message Registry

## Outcome

`BarrierCompatibility` provides a code-to-decoder registry for reassembled
Barrier frame payloads and an unknown-message policy that reports unmatched
payloads as a diagnostic outcome instead of failing or crashing.

## Why no message code is defined here

`docs/adr/M1-025-barrier-client-wire-contract.md` freezes only the 4-byte
length-prefix frame envelope and the first-frame marker/version bytes. Its
unknowns table lists Barrier message codes, message names and payload field
layouts as not frozen, and the sanitized fixtures explicitly make no message
claim. The registry therefore:

- hardcodes no Barrier message code or message name;
- assumes no code width or position beyond "leading payload bytes";
- leaves each code to the later decoder issue that owns the evidence for it,
  which registers the code as an opaque byte prefix together with its decoder.

## Types

All declarations are module-internal; no public API or contract is added.

- `BarrierMessageCode`: non-empty opaque byte prefix. It is not string-backed,
  so a code cannot be logged or passed on as text.
- `BarrierMessageRegistry<Message, DecodeFailure>` is a value type:
  - `register(_:decoder:)` adds a code and a decoder
    `@Sendable ([UInt8]) throws(DecodeFailure) -> Message`;
  - `decode(_:)` dispatches one reassembled payload and returns a
    `BarrierMessageDispatch<Message>`;
  - `registeredCodeCount` reports the number of registered codes.
- `BarrierMessageDispatch<Message>`: `.decoded(Message)` or
  `.unknown(BarrierUnknownMessageDiagnostic)`.
- `BarrierUnknownMessageDiagnostic`: allowlisted metadata only,
  `payloadByteCount`.
- `BarrierMessageRegistryError`: typed registration failures `emptyCode`,
  `duplicateCode` and `ambiguousCode`. Errors carry no code or payload bytes.

`Message` is an adapter-internal type chosen by the consumer. The registry does
not depend on KVM Core; translating decoded messages to `KVMEvent` stays with
later adapter issues, so codes never reach KVM Core.

## Behavior

- Registered codes stay prefix-free: a code equal to, extending, or being a
  prefix of a registered code is rejected. At most one code matches any
  payload, so dispatch does not depend on registration order.
- A matching decoder receives the payload bytes after its code; a payload equal
  to its code yields an empty body.
- A decoder failure propagates unchanged through `decode(_:)` with its typed
  error; the registry neither swallows nor rewraps it.
- A failed registration leaves the registry unchanged. `decode(_:)` does not
  mutate the registry, so repeated calls return the same outcome and a decoder
  failure does not affect later dispatch.

### Unknown-message policy

A payload that matches no registered code, including an empty payload or one
shorter than every candidate code, is skipped and reported as
`.unknown(BarrierUnknownMessageDiagnostic(payloadByteCount:))`:

- no decoder runs, no error is thrown and nothing traps;
- no payload or code bytes are retained in the diagnostic, so it cannot carry
  typed text, clipboard content or other reconstructable data;
- the caller decides how to surface the diagnostic. The registry performs no
  logging.

Whether a specific unknown message must instead terminate a session is protocol
policy owned by the later handshake/control issues; the registry only
guarantees a non-crashing, content-free diagnostic.

## Scope boundaries

- No semantic payload is parsed. Server hello, client hello-back, handshake,
  control, mouse and keyboard decoding belong to M1-027 and later issues.
- Framing is unchanged. The registry consumes complete payloads produced by
  `BarrierFrameReassembler` (M1-022); fragmentation, coalescing and truncation
  are handled and tested there and do not apply to a registry that only sees
  whole payloads.
- No socket, transport, TLS, logging, threading or KVM Core dependency is
  added.
- No Barrier/Deskflow source was consulted or copied. Tests use the golden
  `BARRIER-EVID-0002` first-frame payload with the frozen M1-025 marker as a
  dispatch prefix, plus synthetic codes with no Barrier meaning.

## Validation coverage

`BarrierMessageRegistryTests` verifies:

- happy path: the golden payload dispatches to the decoder registered for the
  frozen marker prefix, the body equals the version bytes, and code plus body
  equal the golden payload exactly; codes of different widths dispatch to their
  own decoders; dispatch is independent of registration order;
- boundaries: payload equal to its code, payloads shorter than a code at every
  length, empty payload, empty registry, codes differing only in the last byte;
- failures: empty, duplicate and ambiguous (both directions) codes; unknown
  payloads (near miss, golden payload without registration, 64 KiB payload)
  never reach a decoder; the diagnostic exposes only `payloadByteCount`;
  decoder failures propagate typed;
- cleanup/idempotency: failed registrations leave the registry unchanged,
  repeated decode returns the same outcome, a decoder failure does not affect
  later dispatch, and registering on a copy does not change the original.

## Rollback

Revert the M1-026 PR. The registry owns no runtime resource, persisted data or
migration, and no production code consumes it yet.
