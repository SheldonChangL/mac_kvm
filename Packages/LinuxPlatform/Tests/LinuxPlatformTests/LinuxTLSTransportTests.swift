#if os(Linux)
  import Crypto
  import Foundation
  import KVMContracts
  import LinuxPlatform
  import NIOCore
  import NIOPosix
  import NIOSSL
  import NIOTLS
  import Synchronization
  import Testing

  // M1-055-FOLLOWUP-001 tests. Each test runs an in-process NIOSSL server on 127.0.0.1 with an
  // ephemeral certificate that `openssl` creates in a temporary directory (a P-256 self-signed
  // certificate, or a P-256 leaf signed by an ephemeral CA, sent with its CA as a two-certificate
  // chain). No real host's certificate or fingerprint appears here. The optional loopback suite
  // runs only when `MACKVM_TLS_LOOPBACK_ENDPOINT` and `MACKVM_TLS_LOOPBACK_PIN` are set; it pins
  // a running Mac server identity whose fingerprint is passed at run time and never recorded.

  // MARK: - Ephemeral certificates

  struct TestIdentity {
    let chain: [NIOSSLCertificate]
    let key: NIOSSLPrivateKey

    /// SHA-256 of the leaf certificate's DER: the pin the transport must compute.
    var leafPin: Data {
      Data(SHA256.hash(data: try! chain[0].toDERBytes()))
    }

    /// SHA-256 over every presented certificate's DER, concatenated in order.
    var wholeChainDigest: Data {
      var hasher = SHA256()
      for certificate in chain { hasher.update(data: try! certificate.toDERBytes()) }
      return Data(hasher.finalize())
    }
  }

  enum Openssl {
    static func run(_ arguments: [String], in directory: URL) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
      process.arguments = arguments
      process.currentDirectoryURL = directory
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
    }

    static func temporaryDirectory() throws -> URL {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("m1-055-followup-001-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }

    /// A P-256 self-signed certificate, the shape of the Mac server identity.
    static func selfSigned() throws -> TestIdentity {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try run(
        [
          "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
          "-keyout", "key.pem", "-out", "cert.pem", "-days", "1", "-subj", "/CN=m1-055-test",
        ], in: directory)
      return try load(directory, certificates: ["cert.pem"])
    }

    /// A P-256 leaf signed by an ephemeral P-256 CA; the server presents `[leaf, ca]`.
    static func chained() throws -> TestIdentity {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try run(
        [
          "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
          "-keyout", "ca.key", "-out", "ca.pem", "-days", "1", "-subj", "/CN=m1-055-test-ca",
        ], in: directory)
      try run(
        [
          "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
          "-keyout", "key.pem", "-out", "leaf.csr", "-subj", "/CN=m1-055-test-leaf",
        ], in: directory)
      try run(
        [
          "x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
          "-CAcreateserial", "-out", "leaf.pem", "-days", "1",
        ], in: directory)
      return try load(directory, certificates: ["leaf.pem", "ca.pem"])
    }

    private static func load(_ directory: URL, certificates: [String]) throws -> TestIdentity {
      let chain = try certificates.flatMap {
        try NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent($0).path)
      }
      let key = try NIOSSLPrivateKey(
        file: directory.appendingPathComponent("key.pem").path, format: .pem)
      return TestIdentity(chain: chain, key: key)
    }
  }

  // MARK: - In-process server

  /// What the in-process server does once a TLS session is up.
  enum ServerScript: Sendable {
    /// Echo every received byte back.
    case echo
    /// Write `count` records of `size` bytes, each flushed on its own, then stay open.
    case flood(count: Int, size: Int)
    /// Write the bytes, then close the connection.
    case sendThenClose(Data)
    /// Write one large buffer, which NIOSSL sends as several TLS records.
    case bulk(Int)
    /// Write `count` bytes of the pattern `index % 251` in one buffer, then stay open.
    case pattern(Int)
    /// Write bytes that are not a TLS record straight to the socket.
    case garbageAfterHandshake
  }

  /// Sits in front of the TLS handler, so its writes reach the socket unencrypted.
  final class RawInjector: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    private var context: ChannelHandlerContext?
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func inject(_ bytes: [UInt8]) {
      guard let context else { return }
      context.writeAndFlush(NIOAny(context.channel.allocator.buffer(bytes: bytes)), promise: nil)
    }
  }

  final class ServerRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var received = Data()
    private var accepted = 0
    private var closed = 0
    private var handshakes = 0

    func add(_ data: Data) { lock.withLock { received.append(data) } }
    func didAccept() { lock.withLock { accepted += 1 } }
    func didClose() { lock.withLock { closed += 1 } }
    func didHandshake() { lock.withLock { handshakes += 1 } }
    var bytes: Data { lock.withLock { received } }
    var acceptedCount: Int { lock.withLock { accepted } }
    var closedCount: Int { lock.withLock { closed } }
    var handshakeCount: Int { lock.withLock { handshakes } }
  }

  final class ServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let script: ServerScript
    let record: ServerRecord
    let injector: RawInjector

    init(script: ServerScript, record: ServerRecord, injector: RawInjector) {
      self.script = script
      self.record = record
      self.injector = injector
    }

    func channelActive(context: ChannelHandlerContext) {
      record.didAccept()
      context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
      record.didClose()
      context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
      if case .handshakeCompleted = event as? TLSUserEvent {
        record.didHandshake()
        switch script {
        case .echo:
          break
        case .flood(let count, let size):
          for _ in 0..<count {
            let buffer = context.channel.allocator.buffer(repeating: 0x5A, count: size)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
          }
        case .sendThenClose(let data):
          let buffer = context.channel.allocator.buffer(bytes: data)
          context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
          context.close(promise: nil)
        case .bulk(let size):
          let buffer = context.channel.allocator.buffer(repeating: 0x33, count: size)
          context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        case .pattern(let size):
          let buffer = context.channel.allocator.buffer(bytes: patternBytes(size))
          context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        case .garbageAfterHandshake:
          injector.inject(Array(repeating: 0xEE, count: 64))
        }
      }
      context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let buffer = unwrapInboundIn(data)
      record.add(Data(buffer.readableBytesView))
      if case .echo = script {
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
      }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      context.close(promise: nil)
    }
  }

  /// Counts raw TCP connections and never speaks TLS: a peer that stalls the handshake.
  final class SilentHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let record: ServerRecord
    init(record: ServerRecord) { self.record = record }
    func channelActive(context: ChannelHandlerContext) { record.didAccept() }
    func channelInactive(context: ChannelHandlerContext) { record.didClose() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      record.add(Data(unwrapInboundIn(data).readableBytesView))
    }
  }

  struct TestServer {
    let channel: any Channel
    let record: ServerRecord
    var port: UInt16 { UInt16(channel.localAddress!.port!) }

    static func start(
      group: any EventLoopGroup,
      identity: TestIdentity?,
      script: ServerScript = .echo,
      maximumTLSVersion: TLSVersion? = nil
    ) async throws -> TestServer {
      let record = ServerRecord()
      var context: NIOSSLContext?
      if let identity {
        var configuration = TLSConfiguration.makeServerConfiguration(
          certificateChain: identity.chain.map { .certificate($0) },
          privateKey: .privateKey(identity.key))
        if let maximumTLSVersion {
          configuration.minimumTLSVersion = .tlsv1
          configuration.maximumTLSVersion = maximumTLSVersion
        }
        context = try NIOSSLContext(configuration: configuration)
      }
      let sslContext = context
      let channel = try await ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            if let sslContext {
              let injector = RawInjector()
              try channel.pipeline.syncOperations.addHandler(injector)
              try channel.pipeline.syncOperations.addHandler(
                NIOSSLServerHandler(context: sslContext))
              try channel.pipeline.syncOperations.addHandler(
                ServerHandler(script: script, record: record, injector: injector))
            } else {
              try channel.pipeline.syncOperations.addHandler(SilentHandler(record: record))
            }
          }
        }
        .bind(host: "127.0.0.1", port: 0).get()
      return TestServer(channel: channel, record: record)
    }

    func stop() async { try? await channel.close() }
  }

  // MARK: - Helpers

  /// `count` bytes whose value is the index modulo 251, so a drop or reorder shows.
  func patternBytes(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8($0 % 251) }
  }

  /// Records every digest the transport hands to the evaluator and answers with `decision`.
  final class EvaluatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [Data] = []
    private let decide: @Sendable (Data) -> LinuxTLSTrustDecision

    init(_ decide: @escaping @Sendable (Data) -> LinuxTLSTrustDecision) { self.decide = decide }

    var seen: [Data] { lock.withLock { digests } }

    var evaluator: @Sendable (Data) -> LinuxTLSTrustDecision {
      { [self] digest in
        lock.withLock { digests.append(digest) }
        return decide(digest)
      }
    }
  }

  func makeTransport(
    port: UInt16,
    group: any EventLoopGroup,
    timeout: Duration = .seconds(5),
    evaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision
  ) -> LinuxTLSTransport {
    LinuxTLSTransport(
      request: LinuxTLSConnectionRequest(host: "127.0.0.1", port: port, connectTimeout: timeout),
      group: group,
      trustEvaluator: evaluator)
  }

  func pinning(_ pin: Data) -> @Sendable (Data) -> LinuxTLSTrustDecision {
    { digest in
      guard digest.count == 32 else { return .reject(.trustRejected) }
      return digest == pin ? .accept : .reject(.identityChanged)
    }
  }

  func connectError(_ transport: LinuxTLSTransport) async -> CoreError? {
    do throws(CoreError) {
      try await transport.connect()
      return nil
    } catch {
      return error
    }
  }

  func waitUntil(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  /// Reads `count` bytes from the stream.
  func read(_ count: Int, from stream: AsyncThrowingStream<Data, any Error>) async throws -> Data {
    var collected = Data()
    for try await chunk in stream {
      collected.append(chunk)
      if collected.count >= count { break }
    }
    return collected
  }

  // MARK: - Suite

  @Suite("LinuxTLSTransport", .serialized, .timeLimit(.minutes(1)))
  struct LinuxTLSTransportTests {
    let group = MultiThreadedEventLoopGroup.singleton

    @Test("a matching pin connects and carries bytes both ways in order")
    func matchingPin() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      let probe = EvaluatorProbe(pinning(identity.leafPin))
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      try await transport.connect()
      #expect(await transport.isNoDelayEnabled())
      let message = Data((0..<4096).map { UInt8($0 % 251) })
      try await transport.send(message.prefix(1000))
      try await transport.send(Data())
      try await transport.send(message.dropFirst(1000))
      let echoed = try await read(message.count, from: transport.incomingBytes)
      #expect(echoed == message)
      #expect(server.record.bytes == message)
      #expect(probe.seen == [identity.leafPin])
      #expect(transport.presentedFingerprint == nil)
      await transport.disconnect()
      await server.stop()
    }

    @Test("the evaluator receives the SHA-256 of the leaf DER, not of the chain")
    func pinsTheLeaf() async throws {
      let identity = try Openssl.chained()
      #expect(identity.chain.count == 2)
      #expect(identity.leafPin != identity.wholeChainDigest)
      let server = try await TestServer.start(group: group, identity: identity)
      let probe = EvaluatorProbe(pinning(identity.leafPin))
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      try await transport.connect()
      #expect(probe.seen == [identity.leafPin])
      await transport.disconnect()
      await server.stop()
    }

    @Test("an unknown identity fails closed with identityUnknown and no application byte")
    func unknownIdentity() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      let probe = EvaluatorProbe { _ in .reject(.identityUnknown) }
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      let error = await connectError(transport)
      #expect(error?.code == .security(.identityUnknown))
      #expect(error?.retryDisposition == .userActionRequired)
      #expect(probe.seen.count == 1)
      #expect(transport.presentedFingerprint == identity.leafPin)
      #expect(server.record.handshakeCount == 0)
      #expect(server.record.bytes.isEmpty)
      await #expect(throws: CoreError.self) {
        for try await _ in transport.incomingBytes {}
      }
      do throws(CoreError) {
        try await transport.send(Data([1]))
        Issue.record("send after a rejected connect succeeded")
      } catch {
        #expect(error.code == .transport(.disconnected))
      }
      await waitUntil { server.record.closedCount == 1 }
      #expect(server.record.bytes.isEmpty)
      await server.stop()
    }

    @Test("a changed identity fails closed with identityChanged")
    func changedIdentity() async throws {
      let identity = try Openssl.selfSigned()
      let other = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      let probe = EvaluatorProbe(pinning(other.leafPin))
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      let error = await connectError(transport)
      #expect(error?.code == .security(.identityChanged))
      #expect(transport.presentedFingerprint == identity.leafPin)
      #expect(server.record.handshakeCount == 0)
      #expect(server.record.bytes.isEmpty)
      await server.stop()
    }

    @Test("a wrong digest length from the evaluator fails closed with trustRejected")
    func wrongDigestLength() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      // An evaluator that requires a 31-byte digest: the 32-byte digest is a wrong length for it.
      let probe = EvaluatorProbe { digest in
        digest.count == 31 ? .accept : .reject(.trustRejected)
      }
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      let error = await connectError(transport)
      #expect(error?.code == .security(.trustRejected))
      #expect(probe.seen.map(\.count) == [32])
      #expect(server.record.handshakeCount == 0)
      #expect(server.record.bytes.isEmpty)
      await server.stop()
    }

    @Test("a server limited to TLS 1.1 is refused and the evaluator is never asked")
    func tls11Refused() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(
        group: group, identity: identity, maximumTLSVersion: .tlsv11)
      let probe = EvaluatorProbe { _ in .accept }
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      let error = await connectError(transport)
      #expect(error?.code == .security(.trustRejected))
      #expect(probe.seen.isEmpty)
      #expect(server.record.handshakeCount == 0)
      await server.stop()
    }

    @Test("the end of the server's stream finishes the incoming bytes once, after the data")
    func endOfStream() async throws {
      let identity = try Openssl.selfSigned()
      let payload = Data("last words".utf8)
      let server = try await TestServer.start(
        group: group, identity: identity, script: .sendThenClose(payload))
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      try await transport.connect()
      var received = Data()
      for try await chunk in transport.incomingBytes { received.append(chunk) }
      #expect(received == payload)
      var iterator = transport.incomingBytes.makeAsyncIterator()
      #expect(try await iterator.next() == nil)
      do throws(CoreError) {
        try await transport.send(Data([1]))
        Issue.record("send after the end of the stream succeeded")
      } catch {
        #expect(error.code == .transport(.disconnected))
      }
      await transport.disconnect()
      await server.stop()
    }

    @Test("M1-055-FOLLOWUP-002: a slow consumer receives a 1 MiB payload in order, unended")
    func slowConsumerLargePayload() async throws {
      let identity = try Openssl.selfSigned()
      let size = 1 << 20
      let server = try await TestServer.start(
        group: group, identity: identity, script: .pattern(size))
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      try await transport.connect()
      // The consumer is stalled while the server writes everything it can.
      try await Task.sleep(for: .milliseconds(500))
      var received = Data()
      for try await chunk in transport.incomingBytes {
        received.append(chunk)
        if received.count >= size { break }
        try await Task.sleep(for: .microseconds(200))
      }
      #expect(received.count == size)
      #expect(received == Data(patternBytes(size)))
      // The connection is still usable after the payload.
      try await transport.send(Data([7]))
      await waitUntil { server.record.bytes == Data([7]) }
      #expect(server.record.bytes == Data([7]))
      await transport.disconnect()
      await server.stop()
    }

    @Test("M1-055-FOLLOWUP-002: a stalled consumer holds socket reads; queued bytes stay bounded")
    func stalledConsumerIsBounded() async throws {
      let identity = try Openssl.selfSigned()
      let size = 4 << 20
      let server = try await TestServer.start(
        group: group, identity: identity, script: .pattern(size))
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      try await transport.connect()
      await waitUntil { transport.bufferedByteCount >= LinuxTLSTransport.inboundHighWaterBytes }
      try await Task.sleep(for: .milliseconds(500))
      // Paused: far less than the 4 MiB on the wire is queued, and the session is alive.
      #expect(transport.bufferedByteCount >= LinuxTLSTransport.inboundHighWaterBytes)
      #expect(transport.peakBufferedByteCount < LinuxTLSTransport.maximumBufferedBytes)
      #expect(transport.peakBufferedByteCount < size / 4)
      #expect(
        transport.peakBufferedByteCount <= LinuxTLSTransport.inboundHighWaterBytes + 512 * 1024)

      var received = Data()
      for try await chunk in transport.incomingBytes {
        received.append(chunk)
        if received.count >= size { break }
      }
      #expect(received == Data(patternBytes(size)))
      #expect(transport.peakBufferedByteCount < LinuxTLSTransport.maximumBufferedBytes)
      await transport.disconnect()
      await server.stop()
    }

    @Test("M1-055-FOLLOWUP-002: the flow-control limits keep their values")
    func flowControlLimits() {
      #expect(LinuxTLSTransport.inboundHighWaterBytes == 256 * 1024)
      #expect(LinuxTLSTransport.inboundLowWaterBytes == 64 * 1024)
      #expect(LinuxTLSTransport.maximumBufferedBytes == 1024 * 1024)
    }

    @Test("a large read is yielded in chunks of at most 16 KiB, in order")
    func chunkBound() async throws {
      let identity = try Openssl.selfSigned()
      let size = 200_000
      let server = try await TestServer.start(group: group, identity: identity, script: .bulk(size))
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      try await transport.connect()
      var total = 0
      var largest = 0
      for try await chunk in transport.incomingBytes {
        #expect(chunk.allSatisfy { $0 == 0x33 })
        largest = max(largest, chunk.count)
        total += chunk.count
        if total >= size { break }
      }
      #expect(total == size)
      #expect(largest <= LinuxTLSTransport.maximumChunkLength)
      #expect(LinuxTLSTransport.maximumChunkLength == 16_384)
      await transport.disconnect()
      await server.stop()
    }

    @Test("a TLS error after the handshake ends the stream with reset and back-off")
    func tlsErrorAfterHandshake() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(
        group: group, identity: identity, script: .garbageAfterHandshake)
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      try await transport.connect()
      do {
        for try await _ in transport.incomingBytes {}
        Issue.record("the stream finished without an error")
      } catch let error as CoreError {
        #expect(error.code == .transport(.reset))
        #expect(error.retryDisposition == .backoff)
      }
      await transport.disconnect()
      await server.stop()
    }

    @Test("send before connect is a precondition failure and sends nothing")
    func sendBeforeConnect() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      do throws(CoreError) {
        try await transport.send(Data([1, 2, 3]))
        Issue.record("send before connect succeeded")
      } catch {
        #expect(error.code == .internalFailure(.preconditionFailed))
      }
      #expect(server.record.acceptedCount == 0)
      await transport.disconnect()
      await server.stop()
    }

    @Test("a second connect is refused: the instance is single-use")
    func singleUse() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      let probe = EvaluatorProbe(pinning(identity.leafPin))
      let transport = makeTransport(port: server.port, group: group, evaluator: probe.evaluator)

      try await transport.connect()
      let second = await connectError(transport)
      #expect(second?.code == .internalFailure(.preconditionFailed))
      await transport.disconnect()
      let third = await connectError(transport)
      #expect(third?.code == .internalFailure(.preconditionFailed))
      #expect(probe.seen.count == 1)
      #expect(server.record.acceptedCount == 1)
      await server.stop()
    }

    @Test("cancelling the task during connect fails with cancellation and closes the socket")
    func cancelDuringConnect() async throws {
      let server = try await TestServer.start(group: group, identity: nil)
      let probe = EvaluatorProbe { _ in .accept }
      let transport = makeTransport(
        port: server.port, group: group, timeout: .seconds(30), evaluator: probe.evaluator)

      let task = Task { await connectError(transport) }
      await waitUntil { server.record.acceptedCount == 1 }
      #expect(server.record.acceptedCount == 1)
      let started = ContinuousClock.now
      task.cancel()
      let error = await task.value
      #expect(error?.code == .cancellation(.requested))
      #expect(ContinuousClock.now - started < .seconds(5))
      await waitUntil { server.record.closedCount == 1 }
      #expect(server.record.closedCount == 1)
      #expect(probe.seen.isEmpty)
      await #expect(throws: CoreError.self) {
        for try await _ in transport.incomingBytes {}
      }
      await server.stop()
    }

    @Test("disconnect during connect ends the connect and is bounded")
    func disconnectDuringConnect() async throws {
      let server = try await TestServer.start(group: group, identity: nil)
      let transport = makeTransport(
        port: server.port, group: group, timeout: .seconds(30), evaluator: { _ in .accept })

      let task = Task { await connectError(transport) }
      await waitUntil { server.record.acceptedCount == 1 }
      await transport.disconnect()
      let error = await task.value
      #expect(error?.code == .cancellation(.requested))
      await waitUntil { server.record.closedCount == 1 }
      #expect(server.record.closedCount == 1)
      await server.stop()
    }

    @Test("a handshake that never completes times out")
    func handshakeTimeout() async throws {
      let server = try await TestServer.start(group: group, identity: nil)
      let transport = makeTransport(
        port: server.port, group: group, timeout: .milliseconds(300), evaluator: { _ in .accept })

      let started = ContinuousClock.now
      let error = await connectError(transport)
      #expect(error?.code == .timeout(.connect))
      #expect(ContinuousClock.now - started < .seconds(5))
      await waitUntil { server.record.closedCount == 1 }
      #expect(server.record.closedCount == 1)
      await server.stop()
    }

    @Test("a refused TCP connection maps to transport refused")
    func refused() async throws {
      let server = try await TestServer.start(group: group, identity: nil)
      let port = server.port
      await server.stop()
      let transport = makeTransport(port: port, group: group, evaluator: { _ in .accept })
      let error = await connectError(transport)
      #expect(error?.code == .transport(.refused))
    }

    @Test("disconnect twice is idempotent and finishes the stream once, normally")
    func disconnectTwice() async throws {
      let identity = try Openssl.selfSigned()
      let server = try await TestServer.start(group: group, identity: identity)
      let transport = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))

      try await transport.connect()
      await transport.disconnect()
      await transport.disconnect()
      var chunks = 0
      for try await _ in transport.incomingBytes { chunks += 1 }
      #expect(chunks == 0)
      await waitUntil { server.record.closedCount == 1 }
      #expect(server.record.closedCount == 1)

      // Bounded even when the calling task is already cancelled.
      let other = makeTransport(
        port: server.port, group: group, evaluator: pinning(identity.leafPin))
      try await other.connect()
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await other.disconnect()
      }
      await cancelled.value
      for try await _ in other.incomingBytes {}
      await waitUntil { server.record.closedCount == 2 }
      #expect(server.record.closedCount == 2)
      await server.stop()
    }

    @Test("the connection request keeps its fields")
    func requestFields() {
      let request = LinuxTLSConnectionRequest(host: "h", port: 24800, connectTimeout: .seconds(3))
      #expect(request.host == "h")
      #expect(request.port == 24800)
      #expect(request.connectTimeout == .seconds(3))
    }
  }

  // MARK: - Optional loopback run against a running Mac server identity

  @Suite(
    "LinuxTLSTransport against a Mac server identity",
    .enabled(if: ProcessInfo.processInfo.environment["MACKVM_TLS_LOOPBACK_ENDPOINT"] != nil),
    .timeLimit(.minutes(1)))
  struct LinuxTLSTransportLoopbackTests {
    let group = MultiThreadedEventLoopGroup.singleton

    private var endpoint: (host: String, port: UInt16, pin: Data)? {
      let environment = ProcessInfo.processInfo.environment
      guard let value = environment["MACKVM_TLS_LOOPBACK_ENDPOINT"],
        let hex = environment["MACKVM_TLS_LOOPBACK_PIN"], hex.count == 64,
        let separator = value.lastIndex(of: ":"),
        let port = UInt16(value[value.index(after: separator)...])
      else { return nil }
      var pin = Data()
      var index = hex.startIndex
      while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        pin.append(byte)
        index = next
      }
      return (String(value[..<separator]), port, pin)
    }

    @Test("the pinned Mac server identity is accepted and a different pin is rejected")
    func macIdentity() async throws {
      let endpoint = try #require(endpoint)
      let request = LinuxTLSConnectionRequest(
        host: endpoint.host, port: endpoint.port, connectTimeout: .seconds(5))
      let probe = EvaluatorProbe(pinning(endpoint.pin))
      let accepted = LinuxTLSTransport(
        request: request, group: group, trustEvaluator: probe.evaluator)
      try await accepted.connect()
      #expect(probe.seen == [endpoint.pin])
      await accepted.disconnect()

      var wrong = endpoint.pin
      wrong[0] ^= 0xFF
      let rejected = LinuxTLSTransport(
        request: request, group: group, trustEvaluator: pinning(wrong))
      let error = await connectError(rejected)
      #expect(error?.code == .security(.identityChanged))
      #expect(rejected.presentedFingerprint == endpoint.pin)
    }
  }
#endif
