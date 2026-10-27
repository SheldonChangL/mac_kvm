// Connection admission for the Barrier server role (M2-024).
// The protocol module must not own a socket implementation (ARCHITECTURE_GUARDRAILS,
// M1-ARCH-001), so the concrete listener lives in a platform module and hands each
// accepted connection to this gate as an abstract `Transport`. The gate enforces the
// connection limit and a connect timeout and owns idempotent stop. It never touches
// input state: every listener failure is a typed error for the session owner.

import KVMContracts

/// Typed listener failure. Carries no address, port or peer data.
enum BarrierListenerError: Error, Equatable, Sendable {
  case invalidPolicy
  case capacityExceeded
  case connectFailed(CoreError)
  case connectTimedOut
  case cancelled
  case stopped
}

/// Validated admission limits.
struct BarrierListenerPolicy: Equatable, Sendable {
  /// Upper bound on simultaneously admitted connections.
  static let largestConnectionLimit = 8

  let maximumConcurrentConnections: Int
  let connectTimeout: Duration

  init(maximumConcurrentConnections: Int, connectTimeout: Duration) throws(BarrierListenerError) {
    guard (1...Self.largestConnectionLimit).contains(maximumConcurrentConnections),
      connectTimeout > .zero
    else { throw .invalidPolicy }
    self.maximumConcurrentConnections = maximumConcurrentConnections
    self.connectTimeout = connectTimeout
  }
}

/// Opaque handle for one admitted connection.
struct BarrierListenerAdmission: Hashable, Sendable {
  fileprivate let identifier: UInt64
}

/// Admits accepted transports within the policy.
actor BarrierListenerTransport {
  private enum ConnectOutcome: Sendable {
    case connected
    case failed(CoreError)
    case timedOut
    case cancelled
  }

  private let policy: BarrierListenerPolicy
  private let clock: any KVMClock
  private var admitted: [BarrierListenerAdmission: any Transport] = [:]
  private var pendingCount = 0
  private var nextIdentifier: UInt64 = 0
  private var isStopped = false

  init(policy: BarrierListenerPolicy, clock: any KVMClock) {
    self.policy = policy
    self.clock = clock
  }

  /// Number of admitted connections not yet released.
  var activeCount: Int { admitted.count }

  /// Connects `transport` within the timeout and admits it, or disconnects it
  /// and throws. The timeout holds even if the transport's `connect()` ignores
  /// cancellation, because the transport is disconnected when the timeout wins. The slot is reserved before connecting, so concurrent admits
  /// cannot exceed the limit.
  func admit(_ transport: any Transport) async throws(BarrierListenerError)
    -> BarrierListenerAdmission
  {
    guard !isStopped else {
      await transport.disconnect()
      throw .stopped
    }
    guard admitted.count + pendingCount < policy.maximumConcurrentConnections else {
      await transport.disconnect()
      throw .capacityExceeded
    }
    pendingCount += 1
    let outcome = await connect(transport)
    pendingCount -= 1
    switch outcome {
    case .connected:
      if isStopped {
        await transport.disconnect()
        throw .stopped
      }
    // `connect(_:)` has already disconnected the transport in these cases.
    case .failed(let error): throw .connectFailed(error)
    case .timedOut: throw .connectTimedOut
    case .cancelled: throw .cancelled
    }
    nextIdentifier += 1
    let admission = BarrierListenerAdmission(identifier: nextIdentifier)
    admitted[admission] = transport
    return admission
  }

  /// Forgets an admitted connection whose owner has ended it. Idempotent.
  func release(_ admission: BarrierListenerAdmission) {
    admitted[admission] = nil
  }

  /// Disconnects every admitted transport and rejects later admits. Idempotent.
  func stop() async {
    isStopped = true
    let transports = Array(admitted.values)
    admitted = [:]
    for transport in transports {
      await transport.disconnect()
    }
  }

  private func connect(_ transport: any Transport) async -> ConnectOutcome {
    let timeout = policy.connectTimeout
    let clock = clock
    return await withTaskGroup(of: ConnectOutcome.self) { group in
      group.addTask {
        do throws(CoreError) {
          try await transport.connect()
          return .connected
        } catch {
          return .failed(error)
        }
      }
      group.addTask {
        do throws(CoreError) {
          try await clock.sleep(for: timeout)
          return .timedOut
        } catch {
          return .cancelled
        }
      }
      let first = await group.next() ?? .cancelled
      group.cancelAll()
      if case .connected = first { return first }
      // The task group waits for every child. Disconnecting here forces a
      // connect that ignores cancellation to end, so the timeout really bounds
      // the admission and the reserved slot is released.
      await transport.disconnect()
      return first
    }
  }
}
