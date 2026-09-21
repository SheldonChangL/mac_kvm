import Foundation

/// A protocol-neutral, ordered byte-stream transport.
///
/// `Transport` owns connection and byte delivery only. It does not interpret
/// frames, protocol messages, events, routing, trust decisions, or input state.
public protocol Transport: Sendable {
  /// Ordered, non-empty byte chunks received during this transport lifecycle.
  ///
  /// Chunk boundaries are implementation details and are not protocol frame
  /// boundaries. The stream has exactly one consumer. Implementations must use
  /// finite buffering, check every continuation yield result, and terminate
  /// with `CoreError.transport(.resourceExhausted)` rather than silently drop,
  /// reorder, or allocate unbounded input when the buffer is full.
  ///
  /// A normal disconnect finishes once. Cancellation and failure finish by
  /// throwing `CoreError`; all other implementation errors must be translated
  /// to `CoreError` before crossing this boundary.
  var incomingBytes: AsyncThrowingStream<Data, any Error> { get }

  /// Establishes the ordered byte stream.
  ///
  /// An instance is single-use. Repeated connect, including after terminal
  /// completion, must fail closed with `CoreError`; reconnect creates a new
  /// transport instance and incoming-byte stream.
  func connect() async throws(CoreError)

  /// Sends every byte in call order after a successful connect.
  ///
  /// An empty value is a successful no-op. The implementation owns partial
  /// write handling; callers never observe or retry a byte suffix themselves.
  func send(_ data: Data) async throws(CoreError)

  /// Ends the lifecycle and releases transport resources.
  ///
  /// This operation must be idempotent, finish `incomingBytes` exactly once,
  /// and must not depend on a successful peer or network response. Cleanup must
  /// complete in bounded time even when the calling task is already cancelled;
  /// cancellation must not skip cleanup or terminal stream delivery.
  func disconnect() async
}
