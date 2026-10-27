import Foundation
import KVMContracts
import KVMCore
import Testing

private func screen(_ value: UInt8) -> ScreenID {
  ScreenID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x31, value)))
}

private let mac = screen(1)
private let linux = screen(2)
private let far = screen(3)

private func router() throws -> ScreenRouter {
  let topology = try ScreenTopology(
    screens: [mac, linux, far],
    links: [
      ScreenLink(from: mac, edge: .right, to: linux),
      ScreenLink(from: linux, edge: .right, to: far),
    ])
  return try #require(ScreenRouter(localScreen: mac, topology: topology))
}

@Suite("M2-031 ScreenRouter")
struct ScreenRouterTests {
  @Test("linked edges of the local screen feed the edge detector")
  func linkedEdges() throws {
    #expect(try router().linkedEdges == [.right])
  }

  @Test("happy path: an activated linked edge with a ready session selects its target")
  func activation() throws {
    let r = try router()
    #expect(r.target(across: .right, available: [linux]) == .target(linux))
  }

  @Test("missing session, unlinked edge and non-adjacent screens do not switch")
  func noTarget() throws {
    let r = try router()
    #expect(r.target(across: .right, available: []) == .unavailable)
    #expect(r.target(across: .left, available: [linux, far]) == .unlinked)
    #expect(r.target(across: .top, available: [linux]) == .unlinked)
  }

  @Test("routing: only committed remote routes input remotely")
  func routing() throws {
    let r = try router()
    #expect(r.route(.local, available: [linux]) == .local)
    #expect(r.route(.enteringRemote(linux), available: [linux]) == .local)
    #expect(r.route(.leavingRemote(linux), available: [linux]) == .local)
    #expect(r.route(.remote(linux), available: [linux]) == .remote(linux))
  }

  @Test("invalid or missing remote targets yield a rollback, never a send")
  func rollback() throws {
    let r = try router()
    #expect(r.route(.remote(linux), available: []) == .rollback(linux))
    #expect(r.route(.remote(far), available: [far]) == .rollback(far))
    #expect(r.route(.remote(screen(9)), available: [screen(9)]) == .rollback(screen(9)))
    #expect(RouteDecision.rollback(linux).recoveryAction == .sessionLost(linux))
    #expect(RouteDecision.remote(linux).recoveryAction == nil)
    #expect(RouteDecision.local.recoveryAction == nil)
  }

  @Test("a local screen outside the topology is rejected")
  func invalidLocal() throws {
    let topology = try ScreenTopology(screens: [mac], links: [])
    #expect(ScreenRouter(localScreen: linux, topology: topology) == nil)
    #expect(ScreenRouter(localScreen: mac, topology: topology)?.linkedEdges == [])
  }
}
