import Foundation
import KVMContracts

/// The producer-side result of offering one captured event.
package enum CaptureEnqueueResult: Equatable, Sendable {
  /// Stored, or handed directly to a waiting consumer.
  case enqueued
  /// Merged into the newest queued event of the same coalescible kind.
  case coalesced
  /// The queue was full and the event was a pointer move that could not be
  /// merged. A later move carries the newer absolute position.
  case droppedMove
  /// A non-droppable event did not fit. The queue is now latched failed and
  /// the caller must fail open (M2-001 `captureFailure`).
  case overflow
  /// The queue was closed; nothing is stored.
  case closed
}

/// Bounded real-time handoff from an input capture callback to Core.
///
/// The producer side, `enqueue(_:)`, never awaits and never allocates beyond
/// the fixed ring buffer; it is safe to call from an event-tap callback. It
/// only takes a short `NSLock` critical section and may resume a waiting
/// consumer continuation.
///
/// Policy (M2-003):
/// - Order is preserved. Coalescing only merges into the newest queued event,
///   so a move or scroll never jumps over a button, key or control event.
/// - Consecutive pointer moves keep the latest absolute position.
/// - Consecutive scrolls sum their deltas with saturation.
/// - When full, a pointer move that cannot be merged is dropped and reported.
/// - When full, any other event (key, button, scroll, clipboard, screen
///   control) is never dropped silently: the queue discards its contents,
///   latches failed and reports `overflow`; the consumer then receives
///   `inputSafety.cleanupRequired` so fail-safe returns input to local.
///
/// The type is a class guarded by one `NSLock`, hence `@unchecked Sendable`.
/// It never logs and never inspects key identity or text.
package final class CaptureQueue: @unchecked Sendable {
  /// Upper bound accepted by `init(capacity:)`.
  package static let maximumCapacity = 4096

  private enum Phase {
    case open
    case overflowed
    case closed
  }

  private let lock = NSLock()
  private var storage: [KVMEvent?]
  private var head = 0
  private var stored = 0
  private var phase = Phase.open
  private var consumer: CheckedContinuation<KVMEvent?, any Error>?
  private var consumerArrivals: [CheckedContinuation<Void, Never>] = []

  /// Creates a queue holding at most `capacity` events, or `nil` when the
  /// capacity is outside `2...maximumCapacity`.
  package init?(capacity: Int) {
    guard capacity >= 2, capacity <= Self.maximumCapacity else { return nil }
    storage = Array(repeating: nil, count: capacity)
  }

  /// Number of stored events.
  package var count: Int {
    lock.withLock { stored }
  }

  /// True after a non-droppable event did not fit, until `reset()`.
  package var hasOverflowed: Bool {
    lock.withLock { phase == .overflowed }
  }

  /// Offers one event without awaiting. Safe from a real-time callback.
  package func enqueue(_ event: KVMEvent) -> CaptureEnqueueResult {
    lock.lock()
    switch phase {
    case .closed:
      lock.unlock()
      return .closed
    case .overflowed:
      lock.unlock()
      return .overflow
    case .open:
      break
    }
    if let waiting = consumer {
      consumer = nil
      lock.unlock()
      waiting.resume(returning: event)
      return .enqueued
    }
    if stored > 0, let merged = Self.merge(newest: storage[tailIndex]!, with: event) {
      storage[tailIndex] = merged
      lock.unlock()
      return .coalesced
    }
    if stored < storage.count {
      storage[(head + stored) % storage.count] = event
      stored += 1
      lock.unlock()
      return .enqueued
    }
    if case .mouseMove = event {
      lock.unlock()
      return .droppedMove
    }
    phase = .overflowed
    clearStorage()
    lock.unlock()
    return .overflow
  }

  /// Removes up to `maximumCount` events in order without awaiting.
  package func drain(maximumCount: Int) -> [KVMEvent] {
    lock.withLock {
      var result: [KVMEvent] = []
      while stored > 0, result.count < maximumCount {
        result.append(popLocked())
      }
      return result
    }
  }

  /// Awaits the next event for the single consumer.
  ///
  /// Returns `nil` after `close()`. Throws `inputSafety.cleanupRequired` after
  /// overflow and a typed cancellation when the waiting task is cancelled.
  package func next() async throws(CoreError) -> KVMEvent? {
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          lock.lock()
          if let immediate = immediateResultLocked() {
            lock.unlock()
            continuation.resume(with: immediate)
            return
          }
          if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: Self.cancellationError)
            return
          }
          // Single consumer: a second concurrent waiter must not replace the
          // first, which would then never be resumed.
          if consumer != nil {
            lock.unlock()
            continuation.resume(throwing: Self.secondConsumerError)
            return
          }
          consumer = continuation
          let arrivals = consumerArrivals
          consumerArrivals = []
          lock.unlock()
          for arrival in arrivals { arrival.resume() }
        }
      } onCancel: {
        let waiting = lock.withLock {
          let waiting = consumer
          consumer = nil
          return waiting
        }
        waiting?.resume(throwing: Self.cancellationError)
      }
    } catch let error as CoreError {
      throw error
    } catch {
      // Only `CoreError` values are resumed into the continuation.
      throw CoreError(
        code: .internalFailure(.unclassified),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .notRequired
      )
    }
  }

  /// Clears an overflow latch and stored events so capture can restart.
  package func reset() {
    lock.withLock {
      if phase == .overflowed { phase = .open }
      clearStorage()
    }
  }

  /// Discards stored events and finishes the consumer. Idempotent.
  package func close() {
    let waiting = lock.withLock {
      phase = .closed
      clearStorage()
      let waiting = consumer
      consumer = nil
      return waiting
    }
    waiting?.resume(returning: nil)
  }

  /// Test scheduling barrier: completes once a consumer is waiting in `next()`.
  package func waitForPendingConsumer() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if consumer != nil {
        lock.unlock()
        continuation.resume()
        return
      }
      consumerArrivals.append(continuation)
      lock.unlock()
    }
  }

  private static let overflowError = CoreError(
    code: .inputSafety(.cleanupRequired),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .partial
  )

  private static let secondConsumerError = CoreError(
    code: .internalFailure(.preconditionFailed),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  private static let cancellationError = CoreError(
    code: .cancellation(.requested),
    severity: .info,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  private var tailIndex: Int {
    (head + stored - 1) % storage.count
  }

  private func immediateResultLocked() -> Result<KVMEvent?, any Error>? {
    switch phase {
    case .overflowed:
      return .failure(Self.overflowError)
    case .closed:
      return .success(nil)
    case .open:
      return stored > 0 ? .success(popLocked()) : nil
    }
  }

  private func popLocked() -> KVMEvent {
    let event = storage[head]!
    storage[head] = nil
    head = (head + 1) % storage.count
    stored -= 1
    return event
  }

  private func clearStorage() {
    for index in storage.indices { storage[index] = nil }
    head = 0
    stored = 0
  }

  private static func merge(newest: KVMEvent, with event: KVMEvent) -> KVMEvent? {
    switch (newest, event) {
    case (.mouseMove, .mouseMove):
      return event
    case (.scroll(let x1, let y1), .scroll(let x2, let y2)):
      return .scroll(deltaX: saturatingAdd(x1, x2), deltaY: saturatingAdd(y1, y2))
    default:
      return nil
    }
  }

  private static func saturatingAdd(_ a: Int32, _ b: Int32) -> Int32 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    guard overflow else { return sum }
    return b > 0 ? .max : .min
  }
}
