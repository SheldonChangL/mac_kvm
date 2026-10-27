import KVMContracts

/// Maps a local edge activation onto a remote screen and tracks the remote
/// pointer while input is routed there (M2-019, C-008).
///
/// All sizes are logical points reported by each side; backing-pixel scale is
/// never used. Local motion is applied to the remote screen one logical point
/// per local logical point, so differing scale factors and resolutions do not
/// change pointer speed in points.
package struct OutboundCoordinateMapper: Equatable, Sendable {
  /// A logical screen size in points.
  package struct LogicalSize: Equatable, Sendable {
    package let width: Double
    package let height: Double

    package init(width: Double, height: Double) {
      self.width = width
      self.height = height
    }
  }

  /// An integral logical point on the remote screen, origin top-left.
  package struct RemotePoint: Equatable, Sendable {
    package let x: Int
    package let y: Int

    package init(x: Int, y: Int) {
      self.x = x
      self.y = y
    }
  }

  /// The largest remote dimension accepted, matching 16-bit wire sizes.
  package static let maximumDimension: Double = 65_535

  package let remoteSize: LogicalSize
  package let entryInset: Int

  private var maxX: Double { remoteSize.width - 1 }
  private var maxY: Double { remoteSize.height - 1 }

  /// Returns `nil` for non-finite or degenerate sizes, dimensions above
  /// `maximumDimension`, or an inset that does not fit inside the screen.
  package init?(remoteSize: LogicalSize, entryInset: Int) {
    let range: ClosedRange<Double> = 2...Self.maximumDimension
    guard range.contains(remoteSize.width), range.contains(remoteSize.height), entryInset >= 0
    else { return nil }
    let shortest = min(remoteSize.width, remoteSize.height) - 1
    guard Double(entryInset) * 2 < shortest else { return nil }
    self.remoteSize = remoteSize
    self.entryInset = entryInset
  }

  /// The remote entry point for a local activation of `edge` at `offset`.
  ///
  /// The pointer arrives on the opposite remote edge, `entryInset` points
  /// inside it, at the same normalized position along the edge. Offsets are
  /// clamped to `0...1`; a non-finite offset uses the edge center.
  package func entryPoint(leaving edge: ScreenEdge, offset: Double) -> RemotePoint {
    let along = offset.isFinite ? min(max(offset, 0), 1) : 0.5
    let inset = Double(entryInset)
    switch edge {
    case .right:
      return point(x: inset, y: along * maxY)
    case .left:
      return point(x: maxX - inset, y: along * maxY)
    case .bottom:
      return point(x: along * maxX, y: inset)
    case .top:
      return point(x: along * maxX, y: maxY - inset)
    }
  }

  /// The normalized form of a remote point for `KVMEvent` positions.
  package func normalized(_ point: RemotePoint) -> NormalizedPoint {
    NormalizedPoint(x: Double(point.x) / maxX, y: Double(point.y) / maxY)
  }

  /// Starts tracking after a local activation of `edge` placed the remote
  /// pointer at `start`.
  package func tracker(entering edge: ScreenEdge, at start: RemotePoint) -> RemotePointerTracker {
    RemotePointerTracker(mapper: self, arrivalEdge: edge.opposite, start: start)
  }

  fileprivate func point(x: Double, y: Double) -> RemotePoint {
    RemotePoint(x: Int((min(max(x, 0), maxX)).rounded()), y: Int((min(max(y, 0), maxY)).rounded()))
  }

  fileprivate var bounds: (maxX: Double, maxY: Double) { (maxX, maxY) }
}

/// Remote pointer state while input is routed to one remote screen.
package struct RemotePointerTracker: Equatable, Sendable {
  /// Result of applying one local motion sample.
  package enum Motion: Equatable, Sendable {
    case moved(OutboundCoordinateMapper.RemotePoint)
    /// The pointer was pushed past the edge it arrived through. `offset` is
    /// the normalized position along that edge, for M2-020.
    case returned(offset: Double)
  }

  private let mapper: OutboundCoordinateMapper
  private let arrivalEdge: ScreenEdge
  private var x: Double
  private var y: Double

  fileprivate init(
    mapper: OutboundCoordinateMapper, arrivalEdge: ScreenEdge,
    start: OutboundCoordinateMapper.RemotePoint
  ) {
    self.mapper = mapper
    self.arrivalEdge = arrivalEdge
    self.x = Double(start.x)
    self.y = Double(start.y)
  }

  /// The current remote pointer position.
  package var position: OutboundCoordinateMapper.RemotePoint {
    mapper.point(x: x, y: y)
  }

  /// Applies the local displacement of `localPosition` from `anchor`, both
  /// normalized on a local screen of `localSize` logical points.
  ///
  /// The local cursor is expected to be re-anchored after each sample, so each
  /// call is one relative motion. Invalid local sizes apply no motion.
  package mutating func apply(
    localPosition: NormalizedPoint, anchor: NormalizedPoint,
    localSize: OutboundCoordinateMapper.LogicalSize
  ) -> Motion {
    guard localSize.width >= 2, localSize.height >= 2, localSize.width.isFinite,
      localSize.height.isFinite
    else { return .moved(position) }
    let nextX = x + (localPosition.x - anchor.x) * (localSize.width - 1)
    let nextY = y + (localPosition.y - anchor.y) * (localSize.height - 1)
    let (maxX, maxY) = mapper.bounds
    let pushedPastArrival: Bool
    switch arrivalEdge {
    case .left: pushedPastArrival = nextX < 0
    case .right: pushedPastArrival = nextX > maxX
    case .top: pushedPastArrival = nextY < 0
    case .bottom: pushedPastArrival = nextY > maxY
    }
    x = min(max(nextX, 0), maxX)
    y = min(max(nextY, 0), maxY)
    if pushedPastArrival {
      let clamped = position
      switch arrivalEdge {
      case .left, .right: return .returned(offset: Double(clamped.y) / maxY)
      case .top, .bottom: return .returned(offset: Double(clamped.x) / maxX)
      }
    }
    return .moved(position)
  }
}
