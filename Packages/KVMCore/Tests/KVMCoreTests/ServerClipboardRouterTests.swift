import Foundation
import KVMContracts
import KVMCore
import Testing

private func fixedUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x32, value))
}

private let clientA = ScreenID(rawValue: fixedUUID(1))
private let clientB = ScreenID(rawValue: fixedUUID(2))
private let peer = DeviceID(rawValue: fixedUUID(3))

private func remote(_ text: String, hash: String = "") -> ClipboardPayload {
  ClipboardPayload(
    transactionID: ClipboardTransactionID(), origin: .remote(peer), utf8Text: text,
    contentHash: hash)
}

private func router(limit byteCount: Int = 1024) throws -> ServerClipboardRouter<Int> {
  ServerClipboardRouter(limit: try #require(ClipboardByteLimit(byteCount: byteCount)))
}

/// Counts the local reads the router asks for.
private final class LocalText: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  private var count = 0

  init(_ value: String?) {
    self.value = value
  }

  var reads: Int { lock.withLock { count } }

  func set(_ text: String?) {
    lock.withLock { value = text }
  }

  func read() -> String? {
    lock.withLock {
      count += 1
      return value
    }
  }
}

@Suite("M2-032 ServerClipboardRouter")
struct ServerClipboardRouterTests {
  @Test("local text goes to an entered client once per local change")
  func localToClient() throws {
    var router = try router()
    let local = LocalText("alpha")
    let first = router.outbound(to: clientA, generation: 1, read: local.read)
    let sent = try #require(first)
    #expect(sent.utf8Text == "alpha")
    #expect(sent.origin == .local)
    #expect(!sent.contentHash.isEmpty)

    #expect(router.outbound(to: clientA, generation: 1, read: local.read) == nil)
    #expect(local.reads == 1)

    local.set("beta")
    #expect(router.outbound(to: clientA, generation: 2, read: local.read)?.utf8Text == "beta")
  }

  @Test("each client gets a local change once")
  func everyClientOnce() throws {
    var router = try router()
    let local = LocalText("alpha")
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) != nil)
    #expect(router.outbound(to: clientB, generation: 1, read: local.read) != nil)
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) == nil)
    #expect(router.outbound(to: clientB, generation: 1, read: local.read) == nil)
    #expect(local.reads == 2)
  }

  @Test("a client's copy is applied locally, never sent back to it, and reaches other clients")
  func clientToLocal() throws {
    var router = try router()
    let admitted = router.inbound(remote("gamma"), from: clientA)
    let applied = try #require(admitted)
    #expect(applied.utf8Text == "gamma")
    #expect(!applied.contentHash.isEmpty)
    router.applied(generation: 2, from: clientA)

    let local = LocalText("gamma")
    #expect(router.outbound(to: clientA, generation: 2, read: local.read) == nil)
    #expect(local.reads == 0)
    #expect(router.outbound(to: clientB, generation: 2, read: local.read)?.utf8Text == "gamma")
  }

  @Test("no echo storm: content a client already holds is not applied again from it")
  func noEchoStorm() throws {
    var router = try router()
    #expect(router.inbound(remote("gamma"), from: clientA) != nil)
    router.applied(generation: 2, from: clientA)
    let local = LocalText("gamma")
    #expect(router.outbound(to: clientB, generation: 2, read: local.read) != nil)

    // Both clients send the same content back under new transactions.
    #expect(router.inbound(remote("gamma"), from: clientB) == nil)
    #expect(router.inbound(remote("gamma"), from: clientA) == nil)
    #expect(router.outbound(to: clientA, generation: 2, read: local.read) == nil)
    #expect(router.outbound(to: clientB, generation: 2, read: local.read) == nil)
  }

  @Test("the inbound hash is recomputed, so an echo with a different hash is still caught")
  func inboundHashRecomputed() throws {
    var router = try router()
    let local = LocalText("alpha")
    let first = router.outbound(to: clientA, generation: 1, read: local.read)
    let sent = try #require(first)
    #expect(router.inbound(remote("alpha", hash: "peer-supplied"), from: clientA) == nil)
    let admitted = router.inbound(remote("delta", hash: sent.contentHash), from: clientA)
    let other = try #require(admitted)
    #expect(other.contentHash != sent.contentHash)
  }

  @Test("copying the same text again is not re-sent, and that generation is not re-read")
  func sameContentNewGeneration() throws {
    var router = try router()
    let local = LocalText("alpha")
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) != nil)
    #expect(router.outbound(to: clientA, generation: 2, read: local.read) == nil)
    #expect(router.outbound(to: clientA, generation: 2, read: local.read) == nil)
    #expect(local.reads == 2)
  }

  @Test("boundary: text at the limit passes, one byte over is refused both ways")
  func sizeLimit() throws {
    var router = try router(limit: 5)
    let local = LocalText("abcde")
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) != nil)
    local.set("abcdef")
    #expect(router.outbound(to: clientA, generation: 2, read: local.read) == nil)
    #expect(router.inbound(remote("vwxyz!"), from: clientA) == nil)
    #expect(router.inbound(remote("vwxyz"), from: clientA) != nil)
  }

  @Test("an empty or unreadable local clipboard sends nothing and is not re-read")
  func nothingToSend() throws {
    var router = try router()
    let local = LocalText(nil)
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) == nil)
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) == nil)
    #expect(local.reads == 1)
  }

  @Test("invalid: local-origin and replayed inbound payloads are refused")
  func invalidInbound() throws {
    var router = try router()
    let local = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "alpha", contentHash: "")
    #expect(router.inbound(local, from: clientA) == nil)

    let first = remote("alpha")
    #expect(router.inbound(first, from: clientA) != nil)
    let replay = ClipboardPayload(
      transactionID: first.transactionID, origin: first.origin, utf8Text: "beta", contentHash: "")
    #expect(router.inbound(replay, from: clientA) == nil)
  }

  @Test("cleanup: a forgotten client starts afresh, and forgetting twice is a no-op")
  func forget() throws {
    var router = try router()
    let local = LocalText("alpha")
    #expect(router.outbound(to: clientA, generation: 1, read: local.read) != nil)
    router.forget(clientA)
    router.forget(clientA)
    router.forget(clientB)
    #expect(router.outbound(to: clientA, generation: 1, read: local.read)?.utf8Text == "alpha")
  }

  @Test("privacy: no rendering of the router contains clipboard text")
  func redacted() throws {
    var router = try router()
    let local = LocalText("m2-032-secret-probe")
    _ = router.outbound(to: clientA, generation: 1, read: local.read)
    _ = router.inbound(remote("m2-032-other-probe"), from: clientB)
    var dumped = ""
    dump(router, to: &dumped)
    for rendering in [String(describing: router), String(reflecting: router), dumped] {
      #expect(!rendering.contains("probe"))
    }
  }
}
