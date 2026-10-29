import Foundation

/// One side of a logical screen rectangle.
package enum ScreenEdge: String, Codable, CaseIterable, Hashable, Sendable {
  case left
  case right
  case top
  case bottom

  /// The edge a pointer arrives through on the linked screen.
  package var opposite: ScreenEdge {
    switch self {
    case .left: .right
    case .right: .left
    case .top: .bottom
    case .bottom: .top
    }
  }
}

/// A declared adjacency: leaving `from` through `edge` arrives on `to`.
///
/// Every link is reciprocal: `to` leaves through `edge.opposite` back to
/// `from`. The reciprocal is derived, not declared again.
package struct ScreenLink: Codable, Hashable, Sendable {
  package let from: ScreenID
  package let edge: ScreenEdge
  package let to: ScreenID

  package init(from: ScreenID, edge: ScreenEdge, to: ScreenID) {
    self.from = from
    self.edge = edge
    self.to = to
  }

  fileprivate var reciprocal: ScreenLink {
    ScreenLink(from: to, edge: edge.opposite, to: from)
  }

  /// The orientation whose `from` sorts first; used for deterministic output.
  fileprivate var canonical: ScreenLink {
    from.rawValue.uuidString <= to.rawValue.uuidString ? self : reciprocal
  }
}

/// Typed, content-free topology validation failures.
package enum ScreenTopologyError: Error, Equatable, Sendable {
  case noScreens
  case tooManyScreens
  case duplicateScreen
  case unknownScreen
  case selfLink
  /// Two links claim the same screen edge, or one screen pair is linked
  /// through more than one edge.
  case conflictingLink
}

/// Validated screen adjacency for server routing (C-008 / M2-016).
///
/// Validation is deterministic and runs on construction and on decoding, so a
/// `ScreenTopology` value is always valid. Encoding emits screens and
/// canonical links in sorted order, so equal topologies encode identically.
package struct ScreenTopology: Codable, Equatable, Sendable {
  /// Upper bound on screens in one topology.
  package static let maximumScreenCount = 16

  /// Screens sorted by identifier.
  package let screens: [ScreenID]
  /// Canonical links sorted by `from`, then `edge`.
  package let links: [ScreenLink]

  private let neighbors: [EdgeKey: ScreenID]

  private struct EdgeKey: Hashable, Sendable {
    let screen: ScreenID
    let edge: ScreenEdge
  }

  package init(screens: [ScreenID], links: [ScreenLink]) throws(ScreenTopologyError) {
    guard !screens.isEmpty else { throw .noScreens }
    guard screens.count <= Self.maximumScreenCount else { throw .tooManyScreens }
    let screenSet = Set(screens)
    guard screenSet.count == screens.count else { throw .duplicateScreen }

    var neighbors: [EdgeKey: ScreenID] = [:]
    var linkedPairs: [Set<ScreenID>: ScreenLink] = [:]
    var canonicalLinks: Set<ScreenLink> = []
    for link in links {
      guard link.from != link.to else { throw .selfLink }
      guard screenSet.contains(link.from), screenSet.contains(link.to) else {
        throw .unknownScreen
      }
      let canonical = link.canonical
      let pair: Set<ScreenID> = [link.from, link.to]
      if let existing = linkedPairs[pair] {
        guard existing == canonical else { throw .conflictingLink }
        continue
      }
      for directed in [link, link.reciprocal] {
        let key = EdgeKey(screen: directed.from, edge: directed.edge)
        guard neighbors[key] == nil else { throw .conflictingLink }
        neighbors[key] = directed.to
      }
      linkedPairs[pair] = canonical
      canonicalLinks.insert(canonical)
    }

    self.screens = screens.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    self.links = canonicalLinks.sorted {
      ($0.from.rawValue.uuidString, Self.order($0.edge))
        < ($1.from.rawValue.uuidString, Self.order($1.edge))
    }
    self.neighbors = neighbors
  }

  /// The screen reached by leaving `screen` through `edge`, if linked.
  package func neighbor(of screen: ScreenID, across edge: ScreenEdge) -> ScreenID? {
    neighbors[EdgeKey(screen: screen, edge: edge)]
  }

  private enum CodingKeys: String, CodingKey {
    case screens
    case links
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      screens: container.decode([ScreenID].self, forKey: .screens),
      links: container.decode([ScreenLink].self, forKey: .links)
    )
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(screens, forKey: .screens)
    try container.encode(links, forKey: .links)
  }

  package static func == (lhs: ScreenTopology, rhs: ScreenTopology) -> Bool {
    lhs.screens == rhs.screens && lhs.links == rhs.links
  }

  private static func order(_ edge: ScreenEdge) -> Int {
    ScreenEdge.allCases.firstIndex(of: edge) ?? 0
  }
}
