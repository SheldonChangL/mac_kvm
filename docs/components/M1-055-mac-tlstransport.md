# M1-055 Network.framework TLS Transport Wrapper

## Outcome

`MacPlatform` provides `MacTLSTransport`, a single-use conformer of the frozen
M1-017 `Transport` contract over Network.framework. It is TLS by default, hands
the peer's DER certificate material, in the order delivered by the platform
callback, to an injected trust evaluator during the handshake, and isolates a plaintext development path behind
`#if DEBUG`. It moves opaque bytes only: it parses no frame, protocol message,
or certificate, and it owns no trust policy.

## Contract alignment and scope

- The canonical interface is `Transport` in
  `Packages/KVMContracts/Sources/KVMContracts/Transport.swift`, frozen by
  M1-017. `MacTLSTransport` implements it unchanged: `incomingBytes`,
  `connect() async throws(CoreError)`, `send(_:) async throws(CoreError)`, and
  `disconnect() async`. Every failure crossing the boundary, including the
  terminal error of `incomingBytes`, is a frozen M1-015 `CoreError`.
- No public contract is added, and no frozen contract, ADR, or wire format is
  changed. `KVMContracts` is not edited.
- Scope is exactly the issue's three items: TLS on by default, peer
  certificate material handed to a trust evaluator at the transport layer, and
  a debug-only insecure path isolated by build flag. Changes are limited to the
  three Exact Files:
  - `Packages/MacPlatform/Sources/MacPlatform/MacTLSTransport.swift`
  - `Packages/MacPlatform/Tests/MacPlatformTests/MacTLSTransportTests.swift`
  - `docs/components/M1-055-mac-tlstransport.md`

## Integration surface

Nothing is `public`. The `package` surface is:

| Declaration | Purpose |
| --- | --- |
| `package final class MacTLSTransport: Transport, @unchecked Sendable` | the transport |
| `package convenience init(host:port:trustEvaluator:)` | production entry point: TLS over the Network.framework backend |
| `package let incomingBytes`, `connect()`, `send(_:)`, `disconnect()` | the frozen `Transport` members |
| `package static func debugInsecurePlaintext(host:port:)` | **DEBUG builds only**; absent from release builds |
| `package enum MacTLSTrustDecision: Equatable, Sendable` | `accept` or `reject(SecurityErrorCode)` |

The trust evaluator is `@Sendable ([Data]) -> MacTLSTrustDecision`. It receives
the presented certificates as DER, in the order delivered by the platform
callback, and answers synchronously. M1-055 assigns no leaf or anchor meaning
to array indices. Rejection
codes are the frozen `SecurityErrorCode` values; no new code is introduced.

Internal only (not `package`): `MacTLSTransportSecurity`,
`MacTLSTransportConnectionRequest`, `MacTLSTransportBackend`,
`MacTLSTransportBackendFailure`, `MacTLSTransportBackendRead`,
`MacTLSNetworkBackend`, the four limit constants, and the test-seam
initializers that take a `backendFactory`.

No caller in the repository uses `MacTLSTransport` yet; wiring it into a
session is not part of this issue.

## Production path and TLS default

The production initializer always uses `MacTLSNetworkBackend`, which wraps one
`NWConnection`:

- The only security mode a release build can express is `.tls`.
  `NWParameters(tls:tcp:)` is built from a default `NWProtocolTLS.Options()`
  plus a verify block; no other TLS option (minimum version, ALPN, client
  identity) is set, so platform defaults apply.
- No backend or connection exists before `connect()`. The request is created
  only then.
- Before any connection is created, port `0`, an empty host, or a host
  containing whitespace, newline, or control characters fails as
  `transport.unavailable`.
- `NWConnection.start` and `cancel` both run on one private serial queue, so a
  connection cancelled before start is never started.
- Connection state maps as: `.ready` → success; `.waiting` →
  `unavailable` (no retry, no waiting for a path); `.failed` → mapped error;
  `.cancelled` → `cancelled`.
- `NWError` maps as: POSIX `ECONNREFUSED` → `refused`; `ECONNRESET`/`EPIPE` →
  `reset`; other POSIX, DNS, Wi-Fi Aware, and unknown → `unavailable`; TLS →
  `tlsFailure`. Any error after this backend was cancelled is `cancelled`.

## TLS verification

The backend installs a verify block with
`sec_protocol_options_set_verify_block`. The block extracts the peer chain,
asks the transport, and completes with `accepted && !chain.isEmpty`. **System
trust is not consulted** and nothing is auto-accepted: the evaluator is the
sole trust authority.

- **DER handoff in platform callback order.** Certificates are collected in
  the order `sec_protocol_metadata_access_peer_certificate_chain` invokes its
  handler, converted with `SecCertificateCopyData`, and passed unchanged.
  Neither the SDK header nor Apple's documentation guarantees a leaf-first
  order, so M1-055 promises none and assigns no leaf or anchor meaning to
  array indices. Collection is bounded by the
  chain limits below; once a limit is exceeded, everything collected is dropped
  and later certificates are ignored, so an oversized chain is never
  accumulated. An unavailable chain is also empty.
- **Shape check before evaluation.** An empty chain, more than 10
  certificates, or more than 256 KiB of total DER is rejected as
  `security.trustRejected` without consulting the evaluator. The byte total is
  checked against a remaining budget, so it cannot overflow.
- **Repeated verify callbacks.** `SecProtocolOptions.h` allows the verify block
  to run more than once per connection. Every valid callback while connecting
  consults the evaluator exactly once, in callback order: when the backend
  invokes callback A and then callback B sequentially, A is evaluated before
  B. This is the order of callbacks, not of certificates within one chain.
- **Sticky rejection.** The first rejection (evaluator or shape) is recorded
  and wins over any earlier acceptance; later callbacks are answered `false`
  without consulting the evaluator again.
- **Ready requires verification.** A TLS handshake that reports ready without
  any accepted verify callback fails closed as `security.trustRejected`.
- **`identityChanged` preservation.** When connect fails, a recorded rejection
  takes precedence over the backend's generic `tlsFailure`, so
  `reject(.identityChanged)` surfaces as exactly `security.identityChanged`,
  distinct from `security.trustRejected`. A backend `tlsFailure` with no
  recorded rejection maps to `security.trustRejected`.
- A decision arriving after the lifecycle ended is discarded.
- **No trust persistence or policy.** This issue stores no certificate,
  fingerprint, pin, or decision, and implements no pairing, trust-on-first-use,
  fingerprint comparison, or identity-change policy. Those belong to later E07
  issues; the caller supplies the evaluator.

## Limits

| Limit | Value | Behavior |
| --- | --- | --- |
| `maximumReceiveLength` | 65,536 bytes (64 KiB) | every backend read asks for at most this; a read returning more fails `transport.resourceExhausted` without being yielded |
| `incomingChunkBufferLimit` | 16 chunks (≤ 16 × 64 KiB ≈ 1 MiB) | `AsyncThrowingStream` with `.bufferingOldest(16)` |
| `maximumPeerCertificateCount` | 10 | an 11th certificate rejects the chain |
| `maximumPeerCertificateBytes` | 262,144 bytes (256 KiB), whole chain | one byte more rejects the chain |

## Lifecycle

State is `idle → connecting → connected → terminated`, guarded by one `NSLock`
(hence `@unchecked Sendable`). No closure, continuation, backend call, stream
yield or finish, or task cancellation runs while the lock is held.

- **Single use.** Only the first `connect()` from `idle` proceeds. A concurrent
  or repeated connect, including after any terminal state, fails with the
  misuse error and creates no second backend. Reconnect means a new instance.
- **Ordered receive.** After ready, one receive task keeps exactly one backend
  read outstanding. Non-empty chunks are yielded in order; empty reads are
  skipped, never yielded.
- **Finite buffer overflow.** Every yield result is checked. On `.dropped` the
  stream fails with `transport.resourceExhausted`; the 16 chunks already
  buffered are delivered first, in order, and receiving stops. On `.terminated`
  the lifecycle ends.
- **Peer end of stream** fails the stream with `transport.disconnected`
  (retry `backoff`). Only a local `disconnect()` finishes the stream normally.
- **Ordered send.** Sends are serialized FIFO in lock-acquisition order, so a
  sequentially awaited send completes before the next begins and concurrent
  sends never interleave. An empty `Data` after connect is a no-op that reaches
  no backend. A failed send is terminal: it throws the mapped error, cancels
  the backend, and fails the stream with the same error.
- **Cancellation.** Task cancellation during connect terminates the lifecycle,
  cancels the backend once, throws `cancellation.requested`, and fails the
  stream with it. `disconnect()` during connect cancels the handshake; connect
  throws `cancellation.requested` while the stream finishes normally. If the
  single consumer cancels its iteration, the backend is cancelled once and
  later sends fail closed.
- **Idempotent, bounded disconnect.** `disconnect()` is synchronous: it never
  awaits the peer, so it completes even from an already cancelled task. The
  first terminal transition cancels the receive task and backend, resumes
  queued senders, and finishes the stream exactly once; later calls do
  nothing. A receive failure caused by that cancellation cannot turn a normal
  finish into a failure.

## Typed errors

| Condition | `CoreError` code | Severity | Retry | Cleanup |
| --- | --- | --- | --- | --- |
| Send before connect; repeated connect | `internal.preconditionFailed` | `error` | `never` | `notRequired` |
| Send after the lifecycle ended | `transport.disconnected` | `error` | `never` | `notRequired` |
| Task cancellation, disconnect during connect, backend `cancelled` | `cancellation.requested` | `info` | `never` | `completed` |
| Trust rejection, bad chain shape, unverified ready, TLS failure | `security.<code>` (evaluator's code, else `trustRejected`) | `error` | `userActionRequired` | `completed` |
| `unavailable` / `refused` / `reset` / `disconnected` | `transport.<same>` | `error` | `backoff` | `completed` |
| `timedOut` | `timeout.connect` / `timeout.write` / `timeout.read` by phase | `error` | `backoff` | `completed` |
| Oversized read, buffer overflow | `transport.resourceExhausted` | `error` | `backoff` | `completed` |
| Peer end of stream | `transport.disconnected` | `error` | `backoff` | `completed` |

No failure sets `underlyingDiagnosticCode`.

## DEBUG-only plaintext path

`MacTLSTransportSecurity.debugInsecurePlaintext`, both
`debugInsecurePlaintext` factories, and every plaintext branch exist only
inside `#if DEBUG`. The debug path uses `NWParameters.tcp`, installs no verify
block, and never consults or accepts a trust decision (its internal evaluator
is a fixed rejection that is never called). It must be selected explicitly;
there is no plaintext fallback from TLS.

In release builds the case, factories, and branches are compiled out, so a
release build cannot express a plaintext request. This is enforced by
conditional compilation and checked by a static source audit; no release-
configuration build has been run for this issue yet.

## Privacy, logging, and key handling

- No production path logs or emits a diagnostic.
- No failure carries host, payload bytes, certificate material, or a platform
  error, code, or message; backend failures are stripped to a closed enum
  before mapping.
- Certificate DER is passed to the evaluator and not retained by the
  transport or backend.
- No private key, client identity, password, or other secret is handled, and
  nothing is written to UserDefaults, a plist, JSON, the Keychain, or a log.
  What the evaluator does with the chain is the responsibility of the later
  trust issues that supply it.

## Deterministic test seam and coverage

Every test except one drives the transport through `FakeTLSBackend`, an
in-memory, lock-guarded backend that records `start`, each evaluation, `ready`,
each receive length, each send, and `cancel` in order. No such test opens a
socket, sleeps, or reads a clock; tests wait on the event log with
`waitUntil`. Certificates are synthetic DER-shaped bytes and are never parsed.

The one test using the production backend,
`tlsTransportDefaultBackendRejectsAnInvalidEndpointWithoutNetwork`, connects to
host `""`, port `0`, with a rejecting evaluator. The backend rejects the
endpoint before creating any connection, so no network is used; connect and
the stream both fail with `transport.unavailable`.

The 35 test functions in `MacTLSTransportTests.swift` cover:

- `Transport` conformance; the TLS request created only at connect;
- the static `#if DEBUG` source audit, and (DEBUG) explicit plaintext selection
  with no evaluation;
- presented chain forwarded unchanged and evaluated exactly once before
  ready; every
  `SecurityErrorCode` rejection surfacing exactly; `identityChanged` distinct
  from `trustRejected`; empty chain rejected without evaluation;
- two verify callbacks evaluated once each in order; a later
  `identityChanged` failing closed despite an earlier accept;
- fixed chain limits; a chain at both limits accepted; 11 certificates or
  256 KiB + 1 rejected without evaluation; ready without verification failing
  closed; a rejected peer unable to send or reconnect;
- send before connect, single-use connect, concurrent second connect, and
  disconnect before connect;
- connect failure mapping for all seven backend failures, send mapping for
  four, receive mapping for four, each terminal and cancelling once;
- ordered chunks with empty reads skipped; 64 KiB read requests; a 64 KiB + 1
  read failing `resourceExhausted`; buffer overflow delivering 16 ordered
  chunks then `resourceExhausted`; peer end of stream as `disconnected`;
- ordered sends with empty sends as no-ops;
- idempotent disconnect finishing once, disconnect from a cancelled task, task
  cancellation and disconnect during connect, and consumer cancellation; and
- privacy: five failures encode to exactly `code`, `severity`,
  `retryDisposition`, `cleanupDisposition`, with no host, payload, or platform
  name in any rendering.

## Validation status

- `swift test --package-path Packages/MacPlatform`, run by Codex after
  remediation: 118 tests passed, 0 failed; 3 opt-in manual probes unrelated to
  M1-055 were skipped.
- Pending: `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM
  -destination 'platform=macOS' build`, `python3
  Tools/Backlog/validate_package.py`, `make architecture-check`, lint, the
  `evidence/issues/M1-055/` package, and security review.
- M1-055 has no mandatory manual step. No real peer or network
  interoperability has been tested.

## Out of scope

- Trust store, fingerprint computation or comparison, pinning, pairing,
  trust-on-first-use, identity-change policy, or any persistence (later E07
  issues).
- Wiring into a Barrier or native session; protocol messages; framing.
- Reconnect, retry, backoff, or transport-owned timeouts.
- Client certificates, ALPN, or custom TLS versions and ciphers.
- UI, diagnostics, or any public API.

## Known limitations

- **Real network path not exercised.** The TLS handshake, verify-block
  invocation, chain extraction, and `NWError` mapping are verified only by
  compilation and the seam; only invalid-endpoint rejection runs the
  production backend.
- **Release behavior is static evidence.** Plaintext exclusion from release
  builds is shown by conditional compilation and a source audit, not by a
  release build or runtime test.
- **The evaluator runs synchronously** inside the verify block on the
  backend's serial queue. A slow evaluator stalls the handshake.
- **No transport-owned timeout.** The production backend never emits
  `timedOut`; a stalled handshake or read lasts until the platform fails it or
  the caller cancels or disconnects.
- **No certificate ordering contract.** Certificates are forwarded in platform
  callback order only. Later fingerprint and trust policy work must establish
  which certificate to use from a verified API or contract, and must not assume
  element zero is the leaf solely from this callback.
- `.waiting` fails immediately as `unavailable` rather than waiting for a
  network path.
- A production chain that exceeds a limit collapses to an empty chain, so it
  is indistinguishable from a missing chain; both are `trustRejected`.
- A clean peer close is reported as a `transport.disconnected` failure, not a
  normal finish.
- Outbound sends have no transport size cap; each `Data` is handed to
  `NWConnection` whole.

## Rollback

Remove or revert the three M1-055 Exact Files. No other file depends on them,
and there is no persisted state, trust data, migration, or runtime resource to
clean up.
