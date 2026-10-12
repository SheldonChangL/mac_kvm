// Code-to-decoder registry for reassembled Barrier frame payloads.
// docs/adr/M1-025-barrier-client-wire-contract.md freezes only the frame envelope and the
// first-frame marker/version bytes; Barrier message codes, their widths and payload field
// layouts remain unknown. The registry therefore hardcodes no message code and assumes no
// code width: each later decoder issue registers its own evidenced code as an opaque byte
// prefix, and the registry only dispatches. Payloads matching no registered code are
// reported as a diagnostic outcome that retains no payload bytes.

/// Typed registration failure. Carries no code or payload bytes.
enum BarrierMessageRegistryError: Error, Equatable, Sendable {
  /// A message code must contain at least one byte.
  case emptyCode
  /// The code is already registered.
  case duplicateCode
  /// The code is a strict prefix of a registered code, or a registered code is a strict
  /// prefix of it, so dispatch would depend on registration order.
  case ambiguousCode
}

/// Opaque leading payload bytes that select a decoder. Deliberately not string-backed, so
/// a code cannot be logged or passed on as text.
struct BarrierMessageCode: Hashable, Sendable {
  let bytes: [UInt8]

  init(bytes: [UInt8]) throws(BarrierMessageRegistryError) {
    guard !bytes.isEmpty else { throw .emptyCode }
    self.bytes = bytes
  }

  fileprivate func isPrefix(of payload: [UInt8]) -> Bool {
    bytes.count <= payload.count && payload[..<bytes.count].elementsEqual(bytes)
  }
}

/// Allowlisted metadata for a payload that matched no registered code.
struct BarrierUnknownMessageDiagnostic: Equatable, Sendable {
  let payloadByteCount: Int
}

/// Outcome of dispatching one reassembled frame payload.
enum BarrierMessageDispatch<Message: Sendable>: Sendable {
  case decoded(Message)
  /// Unknown-message policy: skip the payload and report it. The registry never decodes,
  /// retains or throws for an unknown payload; the caller decides how to surface it.
  case unknown(BarrierUnknownMessageDiagnostic)
}

/// Maps message codes to decoders producing adapter-internal `Message` values.
///
/// Registered codes stay prefix-free, so at most one code matches any payload and dispatch
/// does not depend on registration order. A decoder receives the payload bytes after its
/// code, and its typed failure propagates unchanged. A failed registration leaves the
/// registry unchanged; `decode(_:)` does not mutate the registry.
struct BarrierMessageRegistry<Message: Sendable, DecodeFailure: Error>: Sendable {
  typealias Decoder = @Sendable ([UInt8]) throws(DecodeFailure) -> Message

  private struct Entry: Sendable {
    let code: BarrierMessageCode
    let decoder: Decoder
  }

  private var entries: [Entry] = []

  var registeredCodeCount: Int { entries.count }

  mutating func register(
    _ code: BarrierMessageCode,
    decoder: @escaping Decoder
  ) throws(BarrierMessageRegistryError) {
    for entry in entries {
      if entry.code == code { throw .duplicateCode }
      if entry.code.isPrefix(of: code.bytes) || code.isPrefix(of: entry.code.bytes) {
        throw .ambiguousCode
      }
    }
    entries.append(Entry(code: code, decoder: decoder))
  }

  func decode(_ payload: [UInt8]) throws(DecodeFailure) -> BarrierMessageDispatch<Message> {
    guard let entry = entries.first(where: { $0.code.isPrefix(of: payload) }) else {
      return .unknown(BarrierUnknownMessageDiagnostic(payloadByteCount: payload.count))
    }
    return .decoded(try entry.decoder(Array(payload[entry.code.bytes.count...])))
  }
}
