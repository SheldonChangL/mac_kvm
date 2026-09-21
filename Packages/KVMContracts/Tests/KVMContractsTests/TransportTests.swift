import Foundation
import Testing

@testable import KVMContracts

private actor RecordingTransport: Transport {
  nonisolated let incomingBytes: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private(set) var connectCount = 0
  private(set) var sentChunks: [Data] = []
  private(set) var disconnectCount = 0
  private var hasConnected = false
  private var isTerminal = false

  init(bufferingLimit: Int = 4) {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(bufferingLimit)
    )
    incomingBytes = stream
    self.continuation = continuation
  }

  func connect() async throws(CoreError) {
    guard !hasConnected, !isTerminal else {
      throw Self.preconditionFailure()
    }

    hasConnected = true
    connectCount += 1
  }

  func send(_ data: Data) async throws(CoreError) {
    guard hasConnected, !isTerminal else {
      throw CoreError(
        code: .transport(.disconnected),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .completed
      )
    }
    guard !data.isEmpty else { return }

    sentChunks.append(data)
  }

  func disconnect() async {
    guard !isTerminal else { return }
    isTerminal = true
    disconnectCount += 1
    continuation.finish()
  }

  func receive(_ data: Data) {
    guard hasConnected, !isTerminal, !data.isEmpty else { return }

    switch continuation.yield(data) {
    case .enqueued:
      return
    case .dropped:
      finish(
        throwing: CoreError(
          code: .transport(.resourceExhausted),
          severity: .error,
          retryDisposition: .backoff,
          cleanupDisposition: .notRequired
        )
      )
    case .terminated:
      return
    @unknown default:
      finish(throwing: Self.preconditionFailure())
    }
  }

  func fail(with error: CoreError) {
    guard !isTerminal else { return }
    finish(throwing: error)
  }

  private func finish(throwing error: CoreError) {
    isTerminal = true
    continuation.finish(throwing: error)
  }

  private static func preconditionFailure() -> CoreError {
    CoreError(
      code: .internalFailure(.preconditionFailed),
      severity: .error,
      retryDisposition: .never,
      cleanupDisposition: .notRequired
    )
  }
}

@Test func transportConnectsAndPreservesOutboundByteOrder() async throws {
  let transport = RecordingTransport()
  let first = Data([0x00, 0x01])
  let second = Data([0x02, 0xFF])

  try await transport.connect()
  try await transport.send(first)
  try await transport.send(second)

  #expect(await transport.connectCount == 1)
  #expect(await transport.sentChunks == [first, second])
}

@Test func incomingChunksRemainOrderedWithoutImplyingFrameBoundaries() async throws {
  let transport = RecordingTransport()
  var iterator = transport.incomingBytes.makeAsyncIterator()
  let firstChunk = Data([0x01])
  let secondChunk = Data([0x02, 0x03, 0x04])

  try await transport.connect()
  await transport.receive(firstChunk)
  await transport.receive(secondChunk)

  #expect(try await iterator.next() == firstChunk)
  #expect(try await iterator.next() == secondChunk)
  #expect(firstChunk + secondChunk == Data([0x01, 0x02, 0x03, 0x04]))
}

@Test func zeroLengthChunksAreNoOps() async throws {
  let transport = RecordingTransport()
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()
  try await transport.send(Data())
  await transport.receive(Data())
  await transport.disconnect()

  #expect(await transport.sentChunks.isEmpty)
  #expect(try await iterator.next() == nil)
}

@Test func transportRejectsInvalidLifecycleOperations() async throws {
  let transport = RecordingTransport()
  let bytes = Data([0x01])

  await #expect(throws: CoreError.self) {
    try await transport.send(bytes)
  }

  try await transport.connect()
  await #expect(throws: CoreError.self) {
    try await transport.connect()
  }

  await transport.disconnect()
  await #expect(throws: CoreError.self) {
    try await transport.send(bytes)
  }
  await #expect(throws: CoreError.self) {
    try await transport.connect()
  }
}

@Test func disconnectIsIdempotentAndFinishesIncomingBytes() async throws {
  let transport = RecordingTransport()
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()
  await transport.disconnect()
  await transport.disconnect()

  #expect(await transport.disconnectCount == 1)
  #expect(try await iterator.next() == nil)
}

@Test func typedFailureTerminatesIncomingBytes() async throws {
  let transport = RecordingTransport()
  var iterator = transport.incomingBytes.makeAsyncIterator()
  let terminalError = CoreError(
    code: .transport(.reset),
    severity: .error,
    retryDisposition: .backoff,
    cleanupDisposition: .completed
  )

  try await transport.connect()
  await transport.fail(with: terminalError)

  do {
    _ = try await iterator.next()
    Issue.record("transport failure must not finish as success")
  } catch let error as CoreError {
    #expect(error == terminalError)
  } catch {
    Issue.record("transport failure must remain a CoreError")
  }
}

@Test func cancellationRemainsATypedTerminalFailure() async throws {
  let transport = RecordingTransport()
  var iterator = transport.incomingBytes.makeAsyncIterator()
  let cancellation = CoreError(
    code: .cancellation(.shutdown),
    severity: .notice,
    retryDisposition: .never,
    cleanupDisposition: .completed
  )

  try await transport.connect()
  await transport.fail(with: cancellation)

  do {
    _ = try await iterator.next()
    Issue.record("cancellation must not finish as success")
  } catch let error as CoreError {
    #expect(error.code == .cancellation(.shutdown))
    #expect(error.cleanupDisposition == .completed)
  } catch {
    Issue.record("cancellation must remain a CoreError")
  }
}

@Test func boundedBufferOverflowFailsClosedWithoutReordering() async throws {
  let transport = RecordingTransport(bufferingLimit: 1)
  var iterator = transport.incomingBytes.makeAsyncIterator()
  let retained = Data([0x01])

  try await transport.connect()
  await transport.receive(retained)
  await transport.receive(Data([0x02]))

  #expect(try await iterator.next() == retained)
  do {
    _ = try await iterator.next()
    Issue.record("overflow must terminate with a typed failure")
  } catch let error as CoreError {
    #expect(error.code == .transport(.resourceExhausted))
  } catch {
    Issue.record("overflow must remain a CoreError")
  }
}
