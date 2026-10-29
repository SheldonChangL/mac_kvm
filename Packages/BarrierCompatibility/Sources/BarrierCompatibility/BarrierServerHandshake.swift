// Server-role handshake for the Barrier protocol adapter (M2-025).
// Writes and reads only the byte sequences listed in the proposed
// docs/adr/M2-023-barrier-server-wire-contract.md, which reuses the accepted
// BARRIER-EVID-0004/0005 contracts (M1-PROTOCOL-001, M1-PROTOCOL-002) for the
// server role. Progression: idle -> awaitingHelloBack -> awaitingScreenInfo ->
// ready. The caller owns the transport, the frame reassembler and the clock and
// injects timeout and cancellation as signals; no I/O, timer or sleep lives here.

/// Typed server handshake failure. Carries no screen-name or payload bytes.
enum BarrierServerHandshakeError: Error, Equatable, Sendable {
  /// The expected-name set or name bound is invalid.
  case invalidConfiguration
  /// The HelloBack payload is truncated or its declared name length does not
  /// match the payload.
  case malformedHelloBack
  /// The HelloBack marker is not `Barrier`.
  case unsupportedMarker
  /// The HelloBack version is not the supported `00 01 00 06`.
  case unsupportedVersion
  /// The client screen name is empty, too long or not an ASCII identifier.
  case invalidScreenName
  /// The client screen name is valid but not one the server expects.
  case unknownClientScreen
  /// The `DINF` frame was rejected by the M1-031 decoder rules.
  case screenInfoRejected(BarrierControlMessageError)
  /// A frame other than the one this step requires arrived.
  case unexpectedFrame
  /// The caller's timeout signal arrived before the handshake completed.
  case timedOut
  /// The caller cancelled the handshake before it completed.
  case cancelled
  /// An event arrived in a state that does not accept it.
  case outOfOrderEvent
  /// An event arrived after the handshake completed. The ready state is kept.
  case alreadyReady
}

/// Deterministic Barrier server handshake.
///
/// `start()` returns the hello frame. `receive(payload:)` takes one complete
/// reassembled payload and returns the frames the caller must write next:
/// `QINF` after a valid, expected HelloBack, then `CIAK`, `CROP` and a zero
/// `DSOP` after a valid `DINF`, which moves to `ready`.
///
/// Failures are terminal and sticky. The client screen name is held only
/// after it matched the expected set and is released on any failure. String
/// conversion and reflection are redacted.
struct BarrierServerHandshake: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  enum State: Equatable, Sendable {
    case idle
    case awaitingHelloBack
    case awaitingScreenInfo
    case ready(BarrierScreenInfo)
    case failed(BarrierServerHandshakeError)
  }

  /// Largest accepted client screen-name bound.
  static let largestMaximumScreenNameByteCount = 255

  private static let marker: [UInt8] = Array("Barrier".utf8)
  private static let version: [UInt8] = [0x00, 0x01, 0x00, 0x06]
  private static let decoderPayloadLimit = 64

  private(set) var state = State.idle
  private(set) var clientScreenName: String?
  private let expectedScreenNames: Set<String>
  private let maximumScreenNameByteCount: Int
  private var decoder: BarrierControlDecoder

  init(expectedScreenNames: Set<String>, maximumScreenNameByteCount: Int)
    throws(BarrierServerHandshakeError)
  {
    guard !expectedScreenNames.isEmpty,
      (1...Self.largestMaximumScreenNameByteCount).contains(maximumScreenNameByteCount),
      expectedScreenNames.allSatisfy({
        Self.isValidName(Array($0.utf8), limit: maximumScreenNameByteCount)
      })
    else { throw .invalidConfiguration }
    do throws(BarrierControlMessageError) {
      decoder = try BarrierControlDecoder(maximumPayloadLength: Self.decoderPayloadLimit)
    } catch {
      throw .invalidConfiguration
    }
    self.expectedScreenNames = expectedScreenNames
    self.maximumScreenNameByteCount = maximumScreenNameByteCount
  }

  /// Returns the server hello frame and waits for the HelloBack.
  mutating func start() throws(BarrierServerHandshakeError) -> [UInt8] {
    try expect(.idle)
    state = .awaitingHelloBack
    return Self.frame(Self.marker + Self.version)
  }

  /// Processes one complete client payload and returns the frames to write.
  mutating func receive(payload: [UInt8]) throws(BarrierServerHandshakeError) -> [UInt8] {
    switch state {
    case .awaitingHelloBack:
      try acceptHelloBack(payload)
      state = .awaitingScreenInfo
      return Self.tokenFrame(.qinf)
    case .awaitingScreenInfo:
      let screen = try acceptScreenInfo(payload)
      state = .ready(screen)
      return Self.tokenFrame(.ciak) + Self.tokenFrame(.crop)
        + Self.frame(BarrierControlToken.dsop.bytes + [0, 0, 0, 0])
    default:
      try expect(.awaitingHelloBack)
      return []
    }
  }

  /// Injected timeout signal. Terminal before `ready`; ignored afterwards.
  mutating func timeOut() {
    terminate(.timedOut)
  }

  /// Injected cancellation. Terminal before `ready`; ignored afterwards.
  mutating func cancel() {
    terminate(.cancelled)
  }

  var description: String { "BarrierServerHandshake(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

  private mutating func acceptHelloBack(_ payload: [UInt8]) throws(BarrierServerHandshakeError) {
    let fixed = Self.marker.count + Self.version.count + 4
    guard payload.count >= Self.marker.count else { try fail(.malformedHelloBack) }
    guard Array(payload.prefix(Self.marker.count)) == Self.marker else {
      try fail(.unsupportedMarker)
    }
    guard payload.count >= fixed else { try fail(.malformedHelloBack) }
    let versionStart = Self.marker.count
    guard Array(payload[versionStart..<versionStart + Self.version.count]) == Self.version else {
      try fail(.unsupportedVersion)
    }
    let lengthStart = versionStart + Self.version.count
    let declared = payload[lengthStart..<fixed].reduce(0) { ($0 << 8) | Int($1) }
    guard declared == payload.count - fixed else { try fail(.malformedHelloBack) }
    let name = Array(payload[fixed...])
    guard Self.isValidName(name, limit: maximumScreenNameByteCount) else {
      try fail(.invalidScreenName)
    }
    // Validated ASCII identifier bytes, so decoding cannot substitute.
    let text = String(decoding: name, as: UTF8.self)
    guard expectedScreenNames.contains(text) else { try fail(.unknownClientScreen) }
    clientScreenName = text
  }

  private mutating func acceptScreenInfo(_ payload: [UInt8]) throws(BarrierServerHandshakeError)
    -> BarrierScreenInfo
  {
    let outcome: BarrierControlOutcome
    do throws(BarrierControlMessageError) {
      outcome = try decoder.decode(payload: payload, direction: .clientToServer)
    } catch {
      try fail(.screenInfoRejected(error))
    }
    guard case .event(.screenInfo(let screen)) = outcome else { try fail(.unexpectedFrame) }
    return screen
  }

  private mutating func terminate(_ error: BarrierServerHandshakeError) {
    switch state {
    case .idle, .awaitingHelloBack, .awaitingScreenInfo:
      state = .failed(error)
      clientScreenName = nil
    case .ready, .failed:
      break
    }
  }

  private mutating func expect(_ expected: State) throws(BarrierServerHandshakeError) {
    switch state {
    case .failed(let error):
      throw error
    case .ready:
      throw .alreadyReady
    case expected:
      return
    case .idle, .awaitingHelloBack, .awaitingScreenInfo:
      try fail(.outOfOrderEvent)
    }
  }

  private mutating func fail(_ error: BarrierServerHandshakeError)
    throws(BarrierServerHandshakeError)
    -> Never
  {
    state = .failed(error)
    clientScreenName = nil
    throw error
  }

  private static func isValidName(_ bytes: [UInt8], limit: Int) -> Bool {
    guard !bytes.isEmpty, bytes.count <= limit else { return false }
    return bytes.allSatisfy { byte in
      switch byte {
      case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
        true
      default:
        false
      }
    }
  }

  private static func tokenFrame(_ token: BarrierControlToken) -> [UInt8] {
    frame(token.bytes)
  }

  private static func frame(_ payload: [UInt8]) -> [UInt8] {
    let count = UInt32(payload.count)
    return [
      UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF),
      UInt8(count & 0xFF),
    ]
      + payload
  }
}
