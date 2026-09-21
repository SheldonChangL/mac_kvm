import Foundation
import KVMContracts
import KVMCore
import Testing

private let firstChunk = Data([0x01])
private let secondChunk = Data([0x02, 0x03, 0x04])

@Test func mockTransportRecordsOutboundBytesInCallOrder() async throws {
  let transport = try MockTransport()
  let first = Data([0x00, 0x01])
  let second = Data([0x02, 0xFF])

  try await transport.connect()
  try await transport.send(first)
  try await transport.send(second)

  #expect(await transport.connectCount == 1)
  #expect(await transport.recordedOutbound == [first, second])
}

@Test func mockTransportDeliversScriptedInboundChunksInOrder() async throws {
  let transport = try MockTransport(inbound: [firstChunk, secondChunk])
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()

  #expect(try await iterator.next() == firstChunk)
  #expect(try await iterator.next() == secondChunk)
  #expect(firstChunk + secondChunk == Data([0x01, 0x02, 0x03, 0x04]))
}

@Test func mockTransportTreatsZeroLengthSendAsSuccessfulNoOp() async throws {
  let transport = try MockTransport()

  try await transport.connect()
  try await transport.send(Data())

  #expect(await transport.recordedOutbound.isEmpty)
}

@Test func mockTransportRejectsEmptyScriptedInboundChunk() {
  do {
    _ = try MockTransport(inbound: [firstChunk, Data()])
    Issue.record("an empty scripted chunk must fail closed")
  } catch {
    #expect(error.code == .internalFailure(.preconditionFailed))
  }
}

@Test func mockTransportRejectsNonPositiveBufferLimit() {
  do {
    _ = try MockTransport(incomingBufferLimit: 0)
    Issue.record("a non-positive buffer limit must fail closed")
  } catch {
    #expect(error.code == .internalFailure(.preconditionFailed))
  }
}

@Test func mockTransportRejectsInvalidLifecycleOperations() async throws {
  let transport = try MockTransport()
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
  #expect(await transport.recordedOutbound.isEmpty)
}

@Test func mockTransportInjectsNormalEndOfStreamAfterScriptedChunks() async throws {
  let transport = try MockTransport(inbound: [firstChunk], completion: .endOfStream)
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()

  #expect(try await iterator.next() == firstChunk)
  #expect(try await iterator.next() == nil)
}

@Test func mockTransportInjectsTypedTransportFailure() async throws {
  let terminalError = CoreError(
    code: .transport(.reset),
    severity: .error,
    retryDisposition: .backoff,
    cleanupDisposition: .completed
  )
  let transport = try MockTransport(
    inbound: [firstChunk],
    completion: .failure(terminalError)
  )
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()
  #expect(try await iterator.next() == firstChunk)

  do {
    _ = try await iterator.next()
    Issue.record("injected failure must not finish as success")
  } catch let error as CoreError {
    #expect(error == terminalError)
  } catch {
    Issue.record("injected failure must remain a CoreError")
  }
}

@Test func mockTransportInjectsCancellationDomainFailure() async throws {
  let cancellation = CoreError(
    code: .cancellation(.shutdown),
    severity: .notice,
    retryDisposition: .never,
    cleanupDisposition: .completed
  )
  let transport = try MockTransport(completion: .failure(cancellation))
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()

  do {
    _ = try await iterator.next()
    Issue.record("injected cancellation must not finish as success")
  } catch let error as CoreError {
    #expect(error.code == .cancellation(.shutdown))
    #expect(error.cleanupDisposition == .completed)
  } catch {
    Issue.record("injected cancellation must remain a CoreError")
  }
}

@Test func mockTransportFailsClosedOnBoundedBufferOverflow() async throws {
  let transport = try MockTransport(
    inbound: [firstChunk, secondChunk],
    completion: .endOfStream,
    incomingBufferLimit: 1
  )
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()

  #expect(try await iterator.next() == firstChunk)
  do {
    _ = try await iterator.next()
    Issue.record("overflow must terminate with a typed failure")
  } catch let error as CoreError {
    #expect(error.code == .transport(.resourceExhausted))
  } catch {
    Issue.record("overflow must remain a CoreError")
  }
}

@Test func mockTransportDisconnectIsIdempotentAndFinishesIncomingBytesOnce() async throws {
  let transport = try MockTransport(inbound: [firstChunk])
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()
  await transport.disconnect()
  await transport.disconnect()

  #expect(await transport.disconnectCount == 1)
  #expect(try await iterator.next() == firstChunk)
  #expect(try await iterator.next() == nil)
}

@Test func mockTransportCleanupCompletesInsideAnAlreadyCancelledTask() async throws {
  let transport = try MockTransport()
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()
  let cleanup = Task {
    withUnsafeCurrentTask { task in
      task?.cancel()
    }
    await transport.disconnect()
  }
  await cleanup.value

  #expect(await transport.disconnectCount == 1)
  #expect(try await iterator.next() == nil)
}
