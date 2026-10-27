import KVMContracts

/// Maps a remote return-edge position back to a safe local re-entry point
/// (M2-020, C-008).
///
/// The pointer re-enters through the local edge it originally left, at the
/// returned normalized offset along that edge. The point is clamped out of
/// the corner dead zone and placed `reentryInset` points inside the edge, so
/// it is never on an edge: the M2-017 detector sees the pointer as away and
/// must re-arm before another switch, which prevents an immediate re-exit.
package struct ReturnCoordinateMapper: Equatable, Sendable {
  /// A logical screen size in points.
  package struct LogicalSize: Equatable, Sendable {
    package let width: Double
    package let height: Double

    package init(width: Double, height: Double) {
      self.width = width
      self.height = height
    }
  }

  /// A local logical point, origin top-left.
  package struct LocalPoint: Equatable, Sendable {
    package let x: Double
    package let y: Double

    package init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  package let localSize: LogicalSize
  package let reentryInset: Double
  package let cornerDeadZone: Double

  private var maxX: Double { localSize.width - 1 }
  private var maxY: Double { localSize.height - 1 }

  /// Returns `nil` for degenerate or non-finite sizes, an inset below one
  /// point, or an inset/dead zone that does not fit inside the screen.
  package init?(localSize: LogicalSize, reentryInset: Double, cornerDeadZone: Double) {
    guard localSize.width.isFinite, localSize.height.isFinite, localSize.width >= 2,
      localSize.height >= 2, reentryInset.isFinite, reentryInset >= 1,
      cornerDeadZone.isFinite, cornerDeadZone >= 0
    else { return nil }
    let shortest = min(localSize.width, localSize.height) - 1
    guard reentryInset * 2 < shortest, cornerDeadZone * 2 < shortest else { return nil }
    self.localSize = localSize
    self.reentryInset = reentryInset
    self.cornerDeadZone = cornerDeadZone
  }

  /// The local point for a return through `edge` at `offset`.
  ///
  /// Non-finite offsets use the edge center.
  package func reentryPoint(leftThrough edge: ScreenEdge, offset: Double) -> LocalPoint {
    let along = offset.isFinite ? min(max(offset, 0), 1) : 0.5
    switch edge {
    case .left:
      return LocalPoint(x: reentryInset, y: band(along * maxY, max: maxY))
    case .right:
      return LocalPoint(x: maxX - reentryInset, y: band(along * maxY, max: maxY))
    case .top:
      return LocalPoint(x: band(along * maxX, max: maxX), y: reentryInset)
    case .bottom:
      return LocalPoint(x: band(along * maxX, max: maxX), y: maxY - reentryInset)
    }
  }

  /// The normalized form of a local point, for the reducer's cursor effect.
  package func normalized(_ point: LocalPoint) -> NormalizedPoint {
    NormalizedPoint(x: point.x / maxX, y: point.y / maxY)
  }

  private func band(_ value: Double, max upper: Double) -> Double {
    min(max(value, cornerDeadZone), upper - cornerDeadZone)
  }
}
