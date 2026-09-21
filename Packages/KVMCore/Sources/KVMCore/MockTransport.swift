import Foundation
import KVMContracts

/// How a scripted ``MockTransport`` lifecycle ends once its inbound script is
/// exhausted.
///
/// The frozen `Transport` contract has exactly three terminal outcomes, so this
/// control surface offers exactly those and no additional semantics.
package enum MockTransportCompletion: Sendable {
  /// Leave `incomingBytes` open until `disconnect()` performs cleanup.
  case openUntilDisconnect
  /// Finish `incomingBytes` once as a normal end of stream.
  case endOfStream
  /// Finish `incomingBytes` once by throwing this exact typed failure.
  ///
  /// A cancellation-domain `CoreError` is injected through this case; the
  /// contract expresses cancellation as a typed terminal failure rather than a
  /// separate channel.
  case failure(CoreError)
}

/// A resource-free `Transport` test double.
///
/// The double owns no socket, network, TLS, protocol, frame, or platform state.
/// It scripts ordered non-empty inbound chunks, records ordered outbound bytes,
/// and injects the three terminal outcomes the contract allows.
///
/// Visibility is deliberately `package`: the `Transport` interface itself stays
/// the only public contract, while this concrete double remains reachable to
/// first-party test targets in the same package without adding public API.
package actor MockTransport: Transport {
  package nonisolated let incomingBytes: AsyncThrowingStream<Data, any Error>

  /// Successful `connect()` calls observed by this instance.
  package private(set) var connectCount = 0
  /// Cleanup executions observed by this instance; repeated cleanup is skipped.
  package private(set) var disconnectCount = 0
  /// Non-empty outbound values in the order `send(_:)` accepted them.
  package private(set) var recordedOutbound: [Data] = []

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let scriptedInbound: [Data]
  private let completion: MockTransportCompletion

  private var hasConnected = false
  private var hasDisconnected = false
  private var isTerminal = false

  /// Creates a single-use double.
  ///
  /// - Parameters:
  ///   - inbound: ordered chunks delivered on `connect()`. Every chunk must be
  ///     non-empty because the contract never emits empty chunks.
  ///   - completion: the terminal outcome applied after the script drains.
  ///   - incomingBufferLimit: the finite buffer depth. Exceeding it fails
  ///     closed with `transport.resourceExhausted` instead of dropping bytes.
  package init(
    inbound: [Data] = [],
    completion: MockTransportCompletion = .openUntilDisconnect,
    incomingBufferLimit: Int = 8
  ) throws(CoreError) {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(incomingBufferLimit)
    )
    incomingBytes = stream
    self.continuation = continuation
    scriptedInbound = inbound
    self.completion = completion

    guard incomingBufferLimit > 0, inbound.allSatisfy({ !$0.isEmpty }) else {
      continuation.finish()
      throw Self.preconditionFailure()
    }
  }

  package func connect() async throws(CoreError) {
    guard !hasConnected, !isTerminal else {
      throw Self.preconditionFailure()
    }

    hasConnected = true
    connectCount += 1
    deliverScriptedInbound()
  }

  package func send(_ data: Data) async throws(CoreError) {
    guard hasConnected, !hasDisconnected, !isTerminal else {
      throw CoreError(
        code: .transport(.disconnected),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .completed
      )
    }
    guard !data.isEmpty else { return }

    recordedOutbound.append(data)
  }

  package func disconnect() async {
    guard !hasDisconnected else { return }

    hasDisconnected = true
    disconnectCount += 1
    finishNormally()
  }

  private func deliverScriptedInbound() {
    for chunk in scriptedInbound {
      guard !isTerminal else { return }

      switch continuation.yield(chunk) {
      case .enqueued:
        continue
      case .dropped:
        finish(throwing: Self.resourceExhausted())
        return
      case .terminated:
        isTerminal = true
        return
      @unknown default:
        finish(throwing: Self.preconditionFailure())
        return
      }
    }
    applyCompletion()
  }

  private func applyCompletion() {
    switch completion {
    case .openUntilDisconnect:
      return
    case .endOfStream:
      finishNormally()
    case .failure(let error):
      finish(throwing: error)
    }
  }

  private func finishNormally() {
    guard !isTerminal else { return }

    isTerminal = true
    continuation.finish()
  }

  private func finish(throwing error: CoreError) {
    guard !isTerminal else { return }

    isTerminal = true
    continuation.finish(throwing: error)
  }

  private static func preconditionFailure() -> CoreError {
    CoreError(
      code: .internalFailure(.preconditionFailed),
      severity: .error,
      retryDisposition: .never,
      cleanupDisposition: .notRequired
    )
  }

  private static func resourceExhausted() -> CoreError {
    CoreError(
      code: .transport(.resourceExhausted),
      severity: .error,
      retryDisposition: .backoff,
      cleanupDisposition: .notRequired
    )
  }
}
