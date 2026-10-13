// Client handshake state machine for the Barrier protocol adapter.
// Sequences the two frozen handshake contracts: the server hello payload validated by
// BarrierServerHello (M1-027, docs/adr/M1-025-barrier-client-wire-contract.md) and the
// HelloBack frame written by BarrierClientHelloBackWriter (M1-028,
// docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md). The progression is
// connected -> awaitHello -> sendHelloBack -> protocolConnected. Every input is an
// explicit event: the caller owns the transport, the reassembler (M1-022) and the clock,
// and injects timeout and cancellation as signals, so no I/O, timer or sleep lives here.
// Messages after HelloBack (QINF and later) are not frozen and are not handled here.

/// Typed handshake failure. Carries only the nested typed errors, which hold at most byte
/// counts and limits; never payload bytes or screen-name bytes.
enum BarrierClientHandshakeError: Error, Equatable, Sendable {
  /// The server hello payload was rejected by M1-027 validation.
  case serverHelloRejected(BarrierServerHelloError)
  /// The HelloBack frame could not be written for the configured screen name.
  case helloBackRejected(BarrierClientHelloBackError)
  /// The caller's timeout signal arrived before the handshake completed.
  case timedOut
  /// The caller cancelled the handshake before it completed.
  case cancelled
  /// An event arrived in a state that does not accept it.
  case outOfOrderEvent
  /// An event arrived after the handshake completed. The completed state is kept.
  case alreadyConnected
}

/// Deterministic Barrier client handshake.
///
/// `start()` moves `connected` to `awaitHello`. `receiveServerHello(payload:)` takes one
/// complete payload from the frame reassembler, validates it, then returns the HelloBack
/// frame for the caller to write and moves to `sendHelloBack`. `helloBackSent()` reports
/// that the caller wrote that frame and moves to `protocolConnected`.
///
/// Failures are terminal and sticky: the first failure is latched in `.failed`, later
/// events rethrow it, and `timeOut()` and `cancel()` keep the original reason. Any event out
/// of order before completion fails closed. After `protocolConnected` events throw
/// `alreadyConnected` without changing state, and late timeout or cancel signals are
/// ignored because session teardown belongs to the session owner. The screen name is
/// released on entering `sendHelloBack` or any terminal state.
struct BarrierClientHandshake: Sendable {
  enum State: Equatable, Sendable {
    case connected
    case awaitHello
    case sendHelloBack
    case protocolConnected
    case failed(BarrierClientHandshakeError)
  }

  private(set) var state = State.connected
  private let helloBackWriter: BarrierClientHelloBackWriter
  private var screenName: String?

  /// The screen name is validated by the writer only after a supported hello is accepted.
  init(screenName: String, helloBackWriter: BarrierClientHelloBackWriter) {
    self.screenName = screenName
    self.helloBackWriter = helloBackWriter
  }

  mutating func start() throws(BarrierClientHandshakeError) {
    try expect(.connected)
    state = .awaitHello
  }

  /// Validates the hello before the screen name, so no HelloBack is composed for an
  /// unsupported server.
  mutating func receiveServerHello(
    payload: [UInt8]
  ) throws(BarrierClientHandshakeError) -> [UInt8] {
    try expect(.awaitHello)
    do throws(BarrierServerHelloError) {
      _ = try BarrierServerHello(payload: payload)
    } catch {
      try fail(.serverHelloRejected(error))
    }
    let frame: [UInt8]
    do throws(BarrierClientHelloBackError) {
      frame = try helloBackWriter.frame(screenName: screenName ?? "")
    } catch {
      try fail(.helloBackRejected(error))
    }
    screenName = nil
    state = .sendHelloBack
    return frame
  }

  mutating func helloBackSent() throws(BarrierClientHandshakeError) {
    try expect(.sendHelloBack)
    state = .protocolConnected
  }

  /// Injected timeout signal. Terminal before completion; ignored afterwards.
  mutating func timeOut() {
    terminate(.timedOut)
  }

  /// Injected cancellation. Terminal before completion; ignored afterwards.
  mutating func cancel() {
    terminate(.cancelled)
  }

  private mutating func terminate(_ error: BarrierClientHandshakeError) {
    switch state {
    case .connected, .awaitHello, .sendHelloBack:
      state = .failed(error)
      screenName = nil
    case .protocolConnected, .failed:
      break
    }
  }

  /// Throws the latched failure, `alreadyConnected`, or fails closed when `expected` is not
  /// the current pending state.
  private mutating func expect(_ expected: State) throws(BarrierClientHandshakeError) {
    switch state {
    case .failed(let error):
      throw error
    case .protocolConnected:
      throw .alreadyConnected
    case expected:
      return
    case .connected, .awaitHello, .sendHelloBack:
      try fail(.outOfOrderEvent)
    }
  }

  /// Latches `error`, releases the screen name and throws.
  private mutating func fail(
    _ error: BarrierClientHandshakeError
  ) throws(BarrierClientHandshakeError) -> Never {
    state = .failed(error)
    screenName = nil
    throw error
  }
}
