import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

private final class FakeCursor: @unchecked Sendable {
  private let lock = NSLock()
  var location: CGPoint? = CGPoint(x: 100, y: 100)
  var displays: [CGRect] = [CGRect(x: 0, y: 0, width: 1000, height: 500)]
  var warpSucceeds = true
  var failingWarpPoints: [CGPoint] = []
  var associateSucceeds = true
  private(set) var warps: [CGPoint] = []
  private(set) var associations: [Bool] = []

  func record(warp point: CGPoint) -> Bool {
    lock.withLock { warps.append(point) }
    return warpSucceeds && !failingWarpPoints.contains(point)
  }

  func record(associate value: Bool) -> Bool {
    lock.withLock { associations.append(value) }
    return associateSucceeds
  }

  var environment: CursorEnvironment {
    CursorEnvironment(
      currentLocation: { self.location },
      displayBounds: { self.displays },
      warp: { self.record(warp: $0) },
      associateMouseAndCursor: { self.record(associate: $0) }
    )
  }
}

@Suite("M2-021 CursorRestorer")
struct CursorRestorerTests {
  @Test("happy path: the preferred re-entry point wins when it is on a display")
  func preferred() {
    let fake = FakeCursor()
    let restorer = CursorRestorer(environment: fake.environment)
    #expect(restorer.saveCurrent())
    #expect(restorer.restore(preferred: CGPoint(x: 998, y: 250)) == .restored(.preferred))
    #expect(fake.warps == [CGPoint(x: 998, y: 250)])
    #expect(fake.associations == [true])
  }

  @Test("fallback: the saved point is used when no preferred point is given")
  func saved() {
    let fake = FakeCursor()
    let restorer = CursorRestorer(environment: fake.environment)
    _ = restorer.saveCurrent()
    #expect(restorer.restore(preferred: nil) == .restored(.saved))
    #expect(fake.warps == [CGPoint(x: 100, y: 100)])
  }

  @Test("hot-plug: points on removed displays fall back to the first display center")
  func hotPlug() {
    let fake = FakeCursor()
    fake.location = CGPoint(x: 1500, y: 100)
    fake.displays = [
      CGRect(x: 0, y: 0, width: 1000, height: 500), CGRect(x: 1000, y: 0, width: 1000, height: 500),
    ]
    let restorer = CursorRestorer(environment: fake.environment)
    _ = restorer.saveCurrent()
    fake.displays = [CGRect(x: 0, y: 0, width: 1000, height: 500)]
    #expect(restorer.restore(preferred: CGPoint(x: 1998, y: 10)) == .restored(.displayCenter))
    #expect(fake.warps == [CGPoint(x: 500, y: 250)])
  }

  @Test("failure: no display or a failing warp is reported, association still restored")
  func failures() {
    let fake = FakeCursor()
    fake.displays = []
    let restorer = CursorRestorer(environment: fake.environment)
    #expect(restorer.restore(preferred: nil) == .failed)
    #expect(fake.associations == [true])
    fake.displays = [CGRect(x: 0, y: 0, width: 10, height: 10)]
    fake.warpSucceeds = false
    #expect(restorer.restore(preferred: CGPoint(x: 1, y: 1)) == .failed)
    #expect(fake.associations == [true, true])
  }

  @Test("a failed warp falls through to the next candidate")
  func warpFallthrough() {
    let fake = FakeCursor()
    let restorer = CursorRestorer(environment: fake.environment)
    _ = restorer.saveCurrent()
    fake.failingWarpPoints = [CGPoint(x: 998, y: 250)]
    #expect(restorer.restore(preferred: CGPoint(x: 998, y: 250)) == .restored(.saved))
    #expect(fake.warps == [CGPoint(x: 998, y: 250), CGPoint(x: 100, y: 100)])
  }

  @Test("save rejects unreadable locations and keeps the previous point")
  func saveFailure() {
    let fake = FakeCursor()
    let restorer = CursorRestorer(environment: fake.environment)
    _ = restorer.saveCurrent()
    fake.location = nil
    #expect(!restorer.saveCurrent())
    fake.location = CGPoint(x: CGFloat.nan, y: 0)
    #expect(!restorer.saveCurrent())
    #expect(restorer.restore(preferred: nil) == .restored(.saved))
    #expect(fake.warps == [CGPoint(x: 100, y: 100)])
  }

  @Test("restore is idempotent and clear forgets the saved point")
  func idempotent() {
    let fake = FakeCursor()
    let restorer = CursorRestorer(environment: fake.environment)
    _ = restorer.saveCurrent()
    #expect(restorer.restore(preferred: nil) == .restored(.saved))
    #expect(restorer.restore(preferred: nil) == .restored(.saved))
    restorer.clear()
    #expect(restorer.restore(preferred: nil) == .restored(.displayCenter))
  }
}
