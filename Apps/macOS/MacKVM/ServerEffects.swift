import CoreGraphics
import Foundation
import KVMContracts
import KVMCore
import MacPlatform

/// One status line on standard output. Callers never pass input content, key
/// identities, addresses or certificate material.
func report(_ message: String) {
  let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
  print("[\(stamp)] \(message)")
  fflush(stdout)
}

/// Monotonic time for edge dwell, independent of event timestamps.
func uptime() -> Duration {
  .nanoseconds(Int64(clamping: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
}

/// The single client the M2 server serves, and its ordered outbox.
final class ClientSlot: @unchecked Sendable {
  private struct Client {
    let screen: ScreenID
    let session: ServerSession
    let outbox: CaptureQueue
  }

  private let lock = NSLock()
  private var client: Client?

  /// Claims the slot; `false` when another client holds it.
  func claim(screen: ScreenID, session: ServerSession, outbox: CaptureQueue) -> Bool {
    lock.withLock {
      guard client == nil else { return false }
      client = Client(screen: screen, session: session, outbox: outbox)
      return true
    }
  }

  func release(_ screen: ScreenID) {
    lock.withLock { if client?.screen == screen { client = nil } }
  }

  func outbox(for screen: ScreenID) -> CaptureQueue? {
    lock.withLock { client?.screen == screen ? client?.outbox : nil }
  }

  var session: ServerSession? { lock.withLock { client?.session } }
  var outbox: CaptureQueue? { lock.withLock { client?.outbox } }
}

/// Whether the next fail-safe recovery must put the cursor back.
final class RecoveryCursorFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set(_ restore: Bool) { lock.withLock { value = restore } }
  var restoresCursor: Bool { lock.withLock { value } }
}

/// The local half of the fail-safe (ServerFailSafe).
///
/// Local key and button releases need no synthetic events: a release whose
/// down went to the local system is always given back to it
/// (`ServerCoordinator.handleSuppressed`), so no local key or button is left
/// held by suppression. The coordinator clears its own transient state.
struct LocalInputSafety: ServerLocalInputSafety {
  let suppressor: LocalEventSuppressor?
  let cursor: CursorRestorer?
  let flag: RecoveryCursorFlag

  func stopSuppression() throws(CoreError) { suppressor?.disableSuppression() }
  func releaseAllKeys() throws(CoreError) {}
  func releaseAllMouseButtons() throws(CoreError) {}
  func restoreLocalCursor() throws(CoreError) {
    guard flag.restoresCursor, let cursor else { return }
    if case .failed = cursor.restore(preferred: nil) {
      throw CoreError(
        code: .inputSafety(.localStateRestoreFailed), severity: .error,
        retryDisposition: .never, cleanupDisposition: .failed)
    }
  }
  func clearTransientState() throws(CoreError) {}
}

/// Executes the coordinator's effects on this Mac. Called with the coordinator
/// lock held, so nothing here waits or calls back into the coordinator.
final class MacServerEffects: ServerCoordinatorEffects, @unchecked Sendable {
  /// Local points the parked cursor keeps away from the linked edge.
  static let parkInset: Double = 4
  static let enterTimeout = Duration.seconds(1)

  private let desktop: CGRect
  private let edge: ScreenEdge
  private let suppressor: LocalEventSuppressor?
  private let cursor: CursorRestorer?
  private let failSafe: ServerFailSafe
  private let recoveryFlag: RecoveryCursorFlag
  private let clients: ClientSlot
  private let lock = NSLock()
  private var parkPoint: CGPoint?
  private var timeouts: [ScreenID: Task<Void, Never>] = [:]
  private var onEnterTimeout: (@Sendable (ScreenID) -> Void)?

  /// `suppressor` and `cursor` are `nil` when the run must not touch local
  /// input (the DEBUG smoke driver).
  init(
    desktop: CGRect, edge: ScreenEdge, suppressor: LocalEventSuppressor?, cursor: CursorRestorer?,
    clients: ClientSlot
  ) {
    self.desktop = desktop
    self.edge = edge
    self.suppressor = suppressor
    self.cursor = cursor
    self.clients = clients
    recoveryFlag = RecoveryCursorFlag()
    failSafe = ServerFailSafe(
      local: LocalInputSafety(suppressor: suppressor, cursor: cursor, flag: recoveryFlag))
  }

  /// Wires the enter timeout back to the coordinator once it exists.
  func onEnterTimeout(_ handler: @escaping @Sendable (ScreenID) -> Void) {
    lock.withLock { onEnterTimeout = handler }
  }

  /// Warps the cursor back to its park point after a swallowed motion.
  func repark() {
    if let point = lock.withLock({ parkPoint }) { MacDesktop.warpCursor(to: point) }
  }

  // MARK: ServerCoordinatorEffects

  func saveLocalCursor() {
    guard let cursor else { return }
    cursor.saveCurrent()
    let location = MacDesktop.cursorLocation()
    lock.withLock { parkPoint = location.map(parked) }
  }

  func enableSuppression() {
    repark()
    suppressor?.enableSuppression()
    report("input is now remote")
  }

  func disableSuppression() {
    suppressor?.disableSuppression()
  }

  func restoreLocalCursor(at position: NormalizedPoint) {
    lock.withLock { parkPoint = nil }
    report("input is local again")
    guard let cursor else { return }
    let point = CGPoint(
      x: desktop.minX + position.x * (desktop.width - 1),
      y: desktop.minY + position.y * (desktop.height - 1))
    if case .failed = cursor.restore(preferred: point) {
      report("cursor restore failed")
    }
  }

  func recoverLocal(cursorWasParked: Bool) {
    lock.withLock { parkPoint = nil }
    recoveryFlag.set(cursorWasParked && cursor != nil)
    let disposition = failSafe.recoverLocal()
    report("local recovery: \(disposition)")
  }

  func deliver(_ event: KVMEvent, to screen: ScreenID) -> Bool {
    guard let outbox = clients.outbox(for: screen) else { return false }
    switch outbox.enqueue(event) {
    case .enqueued, .coalesced, .droppedMove: return true
    case .overflow, .closed: return false
    }
  }

  func startEnterTimeout(for screen: ScreenID) {
    let handler = lock.withLock { onEnterTimeout }
    let task = Task {
      try? await Task.sleep(for: Self.enterTimeout)
      if !Task.isCancelled { handler?(screen) }
    }
    let previous = lock.withLock { timeouts.updateValue(task, forKey: screen) }
    previous?.cancel()
  }

  func cancelEnterTimeout(for screen: ScreenID) {
    lock.withLock { timeouts.removeValue(forKey: screen) }?.cancel()
  }

  /// `location` moved `parkInset` away from the linked edge.
  private func parked(_ location: CGPoint) -> CGPoint {
    let inset = Self.parkInset
    switch edge {
    case .right: return CGPoint(x: min(location.x, desktop.maxX - 1 - inset), y: location.y)
    case .left: return CGPoint(x: max(location.x, desktop.minX + inset), y: location.y)
    case .bottom: return CGPoint(x: location.x, y: min(location.y, desktop.maxY - 1 - inset))
    case .top: return CGPoint(x: location.x, y: max(location.y, desktop.minY + inset))
    }
  }
}
