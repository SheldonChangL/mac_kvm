// Barrier client-direction mouse button decoder (M1-033). `DMDN` and `DMUP` each carry one
// body byte, a button number. The layout, the observed values 1 to 5 and the rule that other
// values are dropped come only from
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md
// (BARRIER-EVID-0006-CLAIM-002). The contract does not name the buttons: which `MouseButton`
// a wire value stands for is the first-party table of `BarrierServerInputEncoder.button`,
// which this decoder inverts. One complete payload, already bounded and reassembled by
// BarrierFrameReassembler (M1-022), becomes one outcome: a `KVMEvent.mouseButton` or a
// content-free drop diagnostic. The decoder is stateless, never logs, and imports only
// KVMContracts; updating macOS state is out of its scope.

import KVMContracts

/// The tokens M1-033 owns. Names are the frozen ASCII tokens, observed server to client only.
enum BarrierMouseButtonToken: CaseIterable, Hashable, Sendable {
  case dmdn, dmup

  static let byteCount = 4

  var bytes: [UInt8] {
    switch self {
    case .dmdn: Array("DMDN".utf8)
    case .dmup: Array("DMUP".utf8)
    }
  }

  /// `DMDN` presses a button and `DMUP` releases it.
  var phase: ButtonPhase {
    switch self {
    case .dmdn: .down
    case .dmup: .up
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

/// Typed decoder failure. A thrown error ends the session (M1-PROTOCOL-003 "Fail closed").
/// Carries only allowlisted metadata (token, direction, counts); never payload or body bytes.
enum BarrierMouseButtonDecoderError: Error, Equatable, Sendable {
  /// The payload is shorter than a token or starts with a token this decoder does not own.
  case unknownToken(payloadByteCount: Int)
  /// The token was observed only server to client.
  case unexpectedDirection(token: BarrierMouseButtonToken, direction: BarrierControlDirection)
  /// The body is not exactly one byte.
  case invalidBodyLength(token: BarrierMouseButtonToken, bodyByteCount: Int)
}

/// Allowlisted metadata for a dropped frame: the token, the direction, the body length and the
/// reason, never the button value (M1-PROTOCOL-003 "Rejection semantics", M1-011).
struct BarrierMouseButtonDropDiagnostic: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    /// Wire value 0 or 6...255: outside the contract's 1 to 5.
    case buttonOutOfContract
    /// Wire value 5: inside the contract, but `MouseButton` has no case for it.
    case unrepresentableButton
  }

  let token: BarrierMouseButtonToken
  let direction: BarrierControlDirection
  let bodyByteCount: Int
  let reason: Reason
}

/// Outcome of decoding one payload.
enum BarrierMouseButtonOutcome: Equatable, Sendable {
  /// Always `KVMEvent.mouseButton`.
  case event(KVMEvent)
  /// The frame is dropped and the session continues.
  case dropped(BarrierMouseButtonDropDiagnostic)
}

/// Stateless `DMDN`/`DMUP` decoder; the inverse of `BarrierServerInputEncoder.button`.
///
/// `decode` checks, in order: the token, the direction, the body length, then the value.
/// A failed check throws. A value that is not a representable button is dropped, and the
/// outcome depends on the frame's own bytes only. There is no pressed set. A `DMUP` is dropped
/// exactly when the `DMDN` with the same value is, so every press this decoder emits can be
/// released by an emitted `DMUP` carrying the same value, and a release of a representable
/// button is never dropped for lack of a press. Pairing is by value only: a release whose value
/// differs from its press releases a different button. The pressed-input ledger that releases
/// whatever is still held on a terminal path lives in the Core (M1-063-FOLLOWUP-001), not here.
/// Nothing here owns a resource, so there is nothing to cancel or clean up.
enum BarrierMouseButtonDecoder {
  static let bodyByteCount = 1

  /// The button numbers the contract accepts. Anything else is out of contract.
  private static let contractWireValues: ClosedRange<UInt8> = 1...5

  /// The `MouseButton` for a wire value: 1 left, 2 middle, 3 right, 4 auxiliary; `nil` for
  /// every other value, 5 included.
  ///
  /// This is the encoder's table, not `MouseButton`'s raw values: those are left 1, right 2,
  /// middle 3, so `MouseButton(rawValue:)` would swap middle and right.
  static func mouseButton(wireValue: UInt8) -> MouseButton? {
    switch wireValue {
    case 1: .left
    case 2: .middle
    case 3: .right
    case 4: .auxiliary
    default: nil
    }
  }

  static func decode(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierMouseButtonDecoderError) -> BarrierMouseButtonOutcome {
    guard let token = BarrierMouseButtonToken(payloadPrefix: payload) else {
      throw .unknownToken(payloadByteCount: payload.count)
    }
    guard direction == .serverToClient else {
      throw .unexpectedDirection(token: token, direction: direction)
    }
    let body = payload.dropFirst(BarrierMouseButtonToken.byteCount)
    guard body.count == bodyByteCount else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }
    let wireValue = body[body.startIndex]
    if let button = mouseButton(wireValue: wireValue) {
      return .event(.mouseButton(button: button, phase: token.phase))
    }
    let reason: BarrierMouseButtonDropDiagnostic.Reason =
      contractWireValues.contains(wireValue) ? .unrepresentableButton : .buttonOutOfContract
    return .dropped(
      BarrierMouseButtonDropDiagnostic(
        token: token, direction: direction, bodyByteCount: body.count, reason: reason))
  }
}
