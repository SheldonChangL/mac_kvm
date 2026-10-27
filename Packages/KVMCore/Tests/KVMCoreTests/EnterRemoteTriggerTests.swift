import Foundation
import KVMContracts
import KVMCore
import Testing

private func screen(_ value: UInt8) -> ScreenID {
  ScreenID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, value)))
}

private let mac = screen(1)
private let linux = screen(2)

private func makeTrigger(links: [ScreenLink] = [ScreenLink(from: mac, edge: .right, to: linux)])
  throws
  -> EnterRemoteTrigger
{
  let topology = try ScreenTopology(screens: [mac, linux], links: links)
  let router = try #require(ScreenRouter(localScreen: mac, topology: topology))
  let configuration = try #require(
    EdgeDetector.Configuration(activationDelay: .milliseconds(50), cornerDeadZone: 20))
  let mapper = try #require(
    OutboundCoordinateMapper(
      remoteSize: OutboundCoordinateMapper.LogicalSize(width: 1921, height: 1081), entryInset: 1))
  return try #require(
    EnterRemoteTrigger(
      router: router, configuration: configuration,
      localSize: EdgeDetector.ScreenSize(width: 1001, height: 501),
      remoteMappers: [linux: mapper]))
}

@Suite("M2-010 EnterRemoteTrigger")
struct EnterRemoteTriggerTests {
  @Test("happy path: a dwell on a linked edge emits one enter intent with the entry point")
  func intent() throws {
    var trigger = try makeTrigger()
    #expect(trigger.pointer(x: 1000, y: 250, at: .zero, state: .local, available: [linux]) == nil)
    let intent = trigger.pointer(
      x: 1000, y: 250, at: .milliseconds(50), state: .local, available: [linux])
    #expect(
      intent?.action == .edgeActivated(target: linux, entry: NormalizedPoint(x: 1.0 / 1920, y: 0.5))
    )
    #expect(intent?.edge == .right)
    #expect(intent?.entryPoint == OutboundCoordinateMapper.RemotePoint(x: 1, y: 540))
    #expect(
      trigger.pointer(x: 1000, y: 250, at: .milliseconds(200), state: .local, available: [linux])
        == nil)
  }

  @Test("tick fires a pending dwell without a new sample")
  func tick() throws {
    var trigger = try makeTrigger()
    _ = trigger.pointer(x: 1000, y: 125, at: .zero, state: .local, available: [linux])
    #expect(trigger.tick(at: .milliseconds(49), state: .local, available: [linux]) == nil)
    #expect(trigger.tick(at: .milliseconds(50), state: .local, available: [linux])?.edge == .right)
  }

  @Test("no switch: unlinked edges, missing sessions and missing remote geometry")
  func noSwitch() throws {
    var trigger = try makeTrigger()
    _ = trigger.pointer(x: 0, y: 250, at: .zero, state: .local, available: [linux])
    #expect(
      trigger.pointer(x: 0, y: 250, at: .seconds(1), state: .local, available: [linux]) == nil)

    var noSession = try makeTrigger()
    _ = noSession.pointer(x: 1000, y: 250, at: .zero, state: .local, available: [])
    #expect(
      noSession.pointer(x: 1000, y: 250, at: .seconds(1), state: .local, available: []) == nil)

    let topology = try ScreenTopology(
      screens: [mac, linux], links: [ScreenLink(from: mac, edge: .right, to: linux)])
    let router = try #require(ScreenRouter(localScreen: mac, topology: topology))
    let configuration = try #require(
      EdgeDetector.Configuration(activationDelay: .milliseconds(50), cornerDeadZone: 20))
    var noGeometry = try #require(
      EnterRemoteTrigger(
        router: router, configuration: configuration,
        localSize: EdgeDetector.ScreenSize(width: 1001, height: 501), remoteMappers: [:]))
    _ = noGeometry.pointer(x: 1000, y: 250, at: .zero, state: .local, available: [linux])
    #expect(
      noGeometry.pointer(x: 1000, y: 250, at: .seconds(1), state: .local, available: [linux]) == nil
    )
  }

  @Test("deduplicated: non-local states never trigger and reset the dwell")
  func nonLocalStates() throws {
    var trigger = try makeTrigger()
    for state in [InputState.enteringRemote(linux), .remote(linux), .leavingRemote(linux)] {
      _ = trigger.pointer(x: 1000, y: 250, at: .zero, state: state, available: [linux])
      #expect(
        trigger.pointer(x: 1000, y: 250, at: .seconds(1), state: state, available: [linux]) == nil)
      #expect(trigger.tick(at: .seconds(2), state: state, available: [linux]) == nil)
    }
    #expect(
      trigger.pointer(x: 1000, y: 250, at: .seconds(3), state: .local, available: [linux]) == nil)
    #expect(
      trigger.pointer(
        x: 1000, y: 250, at: .seconds(3) + .milliseconds(50), state: .local, available: [linux])?
        .edge == .right)
  }

  @Test("no switch while a local key or button is held; release re-enables it")
  func heldInputBlocksSwitch() throws {
    var trigger = try makeTrigger()
    trigger.observe(.mouseButton(button: .left, phase: .down))
    trigger.observe(.key(key: .shift, phase: .down, modifiers: ModifierState(shift: true)))
    _ = trigger.pointer(x: 1000, y: 250, at: .zero, state: .local, available: [linux])
    #expect(
      trigger.pointer(x: 1000, y: 250, at: .seconds(1), state: .local, available: [linux]) == nil)
    #expect(trigger.tick(at: .seconds(2), state: .local, available: [linux]) == nil)
    trigger.observe(.mouseButton(button: .left, phase: .up))
    #expect(trigger.tick(at: .seconds(3), state: .local, available: [linux]) == nil)
    trigger.observe(.key(key: .shift, phase: .up, modifiers: ModifierState()))
    trigger.observe(.mouseButton(button: .right, phase: .up))
    _ = trigger.pointer(x: 1000, y: 250, at: .seconds(4), state: .local, available: [linux])
    #expect(
      trigger.pointer(
        x: 1000, y: 250, at: .seconds(4) + .milliseconds(50), state: .local, available: [linux])?
        .edge == .right)
  }

  @Test("invalid configuration: degenerate local size")
  func invalid() throws {
    let topology = try ScreenTopology(screens: [mac], links: [])
    let router = try #require(ScreenRouter(localScreen: mac, topology: topology))
    let configuration = try #require(
      EdgeDetector.Configuration(activationDelay: .milliseconds(50), cornerDeadZone: 20))
    #expect(
      EnterRemoteTrigger(
        router: router, configuration: configuration,
        localSize: EdgeDetector.ScreenSize(width: 1, height: 501), remoteMappers: [:]) == nil)
  }
}
