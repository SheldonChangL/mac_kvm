/// The closed, privacy-safe reason supplied when a protocol session is ended.
///
/// Protocol adapters may refine a terminal failure into `CoreError`, but must
/// not attach arbitrary protocol text, peer data, typed input, or clipboard
/// content to a disconnect reason.
public enum DisconnectReason: Codable, Equatable, Sendable {
  /// The user or application explicitly requested a normal disconnect.
  case userRequested

  /// The peer completed an orderly transport shutdown.
  case transportClosed

  /// Structured concurrency cancelled the owning operation.
  case cancellation(CancellationReason)

  /// A typed terminal failure ended the session.
  case failure(CoreError)

  /// Application termination requested a normal, bounded shutdown.
  case applicationTermination
}

/// A protocol-neutral session boundary shared by Barrier and native adapters.
///
/// Conforming adapters translate between protocol traffic and `KVMEvent`.
/// They must not expose wire message codes, socket implementations, or platform
/// input types through this interface.
public protocol KVMProtocolSession: Sendable {
  /// The ordered event stream for the current session lifecycle.
  ///
  /// A normal disconnect finishes the stream once. Cancellation and failure
  /// finish it by throwing a `CoreError`. Implementations must map all other
  /// implementation errors to `CoreError` before crossing this boundary. The
  /// stream has exactly one consumer; creating multiple iterators is invalid.
  var events: AsyncThrowingStream<KVMEvent, any Error> { get }

  /// Connects and completes only after the protocol session can send events.
  ///
  /// A session instance is single-use. Repeated connect, including after a
  /// terminal result, must fail closed with `CoreError`; reconnect creates a
  /// new session instance and event stream.
  func connect() async throws(CoreError)

  /// Encodes and sends one platform-neutral event in session order.
  func send(_ event: KVMEvent) async throws(CoreError)

  /// Ends the lifecycle and releases protocol/transport resources.
  ///
  /// This operation is asynchronous so callers can await terminal stream
  /// delivery and resource cleanup. It must be idempotent and must not depend
  /// on a successful network response. Cleanup must complete in bounded time
  /// even when the calling task is already cancelled; cancellation must not
  /// cause an early return that skips cleanup or terminal stream delivery.
  func disconnect(reason: DisconnectReason) async
}
