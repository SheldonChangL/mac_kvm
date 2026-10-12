// Byte-stream frame reassembler for the Barrier protocol adapter.
// Applies the frame envelope from docs/adr/M1-025-barrier-client-wire-contract.md (a
// 4-byte unsigned big-endian length prefix followed by exactly that many payload bytes)
// to the complete ordered byte stream, so frames split across or coalesced within
// appended chunks are both handled. The payload limit is a caller-supplied product safety
// bound, not an observed Barrier compatibility limit. Payloads are returned opaque;
// message codes and payload layouts are out of scope.

/// Typed reassembly failure. Carries only counts and limits, never stream bytes.
enum BarrierFrameReassemblerError: Error, Equatable, Sendable {
  /// The caller-supplied maximum payload length is negative.
  case invalidMaximumPayloadLength
  /// A length prefix declares more payload bytes than the caller-supplied limit.
  case oversize(limit: Int)
  /// The stream ended after `received` (1...3) bytes of a length prefix.
  case truncatedPrefix(received: Int)
  /// The stream ended after `received` of `expected` payload bytes. Both counts exclude
  /// the 4-byte prefix.
  case truncatedPayload(expected: Int, received: Int)
  /// Bytes were appended after a successful `finish()`.
  case appendAfterFinish
}

/// Reassembles length-prefixed frames from arbitrarily chunked stream bytes.
///
/// `append(_:)` parses eagerly: every frame completed by the new bytes is queued for
/// `nextPayload()`, and only the current incomplete frame stays buffered. A prefix above
/// the limit fails before any of its payload is buffered. Failures are sticky: the partial
/// frame is discarded, later `append(_:)` and `finish()` calls rethrow the same error, and
/// `nextPayload()` rethrows it once every frame completed before the failure is drained.
struct BarrierFrameReassembler: Sendable {
  private enum State: Sendable {
    case open
    case finished
    case failed(BarrierFrameReassemblerError)
  }

  let maximumPayloadLength: Int
  private var state = State.open
  private var prefix: [UInt8] = []
  /// Declared payload length of the current frame once its prefix is complete.
  private var payloadLength: Int?
  private var payload: [UInt8] = []
  private var readyPayloads: [[UInt8]] = []
  private var readyIndex = 0

  init(maximumPayloadLength: Int) throws(BarrierFrameReassemblerError) {
    guard maximumPayloadLength >= 0 else { throw .invalidMaximumPayloadLength }
    self.maximumPayloadLength = maximumPayloadLength
  }

  /// Bytes of the current incomplete frame, prefix included.
  var pendingByteCount: Int { prefix.count + payload.count }

  mutating func append(_ bytes: [UInt8]) throws(BarrierFrameReassemblerError) {
    switch state {
    case .open:
      break
    case .finished:
      throw .appendAfterFinish
    case .failed(let error):
      throw error
    }
    var index = bytes.startIndex
    while index < bytes.endIndex {
      if let length = payloadLength {
        let end = index + min(length - payload.count, bytes.endIndex - index)
        payload.append(contentsOf: bytes[index..<end])
        index = end
        if payload.count == length { completeFrame() }
      } else {
        let end = index + min(4 - prefix.count, bytes.endIndex - index)
        prefix.append(contentsOf: bytes[index..<end])
        index = end
        if prefix.count == 4 { try beginPayload() }
      }
    }
  }

  /// Returns the oldest completed payload, or `nil` when none is ready. After a failure,
  /// throws that failure once earlier completed payloads are drained.
  mutating func nextPayload() throws(BarrierFrameReassemblerError) -> [UInt8]? {
    guard readyIndex < readyPayloads.count else {
      if case .failed(let error) = state { throw error }
      return nil
    }
    let next = readyPayloads[readyIndex]
    readyPayloads[readyIndex] = []
    readyIndex += 1
    // Compact once half the queue is consumed, so a consumer that stays behind by a frame
    // cannot leave consumed slots accumulating on a long-lived stream.
    if readyIndex * 2 >= readyPayloads.count {
      readyPayloads.removeFirst(readyIndex)
      readyIndex = 0
    }
    return next
  }

  /// Marks end of stream. Throws a truncation error if a frame is incomplete; repeated
  /// calls return the same outcome.
  mutating func finish() throws(BarrierFrameReassemblerError) {
    switch state {
    case .open:
      break
    case .finished:
      return
    case .failed(let error):
      throw error
    }
    if let length = payloadLength {
      try fail(.truncatedPayload(expected: length, received: payload.count))
    } else if !prefix.isEmpty {
      try fail(.truncatedPrefix(received: prefix.count))
    }
    state = .finished
  }

  private mutating func beginPayload() throws(BarrierFrameReassemblerError) {
    let declared = prefix.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    // Int(exactly:) fails only where Int is 32 bits; such a prefix exceeds any Int limit.
    guard let length = Int(exactly: declared), length <= maximumPayloadLength else {
      try fail(.oversize(limit: maximumPayloadLength))
    }
    payloadLength = length
    if length == 0 { completeFrame() }
  }

  private mutating func completeFrame() {
    readyPayloads.append(payload)
    prefix = []
    payloadLength = nil
    payload = []
  }

  /// Latches `error`, discards the incomplete frame and throws.
  private mutating func fail(
    _ error: BarrierFrameReassemblerError
  ) throws(BarrierFrameReassemblerError) -> Never {
    state = .failed(error)
    prefix = []
    payloadLength = nil
    payload = []
    throw error
  }
}
