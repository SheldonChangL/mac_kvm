import Foundation
import Testing

@testable import KVMContracts

private actor RecordingProtocolSession: KVMProtocolSession {
  nonisolated let events: AsyncThrowingStream<KVMEvent, any Error>

  private let continuation: AsyncThrowingStream<KVMEvent, any Error>.Continuation
  private(set) var connectCount = 0
  private(set) var sentEvents: [KVMEvent] = []
  private(set) var disconnectReasons: [DisconnectReason] = []
  private var hasConnected = false
  private var isTerminal = false

  init() {
    let (stream, continuation) = AsyncThrowingStream<KVMEvent, any Error>.makeStream()
    events = stream
    self.continuation = continuation
  }

  func connect() async throws(CoreError) {
    guard !hasConnected, !isTerminal else {
      throw CoreError(
        code: .internalFailure(.preconditionFailed),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .notRequired
      )
    }

    hasConnected = true
    connectCount += 1
  }

  func send(_ event: KVMEvent) async throws(CoreError) {
    guard !isTerminal else {
      throw CoreError(
        code: .transport(.disconnected),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .completed
      )
    }

    sentEvents.append(event)
    continuation.yield(event)
  }

  func disconnect(reason: DisconnectReason) async {
    disconnectReasons.append(reason)
    guard !isTerminal else { return }
    isTerminal = true

    switch reason {
    case .cancellation(let cancellationReason):
      continuation.finish(
        throwing: CoreError(
          code: .cancellation(cancellationReason),
          severity: .notice,
          retryDisposition: .never,
          cleanupDisposition: .completed
        )
      )
    case .failure(let error):
      continuation.finish(throwing: error)
    default:
      continuation.finish()
    }
  }
}

@Test func sessionConnectsSendsAndEmitsPlatformNeutralEvents() async throws {
  let session = RecordingProtocolSession()
  var iterator = session.events.makeAsyncIterator()
  let event = KVMEvent.scroll(deltaX: -1, deltaY: 2)

  try await session.connect()
  try await session.send(event)

  #expect(try await iterator.next() == event)
  #expect(await session.connectCount == 1)
  #expect(await session.sentEvents == [event])
}

@Test func sessionRejectsRepeatedConnectAndReconnectAfterTermination() async throws {
  let session = RecordingProtocolSession()

  try await session.connect()
  await #expect(throws: CoreError.self) {
    try await session.connect()
  }

  await session.disconnect(reason: .userRequested)
  await #expect(throws: CoreError.self) {
    try await session.connect()
  }
}

@Test func disconnectReasonsAreClosedTypedAndCodable() throws {
  let failure = CoreError(
    code: .security(.identityChanged),
    severity: .error,
    retryDisposition: .userActionRequired,
    cleanupDisposition: .completed
  )
  let reasons: [DisconnectReason] = [
    .userRequested,
    .transportClosed,
    .cancellation(.requested),
    .failure(failure),
    .applicationTermination,
  ]

  for reason in reasons {
    let encoded = try JSONEncoder().encode(reason)
    #expect(try JSONDecoder().decode(DisconnectReason.self, from: encoded) == reason)
    let serialized = String(decoding: encoded, as: UTF8.self)
    #expect(!serialized.contains("message"))
    #expect(!serialized.contains("description"))
  }

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      DisconnectReason.self,
      from: Data(#"{"unknownTerminalReason":{}}"#.utf8)
    )
  }
}

@Test func gracefulDisconnectFinishesEventsAndIsIdempotent() async throws {
  let session = RecordingProtocolSession()
  var iterator = session.events.makeAsyncIterator()

  await session.disconnect(reason: .userRequested)
  await session.disconnect(reason: .applicationTermination)

  #expect(try await iterator.next() == nil)
  #expect(await session.disconnectReasons == [.userRequested, .applicationTermination])
}

@Test func terminalFailureFinishesEventsWithTheTypedCoreError() async {
  let session = RecordingProtocolSession()
  var iterator = session.events.makeAsyncIterator()
  let terminalError = CoreError(
    code: .protocolViolation(.malformed),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .completed
  )

  await session.disconnect(reason: .failure(terminalError))

  do {
    _ = try await iterator.next()
    Issue.record("terminal failure must not finish as success")
  } catch let error as CoreError {
    #expect(error == terminalError)
  } catch {
    Issue.record("terminal failure must remain a CoreError")
  }
}

@Test func cancellationIsTerminalAndSendAfterTerminationFailsClosed() async {
  let session = RecordingProtocolSession()
  var iterator = session.events.makeAsyncIterator()
  let reason = DisconnectReason.cancellation(.shutdown)

  await session.disconnect(reason: reason)

  do {
    _ = try await iterator.next()
    Issue.record("cancellation must not finish as success")
  } catch let error as CoreError {
    #expect(error.code == .cancellation(.shutdown))
    #expect(error.cleanupDisposition == .completed)
  } catch {
    Issue.record("cancellation must remain a CoreError")
  }
  await #expect(throws: CoreError.self) {
    try await session.send(.mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)))
  }
  #expect(await session.disconnectReasons == [reason])
}
