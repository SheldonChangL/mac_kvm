import KVMContracts
import KVMCore
import Testing

private let size = ReturnCoordinateMapper.LogicalSize(width: 1001, height: 501)

private func mapper(inset: Double = 2, deadZone: Double = 30) throws -> ReturnCoordinateMapper {
  try #require(
    ReturnCoordinateMapper(localSize: size, reentryInset: inset, cornerDeadZone: deadZone))
}

@Suite("M2-020 ReturnCoordinateMapper")
struct ReturnCoordinateMapperTests {
  @Test("re-entry lands inside the edge that was left, at the returned offset")
  func reentry() throws {
    let m = try mapper()
    #expect(m.reentryPoint(leftThrough: .right, offset: 0.5) == .init(x: 998, y: 250))
    #expect(m.reentryPoint(leftThrough: .left, offset: 0.25) == .init(x: 2, y: 125))
    #expect(m.reentryPoint(leftThrough: .top, offset: 0.75) == .init(x: 750, y: 2))
    #expect(m.reentryPoint(leftThrough: .bottom, offset: 0.5) == .init(x: 500, y: 498))
  }

  @Test("boundary: offsets are clamped out of the corner dead zone")
  func cornerClamp() throws {
    let m = try mapper()
    #expect(m.reentryPoint(leftThrough: .right, offset: 0) == .init(x: 998, y: 30))
    #expect(m.reentryPoint(leftThrough: .right, offset: 1) == .init(x: 998, y: 470))
    #expect(m.reentryPoint(leftThrough: .top, offset: -5) == .init(x: 30, y: 2))
    #expect(m.reentryPoint(leftThrough: .top, offset: .infinity) == .init(x: 500, y: 2))
  }

  @Test("re-entry never sits on an edge, so the edge detector must re-arm")
  func avoidsImmediateReswitch() throws {
    let m = try mapper(inset: 1)
    var detector = EdgeDetector(
      configuration: try #require(
        EdgeDetector.Configuration(activationDelay: .milliseconds(50), cornerDeadZone: 30)),
      screenSize: EdgeDetector.ScreenSize(width: 1001, height: 501),
      linkedEdges: Set(ScreenEdge.allCases)
    )
    for edge in ScreenEdge.allCases {
      for offset in [0.0, 0.5, 1.0] {
        let point = m.reentryPoint(leftThrough: edge, offset: offset)
        #expect(detector.update(x: point.x, y: point.y, at: .seconds(1)) == .idle)
      }
    }
  }

  @Test("normalized form is relative to the local logical size")
  func normalized() throws {
    let m = try mapper()
    #expect(m.normalized(.init(x: 500, y: 250)) == NormalizedPoint(x: 0.5, y: 0.5))
  }

  @Test("invalid configuration is rejected")
  func invalid() {
    typealias M = ReturnCoordinateMapper
    #expect(M(localSize: .init(width: 1, height: 500), reentryInset: 1, cornerDeadZone: 20) == nil)
    #expect(M(localSize: size, reentryInset: 0, cornerDeadZone: 20) == nil)
    #expect(M(localSize: size, reentryInset: .nan, cornerDeadZone: 20) == nil)
    #expect(M(localSize: size, reentryInset: 1, cornerDeadZone: -1) == nil)
    #expect(M(localSize: size, reentryInset: 1, cornerDeadZone: 250) == nil)
    #expect(M(localSize: size, reentryInset: 251, cornerDeadZone: 20) == nil)
  }
}
