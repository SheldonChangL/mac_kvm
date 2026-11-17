# M1-055-FOLLOWUP-001 Linux TLS Transport

## Outcome

`LinuxTLSTransport` is the Linux conformer of the C-002 `Transport` contract. It
opens one TLS connection to the Mac server with swift-nio-ssl and pins the
server's identity through the C-009 trust policy: the SHA-256 of the leaf
certificate's DER is compared by an injected trust evaluator. The pinning rules
and the lifecycle rules below are first-party; no Barrier behavior is involved.
The transport moves opaque bytes; the Barrier wire belongs to the client session.

Exact Files:

- `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTLSTransport.swift`
- `Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxTLSTransportTests.swift`
- `docs/platform/linux/M1-055-FOLLOWUP-001-linux-tls-transport.md`
- `evidence/issues/M1-055-FOLLOWUP-001/`

Depends on M4-020 (the Linux package and `verify-linux`), M1-017, M1-056 (as the
contract reference), C-002 and C-009. The Mac counterpart is `MacTLSTransport`.

## API

```swift
package enum LinuxTLSTrustDecision: Equatable, Sendable { case accept; case reject(SecurityErrorCode) }
package struct LinuxTLSConnectionRequest: Equatable, Sendable {
  package init(host: String, port: UInt16, connectTimeout: Duration)
}
package final class LinuxTLSTransport: Transport, @unchecked Sendable {
  package static let inboundHighWaterBytes: Int  // 256 KiB: socket reads pause (M1-055-FOLLOWUP-002)
  package static let inboundLowWaterBytes: Int  // 64 KiB: socket reads resume
  package static let maximumBufferedBytes: Int  // 1 MiB: hard ceiling, resourceExhausted
  package static let maximumChunkLength: Int  // 16 KiB
  package init(request: LinuxTLSConnectionRequest, group: any EventLoopGroup,
               trustEvaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision)
  package let incomingBytes: AsyncThrowingStream<Data, any Error>
  package func connect() async throws(CoreError)
  package func send(_ data: Data) async throws(CoreError)
  package func disconnect() async
  package var presentedFingerprint: Data? { get }
  package func isNoDelayEnabled() async -> Bool  // for tests
  package var bufferedByteCount: Int { get }  // for tests
  package var peakBufferedByteCount: Int { get }  // for tests
}
```

The event loop group is borrowed: the composition root owns it and shuts it
down. The evaluator receives the 32-byte digest and must not block, because it
runs on the event loop inside the handshake.

## Pinning (first-party, C-009)

1. The client configuration is `TLSConfiguration.makeClientConfiguration()` with
   `minimumTLSVersion = .tlsv12` and `certificateVerification = .noHostnameVerification`.
   No server name is sent (`serverHostname: nil`).
2. `customVerificationCallback` replaces chain validation. It hashes the DER of
   the first presented certificate, the leaf, with SHA-256 (swift-crypto). It
   never hashes the rest of the chain.
3. The evaluator is asked once per connect. The answer is latched: a repeated
   callback returns the same answer without asking again.
4. Only `.accept` answers `.certificateVerified`. Every other outcome answers
   `.failed`, which aborts the handshake before the client sends its Finished
   message. No application byte can be sent: `send` refuses until `connect()`
   has returned.
5. An empty chain or more than 10 certificates is rejected without asking.
6. `connect()` throws the rejection's code, with `.userActionRequired`:

| Evaluator answer | `connect()` throws |
| --- | --- |
| `.reject(.identityUnknown)` (nothing stored) | `security(.identityUnknown)` |
| `.reject(.identityChanged)` (stored pin differs) | `security(.identityChanged)` |
| `.reject(.trustRejected)` (for example a digest that is not 32 bytes) | `security(.trustRejected)` |
| any TLS failure (protocol version, alert, bad record) before the handshake completes | `security(.trustRejected)` |

7. A handshake that completes without an accepted verification fails closed
   with `trustRejected`, as a second line behind the callback. This guard is
   defense in depth and not reachable through swift-nio-ssl today: a handshake
   cannot complete unless the callback answered `.certificateVerified`, and the
   callback answers that only after an accept. No test reaches it, so no mutant
   of it is recorded.
8. After a rejection the presented fingerprint is kept in `presentedFingerprint`
   so the command line can display it next to the stored one (plan a.7). It is
   never kept after an accept, and nothing logs it.

## Why `.noHostnameVerification`

swift-nio-ssl validates the server name after the custom callback unless the
configuration says otherwise. The Mac identity is a self-signed P-256
certificate that names no host, and the pin is a stronger check than a name.
`.none` is not used: it would skip the custom callback and accept anything.

## Lifecycle

- One `NSLock` guards the state. No channel call, continuation, stream yield or
  finish runs while it is held.
- An instance is single-use. A second `connect()`, also after a terminal end,
  throws `internalFailure(.preconditionFailed)`.
- `connect()` is bounded by `connectTimeout`: the bootstrap's TCP connect
  timeout and one event-loop deadline that covers the TCP connect and the
  handshake together. Expiry throws `timeout(.connect)` with `.backoff`.
- `TCP_NODELAY` is set on the socket (the Mac listener does the same).
- Task cancellation during `connect()` and `disconnect()` during `connect()`
  close the socket and end `connect()` with `cancellation(.requested)` at once.
- `send` before `connect()` throws `internalFailure(.preconditionFailed)`;
  after the end it throws `transport(.disconnected)`. An empty send is a no-op.
  Writes go through the channel in call order; NIO handles partial writes.
- `disconnect()` is synchronous and idempotent: it closes the channel, cancels
  the deadline and finishes `incomingBytes` once. It does not wait for the
  peer, so it is bounded even when the calling task is already cancelled.

## Incoming bytes

- `incomingBytes` is pull-driven (M1-055-FOLLOWUP-002). Decrypted bytes wait
  in a byte-counted queue, split into chunks of at most `maximumChunkLength`
  (16 KiB); each `next()` takes the oldest chunk.
- Backpressure: once the queue holds `inboundHighWaterBytes` (256 KiB), the
  inbound handler (after the TLS handler) holds the channel's `read` event, so
  no further socket read happens and TCP flow control slows the peer. When the
  consumer drains the queue below `inboundLowWaterBytes` (64 KiB), the held
  read is re-issued on the event loop. A slow consumer therefore receives any
  amount of data in order without the session ending (a 600 KB clipboard
  previously overflowed the old 16-chunk `bufferingOldest` stream and ended
  with `resourceExhausted`, issue #372).
- One socket read already in flight can still land after the pause, so the
  queue may pass the high-water mark by about one read. `maximumBufferedBytes`
  (1 MiB) is a hard ceiling: a read that would pass it ends the stream with
  `transport(.resourceExhausted)` after the chunks already queued, in order.
  Nothing is silently dropped. Protocol and clipboard size limits (1 MiB
  clipboard) are enforced above the transport and are unchanged.
- A cancelled consumer task ends the lifecycle (the channel closes); a second
  concurrent consumer is refused with `internalFailure(.preconditionFailed)`.
- The peer closing the connection with a TLS `close_notify` finishes the
  stream normally, once, after the data it sent (plan a.5: a clean end that the
  reconnect manager retries). A bare TCP FIN after the handshake, without
  `close_notify`, is an unclean shutdown: NIOSSL reports it as an error, and
  the stream ends with `transport(.reset)`.
- The channel is stored when the TCP connect completes, on the channel's event
  loop. The handshake needs further round trips on that loop, so the channel
  is always stored before the phase becomes connected and before `send` looks
  for it.
- A TLS or socket error after the handshake ends the stream with
  `transport(.reset)` or the mapped network code, never with a security code,
  so a broken connection is retried with back-off.
- If the consumer stops iterating, the transport ends its lifecycle.

## Errors

| Situation | `CoreError` | Retry |
| --- | --- | --- |
| TCP refused | `transport(.refused)` | `.backoff` |
| host unreachable, name not resolved | `transport(.unavailable)` | `.backoff` |
| reset or broken pipe | `transport(.reset)` | `.backoff` |
| no handshake within `connectTimeout` | `timeout(.connect)` | `.backoff` |
| peer closed before the handshake completed | `transport(.disconnected)` | `.backoff` |
| trust rejection or TLS failure | `security(...)`, see Pinning | `.userActionRequired` |
| queue past `maximumBufferedBytes` (1 MiB) | `transport(.resourceExhausted)` | `.backoff` |
| cancelled | `cancellation(.requested)` | `.never` |
| misuse | `internalFailure(.preconditionFailed)` | `.never` |

No error carries a host, bytes, certificate material or a TLS diagnostic.

## Proof against the Mac server identity

The issue's first task was to prove that swift-nio-ssl pins the real Mac server
identity, a P-256 self-signed certificate over TLS 1.3 (the open question in
M4-001). On 2026-11-17 the implementer ran the `MacKVM smoke` server on the Mac
with a throwaway identity label, loopback only, and ran the optional suite
`LinuxTLSTransportLoopbackTests` in a Linux container against it, with the
endpoint and the pin passed in environment variables. The pinned identity was
accepted and a pin with one byte changed was rejected with `identityChanged`.
`openssl s_client` from the same container reported TLS 1.3, an ECDSA
signature and a 256-bit server key. The identity was deleted afterwards. No
fingerprint was recorded. The fallback to system OpenSSL is not needed.

To repeat it, set `MACKVM_TLS_LOOPBACK_ENDPOINT=<host>:<port>` and
`MACKVM_TLS_LOOPBACK_PIN=<64 hex digits>` and run
`swift test --filter LinuxTLSTransportLoopbackTests`. Without them the suite
is skipped.

## Tests

The tests run on Linux only (`make verify-linux`). Each test starts an
in-process NIOSSL server on 127.0.0.1 with a certificate that `openssl` makes
in a temporary directory (`openssl` is installed by `verify-linux`):

- a matching pin: bytes both ways in order, `TCP_NODELAY` set, the evaluator
  asked once with the leaf pin, nothing kept in `presentedFingerprint`;
- the evaluator receives the leaf digest, not a digest of the chain, with a
  two-certificate chain (leaf and its CA);
- an unknown identity, a changed identity and a wrong digest length: the mapped
  security error, the server never completes the handshake and receives no
  application byte, and the fingerprint is kept;
- a server limited to TLS 1.1: refused, the evaluator is never asked;
- end of stream, send before connect, a second connect, task
  cancellation and `disconnect()` during connect, a handshake timeout, a refused
  connection, and `disconnect()` twice, also from a cancelled task;
- a 200,000-byte server write arrives in chunks of at most 16 KiB, in order;
- M1-055-FOLLOWUP-002: a consumer stalled for 500 ms then reading slowly
  receives a 1 MiB patterned payload in order with the session still usable;
  a stalled consumer facing 4 MiB keeps the queue at the high-water mark,
  well under the 1 MiB ceiling, then receives all 4 MiB in order; and the
  Linux client runtime (`Tests/Integration/LinuxClientRuntimeTests.swift`) over
  the real `LinuxTLSTransport` and an in-process first-party Barrier server
  writes a 600 KB server clipboard sent on enter, with no reconnect;
- bytes that are not a TLS record, written after the handshake, end the stream
  with `transport(.reset)` and `.backoff`.

Both suites have a one-minute time limit, so a mutant that makes a test wait
fails instead of hanging.

## Privacy

Nothing in this file logs. The fingerprint is exposed only through
`presentedFingerprint` after a rejection, for the deliberate display described
in plan a.7. It is for display only: callers must never log it, put it in an
error or send it anywhere.

The cipher suites are swift-nio-ssl's defaults for a client configuration;
only the minimum version (TLS 1.2) is set here. A change of the swift-nio-ssl
pin can change the suites and needs a security look. The tests use ephemeral certificates and no real host's
fingerprint.

## Known limitations

- `NIOTLS` (for `TLSUserEvent.handshakeCompleted`) is imported as a transitive
  module of swift-nio, which the LinuxPlatform target already depends on through
  swift-nio-ssl. `Package.swift` does not list the `NIOTLS` product, because only
  its owners may change it; M4-020-FOLLOWUP-001 should add it to the target's
  dependencies.
- C-009's revoked state is not produced here; the evaluator decides it.
- The certificate's validity dates are not checked, as on the Mac: the pin is
  the identity.
