import Foundation
import KVMContracts
import KVMCore
import Testing

private func fixedUUID(_ kind: UInt8, _ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x30, kind, value))
}

private func sessionID(_ value: UInt8) -> SessionID { SessionID(rawValue: fixedUUID(1, value)) }
private func screen(_ value: UInt8) -> ScreenID { ScreenID(rawValue: fixedUUID(2, value)) }

/// Minimal protocol session that only records disconnects.
private final class RecordingProtocolSession: KVMProtocolSession, @unchecked Sendable {
  private let lock = NSLock()
  private var reasons: [DisconnectReason] = []
  let events: AsyncThrowingStream<KVMEvent, any Error>
  private let continuation: AsyncThrowingStream<KVMEvent, any Error>.Continuation

  init() {
    (events, continuation) = AsyncThrowingStream.makeStream()
  }

  var disconnects: [DisconnectReason] { lock.withLock { reasons } }

  func connect() async throws(CoreError) {}
  func send(_ event: KVMEvent) async throws(CoreError) {}
  func disconnect(reason: DisconnectReason) async {
    lock.withLock { reasons.append(reason) }
    continuation.finish()
  }
}

private func makeSession(_ id: UInt8, screen screenValue: UInt8)
  -> (ServerSession, RecordingProtocolSession)
{
  let fake = RecordingProtocolSession()
  return (
    ServerSession(id: sessionID(id), screen: screen(screenValue), protocolSession: fake), fake
  )
}

@Suite("M2-030 SessionManager")
struct SessionManagerTests {
  @Test("happy path: register, look up by screen, activate and remove")
  func lifecycle() async throws {
    let manager = try #require(SessionManager(maximumSessions: 4))
    let (session, fake) = makeSession(1, screen: 1)
    try await manager.register(session)
    #expect(await manager.session(for: screen(1)) === session)
    #expect(await manager.count == 1)
    try await manager.activate(screen(1))
    #expect(await manager.activeTarget == screen(1))
    #expect(await manager.remove(sessionID(1), reason: .userRequested) == .removedActive(screen(1)))
    #expect(await manager.activeTarget == nil)
    #expect(await manager.count == 0)
    #expect(fake.disconnects == [.userRequested])
  }

  @Test("invalid: duplicate ids, duplicate screens and capacity are rejected and closed")
  func rejections() async throws {
    let manager = try #require(SessionManager(maximumSessions: 2))
    try await manager.register(makeSession(1, screen: 1).0)
    let (sameID, sameIDFake) = makeSession(1, screen: 2)
    await #expect(throws: SessionManagerError.duplicateSession) {
      try await manager.register(sameID)
    }
    #expect(sameIDFake.disconnects.count == 1)
    let (sameScreen, _) = makeSession(2, screen: 1)
    await #expect(throws: SessionManagerError.duplicateScreen) {
      try await manager.register(sameScreen)
    }
    try await manager.register(makeSession(3, screen: 3).0)
    let (extra, extraFake) = makeSession(4, screen: 4)
    await #expect(throws: SessionManagerError.capacityExceeded) {
      try await manager.register(extra)
    }
    #expect(extraFake.disconnects.count == 1)
    #expect(SessionManager(maximumSessions: 0) == nil)
    #expect(SessionManager(maximumSessions: SessionManager.largestSessionLimit + 1) == nil)
  }

  @Test("exactly one active target; unknown screens cannot be activated")
  func uniqueActive() async throws {
    let manager = try #require(SessionManager(maximumSessions: 4))
    try await manager.register(makeSession(1, screen: 1).0)
    try await manager.register(makeSession(2, screen: 2).0)
    try await manager.activate(screen(1))
    try await manager.activate(screen(2))
    #expect(await manager.activeTarget == screen(2))
    await #expect(throws: SessionManagerError.unknownScreen) {
      try await manager.activate(screen(9))
    }
    #expect(await manager.activeTarget == screen(2))
    await manager.deactivate()
    await manager.deactivate()
    #expect(await manager.activeTarget == nil)
    #expect(await manager.remove(sessionID(1), reason: .userRequested) == .removed)
    #expect(await manager.remove(sessionID(1), reason: .userRequested) == .notFound)
  }

  @Test("closeAll closes every session once and is idempotent")
  func closeAll() async throws {
    let manager = try #require(SessionManager(maximumSessions: 4))
    let (a, fakeA) = makeSession(1, screen: 1)
    let (b, fakeB) = makeSession(2, screen: 2)
    try await manager.register(a)
    try await manager.register(b)
    try await manager.activate(screen(1))
    #expect(await manager.closeAll(reason: .applicationTermination) == screen(1))
    #expect(await manager.closeAll(reason: .applicationTermination) == nil)
    #expect(fakeA.disconnects == [.applicationTermination])
    #expect(fakeB.disconnects == [.applicationTermination])
    #expect(await manager.count == 0)
    #expect(await manager.activeTarget == nil)
  }

  @Test("concurrent register and remove keep the dictionary consistent")
  func concurrency() async throws {
    let manager = try #require(SessionManager(maximumSessions: SessionManager.largestSessionLimit))
    let limit = UInt8(SessionManager.largestSessionLimit)
    await withTaskGroup(of: Void.self) { group in
      for value in 1...limit {
        group.addTask { try? await manager.register(makeSession(value, screen: value).0) }
      }
    }
    #expect(await manager.count == Int(limit))
    await withTaskGroup(of: Void.self) { group in
      for value in 1...limit where value % 2 == 0 {
        group.addTask { _ = await manager.remove(sessionID(value), reason: .userRequested) }
      }
      group.addTask { try? await manager.activate(screen(1)) }
    }
    #expect(await manager.count == Int(limit) / 2)
    #expect(await manager.activeTarget == screen(1))
  }
}
