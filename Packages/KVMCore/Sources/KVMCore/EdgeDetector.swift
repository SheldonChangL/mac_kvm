import KVMContracts

/// Pure edge-dwell detector for server screen switching (M2-017).
///
/// The caller supplies pointer samples in local logical points of one screen
/// (origin top-left, y grows down) with monotonic timestamps. A linked edge
/// activates once after the pointer has stayed on it for the activation delay.
/// Corners within the dead zone never activate, moving off the edge cancels a
/// pending activation, and after an activation the pointer must leave the edge
/// before it can activate again.
///
/// The detector has no clock: `tick(at:)` lets the owner evaluate a pending
/// dwell without a new pointer sample, using any `KVMClock`-driven timestamp.
package struct EdgeDetector: Sendable {
  /// Logical screen size in points.
  package struct ScreenSize: Equatable, Sendable {
    package let width: Double
    package let height: Double

    package init(width: Double, height: Double) {
      self.width = width
      self.height = height
    }
  }

  /// Validated dwell configuration.
  package struct Configuration: Equatable, Sendable {
    package static let delayRange: ClosedRange<Duration> = .milliseconds(50)...(.milliseconds(100))
    package static let deadZoneRange: ClosedRange<Double> = 20...40

    package let activationDelay: Duration
    package let cornerDeadZone: Double

    /// Returns `nil` outside the M2-017 baseline ranges.
    package init?(activationDelay: Duration, cornerDeadZone: Double) {
      guard Self.delayRange.contains(activationDelay),
        cornerDeadZone.isFinite, Self.deadZoneRange.contains(cornerDeadZone)
      else { return nil }
      self.activationDelay = activationDelay
      self.cornerDeadZone = cornerDeadZone
    }
  }

  /// Detector output for one sample or tick.
  package enum Signal: Equatable, Sendable {
    case idle
    case pending(ScreenEdge)
    /// `offset` is the normalized position along the edge (y for left/right,
    /// x for top/bottom), in `0...1`.
    case activated(ScreenEdge, offset: Double)
  }

  private enum Phase: Equatable, Sendable {
    case away
    case pending(ScreenEdge, since: Duration, offset: Double)
    case fired(ScreenEdge)
  }

  package let configuration: Configuration
  package let screenSize: ScreenSize
  package let linkedEdges: Set<ScreenEdge>

  private var phase = Phase.away
  private var lastTimestamp: Duration?

  package init(configuration: Configuration, screenSize: ScreenSize, linkedEdges: Set<ScreenEdge>) {
    self.configuration = configuration
    self.screenSize = screenSize
    self.linkedEdges = linkedEdges
  }

  /// Processes one pointer sample.
  ///
  /// Non-finite coordinates, invalid screen sizes and timestamps earlier than
  /// the previous one cancel any pending activation and return `idle`.
  /// Coordinates outside the screen are clamped to it.
  package mutating func update(x: Double, y: Double, at timestamp: Duration) -> Signal {
    guard x.isFinite, y.isFinite, screenSize.width >= 1, screenSize.height >= 1,
      acceptTimestamp(timestamp)
    else {
      reset()
      return .idle
    }
    let maxX = screenSize.width - 1
    let maxY = screenSize.height - 1
    let cx = min(max(x, 0), maxX)
    let cy = min(max(y, 0), maxY)
    guard let (edge, offset) = eligibleEdge(x: cx, y: cy, maxX: maxX, maxY: maxY) else {
      phase = .away
      return .idle
    }
    switch phase {
    case .fired(let fired) where fired == edge:
      return .idle
    case .pending(let pending, let since, _) where pending == edge:
      phase = .pending(edge, since: since, offset: offset)
    default:
      phase = .pending(edge, since: timestamp, offset: offset)
    }
    return evaluate(at: timestamp)
  }

  /// Evaluates a pending dwell at `timestamp` without a new pointer sample.
  package mutating func tick(at timestamp: Duration) -> Signal {
    guard acceptTimestamp(timestamp) else {
      reset()
      return .idle
    }
    return evaluate(at: timestamp)
  }

  /// Cancels any pending or fired state. Idempotent.
  package mutating func reset() {
    phase = .away
    lastTimestamp = nil
  }

  private mutating func acceptTimestamp(_ timestamp: Duration) -> Bool {
    if let last = lastTimestamp, timestamp < last {
      return false
    }
    lastTimestamp = timestamp
    return true
  }

  private mutating func evaluate(at timestamp: Duration) -> Signal {
    guard case .pending(let edge, let since, let offset) = phase else { return .idle }
    guard timestamp - since >= configuration.activationDelay else { return .pending(edge) }
    phase = .fired(edge)
    return .activated(edge, offset: offset)
  }

  private func eligibleEdge(x: Double, y: Double, maxX: Double, maxY: Double)
    -> (ScreenEdge, Double)?
  {
    let zone = configuration.cornerDeadZone
    let inVerticalBand = y >= zone && y <= maxY - zone
    let inHorizontalBand = x >= zone && x <= maxX - zone
    let candidates: [(ScreenEdge, Bool, Bool, Double)] = [
      (.left, x <= 0, inVerticalBand, y / screenSize.height),
      (.right, x >= maxX, inVerticalBand, y / screenSize.height),
      (.top, y <= 0, inHorizontalBand, x / screenSize.width),
      (.bottom, y >= maxY, inHorizontalBand, x / screenSize.width),
    ]
    for (edge, onEdge, outsideCorner, offset) in candidates
    where onEdge && outsideCorner && linkedEdges.contains(edge) {
      return (edge, min(max(offset, 0), 1))
    }
    return nil
  }
}
