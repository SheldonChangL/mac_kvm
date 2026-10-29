import Foundation
import KVMContracts
import Testing

private func screen(_ value: UInt8) -> ScreenID {
  ScreenID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x16, value)))
}

private let mac = screen(1)
private let linux = screen(2)
private let third = screen(3)

@Suite("M2-016 ScreenTopology")
struct ScreenTopologyTests {
  @Test("happy path: a declared link resolves both ways")
  func reciprocal() throws {
    let topology = try ScreenTopology(
      screens: [mac, linux],
      links: [ScreenLink(from: mac, edge: .right, to: linux)]
    )
    #expect(topology.neighbor(of: mac, across: .right) == linux)
    #expect(topology.neighbor(of: linux, across: .left) == mac)
    #expect(topology.neighbor(of: mac, across: .left) == nil)
    #expect(topology.neighbor(of: mac, across: .top) == nil)
    #expect(topology.neighbor(of: third, across: .right) == nil)
  }

  @Test("edges have fixed opposites")
  func opposites() {
    #expect(ScreenEdge.left.opposite == .right)
    #expect(ScreenEdge.right.opposite == .left)
    #expect(ScreenEdge.top.opposite == .bottom)
    #expect(ScreenEdge.bottom.opposite == .top)
  }

  @Test("explicit reciprocal declarations are accepted once")
  func explicitReciprocal() throws {
    let topology = try ScreenTopology(
      screens: [mac, linux],
      links: [
        ScreenLink(from: mac, edge: .right, to: linux),
        ScreenLink(from: linux, edge: .left, to: mac),
      ]
    )
    #expect(topology.links == [ScreenLink(from: mac, edge: .right, to: linux)])
  }

  @Test("invalid: self links, unknown screens, duplicates and empty sets")
  func invalid() {
    #expect(throws: ScreenTopologyError.noScreens) {
      try ScreenTopology(screens: [], links: [])
    }
    #expect(throws: ScreenTopologyError.duplicateScreen) {
      try ScreenTopology(screens: [mac, mac], links: [])
    }
    #expect(throws: ScreenTopologyError.selfLink) {
      try ScreenTopology(screens: [mac], links: [ScreenLink(from: mac, edge: .left, to: mac)])
    }
    #expect(throws: ScreenTopologyError.unknownScreen) {
      try ScreenTopology(screens: [mac], links: [ScreenLink(from: mac, edge: .left, to: linux)])
    }
  }

  @Test("invalid: conflicting links on the same edge or its reciprocal")
  func conflicting() {
    #expect(throws: ScreenTopologyError.conflictingLink) {
      try ScreenTopology(
        screens: [mac, linux, third],
        links: [
          ScreenLink(from: mac, edge: .right, to: linux),
          ScreenLink(from: mac, edge: .right, to: third),
        ]
      )
    }
    #expect(throws: ScreenTopologyError.conflictingLink) {
      try ScreenTopology(
        screens: [mac, linux, third],
        links: [
          ScreenLink(from: mac, edge: .right, to: linux),
          ScreenLink(from: third, edge: .right, to: linux),
        ]
      )
    }
    #expect(throws: ScreenTopologyError.conflictingLink) {
      try ScreenTopology(
        screens: [mac, linux],
        links: [
          ScreenLink(from: mac, edge: .right, to: linux),
          ScreenLink(from: mac, edge: .left, to: linux),
        ]
      )
    }
  }

  @Test("boundary: the screen count is bounded")
  func screenLimit() throws {
    let many = (0..<UInt8(ScreenTopology.maximumScreenCount)).map { screen($0 &+ 10) }
    _ = try ScreenTopology(screens: many, links: [])
    #expect(throws: ScreenTopologyError.tooManyScreens) {
      try ScreenTopology(screens: many + [screen(200)], links: [])
    }
  }

  @Test("serialization is deterministic and decoding revalidates")
  func serialization() throws {
    let a = try ScreenTopology(
      screens: [linux, mac, third],
      links: [
        ScreenLink(from: third, edge: .top, to: mac),
        ScreenLink(from: mac, edge: .right, to: linux),
      ]
    )
    let b = try ScreenTopology(
      screens: [third, mac, linux],
      links: [
        ScreenLink(from: linux, edge: .left, to: mac),
        ScreenLink(from: mac, edge: .bottom, to: third),
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encodedA = try encoder.encode(a)
    #expect(encodedA == (try encoder.encode(b)))
    #expect(try JSONDecoder().decode(ScreenTopology.self, from: encodedA) == a)

    let tampered = Data(
      """
      {"links":[{"edge":"left","from":{"rawValue":"\(mac.rawValue)"},"to":{"rawValue":"\(mac.rawValue)"}}],\
      "screens":[{"rawValue":"\(mac.rawValue)"}]}
      """.utf8)
    #expect(throws: ScreenTopologyError.selfLink) {
      try JSONDecoder().decode(ScreenTopology.self, from: tampered)
    }
  }
}
