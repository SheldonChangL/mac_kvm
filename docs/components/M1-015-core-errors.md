# M1-015 Core Error, Result, and Cancellation Taxonomy

## Outcome

`KVMContracts` provides one typed, platform-neutral failure model for protocol
adapters, transport, Core, security, permission, input safety, clipboard, and
lifecycle work. The model implements the closed taxonomy accepted by the
M1-011 privacy-safe logging ADR without carrying arbitrary error text.

## Error model

`CoreError` is an immutable `Error`, `Codable`, `Hashable`, and `Sendable`
value containing only:

- a closed `CoreErrorCode`;
- a closed severity;
- a retry disposition;
- a cleanup disposition; and
- an optional signed 32-bit `UnderlyingDiagnosticCode`.

`CoreErrorCode` couples a domain with that domain's typed code enum, preventing
invalid domain/code combinations. Its domains and minimum codes are exactly the
M1-011 allowlist:

- cancellation: requested, superseded, shutdown;
- timeout: connect, handshake, read, write, keepalive, cleanup;
- transport: unavailable, disconnected, refused, reset, resource exhausted;
- protocol: malformed, oversized, unsupported version/message, invariant
  violation;
- security: unknown/changed/revoked identity, trust rejected, secure storage
  unavailable;
- permission: accessibility denied, capability unavailable;
- input safety: cleanup required/partial/failed, local-state restore failed;
- clipboard: unsupported type, invalid UTF-8, oversized, loop rejected;
- lifecycle: sleep, wake, termination, subsystem unavailable; and
- internal: unclassified, precondition failed, state invariant violation.

The Swift cases `protocolViolation` and `internalFailure` use raw diagnostic
domain values `protocol` and `internal`, avoiding language-keyword ambiguity
without changing the accepted domain names.

## Result and cancellation

`CoreResult<Success>` is the canonical `Result<Success, CoreError>` alias.
Cancellation remains a typed failure through `CancellationReason`; it is never
silently converted into success.

Retry dispositions are:

- `never`: no retry;
- `userActionRequired`: retry is possible only after explicit user action and
  is never automatic;
- `backoff`: automatic retry is allowed after the owning component's bounded
  backoff policy; and
- `immediateAfterStateChange`: automatic retry is allowed only after a verified
  relevant state change.

This Issue classifies retry eligibility. It does not define timers, backoff
durations, retry counts, or scheduling.

Cleanup disposition is independent of retry. A caller must not infer that a
retryable error completed input cleanup, and a failed/partial cleanup must not
be reported as success.

## Diagnostic privacy

The error value has no message, description, arbitrary dictionary, raw bytes,
generic underlying `Error`, reflection dump, stack arguments, path, address,
peer identity, fingerprint, typed text, clipboard content, secret, or key
material field. The optional underlying code preserves only a bounded numeric
status for mapping and debugging.

Conformance to `Codable` is not authorization to log a `CoreError` directly.
M1-011 still requires an approved event id and metadata schema before any
numeric status or taxonomy field crosses the diagnostic boundary. Unknown enum
values fail decoding instead of selecting a fallback. Unmapped implementation
errors must become `internal.unclassified` without their source text.

## Validation coverage

Tests verify:

- one typed code maps to each frozen domain and every domain is represented;
- every frozen leaf-code, severity, and cleanup allowlist is exact;
- CoreError satisfies its value/concurrency/coding contracts and round-trips;
- encoded errors contain no message or description field;
- retryable, automatic-retry, and user-action semantics are distinct;
- signed 32-bit underlying-code boundaries round-trip unchanged;
- unknown domain and retry values fail decoding;
- cancellation remains a typed terminal `CoreResult` failure; and
- all prior KVMEvent and identifier tests remain green.

These declarations own no task, timer, connection, input state, or other
runtime resource. They record cancellation and cleanup outcomes but do not
perform cleanup; executable cleanup and idempotency tests belong to the
components that own those resources.

## Architecture and scope boundaries

No Barrier/native message code, socket/network implementation, platform error
object, OS input code, UI state, logging sink, trust decision, timer, or retry
loop is introduced. The taxonomy is not a wire protocol; M3-010 separately owns
wire-visible Native Protocol error codes.

The M1-011 event catalog and closed event-specific stage allowlists remain
deferred to the first Issue that emits production diagnostics. M1-015 does not
invent a generic stage field or weaken the requirement that event catalogs
review each emitted field.

## Rollback

Revert the M1-015 PR and keep all dependent session, transport, codec,
permission, clipboard, and trust Issues blocked until the typed failure boundary
is restored. No runtime resource, persisted data, or migration requires cleanup.
