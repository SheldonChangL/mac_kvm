/// A replaceable monotonic delay boundary for timeout and backoff scheduling.
///
/// Callers own timeout and retry policy. A clock only suspends for the supplied
/// non-negative duration and never uses wall-clock time, calendar time, or a
/// protocol/network implementation.
public protocol KVMClock: Sendable {
  /// Suspends for `duration`, or throws a typed cancellation/failure.
  ///
  /// Zero completes immediately after checking task cancellation. Negative
  /// durations fail closed with `internal.preconditionFailed`.
  func sleep(for duration: Duration) async throws(CoreError)
}

/// The production monotonic clock backed by Swift's `ContinuousClock`.
public struct ContinuousKVMClock: KVMClock {
  public init() {}

  public func sleep(for duration: Duration) async throws(CoreError) {
    guard duration >= .zero else {
      throw ClockError.invalidDuration()
    }
    guard !Task.isCancelled else {
      throw ClockError.cancelled()
    }
    guard duration > .zero else { return }

    do {
      try await ContinuousClock().sleep(for: duration)
    } catch is CancellationError {
      throw ClockError.cancelled()
    } catch {
      throw ClockError.unclassifiedFailure()
    }
  }
}

/// A manually advanced monotonic clock for deterministic tests.
///
/// `advance(by:)` resumes every sleep whose deadline has been reached, ordered
/// first by deadline and then by registration. It never waits for wall time.
public actor TestKVMClock: KVMClock {
  private struct PendingSleep {
    let deadline: Duration
    let registrationOrder: UInt64
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct CountWaiter {
    let expectedCount: Int
    let continuation: CheckedContinuation<Void, any Error>
  }

  public private(set) var elapsed: Duration = .zero

  public var pendingSleepCount: Int {
    pendingSleeps.count
  }

  private var nextIdentifier: UInt64 = 0
  private var pendingSleeps: [UInt64: PendingSleep] = [:]
  private var countWaiters: [UInt64: CountWaiter] = [:]

  public init() {}

  public func sleep(for duration: Duration) async throws(CoreError) {
    guard duration >= .zero else {
      throw ClockError.invalidDuration()
    }
    guard !Task.isCancelled else {
      throw ClockError.cancelled()
    }
    guard duration > .zero else { return }

    let identifier = makeIdentifier()
    let deadline = elapsed + duration

    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          pendingSleeps[identifier] = PendingSleep(
            deadline: deadline,
            registrationOrder: identifier,
            continuation: continuation
          )
          resumeSatisfiedCountWaiters()
        }
      } onCancel: {
        Task {
          await self.cancelSleep(identifier)
        }
      }
    } catch let error as CoreError {
      throw error
    } catch {
      throw ClockError.unclassifiedFailure()
    }
  }

  /// Advances monotonic test time and resumes all newly due sleeps.
  public func advance(by duration: Duration) throws(CoreError) {
    guard duration >= .zero else {
      throw ClockError.invalidDuration()
    }

    elapsed += duration
    let due =
      pendingSleeps
      .filter { $0.value.deadline <= elapsed }
      .sorted {
        if $0.value.deadline == $1.value.deadline {
          return $0.value.registrationOrder < $1.value.registrationOrder
        }
        return $0.value.deadline < $1.value.deadline
      }

    for (identifier, sleep) in due {
      pendingSleeps.removeValue(forKey: identifier)
      sleep.continuation.resume()
    }
  }

  /// Test-only scheduling barrier used to avoid sleeps or polling in tests.
  func waitUntilPendingSleepCount(_ expectedCount: Int) async throws(CoreError) {
    guard expectedCount >= 0 else {
      throw ClockError.invalidCount()
    }
    guard pendingSleeps.count < expectedCount else { return }
    guard !Task.isCancelled else {
      throw ClockError.cancelled()
    }

    let identifier = makeIdentifier()
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          countWaiters[identifier] = CountWaiter(
            expectedCount: expectedCount,
            continuation: continuation
          )
          resumeSatisfiedCountWaiters()
        }
      } onCancel: {
        Task {
          await self.cancelCountWaiter(identifier)
        }
      }
    } catch let error as CoreError {
      throw error
    } catch {
      throw ClockError.unclassifiedFailure()
    }
  }

  private func makeIdentifier() -> UInt64 {
    let identifier = nextIdentifier
    nextIdentifier &+= 1
    return identifier
  }

  private func cancelSleep(_ identifier: UInt64) {
    guard let sleep = pendingSleeps.removeValue(forKey: identifier) else { return }
    sleep.continuation.resume(throwing: ClockError.cancelled())
  }

  private func cancelCountWaiter(_ identifier: UInt64) {
    guard let waiter = countWaiters.removeValue(forKey: identifier) else { return }
    waiter.continuation.resume(throwing: ClockError.cancelled())
  }

  private func resumeSatisfiedCountWaiters() {
    let satisfied = countWaiters.filter { pendingSleeps.count >= $0.value.expectedCount }
    for (identifier, waiter) in satisfied {
      countWaiters.removeValue(forKey: identifier)
      waiter.continuation.resume()
    }
  }
}

private enum ClockError {
  static func cancelled() -> CoreError {
    CoreError(
      code: .cancellation(.requested),
      severity: .notice,
      retryDisposition: .never,
      cleanupDisposition: .completed
    )
  }

  static func invalidDuration() -> CoreError {
    CoreError(
      code: .internalFailure(.preconditionFailed),
      severity: .error,
      retryDisposition: .never,
      cleanupDisposition: .notRequired
    )
  }

  static func invalidCount() -> CoreError {
    invalidDuration()
  }

  static func unclassifiedFailure() -> CoreError {
    CoreError(
      code: .internalFailure(.unclassified),
      severity: .error,
      retryDisposition: .never,
      cleanupDisposition: .notRequired
    )
  }
}
