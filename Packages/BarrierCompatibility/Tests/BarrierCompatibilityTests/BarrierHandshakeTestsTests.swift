import Testing
@testable import BarrierCompatibility

// M1-030: fragmentation, timeout and version-mismatch coverage for the M1-029
// BarrierClientHandshake driven through the M1-022 BarrierFrameReassembler, the way the
// transport owner hands bytes to the handshake. Timeout and cancellation are the
// handshake's caller-injected signals, so no clock, sleep, retry or task is involved.

private typealias HandshakeError = BarrierClientHandshakeError

// Golden server hello: BARRIER-EVID-0002 run 0, frozen by
// docs/adr/M1-025-barrier-client-wire-contract.md (the bytes used by M1-027 and M1-029).
// Golden HelloBack: BARRIER-EVID-0004 attempt 0 (`m1-client`), frozen by
// docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md (the bytes used by M1-028 and
// M1-029). Copied by hand; if that evidence is superseded, update these bytes from the
// superseding artifact.
private let helloPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let helloFrame: [UInt8] = [0x00, 0x00, 0x00, 0x0B] + helloPayload
private let helloBackFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x18, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00,
  0x06, 0x00, 0x00, 0x00, 0x09, 0x6D, 0x31, 0x2D, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74,
]
/// Offsets of the four version bytes inside the hello frame (4-byte prefix + 7-byte marker).
private let versionFrameOffsets = 11..<15

private func makeStartedHandshake(screenName: String = "m1-client") throws
  -> BarrierClientHandshake
{
  var handshake = BarrierClientHandshake(
    screenName: screenName,
    helloBackWriter: try BarrierClientHelloBackWriter(maximumScreenNameByteCount: 64))
  try handshake.start()
  return handshake
}

/// Splits `bytes` before every index in `boundaries`, which are ascending in
/// `1..<bytes.count`.
private func split(_ bytes: [UInt8], at boundaries: [Int]) -> [[UInt8]] {
  var chunks: [[UInt8]] = []
  var start = 0
  for end in boundaries + [bytes.count] {
    chunks.append(Array(bytes[start..<end]))
    start = end
  }
  return chunks
}

/// Appends `chunk` and hands every payload it completes to `handshake`, as the transport
/// owner would. Returns the frames the handshake asked the caller to write and the
/// handshake errors, in order.
private func deliver(
  _ chunk: [UInt8], to reassembler: inout BarrierFrameReassembler,
  handshake: inout BarrierClientHandshake
) throws -> (frames: [[UInt8]], errors: [HandshakeError]) {
  var frames: [[UInt8]] = []
  var errors: [HandshakeError] = []
  try reassembler.append(chunk)
  while let payload = try reassembler.nextPayload() {
    do throws(HandshakeError) {
      frames.append(try handshake.receiveServerHello(payload: payload))
    } catch {
      errors.append(error)
    }
  }
  return (frames, errors)
}

/// True when `value`, or any value-type node reachable from it, is a string or a class
/// instance. Class instances end the walk without being traversed, so reference cycles
/// cannot recurse.
private func reflectedGraphContainsStringOrReference(_ value: Any) -> Bool {
  if value is String { return true }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .class { return true }
  return mirror.children.contains { reflectedGraphContainsStringOrReference($0.value) }
}

/// True when the handshake still stores a string (the screen name) or any reference-typed
/// value that could keep a resource alive.
private func retainsStringOrReference(_ handshake: BarrierClientHandshake) -> Bool {
  reflectedGraphContainsStringOrReference(handshake)
}

// MARK: - Happy path through every fragmentation

@Test func fragmentedHelloCompletesTheHandshakeForEverySplitOfTheFrame() throws {
  // A 15-byte frame has 14 inner byte boundaries. Every subset of them is one way the
  // stream can fragment the hello, from a single chunk (no split) to one-byte chunks (every
  // split): 2^14 = 16384 fragmentations, all exercised.
  let boundaryCount = helloFrame.count - 1
  var fragmentations = 0
  for mask in 0..<(1 << boundaryCount) {
    let boundaries = (1...boundaryCount).filter { mask & (1 << ($0 - 1)) != 0 }
    let chunks = split(helloFrame, at: boundaries)
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    var handshake = try makeStartedHandshake()
    for chunk in chunks.dropLast() {
      let delivered = try deliver(chunk, to: &reassembler, handshake: &handshake)
      #expect(delivered.frames.isEmpty && delivered.errors.isEmpty)
      #expect(handshake.state == .awaitHello)
    }
    let delivered = try deliver(chunks[chunks.count - 1], to: &reassembler, handshake: &handshake)
    #expect(delivered.frames == [helloBackFrame])
    #expect(delivered.errors.isEmpty)
    #expect(handshake.state == .sendHelloBack)
    #expect(reassembler.pendingByteCount == 0)
    try handshake.helloBackSent()
    #expect(handshake.state == .protocolConnected)
    fragmentations += 1
  }
  #expect(fragmentations == 16384)
}

@Test func oneByteChunksWithEmptyAppendsKeepTheHandshakeWaitingUntilTheLastByte() throws {
  // One-byte chunks are the finest fragmentation; empty appends between them are a
  // zero-length boundary the transport may also produce.
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var handshake = try makeStartedHandshake()
  var frames: [[UInt8]] = []
  for (index, byte) in helloFrame.enumerated() {
    let empty = try deliver([], to: &reassembler, handshake: &handshake)
    #expect(empty.frames.isEmpty && empty.errors.isEmpty)
    let delivered = try deliver([byte], to: &reassembler, handshake: &handshake)
    #expect(delivered.errors.isEmpty)
    frames += delivered.frames
    if index < helloFrame.count - 1 {
      #expect(frames.isEmpty)
      #expect(handshake.state == .awaitHello)
      #expect(reassembler.pendingByteCount == index + 1)
    }
  }
  #expect(frames == [helloBackFrame])
  try handshake.helloBackSent()
  #expect(handshake.state == .protocolConnected)
}

// MARK: - Boundary

@Test func helloAtExactlyThePayloadLimitCompletesAndOneBelowNeverReachesTheHandshake() throws {
  var atLimit = try BarrierFrameReassembler(maximumPayloadLength: helloPayload.count)
  var accepted = try makeStartedHandshake()
  let delivered = try deliver(helloFrame, to: &atLimit, handshake: &accepted)
  #expect(delivered.frames == [helloBackFrame])

  // One byte below the hello length, the reassembler rejects the prefix before buffering
  // the payload; the handshake receives nothing and ends only through the timeout signal.
  var belowLimit = try BarrierFrameReassembler(maximumPayloadLength: helloPayload.count - 1)
  var waiting = try makeStartedHandshake()
  #expect(throws: BarrierFrameReassemblerError.oversize(limit: helloPayload.count - 1)) {
    _ = try deliver(helloFrame, to: &belowLimit, handshake: &waiting)
  }
  #expect(waiting.state == .awaitHello)
  waiting.timeOut()
  #expect(waiting.state == .failed(.timedOut))
}

// MARK: - Unsupported version

@Test func unsupportedVersionFailsWithTheFixedErrorAtEveryFragmentationBoundary() throws {
  // Every single-byte change of every version byte, delivered as two chunks split at every
  // inner boundary of the frame: 4 * 255 * 14 = 14280 runs.
  let expected = HandshakeError.serverHelloRejected(.unsupportedVersion)
  var runs = 0
  for offset in versionFrameOffsets {
    for value in UInt8.min...UInt8.max where value != helloFrame[offset] {
      var frame = helloFrame
      frame[offset] = value
      for boundary in 1..<frame.count {
        var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
        var handshake = try makeStartedHandshake()
        var errors: [HandshakeError] = []
        var frames: [[UInt8]] = []
        for chunk in split(frame, at: [boundary]) {
          let delivered = try deliver(chunk, to: &reassembler, handshake: &handshake)
          errors += delivered.errors
          frames += delivered.frames
        }
        #expect(errors == [expected])
        #expect(frames.isEmpty)
        #expect(handshake.state == .failed(expected))
        runs += 1
      }
    }
  }
  #expect(runs == 14280)
}

@Test func unsupportedMultiByteVersionsFailWithTheSameFixedError() throws {
  // Neighbouring and extreme versions that change more than one byte; no negotiation,
  // downgrade or fallback is attempted for any of them.
  let versions: [[UInt8]] = [
    [0x00, 0x01, 0x00, 0x05], [0x00, 0x01, 0x00, 0x07], [0x00, 0x02, 0x00, 0x06],
    [0x00, 0x00, 0x00, 0x06], [0x00, 0x00, 0x00, 0x00], [0xFF, 0xFF, 0xFF, 0xFF],
    [0x06, 0x00, 0x01, 0x00],
  ]
  let expected = HandshakeError.serverHelloRejected(.unsupportedVersion)
  for version in versions {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    var handshake = try makeStartedHandshake()
    let frame = Array(helloFrame[..<versionFrameOffsets.lowerBound]) + version
    let delivered = try deliver(frame, to: &reassembler, handshake: &handshake)
    #expect(delivered.errors == [expected])
    #expect(delivered.frames.isEmpty)
  }
  // The fixed error carries no version bytes or any other associated value.
  #expect(Mirror(reflecting: BarrierServerHelloError.unsupportedVersion).children.isEmpty)
}

@Test func unsupportedVersionDoesNotProceedForAnyLaterEvent() throws {
  // The rejection is reported even with a screen name the writer would also reject, a later
  // supported hello cannot revive the handshake, and no HelloBack is ever composed.
  let expected = HandshakeError.serverHelloRejected(.unsupportedVersion)
  var frame = helloFrame
  frame[versionFrameOffsets.upperBound - 1] = 0x07
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var handshake = try makeStartedHandshake(screenName: "")
  let rejected = try deliver(frame, to: &reassembler, handshake: &handshake)
  #expect(rejected.errors == [expected])
  let retried = try deliver(helloFrame, to: &reassembler, handshake: &handshake)
  #expect(retried.errors == [expected])
  #expect(retried.frames.isEmpty)
  #expect(throws: expected) { try handshake.helloBackSent() }
  handshake.timeOut()
  handshake.cancel()
  #expect(handshake.state == .failed(expected))
}

// MARK: - Timeout and cancellation at every byte boundary

@Test func timeoutAtEveryByteBoundaryEndsWithTimedOutAndNoLaterOutput() throws {
  // The caller's timeout signal arrives after `delivered` frame bytes (0 through 14), then
  // the rest of the frame arrives late. The completed payload must not produce a HelloBack.
  for delivered in 0..<helloFrame.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    var handshake = try makeStartedHandshake()
    for byte in helloFrame[..<delivered] {
      _ = try deliver([byte], to: &reassembler, handshake: &handshake)
    }
    #expect(handshake.state == .awaitHello)
    handshake.timeOut()
    handshake.timeOut()
    handshake.cancel()
    #expect(handshake.state == .failed(.timedOut))
    let late = try deliver(
      Array(helloFrame[delivered...]), to: &reassembler, handshake: &handshake)
    #expect(late.frames.isEmpty)
    #expect(late.errors == [.timedOut])
    #expect(throws: HandshakeError.timedOut) { try handshake.helloBackSent() }
    #expect(throws: HandshakeError.timedOut) { try handshake.start() }
    #expect(handshake.state == .failed(.timedOut))
  }
}

@Test func timeoutAfterTheHelloButBeforeHelloBackIsSentNeverConnects() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var handshake = try makeStartedHandshake()
  let delivered = try deliver(helloFrame, to: &reassembler, handshake: &handshake)
  #expect(delivered.frames == [helloBackFrame])
  handshake.timeOut()
  #expect(handshake.state == .failed(.timedOut))
  #expect(throws: HandshakeError.timedOut) { try handshake.helloBackSent() }
  #expect(handshake.state == .failed(.timedOut))
}

@Test func cancelAtEveryByteBoundaryEndsWithCancelledAndNoLaterOutput() throws {
  for delivered in 0...helloFrame.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    var handshake = try makeStartedHandshake()
    _ = try deliver(Array(helloFrame[..<delivered]), to: &reassembler, handshake: &handshake)
    handshake.cancel()
    handshake.cancel()
    handshake.timeOut()
    #expect(handshake.state == .failed(.cancelled))
    let late = try deliver(
      Array(helloFrame[delivered...]), to: &reassembler, handshake: &handshake)
    #expect(late.frames.isEmpty)
    #expect(late.errors == (delivered < helloFrame.count ? [.cancelled] : []))
    #expect(throws: HandshakeError.cancelled) { try handshake.helloBackSent() }
    #expect(handshake.state == .failed(.cancelled))
  }
}

// MARK: - Cleanup

@Test func timeoutAndCancelLeaveNoRetainedStringOrReferenceAtAnyByteBoundary() throws {
  // Positive control: a waiting handshake still holds its screen name, so the check can
  // detect retention.
  #expect(retainsStringOrReference(try makeStartedHandshake()))
  for delivered in 0..<helloFrame.count {
    for terminate in [true, false] {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
      var handshake = try makeStartedHandshake()
      _ = try deliver(Array(helloFrame[..<delivered]), to: &reassembler, handshake: &handshake)
      if terminate { handshake.timeOut() } else { handshake.cancel() }
      #expect(!retainsStringOrReference(handshake))
    }
  }
}

@Test func lateTimeoutAfterAFragmentedHandshakeCompletesKeepsProtocolConnected() throws {
  // After completion the handshake owns nothing; session teardown belongs to its owner.
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var handshake = try makeStartedHandshake()
  var frames: [[UInt8]] = []
  for chunk in split(helloFrame, at: [4, 11]) {
    frames += try deliver(chunk, to: &reassembler, handshake: &handshake).frames
  }
  #expect(frames == [helloBackFrame])
  try handshake.helloBackSent()
  handshake.timeOut()
  handshake.cancel()
  #expect(handshake.state == .protocolConnected)
  #expect(!retainsStringOrReference(handshake))
}
