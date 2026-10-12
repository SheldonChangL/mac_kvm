// Server hello validation for the first marker-bearing Barrier frame payload.
// docs/adr/M1-025-barrier-client-wire-contract.md freezes only this payload: ASCII marker
// bytes `42 61 72 72 69 65 72` followed immediately by the opaque version bytes
// `00 01 00 06`, under an exact-supported-version fail-closed policy. Barrier message
// codes, code width, optional fields and any field layout beyond these bytes are not
// frozen, so no message code is defined here and nothing after the version is accepted.
// The parser consumes one complete payload produced by BarrierFrameReassembler (M1-022);
// stream fragmentation is handled there.

/// Typed server hello failure. Carries only the payload byte count, never payload bytes.
enum BarrierServerHelloError: Error, Equatable, Sendable {
  /// The payload ends inside the marker; the bytes present match the supported marker.
  case truncatedMarker(payloadByteCount: Int)
  /// The marker is not the supported marker.
  case unsupportedMarker
  /// The payload ends inside the version; the bytes present match the supported version.
  case truncatedVersion(payloadByteCount: Int)
  /// The version is not the supported version. No negotiation or fallback is attempted.
  case unsupportedVersion
  /// Bytes follow the version. Their layout is not frozen, so they are not accepted.
  case unexpectedTrailingBytes(payloadByteCount: Int)
}

/// A validated server hello. Only constructible from a payload that equals the supported
/// marker followed by the supported version, with nothing before or after.
struct BarrierServerHello: Equatable, Sendable {
  static let supportedMarkerBytes: [UInt8] = [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72]
  /// Opaque: M1-025 does not freeze whether these bytes form one or more integers.
  static let supportedVersionBytes: [UInt8] = [0x00, 0x01, 0x00, 0x06]
  static let payloadByteCount = supportedMarkerBytes.count + supportedVersionBytes.count

  /// The accepted version bytes, always equal to `supportedVersionBytes`.
  let versionBytes: [UInt8]

  var markerBytes: [UInt8] { Self.supportedMarkerBytes }

  /// Validates the marker, then the version, then the payload length. A mismatch in the
  /// bytes present is reported before truncation, so a foreign variant is never reported
  /// as a partial supported hello.
  init(payload: [UInt8]) throws(BarrierServerHelloError) {
    let marker = Self.supportedMarkerBytes
    let markerPrefix = payload.prefix(marker.count)
    guard markerPrefix.elementsEqual(marker.prefix(markerPrefix.count)) else {
      throw .unsupportedMarker
    }
    guard markerPrefix.count == marker.count else {
      throw .truncatedMarker(payloadByteCount: payload.count)
    }

    let version = Self.supportedVersionBytes
    let versionPrefix = payload.dropFirst(marker.count).prefix(version.count)
    guard versionPrefix.elementsEqual(version.prefix(versionPrefix.count)) else {
      throw .unsupportedVersion
    }
    guard versionPrefix.count == version.count else {
      throw .truncatedVersion(payloadByteCount: payload.count)
    }

    guard payload.count == Self.payloadByteCount else {
      throw .unexpectedTrailingBytes(payloadByteCount: payload.count)
    }
    versionBytes = version
  }
}
