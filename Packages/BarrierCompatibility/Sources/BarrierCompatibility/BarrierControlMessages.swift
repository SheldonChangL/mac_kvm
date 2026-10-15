// Screen-info, setup, enter, leave and keepalive control decoder for the Barrier protocol
// adapter. Field layouts, directions and bounds come only from
// docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md (BARRIER-EVID-0005): a
// 4-byte ASCII token starts every payload, QINF/CIAK/CROP/CALV/CNOP/COUT carry no body,
// DSOP carries a 4-byte zero, DINF a 14-byte screen description and CINN a 10-byte enter.
// DCLP/DKDN/DKUP are known excluded tokens: one complete payload is skipped and reported
// without decoding its body. Every other token fails closed. The decoder consumes complete
// payloads produced by BarrierFrameReassembler (M1-022); stream fragmentation is handled
// there. Outputs are adapter-internal; mapping enter/leave to KVMEvent belongs to a later
// adapter issue, and keepalive/no-op outputs are never control events.

/// Direction of the stream a payload was read from.
enum BarrierControlDirection: Equatable, Sendable {
  case serverToClient
  case clientToServer
}

/// The tokens M1-031 recognizes. Names are the frozen ASCII tokens.
enum BarrierControlToken: CaseIterable, Hashable, Sendable {
  case qinf, ciak, crop, dsop, dinf, cinn, cout, calv, cnop
  /// Known excluded side-effect tokens: skipped, never decoded.
  case dclp, dkdn, dkup

  static let byteCount = 4

  var bytes: [UInt8] {
    switch self {
    case .qinf: Array("QINF".utf8)
    case .ciak: Array("CIAK".utf8)
    case .crop: Array("CROP".utf8)
    case .dsop: Array("DSOP".utf8)
    case .dinf: Array("DINF".utf8)
    case .cinn: Array("CINN".utf8)
    case .cout: Array("COUT".utf8)
    case .calv: Array("CALV".utf8)
    case .cnop: Array("CNOP".utf8)
    case .dclp: Array("DCLP".utf8)
    case .dkdn: Array("DKDN".utf8)
    case .dkup: Array("DKUP".utf8)
    }
  }

  /// Directions in which BARRIER-EVID-0005 observed the token. Any other direction fails
  /// closed.
  var observedDirections: [BarrierControlDirection] {
    switch self {
    case .calv: [.serverToClient, .clientToServer]
    case .dinf, .cnop: [.clientToServer]
    case .qinf, .ciak, .crop, .dsop, .cinn, .cout, .dclp, .dkdn, .dkup: [.serverToClient]
    }
  }

  init?(payloadPrefix payload: [UInt8]) {
    guard
      let token = Self.allCases.first(where: {
        payload.prefix(Self.byteCount).elementsEqual($0.bytes)
      })
    else { return nil }
    self = token
  }
}

/// Typed control failure. Carries only allowlisted metadata (token, direction, counts,
/// limits); never payload bytes, body bytes or screen geometry.
enum BarrierControlMessageError: Error, Equatable, Sendable {
  /// The caller-supplied limit cannot hold the largest consumable payload (DINF).
  case invalidMaximumPayloadLength
  /// The payload exceeds the caller-supplied limit. Checked before the token.
  case oversizePayload(limit: Int)
  /// The payload is shorter than a token or starts with a token M1-031 does not recognize.
  case unknownToken(payloadByteCount: Int)
  /// The token was not observed in this direction.
  case unexpectedDirection(token: BarrierControlToken, direction: BarrierControlDirection)
  /// The body is not exactly the frozen length (truncated or trailing bytes).
  case invalidBodyLength(token: BarrierControlToken, bodyByteCount: Int)
  /// DSOP carries a value other than the observed zero.
  case unsupportedSetupOption
  /// The DINF reserved field is not zero.
  case nonZeroReservedField
  /// A DINF width or height is zero or above 0x7fff.
  case invalidScreenSize
  /// A raw coordinate is above 0x7fff, where signed and unsigned readings disagree.
  case coordinateOutOfRange(token: BarrierControlToken)
  /// A coordinate lies outside the DINF rectangle it is validated against.
  case coordinateOutsideScreen(token: BarrierControlToken)
  /// CINN arrived before any valid DINF.
  case enterWithoutScreenInfo
  /// The token is not accepted in the current session state.
  case unexpectedInState(token: BarrierControlToken)
}

/// A validated DINF body. The reserved field is always zero and is not kept. Width and
/// height are in `1...0x7fff`; cursor coordinates are in `0...0x7fff` and inside the
/// rectangle.
struct BarrierScreenInfo: Equatable, Sendable {
  let originX: Int16
  let originY: Int16
  let width: UInt16
  let height: UInt16
  let cursorX: UInt16
  let cursorY: UInt16

  /// True when (`x`, `y`) lies in `[origin, origin + size)` on both axes. Computed in `Int`,
  /// so no edge can overflow.
  func contains(x: UInt16, y: UInt16) -> Bool {
    Self.span(origin: originX, size: width).contains(Int(x))
      && Self.span(origin: originY, size: height).contains(Int(y))
  }

  private static func span(origin: Int16, size: UInt16) -> Range<Int> {
    Int(origin)..<(Int(origin) + Int(size))
  }
}

/// The CINN sequence field. Opaque: only its position is frozen, not its ordering.
struct BarrierEnterSequence: Equatable, Sendable {
  let rawValue: UInt32
}

/// The CINN modifier mask. Opaque: no bit meaning is frozen.
struct BarrierEnterModifierMask: Equatable, Sendable {
  let rawValue: UInt16
}

/// A validated CINN body. Coordinates are in `0...0x7fff` and inside the current screen.
struct BarrierEnter: Equatable, Sendable {
  let x: UInt16
  let y: UInt16
  let sequence: BarrierEnterSequence
  let modifierMask: BarrierEnterModifierMask
}

/// Setup frames accepted and otherwise ignored.
enum BarrierSetupControl: Equatable, Sendable {
  case ciak
  case crop
  /// DSOP with its 4-byte zero body; no option semantics are frozen.
  case dsopZero
}

/// Platform-neutral control events for the Barrier session adapter. Not input events, and
/// deliberately without keepalive, no-op or excluded-frame cases.
enum BarrierControlEvent: Equatable, Sendable {
  case screenInfoRequested
  case setup(BarrierSetupControl)
  case screenInfo(BarrierScreenInfo)
  case enter(BarrierEnter)
  case leave
}

/// Keepalive and no-op frames. Protocol upkeep only; never forwarded as a control event.
enum BarrierKeepalive: Equatable, Sendable {
  case keepalive(BarrierControlDirection)
  case noOp
}

/// Allowlisted metadata for a skipped excluded frame. Never holds body bytes.
struct BarrierExcludedFrameDiagnostic: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    case excludedSideEffectNotConsumable
  }

  let token: BarrierControlToken
  let direction: BarrierControlDirection
  let payloadByteCount: Int
  let reason: Reason
}

/// Outcome of decoding one payload.
enum BarrierControlOutcome: Equatable, Sendable {
  case event(BarrierControlEvent)
  case keepalive(BarrierKeepalive)
  case skipped(BarrierExcludedFrameDiagnostic)

  var controlEvent: BarrierControlEvent? {
    if case .event(let event) = self { event } else { nil }
  }
}

/// Deterministic control-message decoder for one Barrier session.
///
/// The caller passes every complete payload of both directions, including the client's own
/// outbound DINF, with its direction. State rules, the minimum needed to validate enter
/// against the current screen without claiming ordering the evidence does not show:
///
/// - `setup`: before the first enter. QINF, CIAK, CROP and DSOP are accepted only here
///   (QINF also in `inactive`). A DINF sets or replaces the screen.
/// - CINN requires a screen and moves `setup` or `inactive` to `active`; in `active` it
///   fails closed (repeated enter is not evidenced).
/// - COUT is accepted only in `active` and moves to `inactive`.
/// - Screen geometry changes only while not active: QINF and DINF fail closed in `active`.
/// - CALV, CNOP and excluded frames are accepted in every live state and change nothing.
///
/// Failures are terminal and sticky: the first error is latched in `.failed`, which keeps
/// no geometry, and every later payload rethrows it. A new session needs a new decoder.
/// There is no I/O, timer, task or resource, so there is nothing to cancel.
struct BarrierControlDecoder: Sendable {
  enum State: Equatable, Sendable {
    case setup(BarrierScreenInfo?)
    case active(BarrierScreenInfo)
    case inactive(BarrierScreenInfo)
    case failed(BarrierControlMessageError)

    var screen: BarrierScreenInfo? {
      switch self {
      case .setup(let screen): screen
      case .active(let screen), .inactive(let screen): screen
      case .failed: nil
      }
    }
  }

  private static let dinfBodyByteCount = 14
  private static let cinnBodyByteCount = 10
  private static let dsopBodyByteCount = 4
  private static let maximumRawCoordinate: UInt16 = 0x7FFF
  /// DINF is the largest consumable payload: token plus 14-byte body.
  static let minimumMaximumPayloadLength = BarrierControlToken.byteCount + dinfBodyByteCount

  /// Product safety bound on one payload, supplied by the caller, who should configure the
  /// frame reassembler with the same value. Not an observed Barrier limit.
  let maximumPayloadLength: Int
  private(set) var state = State.setup(nil)

  init(maximumPayloadLength: Int) throws(BarrierControlMessageError) {
    guard maximumPayloadLength >= Self.minimumMaximumPayloadLength else {
      throw .invalidMaximumPayloadLength
    }
    self.maximumPayloadLength = maximumPayloadLength
  }

  /// Checks, in order: limit, token, direction, body length and fields, then state.
  mutating func decode(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierControlMessageError) -> BarrierControlOutcome {
    if case .failed(let error) = state { throw error }
    do throws(BarrierControlMessageError) {
      return try decodeLive(payload: payload, direction: direction)
    } catch {
      state = .failed(error)
      throw error
    }
  }

  private mutating func decodeLive(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierControlMessageError) -> BarrierControlOutcome {
    guard payload.count <= maximumPayloadLength else {
      throw .oversizePayload(limit: maximumPayloadLength)
    }
    guard let token = BarrierControlToken(payloadPrefix: payload) else {
      throw .unknownToken(payloadByteCount: payload.count)
    }
    guard token.observedDirections.contains(direction) else {
      throw .unexpectedDirection(token: token, direction: direction)
    }
    let body = payload.dropFirst(BarrierControlToken.byteCount)

    switch token {
    case .dclp, .dkdn, .dkup:
      return .skipped(
        BarrierExcludedFrameDiagnostic(
          token: token, direction: direction, payloadByteCount: payload.count,
          reason: .excludedSideEffectNotConsumable))
    case .calv:
      try requireBody(body, count: 0, token: token)
      return .keepalive(.keepalive(direction))
    case .cnop:
      try requireBody(body, count: 0, token: token)
      return .keepalive(.noOp)
    case .qinf:
      try requireBody(body, count: 0, token: token)
      if case .active = state { throw .unexpectedInState(token: token) }
      return .event(.screenInfoRequested)
    case .ciak, .crop:
      try requireBody(body, count: 0, token: token)
      try requireSetup(token)
      return .event(.setup(token == .ciak ? .ciak : .crop))
    case .dsop:
      try requireBody(body, count: Self.dsopBodyByteCount, token: token)
      guard body.allSatisfy({ $0 == 0 }) else { throw .unsupportedSetupOption }
      try requireSetup(token)
      return .event(.setup(.dsopZero))
    case .dinf:
      let screen = try Self.screenInfo(body)
      switch state {
      case .setup:
        state = .setup(screen)
      case .inactive:
        state = .inactive(screen)
      case .active, .failed:
        throw .unexpectedInState(token: token)
      }
      return .event(.screenInfo(screen))
    case .cinn:
      let enter = try Self.enter(body)
      let screen: BarrierScreenInfo
      switch state {
      case .setup(let current?), .inactive(let current):
        screen = current
      case .setup(nil):
        throw .enterWithoutScreenInfo
      case .active, .failed:
        throw .unexpectedInState(token: token)
      }
      guard screen.contains(x: enter.x, y: enter.y) else {
        throw .coordinateOutsideScreen(token: token)
      }
      state = .active(screen)
      return .event(.enter(enter))
    case .cout:
      try requireBody(body, count: 0, token: token)
      guard case .active(let screen) = state else { throw .unexpectedInState(token: token) }
      state = .inactive(screen)
      return .event(.leave)
    }
  }

  private func requireSetup(_ token: BarrierControlToken) throws(BarrierControlMessageError) {
    guard case .setup = state else { throw .unexpectedInState(token: token) }
  }

  private func requireBody(
    _ body: ArraySlice<UInt8>, count: Int, token: BarrierControlToken
  ) throws(BarrierControlMessageError) {
    guard body.count == count else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }
  }

  private static func screenInfo(
    _ body: ArraySlice<UInt8>
  ) throws(BarrierControlMessageError) -> BarrierScreenInfo {
    guard body.count == dinfBodyByteCount else {
      throw .invalidBodyLength(token: .dinf, bodyByteCount: body.count)
    }
    guard uint16(body, at: 8) == 0 else { throw .nonZeroReservedField }
    let width = uint16(body, at: 4)
    let height = uint16(body, at: 6)
    guard (1...maximumRawCoordinate).contains(width), (1...maximumRawCoordinate).contains(height)
    else { throw .invalidScreenSize }
    let cursorX = uint16(body, at: 10)
    let cursorY = uint16(body, at: 12)
    guard cursorX <= maximumRawCoordinate, cursorY <= maximumRawCoordinate else {
      throw .coordinateOutOfRange(token: .dinf)
    }
    let screen = BarrierScreenInfo(
      originX: Int16(bitPattern: uint16(body, at: 0)),
      originY: Int16(bitPattern: uint16(body, at: 2)),
      width: width, height: height, cursorX: cursorX, cursorY: cursorY)
    guard screen.contains(x: cursorX, y: cursorY) else {
      throw .coordinateOutsideScreen(token: .dinf)
    }
    return screen
  }

  private static func enter(
    _ body: ArraySlice<UInt8>
  ) throws(BarrierControlMessageError) -> BarrierEnter {
    guard body.count == cinnBodyByteCount else {
      throw .invalidBodyLength(token: .cinn, bodyByteCount: body.count)
    }
    let x = uint16(body, at: 0)
    let y = uint16(body, at: 2)
    guard x <= maximumRawCoordinate, y <= maximumRawCoordinate else {
      throw .coordinateOutOfRange(token: .cinn)
    }
    let sequence = UInt32(uint16(body, at: 4)) << 16 | UInt32(uint16(body, at: 6))
    return BarrierEnter(
      x: x, y: y, sequence: BarrierEnterSequence(rawValue: sequence),
      modifierMask: BarrierEnterModifierMask(rawValue: uint16(body, at: 8)))
  }

  /// Big-endian 16-bit read; callers have already checked the exact body length.
  private static func uint16(_ body: ArraySlice<UInt8>, at offset: Int) -> UInt16 {
    let index = body.startIndex + offset
    return UInt16(body[index]) << 8 | UInt16(body[index + 1])
  }
}
