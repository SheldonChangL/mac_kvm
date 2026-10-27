import KVMContracts
import KVMCore
import Testing

private let size = EdgeDetector.ScreenSize(width: 1000, height: 500)

private func config(delayMilliseconds: Int = 80, deadZone: Double = 30) throws
  -> EdgeDetector.Configuration
{
  try #require(
    EdgeDetector.Configuration(
      activationDelay: .milliseconds(delayMilliseconds), cornerDeadZone: deadZone))
}

private func detector(_ edges: Set<ScreenEdge> = [.right]) throws -> EdgeDetector {
  EdgeDetector(configuration: try config(), screenSize: size, linkedEdges: edges)
}

private func at(_ ms: Int) -> Duration { .milliseconds(ms) }

@Suite("M2-017 EdgeDetector")
struct EdgeDetectorTests {
  @Test("configuration accepts only the 50...100 ms delay and 20...40 px dead zone baseline")
  func configurationBounds() {
    typealias C = EdgeDetector.Configuration
    #expect(C(activationDelay: .milliseconds(50), cornerDeadZone: 20) != nil)
    #expect(C(activationDelay: .milliseconds(100), cornerDeadZone: 40) != nil)
    #expect(C(activationDelay: .milliseconds(49), cornerDeadZone: 30) == nil)
    #expect(C(activationDelay: .milliseconds(101), cornerDeadZone: 30) == nil)
    #expect(C(activationDelay: .milliseconds(80), cornerDeadZone: 19.9) == nil)
    #expect(C(activationDelay: .milliseconds(80), cornerDeadZone: 40.1) == nil)
    #expect(C(activationDelay: .milliseconds(80), cornerDeadZone: .nan) == nil)
  }

  @Test("happy path: dwelling on a linked edge activates once after the delay")
  func activation() throws {
    var edge = try detector()
    #expect(edge.update(x: 500, y: 250, at: at(0)) == .idle)
    #expect(edge.update(x: 999, y: 250, at: at(10)) == .pending(.right))
    #expect(edge.update(x: 999, y: 260, at: at(89)) == .pending(.right))
    #expect(edge.update(x: 999, y: 250, at: at(90)) == .activated(.right, offset: 0.5))
    #expect(edge.update(x: 999, y: 250, at: at(200)) == .idle)
  }

  @Test("tick activates without a new pointer sample")
  func tickActivation() throws {
    var edge = try detector()
    _ = edge.update(x: 999, y: 125, at: at(0))
    #expect(edge.tick(at: at(79)) == .pending(.right))
    #expect(edge.tick(at: at(80)) == .activated(.right, offset: 0.25))
    #expect(edge.tick(at: at(81)) == .idle)
  }

  @Test("moving off the edge cancels a pending activation")
  func cancellation() throws {
    var edge = try detector()
    _ = edge.update(x: 999, y: 250, at: at(0))
    #expect(edge.update(x: 990, y: 250, at: at(50)) == .idle)
    #expect(edge.update(x: 999, y: 250, at: at(60)) == .pending(.right))
    #expect(edge.update(x: 999, y: 250, at: at(139)) == .pending(.right))
    #expect(edge.update(x: 999, y: 250, at: at(140)) == .activated(.right, offset: 0.5))
  }

  @Test("re-arming requires leaving the edge after an activation")
  func rearm() throws {
    var edge = try detector()
    _ = edge.update(x: 999, y: 250, at: at(0))
    _ = edge.update(x: 999, y: 250, at: at(80))
    #expect(edge.update(x: 999, y: 250, at: at(500)) == .idle)
    #expect(edge.update(x: 900, y: 250, at: at(510)) == .idle)
    #expect(edge.update(x: 999, y: 250, at: at(520)) == .pending(.right))
  }

  @Test("unlinked edges never activate")
  func unlinked() throws {
    var edge = try detector([.right])
    #expect(edge.update(x: 0, y: 250, at: at(0)) == .idle)
    #expect(edge.update(x: 0, y: 250, at: at(500)) == .idle)
    #expect(edge.update(x: 500, y: 0, at: at(600)) == .idle)
    #expect(edge.update(x: 500, y: 499, at: at(700)) == .idle)
    var none = try detector([])
    #expect(none.update(x: 999, y: 250, at: at(0)) == .idle)
  }

  @Test("corner dead zone blocks and cancels activation on all four edges")
  func corners() throws {
    var edge = try detector(Set(ScreenEdge.allCases))
    #expect(edge.update(x: 999, y: 29, at: at(0)) == .idle)
    #expect(edge.update(x: 999, y: 470.5, at: at(10)) == .idle)
    #expect(edge.update(x: 0, y: 10, at: at(20)) == .idle)
    #expect(edge.update(x: 15, y: 0, at: at(30)) == .idle)
    #expect(edge.update(x: 985, y: 499, at: at(40)) == .idle)
    #expect(edge.update(x: 999, y: 30, at: at(50)) == .pending(.right))
    #expect(edge.update(x: 999, y: 20, at: at(100)) == .idle)
    #expect(edge.update(x: 0, y: 250, at: at(200)) == .pending(.left))
    #expect(edge.update(x: 0, y: 250, at: at(280)) == .activated(.left, offset: 0.5))
    _ = edge.update(x: 500, y: 250, at: at(300))
    #expect(edge.update(x: 250, y: 0, at: at(310)) == .pending(.top))
    #expect(edge.update(x: 250, y: 0, at: at(390)) == .activated(.top, offset: 0.25))
    _ = edge.update(x: 500, y: 250, at: at(400))
    #expect(edge.update(x: 750, y: 499, at: at(410)) == .pending(.bottom))
    #expect(edge.update(x: 750, y: 499, at: at(490)) == .activated(.bottom, offset: 0.75))
  }

  @Test("out-of-bounds, non-finite and backwards samples fail safe")
  func invalidSamples() throws {
    var edge = try detector()
    _ = edge.update(x: 999, y: 250, at: at(0))
    #expect(edge.update(x: .nan, y: 250, at: at(10)) == .idle)
    #expect(edge.update(x: 999, y: 250, at: at(20)) == .pending(.right))
    #expect(edge.update(x: 999, y: 250, at: at(5)) == .idle)
    #expect(edge.update(x: 1500, y: 250, at: at(30)) == .pending(.right))
    #expect(edge.update(x: 1500, y: 250, at: at(110)) == .activated(.right, offset: 0.5))
  }

  @Test("reset clears pending state and is idempotent")
  func reset() throws {
    var edge = try detector()
    _ = edge.update(x: 999, y: 250, at: at(0))
    edge.reset()
    edge.reset()
    #expect(edge.tick(at: at(200)) == .idle)
    #expect(edge.update(x: 999, y: 250, at: at(210)) == .pending(.right))
  }
}
