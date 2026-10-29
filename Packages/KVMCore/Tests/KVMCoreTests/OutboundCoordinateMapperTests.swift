import KVMContracts
import KVMCore
import Testing

private let remote = OutboundCoordinateMapper.LogicalSize(width: 1921, height: 1081)
private let local = OutboundCoordinateMapper.LogicalSize(width: 1001, height: 501)
private let center = NormalizedPoint(x: 0.5, y: 0.5)

private func mapper() throws -> OutboundCoordinateMapper {
  try #require(OutboundCoordinateMapper(remoteSize: remote, entryInset: 1))
}

@Suite("M2-019 OutboundCoordinateMapper")
struct OutboundCoordinateMapperTests {
  @Test("entry lands on the opposite remote edge, inset, at the same normalized offset")
  func entryPoints() throws {
    let m = try mapper()
    #expect(m.entryPoint(leaving: .right, offset: 0.5) == .init(x: 1, y: 540))
    #expect(m.entryPoint(leaving: .left, offset: 0.25) == .init(x: 1919, y: 270))
    #expect(m.entryPoint(leaving: .bottom, offset: 0.75) == .init(x: 1440, y: 1))
    #expect(m.entryPoint(leaving: .top, offset: 0) == .init(x: 0, y: 1079))
    #expect(m.entryPoint(leaving: .right, offset: 1) == .init(x: 1, y: 1080))
  }

  @Test("normalized form matches the remote logical point")
  func normalized() throws {
    let m = try mapper()
    let point = m.entryPoint(leaving: .right, offset: 0.5)
    #expect(m.normalized(point) == NormalizedPoint(x: 1.0 / 1920.0, y: 0.5))
  }

  @Test("boundary: offsets are clamped and non-finite offsets fall back to the center")
  func offsetClamping() throws {
    let m = try mapper()
    #expect(m.entryPoint(leaving: .right, offset: -3) == .init(x: 1, y: 0))
    #expect(m.entryPoint(leaving: .right, offset: 9) == .init(x: 1, y: 1080))
    #expect(m.entryPoint(leaving: .right, offset: .nan) == .init(x: 1, y: 540))
  }

  @Test("invalid sizes and insets are rejected")
  func invalidConfiguration() {
    typealias Size = OutboundCoordinateMapper.LogicalSize
    #expect(OutboundCoordinateMapper(remoteSize: Size(width: 1, height: 100), entryInset: 0) == nil)
    #expect(OutboundCoordinateMapper(remoteSize: Size(width: 100, height: 0), entryInset: 0) == nil)
    #expect(
      OutboundCoordinateMapper(remoteSize: Size(width: 70000, height: 10), entryInset: 0) == nil)
    #expect(
      OutboundCoordinateMapper(remoteSize: Size(width: 100, height: 100), entryInset: -1) == nil)
    #expect(
      OutboundCoordinateMapper(remoteSize: Size(width: 100, height: 100), entryInset: 50) == nil)
  }

  @Test("tracker applies local logical deltas one to one and clamps to the remote screen")
  func tracking() throws {
    let m = try mapper()
    var tracker = m.tracker(entering: .right, at: m.entryPoint(leaving: .right, offset: 0.5))
    let moved = tracker.apply(
      localPosition: NormalizedPoint(x: 0.6, y: 0.4), anchor: center, localSize: local)
    #expect(moved == .moved(.init(x: 101, y: 490)))
    let far = tracker.apply(
      localPosition: NormalizedPoint(x: 1, y: 1), anchor: center, localSize: local)
    #expect(far == .moved(.init(x: 601, y: 740)))
    for _ in 0..<10 {
      _ = tracker.apply(
        localPosition: NormalizedPoint(x: 1, y: 1), anchor: center, localSize: local)
    }
    #expect(tracker.position == .init(x: 1920, y: 1080))
  }

  @Test("pushing past the arrival edge reports a return with the offset along that edge")
  func returnEdge() throws {
    let m = try mapper()
    var tracker = m.tracker(entering: .right, at: .init(x: 1, y: 540))
    let back = tracker.apply(
      localPosition: NormalizedPoint(x: 0.49, y: 0.5), anchor: center, localSize: local)
    #expect(back == .returned(offset: 0.5))
    var other = m.tracker(entering: .bottom, at: .init(x: 480, y: 1))
    #expect(
      other.apply(localPosition: NormalizedPoint(x: 0.5, y: 0.49), anchor: center, localSize: local)
        == .returned(offset: 0.25))
  }

  @Test("pushing past a non-arrival edge clamps instead of returning")
  func otherEdgesClamp() throws {
    let m = try mapper()
    var tracker = m.tracker(entering: .right, at: .init(x: 1, y: 0))
    #expect(
      tracker.apply(
        localPosition: NormalizedPoint(x: 0.5, y: 0.1), anchor: center, localSize: local)
        == .moved(.init(x: 1, y: 0)))
  }

  @Test("invalid local sizes produce no movement")
  func invalidLocalSize() throws {
    let m = try mapper()
    var tracker = m.tracker(entering: .right, at: .init(x: 10, y: 10))
    let zero = OutboundCoordinateMapper.LogicalSize(width: 0, height: 0)
    #expect(
      tracker.apply(localPosition: NormalizedPoint(x: 1, y: 1), anchor: center, localSize: zero)
        == .moved(.init(x: 10, y: 10)))
  }
}
