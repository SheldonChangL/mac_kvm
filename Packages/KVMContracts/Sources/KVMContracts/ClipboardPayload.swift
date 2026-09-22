import Foundation

/// Clipboard failures are terminal and content-caused: retrying the same input
/// can only fail the same way, and no clipboard resource was acquired before
/// the check. The error carries the frozen taxonomy value and nothing else, so
/// no text, byte count, or hash can escape through it.
private func clipboardFailure(_ code: ClipboardErrorCode) -> CoreError {
  CoreError(
    code: .clipboard(code),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )
}

/// A caller-supplied, strictly positive UTF-8 byte budget for one clipboard
/// transfer.
///
/// M1-052 deliberately defines no default, minimum, or global maximum. C-007
/// freezes that clipboard content carries size limits; it does not freeze a
/// number, and inventing one here would bind every future platform, session,
/// and configuration Issue to a value this contract has no evidence for. The
/// limit is therefore always supplied by the policy owner.
///
/// A non-positive budget is rejected at construction rather than at use. The
/// frozen `ClipboardErrorCode` allowlist has no code for a misconfigured
/// limit, and M1-052 must not extend that allowlist, so the type makes the
/// invalid state unrepresentable instead of inventing a failure code for it.
public struct ClipboardByteLimit: Hashable, Sendable {
  public let byteCount: Int

  /// Returns `nil` when `byteCount` is zero or negative.
  public init?(byteCount: Int) {
    guard byteCount > 0 else {
      return nil
    }
    self.byteCount = byteCount
  }
}

/// The V1 clipboard codec: UTF-8 plain text only.
///
/// There is no representation, format, or type parameter, so no caller can ask
/// for anything else. Platform pasteboard type negotiation, content hashing,
/// loop suppression, and wire framing are owned by their own Issues and are
/// deliberately absent here.
///
/// Both directions are pure, synchronous, and total over their inputs: the
/// same input always produces the same result or the same typed failure, and
/// no value is retained, cached, or logged.
public enum ClipboardTextCodec {
  /// Encodes plain text to its UTF-8 bytes, rejecting content whose UTF-8
  /// length exceeds `limit`.
  ///
  /// The length is measured on the UTF-8 view before any buffer is produced,
  /// so an oversized value is rejected without being copied.
  public static func encode(_ text: String, limit: ClipboardByteLimit) throws -> Data {
    guard text.utf8.count <= limit.byteCount else {
      throw clipboardFailure(.oversized)
    }
    return Data(text.utf8)
  }

  /// Decodes UTF-8 bytes to plain text, rejecting oversized input before any
  /// decoding or allocation and rejecting malformed UTF-8 explicitly.
  ///
  /// Size is checked first so that an input that is both oversized and
  /// malformed never reaches the decoder; this is the guardrail requirement
  /// that unknown or oversize input is bounded before allocation.
  ///
  /// Validation is byte-faithful. `String(data:encoding:.utf8)` silently drops
  /// a leading U+FEFF, which would make a decode/encode cycle lose bytes, so
  /// the bytes are validated with the Unicode parser and only then converted.
  /// Malformed input is never repaired with U+FFFD; it is rejected.
  public static func decode(_ data: Data, limit: ClipboardByteLimit) throws -> String {
    guard data.count <= limit.byteCount else {
      throw clipboardFailure(.oversized)
    }
    guard ClipboardTextCodec.isWellFormedUTF8(data) else {
      throw clipboardFailure(.invalidUTF8)
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Rejects overlong encodings, surrogate code points, scalars above
  /// U+10FFFF, and truncated or stray continuation bytes.
  private static func isWellFormedUTF8(_ data: Data) -> Bool {
    var parser = Unicode.UTF8.ForwardParser()
    var bytes = data.makeIterator()
    while true {
      switch parser.parseScalar(from: &bytes) {
      case .valid:
        continue
      case .emptyInput:
        return true
      case .error:
        return false
      }
    }
  }
}

extension ClipboardPayload {
  /// The payload's size in UTF-8 bytes, which is the unit every clipboard
  /// limit is expressed in. Character count is not a size.
  public var utf8ByteCount: Int {
    utf8Text.utf8.count
  }

  /// Checks the payload against a caller-supplied budget.
  ///
  /// Only size is checked. `utf8Text` is a `String` and therefore always
  /// well-formed Unicode, and `contentHash` is verified by the Issue that
  /// owns hashing, not here.
  public func validate(against limit: ClipboardByteLimit) throws {
    guard utf8ByteCount <= limit.byteCount else {
      throw clipboardFailure(.oversized)
    }
  }
}
